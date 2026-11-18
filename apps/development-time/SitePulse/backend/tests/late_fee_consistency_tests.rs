//! STORY-07-13: one late-fee figure across the dashboard, the statement and the ledger.

use chrono::{Datelike, Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::scheduler::site_local_date;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::dues_calculation_service::DuesCalculationService;
use sitepulse_backend::services::dues_ledger;
use sitepulse_backend::services::late_fee_service::{plan_accruals, LateFeeService};
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn date(y: i32, m: u32, day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(y, m, day).unwrap()
}

fn today() -> NaiveDate {
    site_local_date("Europe/Istanbul", Utc::now())
}

fn liability(id: &str, amount: &str, due: NaiveDate) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: "d-14".to_string(),
        period: "Ekim 2026".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: due,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
    }
}

async fn state_with(due: DuesLiability) -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues.push(due);
    }
    state
}

async fn stored(state: &AppState, id: &str) -> DuesLiability {
    let inner = state.inner.read().await;
    inner.dues.iter().find(|x| x.id == id).cloned().unwrap()
}

/// Runs the job day by day over `days` days from the due date, as a daily
/// scheduler would; returns the accrual rows.
fn run_daily(due: &DuesLiability, until: NaiveDate) -> (DuesLiability, Vec<LateFeeAccrual>) {
    let mut current = due.clone();
    let mut rows: Vec<LateFeeAccrual> = Vec::new();
    let mut day = due.due_date;
    while day < until {
        day = day.succ_opt().unwrap();
        if let Some((new_rows, updated)) = plan_accruals(SITE, &current, rows.last(), day) {
            rows.extend(new_rows);
            current = updated;
        }
    }
    (current, rows)
}

// covers: SC-07-13-01
#[test]
fn when_the_job_runs_on_the_tenth_day_then_the_fee_is_the_evaluation_for_that_day() {
    let due = liability("lf-1", "1400.00", date(2026, 10, 15));
    let (after, rows) = run_daily(&due, date(2026, 10, 25));
    assert_eq!(after.delay_penalty, d("23.33"));
    assert_eq!(after.total_amount, d("1423.33"));
    let evaluated = DuesCalculationService::new().calculate_delay_penalty(due, date(2026, 10, 25));
    assert_eq!(after.delay_penalty, evaluated.delay_penalty);
    assert_eq!(
        rows.iter().map(|r| r.daily_amount).sum::<Decimal>(),
        d("23.33")
    );
}

// covers: SC-07-13-03
#[test]
fn when_the_job_runs_every_day_then_the_fee_is_rounded_once_per_segment() {
    let due = liability("lf-3", "1400.00", date(2026, 10, 15));
    let (after, rows) = run_daily(&due, date(2026, 11, 14));
    assert_eq!(after.delay_penalty, d("70.00"));
    let in_month = |m: u32| {
        rows.iter()
            .filter(|r| r.accrual_date.month() == m)
            .map(|r| r.daily_amount)
            .sum::<Decimal>()
    };
    assert_eq!(in_month(10), d("37.33"), "not 16 x 2.33 = 37.28");
    assert_eq!(in_month(11), d("32.67"));
}

#[test]
fn when_a_payment_ends_a_segment_then_the_next_segment_starts_from_its_total() {
    let due = liability("lf-4", "1000.00", date(2026, 9, 1));
    let (mut mid, rows) = run_daily(&due, date(2026, 9, 16));
    assert_eq!(mid.delay_penalty, d("25.00"));
    mid.paid_principal = d("600.00");
    dues_ledger::refresh(&mut mid);
    let mut all = rows;
    let mut current = mid;
    let mut day = date(2026, 9, 16);
    while day < date(2026, 10, 1) {
        day = day.succ_opt().unwrap();
        if let Some((new_rows, updated)) = plan_accruals(SITE, &current, all.last(), day) {
            all.extend(new_rows);
            current = updated;
        }
    }
    assert_eq!(
        current.delay_penalty,
        d("35.00"),
        "25.00 + 400 x 5% x 15 / 30"
    );
}

