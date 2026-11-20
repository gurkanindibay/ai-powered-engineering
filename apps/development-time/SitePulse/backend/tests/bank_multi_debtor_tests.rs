//! Issue 208: a unit-level bank transfer with several open debtors is never auto-matched.

use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::state::AppState;

const VIBAN: &str = "TR410020504213991067000014";
const UNIT: &str = "d-14";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn due(id: &str, debtor: DebtorType) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: "Kasım 2026".to_string(),
        principal_amount: d("800.00"),
        delay_penalty: Decimal::ZERO,
        total_amount: d("800.00"),
        due_date: chrono::Utc::now().date_naive() + chrono::Days::new(15),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: debtor,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
    }
}

async fn state_with(dues: Vec<DuesLiability>) -> AppState {
    let state = AppState::new();
    {
        let mut inner = state.inner.write().await;
        inner.dues.retain(|x| x.unit_id != UNIT);
        inner.dues.extend(dues);
        inner.reconciliation_queue.clear();
    }
    state
}

fn webhook(txn: &str, sender: Option<&str>) -> BankIncomingWebhookRequest {
    BankIncomingWebhookRequest {
        transaction_id: txn.to_string(),
        virtual_iban: VIBAN.to_string(),
        amount: d("800.00"),
        currency: Some("TRY".to_string()),
        sender_name: sender.map(str::to_string),
        sender_iban: None,
        description: None,
        signature: None,
    }
}

async fn send(state: &AppState, req: BankIncomingWebhookRequest) -> BankIncomingWebhookResponse {
    let (_, axum::Json(res)) =
        sitepulse_backend::handlers::process_bank_incoming_webhook(state.clone(), req)
            .await
            .unwrap();
    res
}

async fn confirm(
    state: &AppState,
    match_id: &str,
    debtor: Option<DebtorType>,
) -> Result<ConfirmReconciliationResponse, (axum::http::StatusCode, String)> {
    let mut req = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.to_string()],
        matches: vec![],
        optional_message: None,
        remember_sender_iban: None,
        owner_capital_match_ids: Vec::new(),
        debtor_assignments: Default::default(),
    };
    if let Some(debtor) = debtor {
        req.debtor_assignments.insert(match_id.to_string(), debtor);
    }
    sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req),
    )
    .await
    .map(|(_, axum::Json(res))| res)
}

// covers: SC-07-03-03, SC-13-12-05
#[tokio::test]
async fn when_unit_has_several_open_debtors_then_transfer_is_held_unmatched_and_assigned_once() {
    let state = state_with(vec![
        due("md-owner", DebtorType::Owner),
        due("md-tenant", DebtorType::Tenant),
    ])
    .await;

    let res = send(&state, webhook("TX-MD-01", None)).await;
    assert_eq!(res.status, "UNMATCHED");
    assert_eq!(res.message, "several open debtors");
    {
        let inner = state.inner.read().await;
        assert!(inner.payment_receipts.is_empty());
        assert!(inner
            .dues
            .iter()
            .filter(|x| x.unit_id == UNIT)
            .all(|x| x.paid_principal == Decimal::ZERO));
        assert_eq!(inner.reconciliation_queue.len(), 1);
        let held = &inner.reconciliation_queue[0];
        assert_eq!(held.status, ReconciliationStatus::Unmatched);
        assert_eq!(held.notes.as_deref(), Some("several open debtors"));
    }
    let match_id = state.inner.read().await.reconciliation_queue[0]
        .match_id
        .clone();

    // Approving without choosing a debtor is refused and settles nothing.
    let refused = confirm(&state, &match_id, None).await.unwrap_err();
    assert_eq!(refused.0, axum::http::StatusCode::UNPROCESSABLE_ENTITY);
    assert!(state.inner.read().await.payment_receipts.is_empty());

    // The manager assigns the tenant and approves once.
    let done = confirm(&state, &match_id, Some(DebtorType::Tenant))
        .await
        .unwrap();
    assert_eq!(done.confirmed_count, 1);
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.payment_receipts.len(), 1);
        let by = |id: &str| {
            inner
                .dues
                .iter()
                .find(|x| x.id == id)
                .unwrap()
                .paid_principal
        };
        assert_eq!(by("md-tenant"), d("800.00"));
        assert_eq!(by("md-owner"), Decimal::ZERO);
    }

    // A second approval is refused and adds no receipt.
    let again = confirm(&state, &match_id, Some(DebtorType::Tenant))
        .await
        .unwrap_err();
    assert_eq!(again.0, axum::http::StatusCode::CONFLICT);
    assert_eq!(state.inner.read().await.payment_receipts.len(), 1);
}

// covers: SC-07-03-04, SC-13-12-05
#[tokio::test]
async fn when_held_transfer_is_delivered_again_then_it_is_a_duplicate_and_adds_no_queue_item() {
    let state = state_with(vec![
        due("md-owner", DebtorType::Owner),
        due("md-tenant", DebtorType::Tenant),
    ])
    .await;
    send(&state, webhook("TX-MD-02", None)).await;
    let again = send(&state, webhook("TX-MD-02", None)).await;
    assert_eq!(again.status, "DUPLICATE_IGNORED");
    assert_eq!(state.inner.read().await.reconciliation_queue.len(), 1);
}

#[tokio::test]
async fn when_unit_has_one_open_debtor_then_transfer_still_matches_automatically() {
    let state = state_with(vec![due("md-tenant", DebtorType::Tenant)]).await;
    let res = send(&state, webhook("TX-MD-03", None)).await;
    assert_eq!(res.status, "CLEARED");
    assert_eq!(state.inner.read().await.payment_receipts.len(), 1);
}
