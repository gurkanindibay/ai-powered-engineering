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
        req.debtor_assignments
            .insert(match_id.to_string(), debtor.into());
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

// Issue #278: approving held transfer for TENANT resolves to active tenant, settles their debt, and names them as payer.
#[tokio::test]
async fn when_held_transfer_approved_for_tenant_then_settles_active_tenant_charges() {
    let state = state_with(vec![
        DuesLiability {
            liable_person_id: Some(101),
            ..due("owner-sept", DebtorType::Owner)
        },
        DuesLiability {
            liable_person_id: Some(102),
            ..due("selin-oct", DebtorType::Tenant)
        },
        DuesLiability {
            liable_person_id: Some(103),
            ..due("mert-nov", DebtorType::Tenant)
        },
    ])
    .await;
    {
        let mut inner = state.inner.write().await;
        inner.unit_occupancies.insert(
            UNIT.to_string(),
            vec![
                OccupancyHistoryItem {
                    id: 1,
                    unit_id: 14,
                    person_id: 101,
                    person_name: "Ahmet Yılmaz".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Owner,
                    start_date: "2026-01-01".to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
                OccupancyHistoryItem {
                    id: 2,
                    unit_id: 14,
                    person_id: 102,
                    person_name: "Selin Demir".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-10-01".to_string(),
                    end_date: Some("2026-10-31".to_string()),
                    is_active: false,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
                OccupancyHistoryItem {
                    id: 3,
                    unit_id: 14,
                    person_id: 103,
                    person_name: "Mert Kılıç".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-11-01".to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
            ],
        );
        if let Some(u) = inner.units.iter_mut().find(|u| u.id == UNIT) {
            u.owner_user_id = Some("person-101".to_string());
            u.tenant_user_id = Some("person-103".to_string());
        }
    }

    let res = send(&state, webhook("TX-MD-278-1", None)).await;
    assert_eq!(res.status, "UNMATCHED");
    assert_eq!(res.message, "several open debtors");

    let match_id = state.inner.read().await.reconciliation_queue[0]
        .match_id
        .clone();

    let done = confirm(&state, &match_id, Some(DebtorType::Tenant))
        .await
        .unwrap();
    assert_eq!(done.confirmed_count, 1);

    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    let receipt = &inner.payment_receipts[0];
    assert_eq!(receipt.payer_name, "Mert Kılıç");
    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.payer_person_id, Some(103));
    assert_eq!(receipt.allocated_principal, d("800.00"));
    assert_eq!(receipt.allocated_advance, Decimal::ZERO);

    let by = |id: &str| {
        inner
            .dues
            .iter()
            .find(|x| x.id == id)
            .unwrap()
            .paid_principal
    };
    assert_eq!(by("mert-nov"), d("800.00"));
    assert_eq!(by("selin-oct"), Decimal::ZERO);
    assert_eq!(by("owner-sept"), Decimal::ZERO);
}

// Issue #278: approving held transfer by specific person name settles that person's open liabilities.
#[tokio::test]
async fn when_held_transfer_approved_by_person_name_then_settles_that_person() {
    let state = state_with(vec![
        DuesLiability {
            liable_person_id: Some(101),
            ..due("owner-sept", DebtorType::Owner)
        },
        DuesLiability {
            liable_person_id: Some(102),
            ..due("selin-oct", DebtorType::Tenant)
        },
        DuesLiability {
            liable_person_id: Some(103),
            ..due("mert-nov", DebtorType::Tenant)
        },
    ])
    .await;
    {
        let mut inner = state.inner.write().await;
        inner.unit_occupancies.insert(
            UNIT.to_string(),
            vec![
                OccupancyHistoryItem {
                    id: 2,
                    unit_id: 14,
                    person_id: 102,
                    person_name: "Selin Demir".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-10-01".to_string(),
                    end_date: Some("2026-10-31".to_string()),
                    is_active: false,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
                OccupancyHistoryItem {
                    id: 3,
                    unit_id: 14,
                    person_id: 103,
                    person_name: "Mert Kılıç".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-11-01".to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
            ],
        );
    }

    send(&state, webhook("TX-MD-278-2", None)).await;
    let match_id = state.inner.read().await.reconciliation_queue[0]
        .match_id
        .clone();

    // Manager assigns to Selin Demir specifically
    let mut req = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        ..Default::default()
    };
    req.debtor_assignments.insert(
        match_id,
        DebtorAssignment::Person("Selin Demir".to_string()),
    );

    let (_, axum::Json(done)) = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req),
    )
    .await
    .unwrap();
    assert_eq!(done.confirmed_count, 1);

    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    let receipt = &inner.payment_receipts[0];
    assert_eq!(receipt.payer_name, "Selin Demir");
    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.payer_person_id, Some(102));
    assert_eq!(receipt.allocated_principal, d("800.00"));
    assert_eq!(receipt.allocated_advance, Decimal::ZERO);

    let by = |id: &str| {
        inner
            .dues
            .iter()
            .find(|x| x.id == id)
            .unwrap()
            .paid_principal
    };
    assert_eq!(by("selin-oct"), d("800.00"));
    assert_eq!(by("mert-nov"), Decimal::ZERO);
    assert_eq!(by("owner-sept"), Decimal::ZERO);
}

