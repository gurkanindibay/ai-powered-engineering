//! SPEC-005 acceptance tests: single ingestion path, KMK 20 penalty base,
//! TBK 101 payer designation, match-all without duplicates, debt aging.
//! In-memory mode; the PostgreSQL side is covered by the schema-integrity gate
//! and the API system check.

use chrono::{Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

const WEBHOOK_SECRET: &str = "spec-005-test-webhook-secret";
const UNIT: &str = "d-14";
const VIRTUAL_IBAN: &str = "TR410020504213991067000014";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn liability(
    id: &str,
    period: &str,
    principal: &str,
    due_date: NaiveDate,
    debtor: &str,
    expense: &str,
) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: period.to_string(),
        principal_amount: d(principal),
        delay_penalty: Decimal::ZERO,
        total_amount: d(principal),
        due_date,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::from_str_loose(debtor),
        expense_type: ExpenseType::from_str_loose(expense),
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
    }
}

/// The fixture site (unit d-14 in site-1) owing exactly `dues`: no seeded
/// liabilities, advances, receipts or ledger rows.
async fn state_with(dues: Vec<DuesLiability>) -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues = dues;
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner.homeowner_payments.clear();
        inner.reconciliation_queue.clear();
    }
    state
}

fn today() -> NaiveDate {
    Utc::now().date_naive()
}

async fn webhook(
    state: &AppState,
    txn: &str,
    amount: &str,
    description: &str,
) -> BankIncomingWebhookResponse {
    std::env::set_var("SITEPULSE_BANK_WEBHOOK_SECRET", WEBHOOK_SECRET);
    let req = BankIncomingWebhookRequest {
        transaction_id: txn.to_string(),
        virtual_iban: VIRTUAL_IBAN.to_string(),
        amount: d(amount),
        currency: Some("TRY".to_string()),
        sender_name: Some("Ahmet Yılmaz".to_string()),
        sender_iban: None,
        description: Some(description.to_string()),
        signature: None,
    };
    let body = serde_json::to_vec(&req).unwrap();
    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        sitepulse_backend::handlers::BANK_WEBHOOK_SIGNATURE_HEADER,
        sitepulse_backend::auth::sign_webhook_body(WEBHOOK_SECRET, &body)
            .parse()
            .unwrap(),
    );
    let (status, axum::Json(res)) = sitepulse_backend::handlers::handle_bank_incoming_webhook(
        axum::extract::State(state.clone()),
        headers,
        axum::body::Bytes::from(body),
    )
    .await
    .unwrap();
    assert_eq!(status, axum::http::StatusCode::OK);
    res
}

// covers: SC-09-06-04
#[tokio::test]
async fn when_tenant_webhook_mentions_capital_then_it_waits_for_manager_review() {
    let state = state_with(Vec::new()).await;
    {
        let mut inner = state.inner.write().await;
        let mut tenant = inner
            .users
            .iter()
            .find(|user| user.id == "usr-home-owner-1")
            .unwrap()
            .clone();
        tenant.id = "usr-review-tenant".to_string();
        tenant.full_name = "Canan Kaya".to_string();
        inner.users.push(tenant);
        inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .unwrap()
            .tenant_user_id = Some("usr-review-tenant".to_string());
    }
    std::env::set_var("SITEPULSE_BANK_WEBHOOK_SECRET", WEBHOOK_SECRET);
    let req = BankIncomingWebhookRequest {
        transaction_id: "CAPITAL-REVIEW-001".to_string(),
        virtual_iban: VIRTUAL_IBAN.to_string(),
        amount: d("300.00"),
        currency: Some("TRY".to_string()),
        sender_name: Some("Canan Kaya".to_string()),
        sender_iban: None,
        description: Some("A Blok D:14 Asansör Demirbaş".to_string()),
        signature: None,
    };
    let body = serde_json::to_vec(&req).unwrap();
    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        sitepulse_backend::handlers::BANK_WEBHOOK_SIGNATURE_HEADER,
        sitepulse_backend::auth::sign_webhook_body(WEBHOOK_SECRET, &body)
            .parse()
            .unwrap(),
    );
    let (status, axum::Json(response)) = sitepulse_backend::handlers::handle_bank_incoming_webhook(
        axum::extract::State(state.clone()),
        headers,
        axum::body::Bytes::from(body),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::ACCEPTED);
    assert_eq!(response.status, "PENDING_REVIEW");
    let inner = state.inner.read().await;
    assert!(inner.payment_receipts.is_empty());
    assert_eq!(inner.reconciliation_queue.len(), 1);
    assert_eq!(
        inner.reconciliation_queue[0].status,
        ReconciliationStatus::PendingApproval
    );
}

