//! E2E-only deterministic scheduler clock and control endpoint.

use chrono::{DateTime, Utc};

/// Fixture instant published by the E2E control endpoint; `None` until a runner sets the date.
#[cfg(feature = "e2e")]
static FIXTURE_NOW: RwLock<Option<DateTime<Utc>>> = RwLock::new(None);

/// Current instant for date-dependent reads and writes.
///
/// Returns the E2E fixture time once a runner has set the clock through the control endpoint,
/// otherwise the system clock. Normal backend builds always use the system clock.
pub fn now_utc() -> DateTime<Utc> {
    #[cfg(feature = "e2e")]
    if let Ok(guard) = FIXTURE_NOW.read() {
        if let Some(fixture) = *guard {
            return fixture;
        }
    }
    Utc::now()
}

#[cfg(feature = "e2e")]
use chrono::NaiveDate;
#[cfg(feature = "e2e")]
use serde::{Deserialize, Serialize};
#[cfg(feature = "e2e")]
use std::sync::{
    atomic::{AtomicBool, Ordering},
    RwLock,
};

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum E2eClockError {
    #[error("SITEPULSE_E2E requires a backend built with the e2e feature")]
    FeatureRequired,
    #[error("SITEPULSE_E2E cannot be enabled in production")]
    ProductionMode,
    #[error("E2E clock lock is unavailable")]
    LockUnavailable,
    #[error("E2E clock cannot advance to an earlier date")]
    CannotRewind,
    #[error("E2E clock is disabled")]
    Disabled,
    #[error("an E2E scheduler tick is already running")]
    TickInProgress,
    #[error("E2E scheduler tick failed: {0}")]
    Scheduler(String),
}

impl axum::response::IntoResponse for E2eClockError {
    fn into_response(self) -> axum::response::Response {
        use axum::http::StatusCode;
        let status = match &self {
            Self::CannotRewind => StatusCode::BAD_REQUEST,
            Self::Disabled => StatusCode::NOT_FOUND,
            Self::TickInProgress => StatusCode::CONFLICT,
            Self::FeatureRequired
            | Self::ProductionMode
            | Self::LockUnavailable
            | Self::Scheduler(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, self.to_string()).into_response()
    }
}

/// Checks that the requested E2E mode is compiled in and cannot be enabled in production.
pub fn validate_e2e_configuration() -> Result<bool, E2eClockError> {
    let enabled = std::env::var("SITEPULSE_E2E").is_ok_and(|value| value == "true");
    validate_requested_configuration(
        enabled,
        cfg!(feature = "e2e"),
        crate::state::AppStateInner::is_production(),
    )
}

fn validate_requested_configuration(
    enabled: bool,
    feature_compiled: bool,
    production: bool,
) -> Result<bool, E2eClockError> {
    if !enabled {
        return Ok(false);
    }
    if !feature_compiled {
        return Err(E2eClockError::FeatureRequired);
    }
    if production {
        return Err(E2eClockError::ProductionMode);
    }
    Ok(true)
}

#[cfg(test)]
mod configuration_tests {
    use super::validate_requested_configuration;

    #[test]
    fn startup_rejects_an_e2e_flag_without_the_e2e_build_feature() {
        assert!(validate_requested_configuration(true, false, false).is_err());
    }

    #[test]
    fn startup_rejects_e2e_mode_in_production() {
        assert!(validate_requested_configuration(true, true, true).is_err());
    }

    #[test]
    fn startup_leaves_e2e_mode_disabled_by_default() {
        assert_eq!(
            validate_requested_configuration(false, true, false),
            Ok(false)
        );
    }
}

/// Date source shared by the E2E runner and deterministic scheduler tests.
#[derive(Debug)]
#[cfg(feature = "e2e")]
pub struct E2eClock {
    date: RwLock<NaiveDate>,
    tick_in_progress: AtomicBool,
}

#[cfg(feature = "e2e")]
impl E2eClock {
    /// Creates a clock at `date`.
    pub fn new(date: NaiveDate) -> Self {
        Self {
            date: RwLock::new(date),
            tick_in_progress: AtomicBool::new(false),
        }
    }

