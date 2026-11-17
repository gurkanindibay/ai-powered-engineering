//! Accrual corrections: cancel, re-issue and credit note (STORY-07-11).
//!
//! * A manager requests a correction with a reason; a second person approves it
//!   (four-eyes), like the waivers and write-offs of `plan_service`.
//! * The original liability is never deleted or overwritten. A cancel (and the
//!   cancel half of a re-issue) sets it to `CANCELLED` and keeps its amounts; a
//!   credit note lowers what it owes and reverses the late fee in proportion.
//! * What the debtor had already paid on the cancelled or reduced amount moves to
//!   their advance balance and is then offset against their other open
//!   liabilities. Receipts are never touched.
//! * The general ledger posts the reversing entries from the approved records
//!   (`accounting_service`), and the resident statement lists them.

use chrono::Utc;
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::correction_repository::{apply_accrual_correction, CorrectionWrite};
use crate::db::finance_store::FinanceStore;
use crate::finance_book::col;
use crate::models::*;
use crate::services::advance_offset_service::{settle_advances, OffsetScope};
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::AppState;

/// What approving a correction does to one liability.
#[derive(Debug, Clone, PartialEq)]
pub struct CorrectionPlan {
    pub cancel: bool,
    pub principal: Decimal,
    pub penalty: Decimal,
    pub paid_principal: Decimal,
    pub paid_penalty: Decimal,
    /// Late fee taken off the liability.
    pub penalty_reversed: Decimal,
    /// Paid amount that moves to the debtor's advance balance.
    pub advance_credit: Decimal,
}

fn round2(value: Decimal) -> Decimal {
    value.round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
}

/// Computes the effect of a correction on `due` (pure, so it can be tested alone).
///
/// * Cancel and re-issue: the liability keeps its amounts, is marked cancelled,
///   its whole late fee is reversed and everything it had received moves to the
///   advance balance.
/// * Credit note of `amount`: the principal drops by `amount`, the late fee is
///   scaled to the new principal (rounded half away from zero), and whatever was
///   paid beyond the new amounts moves to the advance balance.
pub fn plan_correction(
    due: &DuesLiability,
    kind: &str,
    amount: Decimal,
) -> FinanceResult<CorrectionPlan> {
    if due.status == DebtStatus::Cancelled {
        return Err(conflict("The liability is already cancelled"));
    }
    if kind != CORRECTION_CREDIT_NOTE {
        return Ok(CorrectionPlan {
            cancel: true,
            principal: due.principal_amount,
            penalty: due.delay_penalty,
            paid_principal: due.paid_principal,
            paid_penalty: due.paid_penalty,
            penalty_reversed: due.delay_penalty,
            advance_credit: due.paid_principal + due.paid_penalty,
        });
    }
    if amount >= due.principal_amount {
        return Err(conflict(format!(
            "A credit note must be below the principal of ₺{:.2}; cancel the liability instead",
            due.principal_amount
        )));
    }
    let principal = due.principal_amount - amount;
    let penalty = round2(due.delay_penalty * principal / due.principal_amount);
    let paid_principal = due.paid_principal.min(principal);
    let paid_penalty = due.paid_penalty.min(penalty);
    Ok(CorrectionPlan {
        cancel: false,
        principal,
        penalty,
        paid_principal,
        paid_penalty,
        penalty_reversed: due.delay_penalty - penalty,
        advance_credit: (due.paid_principal - paid_principal) + (due.paid_penalty - paid_penalty),
    })
}

/// Applies a plan to the in-memory liability.
fn apply_plan(due: &mut DuesLiability, plan: &CorrectionPlan, today: chrono::NaiveDate) {
    if plan.cancel {
        due.status = DebtStatus::Cancelled;
    } else {
        due.principal_amount = plan.principal;
        due.delay_penalty = plan.penalty;
        due.paid_principal = plan.paid_principal;
        due.paid_penalty = plan.paid_penalty;
        due.total_amount = dues_ledger::outstanding(due);
        due.status = if due.total_amount <= Decimal::ZERO {
            DebtStatus::Paid
        } else if due.due_date < today {
            DebtStatus::Overdue
        } else {
            DebtStatus::Pending
        };
    }
    dues_ledger::refresh(due);
}

