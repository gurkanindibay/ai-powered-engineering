//! Supplementary charges for days nobody was billed (STORY-07-13).
//!
//! When a responsible party's start residing date is back-dated into a month that was
//! already accrued without a charge for the unit, those days would never be billed. They
//! become a supplementary charge that refers to the original month:
//!
//! - posted in that month while it is open, otherwise in the current open period, so a
//!   closed month's snapshot never changes (as for late fees after close, STORY-07-12);
//! - due on the original month's due date, which keeps FIFO settling the oldest month first;
//! - days already billed to someone are not touched here: they go through the four-eyes
//!   split correction (`OccupancyService::request_open_period_split`).

use chrono::NaiveDate;
use rust_decimal::Decimal;

use crate::db::dues_repository::SupplementaryInsert;
use crate::db::finance_store::FinanceStore;
use crate::domain::billing_period::BillingPeriod;
use crate::domain::occupancy_proration::unbilled_days_amount;
use crate::models::{
    DebtStatus, DebtorType, DuesLiability, DuesPeriodStatus, ExpenseType, OccupancyHistoryItem,
};
use crate::services::finance_common::{conflict, FinanceResult};
use crate::services::operating_budget_service as budgets;
use crate::state::{AppState, AppStateInner};

/// A supplementary charge decided but not yet stored.
#[derive(Debug, Clone)]
pub struct PlannedCharge {
    pub due: DuesLiability,
    /// Canonical key (`2026-10`) of the month the charge bills.
    pub source_period_key: String,
}

/// The month a liability bills: its own period unless it is a supplementary charge.
pub fn billed_period(inner: &AppStateInner, due: &DuesLiability) -> Option<BillingPeriod> {
    match inner.dues_source_period.get(&due.id) {
        Some(source) => BillingPeriod::parse(source).ok(),
        None => BillingPeriod::parse(&due.period).ok(),
    }
}

/// Decides the supplementary charges a new responsible party owes for `start_date` onward.
///
/// Only accrued months (a billing period row exists) up to `today` are considered, and only
/// when the unit has no operational liability at all for the month. Nothing is changed.
pub fn plan_supplementary_charges(
    inner: &AppStateInner,
    site_id: &str,
    unit_id: &str,
    debtor_type: DebtorType,
    start_date: NaiveDate,
    today: NaiveDate,
) -> FinanceResult<Vec<PlannedCharge>> {
    let Some(site) = inner
        .sites
        .iter()
        .find(|site| crate::auth::same_id(&site.id, site_id))
    else {
        return Ok(Vec::new());
    };
    if !site.proration_enabled {
        return Ok(Vec::new());
    }
    let Some(unit) = inner.units.iter().find(|unit| {
        crate::auth::same_id(&unit.id, unit_id) && crate::auth::same_id(&unit.site_id, site_id)
    }) else {
        return Ok(Vec::new());
    };
    let grace_days = inner
        .site_accrual_schedules
        .get(site_id)
        .map_or(0, |schedule| schedule.grace_days);

    let mut months: Vec<(BillingPeriod, &crate::models::DuesPeriod)> = inner
        .dues_periods
        .iter()
        .filter(|row| crate::auth::same_id(&row.site_id, site_id))
        .filter_map(|row| {
            BillingPeriod::parse(&row.period_name)
                .ok()
                .map(|p| (p, row))
        })
        .filter(|(period, _)| period.first_day() <= today && period.last_day() >= start_date)
        .collect();
    months.sort_by_key(|(period, _)| *period);

    let current = BillingPeriod::of_date(today);
    let mut planned = Vec::new();
    for (month, row) in months {
        let already_billed = inner.dues.iter().any(|due| {
            crate::auth::same_id(&due.unit_id, &unit.id)
                && due.expense_type == ExpenseType::OperationalDues
                && due.status != DebtStatus::Cancelled
                && billed_period(inner, due) == Some(month)
        });
        if already_billed {
            continue;
        }
        let Ok(basis) = budgets::operational_dues_basis(inner, unit, row.due_date) else {
            continue;
        };
        let Ok(Some(amount)) =
            unbilled_days_amount(basis.amount, month.first_day(), unit.created_on, start_date)
        else {
            continue;
        };
        let posting = posting_period(inner, site_id, month, current)?;
        planned.push(PlannedCharge {
            due: DuesLiability {
                id: String::new(),
                unit_id: unit.id.clone(),
                period: posting.label(),
                principal_amount: amount,
                delay_penalty: Decimal::ZERO,
                total_amount: amount,
                due_date: row.due_date,
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                debtor_type,
                expense_type: ExpenseType::OperationalDues,
                penalty_accrued_through: None,
                grace_days,
            },
            source_period_key: month.key(),
        });
    }
    Ok(planned)
}

