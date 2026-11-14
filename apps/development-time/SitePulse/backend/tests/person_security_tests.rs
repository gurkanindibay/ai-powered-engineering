//! Person module security regressions (S2, S3, S5, S6, S8, S9 and the removed fake success paths).
mod support;
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::account_activation_service::{
    issue_in_memory, ActivateAccountRequest, ActivationError, ActivationPurpose,
    ConfirmEmailRequest,
};
use sitepulse_backend::services::site_admin_service::{self, EMAIL_NOT_AVAILABLE, UNIT_NOT_FOUND};
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

fn owner_request(unit_no: i32, email: &str) -> RegisterHomeOwnerRequest {
    RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no,
        floor: 2,
        owner_full_name: "Selin Aksoy".to_string(),
        email: email.to_string(),
        phone: "+90 532 555 1010".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: Some(Decimal::from_str_exact("1400.00").unwrap()),
        house_type: Some("2+1".to_string()),
        is_resident: true,
        role: None,
    }
}

async fn user_by_email(state: &AppState, email: &str) -> User {
    state
        .inner
        .read()
        .await
        .users
        .iter()
        .find(|u| u.email == email)
        .cloned()
        .expect("user exists")
}

async fn login(state: &AppState, email: &str, password: &str) -> Result<AuthResponse, String> {
    AuthService::new(state.clone())
        .authenticate_with_password(PasswordLoginRequest {
            email: email.to_string(),
            password: password.to_string(),
        })
        .await
}

#[tokio::test]
async fn registration_never_returns_or_stores_a_known_password() {
    let state = AppState::new();
    let res = SiteAdminService::new(state.clone())
        .register_home_owner("site-1", owner_request(41, "selin.aksoy@example.com"))
        .await
        .expect("registered");

    let json = serde_json::to_string(&res).expect("serializes");
    assert!(
        !json.contains("password\":\"SP-"),
        "no password in the response: {json}"
    );
    assert!(!json.contains("temporary_password"));
    assert_eq!(res.activation.expect("activation").status, "SENT");
    let user = user_by_email(&state, "selin.aksoy@example.com").await;
    assert!(
        user.password_hash.is_none(),
        "an inactive account has no password"
    );
}

#[tokio::test]
async fn activation_token_sets_the_password_exactly_once() {
    let state = AppState::new();
    SiteAdminService::new(state.clone())
        .register_home_owner("site-1", owner_request(42, "mert.ural@example.com"))
        .await
        .expect("registered");
    let user = user_by_email(&state, "mert.ural@example.com").await;
    let issued = {
        let mut inner = state.inner.write().await;
        issue_in_memory(&mut inner, &user.id, ActivationPurpose::Activate, None)
    };
    assert!(login(&state, "mert.ural@example.com", "Strong-Pass-2026")
        .await
        .is_err());

    let activations = AccountActivationService::new(state.clone());
    activations
        .activate(ActivateAccountRequest {
            token: issued.token.clone(),
            new_password: "Strong-Pass-2026".to_string(),
        })
        .await
        .expect("activated");
    let activated = user_by_email(&state, "mert.ural@example.com").await;
    let hash = activated.password_hash.expect("a password is set");
    assert!(
        sitepulse_backend::auth::verify_password_async("Strong-Pass-2026".to_string(), hash)
            .await
            .expect("verifies"),
        "the stored password is the one the person chose"
    );
    assert!(!activated.must_change_password);

    let reuse = activations
        .activate(ActivateAccountRequest {
            token: issued.token,
            new_password: "Another-Pass-2026".to_string(),
        })
        .await;
    assert_eq!(reuse, Err(ActivationError::InvalidToken));
}