pub struct CorrectionService {
    state: AppState,
    store: FinanceStore,
}

impl CorrectionService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    /// Every correction of the site, newest last: the audit list.
    pub async fn list(&self, site_id: &str) -> Vec<AccrualCorrection> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .corrections
                    .iter()
                    .filter(|c| crate::auth::same_id(&c.site_id, site_id))
                    .cloned()
                    .collect()
            })
            .await
    }

    pub async fn request(
        &self,
        caller: &Caller,
        req: RequestCorrectionRequest,
    ) -> FinanceResult<AccrualCorrection> {
        let reason = non_empty(&req.reason, 5, "reason")?;
        let kind = match req.kind.trim().to_ascii_uppercase().as_str() {
            CORRECTION_CANCEL => CORRECTION_CANCEL,
            CORRECTION_REISSUE => CORRECTION_REISSUE,
            CORRECTION_CREDIT_NOTE => CORRECTION_CREDIT_NOTE,
            other => return Err(invalid(format!("Unknown correction kind '{}'", other))),
        };
        let (due, pending_exists) = self
            .store
            .read(|inner| {
                let due = find_due(inner, &caller.site_id, &req.due_id).cloned();
                let pending = due.as_ref().is_ok_and(|d| {
                    inner.finance.corrections.iter().any(|c| {
                        c.status == REQUEST_PENDING && crate::auth::same_id(&c.due_id, &d.id)
                    })
                });
                (due, pending)
            })
            .await;
        let due = due?;
        if due.status == DebtStatus::Cancelled {
            return Err(conflict("The liability is already cancelled"));
        }
        if pending_exists {
            return Err(conflict(
                "A correction of this liability is already waiting for approval",
            ));
        }
        let (amount, new_due_date, new_debtor_type) = match kind {
            CORRECTION_CANCEL => (due.principal_amount, None, None),
            CORRECTION_CREDIT_NOTE => {
                let amount = money(
                    req.amount
                        .ok_or_else(|| invalid("amount is required for a credit note"))?,
                    "amount",
                )?;
                plan_correction(&due, kind, amount)?;
                (amount, None, None)
            }
            _ => {
                let amount = money(
                    req.amount
                        .ok_or_else(|| invalid("amount is required for a re-issue"))?,
                    "amount",
                )?;
                if due.expense_type != ExpenseType::OperationalDues {
                    return Err(conflict(
                        "Only an operational dues liability can be re-issued; cancel the capital liability instead",
                    ));
                }
                let debtor = req
                    .debtor_type
                    .as_deref()
                    .map(|d| parse_debtor(Some(d)))
                    .transpose()?
                    .map(str::to_string);
                (amount, req.due_date, debtor)
            }
        };
        let correction = AccrualCorrection {
            id: 0,
            site_id: caller.site_id.clone(),
            unit_id: due.unit_id.clone(),
            due_id: due.id.clone(),
            period: due.period.clone(),
            debtor_type: due.debtor_type.as_str().to_string(),
            kind: kind.to_string(),
            amount,
            new_due_date,
            new_debtor_type,
            reason,
            requested_by: caller.actor(),
            requested_at: Utc::now(),
            status: REQUEST_PENDING.to_string(),
            decided_by: None,
            decided_at: None,
            decision_note: None,
            principal_before: None,
            penalty_before: None,
            paid_before: None,
            penalty_reversed: None,
            advance_credited: None,
            replacement_due_id: None,
        };
        Ok(self.store.insert(correction, col::corrections).await?)
    }

    /// Approves (applying the correction) or rejects a pending correction.
    pub async fn decide(
        &self,
        caller: &Caller,
        correction_id: i64,
        decision: DecideRequest,
    ) -> FinanceResult<AccrualCorrection> {
        let mut correction = self
            .store
            .read(|inner| {
                inner
                    .finance
                    .corrections
                    .iter()
                    .find(|c| {
                        c.id == correction_id && crate::auth::same_id(&c.site_id, &caller.site_id)
                    })
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Correction {} not found", correction_id)))?;
        if correction.status != REQUEST_PENDING {
            return Err(conflict(format!(
                "Correction {} is already {}",
                correction.id, correction.status
            )));
        }
        if same_actor(&correction.requested_by, &caller.actor()) {
            return Err(FinanceError::Forbidden(
                "The approver must be a different person from the requester (four-eyes)".into(),
            ));
        }
        let mut offset_unit = None;
        if decision.approve {
            self.apply(&mut correction).await?;
            correction.status = REQUEST_APPROVED.to_string();
            offset_unit = Some(correction.unit_id.clone());
        } else {
            correction.status = REQUEST_REJECTED.to_string();
        }
        correction.decided_by = Some(caller.actor());
        correction.decided_at = Some(Utc::now());
        correction.decision_note = opt_text(&decision.note);
        let saved = self.store.update(correction, col::corrections).await?;
        if let Some(unit_id) = offset_unit {
            self.offset_advance(&saved.site_id, &unit_id).await;
        }
        Ok(saved)
    }

    /// Offsets the advance the correction created against the debtor's other
    /// open liabilities (STORY-07-05). The correction stands even if this fails.
    async fn offset_advance(&self, site_id: &str, unit_id: &str) {
        if let Err(error) =
            settle_advances(&self.state, OffsetScope::Unit { site_id, unit_id }).await
        {
            tracing::warn!(site_id, unit_id, %error, "advance offset after a correction failed");
        }
    }

    async fn apply(&self, correction: &mut AccrualCorrection) -> FinanceResult<()> {
        let due = self
            .store
            .read(|inner| find_due(inner, &correction.site_id, &correction.due_id).cloned())
            .await?;
        let plan = plan_correction(&due, &correction.kind, correction.amount)?;
        let replacement = (correction.kind == CORRECTION_REISSUE).then(|| {
            let debtor = correction
                .new_debtor_type
                .as_deref()
                .map(DebtorType::from_str_loose)
                .unwrap_or(due.debtor_type);
            let mut next = due.clone();
            next.principal_amount = correction.amount;
            next.total_amount = correction.amount;
            next.delay_penalty = Decimal::ZERO;
            next.paid_principal = Decimal::ZERO;
            next.paid_penalty = Decimal::ZERO;
            next.status = DebtStatus::Pending;
            next.due_date = correction.new_due_date.unwrap_or(due.due_date);
            next.debtor_type = debtor;
            next.penalty_accrued_through = None;
            next
        });
        let reference = format!("KOR-{}", correction.id);
        let description = format!(
            "Accrual correction {}: {}",
            correction.id, correction.reason
        );
        let mut replacement_id = None;
        let mut replacement = replacement;
        if let Some(pool) = self.state.db_pool() {
            let write = CorrectionWrite {
                site_id: &correction.site_id,
                due_id: &due.id,
                unit_id: &due.unit_id,
                debtor_type: due.debtor_type.as_str(),
                cancel: plan.cancel,
                principal: plan.principal,
                penalty: plan.penalty,
                paid_principal: plan.paid_principal,
                paid_penalty: plan.paid_penalty,
                advance_credit: plan.advance_credit,
                reference: &reference,
                description: &description,
                replacement: replacement.as_ref(),
            };
            replacement_id = apply_accrual_correction(pool, &write)
                .await?
                .map(|id| id.to_string());
        } else if replacement.is_some() {
            replacement_id = Some(format!("due-{}", uuid::Uuid::new_v4().simple()));
        }
        let mut inner = self.state.inner.write().await;
        let today = site_today(&inner, &correction.site_id);
        if let Some(stored) = inner.dues.iter_mut().find(|d| d.id == due.id) {
            apply_plan(stored, &plan, today);
        }
        if plan.advance_credit > Decimal::ZERO {
            inner.adjust_advance(&due.unit_id, due.debtor_type.as_str(), plan.advance_credit);
        }
        if let (Some(next), Some(id)) = (replacement.as_mut(), replacement_id.clone()) {
            next.id = id;
            inner.dues.push(next.clone());
        }
        correction.principal_before = Some(due.principal_amount);
        correction.penalty_before = Some(due.delay_penalty);
        correction.paid_before = Some(due.paid_principal + due.paid_penalty);
        correction.penalty_reversed = Some(plan.penalty_reversed);
        correction.advance_credited = Some(plan.advance_credit);
        correction.replacement_due_id = replacement_id;
        Ok(())
    }
}