    /// Returns the current fixture date at UTC midnight.
    pub fn now(&self) -> Result<DateTime<Utc>, E2eClockError> {
        let date = *self
            .date
            .read()
            .map_err(|_| E2eClockError::LockUnavailable)?;
        Ok(DateTime::<Utc>::from_naive_utc_and_offset(
            date.and_time(chrono::NaiveTime::MIN),
            Utc,
        ))
    }

    /// Sets the fixture date, allowing a test to reset its timeline.
    pub fn set_date(&self, date: NaiveDate) -> Result<(), E2eClockError> {
        *self
            .date
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)? = date;
        Ok(())
    }

    /// Advances the fixture date without allowing time to move backwards.
    pub fn advance_to(&self, date: NaiveDate) -> Result<(), E2eClockError> {
        let mut current = self
            .date
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)?;
        if date < *current {
            return Err(E2eClockError::CannotRewind);
        }
        *current = date;
        Ok(())
    }

    pub(crate) fn begin_tick(&self) -> Result<E2eTickGuard<'_>, E2eClockError> {
        self.tick_in_progress
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .map_err(|_| E2eClockError::TickInProgress)?;
        Ok(E2eTickGuard(&self.tick_in_progress))
    }
}

#[cfg(feature = "e2e")]
pub(crate) struct E2eTickGuard<'a>(&'a AtomicBool);

#[cfg(feature = "e2e")]
impl Drop for E2eTickGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

#[derive(Debug, Deserialize)]
#[cfg(feature = "e2e")]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ClockRequest {
    SetDate { date: NaiveDate },
    AdvanceTo { date: NaiveDate },
    Tick,
}

#[derive(Debug, Serialize)]
#[cfg(feature = "e2e")]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum ClockResponse {
    DateSet {
        date: NaiveDate,
    },
    Advanced {
        date: NaiveDate,
    },
    Ticked {
        date: NaiveDate,
        report: crate::scheduler::E2eTickReport,
    },
}

/// Handles the private E2E control endpoint.
#[cfg(feature = "e2e")]
pub async fn control(
    axum::extract::State(state): axum::extract::State<crate::state::AppState>,
    axum::Json(request): axum::Json<ClockRequest>,
) -> Result<axum::Json<ClockResponse>, E2eClockError> {
    let Some(clock) = state.e2e_clock.as_ref() else {
        return Err(E2eClockError::Disabled);
    };
    let publishes_fixture_time = !matches!(request, ClockRequest::Tick);
    let response = match request {
        ClockRequest::SetDate { date } => {
            clock.set_date(date)?;
            ClockResponse::DateSet { date }
        }
        ClockRequest::AdvanceTo { date } => {
            clock.advance_to(date)?;
            ClockResponse::Advanced { date }
        }
        ClockRequest::Tick => {
            let now = clock.now()?;
            let date = now.date_naive();
            let report = crate::scheduler::run_e2e_tick(&state).await?;
            ClockResponse::Ticked { date, report }
        }
    };
    if publishes_fixture_time {
        let fixture = clock.now()?;
        *FIXTURE_NOW
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)? = Some(fixture);
    }
    Ok(axum::Json(response))
}

#[cfg(test)]
#[cfg(feature = "e2e")]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn date(day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 11, day).unwrap_or(NaiveDate::MIN)
    }

    #[test]
    fn setting_and_advancing_the_clock_updates_its_fixture_time() {
        let clock = E2eClock::new(date(1));
        assert_eq!(clock.now().map(|now| now.date_naive()), Ok(date(1)));
        assert_eq!(clock.advance_to(date(30)), Ok(()));
        assert_eq!(clock.now().map(|now| now.date_naive()), Ok(date(30)));
        assert!(clock.advance_to(date(29)).is_err());
        assert_eq!(clock.set_date(date(2)), Ok(()));
        assert_eq!(clock.now().map(|now| now.date_naive()), Ok(date(2)));
    }
}
