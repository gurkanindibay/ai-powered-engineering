//! Issue 296 / SC-13-09-07: a manager assigns an unmatched statement item to a
//! unit and debtor, and confirm-reconciliation settles it exactly once.

use axum::body::Body;
use axum::extract::FromRequest;
use axum::http::{Request, StatusCode};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::state::AppState;

/// The seeded site account of Begonya Sitesi: a transfer here has no unit.
const SITE_IBAN: &str = "TR620020500009863791600001";
const SITE: &str = "site-1";
const UNIT: &str = "d-14";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).expect("fixture amount is a decimal")
}

fn due(id: &str, debtor: DebtorType, amount: &str) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: "Eylül 2026".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: chrono::Utc::now().date_naive() + chrono::Days::new(15),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: debtor,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
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

/// Files one transfer to the site account with no unit and no sender hint, so it
/// lands in the reconciliation queue as `UNMATCHED` (SC-13-09-07 given).
async fn import_unmatched(state: &AppState, transaction_id: &str, amount: &str) -> String {
    let payload = BankIncomingWebhookRequest {
        transaction_id: transaction_id.to_string(),
        virtual_iban: SITE_IBAN.to_string(),
        amount: d(amount),
        currency: Some("TRY".to_string()),
        sender_name: None,
        sender_iban: None,
        description: Some(String::new()),
        signature: None,
    };
    let (_, axum::Json(res)) =
        sitepulse_backend::handlers::process_bank_incoming_webhook(state.clone(), payload)
            .await
            .expect("the unmatched transfer is accepted");
    assert_eq!(res.status, "UNMATCHED");
    let inner = state.inner.read().await;
    let item = inner
        .reconciliation_queue
        .iter()
        .find(|m| m.transaction.transaction_id == transaction_id)
        .expect("the transfer is in the queue");
    assert_eq!(item.status, ReconciliationStatus::Unmatched);
    assert!(item.matched_unit_id.is_none());
    assert!(item.assigned_unit_id.is_none());
    item.match_id.clone()
}

async fn assign(
    state: &AppState,
    match_id: &str,
    site_id: &str,
    unit_id: &str,
    debtor_role: DebtorType,
) -> Result<ReconciliationMatch, (StatusCode, String)> {
    sitepulse_backend::handlers::assign_reconciliation_match(
        axum::extract::Path(match_id.to_string()),
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(AssignReconciliationMatchRequest {
            site_id: site_id.to_string(),
            unit_id: unit_id.to_string(),
            debtor_role,
        }),
    )
    .await
    .map(|axum::Json(m)| m)
}

async fn confirm(
    state: &AppState,
    match_id: &str,
) -> Result<ConfirmReconciliationResponse, (StatusCode, String)> {
    sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ConfirmReconciliationRequest {
            site_id: SITE.to_string(),
            match_ids: vec![match_id.to_string()],
            matches: vec![],
            optional_message: None,
            remember_sender_iban: None,
            owner_capital_match_ids: Vec::new(),
            debtor_assignments: Default::default(),
        }),
    )
    .await
    .map(|(_, axum::Json(res))| res)
}

async fn paid_principal(state: &AppState, due_id: &str) -> Decimal {
    state
        .inner
        .read()
        .await
        .dues
        .iter()
        .find(|x| x.id == due_id)
        .expect("fixture due exists")
        .paid_principal
}

// covers: SC-13-09-07
#[tokio::test]
async fn when_unmatched_item_is_assigned_then_confirm_settles_it_exactly_once() {
    let state = state_with(vec![
        due("stmt-owner", DebtorType::Owner, "1675.00"),
        due("stmt-tenant", DebtorType::Tenant, "1675.00"),
    ])
    .await;
    let state = &state;
    let match_id = import_unmatched(state, "TX-STMT-296", "1675.00").await;

    let assigned = assign(state, &match_id, SITE, UNIT, DebtorType::Tenant)
        .await
        .expect("the unmatched item is assigned to the unit");
    assert_eq!(assigned.assigned_unit_id.as_deref(), Some(UNIT));
    assert_eq!(assigned.assigned_debtor_role, Some(DebtorType::Tenant));
    assert!(assigned.matched_unit_id.is_none());
    assert_eq!(assigned.status, ReconciliationStatus::Unmatched);

    // Assigning the same pair again succeeds and does not duplicate the item.
    let again = assign(state, &match_id, SITE, UNIT, DebtorType::Tenant)
        .await
        .expect("assigning the same pair is idempotent");
    assert_eq!(again.match_id, match_id);
    assert_eq!(state.inner.read().await.reconciliation_queue.len(), 1);

    let done = confirm(state, &match_id).await.expect("the item settles");
    assert_eq!(done.confirmed_count, 1);
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.payment_receipts.len(), 1);
        assert_eq!(inner.payment_entries.len(), 1);
        let item = inner
            .reconciliation_queue
            .iter()
            .find(|m| m.match_id == match_id)
            .expect("the item stays in the queue");
        assert_eq!(item.status, ReconciliationStatus::Approved);
        assert_eq!(item.assigned_unit_id.as_deref(), Some(UNIT));
        assert_eq!(item.assigned_debtor_role, Some(DebtorType::Tenant));
    }
    // The assigned debtor paid; the other debtor of the same unit was not touched.
    assert_eq!(paid_principal(state, "stmt-tenant").await, d("1675.00"));
    assert_eq!(paid_principal(state, "stmt-owner").await, Decimal::ZERO);

    // A retried approval is harmless: same receipt, same single entry, same allocations.
    let retry = confirm(state, &match_id)
        .await
        .expect("a repeated approval is idempotent");
    assert_eq!(retry.confirmed_count, 1);
    assert_eq!(retry.confirmed_matches.len(), 1);
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.payment_receipts.len(), 1);
        assert_eq!(inner.payment_entries.len(), 1);
        assert_eq!(inner.payment_receipts[0].allocation_breakdown.len(), 1);
    }
    assert_eq!(paid_principal(state, "stmt-tenant").await, d("1675.00"));
    assert_eq!(paid_principal(state, "stmt-owner").await, Decimal::ZERO);
}

