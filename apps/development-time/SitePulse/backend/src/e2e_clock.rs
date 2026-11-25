//! E2E-only deterministic scheduler clock and control endpoint.

use chrono::{DateTime, Utc};

/// Fixture instant published by the E2E control endpoint; `None` until a runner sets the date.
#[cfg(feature = "e2e")]
static FIXTURE_NOW: RwLock<Option<DateTime<Utc>>> = RwLock::new(None);

/// Time zone the simulated clock is reported in (matches the demo site default).
#[cfg(feature = "e2e")]
const REPORTING_TIMEZONE: &str = "Europe/Istanbul";

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

/// The process-wide [`crate::domain::clock::Clock`]: the E2E fixture time once a runner has set
/// the clock in an `e2e` build, the system clock otherwise. Date-dependent rules (effective
/// dates, due dates, late fees, value dates) read "now" through it.
#[derive(Debug, Default, Clone, Copy)]
pub struct ProcessClock;

impl crate::domain::clock::Clock for ProcessClock {
    fn now(&self) -> DateTime<Utc> {
        now_utc()
    }
}

/// Shared handle to the process clock.
pub const PROCESS_CLOCK: ProcessClock = ProcessClock;

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
    instant: RwLock<DateTime<Utc>>,
    tick_in_progress: AtomicBool,
}

#[cfg(feature = "e2e")]
impl E2eClock {
    /// Creates a clock at `date`.
    pub fn new(date: NaiveDate) -> Self {
        Self {
            instant: RwLock::new(midnight_utc(date)),
            tick_in_progress: AtomicBool::new(false),
        }
    }

    /// Returns the current fixture instant (UTC midnight after a date was set).
    pub fn now(&self) -> Result<DateTime<Utc>, E2eClockError> {
        self.instant
            .read()
            .map(|guard| *guard)
            .map_err(|_| E2eClockError::LockUnavailable)
    }

    /// Sets the fixture date (UTC midnight), allowing a test to reset its timeline.
    pub fn set_date(&self, date: NaiveDate) -> Result<(), E2eClockError> {
        self.set_instant(midnight_utc(date))
    }

    /// Sets the fixture instant, for boundaries that fall inside a UTC day
    /// (for example the Europe/Istanbul midnight, 21:00 UTC the evening before).
    pub fn set_instant(&self, at: DateTime<Utc>) -> Result<(), E2eClockError> {
        *self
            .instant
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)? = at;
        Ok(())
    }

    /// Advances the fixture date without allowing time to move backwards.
    pub fn advance_to(&self, date: NaiveDate) -> Result<(), E2eClockError> {
        let target = midnight_utc(date);
        let mut current = self
            .instant
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)?;
        if target < *current {
            return Err(E2eClockError::CannotRewind);
        }
        *current = target;
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
fn midnight_utc(date: NaiveDate) -> DateTime<Utc> {
    DateTime::<Utc>::from_naive_utc_and_offset(date.and_time(chrono::NaiveTime::MIN), Utc)
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
    SetDate {
        date: NaiveDate,
    },
    AdvanceTo {
        date: NaiveDate,
    },
    /// Sets an exact instant (RFC 3339), e.g. `2026-11-30T20:30:00Z`.
    SetInstant {
        at: DateTime<Utc>,
    },
    /// Returns the process to the system clock until the next date is set.
    Clear,
    Tick,
    Get,
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
    InstantSet {
        at: DateTime<Utc>,
    },
    Cleared,
    Ticked {
        date: NaiveDate,
        report: crate::scheduler::E2eTickReport,
    },
    Current {
        utc: DateTime<Utc>,
        date: NaiveDate,
        time: String,
        iso: String,
        timezone: String,
    },
}

/// Drops the published fixture instant so `now_utc()` follows the system clock again.
#[cfg(feature = "e2e")]
pub fn clear_fixture_now() -> Result<(), E2eClockError> {
    *FIXTURE_NOW
        .write()
        .map_err(|_| E2eClockError::LockUnavailable)? = None;
    Ok(())
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
    let publishes_fixture_time = matches!(
        request,
        ClockRequest::SetDate { .. }
            | ClockRequest::AdvanceTo { .. }
            | ClockRequest::SetInstant { .. }
    );
    let response = match request {
        ClockRequest::SetDate { date } => {
            clock.set_date(date)?;
            ClockResponse::DateSet { date }
        }
        ClockRequest::AdvanceTo { date } => {
            clock.advance_to(date)?;
            ClockResponse::Advanced { date }
        }
        ClockRequest::SetInstant { at } => {
            clock.set_instant(at)?;
            ClockResponse::InstantSet { at }
        }
        ClockRequest::Clear => {
            clear_fixture_now()?;
            ClockResponse::Cleared
        }
        ClockRequest::Tick => {
            let now = clock.now()?;
            let date = now.date_naive();
            let report = crate::scheduler::run_e2e_tick(&state).await?;
            ClockResponse::Ticked { date, report }
        }
        ClockRequest::Get => current_clock_response(clock)?,
    };
    if publishes_fixture_time {
        let fixture = clock.now()?;
        *FIXTURE_NOW
            .write()
            .map_err(|_| E2eClockError::LockUnavailable)? = Some(fixture);
    }
    Ok(axum::Json(response))
}

