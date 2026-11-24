mod support;
// HTTP-level security tests: drive the real router (middleware included) and
// assert authentication, role policy and tenant isolation.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use sitepulse_backend::{app::build_router, models::Role, state::AppState};
use tower::ServiceExt;

/// Every non-public route in the router, with a representative concrete path.
const PROTECTED_ROUTES: &[(&str, &str)] = &[
    ("GET", "/api/v1/residents/d-14/dashboard"),
    ("POST", "/api/v1/auth/change-password"),
    ("GET", "/api/v1/auth/me"),
    ("GET", "/api/v1/saas/sites"),
    ("POST", "/api/v1/saas/sites"),
    ("PUT", "/api/v1/saas/sites/site-1"),
    ("DELETE", "/api/v1/saas/sites/site-1"),
    ("POST", "/api/v1/saas/sites/site-1/reset-admin-password"),
    ("GET", "/api/v1/saas/stats"),
    ("GET", "/api/v1/site-admin/home-owners"),
    ("POST", "/api/v1/site-admin/home-owners"),
    ("PUT", "/api/v1/site-admin/home-owners/d-14"),
    ("DELETE", "/api/v1/site-admin/home-owners/d-14"),
    ("POST", "/api/v1/site-admin/units/d-14/move-out"),
    ("POST", "/api/v1/site-admin/units/d-14/move-in"),
    ("GET", "/api/v1/site-admin/units/d-14/occupancy-history"),
    ("GET", "/api/v1/site-admin/house-types"),
    ("POST", "/api/v1/site-admin/house-types"),
    ("DELETE", "/api/v1/site-admin/house-types/ht-1"),
    ("GET", "/api/v1/site-admin/blocks"),
    ("POST", "/api/v1/site-admin/blocks"),
    ("GET", "/api/v1/registration/invite-link"),
    ("GET", "/api/v1/registration/pending"),
    ("POST", "/api/v1/registration/approve/req-seed-01"),
    ("POST", "/api/v1/registration/reject/req-seed-01"),
    ("GET", "/api/v1/home-residents/invite-link/d-14"),
    ("GET", "/api/v1/home-residents/members/d-14"),
    ("POST", "/api/v1/home-residents/members/d-14"),
    ("DELETE", "/api/v1/home-residents/members/d-14/r-1"),
    ("PUT", "/api/v1/home-residents/members/d-14/r-1"),
    ("POST", "/api/v1/bank/statements/parse"),
    ("GET", "/api/v1/bank/statements/reconciliation-queue"),
    ("POST", "/api/v1/bank/statements/confirm-reconciliation"),
    ("GET", "/api/v1/site-admin/bank-account/site-1"),
    ("POST", "/api/v1/site-admin/bank-account/site-1"),
    ("GET", "/api/v1/units/d-14/virtual-iban"),
    ("GET", "/api/v1/bank/kuveyt-turk/status"),
    ("POST", "/api/v1/bank/kuveyt-turk/configure"),
    ("POST", "/api/v1/bank/kuveyt-turk/test-connection"),
    ("POST", "/api/v1/bank/remembered-ibans"),
    ("GET", "/api/v1/residents/d-14/matching-criteria"),
    ("POST", "/api/v1/residents/d-14/matching-criteria/ibans"),
    (
        "DELETE",
        "/api/v1/residents/d-14/matching-criteria/ibans/TR1",
    ),
    (
        "PUT",
        "/api/v1/residents/d-14/matching-criteria/payer-names",
    ),
    ("GET", "/api/v1/dues/periods"),
    ("POST", "/api/v1/dues/periods"),
    ("POST", "/api/v1/dues/accrue-period"),
    ("POST", "/api/v1/payments/record"),
    ("POST", "/api/v1/payments/match-all"),
    ("GET", "/api/v1/payments/homeowner-records"),
    ("GET", "/api/v1/payments/stream"),
    ("GET", "/api/v1/payments/debt-aging"),
    ("POST", "/api/v1/payments/record-manual"),
    ("POST", "/api/v1/payments/inter-ledger-transfer"),
    ("GET", "/api/v1/payments/receipts/1"),
    ("POST", "/api/v1/site-admin/units/d-14/transfer-ownership"),
    ("GET", "/api/v1/capital-projects"),
    ("POST", "/api/v1/capital-projects"),
    ("GET", "/api/v1/capital-projects/cproj-1"),
    ("GET", "/api/v1/capital-projects/cproj-1/installments"),
    (
        "POST",
        "/api/v1/capital-projects/cproj-1/accrue-installment",
    ),
    ("GET", "/api/v1/capital-projects/cproj-1/disbursements"),
    ("POST", "/api/v1/capital-projects/cproj-1/disbursements"),
    ("GET", "/api/v1/capital-projects/cproj-1/unit-shares"),
    ("GET", "/api/v1/site-admin/overview"),
    ("POST", "/api/v1/system/wipe-all-data"),
    ("POST", "/api/v1/system/purge-site/1"),
];

