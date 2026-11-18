//! Daily KMK 20 late-fee accrual and its reconciliation, STORY-07-13.
//!
//! The dashboard, the resident statement and the debt aging report evaluate the
//! late fee up to today; the ledger books what is stored. The daily job (run in
//! each site's time zone) persists the fee of every open overdue liability, one
//! `LateFeeAccrual` row per liability and day, so the stored fee and the ledger
//! catch up with the evaluation and the ledger books each day's fee on that day.
//!
//! Rounding: within a segment of unchanged outstanding principal the fee is
//! `segment_base + round(principal * 5% * days_since_segment_start / 30)`, rounded
//! once for the whole segment, and a day's amount is the difference from the
//! previous day's total. Rounding every day separately would drift
//! (₺2.33 × 16 days = ₺37.28, not ₺37.33).

use chrono::NaiveDate;
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::finance_records as rec;
use crate::db::finance_store::FinanceStore;
use crate::models::*;
use crate::services::dues_calculation_service::DuesCalculationService;
use crate::services::dues_ledger;
use crate::services::finance_common::*;
use crate::state::AppState;

/// The fee of one segment: `principal * 5% * days / 30`, rounded once.
pub fn segment_fee(principal: Decimal, days: i64) -> Decimal {
    if days <= 0 || principal <= Decimal::ZERO {
        return Decimal::ZERO;
    }
    (principal * Decimal::new(5, 2) * Decimal::from(days) / Decimal::from(30))
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
}

/// The days still to accrue for one liability, as `LateFeeAccrual` rows without
/// ids, and the liability as it is after them. `None` when nothing is due.
pub fn plan_accruals(
    site_id: &str,
    due: &DuesLiability,
    last: Option<&LateFeeAccrual>,
    today: NaiveDate,
) -> Option<(Vec<LateFeeAccrual>, DuesLiability)> {
    if matches!(due.status, DebtStatus::Paid | DebtStatus::Cancelled) {
        return None;
    }
    let principal = dues_ledger::outstanding_principal(due);
    if principal <= Decimal::ZERO
        || today <= due.due_date
        || (due.penalty_accrued_through.is_none()
            && last.is_none()
            && DuesCalculationService::in_grace(due, today))
    {
        return None;
    }
    let paid_floor = due.delay_penalty.max(due.paid_penalty);
    // Continue the logged segment only while nothing else touched the liability.
    let continuing = last.filter(|l| {
        l.outstanding_principal == principal
            && due.penalty_accrued_through == Some(l.accrual_date)
            && due.delay_penalty == l.cumulative_fee
    });
    let (segment_start, segment_base, legacy_floor, mut previous, mut day) = match continuing {
        Some(l) => (
            l.segment_start,
            l.segment_base,
            Decimal::ZERO,
            l.cumulative_fee,
            l.accrual_date,
        ),
        None => {
            let start = due
                .penalty_accrued_through
                .map_or(due.due_date, |t| t.max(due.due_date));
            // A liability without an accrual date has a stored fee that covers part
            // of its first segment: the segment never ends below it.
            let (base, floor) = match due.penalty_accrued_through {
                Some(_) => (paid_floor, Decimal::ZERO),
                None => (Decimal::ZERO, paid_floor),
            };
            (start, base, floor, paid_floor, start)
        }
    };
    let mut rows = Vec::new();
    while day < today {
        day = day.succ_opt()?;
        let fee = (segment_base + segment_fee(principal, (day - segment_start).num_days()))
            .max(legacy_floor)
            .max(previous);
        rows.push(LateFeeAccrual {
            id: 0,
            site_id: site_id.to_string(),
            due_id: due.id.clone(),
            accrual_date: day,
            outstanding_principal: principal,
            segment_start,
            segment_base,
            cumulative_fee: fee,
            daily_amount: fee - previous,
        });
        previous = fee;
    }
    let last_row = rows.last()?;
    let mut updated = due.clone();
    updated.delay_penalty = last_row.cumulative_fee;
    updated.penalty_accrued_through = Some(last_row.accrual_date);
    updated.status = DebtStatus::Overdue;
    dues_ledger::refresh(&mut updated);
    Some((rows, updated))
}

