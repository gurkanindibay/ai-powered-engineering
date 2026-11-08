//! Multi-bank feeds, payer matching and the daily ledger-vs-bank
//! reconciliation, SPEC-009 R9.
//!
//! * Transfers that bypass the unit's virtual IBAN are matched by what the payer
//!   wrote (`domain::payer_match`): a T.C. Kimlik No (compared as a digest),
//!   a mobile number, a block/unit reference, or a known payer name.
//! * A feed connection keeps a *reference* to the credential (a secret name in
//!   the deployment's vault), never the secret. Real corporate bank APIs are
//!   [`BankFeed`] implementations; the sandbox returns no new lines.
//! * The daily run compares the bank's movement with the ledger's bank movement
//!   for one business day and stores the difference and unmatched lines.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::payer_match;
use crate::domain::text::fold_turkish;
use crate::domain::TrIban;
use crate::finance_book::col;
use crate::models::*;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::{AppState, AppStateInner};

pub const FEED_PROVIDERS: [&str; 3] = ["SANDBOX", "STATEMENT_FILE", "KUVEYT_TURK"];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{0}")]
pub struct FeedError(pub String);

/// A source of bank account movements.
pub trait BankFeed: Send + Sync {
    fn fetch(&self, connection: &BankFeedConnection) -> Result<Vec<BankLine>, FeedError>;
}

/// No live connection: nothing new to fetch.
pub struct SandboxFeed;

impl BankFeed for SandboxFeed {
    fn fetch(&self, _connection: &BankFeedConnection) -> Result<Vec<BankLine>, FeedError> {
        Ok(Vec::new())
    }
}

/// Statement files are uploaded through `/bank/statements/parse`; the feed itself fetches nothing.
pub struct StatementFileFeed;

impl BankFeed for StatementFileFeed {
    fn fetch(&self, _connection: &BankFeedConnection) -> Result<Vec<BankLine>, FeedError> {
        Ok(Vec::new())
    }
}

pub fn feed_for(provider: &str) -> Result<Box<dyn BankFeed>, FeedError> {
    match provider {
        "SANDBOX" if !crate::state::AppStateInner::is_production() => Ok(Box::new(SandboxFeed)),
        "STATEMENT_FILE" => Ok(Box::new(StatementFileFeed)),
        other => Err(FeedError(format!(
            "The {} corporate feed is configured through its own integration (see /bank/kuveyt-turk)",
            other
        ))),
    }
}

fn add_candidate(
    list: &mut Vec<(String, u32, Vec<String>)>,
    unit: &str,
    score: u32,
    reason: String,
) {
    match list.iter_mut().find(|c| c.0 == unit) {
        Some(c) => {
            c.1 = c.1.max(score).saturating_add(5).min(99);
            c.2.push(reason);
        }
        None => list.push((unit.to_string(), score, vec![reason])),
    }
}

fn open_amount(inner: &AppStateInner, unit_id: &str) -> Decimal {
    inner
        .dues
        .iter()
        .filter(|d| crate::auth::same_id(&d.unit_id, unit_id) && is_open(d))
        .map(dues_ledger::outstanding)
        .sum()
}

/// The ledger's bank movement on one day, as individual items (amount, reference).
fn ledger_bank_items(
    inner: &AppStateInner,
    site_id: &str,
    day: NaiveDate,
) -> Vec<(Decimal, String)> {
    let mut items = Vec::new();
    for r in inner.payment_receipts.iter().filter(|r| {
        crate::auth::same_id(&r.site_id, site_id)
            && r.issued_at.date_naive() == day
            && !matches!(
                r.payment_channel,
                PaymentChannel::Cash | PaymentChannel::ManualCash | PaymentChannel::InterLedger
            )
    }) {
        let sign = if r.receipt_type == LEDGER_KIND_REVERSAL {
            Decimal::NEGATIVE_ONE
        } else {
            Decimal::ONE
        };
        items.push((sign * r.total_amount, r.receipt_number.clone()));
    }
    for p in inner.finance.expense_payments.iter().filter(|p| {
        crate::auth::same_id(&p.site_id, site_id) && p.paid_on == day && p.method == "BANK_TRANSFER"
    }) {
        items.push((-p.amount, format!("ODEME-{}", p.id)));
    }
    let projects: Vec<&str> = inner
        .capital_projects
        .iter()
        .filter(|p| crate::auth::same_id(&p.site_id, site_id))
        .map(|p| p.id.as_str())
        .collect();
    for d in inner
        .capital_disbursements
        .iter()
        .filter(|d| projects.contains(&d.project_id.as_str()) && d.disbursement_date == day)
    {
        items.push((-d.amount, d.id.clone()));
    }
    for e in inner
        .finance
        .journal_entries
        .iter()
        .filter(|e| crate::auth::same_id(&e.site_id, site_id) && e.entry_date == day)
    {
        let net: Decimal = inner
            .finance
            .journal_lines
            .iter()
            .filter(|l| l.entry_id == e.id && l.account_code == crate::domain::double_entry::BANK)
            .map(|l| l.debit - l.credit)
            .sum();
        if !net.is_zero() {
            items.push((net, format!("YEV-{}", e.id)));
        }
    }
    items
}

