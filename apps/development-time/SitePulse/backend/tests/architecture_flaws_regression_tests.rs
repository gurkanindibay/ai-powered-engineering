mod support;
// Regression test suite verifying architectural flaw resolutions (AF-01 through AF-10 and NV-01 through NV-07).

use axum::body::Body;
use axum::http::{Request, StatusCode};
use rust_decimal::Decimal;
use sitepulse_backend::{
    app::build_router,
    models::{
        BankTransactionItem, ConfirmReconciliationRequest, PaymentStreamFilter,
        PendingRegistrationResponse, ReconciliationMatch, ReconciliationStatus, RegistrationStatus,
        Role,
    },
    services::PaymentTrackingService,
    state::AppState,
};
use tower::ServiceExt;

#[tokio::test]
async fn test_cross_tenant_reconciliation_confirmation_blocked() {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        // Match belongs to site-1
        inner.reconciliation_queue.push(ReconciliationMatch {
            match_id: "MATCH-SITE1-01".to_string(),
            site_id: "site-1".to_string(),
            transaction: BankTransactionItem {
                transaction_id: "TXN-01".to_string(),
                date: chrono::NaiveDate::from_ymd_opt(2026, 11, 1).unwrap(),
                amount: Decimal::new(1000, 0),
                currency: "TRY".to_string(),
                description: "Aidat".to_string(),
                sender_name: Some("Ali Veli".to_string()),
                sender_iban: None,
                reference_no: None,
            },
            matched_unit_id: Some("d-14".to_string()),
            matched_block: Some("A".to_string()),
            matched_unit_number: Some(14),
            matched_resident_name: Some("Ali Veli".to_string()),
            confidence_score: 100,
            matched_due_id: None,
            outstanding_balance: Some(Decimal::new(1000, 0)),
            amount_matches_balance: true,
            status: ReconciliationStatus::PendingApproval,
            status_code: "ONAY_BEKLIYOR".to_string(),
            notes: None,
        });
    }

    let app = build_router(state.clone());
    // Manager of site-2 attempts to confirm site-1's match
    let token = support::token(&state, "mgr-site-2", Role::SiteManager, "site-2", None).await;
    let payload = ConfirmReconciliationRequest {
        site_id: "site-2".to_string(),
        match_ids: vec!["MATCH-SITE1-01".to_string()],
        matches: vec![],
        optional_message: None,
        remember_sender_iban: None,
        owner_capital_match_ids: Vec::new(),
        debtor_assignments: Default::default(),
    };

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/bank/statements/confirm-reconciliation")
        .header("authorization", format!("Bearer {}", token))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert!(matches!(
        resp.status(),
        StatusCode::FORBIDDEN | StatusCode::NOT_FOUND
    ));
}

#[tokio::test]
async fn test_cross_tenant_registration_approval_blocked() {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .pending_registrations
            .push(PendingRegistrationResponse {
                request_id: "req-site-1-99".to_string(),
                site_id: "site-1".to_string(),
                block: "A Blok".to_string(),
                unit_no: 10,
                floor: 3,
                full_name: "Yabanci Basvuru".to_string(),
                email: "yabanci@sitepulse.io".to_string(),
                phone: "05551112233".to_string(),
                is_resident: true,
                status: RegistrationStatus::Pending,
                submitted_at: chrono::Utc::now(),
            });
    }

    let app = build_router(state.clone());
    // Site manager of site-2 attempts to approve site-1's pending application
    let token = support::token(&state, "mgr-site-2", Role::SiteManager, "site-2", None).await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/registration/approve/req-site-1-99")
        .header("authorization", format!("Bearer {}", token))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert!(matches!(
        resp.status(),
        StatusCode::FORBIDDEN | StatusCode::NOT_FOUND
    ));
}

#[tokio::test]
async fn test_reject_registration_already_processed_blocked() {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .pending_registrations
            .push(PendingRegistrationResponse {
                request_id: "req-already-approved".to_string(),
                site_id: "site-1".to_string(),
                block: "A Blok".to_string(),
                unit_no: 12,
                floor: 3,
                full_name: "Onaylanmis Basvuru".to_string(),
                email: "onayli@sitepulse.io".to_string(),
                phone: "05551112233".to_string(),
                is_resident: true,
                status: RegistrationStatus::Approved,
                submitted_at: chrono::Utc::now(),
            });
    }

    let app = build_router(state.clone());
    let token = support::token(&state, "mgr-site-1", Role::SiteManager, "site-1", None).await;

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/registration/reject/req-already-approved")
        .header("authorization", format!("Bearer {}", token))
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // Cannot reject an application that is already processed (APPROVED)
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn test_recursive_body_inspection_rejects_nested_foreign_tenant() {
    let state = AppState::new_with_test_fixtures();
    let app = build_router(state.clone());
    let token = support::token(&state, "mgr-site-1", Role::SiteManager, "site-1", None).await;

    // Nested payload containing a foreign unit_id belonging to site-2
    let nested_payload = serde_json::json!({
        "data": {
            "batch": [
                { "unit_id": "d-999-site2" }
            ]
        }
    });

    let req = Request::builder()
        .method("POST")
        .uri("/api/v1/payments/record")
        .header("authorization", format!("Bearer {}", token))
        .header("content-type", "application/json")
        .body(Body::from(serde_json::to_vec(&nested_payload).unwrap()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // unit d-999-site2 is not found in site-1
    assert!(
        resp.status() == StatusCode::NOT_FOUND
            || resp.status() == StatusCode::FORBIDDEN
            || resp.status() == StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn test_payment_stream_pagination() {
    let state = AppState::new_with_test_fixtures();
    let service = PaymentTrackingService::new(state);

    let filter_p1 = PaymentStreamFilter {
        site_id: Some("site-1".to_string()),
        page: Some(1),
        page_size: Some(2),
        ..Default::default()
    };
    let stream_p1 = service.get_payment_stream(filter_p1).await.unwrap();
    assert!(stream_p1.entries.len() <= 2);

    let filter_p2 = PaymentStreamFilter {
        site_id: Some("site-1".to_string()),
        page: Some(2),
        page_size: Some(2),
        ..Default::default()
    };
    let stream_p2 = service.get_payment_stream(filter_p2).await.unwrap();
    assert!(stream_p2.entries.len() <= 2);
}
