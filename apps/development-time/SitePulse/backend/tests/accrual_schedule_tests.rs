//! STORY-07-10 (in-memory): the site's accrual schedule, catch-up and the late-fee grace period.

use chrono::{NaiveDate, TimeZone, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::domain::accrual_schedule::AccrualSchedule;
use sitepulse_backend::models::*;
use sitepulse_backend::scheduler::run_accrual_with_report;
use sitepulse_backend::services::dues_calculation_service::DuesCalculationService;
use sitepulse_backend::services::late_fee_service::plan_accruals;
use sitepulse_backend::services::PaymentTrackingService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn day(y: i32, m: u32, dd: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, dd).unwrap()
}

/// Site 1 without dues, periods or other units: only A-14 (d-14, 1+1 tariff via house type).
async fn clean_site(schedule: AccrualSchedule) -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues_periods.clear();
        inner.units.retain(|u| u.site_id != SITE || u.id == "d-14");
        inner
            .site_accrual_schedules
            .insert(SITE.to_string(), schedule);
    }
    state
}

fn at(y: i32, m: u32, dd: u32) -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(y, m, dd, 9, 0, 0).unwrap()
}

async fn site_dues(state: &AppState) -> Vec<DuesLiability> {
    let inner = state.inner.read().await;
    let units: Vec<String> = inner
        .units
        .iter()
        .filter(|u| u.site_id == SITE)
        .map(|u| u.id.clone())
        .collect();
    inner
        .dues
        .iter()
        .filter(|x| units.contains(&x.unit_id))
        .cloned()
        .collect()
}

fn liability(due: NaiveDate, grace: u32) -> DuesLiability {
    DuesLiability {
        id: "g-1".to_string(),
        unit_id: "d-14".to_string(),
        period: "Ekim 2026".to_string(),
        principal_amount: d("1400.00"),
        delay_penalty: Decimal::ZERO,
        total_amount: d("1400.00"),
        due_date: due,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: grace,
    }
}

// covers: SC-07-10-01
#[tokio::test]
async fn when_the_due_day_is_5_then_every_liability_of_the_period_is_due_on_the_5th() {
    let state = clean_site(AccrualSchedule {
        due_day: 5,
        ..AccrualSchedule::default()
    })
    .await;
    run_accrual_with_report(&state, at(2026, 11, 2)).await;
    let dues = site_dues(&state).await;
    assert!(!dues.is_empty());
    assert!(dues
        .iter()
        .all(|x| x.period == "Kasım 2026" && x.due_date == day(2026, 11, 5)));
}

// covers: SC-07-10-02
#[tokio::test]
async fn when_the_due_day_is_beyond_the_month_end_then_it_falls_on_the_last_day() {
    let state = clean_site(AccrualSchedule {
        due_day: 31,
        ..AccrualSchedule::default()
    })
    .await;
    run_accrual_with_report(&state, at(2027, 2, 2)).await;
    let dues = site_dues(&state).await;
    assert!(!dues.is_empty());
    assert!(dues.iter().all(|x| x.due_date == day(2027, 2, 28)));
}

// covers: SC-07-10-03
#[tokio::test]
async fn when_the_scheduler_was_off_then_it_accrues_the_missed_periods_oldest_first() {
    let state = clean_site(AccrualSchedule::default()).await;
    run_accrual_with_report(&state, at(2026, 8, 2)).await;
    assert_eq!(site_dues(&state).await.len(), 1);

    let report = run_accrual_with_report(&state, at(2026, 11, 2)).await;
    let keys: Vec<&str> = report
        .periods
        .iter()
        .map(|p| p.period_key.as_str())
        .collect();
    assert_eq!(keys, vec!["2026-09", "2026-10", "2026-11"]);
    assert!(report.limited.is_empty());

    let dues = site_dues(&state).await;
    assert_eq!(dues.len(), 4);
    for (label, due) in [
        ("Eylül 2026", day(2026, 9, 15)),
        ("Ekim 2026", day(2026, 10, 15)),
        ("Kasım 2026", day(2026, 11, 15)),
    ] {
        let found: Vec<_> = dues.iter().filter(|x| x.period == label).collect();
        assert_eq!(found.len(), 1, "{label}");
        assert_eq!(found[0].due_date, due, "{label}");
    }
    // A second run the same day changes nothing.
    let again = run_accrual_with_report(&state, at(2026, 11, 2)).await;
    assert!(again.periods.is_empty());
    assert_eq!(site_dues(&state).await.len(), 4);
}

// covers: SC-07-10-04
#[tokio::test]
async fn when_catch_up_reaches_the_limit_then_older_periods_are_reported_not_accrued() {
    let state = clean_site(AccrualSchedule {
        go_live_date: Some(day(2025, 1, 1)),
        ..AccrualSchedule::default()
    })
    .await;
    let report = run_accrual_with_report(&state, at(2026, 11, 2)).await;
    assert_eq!(report.periods.len(), 12);
    assert_eq!(report.periods.first().unwrap().period_key, "2025-12");
    assert_eq!(report.periods.last().unwrap().period_key, "2026-11");
    assert_eq!(report.limited.len(), 1);
    assert_eq!(report.limited[0].first_key, "2025-01");
    assert_eq!(report.limited[0].last_key, "2025-11");
    assert_eq!(site_dues(&state).await.len(), 12);
}