async fn call(
    app: Router,
    method: &str,
    path: &str,
    bearer: Option<&str>,
    body: Option<serde_json::Value>,
) -> (StatusCode, String) {
    let mut builder = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(t) = bearer {
        builder = builder.header("authorization", format!("Bearer {}", t));
    }
    let body = body
        .map(|b| Body::from(b.to_string()))
        .unwrap_or_else(|| Body::from("{}"));
    let resp = app.oneshot(builder.body(body).unwrap()).await.unwrap();
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    (status, String::from_utf8_lossy(&bytes).into_owned())
}

#[tokio::test]
async fn every_protected_route_returns_401_without_a_token() {
    let state = AppState::new_with_test_fixtures();
    for (method, path) in PROTECTED_ROUTES
        .iter()
        .filter(|(_, p)| !p.starts_with("/api/v1/system/"))
    {
        let (status, _) = call(build_router(state.clone()), method, path, None, None).await;
        assert_eq!(
            status,
            StatusCode::UNAUTHORIZED,
            "{} {} must require a token",
            method,
            path
        );
    }
}

#[tokio::test]
async fn forged_and_unsigned_tokens_are_rejected() {
    let state = AppState::new_with_test_fixtures();
    let real = support::token(&state, "usr-test", Role::HomeOwner, "site-1", Some("d-14")).await;
    let parts: Vec<&str> = real.split('.').collect();
    let admin_payload = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        r#"{"sub":"x","email":"x","role":"SAAS_ADMIN","site_id":"site-1","iat":0,"exp":9999999999}"#,
    );
    let forged = format!("{}.{}.{}", parts[0], admin_payload, parts[2]);
    let legacy = format!(
        "{}.{}.{}",
        parts[0], admin_payload, "c2lnX3NpdGVwdWxzZV92ZXJpZmllZF9ydXN0"
    );
    let none_alg = format!("eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.{}.", admin_payload);
    for t in [forged, legacy, none_alg, "garbage".to_string()] {
        let (status, _) = call(
            build_router(state.clone()),
            "GET",
            "/api/v1/saas/sites",
            Some(&t),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn public_routes_stay_reachable() {
    let state = AppState::new_with_test_fixtures();
    let (status, _) = call(build_router(state.clone()), "GET", "/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/banks",
        None,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn residents_cannot_reach_admin_or_other_units() {
    let state = AppState::new_with_test_fixtures();
    let owner = support::token(&state, "usr-test", Role::HomeOwner, "site-1", Some("d-14")).await;
    for (method, path) in [
        ("GET", "/api/v1/saas/sites"),
        ("GET", "/api/v1/site-admin/home-owners"),
        ("POST", "/api/v1/payments/record-manual"),
        ("POST", "/api/v1/bank/kuveyt-turk/configure"),
        ("DELETE", "/api/v1/saas/sites/site-1"),
    ] {
        let (status, _) = call(
            build_router(state.clone()),
            method,
            path,
            Some(&owner),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{} {}", method, path);
    }
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-99/dashboard",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/dashboard",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn site_managers_are_confined_to_their_site() {
    let state = AppState::new_with_test_fixtures();
    let other_manager = support::token(&state, "usr-test", Role::SiteManager, "site-2", None).await;
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/home-owners?site_id=site-1",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "explicit foreign site_id in query"
    );
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/bank-account/site-1",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "foreign site_id in path");
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/units/d-14/occupancy-history",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unit of a foreign site");
    let (status, _) = call(
        build_router(state.clone()),
        "POST",
        "/api/v1/payments/record-manual",
        Some(&other_manager),
        Some(serde_json::json!({ "site_id": "site-1", "unit_id": "d-14", "amount": "10.00" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "foreign site_id in body");

    // With no site_id at all, the request is pinned to the caller's own site (not site-1).
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/home-owners",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        !body.contains("d-14"),
        "site-2 manager must not see site-1 units: {}",
        body
    );

    let own_manager = support::token(&state, "usr-test", Role::SiteManager, "site-1", None).await;
    let (status, _) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/site-admin/units/d-14/occupancy-history",
        Some(&own_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn profile_comes_from_the_token_not_the_query() {
    let state = AppState::new_with_test_fixtures();
    let owner = support::token(
        &state,
        "usr-home-owner-1",
        Role::HomeOwner,
        "site-1",
        Some("d-14"),
    )
    .await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/auth/me?user_id=usr-saas-admin-1",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("ahmet.yilmaz@begonya.com"));
    assert!(!body.contains("SAAS_ADMIN"));
}

#[tokio::test]
async fn system_routes_are_not_routed_unless_explicitly_enabled() {
    let mut state = AppState::new_with_test_fixtures();
    state.settings.dev_routes_enabled = false;
    let admin = support::token(&state, "usr-test", Role::SaasAdmin, "", None).await;
    let (status, _) = call(
        build_router(state.clone()),
        "POST",
        "/api/v1/system/wipe-all-data",
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

/// Object-level isolation (BOLA): a capital project id in the path is not a
/// site id the middleware can check, so the handler must. Another site's
/// manager gets 404 (no existence oracle) on reads *and* on the writes that
/// would accrue dues on, or pay out from, the other site's project.
#[tokio::test]
async fn capital_projects_are_confined_to_their_site() {
    let state = AppState::new_with_test_fixtures();
    state.inner.write().await.accrue_test_due(); // seeds cproj-1 in site-1
    let own = support::token(&state, "mgr-1", Role::SiteManager, "site-1", None).await;
    let other = support::token(&state, "mgr-2", Role::SiteManager, "site-2", None).await;
    let app = build_router(state);

    let (status, _) = call(
        app.clone(),
        "GET",
        "/api/v1/capital-projects/cproj-1",
        Some(&own),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "the owning site reads its project");

    for (method, path, body) in [
        ("GET", "/api/v1/capital-projects/cproj-1", None),
        ("GET", "/api/v1/capital-projects/cproj-1/installments", None),
        ("GET", "/api/v1/capital-projects/cproj-1/unit-shares", None),
        (
            "GET",
            "/api/v1/capital-projects/cproj-1/disbursements",
            None,
        ),
        (
            "POST",
            "/api/v1/capital-projects/cproj-1/accrue-installment",
            Some(serde_json::json!({ "installment_number": 2 })),
        ),
        (
            "POST",
            "/api/v1/capital-projects/cproj-1/disbursements",
            Some(serde_json::json!({
                "milestone_name": "x", "amount": "1.00", "disbursement_date": "2026-11-01",
                "recipient_name": "x", "recipient_iban": "TR120006200000000000000099",
                "disbursement_method": "BANK_TRANSFER"
            })),
        ),
    ] {
        let (status, body_text) = call(app.clone(), method, path, Some(&other), body).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{} {} reached another tenant's project: {}",
            method,
            path,
            body_text
        );
    }
}

/// Payment listings are filtered to the caller's site even when the request
/// names no site at all.
#[tokio::test]
async fn homeowner_payment_records_are_confined_to_their_site() {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .homeowner_payments
            .push(sitepulse_backend::models::HomeownerPaymentRecord {
                id: "hp-leak".to_string(),
                unit_id: "d-14".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                homeowner_name: Some("Site One Payer".to_string()),
                amount: rust_decimal::Decimal::new(100, 0),
                payment_method: sitepulse_backend::models::PaymentChannel::ManualCash,
                reference_code: None,
                note: None,
                status: sitepulse_backend::models::PaymentMatchStatus::Pending,
                cleared_debt_amount: rust_decimal::Decimal::ZERO,
                advance_credit_amount: rust_decimal::Decimal::ZERO,
                created_at: chrono::Utc::now(),
            });
    }
    let mgr2 = support::token(&state, "mgr-2", Role::SiteManager, "site-2", None).await;
    let mgr1 = support::token(&state, "mgr-1", Role::SiteManager, "site-1", None).await;
    let app = build_router(state);
    let (status, body) = call(
        app.clone(),
        "GET",
        "/api/v1/payments/homeowner-records",
        Some(&mgr2),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(!body.contains("Site One Payer"), "leaked: {}", body);
    let (_, body) = call(
        app,
        "GET",
        "/api/v1/payments/homeowner-records",
        Some(&mgr1),
        None,
    )
    .await;
    assert!(
        body.contains("Site One Payer"),
        "own records missing: {}",
        body
    );
}

/// The web client sends `x-request-id` (correlation) with every call. A CORS
/// preflight that does not allow it makes the browser report "could not
/// connect" for every request, including login.
#[tokio::test]
async fn cors_preflight_allows_the_client_correlation_header() {
    let resp = build_router(AppState::new_with_test_fixtures())
        .oneshot(
            Request::builder()
                .method("OPTIONS")
                .uri("/api/v1/auth/login")
                .header("origin", "http://localhost:9190")
                .header("access-control-request-method", "POST")
                .header(
                    "access-control-request-headers",
                    "content-type,authorization,x-request-id",
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let allowed = resp
        .headers()
        .get("access-control-allow-headers")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    assert!(
        allowed.contains("x-request-id"),
        "preflight must allow x-request-id, got {:?} ({})",
        allowed,
        resp.status()
    );
}

// covers: SC-06-04-01
#[tokio::test]
async fn profile_reports_role_unit_and_permissions_of_the_signed_in_owner() {
    let state = AppState::new_with_test_fixtures();
    let owner = support::token(
        &state,
        "usr-home-owner-1",
        Role::HomeOwner,
        "site-1",
        Some("d-14"),
    )
    .await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/auth/me",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let profile: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(profile["role"], "HOME_OWNER");
    assert_eq!(profile["unit_id"], "d-14");
    let permissions = profile["permissions"].as_array().unwrap();
    assert!(permissions.iter().any(|p| p == "UNIT_INVITE_CO_RESIDENT"));
}

/// Security regression S3: production mode is the default when APP_ENV is unset
/// or unrecognised, startup validation rejects missing/unknown values, and
/// development routes stay unrouted in production.
#[tokio::test]
async fn s3_production_mode_fails_closed_without_app_env_and_disables_dev_routes() {
    use sitepulse_backend::state::AppStateInner;

    assert!(AppStateInner::is_production_from(None, false));
    assert!(AppStateInner::is_production_from(Some("staging"), false));
    assert!(AppStateInner::is_production_from(Some("staging"), true));
    assert!(!AppStateInner::is_production_from(
        Some("development"),
        false
    ));
    assert!(AppStateInner::is_production_from(Some("production"), false));

    let unset_err = AppStateInner::validate_mode_from(None, false).unwrap_err();
    assert!(unset_err.contains("APP_ENV is not set"), "got: {unset_err}");
    let unknown_err = AppStateInner::validate_mode_from(Some("staging"), false).unwrap_err();
    assert!(
        unknown_err.contains("APP_ENV must be"),
        "got: {unknown_err}"
    );
    assert_eq!(
        AppStateInner::validate_mode_from(Some("development"), false),
        Ok(())
    );
    assert_eq!(
        AppStateInner::validate_mode_from(Some("production"), false),
        Ok(())
    );

    let mut state = AppState::new_with_test_fixtures();
    state.settings.production = true;
    state.settings.dev_routes_enabled = false;
    let admin = support::token(&state, "usr-test", Role::SaasAdmin, "", None).await;
    let (status, _) = call(
        build_router(state),
        "POST",
        "/api/v1/system/wipe-all-data",
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

/// Security regression S4: login throttling enforces per-client and
/// per-client-account limits without locking out other clients.
#[tokio::test]
async fn s4_login_throttling_enforces_per_client_and_per_account_lockout() {
    use axum::extract::ConnectInfo;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    async fn post_login(
        app: Router,
        ip: Ipv4Addr,
        email: &str,
        password: &str,
    ) -> (StatusCode, String) {
        let mut req = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/login")
            .header(axum::http::header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::json!({ "email": email, "password": password }).to_string(),
            ))
            .unwrap();
        req.extensions_mut()
            .insert(ConnectInfo(SocketAddr::new(IpAddr::V4(ip), 12345)));
        let resp = app.oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = to_bytes(resp.into_body(), 1024 * 1024).await.unwrap();
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    let state = AppState::new_with_test_fixtures();
    let app = build_router(state);
    let client_a = Ipv4Addr::new(203, 0, 113, 10);
    let client_b = Ipv4Addr::new(198, 51, 100, 20);
    let client_c = Ipv4Addr::new(203, 0, 113, 30);

    // 10 attempts from client A against one account succeed in reaching auth (401);
    // the 11th is throttled (429).
    for _ in 0..10 {
        let (status, _) = post_login(app.clone(), client_a, "victim@begonya.com", "wrong").await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    let (status, body) = post_login(app.clone(), client_a, "victim@begonya.com", "wrong").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "body: {body}");

    // Another client (client B) is not locked out for the same account.
    let (status, _) = post_login(app.clone(), client_b, "victim@begonya.com", "wrong").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Per-client limit across distinct emails: 120 requests allowed, 121st blocked.
    for i in 0..120 {
        let email = format!("probe-{i}@example.com");
        let (status, _) = post_login(app.clone(), client_c, &email, "wrong").await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "failed on attempt {i}");
    }
    let (status, body) = post_login(app, client_c, "probe-120@example.com", "wrong").await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS, "body: {body}");
}

/// Security regression S7: responses carry hardening headers and API docs
/// endpoints return 404 in production unless explicitly enabled.
#[tokio::test]
async fn s7_security_headers_and_no_public_api_docs_in_production() {
    let mut prod_state = AppState::new_with_test_fixtures();
    prod_state.settings.production = true;
    prod_state.settings.public_api_docs_enabled = false;
    let prod_app = build_router(prod_state);

    let health_resp = prod_app
        .clone()
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(health_resp.status(), StatusCode::OK);
    let headers = health_resp.headers();
    assert_eq!(headers.get("x-content-type-options").unwrap(), "nosniff");
    assert_eq!(headers.get("x-frame-options").unwrap(), "DENY");
    assert_eq!(headers.get("referrer-policy").unwrap(), "no-referrer");
    assert_eq!(
        headers.get("strict-transport-security").unwrap(),
        "max-age=31536000; includeSubDomains"
    );
    assert_eq!(
        headers.get("content-security-policy").unwrap(),
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    );
    assert_eq!(headers.get("cache-control").unwrap(), "no-store");

    for path in [
        "/api-docs/openapi.json",
        "/api/v1/openapi.json",
        "/openapi.json",
        "/swagger-ui",
        "/docs",
        "/scalar",
    ] {
        let resp = prod_app
            .clone()
            .oneshot(
                Request::builder()
                    .method("GET")
                    .uri(path)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::NOT_FOUND,
            "{path} must return 404 in production"
        );
    }

    let mut dev_state = AppState::new_with_test_fixtures();
    dev_state.settings.production = false;
    dev_state.settings.public_api_docs_enabled = true;
    let dev_app = build_router(dev_state);
    let docs_resp = dev_app
        .oneshot(
            Request::builder()
                .method("GET")
                .uri("/swagger-ui")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(docs_resp.status(), StatusCode::OK);
    assert!(docs_resp
        .headers()
        .get("strict-transport-security")
        .is_none());
    let csp = docs_resp
        .headers()
        .get("content-security-policy")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(csp.contains("https://cdn.jsdelivr.net"), "got: {csp}");
}