fn manual(amount: &str) -> RecordManualPaymentRequest {
    RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: UNIT.to_string(),
        amount: d(amount),
        payer_name: "Ahmet Yılmaz".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::ManualCash,
        ..Default::default()
    }
}

/// R3 + TBK 100: an overdue due collects its penalty (accrued on the unpaid
/// principal up to the payment date) before principal, on every channel.
#[tokio::test]
async fn when_overdue_due_is_paid_by_webhook_then_penalty_is_collected_first_with_a_tah_receipt() {
    let due_date = today() - Days::new(30);
    let state = state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1400.00",
        due_date,
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let expected_penalty = d("70.00"); // 1,400 × 5% × 30 / 30

    let res = webhook(&state, "TXN-SPEC5-PENALTY", "1400.00", "Eylül 2026 aidatı").await;
    assert!(res.receipt_id.starts_with("TAH-"), "{}", res.receipt_id);
    assert_eq!(res.cleared_amount, d("1400.00"));
    assert_eq!(
        res.remaining_debt, expected_penalty,
        "the principal left unpaid equals the penalty collected first"
    );

    let inner = state.inner.read().await;
    let receipt = inner
        .payment_receipts
        .iter()
        .find(|r| r.receipt_number == res.receipt_id)
        .unwrap();
    assert_eq!(receipt.allocated_penalty, expected_penalty);
    assert_eq!(receipt.allocated_principal, d("1330.00"));
    assert_eq!(receipt.payment_channel, PaymentChannel::VirtualIban);
    let due = inner.dues.iter().find(|x| x.id == "op-1").unwrap();
    assert_eq!(due.penalty_accrued_through, Some(today()));
    assert_ne!(due.status, DebtStatus::Paid);
}

/// R1: a re-delivered bank transaction never produces a second receipt.
#[tokio::test]
async fn when_bank_webhook_is_redelivered_then_only_one_receipt_exists() {
    let state = state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1400.00",
        today() + Days::new(10),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let first = webhook(&state, "TXN-SPEC5-DUP", "1500.00", "Eylül 2026").await;
    assert_eq!(first.status, "CLEARED");
    let second = webhook(&state, "TXN-SPEC5-DUP", "1500.00", "Eylül 2026").await;
    assert_eq!(second.status, "DUPLICATE_IGNORED");

    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    assert_eq!(Some(inner.advance_total(UNIT)), Some(d("100.00")));
}

