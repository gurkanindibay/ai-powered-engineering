//! STORY-07-12 acceptance tests. Scenarios live in the EPIC-07 feature file.

use chrono::NaiveDate;
use rust_decimal::Decimal;
use sitepulse_backend::domain::billing_period::BillingPeriod;
use sitepulse_backend::models::*;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::billing_period_service::BillingPeriodService;
use sitepulse_backend::services::correction_service::CorrectionService;
use sitepulse_backend::services::finance_common::{Caller, FinanceError};
use sitepulse_backend::services::payment_tracking_service::PaymentTrackingService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";
const UNIT: &str = "d-14";
const PERIOD_ID: &str = "period-oct-2026";

fn d(value: &str) -> Decimal {
    Decimal::from_str_exact(value).unwrap()
}

fn manager(user_id: &str) -> Caller {
    Caller {
        site_id: SITE.to_string(),
        user_id: user_id.to_string(),
        email: format!("{user_id}@begonya.com"),
        role: Role::SiteManager,
        unit_id: None,
    }
}

fn period(status: DuesPeriodStatus) -> DuesPeriod {
    DuesPeriod {
        id: PERIOD_ID.to_string(),
        site_id: SITE.to_string(),
        period_name: "2026-10".to_string(),
        due_date: NaiveDate::from_ymd_opt(2026, 10, 15).unwrap(),
        status,
        created_at: None,
    }
}

fn liability(id: &str, amount: &str, paid: &str) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: "2026-10".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: NaiveDate::from_ymd_opt(2026, 10, 15).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: d(paid),
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
    }
}

async fn fixture(status: DuesPeriodStatus, amount: &str, paid: &str) -> AppState {
    let state = AppState::new_with_test_fixtures();
    let mut inner = state.inner.write().await;
    inner.dues.clear();
    inner.finance.corrections.clear();
    inner.dues_periods.push(period(status));
    if !amount.is_empty() {
        inner.dues.push(liability("due-oct", amount, paid));
    }
    drop(inner);
    state
}

// covers: SC-07-12-01
#[tokio::test]
async fn closing_a_period_returns_the_summary_and_freezes_its_snapshot() {
    let state = fixture(DuesPeriodStatus::Active, "16800.00", "14000.00").await;
    let service = BillingPeriodService::new(&state);
    let before = service.summary(SITE, PERIOD_ID).await.unwrap();
    assert_eq!(before.accrued, d("16800.00"));
    assert_eq!(before.collected, d("14000.00"));
    assert_eq!(before.outstanding, d("2800.00"));

    let snapshot = service
        .close(&manager("manager-close"), PERIOD_ID, "close-request")
        .await
        .unwrap();
    assert_eq!(snapshot.account_report.status, DuesPeriodStatus::Closed);
    assert_eq!(snapshot.snapshot_version, 1);
    assert!(!snapshot.journal_entries.is_empty());

    // A later change in the live source rows cannot rewrite the closed report or trial balance.
    state.inner.write().await.dues[0].principal_amount = d("12000.00");
    let after = service.summary(SITE, PERIOD_ID).await.unwrap();
    assert_eq!(after.accrued, d("16800.00"));
    assert_eq!(after.outstanding, d("2800.00"));
    assert_eq!(after.status, DuesPeriodStatus::Closed);
    let trial_balance = AccountingService::new(&state)
        .trial_balance(
            SITE,
            Some(NaiveDate::from_ymd_opt(2026, 10, 1).unwrap()),
            Some(NaiveDate::from_ymd_opt(2026, 10, 31).unwrap()),
        )
        .await;
    assert_eq!(
        serde_json::to_value(&trial_balance.rows).unwrap(),
        serde_json::to_value(&snapshot.trial_balance.rows).unwrap()
    );
}

