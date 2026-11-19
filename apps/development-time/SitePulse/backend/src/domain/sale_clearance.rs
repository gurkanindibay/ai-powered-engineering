//! Sale clearance: what stays with the seller and what goes to the buyer at a title transfer.
//!
//! Pure rules, no I/O. Debt that exists at the sale stays with the seller; a capital
//! installment goes to the owner on record when it is accrued, so installments not yet
//! accrued reach the buyer unless an approved seller-pays override says otherwise. The
//! operational dues of the month of an owner-occupied sale are split by calendar days.

use chrono::{Datelike, NaiveDate};
use rust_decimal::{Decimal, RoundingStrategy};

/// The sentence every clearance statement carries.
pub const CLEARANCE_NOTICE: &str = "Existing debt stays with the seller. Capital installments \
that are not yet accrued are billed to the owner on record when they accrue, so they go to the \
buyer unless a seller-pays override is approved by a second manager.";

/// Who is billed for a capital installment that accrues after the sale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallmentDebtor {
    /// The owner on record at accrual (the default).
    OwnerOnRecord,
    /// The seller named by an approved override.
    Seller,
}

/// Status of a seller-pays override request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverrideStatus {
    Pending,
    Approved,
    Rejected,
}

impl OverrideStatus {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "PENDING" => Some(Self::Pending),
            "APPROVED" => Some(Self::Approved),
            "REJECTED" => Some(Self::Rejected),
            _ => None,
        }
    }
}

/// Only an approved override changes the default; pending and rejected requests leave it.
pub fn installment_debtor(override_status: Option<OverrideStatus>) -> InstallmentDebtor {
    match override_status {
        Some(OverrideStatus::Approved) => InstallmentDebtor::Seller,
        _ => InstallmentDebtor::OwnerOnRecord,
    }
}

/// Splits one month's principal between seller and buyer by calendar days.
///
/// The seller is responsible up to the day before `transfer_date`, the buyer from
/// `transfer_date` on. The seller's share is rounded to the cent and the buyer receives the
/// remainder, so the two shares always add up to `principal`. Returns `None` when the transfer
/// is not inside the month after its first day (nothing to split).
pub fn split_month_by_days(
    principal: Decimal,
    period_first_day: NaiveDate,
    transfer_date: NaiveDate,
) -> Option<(Decimal, Decimal)> {
    let next_month = if period_first_day.month() == 12 {
        NaiveDate::from_ymd_opt(period_first_day.year() + 1, 1, 1)?
    } else {
        NaiveDate::from_ymd_opt(period_first_day.year(), period_first_day.month() + 1, 1)?
    };
    let days_in_month = (next_month - period_first_day).num_days();
    let seller_days = (transfer_date - period_first_day).num_days();
    if principal <= Decimal::ZERO || seller_days <= 0 || seller_days >= days_in_month {
        return None;
    }
    let seller = (principal * Decimal::from(seller_days) / Decimal::from(days_in_month))
        .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero);
    let buyer = principal - seller;
    if seller <= Decimal::ZERO || buyer <= Decimal::ZERO {
        return None;
    }
    Some((seller, buyer))
}

/// Escapes one CSV cell: quotes when needed and neutralises spreadsheet formulas.
pub fn csv_cell(value: &str) -> String {
    let guarded = if value.starts_with(['=', '+', '-', '@']) {
        format!("'{value}")
    } else {
        value.to_string()
    };
    if guarded.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", guarded.replace('"', "\"\""))
    } else {
        guarded
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).expect("valid date")
    }

    fn dec(raw: &str) -> Decimal {
        Decimal::from_str_exact(raw).expect("valid decimal")
    }

    #[test]
    fn splits_a_thirty_day_month() {
        let split = split_month_by_days(dec("1500.00"), date(2026, 11, 1), date(2026, 11, 5));
        assert_eq!(split, Some((dec("200.00"), dec("1300.00"))));
    }

    #[test]
    fn splits_a_thirty_one_day_month_with_the_remainder_to_the_buyer() {
        let split = split_month_by_days(dec("1500.00"), date(2026, 12, 1), date(2026, 12, 20));
        assert_eq!(split, Some((dec("919.35"), dec("580.65"))));
    }

    #[test]
    fn no_split_on_the_first_day() {
        assert_eq!(
            split_month_by_days(dec("1500.00"), date(2026, 12, 1), date(2026, 12, 1)),
            None
        );
    }

    #[test]
    fn only_an_approved_override_moves_the_installment_to_the_seller() {
        assert_eq!(installment_debtor(None), InstallmentDebtor::OwnerOnRecord);
        assert_eq!(
            installment_debtor(Some(OverrideStatus::Pending)),
            InstallmentDebtor::OwnerOnRecord
        );
        assert_eq!(
            installment_debtor(Some(OverrideStatus::Rejected)),
            InstallmentDebtor::OwnerOnRecord
        );
        assert_eq!(
            installment_debtor(Some(OverrideStatus::Approved)),
            InstallmentDebtor::Seller
        );
    }

    #[test]
    fn csv_cells_are_quoted_and_formula_safe() {
        assert_eq!(csv_cell("plain"), "plain");
        assert_eq!(csv_cell("a,b"), "\"a,b\"");
        assert_eq!(csv_cell("=SUM(A1)"), "'=SUM(A1)");
    }
}
