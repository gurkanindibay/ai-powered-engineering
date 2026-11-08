//! Card payments through a licensed payment provider, SPEC-007 R4.
//!
//! 6493 sayılı Kanun: accepting card payments is a licensed payment service, so
//! SitePulse never touches card data or funds. The resident pays on the provider's
//! hosted page (with 3-D Secure); the money settles into the site's own account;
//! SitePulse keeps a `payment_intent` with the provider's reference and state. The
//! provider's signed notification moves the intent, and a capture is recorded
//! through the single ingestion path (`record_and_allocate_payment`) with the
//! idempotency key `PSP:<provider>:<reference>`, so a repeated notification never
//! records the payment twice.
//!
//! The only provider implemented here is `SANDBOX`: a simulated hosted page served
//! by the backend outside production. A real provider (bank sanal POS or a
//! TCMB-licensed payment institution) is a new `PaymentProvider` implementation
//! selected with `SITEPULSE_PAYMENT_PROVIDER`.

use std::sync::OnceLock;

use chrono::Utc;
use hmac::{Hmac, Mac};
use rust_decimal::Decimal;
use sha2::Sha256;

use crate::models::{
    CreatePaymentIntentRequest, PaymentIntent, ProviderWebhookEvent, RecordManualPaymentRequest, INTENT_AUTHORIZED,
    INTENT_CAPTURED, INTENT_CREATED, INTENT_FAILED, INTENT_REFUNDED,
};
use crate::state::AppState;

pub const SANDBOX_PROVIDER: &str = "SANDBOX";
pub const SIGNATURE_HEADER: &str = "x-provider-signature";

/// A licensed provider's hosted checkout.
pub trait PaymentProvider: Send + Sync {
    fn name(&self) -> &'static str;
    /// The provider's reference and hosted payment page for a new intent.
    fn create_checkout(&self, intent: &PaymentIntent) -> Result<(String, String), String>;
    /// Asks the provider to refund a captured payment.
    fn refund(&self, intent: &PaymentIntent) -> Result<(), String>;
}

/// The simulated provider: its hosted page is served by this backend
/// (`/api/v1/payment-provider/sandbox/checkout/:ref`) and has no card fields.
pub struct SandboxProvider;

impl PaymentProvider for SandboxProvider {
    fn name(&self) -> &'static str {
        SANDBOX_PROVIDER
    }

    fn create_checkout(&self, _intent: &PaymentIntent) -> Result<(String, String), String> {
        let reference = format!("SBX-{}", uuid::Uuid::new_v4().simple());
        let url = format!("{}/api/v1/payment-provider/sandbox/checkout/{}", public_base_url(), reference);
        Ok((reference, url))
    }

    fn refund(&self, _intent: &PaymentIntent) -> Result<(), String> {
        Ok(())
    }
}

/// The provider configured for this deployment. The sandbox is never used in production.
pub fn configured_provider() -> Result<Box<dyn PaymentProvider>, String> {
    let name = std::env::var("SITEPULSE_PAYMENT_PROVIDER").unwrap_or_else(|_| SANDBOX_PROVIDER.to_string());
    match name.trim().to_uppercase().as_str() {
        SANDBOX_PROVIDER if !crate::state::AppStateInner::is_production() => Ok(Box::new(SandboxProvider)),
        SANDBOX_PROVIDER => Err("Card payments are not available: no licensed payment provider is configured".to_string()),
        other => Err(format!("Card payment provider '{}' is not integrated in this build", other)),
    }
}

pub fn sandbox_enabled() -> bool {
    !crate::state::AppStateInner::is_production()
}

/// Base URL the provider's hosted page and callbacks are reached on.
/// `SITEPULSE_PUBLIC_BASE_URL`, else the local bind address (development).
pub fn public_base_url() -> String {
    std::env::var("SITEPULSE_PUBLIC_BASE_URL")
        .ok()
        .filter(|u| !u.trim().is_empty())
        .unwrap_or_else(|| {
            let port = std::env::var("SITEPULSE_BIND_ADDR")
                .ok()
                .and_then(|a| a.rsplit(':').next().map(str::to_string))
                .unwrap_or_else(|| "8080".to_string());
            format!("http://localhost:{}", port)
        })
        .trim_end_matches('/')
        .to_string()
}