#[tokio::test]
async fn a_newer_activation_token_voids_the_older_one() {
    let state = AppState::new();
    SiteAdminService::new(state.clone())
        .register_home_owner("site-1", owner_request(43, "ela.tan@example.com"))
        .await
        .expect("registered");
    let user = user_by_email(&state, "ela.tan@example.com").await;
    let (old, new) = {
        let mut inner = state.inner.write().await;
        let old = issue_in_memory(&mut inner, &user.id, ActivationPurpose::Activate, None);
        let new = issue_in_memory(&mut inner, &user.id, ActivationPurpose::Activate, None);
        (old, new)
    };
    let activations = AccountActivationService::new(state.clone());
    let stale = activations
        .activate(ActivateAccountRequest {
            token: old.token,
            new_password: "Strong-Pass-2026".to_string(),
        })
        .await;
    assert_eq!(stale, Err(ActivationError::InvalidToken));
    activations
        .activate(ActivateAccountRequest {
            token: new.token,
            new_password: "Strong-Pass-2026".to_string(),
        })
        .await
        .expect("the newest link works");
}

#[tokio::test]
async fn an_email_change_token_cannot_activate_an_account() {
    let state = AppState::new();
    SiteAdminService::new(state.clone())
        .register_home_owner("site-1", owner_request(44, "can.er@example.com"))
        .await
        .expect("registered");
    let user = user_by_email(&state, "can.er@example.com").await;
    let issued = {
        let mut inner = state.inner.write().await;
        issue_in_memory(
            &mut inner,
            &user.id,
            ActivationPurpose::EmailChange,
            Some("can.er2@example.com"),
        )
    };
    let wrong_purpose = AccountActivationService::new(state.clone())
        .activate(ActivateAccountRequest {
            token: issued.token,
            new_password: "Strong-Pass-2026".to_string(),
        })
        .await;
    assert_eq!(wrong_purpose, Err(ActivationError::InvalidToken));
}

#[tokio::test]
async fn tenant_gets_an_own_account_without_the_owners_password() {
    let state = AppState::new();
    let mut request = owner_request(45, "owner.45@example.com");
    request.tenant_full_name = Some("Deniz Kiracı".to_string());
    request.tenant_email = Some("tenant.45@example.com".to_string());
    request.tenant_phone = Some("+90 532 555 4545".to_string());
    let res = SiteAdminService::new(state.clone())
        .register_home_owner("site-1", request)
        .await
        .expect("registered");

    assert_eq!(
        res.tenant_activation.expect("tenant activation").status,
        "SENT"
    );
    let owner = user_by_email(&state, "owner.45@example.com").await;
    let tenant = user_by_email(&state, "tenant.45@example.com").await;
    assert_ne!(owner.id, tenant.id);
    assert!(tenant.password_hash.is_none());
    assert!(owner.password_hash.is_none());
}

#[tokio::test]
async fn login_email_change_waits_for_confirmation_from_the_new_address() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());
    let created = service
        .register_home_owner("site-1", owner_request(46, "old.46@example.com"))
        .await
        .expect("registered");

    let updated = service
        .update_home_owner(
            "site-1",
            &created.unit_id,
            UpdateHomeOwnerRequest {
                owner_full_name: None,
                email: Some("new.46@example.com".to_string()),
                phone: None,
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                remove_tenant: None,
                house_type: None,
                monthly_dues: None,
                land_share: None,
                is_resident: None,
            },
            true,
        )
        .await
        .expect("updated");
    assert_eq!(updated.pending_email_changes.len(), 1);
    assert_eq!(
        updated.pending_email_changes[0].new_email,
        "new.46@example.com"
    );
    let user = user_by_email(&state, "old.46@example.com").await;

    // The confirmation the person receives at the new address applies it.
    let issued = {
        let mut inner = state.inner.write().await;
        issue_in_memory(
            &mut inner,
            &user.id,
            ActivationPurpose::EmailChange,
            Some("new.46@example.com"),
        )
    };
    AccountActivationService::new(state.clone())
        .confirm_email(ConfirmEmailRequest {
            token: issued.token,
        })
        .await
        .expect("confirmed");
    let moved = user_by_email(&state, "new.46@example.com").await;
    assert_eq!(moved.id, user.id);
}

