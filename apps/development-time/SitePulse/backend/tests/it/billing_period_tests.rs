//! STORY-07-08 (in-memory): the canonical billing period key and the due-date check.
//! The atomic batch on PostgreSQL is in `db_accrual_atomic_tests.rs`.

use axum::extract::{Json, State};
use chrono::{NaiveDate, TimeZone, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn day(y: i32, m: u32, dd: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, dd).unwrap()
}

/// Site 1 without dues or budgets: A-14 (3+1, 1800) and A-15 (2+1, 1400).
async fn site_with_two_units() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues_periods.clear();
        let mut second = inner
            .units
            .iter()
            .find(|u| u.id == "d-14")
            .cloned()
            .unwrap();
        second.id = "d-15".to_string();
        second.unit_number = 15;
        second.house_type = Some("2+1".to_string());
        second.virtual_iban = None;
        inner.units.push(second);
    }
    state
}

async fn accrue(
    state: &AppState,
    period: &str,
    due: NaiveDate,
) -> Result<AccrueDuesPeriodResponse, (axum::http::StatusCode, String)> {
    sitepulse_backend::handlers::accrue_monthly_dues(
        State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        Json(AccrueDuesPeriodRequest {
            site_id: SITE.to_string(),
            period: period.to_string(),
            amount: None,
            due_date: due,
        }),
    )
    .await
    .map(|(_, Json(r))| r)
}

// covers: SC-07-08-01
#[tokio::test]
async fn when_another_spelling_of_an_accrued_month_is_accrued_then_it_is_a_duplicate() {
    let state = site_with_two_units().await;
    let first = accrue(&state, "2026-10", day(2026, 10, 15)).await.unwrap();
    assert_eq!(first.newly_accrued_units_count, 2);
    assert_eq!(first.period_key, "2026-10");

    for spelling in ["ekim 2026", "Ekim 2026", "EKİM 2026", "10/2026"] {
        let again = accrue(&state, spelling, day(2026, 10, 15)).await.unwrap();
        assert_eq!(again.period_key, "2026-10", "{spelling}");
        assert_eq!(again.period, "Ekim 2026", "{spelling}");
        assert!(again.already_accrued, "{spelling}");
        assert_eq!(again.newly_accrued_units_count, 0, "{spelling}");
    }
    let inner = state.inner.read().await;
    assert_eq!(inner.dues.len(), 2);
    assert!(inner.dues.iter().all(|x| x.period == "Ekim 2026"));
    assert_eq!(inner.dues_periods.len(), 1);
    assert_eq!(inner.dues_periods[0].period_name, "Ekim 2026");
}

// covers: SC-07-08-01
#[tokio::test]
async fn when_the_scheduler_runs_for_a_month_a_manager_accrued_then_nothing_is_charged_twice() {
    let state = site_with_two_units().await;
    accrue(&state, "ekim 2026", day(2026, 10, 15))
        .await
        .unwrap();
    let before = state.inner.read().await.dues.len();
    let now = Utc.with_ymd_and_hms(2026, 10, 3, 9, 0, 0).unwrap();
    let (_, units) =
        sitepulse_backend::scheduler::run_periodic_accrual_for_all_sites(&state, now).await;
    let inner = state.inner.read().await;
    // Only other sites can have been charged; no unit of site 1 twice.
    assert_eq!(inner.dues.len(), before + units);
    for unit in inner.units.iter().filter(|u| u.site_id == SITE) {
        let charged = inner
            .dues
            .iter()
            .filter(|x| x.unit_id == unit.id && x.period == "Ekim 2026")
            .count();
        assert_eq!(charged, 1, "unit {} charged {} times", unit.id, charged);
    }
}

// covers: SC-07-08-01
#[tokio::test]
async fn when_a_period_is_not_a_month_then_the_request_is_rejected() {
    let state = site_with_two_units().await;
    for text in ["Test Dönemi", "2026-13", ""] {
        let (status, _) = accrue(&state, text, day(2026, 10, 15)).await.unwrap_err();
        assert_eq!(status, axum::http::StatusCode::BAD_REQUEST, "{text}");
    }
    assert!(state.inner.read().await.dues.is_empty());
}

// covers: SC-07-08-02
#[tokio::test]
async fn when_the_due_date_is_outside_the_period_then_nothing_is_written() {
    let state = site_with_two_units().await;
    let (status, message) = accrue(&state, "2026-10", day(2026, 12, 15))
        .await
        .unwrap_err();
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST, "{message}");
    let (status, _) = accrue(&state, "2026-10", day(2026, 9, 30))
        .await
        .unwrap_err();
    assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);
    let inner = state.inner.read().await;
    assert!(inner.dues.is_empty());
    assert!(inner.dues_periods.is_empty());
}

// covers: SC-07-08-04
#[tokio::test]
async fn when_a_unit_has_no_tariff_then_it_is_listed_as_skipped_with_the_reason() {
    let state = site_with_two_units().await;
    {
        let mut inner = state.inner.write().await;
        let mut untariffed = inner
            .units
            .iter()
            .find(|u| u.id == "d-14")
            .cloned()
            .unwrap();
        untariffed.id = "d-16".to_string();
        untariffed.unit_number = 3;
        untariffed.house_type = None;
        inner.units.push(untariffed);
    }
    let resp = accrue(&state, "2026-10", day(2026, 10, 15)).await.unwrap();
    assert_eq!(resp.newly_accrued_units_count, 2);
    assert_eq!(resp.total_amount_accrued, d("3200.00"));
    assert_eq!(resp.skipped_units.len(), 1, "{:?}", resp.skipped_units);
    assert!(
        resp.skipped_units[0].contains("no house-type tariff"),
        "{:?}",
        resp.skipped_units
    );
    assert!(resp.message.contains("1 daire atlandı"), "{}", resp.message);
}

// covers: SC-13-05-01
#[tokio::test]
async fn when_accrual_amount_is_zero_or_negative_then_it_is_rejected_and_creates_nothing() {
    let state = site_with_two_units().await;
    for invalid_amount in [Decimal::ZERO, d("-1500.00"), d("-0.01")] {
        let res = sitepulse_backend::handlers::accrue_monthly_dues(
            State(state.clone()),
            sitepulse_backend::tenancy::TenantScope::platform(),
            Json(AccrueDuesPeriodRequest {
                site_id: SITE.to_string(),
                period: "2026-10".to_string(),
                amount: Some(invalid_amount),
                due_date: day(2026, 10, 15),
            }),
        )
        .await;
        let (status, reason) = res.expect_err("non-positive amount must be rejected");
        assert_eq!(status, axum::http::StatusCode::BAD_REQUEST);
        assert!(reason.contains("amount must be positive"), "got: {reason}");
    }
    let inner = state.inner.read().await;
    assert_eq!(inner.dues.len(), 0);
    assert_eq!(inner.dues_periods.len(), 0);
}

// covers: SC-13-05-01
#[tokio::test]
async fn when_accrual_amount_is_omitted_or_none_then_it_accrues_from_tariffs() {
    let state = site_with_two_units().await;
    let res = sitepulse_backend::handlers::accrue_monthly_dues(
        State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        Json(AccrueDuesPeriodRequest {
            site_id: SITE.to_string(),
            period: "2026-10".to_string(),
            amount: None,
            due_date: day(2026, 10, 15),
        }),
    )
    .await;
    let (status, Json(resp)) = res.expect("omitted amount should succeed using tariffs");
    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(resp.newly_accrued_units_count, 2);
    let inner = state.inner.read().await;
    assert_eq!(inner.dues.len(), 2);
    assert_eq!(inner.dues_periods.len(), 1);
}