// covers: SC-07-12-02
#[tokio::test]
async fn a_closed_period_still_accepts_payment_and_books_it_on_its_receipt_date() {
    let state = fixture(DuesPeriodStatus::Active, "1400.00", "0.00").await;
    let receipt_date = NaiveDate::from_ymd_opt(2026, 11, 3).unwrap();
    state.inner.write().await.dues[0].due_date = receipt_date;
    let service = BillingPeriodService::new(&state);
    service
        .close(&manager("manager-close"), PERIOD_ID, "close-request")
        .await
        .unwrap();

    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("1400.00"),
            payer_name: "A-14 owner".to_string(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::VirtualIban,
            payment_date: Some(receipt_date.and_hms_opt(12, 0, 0).unwrap().and_utc()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(
        state.inner.read().await.dues[0].paid_principal,
        d("1400.00")
    );
    assert_eq!(state.inner.read().await.dues[0].status, DebtStatus::Paid);
    let journal = AccountingService::new(&state)
        .journal(SITE, None, None)
        .await;
    assert!(journal
        .iter()
        .any(|entry| { entry.source == "RECEIPT" && entry.date == receipt_date }));
    assert_eq!(
        service.summary(SITE, PERIOD_ID).await.unwrap().outstanding,
        d("1400.00")
    );
}

// covers: SC-07-12-03
#[tokio::test]
async fn a_correction_to_a_closed_period_posts_later_and_preserves_the_close_report() {
    let state = fixture(DuesPeriodStatus::Active, "1000.00", "0.00").await;
    state.inner.write().await.dues_periods.push(DuesPeriod {
        id: "period-nov-2026".to_string(),
        site_id: SITE.to_string(),
        period_name: "2026-11".to_string(),
        due_date: NaiveDate::from_ymd_opt(2026, 11, 15).unwrap(),
        status: DuesPeriodStatus::Active,
        created_at: None,
    });
    let close = BillingPeriodService::new(&state)
        .close(&manager("manager-close"), PERIOD_ID, "close-request")
        .await
        .unwrap();
    let corrections = CorrectionService::new(&state);
    let request = corrections
        .request(
            &manager("manager-request"),
            RequestCorrectionRequest {
                due_id: "due-oct".to_string(),
                kind: "CREDIT_NOTE".to_string(),
                amount: Some(d("200.00")),
                due_date: None,
                debtor_type: None,
                reason: "approved invoice correction".to_string(),
                replacement_shares: Vec::new(),
            },
        )
        .await
        .unwrap();
    corrections
        .decide(
            &manager("manager-approve"),
            request.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .unwrap();

    let monthly_trial_balance = AccountingService::new(&state)
        .trial_balance(
            SITE,
            Some(NaiveDate::from_ymd_opt(2026, 10, 1).unwrap()),
            Some(NaiveDate::from_ymd_opt(2026, 10, 31).unwrap()),
        )
        .await;
    assert_eq!(
        serde_json::to_value(&monthly_trial_balance.rows).unwrap(),
        serde_json::to_value(&close.trial_balance.rows).unwrap()
    );
    let account_report = BillingPeriodService::new(&state)
        .summary(SITE, PERIOD_ID)
        .await
        .unwrap();
    assert_eq!(account_report.accrued, d("1000.00"));
    assert_eq!(account_report.status, DuesPeriodStatus::Closed);
    let correction_entry = AccountingService::new(&state)
        .journal(SITE, None, None)
        .await
        .into_iter()
        .find(|entry| entry.source == "CREDIT_NOTE")
        .expect("approved credit note is booked");
    let operating_date = {
        let inner = state.inner.read().await;
        sitepulse_backend::services::finance_common::site_today(&inner, SITE)
    };
    assert_eq!(correction_entry.date, operating_date);
    assert!(correction_entry.description.contains("2026-10"));
}

// covers: SC-07-12-04
#[test]
fn accrual_into_a_closed_period_is_rejected_as_a_conflict() {
    let mut inner = sitepulse_backend::state::AppStateInner::blank();
    inner.dues_periods.push(period(DuesPeriodStatus::Closed));
    let result = sitepulse_backend::services::billing_period_service::ensure_open_for_accrual(
        &inner,
        SITE,
        BillingPeriod::parse("2026-10").unwrap(),
    );
    assert!(matches!(result, Err(FinanceError::Conflict(_))));
}

#[test]
fn active_periods_use_the_open_contract_while_accepting_legacy_active_values() {
    assert_eq!(
        serde_json::to_string(&DuesPeriodStatus::Active).unwrap(),
        "\"OPEN\""
    );
    assert_eq!(
        DuesPeriodStatus::from_str_loose("ACTIVE"),
        DuesPeriodStatus::Active
    );
    assert_eq!(
        serde_json::from_str::<DuesPeriodStatus>("\"ACTIVE\"").unwrap(),
        DuesPeriodStatus::Active
    );
}

// covers: SC-07-12-05
#[tokio::test]
async fn reopening_requires_a_second_manager_and_keeps_an_audit_record() {
    let state = fixture(DuesPeriodStatus::Active, "", "").await;
    let service = BillingPeriodService::new(&state);
    service
        .close(&manager("manager-close"), PERIOD_ID, "close-request")
        .await
        .unwrap();
    let requested = service
        .request_reopen(
            &manager("manager-request"),
            PERIOD_ID,
            RequestPeriodReopen {
                reason: "missed invoice".to_string(),
            },
            "reopen-request",
        )
        .await
        .unwrap();
    assert_eq!(requested.status, "PENDING");
    assert_eq!(
        state.inner.read().await.dues_periods[0].status,
        DuesPeriodStatus::Closed
    );
    let self_decision = service
        .decide_reopen(
            &manager("manager-request"),
            &requested.id,
            DecidePeriodReopen {
                approve: true,
                decision_note: None,
            },
            "self-approval",
        )
        .await;
    assert!(matches!(self_decision, Err(FinanceError::Forbidden(_))));

    let decided = service
        .decide_reopen(
            &manager("manager-approve"),
            &requested.id,
            DecidePeriodReopen {
                approve: true,
                decision_note: Some("invoice evidence attached".to_string()),
            },
            "reopen-decision",
        )
        .await
        .unwrap();
    assert_eq!(decided.status, "APPROVED");
    assert_eq!(
        state.inner.read().await.dues_periods[0].status,
        DuesPeriodStatus::Active
    );
    assert_eq!(
        state.inner.read().await.dues_period_reopen_requests.len(),
        1
    );
}
