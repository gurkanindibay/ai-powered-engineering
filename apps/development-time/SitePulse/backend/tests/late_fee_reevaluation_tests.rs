//! #187: a backdated payment re-evaluates late fee charged past its value date.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

fn money(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

/// 1,400.00 due 40 days ago with 70.00 late fee accrued through due date + 30.
async fn state_with_charged_late_fee(paid_penalty: &str) -> (AppState, NaiveDate) {
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
            delay_penalty: money("70.00"),
            total_amount: money("1470.00") - money(paid_penalty),
            due_date,
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: money(paid_penalty),
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(due_date + chrono::Days::new(30)),
        });
    }
    (state, due_date)
}

fn backdated_payment(
    amount: &str,
    due_date: NaiveDate,
    days_after_due: u64,
    channel: PaymentChannel,
) -> RecordManualPaymentRequest {
    let date = (due_date + chrono::Days::new(days_after_due))
        .and_hms_opt(12, 0, 0)
        .unwrap()
        .and_utc();
    RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: money(amount),
        payer_name: "Ayşe Yılmaz".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: channel,
        payment_date: Some(date),
        ..Default::default()
    }
}

// covers: SC-09-04-06
#[tokio::test]
async fn when_a_payment_is_backdated_then_late_fee_is_recalculated_and_the_excess_reversed() {
    let (state, due_date) = state_with_charged_late_fee("0.00").await;
    let service = PaymentTrackingService::new(state.clone());
    let receipt = service
        .record_and_allocate_payment(backdated_payment(
            "1411.67",
            due_date,
            5,
            PaymentChannel::ManualCash,
        ))
        .await
        .unwrap();
    assert_eq!(receipt.allocated_penalty, money("11.67"));
    assert_eq!(receipt.allocated_principal, money("1400.00"));
    assert_eq!(receipt.allocated_advance, Decimal::ZERO);

    let inner = state.inner.read().await;
    let due = &inner.dues[0];
    assert_eq!(due.delay_penalty, money("11.67"), "5 days on 1,400.00");
    assert_eq!(due.paid_penalty, money("11.67"));
    assert_eq!(due.status, DebtStatus::Paid);
    assert_eq!(
        due.penalty_accrued_through,
        Some(due_date + chrono::Days::new(30))
    );
    let adjustments = &inner.finance.adjustments;
    assert_eq!(adjustments.len(), 1);
    assert_eq!(adjustments[0].kind, ADJUSTMENT_PENALTY_REEVALUATION);
    assert_eq!(adjustments[0].amount, money("58.33"));
    assert_eq!(adjustments[0].status, REQUEST_APPROVED);
    assert_eq!(adjustments[0].penalty_before, Some(money("70.00")));
    assert!(adjustments[0].reason.contains(&receipt.receipt_number));
    drop(inner);

    let journal = sitepulse_backend::services::accounting_service::AccountingService::new(&state)
        .journal("site-1", None, None)
        .await;
    let reversal = journal
        .iter()
        .find(|e| e.source == "PENALTY_REVERSAL")
        .expect("the reversal is a GL entry");
    assert!(reversal
        .lines
        .iter()
        .any(|l| l.account_code == "642" && l.debit == money("58.33")));
    let penalty_revenue_net: Decimal = journal
        .iter()
        .flat_map(|e| e.lines.iter())
        .filter(|l| l.account_code == "642")
        .map(|l| l.credit - l.debit)
        .sum();
    assert_eq!(penalty_revenue_net, money("11.67"));
}

// covers: SC-09-04-06
#[tokio::test]
async fn when_a_bank_statement_line_is_backdated_then_late_fee_is_recalculated_the_same_way() {
    let (state, due_date) = state_with_charged_late_fee("0.00").await;
    let service = PaymentTrackingService::new(state.clone());
    service
        .record_and_allocate_payment(backdated_payment(
            "1411.67",
            due_date,
            5,
            PaymentChannel::BankStatement,
        ))
        .await
        .unwrap();
    let inner = state.inner.read().await;
    assert_eq!(inner.dues[0].delay_penalty, money("11.67"));
    assert_eq!(inner.finance.adjustments.len(), 1);
}

// covers: SC-09-04-07
#[tokio::test]
async fn when_penalty_was_already_paid_then_the_excess_moves_to_the_payers_advance() {
    let (state, due_date) = state_with_charged_late_fee("70.00").await;
    let service = PaymentTrackingService::new(state.clone());
    let receipt = service
        .record_and_allocate_payment(backdated_payment(
            "1400.00",
            due_date,
            5,
            PaymentChannel::ManualCash,
        ))
        .await
        .unwrap();
    assert_eq!(receipt.allocated_principal, money("1400.00"));
    assert_eq!(receipt.allocated_penalty, Decimal::ZERO);

    let inner = state.inner.read().await;
    let due = &inner.dues[0];
    assert_eq!(due.delay_penalty, money("11.67"));
    assert_eq!(due.paid_penalty, money("11.67"));
    assert_eq!(due.status, DebtStatus::Paid);
    assert_eq!(inner.advance_balances["d-14"].of("OWNER"), money("58.33"));
    assert_eq!(inner.finance.adjustments[0].amount, money("58.33"));
}

#[tokio::test]
async fn when_a_payment_is_dated_after_the_accrual_then_late_fee_is_untouched() {
    let (state, due_date) = state_with_charged_late_fee("0.00").await;
    let service = PaymentTrackingService::new(state.clone());
    service
        .record_and_allocate_payment(backdated_payment(
            "1470.00",
            due_date,
            30,
            PaymentChannel::ManualCash,
        ))
        .await
        .unwrap();
    let inner = state.inner.read().await;
    assert_eq!(inner.dues[0].paid_penalty, money("70.00"));
    assert!(inner.finance.adjustments.is_empty());
}

#[tokio::test]
async fn when_a_backdated_payment_is_partial_then_late_fee_keeps_accruing_on_the_rest() {
    let (state, due_date) = state_with_charged_late_fee("0.00").await;
    let service = PaymentTrackingService::new(state.clone());
    // 11.67 penalty + 700.00 principal on day 5; 700.00 stays open for 25 more days.
    service
        .record_and_allocate_payment(backdated_payment(
            "711.67",
            due_date,
            5,
            PaymentChannel::ManualCash,
        ))
        .await
        .unwrap();
    let inner = state.inner.read().await;
    let due = &inner.dues[0];
    // 5 days on 1,400.00 (11.67) + 25 days on 700.00 (29.17).
    assert_eq!(due.delay_penalty, money("40.84"));
    assert_eq!(due.paid_principal, money("700.00"));
    assert_eq!(inner.finance.adjustments[0].amount, money("29.16"));
}
