//! #187 with STORY-07-13: a backdated payment rewrites the stored late fee, the
//! day rows and the ledger together.

use chrono::Utc;
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::late_fee_service::LateFeeService;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

fn money(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

// covers: SC-09-04-06
#[tokio::test]
async fn when_the_daily_job_already_ran_then_stored_fee_day_rows_and_ledger_stay_consistent() {
    let state = AppState::new();
    let due_date = Utc::now().date_naive() - chrono::Days::new(40);
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.advance_balances.clear();
        inner.dues.push(DuesLiability {
            id: "late-fee-due".to_string(),
            unit_id: "d-14".to_string(),
            period: "Ekim 2026".to_string(),
            principal_amount: money("1400.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: money("1400.00"),
            due_date,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
        });
    }
    let job = LateFeeService::new(&state);
    job.run_site("site-1").await;
    let before = state.inner.read().await.dues[0].delay_penalty;
    assert_eq!(before, money("93.33"), "40 days on 1,400.00");

    let payment_date = (due_date + chrono::Days::new(5))
        .and_hms_opt(12, 0, 0)
        .unwrap()
        .and_utc();
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some("site-1".to_string()),
            unit_id: "d-14".to_string(),
            amount: money("1411.67"),
            payer_name: "Ayşe Yılmaz".to_string(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::ManualCash,
            payment_date: Some(payment_date),
            ..Default::default()
        })
        .await
        .unwrap();

    let inner = state.inner.read().await;
    assert_eq!(inner.dues[0].delay_penalty, money("11.67"));
    let rows: Vec<_> = inner
        .finance
        .late_fee_accruals
        .iter()
        .filter(|a| a.due_id == "late-fee-due")
        .collect();
    assert!(rows.iter().all(|r| r.cumulative_fee <= money("11.67")));
    assert!(rows.iter().map(|r| r.daily_amount).sum::<Decimal>() <= money("11.67"));
    drop(inner);

    assert!(job.reconcile("site-1").await.consistent);
    let journal = AccountingService::new(&state)
        .journal("site-1", None, None)
        .await;
    let net: Decimal = journal
        .iter()
        .flat_map(|e| e.lines.iter())
        .filter(|l| l.account_code == "642")
        .map(|l| l.credit - l.debit)
        .sum();
    assert_eq!(net, money("11.67"));
}