/// The period a charge for `month` is posted in: the month itself while open, otherwise the
/// current period.
fn posting_period(
    inner: &AppStateInner,
    site_id: &str,
    month: BillingPeriod,
    current: BillingPeriod,
) -> FinanceResult<BillingPeriod> {
    if !is_closed(inner, site_id, month) {
        return Ok(month);
    }
    if is_closed(inner, site_id, current) {
        return Err(conflict(format!(
            "Billing period {} is closed; open a period before posting the charge for {}",
            current.key(),
            month.key()
        )));
    }
    Ok(current)
}

fn is_closed(inner: &AppStateInner, site_id: &str, period: BillingPeriod) -> bool {
    inner.dues_periods.iter().any(|row| {
        crate::auth::same_id(&row.site_id, site_id)
            && BillingPeriod::parse(&row.period_name).ok() == Some(period)
            && row.status == DuesPeriodStatus::Closed
    })
}

pub struct SupplementaryChargeService {
    state: AppState,
}

impl SupplementaryChargeService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Posts the supplementary charges for the session a transition just opened.
    pub async fn post_for_opened_session(
        &self,
        site_id: &str,
        opened: &OccupancyHistoryItem,
        today: NaiveDate,
    ) -> FinanceResult<Vec<DuesLiability>> {
        let Ok(start_date) = NaiveDate::parse_from_str(&opened.start_date, "%Y-%m-%d") else {
            return Ok(Vec::new());
        };
        let unit_id = opened.unit_id.to_string();
        let planned = {
            let inner = self.state.inner.read().await;
            plan_supplementary_charges(&inner, site_id, &unit_id, opened.role, start_date, today)?
        };
        if planned.is_empty() {
            return Ok(Vec::new());
        }

        let inserts: Vec<SupplementaryInsert<'_>> = planned
            .iter()
            .map(|charge| SupplementaryInsert {
                due: &charge.due,
                source_period_key: &charge.source_period_key,
            })
            .collect();
        let stored = FinanceStore::new(&self.state)
            .persist_supplementary(site_id, &inserts)
            .await?;
        let persisted = stored.is_some();
        let ids = stored.unwrap_or_else(|| vec![None; planned.len()]);

        let mut inner = self.state.inner.write().await;
        let mut posted = Vec::new();
        for (charge, id) in planned.into_iter().zip(ids) {
            let mut due = charge.due;
            if persisted {
                let Some(id) = id else { continue };
                due.id = id;
            } else {
                if inner.dues.iter().any(|existing| {
                    crate::auth::same_id(&existing.unit_id, &due.unit_id)
                        && existing.status != DebtStatus::Cancelled
                        && billed_period(&inner, existing)
                            == BillingPeriod::parse(&charge.source_period_key).ok()
                }) {
                    continue;
                }
                due.id = (inner
                    .dues
                    .iter()
                    .filter_map(|existing| crate::db::parse_id_to_i64(&existing.id))
                    .max()
                    .unwrap_or(0)
                    + 1)
                .to_string();
            }
            inner
                .dues_source_period
                .insert(due.id.clone(), charge.source_period_key.clone());
            tracing::info!(
                unit_id = %due.unit_id,
                posted_in = %due.period,
                refers_to = %charge.source_period_key,
                amount = %due.principal_amount,
                "Supplementary charge posted for a back-dated start date"
            );
            inner.dues.push(due.clone());
            posted.push(due);
        }
        Ok(posted)
    }
}
