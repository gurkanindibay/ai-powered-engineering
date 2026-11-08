//! KMK 22 tenant joint liability (SPEC-009 R3, verify with counsel).
//!
//! A tenant answers for the owner's share of common expenses and advances
//! jointly with the owner, but only up to the rent the tenant still owes the
//! owner. SitePulse caps the claimable amount at the unpaid rent: the rent
//! months due up to today that are not paid, plus the next instalment.

use chrono::{Datelike, Months, NaiveDate};
use rust_decimal::Decimal;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lease {
    pub monthly_rent: Decimal,
    pub lease_start: NaiveDate,
    pub lease_end: Option<NaiveDate>,
    /// The last day the tenant has paid rent for, if known.
    pub rent_paid_through: Option<NaiveDate>,
}

/// Rent due dates fall on the lease start's day of month (clamped to the month end).
fn rent_dates(lease: &Lease, until: NaiveDate) -> Vec<NaiveDate> {
    let mut out = Vec::new();
    for i in 0..600u32 {
        let Some(date) = lease.lease_start.checked_add_months(Months::new(i)) else {
            break;
        };
        if date > until || lease.lease_end.is_some_and(|end| date > end) {
            break;
        }
        out.push(date);
    }
    out
}

/// Rent months that are due on or before `as_of` and not covered by
/// `rent_paid_through`, plus the next instalment while the lease runs.
pub fn claimable_rent_months(lease: &Lease, as_of: NaiveDate) -> u32 {
    let paid_through = lease.rent_paid_through;
    let horizon = as_of.checked_add_months(Months::new(1)).unwrap_or(as_of);
    let dates = rent_dates(lease, horizon);
    let unpaid = dates
        .iter()
        .filter(|d| paid_through.is_none_or(|p| **d > p))
        .count();
    // A tenant whose rent is paid through a later month owes nothing now.
    u32::try_from(unpaid).unwrap_or(u32::MAX)
}

/// The cap on what can be claimed from the tenant for the owner's debts.
pub fn rent_cap(lease: &Lease, as_of: NaiveDate) -> Decimal {
    lease.monthly_rent * Decimal::from(claimable_rent_months(lease, as_of))
}

/// The amount of `owner_open_operational` that may be claimed from the tenant.
pub fn claimable_from_tenant(
    lease: &Lease,
    owner_open_operational: Decimal,
    as_of: NaiveDate,
) -> Decimal {
    owner_open_operational
        .max(Decimal::ZERO)
        .min(rent_cap(lease, as_of))
}

/// Whether the lease is in force on `date`.
pub fn is_active_on(lease: &Lease, date: NaiveDate) -> bool {
    lease.lease_start <= date && lease.lease_end.is_none_or(|e| e >= date)
}

/// Month label of a rent date (for certificates): "2027-03".
pub fn rent_month_label(date: NaiveDate) -> String {
    format!("{:04}-{:02}", date.year(), date.month())
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
    fn lease(paid: Option<NaiveDate>) -> Lease {
        Lease {
            monthly_rent: d("15000"),
            lease_start: date(2027, 1, 5),
            lease_end: None,
            rent_paid_through: paid,
        }
    }

    #[test]
    fn the_cap_is_the_unpaid_rent_plus_the_next_instalment() {
        // As of 20 March: rent dates 5 Jan, 5 Feb, 5 Mar are due; 5 Apr is next.
        let as_of = date(2027, 3, 20);
        assert_eq!(claimable_rent_months(&lease(None), as_of), 4);
        assert_eq!(
            claimable_rent_months(&lease(Some(date(2027, 3, 31))), as_of),
            1,
            "only the next instalment is open"
        );
        assert_eq!(
            claimable_rent_months(&lease(Some(date(2027, 4, 30))), as_of),
            0
        );
        let l = lease(Some(date(2027, 3, 31)));
        assert_eq!(claimable_from_tenant(&l, d("40000"), as_of), d("15000"));
        assert_eq!(claimable_from_tenant(&l, d("2000"), as_of), d("2000"));
    }

    #[test]
    fn an_ended_lease_stops_accruing_rent() {
        let l = Lease {
            lease_end: Some(date(2027, 2, 28)),
            ..lease(Some(date(2027, 1, 31)))
        };
        assert_eq!(claimable_rent_months(&l, date(2027, 6, 1)), 1);
        assert!(!is_active_on(&l, date(2027, 3, 1)));
        assert!(is_active_on(&l, date(2027, 2, 1)));
        assert_eq!(rent_month_label(date(2027, 3, 5)), "2027-03");
    }
}
