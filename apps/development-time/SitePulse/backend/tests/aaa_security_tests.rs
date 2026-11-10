//! Security regressions for the SPEC-007 implementation.
mod support;
use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use sitepulse_backend::{
    app::{build_router, ROUTES},
    auth,
    authorization::{SiteId, UnitId},
    models::{Permission, Role},
    security,
    state::AppState,
};
use tower::ServiceExt;

async fn call(
    state: &AppState,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: serde_json::Value,
) -> (StatusCode, serde_json::Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {}", token));
    }
    let resp = build_router(state.clone())
        .oneshot(req.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    assert!(resp.headers().contains_key("x-request-id"));
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or_default())
}
#[tokio::test]
async fn unknown_routes_and_cross_tenant_access_fail_closed() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "manager", Role::SiteManager, "site-1", None).await;
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/future-admin-endpoint",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/site-admin/home-owners?site_id=site-2",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/saas/sites",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
}
#[test]
fn route_inventory_and_permission_matrix_are_explicit() {
    let mut seen = std::collections::HashSet::new();
    for r in ROUTES {
        assert!(seen.insert((r.method, r.path)), "duplicate method/template");
    }
    assert!(ROUTES.len() > 90);
    assert_eq!(
        Permission::permissions_for_role(Role::HomeResident),
        vec![Permission::UnitRead, Permission::UnitPay]
    );
    let admin = Permission::permissions_for_role(Role::SaasAdmin);
    for p in [
        Permission::SiteManage,
        Permission::LedgerManageAll,
        Permission::PaymentReverse,
        Permission::UnitRead,
    ] {
        assert!(!admin.contains(&p));
    }
    assert!(Role::parse("SUPER_ADMIN").is_err());
    assert!(SiteId::parse("unit-5").is_err());
    assert!(UnitId::parse("site-5").is_err());
    assert!(!auth::same_id("site-5", "unit-5"));
}
#[tokio::test]
async fn a_signed_token_without_a_session_is_rejected() {
    let state = AppState::new_with_test_fixtures();
    let token = auth::issue_token(
        "usr-home-owner-1",
        "ahmet.yilmaz@begonya.com",
        Role::HomeOwner,
        "site-1",
        Some("d-14"),
    )
    .unwrap();
    let (status, body) = call(
        &state,
        "GET",
        "/api/v1/auth/me",
        Some(&token),
        serde_json::json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"]["code"], "AUTHENTICATION_REQUIRED");
}
#[tokio::test]
async fn logout_immediately_invalidates_a_copied_access_token() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "owner", Role::HomeOwner, "site-1", Some("d-14")).await;
    assert_eq!(
        call(
            &state,
            "POST",
            "/api/v1/auth/logout",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/auth/me",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}
#[tokio::test]
async fn refresh_reuse_revokes_the_entire_session() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "owner", Role::HomeOwner, "site-1", Some("d-14")).await;
    let claims = auth::verify_token(&token).unwrap();
    let user = security::user(&state, &claims.sub).await.unwrap();
    let credentials = security::create(&state, &user, Some("d-14")).await.unwrap();
    let input = serde_json::json!({"refresh_token":credentials.refresh_token});
    let (status, renewed) = call(&state, "POST", "/api/v1/auth/refresh", None, input.clone()).await;
    assert_eq!(status, StatusCode::OK);
    assert_ne!(renewed["refresh_token"], input["refresh_token"]);
    assert_eq!(
        call(&state, "POST", "/api/v1/auth/refresh", None, input)
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/auth/me",
            renewed["access_token"].as_str(),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}
#[tokio::test]
async fn suspension_and_role_changes_invalidate_access() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "manager", Role::SiteManager, "site-1", None).await;
    state
        .inner
        .write()
        .await
        .sites
        .iter_mut()
        .find(|s| s.id == "site-1")
        .unwrap()
        .status = sitepulse_backend::models::SiteStatus::Suspended;
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/site-admin/overview",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    state
        .inner
        .write()
        .await
        .sites
        .iter_mut()
        .find(|s| s.id == "site-1")
        .unwrap()
        .status = sitepulse_backend::models::SiteStatus::Active;
    state
        .inner
        .write()
        .await
        .users
        .iter_mut()
        .find(|u| u.id == "manager")
        .unwrap()
        .role = Role::HomeResident;
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/site-admin/overview",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}
#[tokio::test]
async fn platform_administrators_do_not_inherit_tenant_permissions() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "platform", Role::SaasAdmin, "", None).await;
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/site-admin/home-owners",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/saas/sites",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::OK
    );
}
#[tokio::test]
async fn stale_unit_relationship_is_not_authorized_by_the_token() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "owner", Role::HomeOwner, "site-1", Some("d-14")).await;
    {
        let mut inner = state.inner.write().await;
        inner
            .units
            .iter_mut()
            .filter(|u| u.owner_user_id.as_deref() == Some("owner"))
            .for_each(|u| u.owner_user_id = None);
    }
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/residents/d-14/dashboard",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
}
#[tokio::test]
async fn mandatory_password_change_and_step_up_are_server_enforced() {
    let state = AppState::new_with_test_fixtures();
    let token = support::token(&state, "manager", Role::SiteManager, "site-1", None).await;
    let (status, body) = call(
        &state,
        "POST",
        "/api/v1/payments/reverse",
        Some(&token),
        serde_json::json!({"receipt":"fake","reason":"test"}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "STEP_UP_REQUIRED");
    state
        .inner
        .write()
        .await
        .users
        .iter_mut()
        .find(|u| u.id == "manager")
        .unwrap()
        .must_change_password = true;
    let (status, body) = call(
        &state,
        "GET",
        "/api/v1/site-admin/home-owners",
        Some(&token),
        serde_json::json!({}),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"]["code"], "PASSWORD_CHANGE_REQUIRED");
    assert_eq!(
        call(
            &state,
            "GET",
            "/api/v1/auth/me",
            Some(&token),
            serde_json::json!({})
        )
        .await
        .0,
        StatusCode::OK
    );
}
#[tokio::test]
async fn when_password_change_required_then_business_routes_are_blocked() {
    let state = AppState::new_with_test_fixtures();
    let cases = [
        ("pcr-saas", Role::SaasAdmin, None, "/api/v1/saas/sites"),
        (
            "pcr-manager",
            Role::SiteManager,
            None,
            "/api/v1/site-admin/home-owners",
        ),
        (
            "pcr-owner",
            Role::HomeOwner,
            Some("d-14"),
            "/api/v1/residents/d-14/dashboard",
        ),
        (
            "pcr-resident",
            Role::HomeResident,
            Some("d-14"),
            "/api/v1/residents/d-14/dashboard",
        ),
        (
            "pcr-auditor",
            Role::Auditor,
            None,
            "/api/v1/payments/debt-aging",
        ),
    ];
    for (id, role, unit, path) in cases {
        let token = support::token(&state, id, role, "site-1", unit).await;
        let (_, before) = call(&state, "GET", path, Some(&token), serde_json::json!({})).await;
        assert_ne!(
            before["error"]["code"], "PASSWORD_CHANGE_REQUIRED",
            "{role:?} is blocked before the flag is set"
        );
        state
            .inner
            .write()
            .await
            .users
            .iter_mut()
            .find(|u| u.id == id)
            .expect("test user exists")
            .must_change_password = true;
        let (status, body) = call(&state, "GET", path, Some(&token), serde_json::json!({})).await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{role:?} {path}");
        assert_eq!(
            body["error"]["code"], "PASSWORD_CHANGE_REQUIRED",
            "{role:?}"
        );
        let (me, _) = call(
            &state,
            "GET",
            "/api/v1/auth/me",
            Some(&token),
            serde_json::json!({}),
        )
        .await;
        assert_eq!(me, StatusCode::OK, "{role:?} can still read its profile");
    }
}
