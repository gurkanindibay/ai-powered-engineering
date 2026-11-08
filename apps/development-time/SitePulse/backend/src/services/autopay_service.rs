//! Autopay with saved cards, SPEC-009 R6 (6493: SitePulse stores only the
//! provider's token, brand, last four digits and expiry; never the card).
//!
//! The daily run charges each active mandate's open due items through the
//! provider. A capture is recorded through the single ingestion path
//! (`record_and_allocate_payment`, idempotency `AUTOPAY:<mandate>:<due>:<attempt>`),
//! so a repeated run never records twice. A decline is logged, notified and
//! retried on D+2 and D+5 after the first attempt; it never marks a due as paid.
//! An expired card suspends the mandate.

use chrono::{Datelike, Days, NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::kvkk::DeliveryChannel;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::services::notification_service::{Message, NotificationService};
use crate::state::AppState;

pub const MAX_ATTEMPTS: i32 = 3;
/// Days after the first attempt on which declined charges are retried.
pub const RETRY_OFFSETS: [u64; 2] = [2, 5];
pub const CARD_INSTALLMENTS: [i32; 6] = [1, 2, 3, 6, 9, 12];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChargeOutcome {
    Captured { reference: String },
    Declined { reason: String },
    ExpiredCard,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct ChargeError(pub String);

/// A provider that charges a saved card token (merchant-initiated transaction).
pub trait TokenCharger: Send + Sync {
    fn name(&self) -> &'static str;
    fn charge(
        &self,
        token: &str,
        amount: Decimal,
        reference: &str,
    ) -> Result<ChargeOutcome, ChargeError>;
    /// Card instalment counts the provider offers.
    fn installments(&self) -> &'static [i32] {
        &CARD_INSTALLMENTS
    }
}

/// Sandbox rules: a token containing `decline` is declined, `expired` is an
/// expired card, anything else is captured.
pub struct SandboxCharger;

impl TokenCharger for SandboxCharger {
    fn name(&self) -> &'static str {
        crate::services::card_payment_service::SANDBOX_PROVIDER
    }
    fn charge(
        &self,
        token: &str,
        _amount: Decimal,
        reference: &str,
    ) -> Result<ChargeOutcome, ChargeError> {
        Ok(if token.contains("expired") {
            ChargeOutcome::ExpiredCard
        } else if token.contains("decline") {
            ChargeOutcome::Declined {
                reason: "Insufficient funds (sandbox)".into(),
            }
        } else {
            ChargeOutcome::Captured {
                reference: format!("SBX-MIT-{}", reference),
            }
        })
    }
}

pub fn configured_charger() -> Result<Box<dyn TokenCharger>, ChargeError> {
    let name = std::env::var("SITEPULSE_PAYMENT_PROVIDER").unwrap_or_else(|_| "SANDBOX".into());
    match name.trim().to_ascii_uppercase().as_str() {
        "SANDBOX" if !crate::state::AppStateInner::is_production() => Ok(Box::new(SandboxCharger)),
        "SANDBOX" => Err(ChargeError(
            "Autopay is not available: no licensed payment provider is configured".into(),
        )),
        other => Err(ChargeError(format!(
            "Card token charges through '{}' are not integrated in this build",
            other
        ))),
    }
}

fn card_expired(method: &SavedPaymentMethod, on: NaiveDate) -> bool {
    (method.exp_year, method.exp_month) < (on.year(), i32::try_from(on.month()).unwrap_or(12))
}

pub struct AutopayService {
    state: AppState,
    store: FinanceStore,
}

