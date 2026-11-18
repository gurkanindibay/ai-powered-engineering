//! A site's accrual schedule, STORY-07-10: which day of the month dues are accrued and due,
//! how long a late fee is held back, and how far back the scheduler catches up.

use chrono::{Datelike, NaiveDate};
use serde::{Deserialize, Serialize};

use crate::domain::billing_period::BillingPeriod;

/// Most grace days a site may grant: past a month it would no longer be a grace period.
pub const MAX_GRACE_DAYS: u32 = 30;
/// Most months the catch-up may reach back.
pub const MAX_CATCH_UP_MONTHS: u32 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccrualSchedule {
    /// Day of month the period is accrued (1 to 28; the scheduler accrues on or after it).
    pub accrual_day: u32,
    /// Day of month the dues are due; a day beyond the month's end falls on its last day.
    pub due_day: u32,
    /// Days after the due date before a late fee applies (0 = none).
    pub grace_days: u32,
    /// Catch-up never accrues more than this many periods back.
    pub catch_up_limit_months: u32,
    /// First day the site was billed; the start of catch-up when no period exists yet.
    pub go_live_date: Option<NaiveDate>,
}

impl Default for AccrualSchedule {
    fn default() -> Self {
        Self {
            accrual_day: 1,
            due_day: 15,
            grace_days: 0,
            catch_up_limit_months: 12,
            go_live_date: None,
        }
    }
}

/// The periods a run must accrue, and the ones the limit left out.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CatchUpPlan {
    pub periods: Vec<BillingPeriod>,
    /// Earliest and latest missing period dropped because of the limit.
    pub limited: Option<(BillingPeriod, BillingPeriod)>,
}

impl AccrualSchedule {
    pub fn validate(&self) -> Result<(), String> {
        if !(1..=28).contains(&self.accrual_day) {
            return Err("accrual_day must be between 1 and 28".to_string());
        }
        if !(1..=31).contains(&self.due_day) {
            return Err("due_day must be between 1 and 31".to_string());
        }
        if self.grace_days > MAX_GRACE_DAYS {
            return Err(format!("grace_days must be at most {MAX_GRACE_DAYS}"));
        }
        if !(1..=MAX_CATCH_UP_MONTHS).contains(&self.catch_up_limit_months) {
            return Err(format!(
                "catch_up_limit_months must be between 1 and {MAX_CATCH_UP_MONTHS}"
            ));
        }
        Ok(())
    }

    /// The due date of a period: the due day, or the month's last day when it is shorter.
    pub fn due_date_for(&self, period: BillingPeriod) -> NaiveDate {
        let last = period.last_day();
        period
            .first_day()
            .with_day(self.due_day.min(last.day()))
            .unwrap_or(last)
    }

    /// The newest period that is already accruable on `local_date`: the current month once
    /// the accrual day has come, the previous one before.
    pub fn current_period(&self, local_date: NaiveDate) -> BillingPeriod {
        let this = BillingPeriod::of_date(local_date);
        if local_date.day() >= self.accrual_day {
            this
        } else {
            previous_period(this)
        }
    }

    /// Periods to accrue on `local_date`, oldest first. `first_period` is the site's earliest
    /// accrued period; `accrued` tells whether a period already carries dues for the site.
    /// Without either a first period or a go-live date only the current period is planned.
    pub fn catch_up_plan(
        &self,
        local_date: NaiveDate,
        first_period: Option<BillingPeriod>,
        accrued: impl Fn(BillingPeriod) -> bool,
    ) -> CatchUpPlan {
        let current = self.current_period(local_date);
        let start = first_period
            .or_else(|| self.go_live_date.map(BillingPeriod::of_date))
            .unwrap_or(current);
        let mut missing = Vec::new();
        let mut cursor = start;
        while cursor <= current {
            // The current period is always planned: units added since are accrued per unit.
            if cursor == current || !accrued(cursor) {
                missing.push(cursor);
            }
            cursor = next_period(cursor);
        }
        let keep = self.catch_up_limit_months as usize;
        if missing.len() <= keep {
            return CatchUpPlan {
                periods: missing,
                limited: None,
            };
        }
        let cut = missing.len() - keep;
        let limited = missing.first().copied().zip(missing.get(cut - 1).copied());
        CatchUpPlan {
            periods: missing.split_off(cut),
            limited,
        }
    }
}

pub fn next_period(period: BillingPeriod) -> BillingPeriod {
    BillingPeriod::of_date(period.last_day().succ_opt().unwrap_or(period.last_day()))
}

pub fn previous_period(period: BillingPeriod) -> BillingPeriod {
    BillingPeriod::of_date(period.first_day().pred_opt().unwrap_or(period.first_day()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(key: &str) -> BillingPeriod {
        BillingPeriod::parse(key).unwrap()
    }

    fn day(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn due_day_beyond_month_end_falls_on_last_day() {
        let s = AccrualSchedule {
            due_day: 31,
            ..AccrualSchedule::default()
        };
        assert_eq!(s.due_date_for(p("2027-02")), day(2027, 2, 28));
        assert_eq!(s.due_date_for(p("2028-02")), day(2028, 2, 29));
        assert_eq!(s.due_date_for(p("2026-11")), day(2026, 11, 30));
    }

    #[test]
    fn catch_up_lists_missing_periods_oldest_first() {
        let s = AccrualSchedule::default();
        let plan = s.catch_up_plan(day(2026, 11, 2), Some(p("2026-08")), |x| x == p("2026-08"));
        assert_eq!(plan.periods, vec![p("2026-09"), p("2026-10"), p("2026-11")]);
        assert_eq!(plan.limited, None);
    }

    #[test]
    fn catch_up_stops_at_the_limit() {
        let s = AccrualSchedule {
            go_live_date: Some(day(2025, 1, 1)),
            ..AccrualSchedule::default()
        };
        let plan = s.catch_up_plan(day(2026, 11, 2), None, |_| false);
        assert_eq!(plan.periods.len(), 12);
        assert_eq!(plan.periods.first(), Some(&p("2025-12")));
        assert_eq!(plan.periods.last(), Some(&p("2026-11")));
        assert_eq!(plan.limited, Some((p("2025-01"), p("2025-11"))));
    }

    #[test]
    fn before_the_accrual_day_the_current_month_is_not_yet_accrued() {
        let s = AccrualSchedule {
            accrual_day: 5,
            ..AccrualSchedule::default()
        };
        assert_eq!(s.current_period(day(2026, 11, 4)), p("2026-10"));
        assert_eq!(s.current_period(day(2026, 11, 5)), p("2026-11"));
        assert_eq!(s.current_period(day(2026, 1, 2)), p("2025-12"));
    }

    #[test]
    fn invalid_values_are_rejected() {
        let mut s = AccrualSchedule::default();
        assert!(s.validate().is_ok());
        s.accrual_day = 29;
        assert!(s.validate().is_err());
        s = AccrualSchedule {
            grace_days: 31,
            ..AccrualSchedule::default()
        };
        assert!(s.validate().is_err());
    }
}