fn webhook_secret() -> &'static [u8] {
    static SECRET: OnceLock<Vec<u8>> = OnceLock::new();
    SECRET.get_or_init(|| match std::env::var("SITEPULSE_PAYMENT_WEBHOOK_SECRET") {
        Ok(s) if s.len() >= 16 => s.into_bytes(),
        _ => {
            // Without a configured secret only the in-process sandbox can sign.
            use rand::RngCore;
            let mut buf = vec![0u8; 32];
            rand::thread_rng().fill_bytes(&mut buf);
            buf
        }
    })
}

pub fn sign_provider_body(body: &[u8]) -> String {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(webhook_secret()).expect("HMAC accepts any key length");
    mac.update(body);
    hex::encode(mac.finalize().into_bytes())
}

pub fn verify_provider_signature(body: &[u8], signature: Option<&str>) -> bool {
    let Some(sig) = signature else { return false };
    let Ok(bytes) = hex::decode(sig.trim().trim_start_matches("sha256=")) else { return false };
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(webhook_secret()).expect("HMAC accepts any key length");
    mac.update(body);
    mac.verify_slice(&bytes).is_ok()
}

#[derive(Debug, Clone, PartialEq)]
pub enum CardPaymentError {
    NotFound(String),
    Invalid(String),
    Conflict(String),
    Unavailable(String),
}

impl std::fmt::Display for CardPaymentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CardPaymentError::NotFound(m)
            | CardPaymentError::Invalid(m)
            | CardPaymentError::Conflict(m)
            | CardPaymentError::Unavailable(m) => f.write_str(m),
        }
    }
}

pub struct CardPaymentService {
    state: AppState,
}