pub struct BankMatchingService {
    store: FinanceStore,
}

impl BankMatchingService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    /// Ranks candidate units for each transfer.
    pub async fn suggest(
        &self,
        site_id: &str,
        req: MatchRequest,
    ) -> FinanceResult<Vec<MatchSuggestion>> {
        let mut out = Vec::with_capacity(req.transfers.len());
        for t in req.transfers {
            let hints = payer_match::extract(&t.description);
            let mut candidates: Vec<(String, u32, Vec<String>)> = Vec::new();
            if let Some(ref tckn) = hints.national_id {
                for unit in self.store.units_by_national_id(site_id, tckn).await? {
                    add_candidate(&mut candidates, &unit, 95, "T.C. Kimlik No".into());
                }
            }
            let rows =
                self.store
                    .read(|inner| {
                        let mut local: Vec<(String, u32, Vec<String>)> = Vec::new();
                        for unit in site_units(inner, site_id) {
                            for debtor in [dues_ledger::DEBTOR_OWNER, dues_ledger::DEBTOR_TENANT] {
                                let Some(user) = debtor_user(inner, unit, debtor) else {
                                    continue;
                                };
                                if let (Some(m), Some(phone)) = (
                                    hints.mobile.as_deref(),
                                    payer_match::normalize_mobile(&user.phone),
                                ) {
                                    if m == phone {
                                        add_candidate(
                                            &mut local,
                                            &unit.id,
                                            85,
                                            format!("telefon ({})", debtor),
                                        );
                                    }
                                }
                                if let Some(ref sender) = t.sender_name {
                                    if !sender.trim().is_empty()
                                        && fold_turkish(sender.trim())
                                            == fold_turkish(user.full_name.trim())
                                    {
                                        add_candidate(
                                            &mut local,
                                            &unit.id,
                                            50,
                                            format!("gönderen adı ({})", debtor),
                                        );
                                    }
                                }
                            }
                            if let Some((ref block, number)) = hints.block_unit {
                                let label = fold_turkish(&inner.block_label(&unit.block_id));
                                let letter = label
                                    .chars()
                                    .next()
                                    .map(|c| c.to_ascii_uppercase().to_string());
                                if unit.unit_number == number
                                    && letter.as_deref() == Some(block.as_str())
                                {
                                    add_candidate(&mut local, &unit.id, 60, "blok/daire".into());
                                }
                            }
                            if let Some(names) = inner.unit_payer_names.get(&unit.id) {
                                if let Some(ref sender) = t.sender_name {
                                    if names.iter().any(|n| {
                                        fold_turkish(n.trim()) == fold_turkish(sender.trim())
                                    }) {
                                        add_candidate(
                                            &mut local,
                                            &unit.id,
                                            55,
                                            "kayıtlı ödeyen adı".into(),
                                        );
                                    }
                                }
                            }
                        }
                        for (unit, score, reasons) in candidates.drain(..) {
                            for r in reasons {
                                add_candidate(&mut local, &unit, score, r);
                            }
                        }
                        local
                            .into_iter()
                            .map(|(unit, mut score, reasons)| {
                                let open = open_amount(inner, &unit);
                                if open == t.amount && open > Decimal::ZERO {
                                    score = (score + 10).min(99);
                                }
                                MatchCandidate {
                                    unit_label: label_of(inner, &unit),
                                    unit_id: unit,
                                    confidence: score,
                                    reasons,
                                    open_amount: open,
                                }
                            })
                            .collect::<Vec<_>>()
                    })
                    .await;
            let mut rows = rows;
            rows.sort_by(|a, b| {
                b.confidence
                    .cmp(&a.confidence)
                    .then(a.unit_label.cmp(&b.unit_label))
            });
            out.push(MatchSuggestion {
                reference: t.reference,
                amount: t.amount,
                description: t.description,
                candidates: rows,
            });
        }
        Ok(out)
    }

    pub async fn feeds(&self, site_id: &str) -> Vec<BankFeedConnection> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .bank_feeds
                    .iter()
                    .filter(|f| crate::auth::same_id(&f.site_id, site_id))
                    .cloned()
                    .collect()
            })
            .await
    }

    pub async fn create_feed(
        &self,
        caller: &Caller,
        req: CreateBankFeedRequest,
    ) -> FinanceResult<BankFeedConnection> {
        let provider = req.provider.trim().to_ascii_uppercase();
        if !FEED_PROVIDERS.contains(&provider.as_str()) {
            return Err(invalid(format!(
                "provider must be one of {:?}",
                FEED_PROVIDERS
            )));
        }
        let iban = TrIban::parse(&req.account_iban).map_err(|e| invalid(e.to_string()))?;
        if let Some(ref c) = req.credential_ref {
            // A reference is a vault key such as `vault:sitepulse/site-1/bank`, never a password.
            if c.len() > 200 || c.contains(char::is_whitespace) {
                return Err(invalid(
                    "credential_ref is a secret reference, not the secret itself",
                ));
            }
        }
        let exists = self
            .store
            .read(|inner| {
                inner.finance.bank_feeds.iter().any(|f| {
                    crate::auth::same_id(&f.site_id, &caller.site_id)
                        && f.account_iban == iban.as_str()
                })
            })
            .await;
        if exists {
            return Err(conflict("This account already has a feed"));
        }
        let feed = BankFeedConnection {
            id: 0,
            site_id: caller.site_id.clone(),
            provider,
            account_iban: iban.into_string(),
            credential_ref: opt_text(&req.credential_ref),
            status: "ACTIVE".into(),
            last_synced_at: None,
            last_error: None,
            created_at: Utc::now(),
        };
        Ok(self.store.insert(feed, col::bank_feeds).await?)
    }

    /// Fetches new lines from a feed (lines feed the reconciliation queue through
    /// the statement parser path in a later step) and records the sync outcome.
    pub async fn sync_feed(
        &self,
        caller: &Caller,
        feed_id: i64,
    ) -> FinanceResult<(BankFeedConnection, usize)> {
        let mut feed = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .bank_feeds
                    .iter()
                    .find(|f| f.id == feed_id && crate::auth::same_id(&f.site_id, &caller.site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Bank feed {} not found", feed_id)))?;
        let result = feed_for(&feed.provider).and_then(|f| f.fetch(&feed));
        let fetched = match result {
            Ok(lines) => {
                feed.status = "ACTIVE".into();
                feed.last_error = None;
                feed.last_synced_at = Some(Utc::now());
                lines.len()
            }
            Err(e) => {
                feed.status = "ERROR".into();
                feed.last_error = Some(e.0);
                0
            }
        };
        let feed = self.store.update(feed, col::bank_feeds).await?;
        Ok((feed, fetched))
    }

    /// Compares one business day of bank lines with the ledger's bank movement.
    pub async fn daily_reconciliation(
        &self,
        caller: &Caller,
        req: DailyReconciliationRequest,
    ) -> FinanceResult<BankReconciliationRun> {
        for (i, l) in req.lines.iter().enumerate() {
            if l.amount.is_zero() || l.amount.scale() > 2 {
                return Err(invalid(format!(
                    "line {}: amount must be non-zero with at most 2 decimals",
                    i
                )));
            }
        }
        let ledger = self
            .store
            .read(|inner| ledger_bank_items(inner, &caller.site_id, req.business_date))
            .await;
        let bank_movement: Decimal = req.lines.iter().map(|l| l.amount).sum();
        let ledger_movement: Decimal = ledger.iter().map(|l| l.0).sum();
        // Greedy one-to-one match on amount (and reference when both have one).
        let mut unmatched_ledger = ledger.clone();
        let mut unmatched_bank = Vec::new();
        for line in &req.lines {
            let pos = unmatched_ledger
                .iter()
                .position(|(a, r)| {
                    *a == line.amount && line.reference.as_deref().is_none_or(|x| x == r)
                })
                .or_else(|| unmatched_ledger.iter().position(|(a, _)| *a == line.amount));
            match pos {
                Some(p) => {
                    unmatched_ledger.remove(p);
                }
                None => unmatched_bank.push(serde_json::json!({
                    "amount": line.amount.to_string(),
                    "reference": line.reference,
                    "description": line.description,
                })),
            }
        }
        let details = serde_json::json!({
            "unmatched_bank_lines": unmatched_bank,
            "unmatched_ledger_items": unmatched_ledger
                .iter()
                .map(|(a, r)| serde_json::json!({"amount": a.to_string(), "reference": r}))
                .collect::<Vec<_>>(),
            "matched": req.lines.len() - unmatched_bank.len(),
        });
        let run = BankReconciliationRun {
            id: 0,
            site_id: caller.site_id.clone(),
            business_date: req.business_date,
            bank_movement,
            ledger_movement,
            difference: bank_movement - ledger_movement,
            bank_closing_balance: req.bank_closing_balance,
            details,
            run_by: caller.actor(),
            created_at: Utc::now(),
        };
        Ok(self.store.insert(run, col::bank_reconciliations).await?)
    }

    pub async fn reconciliation_runs(&self, site_id: &str) -> Vec<BankReconciliationRun> {
        self.store
            .read(|inner| {
                let mut rows: Vec<_> = inner
                    .finance
                    .bank_reconciliations
                    .iter()
                    .filter(|r| crate::auth::same_id(&r.site_id, site_id))
                    .cloned()
                    .collect();
                rows.sort_by_key(|a| std::cmp::Reverse(a.business_date));
                rows
            })
            .await
    }
}