// covers: SC-07-10-05
#[tokio::test]
async fn when_paid_inside_the_grace_period_then_the_late_fee_is_zero() {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues.push(liability(day(2026, 10, 15), 5));
    }
    let request = RecordManualPaymentRequest {
        site_id: Some(SITE.to_string()),
        unit_id: "d-14".to_string(),
        amount: d("1400.00"),
        payer_name: "Owner".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::ManualCash,
        payment_date: Some(at(2026, 10, 19)),
        ..Default::default()
    };
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(request)
        .await
        .unwrap();
    let inner = state.inner.read().await;
    let paid = inner.dues.iter().find(|x| x.id == "g-1").unwrap();
    assert_eq!(paid.status, DebtStatus::Paid);
    assert_eq!(paid.delay_penalty, Decimal::ZERO);
    assert_eq!(paid.paid_penalty, Decimal::ZERO);
}

// covers: SC-07-10-06
#[test]
fn when_the_grace_period_has_ended_then_the_late_fee_runs_from_the_due_date() {
    let calc = DuesCalculationService::new();
    let due = liability(day(2026, 10, 15), 5);
    let inside = calc.calculate_delay_penalty(due.clone(), day(2026, 10, 20));
    assert_eq!(inside.delay_penalty, Decimal::ZERO);
    assert_eq!(inside.penalty_accrued_through, None);
    let after = calc.calculate_delay_penalty(due.clone(), day(2026, 10, 25));
    assert_eq!(after.delay_penalty, d("23.33"));
    assert_eq!(after.total_amount, d("1423.33"));

    // The daily job agrees: nothing inside the grace period, the same figure after it.
    assert!(plan_accruals(SITE, &due, None, day(2026, 10, 20)).is_none());
    let (rows, updated) = plan_accruals(SITE, &due, None, day(2026, 10, 25)).unwrap();
    assert_eq!(updated.delay_penalty, d("23.33"));
    assert_eq!(rows.len(), 10);
}

#[tokio::test]
async fn when_the_grace_period_changes_then_accrued_liabilities_keep_theirs() {
    let state = clean_site(AccrualSchedule {
        grace_days: 5,
        ..AccrualSchedule::default()
    })
    .await;
    run_accrual_with_report(&state, at(2026, 10, 2)).await;
    state.inner.write().await.site_accrual_schedules.insert(
        SITE.to_string(),
        AccrualSchedule {
            grace_days: 0,
            due_day: 20,
            ..AccrualSchedule::default()
        },
    );
    run_accrual_with_report(&state, at(2026, 11, 2)).await;
    let dues = site_dues(&state).await;
    let october = dues.iter().find(|x| x.period == "Ekim 2026").unwrap();
    let november = dues.iter().find(|x| x.period == "Kasım 2026").unwrap();
    assert_eq!(
        (october.grace_days, october.due_date),
        (5, day(2026, 10, 15))
    );
    assert_eq!(
        (november.grace_days, november.due_date),
        (0, day(2026, 11, 20))
    );
}

// covers: SC-07-10-05
#[test]
fn when_a_backdated_payment_is_inside_the_grace_period_then_the_reevaluated_fee_is_zero() {
    let calc = DuesCalculationService::new();
    let (due, through) = (day(2026, 10, 15), day(2026, 11, 14));
    let paid = [(day(2026, 10, 18), d("1400.00"))];
    assert_eq!(
        calc.penalty_through_with_grace(d("1400.00"), due, through, &paid, 5),
        Decimal::ZERO
    );
    // Without grace the same payment leaves 3 days of fee.
    assert_eq!(
        calc.penalty_through_with_grace(d("1400.00"), due, through, &paid, 0),
        d("7.00")
    );
    // After the grace period the fee runs from the due date.
    let late = [(day(2026, 10, 25), d("1400.00"))];
    assert_eq!(
        calc.penalty_through_with_grace(d("1400.00"), due, through, &late, 5),
        d("23.33")
    );
    // Nothing accrues while the grace period runs.
    assert_eq!(
        calc.penalty_through_with_grace(d("1400.00"), due, day(2026, 10, 20), &[], 5),
        Decimal::ZERO
    );
}

#[tokio::test]
async fn when_a_backdated_payment_settles_a_charged_liability_inside_grace_then_the_fee_is_reversed(
) {
    let state = AppState::new();
    let due_date = Utc::now().date_naive() - chrono::Days::new(40);
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.advance_balances.clear();
        let mut due = liability(due_date, 5);
        due.delay_penalty = d("70.00");
        due.total_amount = d("1470.00");
        due.status = DebtStatus::Overdue;
        due.penalty_accrued_through = Some(due_date + chrono::Days::new(30));
        inner.dues.push(due);
    }
    let request = RecordManualPaymentRequest {
        site_id: Some(SITE.to_string()),
        unit_id: "d-14".to_string(),
        amount: d("1400.00"),
        payer_name: "Owner".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::ManualCash,
        payment_date: Some(
            (due_date + chrono::Days::new(3))
                .and_hms_opt(12, 0, 0)
                .unwrap()
                .and_utc(),
        ),
        ..Default::default()
    };
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(request)
        .await
        .unwrap();
    let inner = state.inner.read().await;
    let paid = inner.dues.iter().find(|x| x.id == "g-1").unwrap();
    assert_eq!(paid.status, DebtStatus::Paid);
    assert_eq!(paid.delay_penalty, Decimal::ZERO);
}

#[test]
fn when_day_rows_are_rewritten_then_they_honour_the_grace_period() {
    use sitepulse_backend::services::late_fee_service::rewritten_accruals;
    let mut due = liability(day(2026, 10, 15), 5);
    due.paid_principal = d("1400.00");
    let sum = |payments: &[(NaiveDate, Decimal)]| {
        rewritten_accruals(SITE, &due, payments, day(2026, 10, 15), day(2026, 11, 14))
            .iter()
            .map(|r| r.daily_amount)
            .sum::<Decimal>()
    };
    assert_eq!(sum(&[(day(2026, 10, 18), d("1400.00"))]), Decimal::ZERO);
    assert_eq!(sum(&[(day(2026, 10, 25), d("1400.00"))]), d("23.33"));
}