impl CardPaymentService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Opens a payment intent for a unit and returns it with the provider's hosted page.
    /// `caller_role` is the caller's own debtor role on the unit (OWNER/TENANT), or
    /// `None` for site staff, who may pick either.
    pub async fn create_intent(
        &self,
        unit_id: &str,
        req: CreatePaymentIntentRequest,
        caller_role: Option<&str>,
        actor: &str,
    ) -> Result<PaymentIntent, CardPaymentError> {
        let provider = configured_provider().map_err(CardPaymentError::Unavailable)?;
        if req.amount <= Decimal::ZERO || req.amount.scale() > 2 {
            return Err(CardPaymentError::Invalid("amount must be positive with at most 2 decimals".into()));
        }
        if req.amount > Decimal::from(1_000_000) {
            return Err(CardPaymentError::Invalid("amount exceeds the single card payment limit (₺1.000.000)".into()));
        }
        let requested = req.debtor_type.as_deref().map(|d| d.trim().to_uppercase());
        let debtor = match (caller_role, requested.as_deref()) {
            (Some(own), Some(asked)) if asked != own => {
                return Err(CardPaymentError::Invalid(format!("You can only pay your own ({}) debts", own)));
            }
            (Some(own), _) => own.to_string(),
            (None, Some(asked)) if asked == "OWNER" || asked == "TENANT" => asked.to_string(),
            (None, Some(asked)) => return Err(CardPaymentError::Invalid(format!("debtor_type must be OWNER or TENANT, got '{}'", asked))),
            (None, None) => "OWNER".to_string(),
        };
        let (unit, payer_name) = {
            let inner = self.state.inner.read().await;
            let unit = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, unit_id))
                .cloned()
                .ok_or_else(|| CardPaymentError::NotFound(format!("Unit {} not found", unit_id)))?;
            let holder = if debtor == "TENANT" { unit.tenant_user_id.clone() } else { unit.owner_user_id.clone() };
            if debtor == "TENANT" && holder.is_none() {
                return Err(CardPaymentError::Invalid("The unit has no tenant".into()));
            }
            let name = holder
                .and_then(|id| inner.users.iter().find(|u| u.id == id).map(|u| u.full_name.clone()))
                .unwrap_or_else(|| if debtor == "TENANT" { "Kiracı" } else { "Kat Maliki" }.to_string());
            (unit, name)
        };
        let now = Utc::now();
        let mut intent = PaymentIntent {
            id: String::new(),
            site_id: unit.site_id.clone(),
            unit_id: unit.id.clone(),
            debtor_type: debtor,
            payer_name: req.payer_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or(payer_name),
            amount: req.amount,
            currency: "TRY".to_string(),
            provider: provider.name().to_string(),
            provider_ref: String::new(),
            status: INTENT_CREATED.to_string(),
            checkout_url: None,
            three_ds_status: None,
            fee_amount: None,
            failure_reason: None,
            receipt_number: None,
            designation: req.designation.clone().filter(|d| !d.is_empty()),
            created_by: actor.to_string(),
            created_at: now,
            updated_at: now,
            captured_at: None,
        };
        let (reference, url) = provider.create_checkout(&intent).map_err(CardPaymentError::Unavailable)?;
        intent.provider_ref = reference;
        intent.checkout_url = Some(url);
        if let Some(ref pool) = self.state.pool {
            intent.id = crate::db::insert_payment_intent(pool, &intent)
                .await
                .map_err(|e| CardPaymentError::Unavailable(format!("Payment intent was not saved: {}", e)))?
                .to_string();
        } else {
            let inner = self.state.inner.read().await;
            intent.id = (inner.payment_intents.iter().filter_map(|i| i.id.parse::<i64>().ok()).max().unwrap_or(0) + 1).to_string();
        }
        self.state.inner.write().await.payment_intents.push(intent.clone());
        Ok(intent)
    }

    pub async fn get_intent(&self, unit_id: &str, intent_id: &str) -> Result<PaymentIntent, CardPaymentError> {
        let inner = self.state.inner.read().await;
        inner
            .payment_intents
            .iter()
            .find(|i| i.id == intent_id && crate::auth::same_id(&i.unit_id, unit_id))
            .cloned()
            .ok_or_else(|| CardPaymentError::NotFound(format!("Payment intent {} not found", intent_id)))
    }

    pub async fn intent_by_ref(&self, provider: &str, reference: &str) -> Option<PaymentIntent> {
        let inner = self.state.inner.read().await;
        inner.payment_intents.iter().find(|i| i.provider == provider && i.provider_ref == reference).cloned()
    }

    /// Applies a verified provider notification. A capture records the payment
    /// (once) and stores its receipt number on the intent.
    pub async fn apply_provider_event(&self, event: ProviderWebhookEvent) -> Result<PaymentIntent, CardPaymentError> {
        let mut intent = self
            .intent_by_ref(&event.provider, &event.provider_ref)
            .await
            .ok_or_else(|| CardPaymentError::NotFound(format!("Unknown payment reference {}", event.provider_ref)))?;
        let status = event.status.trim().to_uppercase();
        if event.amount != intent.amount {
            return Err(CardPaymentError::Conflict(format!(
                "Provider amount ₺{:.2} differs from the intent's ₺{:.2}",
                event.amount, intent.amount
            )));
        }
        match (intent.status.as_str(), status.as_str()) {
            // Repeated notifications are answered with the current state.
            (current, next) if current == next => return Ok(intent),
            (INTENT_CAPTURED | INTENT_REFUNDED, INTENT_AUTHORIZED | INTENT_FAILED) => return Ok(intent),
            (INTENT_CREATED, INTENT_AUTHORIZED) => {}
            (INTENT_CREATED | INTENT_AUTHORIZED, INTENT_CAPTURED | INTENT_FAILED) => {}
            (INTENT_CAPTURED, INTENT_REFUNDED) => {}
            (current, next) => {
                return Err(CardPaymentError::Conflict(format!("Payment intent {} cannot move from {} to {}", intent.id, current, next)));
            }
        }
        intent.three_ds_status = event.three_ds_status.clone().or(intent.three_ds_status.take());
        intent.fee_amount = event.fee_amount.or(intent.fee_amount);
        intent.updated_at = Utc::now();
        match status.as_str() {
            INTENT_CAPTURED => {
                let receipt = crate::services::PaymentTrackingService::new(self.state.clone())
                    .record_and_allocate_payment(RecordManualPaymentRequest {
                        site_id: Some(intent.site_id.clone()),
                        unit_id: intent.unit_id.clone(),
                        amount: intent.amount,
                        payer_name: intent.payer_name.clone(),
                        payer_role: intent.debtor_type.clone(),
                        payment_channel: "CREDIT_CARD".to_string(),
                        description: Some(format!("Kredi kartı ile ödeme ({})", intent.provider)),
                        payment_date: None,
                        idempotency_key: Some(format!("PSP:{}:{}", intent.provider, intent.provider_ref)),
                        designation: intent.designation.clone(),
                        external_reference: Some(intent.provider_ref.clone()),
                        designate_from_description: false,
                        settles_unmatched_entry_id: None,
                    })
                    .await
                    .map_err(|e| CardPaymentError::Conflict(format!("The captured payment could not be recorded: {}", e)))?;
                intent.receipt_number = Some(receipt.receipt_number);
                intent.captured_at = Some(Utc::now());
            }
            INTENT_FAILED => {
                intent.failure_reason = event.failure_reason.clone().or_else(|| Some("Declined by the provider".to_string()));
            }
            _ => {}
        }
        intent.status = status;
        self.save(&intent).await?;
        Ok(intent)
    }

    /// After a card payment's receipt is reversed: refund it at the provider and mark it REFUNDED.
    pub async fn refund_for_receipt(&self, site_id: &str, receipt_number: &str) -> Result<Option<PaymentIntent>, CardPaymentError> {
        let found = {
            let inner = self.state.inner.read().await;
            inner
                .payment_intents
                .iter()
                .find(|i| crate::auth::same_id(&i.site_id, site_id) && i.receipt_number.as_deref() == Some(receipt_number))
                .cloned()
        };
        let Some(mut intent) = found else { return Ok(None) };
        if intent.status == INTENT_REFUNDED {
            return Ok(Some(intent));
        }
        let provider = configured_provider().map_err(CardPaymentError::Unavailable)?;
        if provider.name() != intent.provider {
            return Err(CardPaymentError::Unavailable(format!("Provider {} is not configured; refund it there", intent.provider)));
        }
        provider.refund(&intent).map_err(CardPaymentError::Unavailable)?;
        intent.status = INTENT_REFUNDED.to_string();
        intent.updated_at = Utc::now();
        self.save(&intent).await?;
        Ok(Some(intent))
    }

    async fn save(&self, intent: &PaymentIntent) -> Result<(), CardPaymentError> {
        if let Some(ref pool) = self.state.pool {
            crate::db::update_payment_intent(pool, intent)
                .await
                .map_err(|e| CardPaymentError::Unavailable(format!("Payment intent was not saved: {}", e)))?;
        }
        let mut inner = self.state.inner.write().await;
        if let Some(slot) = inner.payment_intents.iter_mut().find(|i| i.id == intent.id) {
            *slot = intent.clone();
        }
        Ok(())
    }
}