/// The day rows of a liability from the day after `after` up to `through`, as they
/// stand once its principal payments (`(date, principal)`, the backdated payment
/// included) are known (#187). A day's fee uses the principal outstanding after the
/// payments dated before that day, so each row stays on the segment formula the daily
/// job continues from. Days with nothing outstanding have no row.
pub fn rewritten_accruals(
    site_id: &str,
    due: &DuesLiability,
    payments: &[(NaiveDate, Decimal)],
    after: NaiveDate,
    through: NaiveDate,
) -> Vec<LateFeeAccrual> {
    let calc = DuesCalculationService::new();
    // A payment inside the grace period counts as made on the due date.
    let grace_end = due.due_date + chrono::Days::new(u64::from(due.grace_days));
    let payments: Vec<(NaiveDate, Decimal)> = payments
        .iter()
        .map(|(d, a)| {
            if due.grace_days > 0 && *d <= grace_end {
                (due.due_date, *a)
            } else {
                (*d, *a)
            }
        })
        .collect();
    let payments = payments.as_slice();
    let cumulative = |day: NaiveDate| {
        calc.penalty_through_with_grace(
            due.principal_amount,
            due.due_date,
            day,
            payments,
            due.grace_days,
        )
    };
    let mut previous = cumulative(after.max(due.due_date));
    let mut rows = Vec::new();
    let mut day = after;
    while day < through {
        let Some(next) = day.succ_opt() else { break };
        day = next;
        if day <= due.due_date {
            continue;
        }
        let before: Vec<&(NaiveDate, Decimal)> =
            payments.iter().filter(|(d, _)| *d < day).collect();
        let outstanding =
            due.principal_amount - before.iter().map(|(_, amount)| *amount).sum::<Decimal>();
        if outstanding <= Decimal::ZERO {
            continue;
        }
        let segment_start = before
            .iter()
            .map(|(d, _)| *d)
            .max()
            .map_or(due.due_date, |d| d.max(due.due_date));
        let fee = cumulative(day);
        rows.push(LateFeeAccrual {
            id: 0,
            site_id: site_id.to_string(),
            due_id: due.id.clone(),
            accrual_date: day,
            outstanding_principal: outstanding,
            segment_start,
            segment_base: cumulative(segment_start),
            cumulative_fee: fee,
            daily_amount: fee - previous,
        });
        previous = fee;
    }
    rows
}

pub struct LateFeeService {
    store: FinanceStore,
    state: AppState,
}

