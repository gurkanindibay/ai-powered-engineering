//! Collection KPIs, SPEC-009 R14: on-time collection rate, DSO and an at-risk
//! score per unit. Inputs are plain values so the same numbers can be computed
//! from memory or from SQL.

use chrono::NaiveDate;
use rust_decimal::{Decimal, RoundingStrategy};

/// One settlement of a liability's principal (an allocation line of a receipt).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settlement {
    pub due_date: NaiveDate,
    pub settled_on: NaiveDate,
    pub amount: Decimal,
}

fn pct(part: Decimal, whole: Decimal) -> Option<Decimal> {
    (whole > Decimal::ZERO).then(|| {
        (part * Decimal::ONE_HUNDRED / whole)
            .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven)
    })
}

/// Principal settled on or before its due date, as a percentage of the principal due.
pub fn on_time_rate(principal_due: Decimal, settlements: &[Settlement]) -> Option<Decimal> {
    let on_time: Decimal = settlements
        .iter()
        .filter(|s| s.settled_on <= s.due_date)
        .map(|s| s.amount)
        .sum();
    pct(on_time, principal_due)
}

/// Settled principal as a percentage of the principal due (any time).
pub fn collection_rate(principal_due: Decimal, settled: Decimal) -> Option<Decimal> {
    pct(settled, principal_due)
}

/// Days sales outstanding: amount-weighted mean of days from the due date to the
/// settlement (early payments count as zero days).
pub fn dso_days(settlements: &[Settlement]) -> Option<Decimal> {
    let total: Decimal = settlements.iter().map(|s| s.amount).sum();
    if total <= Decimal::ZERO {
        return None;
    }
    let weighted: Decimal = settlements
        .iter()
        .map(|s| Decimal::from((s.settled_on - s.due_date).num_days().max(0)) * s.amount)
        .sum();
    Some((weighted / total).round_dp_with_strategy(1, RoundingStrategy::MidpointNearestEven))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskTier {
    Low,
    Medium,
    High,
}

impl RiskTier {
    pub fn as_str(self) -> &'static str {
        match self {
            RiskTier::Low => "LOW",
            RiskTier::Medium => "MEDIUM",
            RiskTier::High => "HIGH",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RiskInput {
    /// Outstanding overdue amount.
    pub overdue_amount: Decimal,
    /// The unit's monthly dues (to express the debt in months).
    pub monthly_dues: Decimal,
    /// Days the oldest overdue item is late.
    pub oldest_days_overdue: i64,
    pub broken_plans: u32,
    pub open_disputes: u32,
    pub in_collection: bool,
}

/// A 0–100 score: months of dues owed (up to 40 points), age of the oldest item
/// (up to 30), broken plans (15 each, up to 30), and a collection case (+10).
/// An open dispute lowers the score by 10: the debt may be wrong.
pub fn risk_score(input: &RiskInput) -> (u32, RiskTier) {
    let months_owed = if input.monthly_dues > Decimal::ZERO {
        input.overdue_amount / input.monthly_dues
    } else if input.overdue_amount > Decimal::ZERO {
        Decimal::from(3)
    } else {
        Decimal::ZERO
    };
    use rust_decimal::prelude::ToPrimitive;
    let months_points = (months_owed * Decimal::from(10))
        .round_dp_with_strategy(0, RoundingStrategy::MidpointNearestEven)
        .to_u32()
        .unwrap_or(40)
        .min(40);
    let age_points = u32::try_from((input.oldest_days_overdue.max(0) / 6).min(30)).unwrap_or(30);
    let plan_points = (input.broken_plans * 15).min(30);
    let case_points = if input.in_collection { 10 } else { 0 };
    let raw = months_points + age_points + plan_points + case_points;
    let score = raw.saturating_sub(input.open_disputes.min(1) * 10).min(100);
    let tier = if score >= 60 {
        RiskTier::High
    } else if score >= 30 {
        RiskTier::Medium
    } else {
        RiskTier::Low
    };
    (score, tier)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap_or_default()
    }
    fn date(m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2027, m, day).unwrap_or_default()
    }

    #[test]
    fn rates_and_dso_are_amount_weighted() {
        let s = vec![
            Settlement {
                due_date: date(1, 10),
                settled_on: date(1, 5),
                amount: d("100"),
            },
            Settlement {
                due_date: date(1, 10),
                settled_on: date(1, 30),
                amount: d("300"),
            },
        ];
        assert_eq!(on_time_rate(d("500"), &s), Some(d("20.00")));
        assert_eq!(collection_rate(d("500"), d("400")), Some(d("80.00")));
        assert_eq!(dso_days(&s), Some(d("15.0")));
        assert_eq!(dso_days(&[]), None);
        assert_eq!(on_time_rate(Decimal::ZERO, &s), None);
    }

    #[test]
    fn risk_tiers_follow_the_debt() {
        let clean = RiskInput {
            overdue_amount: Decimal::ZERO,
            monthly_dues: d("1000"),
            oldest_days_overdue: 0,
            broken_plans: 0,
            open_disputes: 0,
            in_collection: false,
        };
        assert_eq!(risk_score(&clean), (0, RiskTier::Low));
        let late = RiskInput {
            overdue_amount: d("3000"),
            oldest_days_overdue: 90,
            ..clean.clone()
        };
        assert_eq!(risk_score(&late), (45, RiskTier::Medium));
        let worst = RiskInput {
            broken_plans: 1,
            in_collection: true,
            ..late.clone()
        };
        assert_eq!(risk_score(&worst).1, RiskTier::High);
        let disputed = RiskInput {
            open_disputes: 2,
            ..late
        };
        assert_eq!(risk_score(&disputed).0, 35);
    }
}