/// Snapshots the simulated clock in the reporting timezone (Europe/Istanbul).
#[cfg(feature = "e2e")]
fn current_clock_response(clock: &E2eClock) -> Result<ClockResponse, E2eClockError> {
    let now = clock.now()?;
    let local = now.with_timezone(&chrono_tz::Europe::Istanbul);
    Ok(ClockResponse::Current {
        utc: now,
        date: local.date_naive(),
        time: local.format("%H:%M:%S").to_string(),
        iso: local.to_rfc3339(),
        timezone: REPORTING_TIMEZONE.to_string(),
    })
}

/// Handles the read-only E2E clock endpoint used by the PM Workbench Time Machine.
#[cfg(feature = "e2e")]
pub async fn get_clock(
    axum::extract::State(state): axum::extract::State<crate::state::AppState>,
) -> Result<axum::Json<ClockResponse>, E2eClockError> {
    let Some(clock) = state.e2e_clock.as_ref() else {
        return Err(E2eClockError::Disabled);
    };
    Ok(axum::Json(current_clock_response(clock)?))
}

/// Handles the private E2E state reload endpoint to synchronize in-memory state with PostgreSQL.
#[cfg(feature = "e2e")]
pub async fn reload_state(
    axum::extract::State(state): axum::extract::State<crate::state::AppState>,
) -> axum::response::Response {
    use axum::response::IntoResponse;
    if state.settings.is_production() || crate::state::AppStateInner::is_production() {
        return (
            axum::http::StatusCode::FORBIDDEN,
            axum::Json(serde_json::json!({
                "status": "ERROR",
                "message": "E2E state reload is forbidden in production"
            })),
        )
            .into_response();
    }
    match state.reload_from_db().await {
        Ok(()) => {
            tracing::info!("E2E state successfully reloaded from PostgreSQL");
            (
                axum::http::StatusCode::OK,
                axum::Json(serde_json::json!({
                    "status": "OK",
                    "message": "State reloaded from PostgreSQL successfully"
                })),
            )
                .into_response()
        }
        Err(err) => {
            tracing::error!("Failed to reload state from PostgreSQL: {}", err);
            (
                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                axum::Json(serde_json::json!({
                    "status": "ERROR",
                    "message": err
                })),
            )
                .into_response()
        }
    }
}

#[cfg(test)]
#[cfg(feature = "e2e")]
mod tests {
    use super::*;
    use axum::http::StatusCode;
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
        let evening = DateTime::parse_from_rfc3339("2026-11-30T21:30:00Z")
            .map(|at| at.with_timezone(&Utc))
            .unwrap_or(DateTime::<Utc>::MIN_UTC);
        assert_eq!(clock.set_instant(evening), Ok(()));
        assert_eq!(clock.now(), Ok(evening));
        assert_eq!(
            crate::domain::clock::local_date("Europe/Istanbul", evening),
            NaiveDate::from_ymd_opt(2026, 12, 1).unwrap_or(NaiveDate::MIN)
        );
        assert_eq!(clock.set_date(date(2)), Ok(()));
        assert_eq!(clock.now().map(|now| now.date_naive()), Ok(date(2)));
    }

    #[test]
    fn get_clock_reports_the_simulated_state_in_istanbul_time() {
        let clock = E2eClock::new(date(19));
        let Ok(ClockResponse::Current {
            utc,
            date: local_date,
            time,
            iso,
            timezone,
        }) = current_clock_response(&clock)
        else {
            panic!("the clock snapshot must be a Current response");
        };
        assert_eq!(local_date, date(19));
        assert_eq!(timezone, REPORTING_TIMEZONE);
        assert_eq!(
            local_date,
            crate::domain::clock::local_date(REPORTING_TIMEZONE, utc)
        );
        assert!(
            iso.starts_with(&date(19).to_string()),
            "unexpected iso: {iso}"
        );
        assert_eq!(time.len(), 8, "time must be HH:MM:SS, got {time}");
    }

    #[tokio::test]
    async fn reload_state_rejects_in_production_settings() {
        let mut inner = crate::state::AppStateInner::blank();
        inner.clear_all_data();
        let mut state = crate::state::AppState::from_parts(inner, None);
        state.settings.production = true;

        let response = reload_state(axum::extract::State(state)).await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn reload_state_succeeds_in_development_without_db() {
        let mut inner = crate::state::AppStateInner::blank();
        inner.clear_all_data();
        let mut state = crate::state::AppState::from_parts(inner, None);
        state.settings.production = false;

        let response = reload_state(axum::extract::State(state)).await;
        assert_eq!(response.status(), StatusCode::OK);
    }
}