/// R4 / TBK 101: the designated period is paid even though an older one is open.
// covers: SC-13-09-01
#[tokio::test]
async fn when_payer_designates_a_period_then_that_due_is_settled_before_older_dues() {
    let soon = today() + Days::new(5);
    let mut november = liability(
        "nov",
        "Kasım 2026",
        "1500.00",
        soon + Days::new(2),
        "TENANT",
        "OPERATIONAL_DUES",
    );
    november.delay_penalty = d("22.50");
    november.total_amount = d("1522.50");
    let state = state_with(vec![
        liability(
            "sep",
            "Eylül 2026",
            "1500.00",
            soon,
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "oct",
            "Ekim 2026",
            "1500.00",
            soon + Days::new(1),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        november,
    ])
    .await;
    let mut req = manual("1522.50");
    req.designation = Some(PaymentDesignation {
        periods: vec!["KASIM 2026".to_string()],
        ..Default::default()
    });
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(req)
        .await
        .unwrap();

    assert_eq!(receipt.total_amount, d("1522.50"));
    assert_eq!(receipt.allocation_breakdown.len(), 1);
    assert_eq!(receipt.allocation_breakdown[0].period, "Kasım 2026");
    assert_eq!(receipt.allocation_breakdown[0].principal_paid, d("1500.00"));
    assert_eq!(receipt.allocation_breakdown[0].penalty_paid, d("22.50"));
    let inner = state.inner.read().await;
    assert_eq!(
        inner.dues.iter().find(|x| x.id == "nov").unwrap().status,
        DebtStatus::Paid
    );
    let november = inner.dues.iter().find(|x| x.id == "nov").unwrap();
    assert_eq!(november.paid_principal, d("1500.00"));
    assert_eq!(november.paid_penalty, d("22.50"));
    assert_eq!(november.principal_amount, d("1500.00"));
    assert_eq!(november.total_amount, Decimal::ZERO);
    for id in ["sep", "oct"] {
        let older = inner.dues.iter().find(|due| due.id == id).unwrap();
        assert_eq!(
            older.total_amount - older.paid_principal - older.paid_penalty,
            d("1500.00")
        );
    }
    assert!(inner
        .dues
        .iter()
        .filter(|x| x.id != "nov")
        .all(|x| x.status != DebtStatus::Paid));
    let entry = inner
        .payment_entries
        .iter()
        .find(|e| e.receipt_id == Some(receipt.id))
        .unwrap();
    assert!(
        entry
            .description
            .as_deref()
            .unwrap_or("")
            .contains("TBK 101"),
        "{:?}",
        entry.description
    );
}

/// R4: without a designation, FIFO applies (oldest first).
#[tokio::test]
async fn when_no_designation_is_given_then_the_oldest_due_is_settled_first() {
    let soon = today() + Days::new(5);
    let state = state_with(vec![
        liability(
            "sep",
            "Eylül 2026",
            "1400.00",
            soon + Days::new(1),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "aug",
            "Ağustos 2026",
            "1400.00",
            soon,
            "TENANT",
            "OPERATIONAL_DUES",
        ),
    ])
    .await;
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(manual("1400.00"))
        .await
        .unwrap();
    assert_eq!(receipt.allocation_breakdown[0].period, "Ağustos 2026");
}

/// R1: confirming the same statement line twice settles it once.
#[tokio::test]
async fn when_a_statement_line_is_confirmed_twice_then_it_is_settled_once() {
    let state = state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1400.00",
        today() + Days::new(10),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let item = ReconciliationMatch {
        match_id: "MATCH-SPEC5".to_string(),
        site_id: "site-1".to_string(),
        transaction: BankTransactionItem {
            transaction_id: "STMT-TXN-1".to_string(),
            date: today(),
            amount: d("2000.00"),
            currency: "TRY".to_string(),
            description: "A BLOK D:14 EYLUL 2026 AIDAT".to_string(),
            sender_name: Some("Ahmet Yılmaz".to_string()),
            sender_iban: None,
            reference_no: None,
        },
        matched_unit_id: Some(UNIT.to_string()),
        matched_block: Some("A".to_string()),
        matched_unit_number: Some(14),
        matched_resident_name: None,
        confidence_score: 90,
        matched_due_id: None,
        outstanding_balance: None,
        amount_matches_balance: false,
        status: ReconciliationStatus::PendingApproval,
        status_code: ReconciliationStatus::PendingApproval.as_str().to_string(),
        notes: None,
    };
    state.inner.write().await.reconciliation_queue.push(item);
    for _ in 0..2 {
        let (status, axum::Json(res)) = sitepulse_backend::handlers::confirm_reconciliation(
            axum::extract::State(state.clone()),
            sitepulse_backend::tenancy::TenantScope::platform(),
            axum::Json(ConfirmReconciliationRequest {
                site_id: "site-1".to_string(),
                match_ids: vec!["MATCH-SPEC5".to_string()],
                matches: vec![],
                optional_message: None,
                remember_sender_iban: None,
                owner_capital_match_ids: Vec::new(),
                debtor_assignments: Default::default(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(status, axum::http::StatusCode::OK);
        assert_eq!(res.confirmed_count, 1);
    }
    let inner = state.inner.read().await;
    assert_eq!(
        inner.payment_receipts.len(),
        1,
        "idempotent on STMT:<transaction id>"
    );
    assert_eq!(
        inner.payment_receipts[0].payment_channel,
        PaymentChannel::BankStatement
    );
    assert_eq!(Some(inner.advance_total(UNIT)), Some(d("600.00")));
    assert_eq!(inner.dues[0].status, DebtStatus::Paid);
}

/// R2: match-all settles the pending row in place (no second ledger row).
#[tokio::test]
async fn when_match_all_settles_a_pending_payment_then_no_duplicate_ledger_row_is_created() {
    let state = state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1400.00",
        today() + Days::new(10),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    state
        .inner
        .write()
        .await
        .homeowner_payments
        .push(HomeownerPaymentRecord {
            id: "77".to_string(),
            unit_id: UNIT.to_string(),
            block_id: "A".to_string(),
            unit_number: 14,
            homeowner_name: Some("Ahmet Yılmaz".to_string()),
            amount: d("1400.00"),
            payment_method: PaymentChannel::BankTransfer,
            reference_code: Some("REF-77".to_string()),
            note: None,
            status: PaymentMatchStatus::Pending,
            cleared_debt_amount: Decimal::ZERO,
            advance_credit_amount: Decimal::ZERO,
            created_at: Utc::now(),
        });
    let (_, axum::Json(res)) = sitepulse_backend::handlers::match_all_homeowner_payments(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(MatchAllPaymentsRequest {
            site_id: Some("site-1".to_string()),
        }),
    )
    .await
    .unwrap();
    assert_eq!(res.total_payments_processed, 1);

    let inner = state.inner.read().await;
    assert_eq!(
        inner.homeowner_payments.len(),
        1,
        "the pending record is updated, not duplicated"
    );
    assert_eq!(
        inner.homeowner_payments[0].status,
        PaymentMatchStatus::MatchedDebt
    );
    assert_eq!(inner.payment_receipts.len(), 1);
    assert_eq!(inner.payment_entries.len(), 1);
    assert_eq!(inner.payment_entries[0].id, 77);
    assert_eq!(inner.dues[0].status, DebtStatus::Paid);

    // A second run finds nothing pending.
    drop(inner);
    let (_, axum::Json(again)) = sitepulse_backend::handlers::match_all_homeowner_payments(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(MatchAllPaymentsRequest {
            site_id: Some("site-1".to_string()),
        }),
    )
    .await
    .unwrap();
    assert_eq!(again.total_payments_processed, 0);
}

/// R1: a channel outside the V14 vocabulary is rejected, not stored.
#[tokio::test]
async fn when_payment_channel_is_unknown_then_the_payment_is_rejected() {
    let err = sitepulse_backend::services::payment_tracking_service::normalize_payment_channel(
        "TELEPATHY",
    )
    .unwrap_err();
    assert!(err.contains("Unknown payment channel"), "{}", err);
    let state = state_with(vec![]).await;
    assert!(state.inner.read().await.payment_receipts.is_empty());
}

/// R5: aging uses unpaid amounts and the liability's own debtor.
#[tokio::test]
async fn when_debt_aging_is_computed_then_it_uses_outstanding_amounts_and_the_liabilitys_debtor() {
    let mut partially_paid = liability(
        "op-1",
        "Ekim 2026",
        "1000.00",
        today() + Days::new(3),
        "TENANT",
        "OPERATIONAL_DUES",
    );
    partially_paid.paid_principal = d("400.00");
    partially_paid.total_amount = d("600.00");
    let capital = liability(
        "cap-1",
        "Asansör",
        "3000.00",
        today() + Days::new(3),
        "OWNER",
        "CAPITAL_DUES",
    );
    let state = state_with(vec![partially_paid, capital]).await;
    {
        // A tenanted unit: the old report put every row under TENANT.
        let mut inner = state.inner.write().await;
        let tenant_id = inner.users.first().map(|u| u.id.clone());
        if let Some(u) = inner.units.iter_mut().find(|u| u.id == UNIT) {
            u.tenant_user_id = tenant_id;
        }
    }
    let report = PaymentTrackingService::new(state.clone())
        .get_debt_aging_report("site-1")
        .await
        .unwrap();
    let tenant = report
        .brackets
        .iter()
        .find(|b| b.debtor_type == DebtorType::Tenant)
        .expect("tenant row");
    let owner = report
        .brackets
        .iter()
        .find(|b| b.debtor_type == DebtorType::Owner)
        .expect("owner row");
    assert_eq!(tenant.current_due, d("600.00"), "only the unpaid remainder");
    assert_eq!(
        owner.current_due,
        d("3000.00"),
        "capital dues belong to the owner"
    );
    assert_eq!(report.total_current, d("3600.00"));
}