#[tokio::test]
async fn email_change_to_an_address_in_use_is_refused() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());
    let first = service
        .register_home_owner("site-1", owner_request(47, "first.47@example.com"))
        .await
        .expect("registered");
    service
        .register_home_owner("site-1", owner_request(48, "second.48@example.com"))
        .await
        .expect("registered");
    let result = service
        .update_home_owner(
            "site-1",
            &first.unit_id,
            UpdateHomeOwnerRequest {
                owner_full_name: None,
                email: Some("second.48@example.com".to_string()),
                phone: None,
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                remove_tenant: None,
                house_type: None,
                monthly_dues: None,
                land_share: None,
                is_resident: None,
            },
            true,
        )
        .await;
    assert_eq!(result.err(), Some(EMAIL_NOT_AVAILABLE.to_string()));
}

#[tokio::test]
async fn updating_an_unknown_unit_fails_instead_of_inventing_a_response() {
    let state = AppState::new();
    let result = SiteAdminService::new(state)
        .update_home_owner(
            "site-1",
            "987654",
            UpdateHomeOwnerRequest {
                owner_full_name: Some("Nobody".to_string()),
                email: None,
                phone: None,
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                remove_tenant: None,
                house_type: None,
                monthly_dues: None,
                land_share: None,
                is_resident: None,
            },
            true,
        )
        .await;
    assert_eq!(result.err(), Some(UNIT_NOT_FOUND.to_string()));
}

#[tokio::test]
async fn resend_activation_issues_a_link_until_the_account_is_active() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());
    let created = service
        .register_home_owner("site-1", owner_request(49, "resend.49@example.com"))
        .await
        .expect("registered");
    let activations = AccountActivationService::new(state.clone());
    let delivery = activations
        .resend_for_unit("site-1", &created.unit_id, false)
        .await
        .expect("resent");
    assert_eq!(delivery.status, "SENT");

    let user = user_by_email(&state, "resend.49@example.com").await;
    let issued = {
        let mut inner = state.inner.write().await;
        issue_in_memory(&mut inner, &user.id, ActivationPurpose::Activate, None)
    };
    AccountActivationService::new(state.clone())
        .activate(ActivateAccountRequest {
            token: issued.token,
            new_password: "Strong-Pass-2026".to_string(),
        })
        .await
        .expect("activated");
    let again = activations
        .resend_for_unit("site-1", &created.unit_id, false)
        .await;
    assert_eq!(again.err(), Some(ActivationError::AlreadyActive));
}

#[tokio::test]
async fn a_contact_edit_does_not_need_identity_rights_but_a_login_change_does() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());
    let created = service
        .register_home_owner("site-1", owner_request(50, "contact.50@example.com"))
        .await
        .expect("registered");
    let mut request = UpdateHomeOwnerRequest {
        owner_full_name: Some("Renamed Owner".to_string()),
        email: Some("contact.50@example.com".to_string()),
        phone: None,
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        remove_tenant: None,
        house_type: None,
        monthly_dues: None,
        land_share: None,
        is_resident: None,
    };
    service
        .update_home_owner("site-1", &created.unit_id, request.clone(), false)
        .await
        .expect("an unchanged email with a new name is a contact edit");

    request.email = Some("changed.50@example.com".to_string());
    let refused = service
        .update_home_owner("site-1", &created.unit_id, request, false)
        .await;
    assert_eq!(
        refused.err(),
        Some(site_admin_service::LOGIN_CHANGE_NEEDS_STEP_UP.to_string())
    );
    assert!(state
        .inner
        .read()
        .await
        .users
        .iter()
        .any(|u| u.email == "contact.50@example.com"));
}

mod routes {
    use super::support;
    use axum::{
        body::Body,
        http::{Request, StatusCode},
    };
    use sitepulse_backend::{app::build_router, models::Role, state::AppState};
    use tower::ServiceExt;

    async fn post(
        state: &AppState,
        path: &str,
        token: &str,
        body: serde_json::Value,
    ) -> StatusCode {
        build_router(state.clone())
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header("content-type", "application/json")
                    .header("authorization", format!("Bearer {token}"))
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap()
            .status()
    }

