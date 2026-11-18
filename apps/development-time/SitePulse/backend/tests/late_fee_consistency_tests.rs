//! STORY-07-13: one late-fee figure across the dashboard, the statement and the ledger.

use chrono::{Datelike, Days, Months, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::Role;
use sitepulse_backend::models::*;
use sitepulse_backend::scheduler::site_local_date;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::billing_period_service::BillingPeriodService;
use sitepulse_backend::services::dues_calculation_service::DuesCalculationService;
use sitepulse_backend::services::dues_ledger;
use sitepulse_backend::services::finance_common::Caller;
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

/// Approves a STORY-07-11 credit note on `due_id` (requested and approved by two
/// different managers) and returns the stored correction.
async fn approve_credit_note(state: &AppState, due_id: &str, amount: &str) -> AccrualCorrection {
    use sitepulse_backend::services::correction_service::CorrectionService;
    use sitepulse_backend::services::finance_common::Caller;
    let manager = |user: &str| Caller {
        site_id: SITE.to_string(),
        user_id: user.to_string(),
        email: format!("{}@begonya.com", user),
        role: Role::SiteManager,
        unit_id: None,
    };
    let corrections = CorrectionService::new(state);
    let requested = corrections
        .request(
            &manager("usr-site-manager-1"),
            RequestCorrectionRequest {
                due_id: due_id.into(),
                kind: "CREDIT_NOTE".into(),
                amount: Some(d(amount)),
                due_date: None,
                debtor_type: None,
                reason: "budget revision".into(),
            },
        )
        .await
        .unwrap();
    corrections
        .decide(
            &manager("usr-site-manager-2"),
            requested.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .unwrap()
}

// covers: SC-07-13-03
// A credit note on a fee the daily job already booked day by day: the ledger books
// the gross fee from the day rows and the correction reverses its share, so the
// receivable is the reduced liability (STORY-07-11 x STORY-07-13).
#[tokio::test]
async fn when_a_credit_note_follows_daily_accruals_then_the_trial_balance_matches_the_liability() {
    let due = liability("lf-cn-1", "1400.00", today() - Days::new(10));
    let state = state_with(due).await;
    LateFeeService::new(&state).run_site(SITE).await;
    let accrued = stored(&state, "lf-cn-1").await;
    assert_eq!(accrued.delay_penalty, d("23.33"));
    assert!(
        state
            .inner
            .read()
            .await
            .finance
            .late_fee_accruals
            .iter()
            .any(|a| a.due_id == "lf-cn-1"),
        "the daily job wrote day rows before the credit note"
    );

    let correction = approve_credit_note(&state, "lf-cn-1", "700.00").await;
    assert_eq!(correction.penalty_reversed, Some(d("11.66")));
    let reduced = stored(&state, "lf-cn-1").await;
    assert_eq!(reduced.principal_amount, d("700.00"));
    assert_eq!(reduced.delay_penalty, d("11.67"));

    let tb = AccountingService::new(&state)
        .trial_balance(SITE, None, None)
        .await;
    assert!(tb.balanced);
    let row = |code: &str| tb.rows.iter().find(|r| r.account_code == code).cloned();
    assert_eq!(row("120").unwrap().balance, d("711.67"));
    assert_eq!(row("642").unwrap().balance.abs(), d("11.67"));
    // The dashboard's live evaluation agrees with the ledger.
    let live = DuesCalculationService::new().calculate_delay_penalty(reduced, today());
    assert_eq!(live.total_amount, d("711.67"));
}

// covers: SC-07-12-06
#[tokio::test]
async fn when_catch_up_runs_after_close_then_fee_is_booked_open_and_balances_match_dashboard() {
    let today = today();
    let closed_month = today
        .with_day(1)
        .unwrap()
        .checked_sub_months(Months::new(1))
        .unwrap();
    let closed_month_end = (closed_month + Months::new(1)) - Days::new(1);
    let period_key = format!("{:04}-{:02}", closed_month.year(), closed_month.month());
    let due_date = closed_month + Days::new(9);
    let mut due = liability("lf-closed-catch-up", "1400.00", due_date);
    due.period = period_key.clone();
    let state = state_with(due).await;
    {
        let mut inner = state.inner.write().await;
        inner.dues_periods.clear();
        inner.dues_periods.push(DuesPeriod {
            id: "period-closed-catch-up".to_string(),
            site_id: SITE.to_string(),
            period_name: period_key.clone(),
            due_date,
            status: DuesPeriodStatus::Active,
            created_at: None,
        });
        inner.dues_periods.push(DuesPeriod {
            id: "period-open-catch-up".to_string(),
            site_id: SITE.to_string(),
            period_name: format!("{:04}-{:02}", today.year(), today.month()),
            due_date: today,
            status: DuesPeriodStatus::Active,
            created_at: None,
        });
    }
    let caller = Caller {
        site_id: SITE.to_string(),
        user_id: "manager-catch-up".to_string(),
        email: "manager@example.test".to_string(),
        role: Role::SiteManager,
        unit_id: None,
    };
    let snapshot = BillingPeriodService::new(&state)
        .close(&caller, "period-closed-catch-up", "close-catch-up")
        .await
        .unwrap();

    assert_eq!(LateFeeService::new(&state).run_site(SITE).await, 1);
    let inner = state.inner.read().await;
    let rows: Vec<_> = inner
        .finance
        .late_fee_accruals
        .iter()
        .filter(|row| row.due_id == "lf-closed-catch-up")
        .collect();
    assert!(rows.iter().any(|row| {
        row.accrual_date >= closed_month
            && row.accrual_date <= closed_month_end
            && row.booked_on == Some(closed_month_end + Days::new(1))
    }));
    let current_due = inner
        .dues
        .iter()
        .find(|item| item.id == "lf-closed-catch-up")
        .unwrap()
        .clone();
    drop(inner);

    let accounting = AccountingService::new(&state);
    let closed_tb = accounting
        .trial_balance(SITE, Some(closed_month), Some(closed_month_end))
        .await;
    assert_eq!(
        serde_json::to_value(&closed_tb.rows).unwrap(),
        serde_json::to_value(&snapshot.trial_balance.rows).unwrap()
    );
    let current_tb = accounting.trial_balance(SITE, None, None).await;
    assert!(current_tb.balanced);
    let receivable = current_tb
        .rows
        .iter()
        .find(|row| row.account_code == "120")
        .unwrap();
    let dashboard_total = DuesCalculationService::new()
        .calculate_delay_penalty(current_due, today)
        .total_amount;
    assert_eq!(receivable.balance, dashboard_total);
}

// covers: SC-07-13-02
// After a credit note the job starts a new segment from the reduced fee; the next
// day's stored fee must still equal the live evaluation of that day.
#[tokio::test]
async fn when_the_job_runs_the_day_after_a_credit_note_then_the_fee_matches_the_evaluation() {
    let due = liability("lf-cn-2", "1400.00", today() - Days::new(10));
    let state = state_with(due).await;
    LateFeeService::new(&state).run_site(SITE).await;
    approve_credit_note(&state, "lf-cn-2", "700.00").await;
    let reduced = stored(&state, "lf-cn-2").await;
    let last = state
        .inner
        .read()
        .await
        .finance
        .late_fee_accruals
        .iter()
        .filter(|a| a.due_id == "lf-cn-2")
        .max_by_key(|a| a.accrual_date)
        .cloned();

    let tomorrow = today().succ_opt().unwrap();
    let (rows, next) =
        plan_accruals(SITE, &reduced, last.as_ref(), tomorrow).expect("one new day to accrue");
    assert_eq!(rows.len(), 1);
    let live = DuesCalculationService::new().calculate_delay_penalty(reduced, tomorrow);
    assert_eq!(next.delay_penalty, live.delay_penalty);
}
