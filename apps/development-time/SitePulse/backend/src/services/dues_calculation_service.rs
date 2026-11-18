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

    /// KMK Article 20 statutory delay fee: 5% per month, pro-rated daily, on the
    /// principal that is still **unpaid** (SPEC-005 R3).
    ///
    /// The penalty accrues in segments. `delay_penalty` is the amount accrued up
    /// to `penalty_accrued_through`; an evaluation adds only the segment from
    /// `max(due_date, penalty_accrued_through)` to `evaluation_date`:
    /// `outstanding_principal * 0.05 * days / 30`, rounded to 2 decimals half away
    /// from zero, then moves `penalty_accrued_through` to `evaluation_date`.
    /// Payments run this first, so each segment uses the principal outstanding
    /// during that segment.
    ///
    /// * Re-evaluating on the same (or an earlier) date adds nothing.
    /// * The penalty never decreases and is never below what was already paid.
    /// * Once the principal is fully paid the penalty stops accruing.
    /// * A liability that never accrued a segment (`penalty_accrued_through`
    ///   is `None`) is evaluated as one segment from the due date, and never
    ///   ends up below its stored penalty.
    /// * While the liability's grace period runs (`grace_days` after the due date) no fee
    ///   accrues; afterwards the fee runs from the due date.
    /// * `total_amount` is always the outstanding balance.
    pub fn calculate_delay_penalty(
        &self,
        mut dues: DuesLiability,
        evaluation_date: NaiveDate,
    ) -> DuesLiability {
        if matches!(dues.status, DebtStatus::Paid | DebtStatus::Cancelled) {
            dues_ledger::refresh(&mut dues);
            return dues;
        }

        // Grace period (STORY-07-10): while it runs nothing accrues and no segment starts. The
        // first evaluation after it covers the segment from the due date, as KMK 20 requires.
        if dues.penalty_accrued_through.is_none() && Self::in_grace(&dues, evaluation_date) {
            dues.status = if evaluation_date > dues.due_date {
                DebtStatus::Overdue
            } else {
                DebtStatus::Pending
            };
            dues_ledger::refresh(&mut dues);
            return dues;
        }

        let outstanding_principal = dues_ledger::outstanding_principal(&dues);
        let accrued = dues.delay_penalty.max(dues.paid_penalty);
        let segment_start = match dues.penalty_accrued_through {
            Some(through) => through.max(dues.due_date),
            None => dues.due_date,
        };
        let segment_days = (evaluation_date - segment_start).num_days();
        let segment = if segment_days > 0 && outstanding_principal > Decimal::ZERO {
            (outstanding_principal * Self::monthly_rate() * Decimal::from(segment_days)
                / Decimal::from(30))
            .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero)
        } else {
            Decimal::ZERO
        };
        dues.delay_penalty = match dues.penalty_accrued_through {
            Some(_) => accrued + segment,
            // Legacy single segment: the stored figure already covers part of it.
            None => accrued.max(segment),
        };
        if evaluation_date > dues.due_date {
            let through = dues
                .penalty_accrued_through
                .map_or(evaluation_date, |t| t.max(evaluation_date));
            dues.penalty_accrued_through = Some(through);
        }

        let days_overdue = (evaluation_date - dues.due_date).num_days();
        dues.status = if days_overdue > 0 {
            DebtStatus::Overdue
        } else {
            DebtStatus::Pending
        };
        dues_ledger::refresh(&mut dues);
        dues
    }

    /// Whether `date` is within the liability's grace period (the due date and the
    /// `grace_days` after it).
    pub fn in_grace(dues: &DuesLiability, date: NaiveDate) -> bool {
        dues.grace_days > 0 && date <= dues.due_date + chrono::Days::new(u64::from(dues.grace_days))
    }

    fn monthly_rate() -> Decimal {
        Decimal::new(5, 2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{DebtorType, ExpenseType};

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
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
        }
    }

    #[test]
    fn recalculation_is_stable_after_partial_payment() {
        let svc = DuesCalculationService::new();
        let day = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
        let first = svc.calculate_delay_penalty(due("700.00", "23.33"), day);
        let again = svc.calculate_delay_penalty(first.clone(), day);
        assert_eq!(
            first.delay_penalty,
            Decimal::from_str_exact("23.33").unwrap()
        );
        assert_eq!(
            again.delay_penalty, first.delay_penalty,
            "recalculation must not change the penalty"
        );
        assert_eq!(
            again.total_amount,
            Decimal::from_str_exact("700.00").unwrap()
        );
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

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap()
    }

    fn date(m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, m, day).unwrap()
    }

    /// SPEC-005 scenario: ₺1,000 due 09-01, ₺600 principal paid 09-16, evaluated 10-01.
    #[test]
    fn penalty_accrues_only_on_unpaid_principal_after_partial_payment() {
        let svc = DuesCalculationService::new();
        let mut liability = due("0.00", "0.00");
        liability.principal_amount = d("1000.00");
        liability.due_date = date(9, 1);

        // Payment day: accrue the first segment, then pay ₺600 principal.
        let mut at_payment = svc.calculate_delay_penalty(liability, date(9, 16));
        assert_eq!(at_payment.delay_penalty, d("25.00"));
        assert_eq!(at_payment.penalty_accrued_through, Some(date(9, 16)));
        at_payment.paid_principal = d("600.00");

        let later = svc.calculate_delay_penalty(at_payment, date(10, 1));
        assert_eq!(
            later.delay_penalty,
            d("35.00"),
            "₺25.00 + ₺400.00 × 5% × 15 / 30"
        );
        let again = svc.calculate_delay_penalty(later.clone(), date(10, 1));
        assert_eq!(
            again.delay_penalty,
            d("35.00"),
            "same-day re-evaluation adds nothing"
        );
        let earlier = svc.calculate_delay_penalty(later, date(9, 20));
        assert_eq!(
            earlier.delay_penalty,
            d("35.00"),
            "an earlier evaluation date never removes accrual"
        );
        assert_eq!(earlier.penalty_accrued_through, Some(date(10, 1)));
    }

    #[test]
    fn no_penalty_and_no_accrual_date_before_the_due_date() {
        let svc = DuesCalculationService::new();
        let r = svc.calculate_delay_penalty(due("0.00", "0.00"), date(9, 10));
        assert_eq!(r.delay_penalty, Decimal::ZERO);
        assert_eq!(r.penalty_accrued_through, None);
        assert_eq!(r.status, DebtStatus::Pending);
    }
}
