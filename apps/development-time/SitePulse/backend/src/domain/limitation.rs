//! The 5-year limitation of dues claims (TBK 147/1, verify), SPEC-009 R8.
//!
//! Periodic payments such as common expenses become time-barred five years after
//! they fall due. An item within six months of that date is "approaching".

use chrono::{Months, NaiveDate};

pub const LIMITATION_YEARS: u32 = 5;
pub const WARNING_MONTHS: u32 = 6;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LimitationStatus {
    Running,
    Approaching,
    Expired,
}

impl LimitationStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            LimitationStatus::Running => "RUNNING",
            LimitationStatus::Approaching => "APPROACHING",
            LimitationStatus::Expired => "EXPIRED",
        }
    }
}

pub fn limitation_date(due_date: NaiveDate) -> NaiveDate {
    due_date
        .checked_add_months(Months::new(LIMITATION_YEARS * 12))
        .unwrap_or(NaiveDate::MAX)
}

pub fn status(due_date: NaiveDate, as_of: NaiveDate) -> LimitationStatus {
    let limit = limitation_date(due_date);
    if as_of >= limit {
        return LimitationStatus::Expired;
    }
    let warn_from = limit
        .checked_sub_months(Months::new(WARNING_MONTHS))
        .unwrap_or(limit);
    if as_of >= warn_from {
        LimitationStatus::Approaching
    } else {
        LimitationStatus::Running
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap_or_default()
    }

    #[test]
    fn status_moves_from_running_to_expired() {
        let due = date(2022, 1, 10);
        assert_eq!(limitation_date(due), date(2027, 1, 10));
        assert_eq!(status(due, date(2026, 7, 9)), LimitationStatus::Running);
        assert_eq!(
            status(due, date(2026, 7, 10)),
            LimitationStatus::Approaching
        );
        assert_eq!(status(due, date(2027, 1, 10)), LimitationStatus::Expired);
    }
}
