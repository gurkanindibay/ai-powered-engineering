//! Clock port: the single source of "now" for date-dependent rules.
//!
//! Effective-date validation, due dates, late fees, payment value dates and the
//! scheduled jobs read the current instant through [`Clock`] instead of calling
//! the system clock directly. Production wires [`SystemClock`]; backends built
//! with the `e2e` feature may wire the controllable E2E clock instead
//! (`crate::e2e_clock::E2eClock`), and tests supply their own fixed clock.
//!
//! Calendar dates are always taken in the site's time zone: an Istanbul
//! evening after 21:00 UTC is already the next local day, and on the last day
//! of a month already the next month (see [`local_date`]).

use chrono::{DateTime, NaiveDate, Utc};

/// The time zone used when a site's configured zone is missing or invalid.
pub const DEFAULT_TIMEZONE: chrono_tz::Tz = chrono_tz::Europe::Istanbul;

/// Source of the current instant.
pub trait Clock: Send + Sync + std::fmt::Debug {
    /// The current instant in UTC.
    fn now(&self) -> DateTime<Utc>;

    /// Today's calendar date in `timezone` (an IANA name such as `Europe/Istanbul`).
    fn today_in(&self, timezone: &str) -> NaiveDate {
        local_date(timezone, self.now())
    }
}

/// The production clock: the operating system's wall clock.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// The calendar date of `at` in `timezone`; an unknown zone falls back to
/// [`DEFAULT_TIMEZONE`].
pub fn local_date(timezone: &str, at: DateTime<Utc>) -> NaiveDate {
    let tz: chrono_tz::Tz = timezone.parse().unwrap_or(DEFAULT_TIMEZONE);
    at.with_timezone(&tz).date_naive()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[derive(Debug)]
    struct FixedClock(DateTime<Utc>);

    impl Clock for FixedClock {
        fn now(&self) -> DateTime<Utc> {
            self.0
        }
    }

    fn utc(month: u32, day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, month, day, hour, minute, 0)
            .single()
            .unwrap_or(DateTime::<Utc>::MIN_UTC)
    }

    fn date(month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, month, day).unwrap_or(NaiveDate::MIN)
    }

    #[test]
    fn istanbul_month_boundary_is_three_hours_before_utc_midnight() {
        // 2026-11-30 23:30 Europe/Istanbul is 20:30 UTC: still November locally.
        let before = FixedClock(utc(11, 30, 20, 30));
        assert_eq!(before.today_in("Europe/Istanbul"), date(11, 30));
        // 2026-12-01 00:30 Europe/Istanbul is 21:30 UTC on November 30.
        let after = FixedClock(utc(11, 30, 21, 30));
        assert_eq!(after.today_in("Europe/Istanbul"), date(12, 1));
        assert_eq!(after.today_in("UTC"), date(11, 30));
    }

    #[test]
    fn local_midnight_starts_the_new_day_exactly() {
        assert_eq!(
            local_date("Europe/Istanbul", utc(11, 30, 20, 59)),
            date(11, 30)
        );
        assert_eq!(
            local_date("Europe/Istanbul", utc(11, 30, 21, 0)),
            date(12, 1)
        );
    }

    #[test]
    fn month_end_and_leap_day_matrix_uses_the_site_calendar() {
        let cases = [
            ((2024, 2, 28, 20, 59), (2024, 2, 28)),
            ((2024, 2, 28, 21, 0), (2024, 2, 29)),
            ((2024, 2, 29, 20, 59), (2024, 2, 29)),
            ((2024, 2, 29, 21, 0), (2024, 3, 1)),
            ((2025, 2, 28, 21, 0), (2025, 3, 1)),
            ((2026, 4, 29, 21, 0), (2026, 4, 30)),
            ((2026, 4, 30, 21, 0), (2026, 5, 1)),
            ((2026, 1, 30, 21, 0), (2026, 1, 31)),
            ((2026, 1, 31, 21, 0), (2026, 2, 1)),
        ];

        for ((year, month, day, hour, minute), (expected_year, expected_month, expected_day)) in
            cases
        {
            let instant = Utc
                .with_ymd_and_hms(year, month, day, hour, minute, 0)
                .single()
                .expect("valid UTC boundary instant");
            assert_eq!(
                local_date("Europe/Istanbul", instant),
                NaiveDate::from_ymd_opt(expected_year, expected_month, expected_day)
                    .expect("valid expected local date"),
                "UTC {year}-{month:02}-{day:02} {hour:02}:{minute:02}"
            );
        }
    }

    #[test]
    fn an_unknown_time_zone_falls_back_to_istanbul() {
        assert_eq!(local_date("Not/AZone", utc(11, 30, 21, 30)), date(12, 1));
    }

    #[test]
    fn the_system_clock_follows_the_wall_clock() {
        let drift = (Utc::now() - SystemClock.now()).num_seconds().abs();
        assert!(drift < 5);
    }
}
