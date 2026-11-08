//! Payment plan (yapılandırma) schedules, SPEC-009 R10.
//!
//! A plan spreads a debt over equal monthly instalments. The split uses
//! [`super::apportion`] so the instalments add up to the total exactly; the
//! leftover kuruş go to the earliest instalments. Progress compares what was paid
//! on the covered debts since the plan opened with what the schedule required.

use chrono::{Months, NaiveDate};
use rust_decimal::Decimal;
use thiserror::Error;

use super::apportionment::{apportion, ApportionmentError};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PlanError {
    #[error("a plan has between 2 and 36 instalments")]
    InstallmentCount,
    #[error("the plan total must be positive")]
    Total,
    #[error("the schedule date is out of range")]
    Date,
    #[error(transparent)]
    Apportion(#[from] ApportionmentError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduledInstallment {
    pub seq: u32,
    pub due_date: NaiveDate,
    pub amount: Decimal,
}

/// Equal monthly instalments starting on `first_due`.
pub fn schedule(
    total: Decimal,
    count: u32,
    first_due: NaiveDate,
) -> Result<Vec<ScheduledInstallment>, PlanError> {
    if !(2..=36).contains(&count) {
        return Err(PlanError::InstallmentCount);
    }
    if total <= Decimal::ZERO {
        return Err(PlanError::Total);
    }
    let n = usize::try_from(count).map_err(|_| PlanError::InstallmentCount)?;
    // Equal weights, with a tiny preference for earlier positions on ties
    // (apportion breaks ties by lower position already).
    let parts = apportion(total, &vec![1u64; n])?;
    let mut out = Vec::with_capacity(n);
    for (i, amount) in parts.into_iter().enumerate() {
        let seq = u32::try_from(i + 1).map_err(|_| PlanError::InstallmentCount)?;
        let due_date = first_due
            .checked_add_months(Months::new(seq - 1))
            .ok_or(PlanError::Date)?;
        out.push(ScheduledInstallment {
            seq,
            due_date,
            amount,
        });
    }
    Ok(out)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallmentProgress {
    pub seq: u32,
    pub due_date: NaiveDate,
    pub amount: Decimal,
    /// The part of the instalment covered by payments (paid amounts fill
    /// instalments in order).
    pub covered: Decimal,
    /// `PAID`, `PARTIAL`, `DUE` (not yet due), `OVERDUE`.
    pub status: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanProgress {
    pub installments: Vec<InstallmentProgress>,
    pub paid: Decimal,
    pub required_to_date: Decimal,
    /// Every instalment is covered.
    pub completed: bool,
    /// An instalment is overdue by more than the grace days and not covered.
    pub broken: bool,
}

/// Evaluates a schedule against the amount paid since the plan opened.
pub fn evaluate(
    installments: &[ScheduledInstallment],
    paid: Decimal,
    as_of: NaiveDate,
    grace_days: u32,
) -> PlanProgress {
    let mut remaining = paid.max(Decimal::ZERO);
    let mut required_to_date = Decimal::ZERO;
    let mut broken = false;
    let mut rows = Vec::with_capacity(installments.len());
    for inst in installments {
        let covered = remaining.min(inst.amount);
        remaining -= covered;
        let is_due = inst.due_date <= as_of;
        if is_due {
            required_to_date += inst.amount;
        }
        let status = if covered >= inst.amount {
            "PAID"
        } else if !is_due {
            if covered > Decimal::ZERO {
                "PARTIAL"
            } else {
                "DUE"
            }
        } else {
            let days_late = (as_of - inst.due_date).num_days();
            if days_late > i64::from(grace_days) {
                broken = true;
            }
            "OVERDUE"
        };
        rows.push(InstallmentProgress {
            seq: inst.seq,
            due_date: inst.due_date,
            amount: inst.amount,
            covered,
            status,
        });
    }
    let completed = rows.iter().all(|r| r.status == "PAID");
    PlanProgress {
        installments: rows,
        paid,
        required_to_date,
        completed,
        broken: broken && !completed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap_or_default()
    }
    fn date(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap_or_default()
    }

    #[test]
    fn instalments_add_up_and_leftover_goes_first() {
        let s = schedule(d("1000.00"), 3, date(2027, 1, 31)).unwrap_or_default();
        let amounts: Vec<Decimal> = s.iter().map(|i| i.amount).collect();
        assert_eq!(amounts, vec![d("333.34"), d("333.33"), d("333.33")]);
        assert_eq!(s.iter().map(|i| i.amount).sum::<Decimal>(), d("1000.00"));
        assert_eq!(s[1].due_date, date(2027, 2, 28), "month ends are clamped");
        assert_eq!(s[2].due_date, date(2027, 3, 31));
        assert_eq!(
            schedule(d("10"), 1, date(2027, 1, 1)),
            Err(PlanError::InstallmentCount)
        );
        assert_eq!(schedule(d("0"), 3, date(2027, 1, 1)), Err(PlanError::Total));
    }

    #[test]
    fn a_plan_breaks_only_after_the_grace_days() {
        let s = schedule(d("900.00"), 3, date(2027, 1, 10)).unwrap_or_default();
        let on_time = evaluate(&s, d("300.00"), date(2027, 2, 12), 5);
        assert!(
            !on_time.broken,
            "the 2nd instalment is 2 days late, within grace"
        );
        assert_eq!(on_time.required_to_date, d("600.00"));
        let late = evaluate(&s, d("300.00"), date(2027, 2, 16), 5);
        assert!(late.broken);
        assert_eq!(late.installments[1].status, "OVERDUE");
        let done = evaluate(&s, d("900.00"), date(2027, 6, 1), 0);
        assert!(done.completed && !done.broken);
        let partial = evaluate(&s, d("450.00"), date(2027, 1, 20), 0);
        assert_eq!(partial.installments[1].covered, d("150.00"));
        assert_eq!(partial.installments[1].status, "PARTIAL");
    }
}
