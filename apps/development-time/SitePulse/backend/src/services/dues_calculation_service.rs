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
            dues.status = if evaluation_date > dues.fee_due_date() {
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
            Some(through) => through.max(dues.fee_due_date()),
            None => dues.fee_due_date(),
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
        if evaluation_date > dues.fee_due_date() {
            let through = dues
                .penalty_accrued_through
                .map_or(evaluation_date, |t| t.max(evaluation_date));
            dues.penalty_accrued_through = Some(through);
        }

        let days_overdue = (evaluation_date - dues.fee_due_date()).num_days();
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
        dues.grace_days > 0
            && date <= dues.fee_due_date() + chrono::Days::new(u64::from(dues.grace_days))
    }

    /// Late fee a liability accrues from its due date up to `through`, given the
    /// principal payments made against it (`(payment date, principal)`).
    ///
    /// Each payment reduces the penalised principal from its payment date on, and
    /// every segment is rounded like `calculate_delay_penalty`. Used to
    /// re-evaluate the fee when a payment is recorded with a value date earlier
    /// than `penalty_accrued_through` (#187).
    pub fn penalty_through(
        &self,
        principal_amount: Decimal,
        due_date: NaiveDate,
        through: NaiveDate,
        principal_payments: &[(NaiveDate, Decimal)],
    ) -> Decimal {
        self.penalty_through_with_grace(principal_amount, due_date, through, principal_payments, 0)
    }

    /// [`Self::penalty_through`] for a liability with a grace period (STORY-07-10): nothing
    /// accrues up to the end of the grace period, a payment inside it counts as made on the
    /// due date, and afterwards the fee runs from the due date.
    pub fn penalty_through_with_grace(
        &self,
        principal_amount: Decimal,
        due_date: NaiveDate,
        through: NaiveDate,
        principal_payments: &[(NaiveDate, Decimal)],
        grace_days: u32,
    ) -> Decimal {
        let grace_end = due_date + chrono::Days::new(u64::from(grace_days));
        if grace_days > 0 && through <= grace_end {
            return Decimal::ZERO;
        }
        let mut payments: Vec<(NaiveDate, Decimal)> = principal_payments
            .iter()
            .filter(|(_, amount)| *amount > Decimal::ZERO)
            .map(|(date, amount)| {
                if grace_days > 0 && *date <= grace_end {
                    (due_date, *amount)
                } else {
                    (*date, *amount)
                }
            })
            .collect();
        payments.sort_by_key(|(date, _)| *date);
        let mut penalty = Decimal::ZERO;
        let mut cursor = due_date;
        let mut paid = Decimal::ZERO;
        let mut index = 0;
        loop {
            // Payments dated on or before the cursor already reduce the principal.
            while index < payments.len() && payments[index].0 <= cursor {
                paid += payments[index].1;
                index += 1;
            }
            let segment_end = match payments.get(index) {
                Some((date, _)) if *date < through => *date,
                _ => through,
            };
            let days = (segment_end - cursor).num_days();
            let outstanding = (principal_amount - paid).max(Decimal::ZERO);
            if days > 0 && outstanding > Decimal::ZERO {
                penalty += (outstanding * Self::monthly_rate() * Decimal::from(days)
                    / Decimal::from(30))
                .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
            }
            if segment_end >= through {
                break;
            }
            cursor = segment_end;
        }
        penalty
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
            effective_due_date: None,
        }
    }

    #[test]
    fn penalty_through_charges_only_the_days_before_a_backdated_payment() {
        let svc = DuesCalculationService::new();
        let due_date = NaiveDate::from_ymd_opt(2026, 10, 15).unwrap();
        let principal = Decimal::from_str_exact("1400.00").unwrap();
        let nov_15 = NaiveDate::from_ymd_opt(2026, 11, 14).unwrap();
        let oct_20 = NaiveDate::from_ymd_opt(2026, 10, 20).unwrap();
        assert_eq!(
            svc.penalty_through(principal, due_date, nov_15, &[]),
            Decimal::from_str_exact("70.00").unwrap(),
            "one month on the full principal"
        );
        assert_eq!(
            svc.penalty_through(principal, due_date, nov_15, &[(oct_20, principal)]),
            Decimal::from_str_exact("11.67").unwrap(),
            "5 days on 1,400.00 before the payment"
        );
    }

    #[test]
    fn penalty_through_follows_partial_payments_in_date_order() {
        let svc = DuesCalculationService::new();
        let due_date = NaiveDate::from_ymd_opt(2026, 10, 15).unwrap();
        let principal = Decimal::from_str_exact("1400.00").unwrap();
        let through = NaiveDate::from_ymd_opt(2026, 11, 14).unwrap();
        let half = Decimal::from_str_exact("700.00").unwrap();
        let day = |m, d| NaiveDate::from_ymd_opt(2026, m, d).unwrap();
        // 10 days on 1,400 (23.33) then 20 days on 700 (23.33).
        assert_eq!(
            svc.penalty_through(principal, due_date, through, &[(day(10, 25), half)]),
            Decimal::from_str_exact("46.66").unwrap()
        );
        // A payment on the due date or before it leaves nothing to penalise.
        assert_eq!(
            svc.penalty_through(principal, due_date, through, &[(day(10, 15), principal)]),
            Decimal::ZERO
        );
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

    fn late_charge(effective: Option<NaiveDate>) -> DuesLiability {
        let mut liability = due("0.00", "0.00");
        liability.principal_amount = d("650.00");
        liability.due_date = date(11, 10);
        liability.effective_due_date = effective;
        liability
    }

    #[test]
    fn a_charge_created_late_owes_no_fee_for_days_before_it_existed() {
        let svc = DuesCalculationService::new();
        let from_creation =
            svc.calculate_delay_penalty(late_charge(Some(date(11, 18))), date(11, 19));
        assert_eq!(from_creation.delay_penalty, d("1.08"));
        let from_period = svc.calculate_delay_penalty(late_charge(None), date(11, 19));
        assert_eq!(from_period.delay_penalty, d("9.75"));
    }

    #[test]
    fn grace_and_status_count_from_the_effective_due_date() {
        let svc = DuesCalculationService::new();
        let mut charge = late_charge(Some(date(11, 18)));
        charge.grace_days = 5;
        assert!(DuesCalculationService::in_grace(&charge, date(11, 23)));
        assert!(!DuesCalculationService::in_grace(&charge, date(11, 24)));
        let on_creation = svc.calculate_delay_penalty(charge.clone(), date(11, 18));
        assert_eq!(on_creation.status, DebtStatus::Pending);
        assert_eq!(on_creation.delay_penalty, Decimal::ZERO);
    }

    #[test]
    fn the_effective_due_date_is_never_before_the_period_due_date() {
        assert_eq!(
            DuesLiability::effective_due_date_for(date(11, 10), date(11, 2)),
            date(11, 10)
        );
        assert_eq!(
            DuesLiability::effective_due_date_for(date(11, 10), date(11, 18)),
            date(11, 18)
        );
        let mut charge = late_charge(Some(date(11, 1)));
        assert_eq!(charge.fee_due_date(), date(11, 10));
        charge.effective_due_date = None;
        assert_eq!(charge.fee_due_date(), date(11, 10));
    }
}
