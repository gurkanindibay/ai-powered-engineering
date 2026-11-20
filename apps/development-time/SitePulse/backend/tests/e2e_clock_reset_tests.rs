#![cfg(feature = "e2e")]
//! The E2E control endpoint publishes the fixture date and can release it again.
//!
//! Kept in its own test binary because the published instant is process-wide.

use axum::{extract::State, Json};
use chrono::{NaiveDate, Utc};
use sitepulse_backend::e2e_clock::{control, now_utc, ClockRequest, ClockResponse};
use sitepulse_backend::state::AppState;

#[tokio::test]
async fn clear_returns_now_utc_to_the_system_clock() {
    let fixture_date = NaiveDate::from_ymd_opt(2026, 11, 19).expect("valid date");
    let state = AppState::with_e2e_test_clock(fixture_date);

    let Json(set) = control(
        State(state.clone()),
        Json(ClockRequest::SetDate { date: fixture_date }),
    )
    .await
    .expect("set date");
    assert!(matches!(set, ClockResponse::DateSet { .. }));
    assert_eq!(now_utc().date_naive(), fixture_date);

    let Json(response) = control(State(state), Json(ClockRequest::Clear))
        .await
        .expect("clear");
    assert!(matches!(response, ClockResponse::Cleared));

    let drift = (Utc::now() - now_utc()).num_seconds().abs();
    assert!(
        drift < 5,
        "now_utc must follow the system clock after clear"
    );
}
