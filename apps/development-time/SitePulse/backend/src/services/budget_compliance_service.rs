//! İşletme projesi compliance extras, SPEC-009 R1: the legal-basis coverage of
//! operational liabilities, the 90-day transition for mid-year migrations, and
//! reminders before an interim budget's 3-month deadline.

use chrono::Days;
use rust_decimal::{Decimal, RoundingStrategy};

use crate::db::finance_store::FinanceStore;
use crate::models::*;
use crate::services::finance_common::*;
use crate::services::notification_service::NotificationService;
use crate::state::AppState;

pub const MAX_TRANSITION_DAYS: i64 = 90;
pub const INTERIM_REMINDER_DAYS: i64 = 14;

pub struct BudgetComplianceService {
    state: AppState,
    store: FinanceStore,
}

impl BudgetComplianceService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: FinanceStore::new(state),
        }
    }

    pub async fn set_transition(&self, caller: &Caller, req: SetTransitionRequest) -> FinanceResult<LegalBasisReport> {
        if !(0..=MAX_TRANSITION_DAYS).contains(&req.transition_days) {
            return Err(invalid(format!("transition_days must be between 0 and {}", MAX_TRANSITION_DAYS)));
        }
        let today = self.store.read(|inner| site_today(inner, &caller.site_id)).await;
        let until = (req.transition_days > 0)
            .then(|| today.checked_add_days(Days::new(u64::try_from(req.transition_days).unwrap_or(0))))
            .flatten();
        self.store.set_budget_transition(&caller.site_id, until).await?;
        Ok(self.legal_basis(&caller.site_id).await)
    }

    /// Operational liabilities and whether each rests on a budget (target 100%).
    pub async fn legal_basis(&self, site_id: &str) -> LegalBasisReport {
        self.store
            .read(|inner| {
                let today = site_today(inner, site_id);
                let until = inner
                    .finance
                    .budget_transitions
                    .iter()
                    .find(|(s, _)| crate::auth::same_id(s, site_id))
                    .map(|(_, d)| *d);
                let heat: Vec<&str> = inner
                    .finance
                    .heat_shares
                    .iter()
                    .filter_map(|s| s.due_id.as_deref())
                    .collect();
                let operational: Vec<&DuesLiability> = site_dues(inner, site_id)
                    .filter(|d| d.expense_type == ExpenseType::OperationalDues && !heat.contains(&d.id.as_str()))
                    .collect();
                let without: Vec<LiabilityWithoutBasis> = operational
                    .iter()
                    .filter(|d| !inner.dues_budget_basis.contains_key(&d.id))
                    .map(|d| LiabilityWithoutBasis {
                        due_id: d.id.clone(),
                        unit_label: label_of(inner, &d.unit_id),
                        period: d.period.clone(),
                        due_date: d.due_date,
                        principal: d.principal_amount,
                    })
                    .collect();
                let total = operational.len();
                let with = total - without.len();
                LegalBasisReport {
                    site_id: site_id.to_string(),
                    transition_until: until,
                    in_transition: until.is_some_and(|u| today <= u),
                    operational_liabilities: total,
                    with_legal_basis: with,
                    coverage_percent: (total > 0).then(|| {
                        (Decimal::from(u64::try_from(with).unwrap_or(0)) * Decimal::ONE_HUNDRED
                            / Decimal::from(u64::try_from(total).unwrap_or(1)))
                        .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)
                    }),
                    without_basis: without,
                }
            })
            .await
    }

    /// Notifies staff about interim budgets near or past their 3-month deadline (daily job).
    pub async fn remind_interim_deadlines(&self) -> FinanceResult<usize> {
        let due: Vec<(String, String, i32, chrono::NaiveDate, bool)> = self
            .store
            .read(|inner| {
                inner
                    .operating_budgets
                    .iter()
                    .filter(|b| b.status == BUDGET_INTERIM)
                    .filter_map(|b| {
                        let deadline = b.interim_deadline?;
                        let today = site_today(inner, &b.site_id);
                        let days = (deadline - today).num_days();
                        (days <= INTERIM_REMINDER_DAYS).then(|| {
                            (b.site_id.clone(), b.id.clone(), b.fiscal_year, deadline, days < 0)
                        })
                    })
                    .collect()
            })
            .await;
        let notifier = NotificationService::new(&self.state);
        let mut sent = 0;
        for (site, id, year, deadline, past) in due {
            let (subject, stage) = if past {
                (format!("Geçici işletme projesi {} süresi doldu", year), "past")
            } else {
                (format!("Geçici işletme projesi {} için genel kurul süresi yaklaşıyor", year), "soon")
            };
            let body = format!(
                "KMK 37: geçici işletme projesi #{} en geç {} tarihine kadar kat malikleri kuruluna sunulmalıdır.",
                id,
                deadline.format("%d.%m.%Y")
            );
            sent += notifier
                .notify_staff(&site, "BUDGET", &subject, &body, &format!("interim-deadline:{}:{}", id, stage))
                .await?
                .len();
        }
        Ok(sent)
    }
}