// covers: SC-07-13-02
#[tokio::test]
async fn when_the_job_runs_twice_on_one_day_then_nothing_changes() {
    let due = liability("lf-2", "1400.00", today() - Days::new(10));
    let state = state_with(due).await;
    let svc = LateFeeService::new(&state);
    assert_eq!(svc.run_site(SITE).await, 1);
    let first_due = stored(&state, "lf-2").await;
    let first_rows = state.inner.read().await.finance.late_fee_accruals.clone();
    let acc = AccountingService::new(&state);
    let first_tb = acc.trial_balance(SITE, None, None).await;
    assert_eq!(first_rows.len(), 10);

    assert_eq!(svc.run_site(SITE).await, 0);
    let again = stored(&state, "lf-2").await;
    assert_eq!(again.delay_penalty, first_due.delay_penalty);
    assert_eq!(
        again.penalty_accrued_through,
        first_due.penalty_accrued_through
    );
    assert_eq!(
        state.inner.read().await.finance.late_fee_accruals,
        first_rows
    );
    let second_tb = acc.trial_balance(SITE, None, None).await;
    assert_eq!(second_tb.total_debit, first_tb.total_debit);
}

// covers: SC-07-13-01, SC-07-13-03
#[tokio::test]
async fn when_the_job_has_run_then_the_ledger_books_each_day_and_agrees_with_the_evaluation() {
    let due = liability("lf-5", "1400.00", today() - Days::new(30));
    let state = state_with(due.clone()).await;
    LateFeeService::new(&state).run_site(SITE).await;
    let after = stored(&state, "lf-5").await;
    assert_eq!(after.delay_penalty, d("70.00"));

    let evaluated = DuesCalculationService::new().calculate_delay_penalty(after.clone(), today());
    assert_eq!(evaluated.total_amount, after.total_amount);
    let acc = AccountingService::new(&state);
    let tb = acc.trial_balance(SITE, None, None).await;
    let row = |code: &str| tb.rows.iter().find(|r| r.account_code == code).cloned();
    assert_eq!(row("120").unwrap().balance, d("1470.00"));
    assert_eq!(row("642").unwrap().credit, d("70.00"));
    // The fee is spread over the days it accrued on, not booked in one entry.
    let first_day = due.due_date.succ_opt().unwrap();
    let day_tb = acc
        .trial_balance(SITE, Some(first_day), Some(first_day))
        .await;
    assert_eq!(
        day_tb
            .rows
            .iter()
            .find(|r| r.account_code == "642")
            .unwrap()
            .credit,
        d("2.33")
    );
}

// covers: SC-07-13-03
#[tokio::test]
async fn when_the_job_has_not_run_yet_then_the_trial_balance_still_matches_the_evaluation() {
    let due = liability("lf-6", "1400.00", today() - Days::new(10));
    let state = state_with(due.clone()).await;
    let live = DuesCalculationService::new().calculate_delay_penalty(due, today());
    let tb = AccountingService::new(&state)
        .trial_balance(SITE, None, None)
        .await;
    let receivable = tb.rows.iter().find(|r| r.account_code == "120").unwrap();
    assert_eq!(receivable.balance, live.total_amount);
}

// covers: SC-07-13-04
#[tokio::test]
async fn when_the_stored_fee_differs_from_the_evaluation_then_the_check_reports_the_liability() {
    let due = liability("lf-7", "1400.00", today() - Days::new(10));
    let state = state_with(due).await;
    let svc = LateFeeService::new(&state);
    let report = svc.reconcile(SITE).await;
    assert!(!report.consistent);
    assert_eq!(report.mismatches.len(), 1);
    assert_eq!(report.mismatches[0].due_id, "lf-7");
    assert_eq!(report.mismatches[0].stored_fee, Decimal::ZERO);
    assert_eq!(report.mismatches[0].evaluated_fee, d("23.33"));

    svc.run_site(SITE).await;
    let after = svc.reconcile(SITE).await;
    assert!(after.consistent, "{:?}", after.mismatches);
    assert_eq!(after.liabilities_checked, 1);
}