impl AutopayService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    /// Validates and stores the instalment choice and save-card flag of a new intent.
    pub async fn set_intent_options(
        &self,
        intent_id: &str,
        installments: Option<i32>,
        save_card: bool,
    ) -> FinanceResult<()> {
        let n = installments.unwrap_or(1);
        let charger = configured_charger().map_err(|e| FinanceError::Unavailable(e.0))?;
        if !charger.installments().contains(&n) {
            return Err(invalid(format!(
                "{} instalments are not offered; choose one of {:?}",
                n,
                charger.installments()
            )));
        }
        if n != 1 || save_card {
            self.store
                .set_intent_options(intent_id, n, save_card)
                .await?;
        }
        Ok(())
    }

    /// After a captured hosted payment: keeps the provider's card token when the
    /// payer asked to save the card. The sandbox issues its own token.
    pub async fn after_capture(
        &self,
        intent: &PaymentIntent,
        token: Option<ProviderCardToken>,
    ) -> FinanceResult<Option<SavedPaymentMethod>> {
        let save = self
            .store
            .read(|inner| inner.finance.intent_options.get(&intent.id).map(|o| o.1))
            .await
            .unwrap_or(false);
        if !save || intent.status != INTENT_CAPTURED {
            return Ok(None);
        }
        let token = match token {
            Some(t) => t,
            None if intent.provider == crate::services::card_payment_service::SANDBOX_PROVIDER => {
                ProviderCardToken {
                    token: format!("tok_sbx_{}", uuid::Uuid::new_v4().simple()),
                    brand: "VISA".into(),
                    last4: "4242".into(),
                    exp_month: 12,
                    exp_year: Utc::now().year() + 3,
                }
            }
            None => return Ok(None),
        };
        self.save_method(intent, token).await.map(Some)
    }

    pub async fn save_method(
        &self,
        intent: &PaymentIntent,
        token: ProviderCardToken,
    ) -> FinanceResult<SavedPaymentMethod> {
        if token.last4.len() != 4 || !token.last4.chars().all(|c| c.is_ascii_digit()) {
            return Err(invalid("last4 must be four digits"));
        }
        if let Some(existing) = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .payment_methods
                    .iter()
                    .find(|m| m.provider == intent.provider && m.token_ref == token.token)
                    .cloned()
            })
            .await
        {
            return Ok(existing);
        }
        let method = SavedPaymentMethod {
            id: 0,
            site_id: intent.site_id.clone(),
            unit_id: intent.unit_id.clone(),
            debtor_type: intent.debtor_type.clone(),
            owner_ref: intent.created_by.clone(),
            provider: intent.provider.clone(),
            token_ref: token.token,
            brand: token.brand,
            last4: token.last4,
            exp_month: token.exp_month,
            exp_year: token.exp_year,
            status: MANDATE_ACTIVE.to_string(),
            created_at: Utc::now(),
        };
        Ok(self.store.insert(method, col::payment_methods).await?)
    }

    pub async fn overview(&self, caller: &Caller, unit_id: &str) -> FinanceResult<AutopayOverview> {
        self.store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, unit_id)?;
                let own = resident_debtor(caller, &unit);
                let mine = |debtor: &str| own.is_none_or(|o| o == debtor);
                let methods: Vec<SavedPaymentMethod> = inner
                    .finance
                    .payment_methods
                    .iter()
                    .filter(|m| crate::auth::same_id(&m.unit_id, &unit.id) && mine(&m.debtor_type))
                    .cloned()
                    .collect();
                let mandates: Vec<AutopayMandate> = inner
                    .finance
                    .mandates
                    .iter()
                    .filter(|m| crate::auth::same_id(&m.unit_id, &unit.id) && mine(&m.debtor_type))
                    .cloned()
                    .collect();
                let attempts = inner
                    .finance
                    .autopay_attempts
                    .iter()
                    .filter(|a| mandates.iter().any(|m| m.id == a.mandate_id))
                    .cloned()
                    .collect();
                Ok(AutopayOverview {
                    payment_methods: methods,
                    mandates,
                    attempts,
                })
            })
            .await
    }

    pub async fn create_mandate(
        &self,
        caller: &Caller,
        unit_id: &str,
        req: CreateMandateRequest,
    ) -> FinanceResult<AutopayMandate> {
        if let Some(max) = req.max_amount {
            money(max, "max_amount")?;
        }
        let (unit, method) = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, unit_id)?;
                let method = inner
                    .finance
                    .payment_methods
                    .iter()
                    .find(|m| {
                        m.id == req.payment_method_id && crate::auth::same_id(&m.unit_id, &unit.id)
                    })
                    .cloned()
                    .ok_or_else(|| not_found("Saved card not found for this unit"))?;
                Ok::<_, FinanceError>((unit, method))
            })
            .await?;
        let debtor = match resident_debtor(caller, &unit) {
            Some(own) => own.to_string(),
            None => {
                parse_debtor(req.debtor_type.as_deref().or(Some(&method.debtor_type)))?.to_string()
            }
        };
        if method.debtor_type != debtor {
            return Err(FinanceError::Forbidden(
                "The card belongs to the other debtor of the unit".into(),
            ));
        }
        let today = self
            .store
            .read(|inner| site_today(inner, &caller.site_id))
            .await;
        if method.status != MANDATE_ACTIVE || card_expired(&method, today) {
            return Err(conflict("The saved card is not active or has expired"));
        }
        let exists = self
            .store
            .read(|inner| {
                inner.finance.mandates.iter().any(|m| {
                    m.status == MANDATE_ACTIVE
                        && crate::auth::same_id(&m.unit_id, &unit.id)
                        && m.debtor_type == debtor
                })
            })
            .await;
        if exists {
            return Err(conflict(
                "An active autopay mandate already exists for this debtor",
            ));
        }
        let now = Utc::now();
        let mandate = AutopayMandate {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: unit.id.clone(),
            debtor_type: debtor,
            payment_method_id: method.id,
            max_amount: req.max_amount,
            status: MANDATE_ACTIVE.to_string(),
            consented_by: caller.actor(),
            consented_at: now,
            suspended_reason: None,
            updated_at: now,
        };
        Ok(self.store.insert(mandate, col::mandates).await?)
    }

    pub async fn cancel_mandate(
        &self,
        caller: &Caller,
        unit_id: &str,
        mandate_id: i64,
    ) -> FinanceResult<AutopayMandate> {
        let mut mandate = self
            .store
            .read(|inner| {
                let unit = find_unit(inner, &caller.site_id, unit_id)?;
                let m = inner
                    .finance
                    .mandates
                    .iter()
                    .find(|m| m.id == mandate_id && crate::auth::same_id(&m.unit_id, &unit.id))
                    .cloned()
                    .ok_or_else(|| not_found(format!("Mandate {} not found", mandate_id)))?;
                if resident_debtor(caller, &unit).is_some_and(|own| own != m.debtor_type) {
                    return Err(FinanceError::Forbidden("Not your mandate".into()));
                }
                Ok(m)
            })
            .await?;
        mandate.status = MANDATE_CANCELLED.to_string();
        mandate.updated_at = Utc::now();
        Ok(self.store.update(mandate, col::mandates).await?)
    }

    /// Charges every active mandate's due items (daily job).
    pub async fn run(
        &self,
        site_id: &str,
        as_of: Option<NaiveDate>,
    ) -> FinanceResult<AutopayRunReport> {
        let as_of = match as_of {
            Some(d) => d,
            None => self.store.read(|inner| site_today(inner, site_id)).await,
        };
        let charger = configured_charger().map_err(|e| FinanceError::Unavailable(e.0))?;
        let mut report = AutopayRunReport {
            as_of: Some(as_of),
            ..AutopayRunReport::default()
        };
        // (mandate, method, due, attempt number) decided under one lock.
        let work = self
            .store
            .read(|inner| {
                let mut work = Vec::new();
                for m in inner.finance.mandates.iter().filter(|m| {
                    m.status == MANDATE_ACTIVE && crate::auth::same_id(&m.site_id, site_id)
                }) {
                    let Some(method) = inner
                        .finance
                        .payment_methods
                        .iter()
                        .find(|p| p.id == m.payment_method_id)
                    else {
                        continue;
                    };
                    let mut dues: Vec<&DuesLiability> = inner
                        .dues
                        .iter()
                        .filter(|d| {
                            crate::auth::same_id(&d.unit_id, &m.unit_id)
                                && d.debtor_type.as_str() == m.debtor_type
                                && d.due_date <= as_of
                                && is_open(d)
                        })
                        .collect();
                    dues.sort_by_key(|d| d.due_date);
                    for due in dues {
                        let attempts: Vec<&AutopayAttempt> = inner
                            .finance
                            .autopay_attempts
                            .iter()
                            .filter(|a| a.mandate_id == m.id && a.due_id == due.id)
                            .collect();
                        if attempts.iter().any(|a| a.status == "CAPTURED") {
                            continue;
                        }
                        let n = i32::try_from(attempts.len()).unwrap_or(MAX_ATTEMPTS);
                        if n >= MAX_ATTEMPTS {
                            continue;
                        }
                        if attempts
                            .iter()
                            .filter_map(|a| a.next_retry_on)
                            .max()
                            .is_some_and(|retry| retry > as_of)
                        {
                            continue;
                        }
                        let first = attempts.iter().map(|a| a.attempted_on).min();
                        work.push((m.clone(), method.clone(), due.clone(), n + 1, first));
                    }
                }
                work
            })
            .await;
        let mut suspended: Vec<i64> = Vec::new();
        for (mandate, method, due, attempt_no, first_attempt) in work {
            if suspended.contains(&mandate.id) {
                continue;
            }
            let outstanding = dues_ledger::outstanding(&due);
            let amount = mandate
                .max_amount
                .map_or(outstanding, |max| outstanding.min(max));
            if amount <= Decimal::ZERO {
                continue;
            }
            let reference = format!("{}-{}-{}", mandate.id, due.id, attempt_no);
            let outcome = if card_expired(&method, as_of) {
                ChargeOutcome::ExpiredCard
            } else {
                charger
                    .charge(&method.token_ref, amount, &reference)
                    .map_err(|e| FinanceError::Unavailable(e.0))?
            };
            let mut attempt = AutopayAttempt {
                id: 0,
                mandate_id: mandate.id,
                due_id: due.id.clone(),
                attempt_no,
                amount,
                status: String::new(),
                provider_ref: None,
                receipt_number: None,
                failure_reason: None,
                attempted_on: as_of,
                next_retry_on: None,
                created_at: Utc::now(),
            };
            match outcome {
                ChargeOutcome::Captured { reference } => {
                    let payer = self
                        .store
                        .read(|inner| {
                            inner
                                .units
                                .iter()
                                .find(|u| crate::auth::same_id(&u.id, &mandate.unit_id))
                                .map(|u| debtor_name(inner, u, &mandate.debtor_type))
                        })
                        .await
                        .unwrap_or_else(|| "Otomatik ödeme".into());
                    let receipt = crate::services::PaymentTrackingService::new(self.state.clone())
                        .record_and_allocate_payment(RecordManualPaymentRequest {
                            site_id: Some(mandate.site_id.clone()),
                            unit_id: mandate.unit_id.clone(),
                            amount,
                            payer_name: payer,
                            payer_role: DebtorType::from_str_loose(&mandate.debtor_type),
                            payment_channel: PaymentChannel::CreditCard,
                            description: Some(format!(
                                "Otomatik ödeme ({} ****{})",
                                method.brand, method.last4
                            )),
                            idempotency_key: Some(format!(
                                "AUTOPAY:{}:{}:{}",
                                mandate.id, due.id, attempt_no
                            )),
                            designation: Some(PaymentDesignation {
                                due_ids: vec![due.id.clone()],
                                ..PaymentDesignation::default()
                            }),
                            external_reference: Some(reference.clone()),
                            ..RecordManualPaymentRequest::default()
                        })
                        .await
                        .map_err(FinanceError::Conflict)?;
                    attempt.status = "CAPTURED".into();
                    attempt.provider_ref = Some(reference);
                    attempt.receipt_number = Some(receipt.receipt_number);
                    report.charged += 1;
                }
                ChargeOutcome::Declined { reason } => {
                    attempt.status = "DECLINED".into();
                    attempt.failure_reason = Some(reason.clone());
                    let base = first_attempt.unwrap_or(as_of);
                    attempt.next_retry_on = usize::try_from(attempt_no - 1)
                        .ok()
                        .and_then(|i| RETRY_OFFSETS.get(i))
                        .and_then(|days| base.checked_add_days(Days::new(*days)));
                    report.declined += 1;
                    self.notify(
                        &mandate,
                        "AUTOPAY",
                        &format!("Otomatik ödeme reddedildi ({})", due.period),
                        &format!(
                            "{} ****{} kartınızdan ₺{:.2} tahsil edilemedi: {}. {}",
                            method.brand,
                            method.last4,
                            amount,
                            reason,
                            if attempt.next_retry_on.is_some() {
                                "Tekrar denenecek."
                            } else {
                                "Lütfen ödemeyi elle yapın."
                            }
                        ),
                        &format!("autopay-decline:{}:{}:{}", mandate.id, due.id, attempt_no),
                    )
                    .await?;
                }
                ChargeOutcome::ExpiredCard => {
                    attempt.status = "EXPIRED_CARD".into();
                    attempt.failure_reason = Some("The saved card has expired".into());
                    let mut m = mandate.clone();
                    m.status = MANDATE_SUSPENDED.to_string();
                    m.suspended_reason = Some("Card expired".into());
                    m.updated_at = Utc::now();
                    self.store.update(m, col::mandates).await?;
                    let mut card = method.clone();
                    card.status = "EXPIRED".into();
                    self.store.update(card, col::payment_methods).await?;
                    suspended.push(mandate.id);
                    report.suspended += 1;
                    self.notify(&mandate, "AUTOPAY", "Kartınızın süresi doldu",
                        &format!("Otomatik ödeme için kayıtlı {} ****{} kartınızın süresi doldu; talimat durduruldu.", method.brand, method.last4),
                        &format!("autopay-expired:{}", mandate.id)).await?;
                }
            }
            report
                .attempts
                .push(self.store.insert(attempt, col::autopay_attempts).await?);
        }
        Ok(report)
    }

    async fn notify(
        &self,
        mandate: &AutopayMandate,
        category: &'static str,
        subject: &str,
        body: &str,
        key: &str,
    ) -> FinanceResult<()> {
        let unit = self
            .store
            .read(|inner| find_unit(inner, &mandate.site_id, &mandate.unit_id))
            .await?;
        let notifier = NotificationService::new(&self.state);
        let to = notifier.debtor_recipient(&unit, &mandate.debtor_type).await;
        notifier
            .deliver(
                Message {
                    site_id: mandate.site_id.clone(),
                    unit_id: Some(mandate.unit_id.clone()),
                    channel: DeliveryChannel::Push,
                    category,
                    subject: subject.to_string(),
                    body: body.to_string(),
                    dedupe_key: key.to_string(),
                    mandatory: true,
                },
                &to,
            )
            .await?;
        Ok(())
    }
}