#[tokio::test]
async fn when_assignment_is_invalid_then_it_is_refused_and_leaves_no_state() {
    let state = state_with(vec![due("stmt-owner", DebtorType::Owner, "1675.00")]).await;
    let state = &state;
    let match_id = import_unmatched(state, "TX-STMT-296-BAD", "1675.00").await;

    // Unknown match.
    let unknown = assign(state, "MATCH-DOES-NOT-EXIST", SITE, UNIT, DebtorType::Owner)
        .await
        .expect_err("an unknown match is refused");
    assert_eq!(unknown.0, StatusCode::NOT_FOUND);

    // Unit that is not part of the claimed site.
    let foreign_unit = assign(
        state,
        &match_id,
        SITE,
        "unit-of-another-site",
        DebtorType::Owner,
    )
    .await
    .expect_err("a unit outside the site is refused");
    assert_eq!(foreign_unit.0, StatusCode::NOT_FOUND);

    // A match that belongs to another site is never touched (tenant boundary).
    {
        let mut inner = state.inner.write().await;
        let mut foreign = inner
            .reconciliation_queue
            .iter()
            .find(|m| m.match_id == match_id)
            .expect("fixture item")
            .clone();
        foreign.match_id = "MATCH-FOREIGN-SITE".to_string();
        foreign.site_id = "site-2".to_string();
        inner.reconciliation_queue.push(foreign);
    }
    let foreign_match = assign(state, "MATCH-FOREIGN-SITE", SITE, UNIT, DebtorType::Owner)
        .await
        .expect_err("a match of another site is refused");
    assert_eq!(foreign_match.0, StatusCode::FORBIDDEN);

    let stored = state.inner.read().await;
    let item = stored
        .reconciliation_queue
        .iter()
        .find(|m| m.match_id == match_id)
        .expect("the fixture item exists");
    assert!(item.assigned_unit_id.is_none());
    assert!(item.assigned_debtor_role.is_none());
}

#[tokio::test]
async fn when_assignment_targets_an_approved_match_then_it_is_conflict() {
    let state = state_with(vec![due("stmt-owner", DebtorType::Owner, "1675.00")]).await;
    let state = &state;
    let match_id = import_unmatched(state, "TX-STMT-296-APPROVED", "1675.00").await;
    assign(state, &match_id, SITE, UNIT, DebtorType::Owner)
        .await
        .expect("the item is assigned");
    confirm(state, &match_id).await.expect("the item settles");

    let refused = assign(state, &match_id, SITE, UNIT, DebtorType::Owner)
        .await
        .expect_err("an approved item cannot be reassigned");
    assert_eq!(refused.0, StatusCode::CONFLICT);
}

#[tokio::test]
async fn when_assignment_targets_an_automatically_matched_item_then_it_is_conflict() {
    let state = state_with(vec![due("stmt-owner", DebtorType::Owner, "1675.00")]).await;
    let state = &state;
    let match_id = import_unmatched(state, "TX-STMT-296-MATCHED", "1675.00").await;
    {
        // An item a matching rule already resolved is not an assignment
        // candidate: confirmation would settle the automatic unit instead.
        let mut inner = state.inner.write().await;
        let item = inner
            .reconciliation_queue
            .iter_mut()
            .find(|m| m.match_id == match_id)
            .expect("the fixture item exists");
        item.matched_unit_id = Some(UNIT.to_string());
    }

    let refused = assign(state, &match_id, SITE, UNIT, DebtorType::Owner)
        .await
        .expect_err("an automatically matched item cannot be assigned");
    assert_eq!(refused.0, StatusCode::CONFLICT);
    let inner = state.inner.read().await;
    let item = inner
        .reconciliation_queue
        .iter()
        .find(|m| m.match_id == match_id)
        .expect("the fixture item exists");
    assert!(item.assigned_unit_id.is_none());
}

#[tokio::test]
async fn when_debtor_role_is_not_owner_or_tenant_then_the_body_is_unprocessable() {
    let request = Request::post("/api/v1/bank/statements/reconciliation-queue/MATCH-1/assign")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"site_id":"site-1","unit_id":"d-14","debtor_role":"JANITOR"}"#,
        ))
        .expect("the request is well formed");
    let rejection = axum::Json::<AssignReconciliationMatchRequest>::from_request(request, &())
        .await
        .expect_err("only OWNER and TENANT are accepted");
    // Axum answers a refused JSON body with 422 Unprocessable Entity.
    assert_eq!(rejection.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[test]
fn when_the_assignment_route_is_looked_up_then_it_requires_reconciliation_confirm() {
    use sitepulse_backend::authorization::RoutePolicy;
    use sitepulse_backend::models::Permission;

    let policy = sitepulse_backend::app::route_policy(
        "POST",
        "/api/v1/bank/statements/reconciliation-queue/{match_id}/assign",
    );
    assert!(matches!(
        policy,
        Some(RoutePolicy::Require(Permission::ReconciliationConfirm))
    ));
}