/// The sandbox provider's hosted page: a simulated 3-D Secure step, no card fields.
pub fn sandbox_checkout_page(intent: &PaymentIntent) -> String {
    let esc = |s: &str| s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;");
    let done = intent.status != INTENT_CREATED && intent.status != INTENT_AUTHORIZED;
    let actions = if done {
        format!("<p class=\"state\">Bu ödeme tamamlandı: <b>{}</b>. Bu pencereyi kapatabilirsiniz.</p>", esc(&intent.status))
    } else {
        format!(
            r#"<form method="post" action="{base}/api/v1/payment-provider/sandbox/checkout/{r}/complete">
<button name="outcome" value="APPROVE" id="sandbox_approve">3-D Secure onayla ve öde</button>
<button name="outcome" value="DECLINE" id="sandbox_decline" class="secondary">Reddet</button>
</form>"#,
            base = public_base_url(),
            r = esc(&intent.provider_ref)
        )
    };
    format!(
        r#"<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sandbox ödeme sayfası</title>
<style>body{{font-family:system-ui,sans-serif;max-width:420px;margin:40px auto;padding:0 16px;color:#1f2933;background:#f7f7f5}}
.card{{background:#fff;border:1px solid #d9d9d4;border-radius:10px;padding:20px}}h1{{font-size:18px}}
.amount{{font-size:28px;font-weight:600;margin:12px 0}}.note{{font-size:13px;color:#5f6b76}}
button{{display:block;width:100%;padding:12px;margin-top:10px;border-radius:8px;border:0;background:#1f6f5c;color:#fff;font-size:15px;cursor:pointer}}
button.secondary{{background:#e4e4df;color:#1f2933}}.state{{font-size:15px}}</style></head>
<body><div class="card"><h1>Sandbox ödeme sağlayıcısı</h1>
<p class="note">Bu sayfa lisanslı ödeme kuruluşunun barındırdığı ödeme sayfasını taklit eder. Gerçek kart bilgisi istenmez; SitePulse kart verisi görmez.</p>
<div class="amount">₺{amount}</div><p>{payer} · Referans {r}</p>{actions}</div></body></html>"#,
        amount = crate::services::receipt_document::format_try(intent.amount),
        payer = esc(&intent.payer_name),
        r = esc(&intent.provider_ref),
        actions = actions
    )
}
