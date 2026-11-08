//! HTTP-level security tests: drive the real router (middleware included) and
//! assert authentication, role policy and tenant isolation.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use sitepulse_backend::{app::build_router, auth, models::Role, state::AppState};
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

fn router() -> Router {
    build_router(AppState::new_with_test_fixtures())
}

fn token(role: Role, site: &str, unit: Option<&str>) -> String {
    auth::issue_token("usr-test", "test@example.com", role, site, unit)
}

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
    for (method, path) in PROTECTED_ROUTES {
        let (status, _) = call(router(), method, path, None, None).await;
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
    let real = token(Role::HomeOwner, "site-1", Some("d-14"));
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
        let (status, _) = call(router(), "GET", "/api/v1/saas/sites", Some(&t), None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

#[tokio::test]
async fn public_routes_stay_reachable() {
    let (status, _) = call(router(), "GET", "/health", None, None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(router(), "GET", "/api/v1/site-admin/banks", None, None).await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn residents_cannot_reach_admin_or_other_units() {
    let owner = token(Role::HomeOwner, "site-1", Some("d-14"));
    for (method, path) in [
        ("GET", "/api/v1/saas/sites"),
        ("GET", "/api/v1/site-admin/home-owners"),
        ("POST", "/api/v1/payments/record-manual"),
        ("POST", "/api/v1/bank/kuveyt-turk/configure"),
        ("DELETE", "/api/v1/saas/sites/site-1"),
    ] {
        let (status, _) = call(router(), method, path, Some(&owner), None).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{} {}", method, path);
    }
    let (status, _) = call(
        router(),
        "GET",
        "/api/v1/residents/d-99/dashboard",
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, _) = call(
        router(),
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
    let other_manager = token(Role::SiteManager, "site-2", None);
    let (status, _) = call(
        router(),
        "GET",
        "/api/v1/site-admin/home-owners?site_id=site-1",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::FORBIDDEN,
        "explicit foreign site_id in query"
    );
    let (status, _) = call(
        router(),
        "GET",
        "/api/v1/site-admin/bank-account/site-1",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "foreign site_id in path");
    let (status, _) = call(
        router(),
        "GET",
        "/api/v1/site-admin/units/d-14/occupancy-history",
        Some(&other_manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "unit of a foreign site");
    let (status, _) = call(
        router(),
        "POST",
        "/api/v1/payments/record-manual",
        Some(&other_manager),
        Some(serde_json::json!({ "site_id": "site-1", "unit_id": "d-14", "amount": "10.00" })),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "foreign site_id in body");

    // With no site_id at all, the request is pinned to the caller's own site (not site-1).
    let (status, body) = call(
        router(),
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

    let own_manager = token(Role::SiteManager, "site-1", None);
    let (status, _) = call(
        router(),
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
    let owner = auth::issue_token(
        "usr-home-owner-1",
        "ahmet.yilmaz@begonya.com",
        Role::HomeOwner,
        "site-1",
        Some("d-14"),
    );
    let (status, body) = call(
        router(),
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
    std::env::remove_var("SITEPULSE_ENABLE_DEV_ROUTES");
    let admin = token(Role::SaasAdmin, "", None);
    let (status, _) = call(
        router(),
        "POST",
        "/api/v1/system/wipe-all-data",
        Some(&admin),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}