    #[tokio::test]
    async fn s6_a_resident_cannot_change_the_units_payment_profile_but_the_owner_can() {
        let state = AppState::new_with_test_fixtures();
        let body = serde_json::json!({"sender_iban": "TR330006100519786457841326", "sender_name": "Payer"});
        let path = "/api/v1/residents/d-14/matching-criteria/ibans";

        let resident =
            support::token(&state, "resident-s6", Role::HomeResident, "site-1", None).await;
        assert_eq!(
            post(&state, path, &resident, body.clone()).await,
            StatusCode::FORBIDDEN
        );

        let owner =
            support::token(&state, "owner-s6", Role::HomeOwner, "site-1", Some("d-14")).await;
        let status = post(&state, path, &owner, body).await;
        assert!(
            status != StatusCode::FORBIDDEN && status != StatusCode::NOT_FOUND,
            "the owner is authorized, got {status}"
        );
    }

    #[tokio::test]
    async fn occupancy_changes_need_occupancy_rights() {
        let state = AppState::new_with_test_fixtures();
        let owner =
            support::token(&state, "owner-occ", Role::HomeOwner, "site-1", Some("d-14")).await;
        let status = post(
            &state,
            "/api/v1/site-admin/units/d-14/move-out",
            &owner,
            serde_json::json!({}),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
    }
}

#[tokio::test]
async fn f5_household_relationship_is_stored_as_a_code_and_unknown_text_is_refused() {
    let state = AppState::new_with_test_fixtures();
    let service = SiteAdminService::new(state);
    let added = service
        .add_unit_member(
            "site-1",
            "d-14",
            "Ada Kaya",
            "",
            "ada.kaya@example.com",
            "Çocuğu",
        )
        .await
        .expect("a legacy label is accepted");
    assert_eq!(added.relationship, "CHILD");
    let refused = service
        .add_unit_member(
            "site-1",
            "d-14",
            "Bo Kaya",
            "",
            "bo.kaya@example.com",
            "Landlord",
        )
        .await;
    assert!(refused.is_err());
}

#[tokio::test]
async fn f3_the_given_land_share_is_stored_and_a_missing_one_is_flagged() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());
    let mut given = owner_request(51, "share.51@example.com");
    given.land_share = Some("18".to_string());
    let res = service
        .register_home_owner("site-1", given)
        .await
        .expect("registered");
    assert_eq!(res.land_share, "18/24");
    assert!(!res.warnings.contains(&"LAND_SHARE_DEFAULTED".to_string()));
    let stored = state
        .inner
        .read()
        .await
        .units
        .iter()
        .find(|u| u.unit_number == 51)
        .map(|u| u.land_share);
    assert_eq!(stored, Some(18));

    let missing = service
        .register_home_owner("site-1", owner_request(52, "share.52@example.com"))
        .await
        .expect("registered");
    assert!(missing
        .warnings
        .contains(&"LAND_SHARE_DEFAULTED".to_string()));

    let mut invalid = owner_request(53, "share.53@example.com");
    invalid.land_share = Some("0".to_string());
    assert!(service
        .register_home_owner("site-1", invalid)
        .await
        .is_err());
}

#[tokio::test]
async fn f4_a_defaulted_dues_amount_is_reported_not_silent() {
    let state = AppState::new();
    let mut request = owner_request(54, "dues.54@example.com");
    request.house_type = Some("9+9".to_string());
    request.monthly_dues = None;
    let res = SiteAdminService::new(state)
        .register_home_owner("site-1", request)
        .await
        .expect("registered");
    assert_eq!(res.monthly_dues, Decimal::new(140000, 2));
    assert!(res.warnings.contains(&"DUES_DEFAULTED".to_string()));
}

#[test]
fn f3_land_share_parsing() {
    use sitepulse_backend::services::site_admin_service::parse_land_share;
    assert_eq!(parse_land_share(None), Ok(None));
    assert_eq!(parse_land_share(Some("24")), Ok(Some(24)));
    assert_eq!(parse_land_share(Some("12/240")), Ok(Some(12)));
    assert!(parse_land_share(Some("-3")).is_err());
    assert!(parse_land_share(Some("abc")).is_err());
}