impl LateFeeService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
            state: state.clone(),
        }
    }

    /// Daily job: brings the late fee of every open overdue liability of the site
    /// up to its local today. Idempotent: a second run on the same day changes
    /// nothing. Returns the number of liabilities updated.
    pub async fn run_site(&self, site_id: &str) -> usize {
        let work: Vec<(DuesLiability, Vec<LateFeeAccrual>)> = self
            .store
            .read(|inner| {
                let today = site_today(inner, site_id);
                site_dues(inner, site_id)
                    .filter_map(|d| {
                        let last = inner
                            .finance
                            .late_fee_accruals
                            .iter()
                            .filter(|a| a.due_id == d.id)
                            .max_by_key(|a| a.accrual_date);
                        plan_accruals(site_id, d, last, today)
                            .map(|(rows, updated)| (updated, rows))
                    })
                    .collect()
            })
            .await;
        let mut updated = 0;
        for (due, rows) in work {
            match self.apply(due, rows).await {
                Ok(true) => updated += 1,
                Ok(false) => {}
                Err(e) => tracing::error!("[LateFee] site {}: {}", site_id, e),
            }
        }
        updated
    }

    /// Runs every site (the scheduler's daily job).
    pub async fn run_all(&self) -> usize {
        let sites: Vec<String> = self
            .store
            .read(|inner| inner.sites.iter().map(|s| s.id.clone()).collect())
            .await;
        let mut updated = 0;
        for site in sites {
            updated += self.run_site(&site).await;
        }
        updated
    }

    /// Writes the liability and its day rows together; skips a liability that a
    /// payment changed since the plan was made (the next run plans it again).
    async fn apply(
        &self,
        due: DuesLiability,
        mut rows: Vec<LateFeeAccrual>,
    ) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        let before = self
            .state
            .inner
            .read()
            .await
            .dues
            .iter()
            .find(|d| d.id == due.id)
            .cloned();
        let Some(before) = before else {
            return Ok(false);
        };
        let pool = self.state.db_pool();
        if let Some(pool) = pool {
            let due_id = crate::db::require_id("dues liability", &due.id)?;
            let mut client = pool.get().await?;
            let tx = client.transaction().await?;
            let site = crate::db::require_id("site", &rows[0].site_id)?;
            crate::db::tx_bind_tenant(&tx, site).await?;
            let changed = tx
                .execute(
                    "UPDATE dues_liabilities
                     SET delay_penalty = $2, penalty_accrued_through = $3, status = $4, version = version + 1
                     WHERE id = $1 AND paid_principal = $5 AND delay_penalty = $6",
                    &[
                        &due_id,
                        &due.delay_penalty,
                        &due.penalty_accrued_through,
                        &"OVERDUE",
                        &before.paid_principal,
                        &before.delay_penalty,
                    ],
                )
                .await?;
            if changed != 1 {
                return Ok(false);
            }
            for row in rows.iter_mut() {
                row.id = rec::insert(&*tx, row).await?;
            }
            tx.commit().await?;
        }
        let mut inner = self.state.inner.write().await;
        if pool.is_none() {
            let current = inner.dues.iter().find(|d| d.id == due.id);
            if current.map(|d| (d.paid_principal, d.delay_penalty))
                != Some((before.paid_principal, before.delay_penalty))
            {
                return Ok(false);
            }
            let base = inner
                .finance
                .late_fee_accruals
                .iter()
                .map(|a| a.id)
                .max()
                .unwrap_or(0);
            for (i, row) in rows.iter_mut().enumerate() {
                row.id = base + 1 + i as i64;
            }
        }
        if let Some(slot) = inner.dues.iter_mut().find(|d| d.id == due.id) {
            *slot = due;
        }
        inner.finance.late_fee_accruals.extend(rows);
        Ok(true)
    }

    /// Reports every open liability whose stored late fee differs from its
    /// evaluation for the site's today (what the dashboard, statement and aging
    /// report show), so the stored figures would differ from them.
    pub async fn reconcile(&self, site_id: &str) -> LateFeeReconciliation {
        self.store
            .read(|inner| {
                let today = site_today(inner, site_id);
                let calc = DuesCalculationService::new();
                let mut checked = 0;
                let mut mismatches = Vec::new();
                for d in site_dues(inner, site_id)
                    .filter(|d| !matches!(d.status, DebtStatus::Paid | DebtStatus::Cancelled))
                {
                    checked += 1;
                    let evaluated = calc.calculate_delay_penalty(d.clone(), today);
                    if evaluated.delay_penalty != d.delay_penalty {
                        mismatches.push(LateFeeMismatch {
                            due_id: d.id.clone(),
                            unit_id: d.unit_id.clone(),
                            period: d.period.clone(),
                            stored_fee: d.delay_penalty,
                            evaluated_fee: evaluated.delay_penalty,
                            difference: evaluated.delay_penalty - d.delay_penalty,
                        });
                    }
                }
                LateFeeReconciliation {
                    site_id: site_id.to_string(),
                    as_of: today,
                    liabilities_checked: checked,
                    consistent: mismatches.is_empty(),
                    mismatches,
                }
            })
            .await
    }
}