#[tokio::test]
async fn when_unit_has_duplicate_tenant_names_then_assigning_by_person_id_settles_the_intended_person(
) {
    let state = state_with(vec![
        due("owner-sept", DebtorType::Owner),
        DuesLiability {
            liable_person_id: Some(102),
            ..due("mert-former-oct", DebtorType::Tenant)
        },
        DuesLiability {
            liable_person_id: Some(103),
            ..due("mert-current-nov", DebtorType::Tenant)
        },
    ])
    .await;
    {
        let mut inner = state.inner.write().await;
        inner.unit_occupancies.insert(
            UNIT.to_string(),
            vec![
                OccupancyHistoryItem {
                    id: 2,
                    unit_id: 14,
                    person_id: 102,
                    person_name: "Mert Kılıç".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-10-01".to_string(),
                    end_date: Some("2026-10-31".to_string()),
                    is_active: false,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
                OccupancyHistoryItem {
                    id: 3,
                    unit_id: 14,
                    person_id: 103,
                    person_name: "Mert Kılıç".to_string(),
                    person_phone: None,
                    person_email: None,
                    role: DebtorType::Tenant,
                    start_date: "2026-11-01".to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: None,
                    created_at: chrono::Utc::now(),
                },
            ],
        );
    }

    send(&state, webhook("TX-MD-278-DUP", None)).await;
    let match_id = state.inner.read().await.reconciliation_queue[0]
        .match_id
        .clone();

    // Assigning by ambiguous name fails because two distinct people share the same name on this unit
    let mut ambiguous_req = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        ..Default::default()
    };
    ambiguous_req.debtor_assignments.insert(
        match_id.clone(),
        DebtorAssignment::Person("Mert Kılıç".to_string()),
    );
    let amb_err = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ambiguous_req),
    )
    .await
    .unwrap_err();
    assert_eq!(amb_err.0, axum::http::StatusCode::UNPROCESSABLE_ENTITY);
    assert!(amb_err.1.contains("ambiguous"));
    assert!(state.inner.read().await.payment_receipts.is_empty());

    // Assigning explicitly by PersonId(102) resolves to the former tenant without ambiguity
    let mut pid_req = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        ..Default::default()
    };
    pid_req
        .debtor_assignments
        .insert(match_id, DebtorAssignment::PersonId(102));

    let (_, axum::Json(done)) = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(pid_req),
    )
    .await
    .unwrap();
    assert_eq!(done.confirmed_count, 1);

    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    let receipt = &inner.payment_receipts[0];
    assert_eq!(receipt.payer_name, "Mert Kılıç");
    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.payer_person_id, Some(102));
    assert_eq!(receipt.allocated_principal, d("800.00"));
    assert_eq!(receipt.allocated_advance, Decimal::ZERO);

    let by = |id: &str| {
        inner
            .dues
            .iter()
            .find(|x| x.id == id)
            .unwrap()
            .paid_principal
    };
    assert_eq!(by("mert-former-oct"), d("800.00"));
    assert_eq!(by("mert-current-nov"), Decimal::ZERO);
    assert_eq!(by("owner-sept"), Decimal::ZERO);
}

#[tokio::test]
async fn when_debtor_assignment_is_invalid_or_unknown_then_rejected_and_match_remains_unmatched() {
    let state = state_with(vec![
        due("owner-sept", DebtorType::Owner),
        due("tenant-nov", DebtorType::Tenant),
    ])
    .await;

    send(&state, webhook("TX-MD-278-INV", None)).await;
    let match_id = state.inner.read().await.reconciliation_queue[0]
        .match_id
        .clone();

    // 1) Unknown person ID
    let mut req1 = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        ..Default::default()
    };
    req1.debtor_assignments
        .insert(match_id.clone(), DebtorAssignment::PersonId(9999));
    let err1 = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req1),
    )
    .await
    .unwrap_err();
    assert_eq!(err1.0, axum::http::StatusCode::UNPROCESSABLE_ENTITY);
    assert!(err1.1.contains("not valid for unit"));

    // 2) Unknown person name
    let mut req2 = ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        ..Default::default()
    };
    req2.debtor_assignments.insert(
        match_id.clone(),
        DebtorAssignment::Person("Bilinmeyen Biri".to_string()),
    );
    let err2 = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req2),
    )
    .await
    .unwrap_err();
    assert_eq!(err2.0, axum::http::StatusCode::UNPROCESSABLE_ENTITY);
    assert!(err2.1.contains("not valid for unit"));

    // Queue item remains UNMATCHED and no receipts were created
    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 0);
    assert_eq!(inner.reconciliation_queue.len(), 1);
    assert_eq!(
        inner.reconciliation_queue[0].status,
        ReconciliationStatus::Unmatched
    );
}
