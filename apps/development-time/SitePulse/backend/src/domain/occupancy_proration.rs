//! Splits monthly operational dues between the owner and tenant by calendar days.
//!
//! A tenant session's end date is exclusive, matching `unit_occupancies`. Days
//! with no active tenant belong to the owner. The final role receives the
//! remainder so rounding cannot change the total.

use chrono::{Datelike, Days, NaiveDate};
use rust_decimal::{Decimal, RoundingStrategy};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponsibleParty {
    Owner,
    Tenant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OccupancySpan {
    pub party: ResponsibleParty,
    pub starts_on: NaiveDate,
    /// Exclusive. `None` represents an open session.
    pub ends_before: Option<NaiveDate>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProratedShare {
    pub party: ResponsibleParty,
    pub amount: Decimal,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProrationError {
    #[error("the monthly amount must not be negative")]
    NegativeAmount,
    #[error("the monthly amount must have at most two decimal places")]
    InvalidScale,
}

/// Returns the period's liability shares. With proration disabled, the party
/// responsible on `accrued_on` owes the full month (existing SitePulse policy).
/// With proration enabled, the chargeable days start at unit creation, or at the
/// owner's start residing date when that owner opens the history, and tenant
/// sessions split the remaining days from the owner. A session end date is
/// exclusive; uncovered days after a session are assigned to the owner.
pub fn split_monthly_dues(
    monthly_amount: Decimal,
    period_start: NaiveDate,
    unit_created_on: Option<NaiveDate>,
    spans: &[OccupancySpan],
    proration_enabled: bool,
    accrued_on: NaiveDate,
) -> Result<Vec<ProratedShare>, ProrationError> {
    if monthly_amount < Decimal::ZERO {
        return Err(ProrationError::NegativeAmount);
    }
    if monthly_amount.normalize().scale() > 2 {
        return Err(ProrationError::InvalidScale);
    }
    let Some(period_end) = last_day_of_month(period_start) else {
        return Ok(Vec::new());
    };
    let days_in_month = i64::from(period_end.day());
    let mut charge_start = unit_created_on.unwrap_or(period_start).max(period_start);
    // A unit whose first responsible party is its owner is charged from that owner's
    // start residing date (journey plan Q4): the days before it had a party to bill.
    // A tenant's first span keeps the days before it with the owner (Q9), so only an
    // owner span that opens the history moves the window.
    if let Some(first) = spans.iter().min_by_key(|span| span.starts_on) {
        if first.party == ResponsibleParty::Owner {
            charge_start = charge_start.max(first.starts_on);
        }
    }
    if charge_start > period_end {
        return Ok(Vec::new());
    }

    if !proration_enabled {
        if accrued_on < charge_start {
            return Ok(Vec::new());
        }
        let party = spans
            .iter()
            .find(|span| contains(span, accrued_on))
            .map(|span| span.party)
            .unwrap_or(ResponsibleParty::Owner);
        return Ok(vec![ProratedShare {
            party,
            amount: monthly_amount,
        }]);
    }

    let chargeable_days = period_end.signed_duration_since(charge_start).num_days() + 1;
    let mut role_days = [
        (ResponsibleParty::Owner, 0_i64),
        (ResponsibleParty::Tenant, 0_i64),
    ];
    let mut first_party = None;
    for offset in 0..chargeable_days {
        let Some(date) = charge_start.checked_add_days(Days::new(offset as u64)) else {
            continue;
        };
        let party = spans
            .iter()
            .find(|span| contains(span, date))
            .map(|span| span.party)
            .unwrap_or(ResponsibleParty::Owner);
        first_party.get_or_insert(party);
        let index = match party {
            ResponsibleParty::Owner => 0,
            ResponsibleParty::Tenant => 1,
        };
        role_days[index].1 += 1;
    }

    let active_amount = (monthly_amount * Decimal::from(chargeable_days)
        / Decimal::from(days_in_month))
    .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
    let parties = [ResponsibleParty::Owner, ResponsibleParty::Tenant];
    let active_parties: Vec<(ResponsibleParty, i64)> = parties
        .into_iter()
        .zip(role_days.into_iter().map(|(_, days)| days))
        .filter(|(_, days)| *days > 0)
        .collect();
    if active_parties.len() == 1 {
        return Ok(vec![ProratedShare {
            party: active_parties[0].0,
            amount: active_amount,
        }]);
    }

    let Some(first_party) = first_party else {
        return Ok(Vec::new());
    };
    let first_days = active_parties
        .iter()
        .find(|(party, _)| *party == first_party)
        .map(|(_, days)| *days)
        .unwrap_or(0);
    let first_amount = (monthly_amount * Decimal::from(first_days) / Decimal::from(days_in_month))
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
    let second_party = active_parties
        .iter()
        .find(|(party, _)| *party != first_party)
        .map(|(party, _)| *party);
    let Some(second_party) = second_party else {
        return Ok(vec![ProratedShare {
            party: first_party,
            amount: active_amount,
        }]);
    };
    Ok(vec![
        ProratedShare {
            party: first_party,
            amount: first_amount,
        },
        ProratedShare {
            party: second_party,
            amount: active_amount - first_amount,
        },
    ]
    .into_iter()
    .filter(|share| share.amount > Decimal::ZERO)
    .collect())
}

/// The amount owed for the days of `period_start`'s month that nobody was billed for,
/// counted from `start_date` (the responsible party's start residing date) to the end of
/// the month. A unit created later limits the chargeable days. Returns `None` when no
/// day of the month is chargeable or the amount is zero.
pub fn unbilled_days_amount(
    monthly_amount: Decimal,
    period_start: NaiveDate,
    unit_created_on: Option<NaiveDate>,
    start_date: NaiveDate,
) -> Result<Option<Decimal>, ProrationError> {
    if monthly_amount < Decimal::ZERO {
        return Err(ProrationError::NegativeAmount);
    }
    if monthly_amount.normalize().scale() > 2 {
        return Err(ProrationError::InvalidScale);
    }
    let Some(period_end) = last_day_of_month(period_start) else {
        return Ok(None);
    };
    let charge_start = start_date
        .max(unit_created_on.unwrap_or(period_start))
        .max(period_start);
    if charge_start > period_end {
        return Ok(None);
    }
    let days = period_end.signed_duration_since(charge_start).num_days() + 1;
    let days_in_month = i64::from(period_end.day());
    let amount = (monthly_amount * Decimal::from(days) / Decimal::from(days_in_month))
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
    Ok((amount > Decimal::ZERO).then_some(amount))
}

fn contains(span: &OccupancySpan, date: NaiveDate) -> bool {
    span.starts_on <= date && span.ends_before.is_none_or(|end| date < end)
}

fn last_day_of_month(date: NaiveDate) -> Option<NaiveDate> {
    let next_month = if date.month() == 12 {
        NaiveDate::from_ymd_opt(date.year() + 1, 1, 1)?
    } else {
        NaiveDate::from_ymd_opt(date.year(), date.month() + 1, 1)?
    };
    next_month.pred_opt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(value: &str) -> NaiveDate {
        NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("test date is valid")
    }

    fn money(value: &str) -> Decimal {
        Decimal::from_str_exact(value).expect("test amount is valid")
    }

    #[test]
    fn mid_month_move_in_splits_by_actual_october_days() {
        let spans = [OccupancySpan {
            party: ResponsibleParty::Tenant,
            starts_on: date("2026-10-11"),
            ends_before: None,
        }];
        let shares = split_monthly_dues(
            money("1400.00"),
            date("2026-10-01"),
            None,
            &spans,
            true,
            date("2026-10-20"),
        )
        .expect("valid amount");
        assert_eq!(
            shares[0],
            ProratedShare {
                party: ResponsibleParty::Owner,
                amount: money("451.61")
            }
        );
        assert_eq!(
            shares[1],
            ProratedShare {
                party: ResponsibleParty::Tenant,
                amount: money("948.39")
            }
        );
        assert_eq!(
            shares.iter().map(|share| share.amount).sum::<Decimal>(),
            money("1400.00")
        );
    }

    #[test]
    fn unit_creation_limits_charge_to_the_remaining_calendar_days() {
        let shares = split_monthly_dues(
            money("1800.00"),
            date("2026-11-01"),
            Some(date("2026-11-16")),
            &[],
            true,
            date("2026-11-20"),
        )
        .expect("valid amount");
        assert_eq!(
            shares,
            vec![ProratedShare {
                party: ResponsibleParty::Owner,
                amount: money("900.00")
            }]
        );
    }

    #[test]
    fn a_primary_resident_who_starts_mid_month_is_charged_from_that_day() {
        // F3: A-1 gets its first owner with a start residing date of 2026-11-02, and
        // Kasım 2026 is accrued afterwards. The day before had no responsible party.
        let spans = [OccupancySpan {
            party: ResponsibleParty::Owner,
            starts_on: date("2026-11-02"),
            ends_before: None,
        }];
        let shares = split_monthly_dues(
            money("1500.00"),
            date("2026-11-01"),
            None,
            &spans,
            true,
            date("2026-11-02"),
        )
        .expect("valid amount");
        assert_eq!(
            shares,
            vec![ProratedShare {
                party: ResponsibleParty::Owner,
                amount: money("1450.00")
            }]
        );
    }

    #[test]
    fn days_before_a_tenant_start_stay_with_the_owner_who_opened_the_month() {
        let spans = [
            OccupancySpan {
                party: ResponsibleParty::Owner,
                starts_on: date("2026-10-01"),
                ends_before: Some(date("2026-10-11")),
            },
            OccupancySpan {
                party: ResponsibleParty::Tenant,
                starts_on: date("2026-10-11"),
                ends_before: None,
            },
        ];
        let shares = split_monthly_dues(
            money("1500.00"),
            date("2026-10-01"),
            None,
            &spans,
            true,
            date("2026-10-20"),
        )
        .expect("valid amount");
        assert_eq!(
            shares,
            vec![
                ProratedShare {
                    party: ResponsibleParty::Owner,
                    amount: money("483.87")
                },
                ProratedShare {
                    party: ResponsibleParty::Tenant,
                    amount: money("1016.13")
                },
            ]
        );
    }

    #[test]
    fn move_out_end_date_is_exclusive_and_first_share_rounds_half_away() {
        let spans = [OccupancySpan {
            party: ResponsibleParty::Tenant,
            starts_on: date("2026-10-01"),
            ends_before: Some(date("2026-10-21")),
        }];
        let shares = split_monthly_dues(
            money("1400.00"),
            date("2026-10-01"),
            None,
            &spans,
            true,
            date("2026-10-25"),
        )
        .expect("valid amount");
        assert_eq!(
            shares[0],
            ProratedShare {
                party: ResponsibleParty::Tenant,
                amount: money("903.23")
            }
        );
        assert_eq!(
            shares[1],
            ProratedShare {
                party: ResponsibleParty::Owner,
                amount: money("496.77")
            }
        );
    }

    #[test]
    fn disabled_proration_keeps_the_current_full_month_rule() {
        let spans = [OccupancySpan {
            party: ResponsibleParty::Tenant,
            starts_on: date("2026-10-11"),
            ends_before: None,
        }];
        let shares = split_monthly_dues(
            money("1400.00"),
            date("2026-10-01"),
            None,
            &spans,
            false,
            date("2026-10-20"),
        )
        .expect("valid amount");
        assert_eq!(
            shares,
            vec![ProratedShare {
                party: ResponsibleParty::Tenant,
                amount: money("1400.00")
            }]
        );
    }

    #[test]
    fn unbilled_days_run_from_the_start_date_to_the_month_end() {
        let amount = unbilled_days_amount(
            money("1500.00"),
            date("2026-10-01"),
            None,
            date("2026-10-11"),
        )
        .expect("valid amount");
        assert_eq!(amount, Some(money("1016.13")));
    }

    #[test]
    fn unbilled_days_before_the_month_charge_the_whole_month() {
        let amount = unbilled_days_amount(
            money("1500.00"),
            date("2026-11-01"),
            None,
            date("2026-10-11"),
        )
        .expect("valid amount");
        assert_eq!(amount, Some(money("1500.00")));
    }

    #[test]
    fn unbilled_days_after_the_month_charge_nothing() {
        let amount = unbilled_days_amount(
            money("1500.00"),
            date("2026-10-01"),
            None,
            date("2026-11-02"),
        )
        .expect("valid amount");
        assert_eq!(amount, None);
    }

    #[test]
    fn unbilled_days_respect_the_unit_creation_date() {
        let amount = unbilled_days_amount(
            money("1500.00"),
            date("2026-10-01"),
            Some(date("2026-10-16")),
            date("2026-10-11"),
        )
        .expect("valid amount");
        assert_eq!(amount, Some(money("774.19")));
    }

    #[test]
    fn split_shares_always_add_up_to_the_prorated_total() {
        let owner_then_tenant = |split: &str| {
            [OccupancySpan {
                party: ResponsibleParty::Tenant,
                starts_on: date(split),
                ends_before: None,
            }]
        };
        for (month_start, last_day) in [("2026-02-01", 28), ("2026-04-01", 30), ("2026-10-01", 31)]
        {
            for amount in [
                "1000.00", "1400.00", "100.01", "333.33", "0.05", "10.01", "7.77",
            ] {
                for day in 2..=last_day {
                    let split = format!("{}-{day:02}", &month_start[..7]);
                    let shares = split_monthly_dues(
                        money(amount),
                        date(month_start),
                        None,
                        &owner_then_tenant(&split),
                        true,
                        date(&split),
                    )
                    .expect("valid amount");
                    let total: Decimal = shares.iter().map(|s| s.amount).sum();
                    assert_eq!(total, money(amount), "{amount} split on {split}");
                }
            }
        }
    }

    #[test]
    fn without_proration_an_unoccupied_day_is_billed_to_the_owner() {
        let spans = [OccupancySpan {
            party: ResponsibleParty::Tenant,
            starts_on: date("2026-10-11"),
            ends_before: None,
        }];
        let shares = split_monthly_dues(
            money("1400.00"),
            date("2026-10-01"),
            None,
            &spans,
            false,
            date("2026-10-05"),
        )
        .expect("valid amount");
        assert_eq!(
            shares,
            vec![ProratedShare {
                party: ResponsibleParty::Owner,
                amount: money("1400.00")
            }]
        );
    }

    #[test]
    fn a_negative_monthly_amount_is_rejected_with_and_without_proration() {
        for proration in [true, false] {
            assert_eq!(
                split_monthly_dues(
                    money("-1.00"),
                    date("2026-10-01"),
                    None,
                    &[],
                    proration,
                    date("2026-10-05"),
                ),
                Err(ProrationError::NegativeAmount)
            );
        }
    }
}
