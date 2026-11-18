//! Canonical billing period (STORY-07-08).
//!
//! A billing period is one calendar month identified by the key `YYYY-MM`. The Turkish
//! label ("Ekim 2026") is derived from the key for display only; every other spelling of
//! the same month resolves to the same key or is rejected.

use chrono::{Datelike, NaiveDate};

use super::text::fold_turkish;

/// Days after the end of a period's month in which its due date may still fall.
pub const DUE_DATE_GRACE_DAYS: u64 = 30;

const TURKISH_MONTHS: [&str; 12] = [
    "Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim",
    "Kasım", "Aralık",
];

const ASCII_MONTHS: [&str; 12] = [
    "ocak", "subat", "mart", "nisan", "mayis", "haziran", "temmuz", "agustos", "eylul", "ekim",
    "kasim", "aralik",
];

const ENGLISH_MONTHS: [&str; 12] = [
    "january",
    "february",
    "march",
    "april",
    "may",
    "june",
    "july",
    "august",
    "september",
    "october",
    "november",
    "december",
];

/// One calendar month used as a billing period.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BillingPeriod {
    year: i32,
    month: u32,
}

impl BillingPeriod {
    pub fn new(year: i32, month: u32) -> Option<Self> {
        ((1..=12).contains(&month) && (1900..=2999).contains(&year)).then_some(Self { year, month })
    }

    pub fn of_date(date: NaiveDate) -> Self {
        Self {
            year: date.year(),
            month: date.month(),
        }
    }

    /// Resolves a key ("2026-10"), a Turkish or English label ("Ekim 2026", "ekim 2026",
    /// "EKİM 2026", "October 2026") or "10/2026" to the period. Anything else is an error.
    pub fn parse(text: &str) -> Result<Self, String> {
        let folded = fold_turkish(text.trim());
        let invalid = || {
            format!(
                "'{}' is not a billing period; use the key YYYY-MM, for example 2026-10",
                text.trim()
            )
        };
        let digits = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit());
        let numeric = |year: &str, month: &str| {
            if year.len() == 4 && digits(year) && (1..=2).contains(&month.len()) && digits(month) {
                Self::new(year.parse().ok()?, month.parse().ok()?)
            } else {
                None
            }
        };
        if let Some((a, b)) = folded.split_once('-') {
            return numeric(a, b).ok_or_else(invalid);
        }
        if let Some((a, b)) = folded.split_once('/') {
            return numeric(b, a).ok_or_else(invalid);
        }
        let mut parts = folded.split_whitespace();
        let (Some(name), Some(year), None) = (parts.next(), parts.next(), parts.next()) else {
            return Err(invalid());
        };
        if year.len() != 4 || !digits(year) {
            return Err(invalid());
        }
        let index = ASCII_MONTHS
            .iter()
            .position(|m| *m == name)
            .or_else(|| ENGLISH_MONTHS.iter().position(|m| *m == name))
            .ok_or_else(invalid)?;
        let month = u32::try_from(index).map_or(0, |i| i + 1);
        Self::new(year.parse().map_err(|_| invalid())?, month).ok_or_else(invalid)
    }

    pub fn key(&self) -> String {
        format!("{:04}-{:02}", self.year, self.month)
    }

    pub fn label(&self) -> String {
        let name = TURKISH_MONTHS
            .get(self.month as usize - 1)
            .copied()
            .unwrap_or("?");
        format!("{} {}", name, self.year)
    }

    pub fn first_day(&self) -> NaiveDate {
        NaiveDate::from_ymd_opt(self.year, self.month, 1).unwrap_or(NaiveDate::MIN)
    }

    pub fn last_day(&self) -> NaiveDate {
        let (year, month) = if self.month == 12 {
            (self.year + 1, 1)
        } else {
            (self.year, self.month + 1)
        };
        NaiveDate::from_ymd_opt(year, month, 1)
            .and_then(|d| d.pred_opt())
            .unwrap_or(NaiveDate::MAX)
    }

    /// The due date must fall in the period's month or within the grace days after it.
    pub fn accepts_due_date(&self, due: NaiveDate) -> bool {
        due >= self.first_day() && due <= self.last_day() + chrono::Days::new(DUE_DATE_GRACE_DAYS)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_spelling_of_a_month_resolves_to_one_key() {
        for text in [
            "2026-10",
            "Ekim 2026",
            "ekim 2026",
            "EKİM 2026",
            "EKIM  2026",
            "October 2026",
            "10/2026",
        ] {
            assert_eq!(
                BillingPeriod::parse(text).map(|p| p.key()).as_deref(),
                Ok("2026-10"),
                "{text}"
            );
        }
        assert_eq!(BillingPeriod::parse("2026-1").unwrap().key(), "2026-01");
        assert_eq!(
            BillingPeriod::parse("Şubat 2027").unwrap().label(),
            "Şubat 2027"
        );
        assert_eq!(BillingPeriod::parse("Subat 2027").unwrap().key(), "2027-02");
    }

    #[test]
    fn unparseable_text_is_rejected() {
        for text in [
            "",
            "Test Dönemi",
            "2026-13",
            "2026-00",
            "Ekim",
            "Ekim 26",
            "2026",
        ] {
            assert!(BillingPeriod::parse(text).is_err(), "{text}");
        }
    }

    #[test]
    fn due_date_must_be_in_the_month_or_the_grace_days_after() {
        let october = BillingPeriod::parse("2026-10").unwrap();
        let day = |m, d| NaiveDate::from_ymd_opt(2026, m, d).unwrap();
        assert!(october.accepts_due_date(day(10, 1)));
        assert!(october.accepts_due_date(day(11, 30)));
        assert!(!october.accepts_due_date(day(12, 15)));
        assert!(!october.accepts_due_date(day(9, 30)));
        assert_eq!(
            BillingPeriod::new(2026, 12).unwrap().last_day(),
            day(12, 31)
        );
    }
}
