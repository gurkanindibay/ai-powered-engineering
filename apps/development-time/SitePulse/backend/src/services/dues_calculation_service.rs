use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal::RoundingStrategy;

use crate::models::{DebtStatus, DuesLiability};
use crate::services::dues_ledger;

pub struct DuesCalculationService;

impl Default for DuesCalculationService {
    fn default() -> Self {
        Self
    }
}

impl DuesCalculationService {
    pub fn new() -> Self {
        Self
    }

    /// KMK Article 20 statutory delay fee, pro-rated daily:
    /// `penalty = principal_owed * 0.05 * days_overdue / 30`, rounded half away from zero.
    ///
    /// The result is deterministic and independent of earlier recalculations:
    /// * the base is the principal *owed* (payments are tracked separately in
    ///   `paid_principal`), so recalculation never shrinks the penalty;
    /// * the penalty never decreases: it is at least the stored accrual and at
    ///   least what has already been paid (`paid_penalty`);
    /// * once the principal is fully paid the penalty stops accruing;
    /// * `total_amount` is always the outstanding balance.
    pub fn calculate_delay_penalty(&self, mut dues: DuesLiability, evaluation_date: NaiveDate) -> DuesLiability {
        if dues.status == DebtStatus::Paid {
            dues_ledger::refresh(&mut dues);
            return dues;
        }

        let days_overdue = (evaluation_date - dues.due_date).num_days();
        if days_overdue > 0 && dues_ledger::outstanding_principal(&dues) > Decimal::ZERO {
            let monthly_rate = Decimal::from_str_exact("0.05").unwrap();
            let penalty = (dues.principal_amount * monthly_rate * Decimal::from(days_overdue) / Decimal::from(30))
                .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
            // Monotonic: never below the stored accrual or what was already paid.
            dues.delay_penalty = penalty.max(dues.delay_penalty).max(dues.paid_penalty);
        } else {
            dues.delay_penalty = dues.delay_penalty.max(dues.paid_penalty);
        }

        dues.status = if days_overdue > 0 { DebtStatus::Overdue } else { DebtStatus::Pending };
        dues_ledger::refresh(&mut dues);
        dues
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn due(paid_principal: &str, paid_penalty: &str) -> DuesLiability {
        DuesLiability {
            id: "1".to_string(),
            unit_id: "14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::ZERO,
            due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
            status: DebtStatus::Pending,
            paid_principal: Decimal::from_str_exact(paid_principal).unwrap(),
            paid_penalty: Decimal::from_str_exact(paid_penalty).unwrap(),
            debtor_type: "TENANT".to_string(),
            expense_type: "OPERATIONAL_DUES".to_string(),
        }
    }

    #[test]
    fn recalculation_is_stable_after_partial_payment() {
        let svc = DuesCalculationService::new();
        let day = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
        let first = svc.calculate_delay_penalty(due("700.00", "23.33"), day);
        let again = svc.calculate_delay_penalty(first.clone(), day);
        assert_eq!(first.delay_penalty, Decimal::from_str_exact("23.33").unwrap());
        assert_eq!(again.delay_penalty, first.delay_penalty, "recalculation must not change the penalty");
        assert_eq!(again.total_amount, Decimal::from_str_exact("700.00").unwrap());
    }

    #[test]
    fn paid_penalty_never_disappears_and_accrual_stops_when_principal_is_paid() {
        let svc = DuesCalculationService::new();
        let early = NaiveDate::from_ymd_opt(2026, 9, 1).unwrap();
        let r = svc.calculate_delay_penalty(due("0.00", "10.00"), early);
        assert_eq!(r.delay_penalty, Decimal::from_str_exact("10.00").unwrap());
        let late = NaiveDate::from_ymd_opt(2026, 12, 1).unwrap();
        let mut settled = due("1400.00", "23.33");
        settled.delay_penalty = Decimal::from_str_exact("23.33").unwrap();
        let r = svc.calculate_delay_penalty(settled, late);
        assert_eq!(r.delay_penalty, Decimal::from_str_exact("23.33").unwrap());
        assert_eq!(r.status, DebtStatus::Paid);
    }
}
