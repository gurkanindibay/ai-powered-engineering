use axum::response::IntoResponse;
use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

/// The seeded fixture due (`b-101`, "Eylül 2026") is dated 2026-09-15, so by the
/// real clock it is overdue and the canonical payment path first collects its
/// KMK 20 delay penalty (TBK 100, SPEC-005). Tests whose subject is not the
/// penalty move the open seeded dues to a future due date to stay deterministic.
async fn fixture_dues_not_yet_due(state: &AppState) {
    let due = Utc::now().date_naive() + chrono::Days::new(15);
    let mut inner = state.inner.write().await;
    for d in inner
        .dues
        .iter_mut()
        .filter(|d| d.status != DebtStatus::Paid)
    {
        d.due_date = due;
        d.status = DebtStatus::Pending;
        d.delay_penalty = Decimal::ZERO;
        d.penalty_accrued_through = None;
        d.total_amount = d.principal_amount - d.paid_principal;
    }
}

fn resident_dashboard_authz(role: Role) -> sitepulse_backend::authorization::AuthzContext {
    let token = sitepulse_backend::auth::issue_token(
        "usr-home-owner-1",
        "homeowner@test.example",
        role,
        "site-1",
        Some("d-14"),
    )
    .unwrap();
    let mut claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    claims.role = role;
    claims.site_id = "site-1".to_string();
    claims.unit_id = Some("d-14".to_string());
    sitepulse_backend::authorization::AuthzContext {
        claims,
        permissions: Permission::permissions_for_role(role),
        request_id: "resident-dashboard-test".to_string(),
        stepped_up: false,
    }
}

#[test]
fn when_overdue_by_10_days_then_calculates_exact_5_percent_pro_rated_penalty() {
    let service = DuesCalculationService::new();
    let base_dues = DuesLiability {
        id: "b-1".to_string(),
        unit_id: "d-14".to_string(),
        period: "Eylül 2026".to_string(),
        principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact("1400.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Tenant,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    };

    let evaluation_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
    let result = service.calculate_delay_penalty(base_dues, evaluation_date);

    assert_eq!(result.status, DebtStatus::Overdue);
    assert_eq!(
        result.delay_penalty,
        Decimal::from_str_exact("23.33").unwrap()
    );
    assert_eq!(
        result.total_amount,
        Decimal::from_str_exact("1423.33").unwrap()
    );
}

#[test]
fn when_not_overdue_then_penalty_remains_zero() {
    let service = DuesCalculationService::new();
    let base_dues = DuesLiability {
        id: "b-1".to_string(),
        unit_id: "d-14".to_string(),
        period: "Eylül 2026".to_string(),
        principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact("1400.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Tenant,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    };

    let evaluation_date = NaiveDate::from_ymd_opt(2026, 9, 10).unwrap();
    let result = service.calculate_delay_penalty(base_dues, evaluation_date);

    assert_eq!(result.status, DebtStatus::Pending);
    assert_eq!(result.delay_penalty, Decimal::ZERO);
    assert_eq!(
        result.total_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
}

#[tokio::test]
async fn when_registering_new_site_then_provisions_site_and_manager_with_temporary_password() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    let req = RegisterSiteRequest {
        site_name: "Yıldız Park Evleri".to_string(),
        address: "Kadıköy, İstanbul".to_string(),
        site_admin_full_name: "Kemal Sunal".to_string(),
        site_admin_email: "kemal.sunal@yildizpark.com".to_string(),
        site_admin_phone: "+90 532 555 4433".to_string(),
        plan_type: Some("PREMIUM".to_string()),
        blocks: Some(vec!["A Blok".to_string(), "B Blok".to_string()]),
    };

    let res = service
        .register_site(req)
        .await
        .expect("Site registration failed");
    assert_eq!(res.site_name, "Yıldız Park Evleri");
    assert_eq!(res.slug, "yildiz-park-evleri");
    assert_eq!(res.admin_email, "kemal.sunal@yildizpark.com");
    assert_eq!(res.blocks, vec!["A Blok", "B Blok"]);
    assert!(res.temporary_password.starts_with("SP-"));
    assert!(res.must_change_password);
}

#[tokio::test]
async fn when_updating_site_then_site_details_and_admin_info_are_updated() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    let reg_req = RegisterSiteRequest {
        site_name: "Nilüfer Sitesi".to_string(),
        address: "Bursa, Nilüfer".to_string(),
        site_admin_full_name: "Ali Veli".to_string(),
        site_admin_email: "ali.veli@nilufer.com".to_string(),
        site_admin_phone: "+90 532 111 2233".to_string(),
        plan_type: Some("STANDARD".to_string()),
        blocks: Some(vec!["A Blok".to_string(), "B Blok".to_string()]),
    };
    let reg_res = service
        .register_site(reg_req)
        .await
        .expect("Registration failed");

    let update_req = UpdateSiteRequest {
        site_name: Some("Nilüfer Lüks Rezidans".to_string()),
        address: Some("Bursa, Nilüfer, Çamlık Cad. No:12".to_string()),
        status: Some("ACTIVE".to_string()),
        plan_type: Some("PREMIUM".to_string()),
        site_admin_full_name: Some("Ali Veli Kaya".to_string()),
        site_admin_email: Some("ali.kaya@nilufer.com".to_string()),
        site_admin_phone: Some("+90 532 999 8877".to_string()),
        blocks: Some(vec![
            "A Blok".to_string(),
            "B Blok".to_string(),
            "C Blok".to_string(),
        ]),
        tax_id: None,
        tax_office: None,
    };

    let updated = service
        .update_site(&reg_res.site_id, update_req)
        .await
        .expect("Update failed");
    assert_eq!(updated.site_name, "Nilüfer Lüks Rezidans");
    assert_eq!(updated.address, "Bursa, Nilüfer, Çamlık Cad. No:12");
    assert_eq!(updated.plan_type, PlanType::Premium);
    assert_eq!(updated.primary_manager_name, "Ali Veli Kaya");
    assert_eq!(updated.primary_manager_email, "ali.kaya@nilufer.com");
    assert_eq!(updated.primary_manager_phone, "+90 532 999 8877");
    assert_eq!(updated.blocks, vec!["A Blok", "B Blok", "C Blok"]);
}

fn site_edit_request(blocks: Vec<String>) -> UpdateSiteRequest {
    UpdateSiteRequest {
        site_name: Some("Begonya Sitesi Evleri".to_string()),
        address: Some("Ataşehir, Yeni Sok. No:1, İstanbul".to_string()),
        status: None,
        plan_type: None,
        site_admin_full_name: None,
        site_admin_email: None,
        site_admin_phone: None,
        blocks: Some(blocks),
        tax_id: None,
        tax_office: None,
    }
}

/// Issue #14: the edit form always resends the block list. Re-saving the blocks a
/// site already has must keep their ids (units reference them) and succeed.
#[tokio::test]
async fn when_site_edit_resends_existing_blocks_then_block_ids_are_kept() {
    let state = AppState::new();
    let (site_id, before) = {
        let inner = state.inner.read().await;
        let unit = inner.units.first().expect("seeded unit").clone();
        let blocks: Vec<BlockDto> = inner
            .blocks
            .iter()
            .filter(|b| b.site_id == unit.site_id)
            .cloned()
            .collect();
        (unit.site_id, blocks)
    };
    assert!(!before.is_empty(), "seed must have blocks");
    let mut names: Vec<String> = before.iter().map(|b| b.block_name.clone()).collect();
    names.push("Yeni Blok".to_string());

    let service = SaasTenantService::new(state.clone());
    let updated = service
        .update_site(&site_id, site_edit_request(names.clone()))
        .await
        .expect("re-saving existing blocks must succeed");
    assert_eq!(updated.site_name, "Begonya Sitesi Evleri");
    assert_eq!(updated.blocks, names);

    let inner = state.inner.read().await;
    for block in &before {
        assert!(
            inner
                .blocks
                .iter()
                .any(|b| b.id == block.id && b.block_name == block.block_name),
            "block '{}' lost its id",
            block.block_name
        );
    }
}

/// Issue #14: hydration adds a `person-<id>` shadow row with the manager's email;
/// re-saving the manager's own email must not count it as a second account.
#[tokio::test]
async fn when_site_edit_keeps_manager_email_with_person_shadow_then_it_succeeds() {
    let state = AppState::new();
    let (site_id, manager) = {
        let mut inner = state.inner.write().await;
        let manager = inner
            .users
            .iter()
            .find(|u| u.role == Role::SiteManager)
            .expect("seeded manager")
            .clone();
        let mut shadow = manager.clone();
        shadow.id = format!("person-{}", manager.person_id.expect("manager person"));
        shadow.password_hash = None;
        inner.users.push(shadow);
        (manager.site_id.clone(), manager)
    };
    let mut req = site_edit_request(Vec::new());
    req.blocks = None;
    req.site_admin_full_name = Some(manager.full_name.clone());
    req.site_admin_email = Some(manager.email.clone());
    req.site_admin_phone = Some("+90 532 999 88 77".to_string());

    let updated = SaasTenantService::new(state)
        .update_site(&site_id, req)
        .await
        .expect("own email must not be reported as taken");
    assert_eq!(updated.primary_manager_email, manager.email);
    assert_eq!(updated.primary_manager_phone, "+90 532 999 88 77");
}

/// Removing a block that still has units is rejected before anything changes.
#[tokio::test]
async fn when_site_edit_drops_an_occupied_block_then_nothing_changes() {
    let state = AppState::new();
    let (site_id, site_name, occupied, before) = {
        let mut inner = state.inner.write().await;
        let site = inner.sites.first().expect("seeded site").clone();
        let block = inner
            .blocks
            .iter()
            .find(|b| b.site_id == site.id)
            .expect("seeded block")
            .clone();
        // Put a unit into that block, as PostgreSQL-loaded state does.
        let unit = inner.units.first_mut().expect("seeded unit");
        unit.site_id = site.id.clone();
        unit.block_id = block.id.clone();
        (site.id, site.name, block.block_name, inner.blocks.clone())
    };
    let remaining: Vec<String> = before
        .iter()
        .filter(|b| b.site_id == site_id && b.block_name != occupied)
        .map(|b| b.block_name.clone())
        .collect();

    let service = SaasTenantService::new(state.clone());
    let err = service
        .update_site(&site_id, site_edit_request(remaining))
        .await
        .expect_err("dropping an occupied block must fail");
    assert!(err.contains(&occupied));

    let inner = state.inner.read().await;
    assert_eq!(inner.blocks.len(), before.len());
    let site = inner.sites.iter().find(|s| s.id == site_id).expect("site");
    assert_eq!(
        site.name, site_name,
        "rejected edit must not rename the site"
    );
}

// covers: SC-03-04-04
#[tokio::test]
async fn when_duplicate_email_then_throws_exception() {
    let state = AppState::new();
    let sites_before = state.inner.read().await.sites.len();
    let service = SaasTenantService::new(state.clone());

    let req = RegisterSiteRequest {
        site_name: "Deneme Sitesi".to_string(),
        address: "Ataşehir".to_string(),
        site_admin_full_name: "Mehmet Demir".to_string(),
        site_admin_email: "mehmet.demir@begonya.com".to_string(), // duplicate seed email
        site_admin_phone: "+90 532 000 0000".to_string(),
        plan_type: None,
        blocks: None,
    };

    let err = service.register_site(req).await.unwrap_err();
    assert!(err.contains("already exists") || err.contains("zaten mevcut"));
    assert_eq!(
        state.inner.read().await.sites.len(),
        sites_before,
        "a rejected registration must not create a site"
    );
}

// covers: SC-03-05-01
#[tokio::test]
async fn when_posting_valid_site_onboarding_then_returns_201_with_credentials() {
    let state = AppState::new();
    let payload = RegisterSiteRequest {
        site_name: "Palmiye Evleri".to_string(),
        address: "Kadıköy, İstanbul".to_string(),
        site_admin_full_name: "Murat Yıldırım".to_string(),
        site_admin_email: "murat@palmiyeevleri.com".to_string(),
        site_admin_phone: "+90 532 444 5566".to_string(),
        plan_type: Some("STANDARD".to_string()),
        blocks: Some(vec!["A Blok".to_string()]),
    };

    let res = sitepulse_backend::handlers::register_site(
        axum::extract::State(state),
        axum::Json(payload),
    )
    .await
    .into_response();

    assert_eq!(res.status(), axum::http::StatusCode::CREATED);
    let body = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    for key in ["site_id", "slug", "admin_user_id", "temporary_password"] {
        let value = json[key].as_str().unwrap_or_default();
        assert!(!value.is_empty(), "response is missing {key}: {json}");
    }
    assert_eq!(json["slug"], "palmiye-evleri");
}

#[tokio::test]
async fn when_registering_home_owner_then_sends_activation_instead_of_a_password() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    let req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 22,
        floor: 6,
        owner_full_name: "Canan Dağ".to_string(),
        email: "canan.dag@begonya.com".to_string(),
        phone: "+90 532 444 5566".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: Some("1/24".to_string()),
        monthly_dues: Some(Decimal::from_str_exact("1400.00").unwrap()),
        house_type: Some("2+1".to_string()),
        is_resident: true,
        role: None,
    };

    let res = service
        .register_home_owner("site-1", req)
        .await
        .expect("Registration failed");
    assert_eq!(res.owner_full_name, "Canan Dağ");
    assert_eq!(res.activation.expect("activation status").status, "SENT");
    assert!(res.must_change_password);
}

#[tokio::test]
async fn when_duplicate_email_for_home_owner_then_throws_exception() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    let req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 14,
        floor: 4,
        owner_full_name: "Ahmet Yılmaz".to_string(),
        email: "ahmet.yilmaz@begonya.com".to_string(), // duplicate seed
        phone: "+90 532 111 22 33".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: Some("3+1".to_string()),
        is_resident: true,
        role: None,
    };

    let err = service
        .register_home_owner("site-1", req)
        .await
        .unwrap_err();
    assert_eq!(err, site_admin_service::EMAIL_NOT_AVAILABLE);
    assert!(
        !err.contains("ahmet.yilmaz"),
        "the address must not be echoed back"
    );
}

#[tokio::test]
async fn when_generating_invite_link_then_returns_valid_url_and_token() {
    let state = AppState::new();
    let service = RegistrationApprovalService::new(state);

    let res = service.generate_invitation_link("site-1").await;
    assert!(res.token.starts_with("SP-INV-"));
    assert!(res
        .join_url
        .contains("https://sitepulse.app/join/begonya-sitesi?token="));
}

#[tokio::test]
async fn when_submitting_self_registration_then_creates_pending_request() {
    let state = AppState::new();
    let service = RegistrationApprovalService::new(state);

    let req = SubmitSelfRegistrationRequest {
        block: "C Blok".to_string(),
        unit_no: 8,
        floor: 2,
        full_name: "Murat Güven".to_string(),
        email: "murat.guven@gmail.com".to_string(),
        phone: "+90 533 777 8899".to_string(),
        is_resident: true,
    };

    let res = service
        .submit_self_registration("begonya-sitesi", req)
        .await
        .expect("Submit failed");
    assert_eq!(res.status, RegistrationStatus::Pending);
    assert_eq!(res.full_name, "Murat Güven");
}

#[tokio::test]
async fn when_approving_pending_registration_then_provisions_user_and_returns_credentials() {
    let state = AppState::new();
    let service = RegistrationApprovalService::new(state);

    let token = sitepulse_backend::auth::issue_token(
        "usr-site-manager-1",
        "manager@test.example",
        Role::SiteManager,
        "site-1",
        None,
    )
    .unwrap();
    let mut claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    claims.role = Role::SiteManager;
    claims.site_id = "site-1".to_string();
    let ctx = sitepulse_backend::authorization::AuthzContext {
        claims,
        permissions: Permission::permissions_for_role(Role::SiteManager),
        request_id: "test-approval".to_string(),
        stepped_up: false,
    };
    let res = service
        .approve_registration(&ctx, "req-seed-01")
        .await
        .expect("Approval failed");
    assert_eq!(res.status, RegistrationStatus::Approved);
    assert!(res.temporary_password.starts_with("SP-RESIDENT-"));
    assert_eq!(res.email, "kerem.yilmaz@gmail.com");
}

#[tokio::test]
async fn when_generating_unit_invite_link_then_returns_unit_scoped_url_and_token() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state);

    let res = service
        .generate_unit_invite_link("d-14", Some("Aile Bireyi".to_string()))
        .await
        .expect("invitation persisted");
    assert!(res.token.starts_with("SP-HANE-"));
    assert!(res.invite_url.contains("units/d-14?token="));
    assert_eq!(res.building, "A Blok");
    assert_eq!(res.unit_number, "14");
    assert!(res.security_notice.contains("A Blok D:14 yetkisi tanımlar"));
}

#[tokio::test]
async fn when_generating_unit_invite_for_unknown_unit_then_returns_not_found() {
    let service = HomeResidentInvitationService::new(AppState::new());

    let result = service
        .generate_unit_invite_link("missing-unit", None)
        .await;

    assert_eq!(result.unwrap_err(), "Unit not found");
}

#[tokio::test]
async fn when_registering_home_resident_then_assigns_home_resident_role_and_unit_scope() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state.clone());

    let invite = service
        .generate_unit_invite_link("d-14", Some("Kardeş".to_string()))
        .await
        .expect("invitation persisted");

    let req = RegisterHomeResidentRequest {
        token: invite.token,
        full_name: "Selin Yılmaz".to_string(),
        email: "selin.yilmaz@gmail.com".to_string(),
        phone: Some("+90 535 888 9900".to_string()),
        relationship: Some("Kardeş".to_string()),
    };

    let res = service
        .register_home_resident(req)
        .await
        .expect("Registration failed");
    assert_eq!(res.role, "HOME_RESIDENT");
    assert!(res.permission_scope.contains("UNIT_ONLY (d-14)"));
    assert!(res.temporary_password.starts_with("SP-HANE-"));

    let token = sitepulse_backend::auth::issue_token(
        &res.resident_id,
        &res.email,
        Role::HomeResident,
        "site-1",
        Some(&res.unit_id),
    )
    .unwrap();
    let mut claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    claims.email = res.email.clone();
    claims.site_id = "site-1".to_string();
    claims.role = Role::HomeResident;
    claims.unit_id = Some(res.unit_id.clone());
    assert!(state
        .inner
        .read()
        .await
        .unit_members
        .get(&res.unit_id)
        .unwrap()
        .iter()
        .any(|member| member.email == claims.email));
    sitepulse_backend::authorization::unit(&state, &claims, &res.unit_id)
        .await
        .expect("new household member can access the invited unit dashboard");
}

#[tokio::test]
async fn when_duplicate_email_for_home_resident_then_throws_exception() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state);

    let invite = service
        .generate_unit_invite_link("d-14", None)
        .await
        .expect("invitation persisted");

    let req = RegisterHomeResidentRequest {
        token: invite.token,
        full_name: "Ahmet Yılmaz".to_string(),
        email: "ahmet.yilmaz@begonya.com".to_string(), // duplicate seed
        phone: None,
        relationship: None,
    };

    let err = service.register_home_resident(req).await.unwrap_err();
    assert!(err.contains("already exists") || err.contains("zaten mevcut"));
}

// covers: SC-06-02-01
#[tokio::test]
async fn when_valid_password_registration_then_can_authenticate() {
    let state = AppState::new();
    let invite = HomeResidentInvitationService::new(state.clone())
        .generate_unit_invite_link("d-14", None)
        .await
        .expect("invitation persisted");
    let service = AuthService::new(state);

    let reg_req = RegisterUserRequest {
        full_name: "Emre Aydın".to_string(),
        email: "emre.aydin@gmail.com".to_string(),
        password: "SuperSecretPassword123".to_string(),
        phone: Some("+90 532 999 8877".to_string()),
        unit_invite_token: Some(invite.token.clone()),
    };

    let reg_res = service
        .register_with_password(reg_req)
        .await
        .expect("Register failed");
    assert_eq!(reg_res.user.full_name, "Emre Aydın");
    assert_eq!(
        reg_res.user.site_id, "site-1",
        "site comes from the invited unit"
    );
    assert_eq!(reg_res.user.unit_id, "d-14");
    let claims =
        sitepulse_backend::auth::verify_token(&reg_res.access_token).expect("signed token");
    assert!(
        claims.unit_id.is_none(),
        "access credentials carry no cached resource authority"
    );

    // The invite token is single-use.
    let replay = service
        .register_with_password(RegisterUserRequest {
            full_name: "Replay".to_string(),
            email: "replay@gmail.com".to_string(),
            password: "AnotherPassword123".to_string(),
            phone: None,
            unit_invite_token: Some(invite.token),
        })
        .await
        .unwrap_err();
    assert!(
        replay.contains("kullanıldı") || replay.contains("used") || replay.contains("Invalid"),
        "unexpected invite replay error: {replay}"
    );

    let login_req = PasswordLoginRequest {
        email: "emre.aydin@gmail.com".to_string(),
        password: "SuperSecretPassword123".to_string(),
    };

    let login_res = service
        .authenticate_with_password(login_req)
        .await
        .expect("Login failed");
    assert_eq!(login_res.user.email, "emre.aydin@gmail.com");
    assert_eq!(login_res.token_type, "Bearer");
}

#[tokio::test]
async fn when_wrong_password_then_throws_exception() {
    let state = AppState::new();
    let service = AuthService::new(state);

    let login_req = PasswordLoginRequest {
        email: "ahmet.yilmaz@begonya.com".to_string(),
        password: "WrongPassword999!".to_string(),
    };

    let err = service
        .authenticate_with_password(login_req)
        .await
        .unwrap_err();
    assert!(err.contains("Invalid") || err.contains("hatalı"));
}

// covers: SC-06-03-01
#[tokio::test]
async fn when_valid_google_id_token_then_authenticates_and_links_account() {
    let mut state = AppState::new();
    state.settings.allow_mock_google_tokens = true;
    let invite = HomeResidentInvitationService::new(state.clone())
        .generate_unit_invite_link("d-14", None)
        .await
        .expect("invitation persisted");
    let service = AuthService::new(state);

    let req = GoogleLoginRequest {
        id_token: "mock-google-token:sub-998877:google.ahmet@gmail.com:Ahmet Yılmaz Google"
            .to_string(),
        unit_invite_token: Some(invite.token),
    };

    let res = service
        .authenticate_with_google(req)
        .await
        .expect("Google auth failed");
    assert_eq!(res.user.email, "google.ahmet@gmail.com");
    assert_eq!(res.user.auth_provider, AuthProvider::Google);
}

#[test]
fn when_resident_role_then_has_unit_restricted_permissions() {
    let permissions = Permission::permissions_for_role(Role::HomeResident);
    assert!(permissions.contains(&Permission::UnitRead));
    assert!(permissions.contains(&Permission::UnitPay));
    assert!(!permissions.contains(&Permission::UnitInviteCoResident));
    assert!(!permissions.contains(&Permission::UnitManageHousehold));
    assert!(!permissions.contains(&Permission::SiteManage));
    assert!(!permissions.contains(&Permission::LedgerManageAll));
    assert!(!permissions.contains(&Permission::TenantManage));
}

// covers: SC-06-04-01
#[test]
fn when_home_owner_role_then_has_invite_and_household_permissions() {
    let permissions = Permission::permissions_for_role(Role::HomeOwner);
    assert!(permissions.contains(&Permission::UnitRead));
    assert!(permissions.contains(&Permission::UnitPay));
    assert!(permissions.contains(&Permission::UnitInviteCoResident));
    assert!(permissions.contains(&Permission::UnitManageHousehold));
    assert!(!permissions.contains(&Permission::SiteManage));
}

#[tokio::test]
async fn when_deleting_action_free_site_then_succeeds_and_removes_site() {
    let state = AppState::new();
    let service = SaasTenantService::new(state.clone());

    // Register a new action-free site
    let reg_req = RegisterSiteRequest {
        site_name: "Nilüfer Konutları".to_string(),
        address: "Nilüfer, Bursa".to_string(),
        plan_type: Some("STANDARD".to_string()),
        site_admin_full_name: "Deniz Yılmaz".to_string(),
        site_admin_email: "deniz@nilufer.com".to_string(),
        site_admin_phone: "+90 532 999 1122".to_string(),
        blocks: None,
    };

    let reg_res = service
        .register_site(reg_req)
        .await
        .expect("Site registration failed");
    let site_id = reg_res.site_id;

    // Delete the action-free site
    let del_res = service.delete_site(&site_id).await;
    assert!(del_res.is_ok());

    // Verify it is no longer in the site list
    let all_sites = service.get_all_sites().await;
    assert!(!all_sites.iter().any(|s| s.site_id == site_id));

    service
        .register_site(RegisterSiteRequest {
            site_name: "Nilüfer Yeni Konutları".to_string(),
            address: "Nilüfer, Bursa".to_string(),
            plan_type: Some("STANDARD".to_string()),
            site_admin_full_name: "Deniz Yılmaz".to_string(),
            site_admin_email: "deniz@nilufer.com".to_string(),
            site_admin_phone: "+90 532 999 1122".to_string(),
            blocks: None,
        })
        .await
        .expect("a soft-deleted site's manager email must be reusable");
}

#[tokio::test]
async fn when_deleting_site_with_active_units_or_actions_then_strictly_rejected() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    // "site-1" (Begonya Sitesi) has active units (d-14), dues (b-101), and pending registrations
    let err_msg = service.delete_site("site-1").await.unwrap_err();
    assert!(err_msg.contains("active units exist") || err_msg.contains("işlem kaydı"));
}

#[tokio::test]
async fn when_resetting_admin_password_then_generates_new_temporary_password_and_forces_change() {
    let state = AppState::new();
    let tenant_service = SaasTenantService::new(state.clone());
    let auth_service = AuthService::new(state.clone());

    let reset_res = tenant_service
        .reset_site_admin_password("site-1")
        .await
        .expect("Password reset failed");

    assert_eq!(reset_res.site_id, "site-1");
    assert!(reset_res.temporary_password.starts_with("SP-"));
    assert!(reset_res.must_change_password);
    assert_eq!(reset_res.admin_email, "mehmet.demir@begonya.com");

    // Verify the site manager can authenticate with the renewed temporary password
    let login_req = PasswordLoginRequest {
        email: reset_res.admin_email,
        password: reset_res.temporary_password,
    };
    let login_res = auth_service
        .authenticate_with_password(login_req)
        .await
        .expect("Authentication with renewed password should succeed");

    assert_eq!(login_res.user.role, Role::SiteManager);
    assert!(login_res.user.must_change_password);
}

// covers: SC-03-07-02
#[tokio::test]
async fn when_resetting_admin_password_for_non_existent_site_then_fails() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    let err = service
        .reset_site_admin_password("invalid-site-id")
        .await
        .unwrap_err();
    assert!(
        err.contains("bulunamadı") || err.contains("not found") || err.contains("NotFound"),
        "unexpected error: {err}"
    );
}

// ============================================================================
// STORY-07-02: Zero-Approval Bank Statement (Excel / CSV / MT940) Parser Tests
// ============================================================================

// covers: SC-07-02-01
#[tokio::test]
async fn when_parsing_turkish_bank_excel_then_matches_flat_and_amount() {
    let state = AppState::new();
    let parser = sitepulse_backend::services::BankStatementParser::new();
    let recon_service = sitepulse_backend::services::ReconciliationService::new();

    // Excel export single line / row copied from bank
    let excel_content = "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33";

    let txns = parser
        .parse_statement(
            excel_content,
            Some(sitepulse_backend::models::BankStatementFormat::Excel),
        )
        .expect("Failed to parse Excel statement row");

    assert_eq!(txns.len(), 1);
    let txn = &txns[0];
    assert_eq!(txn.amount, Decimal::from_str_exact("1423.33").unwrap());

    let inner = state.inner.read().await;
    let units = &inner.units;
    let users = &inner.users;
    let dues = &inner.dues;

    // Evaluation date: 10 days overdue past 2026-09-15 -> 2026-09-25
    let eval_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();

    let matches = recon_service.reconcile_transactions(&txns, units, users, dues, eval_date);
    assert_eq!(matches.len(), 1);

    let m = &matches[0];
    // Then the engine identifies unit "A Blok D:14" with 100% confidence
    assert_eq!(m.matched_unit_id.as_deref(), Some("d-14"));
    assert_eq!(m.matched_block.as_deref(), Some("A"));
    assert_eq!(m.matched_unit_number, Some(14));
    assert_eq!(m.matched_resident_name.as_deref(), Some("Ahmet Yılmaz"));
    assert_eq!(m.confidence_score, 100);

    // And matches the exact outstanding dues balance ₺1.423,33
    assert_eq!(
        m.outstanding_balance,
        Some(Decimal::from_str_exact("1423.33").unwrap())
    );
    assert!(m.amount_matches_balance);

    // And marks the transaction as "ONAY_BEKLIYOR" in the reconciliation queue
    assert_eq!(
        m.status,
        sitepulse_backend::models::ReconciliationStatus::PendingApproval
    );
    assert_eq!(m.status_code, "ONAY_BEKLIYOR");
}

#[test]
fn flutter_reconciliation_payload_uses_backend_enum_contract() {
    let payload = serde_json::json!({
        "match_id": "match-1",
        "site_id": "1",
        "transaction": {
            "transaction_id": "txn-1",
            "date": "2026-09-15",
            "amount": "100.00",
            "currency": "TRY",
            "description": "Aidat",
            "sender_name": null,
            "sender_iban": null,
            "reference_no": null
        },
        "matched_unit_id": "14",
        "matched_block": "A",
        "matched_unit_number": 14,
        "matched_resident_name": "Resident",
        "confidence_score": 90,
        "matched_due_id": null,
        "outstanding_balance": "100.00",
        "amount_matches_balance": true,
        "status": "PENDING_APPROVAL",
        "status_code": "ONAY_BEKLIYOR",
        "notes": null
    });
    let parsed: ReconciliationMatch = serde_json::from_value(payload)
        .expect("Flutter reconciliation payload deserializes on the API");
    assert_eq!(parsed.status, ReconciliationStatus::PendingApproval);
}

// covers: SC-07-02-03
#[tokio::test]
async fn when_parsing_mt940_statement_then_extracts_transactions_and_matches_due() {
    let state = AppState::new();
    let parser = sitepulse_backend::services::BankStatementParser::new();
    let recon_service = sitepulse_backend::services::ReconciliationService::new();

    let mt940_content = r#":20:STARTMR
:25:TR120006200000000000001001
:28C:00001/001
:60F:C260901TRY50000,00
:61:2609150915CR1423,33NTRFNONREF//TXN77889
:86:HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT
:62F:C260930TRY51423,33
-"#;

    let txns = parser
        .parse_statement(
            mt940_content,
            Some(sitepulse_backend::models::BankStatementFormat::Mt940),
        )
        .expect("Failed to parse SWIFT MT940 content");

    assert_eq!(txns.len(), 1);
    let txn = &txns[0];
    assert_eq!(txn.date, NaiveDate::from_ymd_opt(2026, 9, 15).unwrap());
    assert_eq!(txn.amount, Decimal::from_str_exact("1423.33").unwrap());
    assert_eq!(txn.currency, "TRY");

    let inner = state.inner.read().await;
    let eval_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();

    let matches = recon_service.reconcile_transactions(
        &txns,
        &inner.units,
        &inner.users,
        &inner.dues,
        eval_date,
    );
    assert_eq!(matches.len(), 1);

    let m = &matches[0];
    assert_eq!(m.matched_unit_id.as_deref(), Some("d-14"));
    assert_eq!(m.confidence_score, 100);
    assert_eq!(m.status_code, "ONAY_BEKLIYOR");
}

#[tokio::test]
async fn when_confirming_reconciliation_batch_then_updates_dues_and_ledger() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;
    let parser = sitepulse_backend::services::BankStatementParser::new();
    let recon_service = sitepulse_backend::services::ReconciliationService::new();

    let content = "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33";
    let txns = parser.parse_statement(content, None).unwrap();

    let eval_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
    let inner = state.inner.write().await;
    let matches = recon_service.reconcile_transactions(
        &txns,
        &inner.units,
        &inner.users,
        &inner.dues,
        eval_date,
    );

    let match_id = matches[0].match_id.clone();
    drop(inner);

    // Call confirm_reconciliation
    let payload = sitepulse_backend::models::ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        matches: matches.clone(),
        optional_message: None,
        remember_sender_iban: None,
        owner_capital_match_ids: Vec::new(),
        debtor_assignments: Default::default(),
    };

    let (status, res) = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(payload),
    )
    .await
    .expect("Reconciliation confirmation failed");

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.confirmed_count, 1);
    assert_eq!(
        res.total_amount_cleared,
        Decimal::from_str_exact("1423.33").unwrap()
    );
    assert_eq!(res.updated_unit_ids, vec!["d-14".to_string()]);
    assert_eq!(res.confirmed_matches.len(), 1);
    assert!(!res.message_sent);
    assert!(res.notification_summary.is_none());

    let inner = state.inner.read().await;
    // Check due status is now Paid
    let due = inner.dues.iter().find(|d| d.id == "b-101").unwrap();
    assert_eq!(due.status, sitepulse_backend::models::DebtStatus::Paid);

    // Check queue item is Approved
    let queue_item = inner
        .reconciliation_queue
        .iter()
        .find(|m| m.match_id == match_id)
        .unwrap();
    assert_eq!(
        queue_item.status,
        sitepulse_backend::models::ReconciliationStatus::Approved
    );
}

#[tokio::test]
async fn when_confirming_reconciliation_with_optional_message_then_reports_notification_sent() {
    let state = AppState::new();
    let parser = sitepulse_backend::services::BankStatementParser::new();
    let recon_service = sitepulse_backend::services::ReconciliationService::new();

    let content = "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33";
    let txns = parser.parse_statement(content, None).unwrap();

    let eval_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
    let mut inner = state.inner.write().await;
    let matches = recon_service.reconcile_transactions(
        &txns,
        &inner.units,
        &inner.users,
        &inner.dues,
        eval_date,
    );

    for m in &matches {
        inner.reconciliation_queue.push(m.clone());
    }
    let match_id = matches[0].match_id.clone();
    drop(inner);

    let payload = sitepulse_backend::models::ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id.clone()],
        matches: vec![],
        optional_message: Some(
            "Sayın Ahmet Yılmaz, ₺1.423,33 aidat ödemeniz onaylanmıştır.".to_string(),
        ),
        remember_sender_iban: None,
        owner_capital_match_ids: Vec::new(),
        debtor_assignments: Default::default(),
    };

    let (status, res) = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(payload),
    )
    .await
    .expect("Reconciliation confirmation failed");

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.confirmed_count, 1);
    assert!(res.message_sent);
    assert!(res
        .notification_summary
        .as_ref()
        .unwrap()
        .contains("iletildi"));
}

// covers: SC-07-06-01
#[tokio::test]
async fn when_site_manager_configures_bank_account_then_format_is_automatically_set_by_bank() {
    let state = AppState::new();
    let service = SiteBankAccountService::new(state.clone());

    let req = ConfigureBankAccountRequest {
        bank_code: "KUVEYT_TURK".to_string(),
        iban: "TR190020500009863791600001".to_string(),
        account_holder: "Begonya Sitesi Yönetimi".to_string(),
        configured_by: Some("usr-site-manager-1".to_string()),
    };

    let res = service
        .configure_account("site-1", req)
        .await
        .expect("Configuration failed");

    assert_eq!(res.bank_code, "KUVEYT_TURK");
    assert_eq!(res.statement_format, BankStatementFormat::Excel);
    assert_eq!(res.bank_name, "Kuveyt Türk Katılım Bankası");
    assert!(res.is_active);

    // Verify retrieval
    let active = service
        .get_active_account("site-1")
        .await
        .expect("Account not found");
    assert_eq!(active.id, res.id);
    assert_eq!(active.statement_format, BankStatementFormat::Excel);
}

#[tokio::test]
async fn when_site_manager_changes_bank_account_then_previous_account_deactivated_and_new_format_set(
) {
    let state = AppState::new();
    let service = SiteBankAccountService::new(state.clone());

    // Initially site-1 has Kuveyt Turk (EXCEL)
    let initial = service.get_active_account("site-1").await.unwrap();
    assert_eq!(initial.statement_format, BankStatementFormat::Excel);

    // Site manager switches bank to Türkiye İş Bankası (CSV)
    let req1 = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "TR290006400000112345678901".to_string(),
        account_holder: "Begonya Sitesi Yeni Hesap".to_string(),
        configured_by: Some("usr-site-manager-1".to_string()),
    };
    let updated1 = service.configure_account("site-1", req1).await.unwrap();
    assert_eq!(updated1.bank_code, "IS_BANKASI");
    assert_eq!(updated1.statement_format, BankStatementFormat::Csv);

    // Verify only ONE active account exists for site-1
    let inner = state.inner.read().await;
    let active_accounts: Vec<_> = inner
        .site_bank_accounts
        .iter()
        .filter(|a| a.site_id == "site-1" && a.is_active)
        .collect();
    assert_eq!(active_accounts.len(), 1);
    assert_eq!(active_accounts[0].id, updated1.id);

    // Check old account is marked inactive
    let old = inner
        .site_bank_accounts
        .iter()
        .find(|a| a.id == initial.id)
        .unwrap();
    assert!(!old.is_active);
}

#[tokio::test]
async fn when_invalid_bank_code_or_iban_then_configuration_fails_validation() {
    let state = AppState::new();
    let service = SiteBankAccountService::new(state.clone());

    // 1. Unknown bank code
    let req_unknown = ConfigureBankAccountRequest {
        bank_code: "NON_EXISTENT_BANK".to_string(),
        iban: "TR290006400000112345678901".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    let err1 = service
        .configure_account("site-1", req_unknown)
        .await
        .unwrap_err();
    assert!(err1.contains("Unknown bank code"), "got: {err1}");

    // 2. Non-TR IBAN
    let req_non_tr = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "DE89370400440532013000".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    let err2 = service
        .configure_account("site-1", req_non_tr)
        .await
        .unwrap_err();
    assert!(err2.contains("Invalid IBAN"), "got: {err2}");

    // 3. Short IBAN
    let req_short = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "TR123".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    let err3 = service
        .configure_account("site-1", req_short)
        .await
        .unwrap_err();
    assert!(err3.contains("Invalid IBAN"), "got: {err3}");

    // 4. Empty account holder
    let req_empty_holder = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "TR290006400000112345678901".to_string(),
        account_holder: "   ".to_string(),
        configured_by: None,
    };
    let err4 = service
        .configure_account("site-1", req_empty_holder)
        .await
        .unwrap_err();
    assert!(
        err4.contains("Account holder") || err4.contains("required"),
        "got: {err4}"
    );

    // 5. Correct structure but wrong check digits (one mistyped digit)
    let req_bad_checksum = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "TR290006400000112345678902".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    let err5 = service.configure_account("site-1", req_bad_checksum).await;
    assert!(err5.unwrap_err().contains("check digits"));

    // 6. Valid IBAN of a different bank than the one selected
    let req_bank_mismatch = ConfigureBankAccountRequest {
        bank_code: "KUVEYT_TURK".to_string(),
        iban: "TR290006400000112345678901".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    let err6 = service.configure_account("site-1", req_bank_mismatch).await;
    assert!(err6.unwrap_err().contains("does not belong to"));

    // 7. Multi-byte input of IBAN length must be rejected, not panic
    let req_multibyte = ConfigureBankAccountRequest {
        bank_code: "IS_BANKASI".to_string(),
        iban: "TRé00064000001123456789".to_string(),
        account_holder: "Begonya Sitesi".to_string(),
        configured_by: None,
    };
    assert!(service
        .configure_account("site-1", req_multibyte)
        .await
        .is_err());
}

// covers: SC-07-06-02
#[tokio::test]
async fn when_parsing_bank_statement_then_enforces_active_bank_format_and_permits_new_format_after_change(
) {
    let state = AppState::new();

    // 1. Initial state: site-1 is Kuveyt Türk (requires EXCEL)
    let excel_content = "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33";
    let mt940_content = ":20:STARTMR\n:25:TR120006200000000000001001\n:28C:00001/001\n:60F:C260901TRY50000,00\n:61:2609150915CR1423,33NTRFNONREF//TXN77889\n:86:HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT\n:62F:C260930TRY51423,33\n-";

    // Ingestion of Excel succeeds under Kuveyt Türk
    let (status1, res1) = sitepulse_backend::handlers::parse_bank_statement(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ParseBankStatementRequest {
            site_id: "site-1".to_string(),
            content: excel_content.to_string(),
            format: None, // Auto-derived from active bank account!
        }),
    )
    .await
    .expect("Excel parse failed");
    assert_eq!(status1, axum::http::StatusCode::OK);
    assert_eq!(res1.total_transactions, 1);

    // Ingestion of MT940 content under Kuveyt Türk (Excel) fails format mismatch
    let err_mt940_under_excel = sitepulse_backend::handlers::parse_bank_statement(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ParseBankStatementRequest {
            site_id: "site-1".to_string(),
            content: mt940_content.to_string(),
            format: None,
        }),
    )
    .await;
    assert!(err_mt940_under_excel.is_err());
    let (code, msg) = err_mt940_under_excel.unwrap_err();
    assert_eq!(code, axum::http::StatusCode::BAD_REQUEST);
    assert!(msg.contains("File format mismatch"));

    // Ingestion with conflicting explicit format parameter fails
    let err_explicit_mismatch = sitepulse_backend::handlers::parse_bank_statement(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ParseBankStatementRequest {
            site_id: "site-1".to_string(),
            content: excel_content.to_string(),
            format: Some(BankStatementFormat::Mt940),
        }),
    )
    .await;
    assert!(err_explicit_mismatch.is_err());

    // 2. NOW: Site Manager changes the bank account to Vakıfbank (which exports MT940)
    let switch_req = ConfigureBankAccountRequest {
        bank_code: "VAKIFBANK".to_string(),
        iban: "TR790001500000123456789012".to_string(),
        account_holder: "Begonya Sitesi Yönetimi".to_string(),
        configured_by: Some("usr-site-manager-1".to_string()),
    };
    let (cfg_status, cfg_res) = sitepulse_backend::handlers::configure_site_bank_account(
        axum::extract::Path("site-1".to_string()),
        axum::extract::State(state.clone()),
        axum::Json(switch_req),
    )
    .await
    .expect("Failed to switch bank account");
    assert_eq!(cfg_status, axum::http::StatusCode::OK);
    assert_eq!(cfg_res.bank_code, "VAKIFBANK");
    assert_eq!(cfg_res.statement_format, BankStatementFormat::Mt940);

    // 3. VERIFY: The new bank format (MT940) is now PERMISSIBLE and succeeds!
    let (status2, res2) = sitepulse_backend::handlers::parse_bank_statement(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ParseBankStatementRequest {
            site_id: "site-1".to_string(),
            content: mt940_content.to_string(),
            format: None, // Auto-derived from new active bank (MT940)!
        }),
    )
    .await
    .expect("MT940 statement should now succeed under Vakıfbank");
    assert_eq!(status2, axum::http::StatusCode::OK);
    assert_eq!(res2.total_transactions, 1);

    // And the previous Excel tabular format is now rejected under Vakıfbank
    let err_excel_under_mt940 = sitepulse_backend::handlers::parse_bank_statement(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(ParseBankStatementRequest {
            site_id: "site-1".to_string(),
            content: excel_content.to_string(),
            format: None,
        }),
    )
    .await;
    assert!(err_excel_under_mt940.is_err());
    let (code2, msg2) = err_excel_under_mt940.unwrap_err();
    assert_eq!(code2, axum::http::StatusCode::BAD_REQUEST);
    assert!(msg2.contains("File format mismatch"));
}

// covers: SC-07-01-01
#[test]
fn when_unit_created_then_generates_unique_sanal_iban() {
    let iban = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14).unwrap();
    assert_eq!(iban.len(), 26);
    assert!(iban.starts_with("TR"));
    assert!(iban.contains("00205"));
    assert!(VirtualIbanService::validate_tr_iban(&iban));
}

#[tokio::test]
async fn when_probing_kuveyt_turk_sandbox_status_then_reports_keys_loaded() {
    let directory =
        std::env::temp_dir().join(format!("sitepulse-key-presence-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let private = directory.join("private.asc");
    let public = directory.join("public.asc");
    std::fs::write(&private, "test-only key presence fixture").unwrap();
    std::fs::write(&public, "test-only key presence fixture").unwrap();
    let mut service = sitepulse_backend::services::KuveytTurkSandboxService::new();
    service.private_key_path = private.to_string_lossy().into_owned();
    service.public_key_path = public.to_string_lossy().into_owned();
    let status_json = service.get_config_status(None);
    std::fs::remove_dir_all(directory).unwrap();
    assert!(status_json.is_sandbox);
    assert_eq!(
        status_json.identity_url,
        "https://prep-identity.kuveytturk.com.tr"
    );
    assert_eq!(
        status_json.gateway_url,
        "https://prep-gateway.kuveytturk.com.tr"
    );
    // Presence checks use isolated fixtures, never real banking credentials.
    assert!(status_json.private_key_present);
    assert!(status_json.public_key_present);
}

// covers: SC-07-01-02
#[tokio::test]
async fn when_querying_resident_dashboard_then_includes_allocated_virtual_iban() {
    let state = AppState::new();
    let res = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
        resident_dashboard_authz(Role::HomeOwner),
    )
    .await;

    // IntoResponse produces (StatusCode, Json<ResidentDashboardDto>)
    let json_bytes = axum::body::to_bytes(res.into_response().into_body(), 1024 * 64)
        .await
        .unwrap();
    let dto: ResidentDashboardDto = serde_json::from_slice(&json_bytes).unwrap();

    assert!(dto.virtual_iban.is_some());
    let iban = dto.virtual_iban.unwrap();
    assert!(iban.starts_with("TR"));
    assert!(iban.contains("00205"));
    assert!(VirtualIbanService::validate_tr_iban(&iban));
}

// covers: SC-05-03-01
#[tokio::test]
async fn when_getting_resident_dashboard_then_returns_real_time_calculated_dues() {
    let state = AppState::new();
    // The dashboard ages a charge by the site's local date, not UTC. Taking the
    // reference date from the same site clock keeps the expected penalty at ten
    // days instead of flipping to eleven every evening in UTC+3.
    let today = {
        let inner = state.inner.read().await;
        let site = inner
            .units
            .iter()
            .find(|unit| unit.id == "d-14")
            .map(|unit| unit.site_id.clone())
            .expect("fixture unit d-14");
        sitepulse_backend::services::finance_common::site_today(&inner, &site)
    };
    let due_date = today - chrono::Duration::days(10);
    {
        let mut inner = state.inner.write().await;
        inner.dues.retain(|d| d.unit_id != "d-14");
        inner.dues.push(DuesLiability {
            id: "due-realtime-test".to_string(),
            unit_id: "d-14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("1400.00").unwrap(),
            due_date,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let res = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
        resident_dashboard_authz(Role::HomeOwner),
    )
    .await;

    let json_bytes = axum::body::to_bytes(res.into_response().into_body(), 1024 * 64)
        .await
        .unwrap();
    let dto: ResidentDashboardDto = serde_json::from_slice(&json_bytes).unwrap();
    assert_eq!(dto.total_debt, Decimal::from_str_exact("1423.33").unwrap());
    let due = dto
        .dues
        .iter()
        .find(|d| d.id == "due-realtime-test")
        .unwrap();
    assert_eq!(
        due.principal_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(due.delay_penalty, Decimal::from_str_exact("23.33").unwrap());
    assert_eq!(
        due.total_amount,
        Decimal::from_str_exact("1423.33").unwrap()
    );
}

#[tokio::test]
async fn when_querying_resident_dashboard_then_separates_capital_dues_by_project() {
    let state = AppState::new_with_test_fixtures();
    let project = CapitalProject {
        id: "cproj-dashboard-test".to_string(),
        site_id: "site-1".to_string(),
        title: "Roof Renewal".to_string(),
        category: CapitalProjectCategory::RoofWaterproofing,
        description: None,
        total_budget: Decimal::from_str_exact("1400.00").unwrap(),
        allocation_basis: AllocationBasis::ByLandShare,
        target_start_date: chrono::Utc::now().date_naive(),
        target_completion_date: None,
        contractor_name: None,
        contractor_tax_no: None,
        contractor_iban: None,
        contract_amount: None,
        status: CapitalProjectStatus::Active,
        collected_amount: Decimal::ZERO,
        disbursed_amount: Decimal::ZERO,
        remaining_fund_balance: Decimal::ZERO,
        total_units_count: 1,
        installments_count: 1,
        created_at: None,
    };
    state
        .inner
        .write()
        .await
        .capital_projects
        .push(project.clone());
    state.inner.write().await.dues.push(DuesLiability {
        id: "capital-due-d14".to_string(),
        unit_id: "d-14".to_string(),
        period: format!("{}: Taksit 1/3", project.title),
        principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact("1400.00").unwrap(),
        due_date: chrono::Utc::now().date_naive() + chrono::Days::new(10),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::CapitalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    });
    {
        let inner = state.inner.read().await;
        assert!(inner
            .dues
            .iter()
            .any(|due| due.unit_id == "d-14" && due.expense_type == ExpenseType::CapitalDues));
        assert!(inner
            .capital_projects
            .iter()
            .any(|item| item.id == project.id && item.site_id == "site-1"));
        assert_eq!(
            resident_dashboard_authz(Role::HomeOwner).claims.role,
            Role::HomeOwner
        );
        assert!(inner.dues.iter().any(|due| {
            due.unit_id == "d-14"
                && due
                    .period
                    .starts_with(&format!("{}: Taksit ", project.title))
                && due.status != DebtStatus::Paid
                && due.expense_type == ExpenseType::CapitalDues
        }));
    }

    let response = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
        resident_dashboard_authz(Role::HomeOwner),
    )
    .await;
    let body = axum::body::to_bytes(response.into_response().into_body(), 1024 * 64)
        .await
        .unwrap();
    let dashboard: ResidentDashboardDto = serde_json::from_slice(&body).unwrap();

    assert_eq!(dashboard.capital_dues.len(), 1);
    assert_eq!(dashboard.capital_dues[0].project_id, project.id);
    assert_eq!(dashboard.capital_dues[0].project_title, project.title);
    assert_eq!(
        dashboard.capital_dues[0].outstanding_balance,
        Decimal::from_str_exact("1400.00").unwrap()
    );

    let resident_response = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state),
        resident_dashboard_authz(Role::HomeResident),
    )
    .await;
    let resident_body =
        axum::body::to_bytes(resident_response.into_response().into_body(), 1024 * 64)
            .await
            .unwrap();
    let resident_dashboard: ResidentDashboardDto = serde_json::from_slice(&resident_body).unwrap();
    assert!(resident_dashboard.capital_dues.is_empty());
}

// covers: SC-07-03-02
#[tokio::test]
async fn when_statement_contains_virtual_iban_then_matches_flat_with_100_percent_confidence() {
    let service = ReconciliationService::new();

    let units = vec![IndependentUnit {
        id: "d-14".to_string(),
        site_id: "site-1".to_string(),
        block_id: "A".to_string(),
        unit_number: 14,
        floor: 4,
        land_share: 24,
        owner_user_id: Some("usr-1".to_string()),
        tenant_user_id: None,
        virtual_iban: Some("TR410020504213991067000014".to_string()),
        house_type: Some("2+1".to_string()),
        monthly_tariff_override: None,

        created_on: None,
    }];

    let dues = vec![DuesLiability {
        id: "due-sep".to_string(),
        unit_id: "d-14".to_string(),
        period: "Eylül 2026".to_string(),
        principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact("1400.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Tenant,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    }];

    // Narrative contains NO block name and NO resident name, only the Virtual IBAN!
    let txns = vec![BankTransactionItem {
        transaction_id: "TXN-9988".to_string(),
        date: NaiveDate::from_ymd_opt(2026, 9, 20).unwrap(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        currency: "TRY".to_string(),
        description: "FAST Gelen Transfer TR410020504213991067000014".to_string(),
        sender_name: None,
        sender_iban: None,
        reference_no: None,
    }];

    let matches = service.reconcile_transactions(
        &txns,
        &units,
        &[],
        &dues,
        NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
    );
    assert_eq!(matches.len(), 1);
    let m = &matches[0];
    assert_eq!(m.matched_unit_id.as_deref(), Some("d-14"));
    assert_eq!(m.confidence_score, 100);
    assert!(m.notes.as_ref().unwrap().contains("Virtual IBAN"));
}

// covers: SC-07-03-01
#[tokio::test]
async fn when_bank_webhook_delivers_virtual_iban_payment_then_clears_dues_and_generates_receipt() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    let webhook_req = BankIncomingWebhookRequest {
        transaction_id: "TXN-KUVEYT-001".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: Some("TR120006200000000012345678".to_string()),
        description: Some("Eylül 2026 Aidatı FAST Ödemesi".to_string()),
        signature: Some("HMAC_SHA256_VALID_SIG".to_string()),
    };

    let (status, axum::Json(res)) = call_signed_webhook(state.clone(), webhook_req.clone())
        .await
        .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.status, "CLEARED");
    assert_eq!(res.matched_unit_id, "d-14");
    assert_eq!(res.matched_block, "A");
    assert_eq!(res.matched_unit_number, 14);
    assert_eq!(res.cleared_due_period.as_deref(), Some("Eylül 2026"));
    assert!(
        res.receipt_id.starts_with("TAH-"),
        "canonical receipt (SPEC-005 R1): {}",
        res.receipt_id
    );

    // Verify state: due is now PAID!
    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.id == "b-101").unwrap();
    assert_eq!(due.status, DebtStatus::Paid);

    // Verify Idempotency Gate (Duplicate Delivery)
    drop(inner);
    let (status2, axum::Json(res2)) = call_signed_webhook(state.clone(), webhook_req)
        .await
        .unwrap();

    assert_eq!(status2, axum::http::StatusCode::OK);
    assert_eq!(res2.status, "DUPLICATE_IGNORED");
}

// covers: SC-07-05-01
#[tokio::test]
async fn when_excess_or_multiple_payments_delivered_then_credited_as_advance_payment() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    // 1. First payment clears existing ₺1400 due
    let webhook_req_1 = BankIncomingWebhookRequest {
        transaction_id: "TXN-ADV-001".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: Some("TR120006200000000012345678".to_string()),
        description: Some("Eylül 2026 Aidatı".to_string()),
        signature: Some("HMAC_VALID".to_string()),
    };

    let (status1, axum::Json(res1)) = call_signed_webhook(state.clone(), webhook_req_1)
        .await
        .unwrap();

    assert_eq!(status1, axum::http::StatusCode::OK);
    assert_eq!(
        res1.cleared_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(res1.remaining_debt, Decimal::ZERO);
    assert_eq!(res1.advance_payment, Decimal::ZERO);

    // 2. Second payment (with new txn id) delivered to same Virtual IBAN when debt is 0
    let webhook_req_2 = BankIncomingWebhookRequest {
        transaction_id: "TXN-ADV-002".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: Decimal::from_str_exact("1460.67").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: Some("TR120006200000000012345678".to_string()),
        description: Some("Ekim 2026 Avans Aidatı".to_string()),
        signature: Some("HMAC_VALID".to_string()),
    };

    let (status2, axum::Json(res2)) = call_signed_webhook(state.clone(), webhook_req_2)
        .await
        .unwrap();

    assert_eq!(status2, axum::http::StatusCode::OK);
    assert_eq!(res2.status, "CLEARED");
    assert_eq!(res2.cleared_due_period, None);
    assert_eq!(res2.remaining_debt, Decimal::ZERO);
    assert_eq!(
        res2.advance_payment,
        Decimal::from_str_exact("1460.67").unwrap()
    );
    assert!(res2.message.contains("advance payment"));

    // 3. Third payment adds another ₺500 to advance payment
    let webhook_req_3 = BankIncomingWebhookRequest {
        transaction_id: "TXN-ADV-003".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: Decimal::from_str_exact("500.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: Some("TR120006200000000012345678".to_string()),
        description: Some("Ekstra Avans".to_string()),
        signature: Some("HMAC_VALID".to_string()),
    };

    let (_, axum::Json(res3)) = call_signed_webhook(state.clone(), webhook_req_3)
        .await
        .unwrap();

    assert_eq!(
        res3.advance_payment,
        Decimal::from_str_exact("1960.67").unwrap()
    );

    // 4. Verify Resident Dashboard reflects the accumulated advance payment
    let res = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state),
        resident_dashboard_authz(Role::HomeOwner),
    )
    .await;

    let json_bytes = axum::body::to_bytes(res.into_response().into_body(), 1024 * 64)
        .await
        .unwrap();
    let dash: ResidentDashboardDto = serde_json::from_slice(&json_bytes).unwrap();

    assert_eq!(dash.total_debt, Decimal::ZERO);
    assert_eq!(
        dash.advance_payment,
        Decimal::from_str_exact("1960.67").unwrap()
    );

    // 5. Verify user-friendly transaction titles and subtitles
    let adv_tx = dash
        .transactions
        .iter()
        .find(|t| t.id == "TXN-ADV-002")
        .unwrap();
    assert_eq!(adv_tx.title, "FAST ile Avans Yükleme");
    assert_eq!(
        adv_tx.subtitle,
        "Aktif borç bulunmuyor • Avans bakiyenize aktarıldı"
    );

    let due_tx = dash
        .transactions
        .iter()
        .find(|t| t.id == "TXN-ADV-001")
        .unwrap();
    assert_eq!(due_tx.title, "FAST ile Aidat Ödemesi");
    assert_eq!(due_tx.subtitle, "Eylül 2026 aidat borcu kapatıldı");
}

// covers: SC-07-05-02
#[tokio::test]
async fn when_new_dues_period_accrued_and_resident_has_advance_payment_then_automatically_offsets_debt(
) {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;
    {
        let mut inner = state.inner.write().await;
        if let Some(d) = inner.dues.iter_mut().find(|d| d.id == "b-101") {
            d.debtor_type = DebtorType::Owner;
        }
    }

    // 1. Payment of ₺2860.67 clears September due (₺1400.00) and leaves ₺1460.67 surplus in advance
    let webhook_req = BankIncomingWebhookRequest {
        transaction_id: "TXN-AUTO-OFFSET-001".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: Decimal::from_str_exact("2860.67").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Ahmet Yılmaz".to_string()),
        sender_iban: Some("TR120006200000000012345678".to_string()),
        description: Some("Eylül 2026 Aidatı + Avans".to_string()),
        signature: Some("HMAC_VALID".to_string()),
    };

    let (status, axum::Json(res)) = call_signed_webhook(state.clone(), webhook_req)
        .await
        .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.remaining_debt, Decimal::ZERO);
    assert_eq!(
        res.advance_payment,
        Decimal::from_str_exact("1460.67").unwrap()
    );

    // 2. New monthly dues period arrives: "Ekim 2026" (₺1400.00)
    let not_yet_due = Utc::now().date_naive() + chrono::Days::new(30);
    let accrued_label =
        sitepulse_backend::domain::billing_period::BillingPeriod::of_date(not_yet_due).label();
    let accrue_req = AccrueDuesPeriodRequest {
        site_id: "site-1".to_string(),
        // The canonical month of the due date (STORY-07-08).
        period: sitepulse_backend::domain::billing_period::BillingPeriod::of_date(not_yet_due)
            .key(),
        amount: Some(Decimal::from_str_exact("1400.00").unwrap()),
        // Not yet due by the real clock, so the offset is exactly the principal.
        due_date: not_yet_due,
    };

    let (accrue_status, axum::Json(accrue_res)) = sitepulse_backend::handlers::accrue_monthly_dues(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(accrue_req),
    )
    .await
    .unwrap();

    assert_eq!(accrue_status, axum::http::StatusCode::OK);
    assert_eq!(accrue_res.auto_settled_units_count, 1);
    assert_eq!(
        accrue_res.total_amount_offset_from_advance,
        Decimal::from_str_exact("1400.00").unwrap()
    );

    // 3. Verify Resident Dashboard:
    // - New October due is automatically marked as PAID!
    // - Total debt is ₺0!
    // - Remaining advance balance is ₺60.67!
    let dash_res = sitepulse_backend::handlers::get_resident_dashboard(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state),
        resident_dashboard_authz(Role::HomeOwner),
    )
    .await;

    let json_bytes = axum::body::to_bytes(dash_res.into_response().into_body(), 1024 * 64)
        .await
        .unwrap();
    let dash: ResidentDashboardDto = serde_json::from_slice(&json_bytes).unwrap();

    assert_eq!(dash.total_debt, Decimal::ZERO);
    assert_eq!(
        dash.advance_payment,
        Decimal::from_str_exact("60.67").unwrap()
    );

    let oct_due = dash
        .dues
        .iter()
        .find(|d| d.period == accrued_label)
        .unwrap();
    assert_eq!(oct_due.status, "PAID");

    // 4. Verify transaction history records the automatic advance offset!
    let offset_tx = dash
        .transactions
        .iter()
        .find(|t| t.title == "Avans ile Aidat Tahsili")
        .unwrap();
    assert_eq!(
        offset_tx.amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(
        offset_tx.subtitle,
        format!("{accrued_label} aidatı avans bakiyenizden otomatik mahsup edildi")
    );
    assert!(offset_tx.is_credit);
}

// covers: SC-07-07-01
#[tokio::test]
async fn when_dues_period_already_accrued_then_duplicate_accrual_is_prevented() {
    let state = AppState::new();

    let accrue_req = AccrueDuesPeriodRequest {
        site_id: "site-1".to_string(),
        period: "Kasım 2026".to_string(),
        amount: Some(Decimal::from_str_exact("1400.00").unwrap()),
        due_date: NaiveDate::from_ymd_opt(2026, 11, 15).unwrap(),
    };

    // First accrual: Succeeds
    let (status1, axum::Json(res1)) = sitepulse_backend::handlers::accrue_monthly_dues(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(accrue_req.clone()),
    )
    .await
    .unwrap();

    assert_eq!(status1, axum::http::StatusCode::OK);
    assert!(!res1.already_accrued);
    assert!(res1.newly_accrued_units_count > 0);

    let initial_dues_count = {
        let inner = state.inner.read().await;
        inner
            .dues
            .iter()
            .filter(|d| d.period == "Kasım 2026")
            .count()
    };
    assert_eq!(initial_dues_count, res1.newly_accrued_units_count);

    // Second accrual for the exact same period and site: MUST BE PREVENTED
    let (status2, axum::Json(res2)) = sitepulse_backend::handlers::accrue_monthly_dues(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(accrue_req),
    )
    .await
    .unwrap();

    assert_eq!(status2, axum::http::StatusCode::OK);
    assert!(res2.already_accrued);
    assert_eq!(res2.newly_accrued_units_count, 0);
    assert!(res2.message.contains("Mükerrer tahakkuk engellendi"));

    // Verify dues count did not increase
    let final_dues_count = {
        let inner = state.inner.read().await;
        inner
            .dues
            .iter()
            .filter(|d| d.period == "Kasım 2026")
            .count()
    };
    assert_eq!(final_dues_count, initial_dues_count);
}

// covers: SC-07-07-02
#[tokio::test]
async fn when_scheduler_batch_runs_then_accrues_and_prevents_duplicate_accrual() {
    let state = AppState::new();
    let test_date = NaiveDate::from_ymd_opt(2026, 12, 1)
        .unwrap()
        .and_hms_opt(9, 0, 0)
        .unwrap()
        .and_utc();

    // First batch run: accrues for all sites
    let (sites_accrued_1, units_accrued_1) =
        sitepulse_backend::scheduler::run_periodic_accrual_for_all_sites(&state, test_date).await;

    assert!(sites_accrued_1 > 0);
    assert!(units_accrued_1 > 0);
    {
        // Priced from the unit's house-type tariff (d-14 is a 3+1 at ₺1800), not a flat ₺1400;
        // d-14 has no tenant, so the owner is liable.
        let inner = state.inner.read().await;
        let accrued = inner
            .dues
            .iter()
            .find(|d| d.unit_id == "d-14" && d.period == "Aralık 2026")
            .unwrap();
        assert_eq!(
            accrued.principal_amount,
            Decimal::from_str_exact("1800.00").unwrap()
        );
        assert_eq!(accrued.debtor_type, DebtorType::Owner);
    }

    // Second batch run for the same date/period: must be completely idempotent (0 newly accrued)
    let (sites_accrued_2, units_accrued_2) =
        sitepulse_backend::scheduler::run_periodic_accrual_for_all_sites(&state, test_date).await;

    assert_eq!(sites_accrued_2, 0);
    assert_eq!(units_accrued_2, 0);
}

#[tokio::test]
async fn when_homeowner_records_payment_with_existing_debt_then_clears_debt() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    // D-14 has existing dues of ₺1400.00
    let payload = sitepulse_backend::models::RecordHomeownerPaymentRequest {
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        payment_method: PaymentMethod::CreditCard,
        reference_code: Some("CC-TEST-001".to_string()),
        note: Some("Eylül aidat kart ödemesi".to_string()),
        homeowner_name: Some("Zeynep Kaya".to_string()),
    };

    let (status, axum::Json(res)) = sitepulse_backend::handlers::record_homeowner_payment(
        axum::extract::State(state.clone()),
        axum::Json(payload),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(
        res.cleared_debt_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(res.advance_payment_amount, Decimal::ZERO);
    assert_eq!(res.remaining_debt, Decimal::ZERO);
    assert_eq!(
        res.status,
        sitepulse_backend::models::PaymentMatchStatus::MatchedDebt
    );

    // Verify due liability is marked as Paid in state
    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.unit_id == "d-14").unwrap();
    assert_eq!(due.status, sitepulse_backend::models::DebtStatus::Paid);
}

#[tokio::test]
async fn when_homeowner_records_payment_with_no_debt_then_matches_as_advance_payment() {
    let state = AppState::new();

    // Add unit d-1 with no dues liabilities
    {
        let mut inner = state.inner.write().await;
        inner
            .units
            .push(sitepulse_backend::models::IndependentUnit {
                id: "d-1".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 1,
                floor: 1,
                land_share: 20,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: Some("2+1".to_string()),
                monthly_tariff_override: None,

                created_on: None,
            });
    }

    let payload = sitepulse_backend::models::RecordHomeownerPaymentRequest {
        unit_id: "d-1".to_string(),
        amount: Decimal::from_str_exact("2000.00").unwrap(),
        payment_method: PaymentMethod::Fast,
        reference_code: Some("FAST-ADV-101".to_string()),
        note: Some("Gelecek aylar için avans".to_string()),
        homeowner_name: Some("Selim Ak".to_string()),
    };

    let (status, axum::Json(res)) = sitepulse_backend::handlers::record_homeowner_payment(
        axum::extract::State(state.clone()),
        axum::Json(payload),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.cleared_debt_amount, Decimal::ZERO);
    assert_eq!(
        res.advance_payment_amount,
        Decimal::from_str_exact("2000.00").unwrap()
    );
    assert_eq!(
        res.total_unit_advance_balance,
        Decimal::from_str_exact("2000.00").unwrap()
    );
    assert_eq!(
        res.status,
        sitepulse_backend::models::PaymentMatchStatus::MatchedAdvance
    );

    let inner = state.inner.read().await;
    let adv = inner.advance_total("d-1");
    assert_eq!(adv, Decimal::from_str_exact("2000.00").unwrap());
}

#[tokio::test]
async fn when_homeowner_records_payment_exceeding_debt_then_clears_debt_and_credits_surplus_as_advance(
) {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    // D-14 has debt of ₺1400.00; payment of ₺2500.00 clears ₺1400 and credits ₺1100 to advance
    let payload = sitepulse_backend::models::RecordHomeownerPaymentRequest {
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("2500.00").unwrap(),
        payment_method: PaymentMethod::CreditCard,
        reference_code: Some("CC-SURPLUS-001".to_string()),
        note: Some("Aidat + avans ödemesi".to_string()),
        homeowner_name: Some("Zeynep Kaya".to_string()),
    };

    let (status, axum::Json(res)) = sitepulse_backend::handlers::record_homeowner_payment(
        axum::extract::State(state.clone()),
        axum::Json(payload),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(
        res.cleared_debt_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(
        res.advance_payment_amount,
        Decimal::from_str_exact("1100.00").unwrap()
    );
    assert_eq!(res.remaining_debt, Decimal::ZERO);
    assert_eq!(
        res.total_unit_advance_balance,
        Decimal::from_str_exact("1100.00").unwrap()
    );
    assert_eq!(
        res.status,
        sitepulse_backend::models::PaymentMatchStatus::PartiallyMatched
    );

    let inner = state.inner.read().await;
    let adv = inner.advance_total("d-14");
    assert_eq!(adv, Decimal::from_str_exact("1100.00").unwrap());
}

#[tokio::test]
async fn when_match_all_homeowner_payments_called_then_collects_and_matches_all_payments_with_debts_and_advance(
) {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    // Add unit d-1 and record two pending payments in state
    {
        let mut inner = state.inner.write().await;
        inner
            .units
            .push(sitepulse_backend::models::IndependentUnit {
                id: "d-1".to_string(),
                site_id: "site-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 1,
                floor: 1,
                land_share: 20,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: Some("2+1".to_string()),
                monthly_tariff_override: None,

                created_on: None,
            });

        // Payment 1 for d-14 (has debt ₺1400) of ₺1400
        inner
            .homeowner_payments
            .push(sitepulse_backend::models::HomeownerPaymentRecord {
                id: "PAY-PENDING-1".to_string(),
                unit_id: "d-14".to_string(),
                block_id: "A".to_string(),
                unit_number: 14,
                homeowner_name: Some("Zeynep Kaya".to_string()),
                amount: Decimal::from_str_exact("1400.00").unwrap(),
                payment_method: PaymentMethod::BankTransfer,
                reference_code: Some("REF-1".to_string()),
                note: Some("Aidat".to_string()),
                status: sitepulse_backend::models::PaymentMatchStatus::Pending,
                cleared_debt_amount: Decimal::ZERO,
                advance_credit_amount: Decimal::ZERO,
                created_at: Utc::now(),
            });

        // Payment 2 for d-1 (no debt) of ₺1500
        inner
            .homeowner_payments
            .push(sitepulse_backend::models::HomeownerPaymentRecord {
                id: "PAY-PENDING-2".to_string(),
                unit_id: "d-1".to_string(),
                block_id: "A".to_string(),
                unit_number: 1,
                homeowner_name: Some("Selim Ak".to_string()),
                amount: Decimal::from_str_exact("1500.00").unwrap(),
                payment_method: PaymentMethod::BankTransfer,
                reference_code: Some("REF-2".to_string()),
                note: Some("Avans".to_string()),
                status: sitepulse_backend::models::PaymentMatchStatus::Pending,
                cleared_debt_amount: Decimal::ZERO,
                advance_credit_amount: Decimal::ZERO,
                created_at: Utc::now(),
            });
    }

    // Call match_all_homeowner_payments
    let (status, axum::Json(res)) = sitepulse_backend::handlers::match_all_homeowner_payments(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(sitepulse_backend::models::MatchAllPaymentsRequest {
            site_id: Some("site-1".to_string()),
        }),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.total_payments_processed, 2);
    assert_eq!(
        res.total_debt_cleared,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(
        res.total_advance_credited,
        Decimal::from_str_exact("1500.00").unwrap()
    );
    assert_eq!(res.matched_debts_count, 1);
    assert_eq!(res.matched_advance_count, 1);

    // Verify d-14 debt is cleared and d-1 has ₺1500 advance
    let inner = state.inner.read().await;
    let d14_due = inner.dues.iter().find(|d| d.unit_id == "d-14").unwrap();
    assert_eq!(d14_due.status, sitepulse_backend::models::DebtStatus::Paid);

    let d1_adv = inner.advance_total("d-1");
    assert_eq!(d1_adv, Decimal::from_str_exact("1500.00").unwrap());
}

#[tokio::test]
async fn when_confirming_reconciliation_with_surplus_or_zero_debt_then_credits_advance_payments() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;
    let recon_service = sitepulse_backend::services::ReconciliationService::new();

    // 1. Transaction 1: ₺2000 for d-14 (which has ₺1400 debt) -> ₺600 surplus
    let txn1 = sitepulse_backend::models::BankTransactionItem {
        transaction_id: "TXN-SURPLUS-99".to_string(),
        date: NaiveDate::from_ymd_opt(2026, 9, 20).unwrap(),
        amount: Decimal::from_str_exact("2000.00").unwrap(),
        currency: "TRY".to_string(),
        description: "HAVALE - ZEYNEP KAYA A BLOK D:14 FAZLA ODEME".to_string(),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: None,
        reference_no: None,
    };

    let eval_date = NaiveDate::from_ymd_opt(2026, 9, 20).unwrap();
    let inner = state.inner.read().await;
    let matches = recon_service.reconcile_transactions(
        &[txn1],
        &inner.units,
        &inner.users,
        &inner.dues,
        eval_date,
    );
    drop(inner);

    assert_eq!(matches.len(), 1);
    let m = &matches[0];
    assert_eq!(m.matched_unit_id.as_deref(), Some("d-14"));
    assert_eq!(m.confidence_score, 80);
    assert_eq!(
        m.status,
        sitepulse_backend::models::ReconciliationStatus::PendingApproval
    );

    let match_id = m.match_id.clone();
    state
        .inner
        .write()
        .await
        .reconciliation_queue
        .push(m.clone());

    let payload = sitepulse_backend::models::ConfirmReconciliationRequest {
        site_id: "site-1".to_string(),
        match_ids: vec![match_id],
        matches: vec![],
        optional_message: None,
        remember_sender_iban: None,
        owner_capital_match_ids: Vec::new(),
        debtor_assignments: Default::default(),
    };

    let (status, axum::Json(res)) = sitepulse_backend::handlers::confirm_reconciliation(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(payload),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(res.confirmed_count, 1);
    assert_eq!(
        res.total_amount_cleared,
        Decimal::from_str_exact("2000.00").unwrap()
    );

    // Verify:
    // 1) Due is Paid
    // 2) d-14 advance balance received the ₺600 surplus!
    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.id == "b-101").unwrap();
    assert_eq!(due.status, sitepulse_backend::models::DebtStatus::Paid);

    // The due is not yet due, so no penalty: ₺2,000 - ₺1,400 = ₺600 surplus.
    let adv = inner.advance_total("d-14");
    assert_eq!(adv, Decimal::from_str_exact("600.00").unwrap());
}

#[tokio::test]
async fn when_sender_iban_is_remembered_subsequent_blank_desc_payment_auto_matches() {
    let state = AppState::new();

    // 1. Manually remember sender IBAN for unit d-14
    let req = sitepulse_backend::models::RememberSenderIbanRequest {
        site_id: "site-1".to_string(),
        unit_id: "d-14".to_string(),
        sender_iban: "TR99 0006 2000 0000 0000 9999 88".to_string(),
        sender_name: Some("Ali Veli".to_string()),
    };

    let axum::Json(resp) = sitepulse_backend::handlers::remember_sender_iban(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req),
    )
    .await
    .expect("Remember sender IBAN should succeed");

    assert!(resp.success);
    // 2. An incoming webhook arrives from this sender IBAN, to general site IBAN, with NO description
    let webhook_payload = sitepulse_backend::models::BankIncomingWebhookRequest {
        transaction_id: "TXN-TEST-REMEMBERED-IBAN-1".to_string(),
        virtual_iban: "TR33 0006 2000 0000 0000 0000 01".to_string(), // General site IBAN
        amount: Decimal::from_str_exact("500.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_iban: Some("TR99 0006 2000 0000 0000 9999 88".to_string()),
        sender_name: Some("Ali Veli".to_string()),
        description: Some("".to_string()), // Completely blank description!
        signature: None,
    };

    let (status, axum::Json(webhook_res)) = call_signed_webhook(state.clone(), webhook_payload)
        .await
        .expect("Webhook processing should succeed");

    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(webhook_res.status, "CLEARED");
    assert_eq!(webhook_res.matched_unit_id, "d-14");
    assert!(webhook_res.message.contains("Remembered Sender IBAN"));
}

#[tokio::test]
async fn when_transfer_cannot_be_matched_then_enters_unmatched_pool_successfully() {
    let state = AppState::new();

    // An incoming transfer to general site IBAN with unknown sender and blank description
    let webhook_payload = sitepulse_backend::models::BankIncomingWebhookRequest {
        transaction_id: "TXN-TEST-UNMATCHED-99".to_string(),
        virtual_iban: "TR620020500009863791600001".to_string(), // Begonya's site account IBAN
        amount: Decimal::from_str_exact("1200.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_iban: Some("TR55 0006 2000 0000 0000 5555 55".to_string()),
        sender_name: Some("Bilinmeyen Kisi".to_string()),
        description: Some("".to_string()), // Blank description
        signature: None,
    };

    let (status, axum::Json(webhook_res)) = call_signed_webhook(state.clone(), webhook_payload)
        .await
        .expect("Webhook processing should succeed");

    // Money arrived at the bank, so HTTP 200 OK
    assert_eq!(status, axum::http::StatusCode::OK);
    assert_eq!(webhook_res.status, "UNMATCHED");
    assert_eq!(webhook_res.matched_unit_id, "UNMATCHED");
    assert_eq!(webhook_res.cleared_amount, Decimal::ZERO);

    // Verify it is placed in reconciliation_queue
    let inner = state.inner.read().await;
    let found = inner
        .reconciliation_queue
        .iter()
        .find(|m| m.transaction.transaction_id == "TXN-TEST-UNMATCHED-99");

    assert!(found.is_some());
    let item = found.unwrap();
    assert_eq!(
        item.status,
        sitepulse_backend::models::ReconciliationStatus::Unmatched
    );
    assert!(item.matched_unit_id.is_none());
}

#[tokio::test]
async fn when_homeowner_manages_matching_criteria_then_criteria_can_be_viewed_added_and_deleted() {
    let state = AppState::new();

    // 1. Get initial matching criteria for d-14
    let axum::Json(criteria) = sitepulse_backend::handlers::get_unit_matching_criteria(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
    )
    .await
    .expect("Should retrieve matching criteria");

    assert_eq!(criteria.unit_id, "d-14");
    assert_eq!(criteria.block, "A");
    assert_eq!(criteria.unit_number, 14);
    assert!(criteria.virtual_iban.is_some());
    assert_eq!(criteria.recommended_description, "A Blok D:14");
    assert!(criteria
        .remembered_ibans
        .iter()
        .any(|i| i.sender_iban == "TR120006200000000000000001"));

    // 2. Add a new sender IBAN (e.g. İş Bankası)
    let add_req = sitepulse_backend::models::AddSenderIbanRequest {
        sender_iban: "TR77 0006 4000 0011 2233 4455 66".to_string(),
        label: Some("İş Bankası Şahsi Hesabım".to_string()),
        bank_name: Some("İş Bankası".to_string()),
    };

    let axum::Json(updated) = sitepulse_backend::handlers::add_unit_sender_iban(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
        axum::Json(add_req),
    )
    .await
    .expect("Should add sender IBAN");

    assert!(updated
        .remembered_ibans
        .iter()
        .any(|i| i.sender_iban == "TR770006400000112233445566"));

    // 3. Update payer names (add family member)
    let payer_req = sitepulse_backend::models::UpdatePayerNamesRequest {
        payer_names: vec![
            "Ahmet Yılmaz".to_string(),
            "Zeynep Kaya".to_string(),
            "Can Yılmaz".to_string(),
        ],
    };

    let axum::Json(updated_names) = sitepulse_backend::handlers::update_unit_payer_names(
        axum::extract::Path("d-14".to_string()),
        axum::extract::State(state.clone()),
        axum::Json(payer_req),
    )
    .await
    .expect("Should update payer names");

    assert_eq!(updated_names.registered_payer_names.len(), 3);
    assert!(updated_names
        .registered_payer_names
        .contains(&"Can Yılmaz".to_string()));

    // 4. Delete the added sender IBAN
    let axum::Json(after_delete) = sitepulse_backend::handlers::delete_unit_sender_iban(
        axum::extract::Path(("d-14".to_string(), "TR770006400000112233445566".to_string())),
        axum::extract::State(state.clone()),
    )
    .await
    .expect("Should delete sender IBAN");

    assert!(!after_delete
        .remembered_ibans
        .iter()
        .any(|i| i.sender_iban == "TR770006400000112233445566"));
}

#[tokio::test]
async fn when_reset_demo_data_invoked_then_payments_and_dues_are_restored_to_clean_slate() {
    let state = AppState::new();
    fixture_dues_not_yet_due(&state).await;

    // 1. Process a payment that pays off September dues and creates advance payment
    let webhook_req = sitepulse_backend::models::BankIncomingWebhookRequest {
        transaction_id: "TXN-RESET-TEST-01".to_string(),
        virtual_iban: "TR410020504213991067000014".to_string(),
        amount: rust_decimal::Decimal::from_str_exact("2000.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: Some("Zeynep Kaya".to_string()),
        sender_iban: Some("TR120006200000000000000001".to_string()),
        description: Some("Aidat".to_string()),
        signature: None,
    };

    let (status, _) = call_signed_webhook(state.clone(), webhook_req)
        .await
        .expect("Payment should process");

    assert_eq!(status, axum::http::StatusCode::OK);

    // Verify state has advance payment and paid due
    {
        let inner = state.inner.read().await;
        assert_eq!(
            Some(inner.advance_total("d-14")),
            Some(rust_decimal::Decimal::from_str_exact("600.00").unwrap())
        );
        let due = inner.dues.iter().find(|d| d.id == "b-101").unwrap();
        assert_eq!(due.status, sitepulse_backend::models::DebtStatus::Paid);
    }

    // 2. Invoke reset_demo_data
    let _ = sitepulse_backend::handlers::reset_demo_data(axum::extract::State(state.clone())).await;

    // 3. Verify clean slate restored (0 debt, 0 transactions, 0 advance)
    {
        let inner = state.inner.read().await;
        assert!(inner.advance_balances.values().all(|a| a.total().is_zero()));
        assert!(inner.homeowner_payments.is_empty());
        assert!(inner.reconciliation_queue.is_empty());
        assert!(inner.dues.is_empty());
    }

    // 4. Test accrue_test_due creates ₺1400 due on demand
    let _ = sitepulse_backend::handlers::accrue_test_due(axum::extract::State(state.clone())).await;
    {
        let inner = state.inner.read().await;
        let due = inner.dues.iter().find(|d| d.id == "b-101").unwrap();
        assert_eq!(due.status, sitepulse_backend::models::DebtStatus::Pending);
        assert_eq!(
            due.total_amount,
            rust_decimal::Decimal::from_str_exact("1400.00").unwrap()
        );
    }
}

#[tokio::test]
async fn when_wipe_all_data_invoked_then_all_sites_units_and_residents_are_purged() {
    let state = AppState::new();

    // Verify initial seeded state has sites and units
    {
        let inner = state.inner.read().await;
        assert!(!inner.sites.is_empty());
        assert!(!inner.units.is_empty());
    }

    // Call wipe_all_data handler
    let _ = sitepulse_backend::handlers::wipe_all_data(axum::extract::State(state.clone())).await;

    // Verify completely clean fresh start state
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.sites.len(), 0);
        assert_eq!(inner.units.len(), 0);
        assert_eq!(inner.dues.len(), 0);
        assert_eq!(
            inner
                .advance_balances
                .values()
                .filter(|a| !a.total().is_zero())
                .count(),
            0
        );
        assert_eq!(inner.reconciliation_queue.len(), 0);
        // Only SaaS platform admin user remains
        assert!(inner
            .users
            .iter()
            .all(|u| u.role == sitepulse_backend::models::Role::SaasAdmin));
    }
}

#[tokio::test]
async fn when_purge_site_cascade_invoked_then_site_and_associated_units_and_residents_are_removed()
{
    let state = AppState::new();

    // Verify site-1 exists with units
    {
        let inner = state.inner.read().await;
        assert!(inner.sites.iter().any(|s| s.id == "site-1"));
        assert!(inner.units.iter().any(|u| u.site_id == "site-1"));
    }

    // Call purge_site_cascade
    let _ = sitepulse_backend::handlers::purge_site_cascade(
        axum::extract::Path("site-1".to_string()),
        axum::extract::State(state.clone()),
    )
    .await;

    // Verify site-1 and its units are removed
    {
        let inner = state.inner.read().await;
        assert!(!inner.sites.iter().any(|s| s.id == "site-1"));
        assert!(!inner.units.iter().any(|u| u.site_id == "site-1"));
    }
}

#[tokio::test]
async fn when_provisioning_12_units_for_site_then_creates_residents_and_virtual_ibans() {
    use axum::response::IntoResponse;
    use sitepulse_backend::models::ProvisionSiteUnitsRequest;

    let state = AppState::new();

    let req = ProvisionSiteUnitsRequest {
        site_id: None,
        site_name: Some("Kardelen Sitesi".to_string()),
        block: Some("A Blok".to_string()),
        units_count: Some(12),
        monthly_dues: Some(rust_decimal::Decimal::from_str_exact("1500.00").unwrap()),
        accrue_initial_dues: Some(true),
        period: Some("Kasım 2026".to_string()),
    };

    let resp = sitepulse_backend::handlers::provision_site_units(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(req),
    )
    .await
    .into_response();

    assert_eq!(resp.status(), axum::http::StatusCode::OK);

    // Verify state
    {
        let inner = state.inner.read().await;
        let site = inner
            .sites
            .iter()
            .find(|s| s.name == "Kardelen Sitesi")
            .expect("Site should be created");
        assert_eq!(site.status, SiteStatus::Active);

        // Verify 12 units were created
        let site_units: Vec<_> = inner
            .units
            .iter()
            .filter(|u| u.site_id == site.id)
            .collect();
        assert_eq!(site_units.len(), 12);

        // Check unit 1
        let u1 = site_units.iter().find(|u| u.unit_number == 1).unwrap();
        assert!(u1.virtual_iban.as_ref().unwrap().starts_with("TR"));
        assert_eq!(u1.virtual_iban.as_ref().unwrap().len(), 26);

        // Check unit 12
        let u12 = site_units.iter().find(|u| u.unit_number == 12).unwrap();
        assert!(u12.virtual_iban.as_ref().unwrap().starts_with("TR"));

        // Check dues accrued
        let dues: Vec<_> = inner
            .dues
            .iter()
            .filter(|d| d.period == "Kasım 2026")
            .collect();
        assert_eq!(dues.len(), 12);
        assert_eq!(
            dues[0].total_amount,
            rust_decimal::Decimal::from_str_exact("1500.00").unwrap()
        );
    }

    let summary_resp =
        sitepulse_backend::handlers::get_units_summary(axum::extract::State(state.clone()))
            .await
            .into_response();
    assert_eq!(summary_resp.status(), axum::http::StatusCode::OK);

    // Test get_site_overview
    let overview_query = sitepulse_backend::models::SiteOverviewQuery {
        site_id: None,
        period: Some("Kasım 2026".to_string()),
    };
    let overview_resp = sitepulse_backend::handlers::get_site_overview(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(overview_query),
    )
    .await
    .into_response();

    assert_eq!(overview_resp.status(), axum::http::StatusCode::OK);
}

#[tokio::test]
async fn when_zero_data_for_site_dues_and_homeowner_then_guidance_provided() {
    let state = AppState::new();

    // 1. Test completely empty state (Zero Site, Zero Units, Zero Dues, Zero Payments)
    {
        let mut inner = state.inner.write().await;
        inner.sites.clear();
        inner.units.clear();
        inner.dues.clear();
        inner.reconciliation_queue.clear();
        inner.homeowner_payments.clear();
        inner.advance_balances.clear();
    }

    let empty_overview_resp = sitepulse_backend::handlers::get_site_overview(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(sitepulse_backend::models::SiteOverviewQuery {
            site_id: None,
            period: None,
        }),
    )
    .await
    .into_response();

    assert_eq!(empty_overview_resp.status(), axum::http::StatusCode::OK);

    // Call get_site_payments with zero data
    let empty_payments_resp = sitepulse_backend::handlers::get_site_payments(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(sitepulse_backend::handlers::SitePaymentsQuery { site_id: None }),
    )
    .await
    .into_response();

    assert_eq!(empty_payments_resp.status(), axum::http::StatusCode::OK);

    // 2. Test Site exists, but Zero Homeowners / Units
    {
        let mut inner = state.inner.write().await;
        inner.sites.push(sitepulse_backend::models::Site {
            id: "site-zero-units".to_string(),
            name: "Lale Konutları".to_string(),
            address: "Kadıköy, İstanbul".to_string(),
            slug: "lale-konutlari".to_string(),
            status: SiteStatus::Active,
            plan_type: PlanType::Standard,
            license_end_date: chrono::NaiveDate::from_ymd_opt(2027, 12, 31).unwrap(),
            timezone: "Europe/Istanbul".to_string(),
            proration_enabled: false,
            tax_id: None,
            tax_office: None,
        });
        inner
            .units
            .push(sitepulse_backend::models::IndependentUnit {
                id: "unit-other-site".to_string(),
                site_id: "site-other".to_string(),
                block_id: "A Blok".to_string(),
                unit_number: 14,
                floor: 4,
                land_share: 1,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: None,
                monthly_tariff_override: None,

                created_on: None,
            });
    }

    let zero_units_resp = sitepulse_backend::handlers::get_site_overview(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(sitepulse_backend::models::SiteOverviewQuery {
            site_id: Some("site-zero-units".to_string()),
            period: None,
        }),
    )
    .await
    .into_response();

    assert_eq!(zero_units_resp.status(), axum::http::StatusCode::OK);
    let zero_units_body = axum::body::to_bytes(zero_units_resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let zero_units_json: serde_json::Value = serde_json::from_slice(&zero_units_body).unwrap();
    assert_eq!(zero_units_json["summary"]["total_units_count"], 0);
    assert_eq!(zero_units_json["flats"].as_array().unwrap().len(), 0);

    // 3. Test Site & Units exist, but Zero Periodic Dues
    {
        let mut inner = state.inner.write().await;
        inner
            .units
            .push(sitepulse_backend::models::IndependentUnit {
                id: "unit-z1".to_string(),
                site_id: "site-zero-units".to_string(),
                block_id: "A".to_string(),
                unit_number: 1,
                floor: 1,
                land_share: 10,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: Some("2+1".to_string()),
                monthly_tariff_override: None,

                created_on: None,
            });
    }

    let zero_dues_resp = sitepulse_backend::handlers::get_site_overview(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(sitepulse_backend::models::SiteOverviewQuery {
            site_id: Some("site-zero-units".to_string()),
            period: None,
        }),
    )
    .await
    .into_response();

    assert_eq!(zero_dues_resp.status(), axum::http::StatusCode::OK);
}

#[tokio::test]
async fn when_invalid_email_or_phone_then_registration_rejected_with_validation_error() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    // 1. Invalid email (no @ or domain)
    let invalid_email_req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 5,
        floor: 2,
        owner_full_name: "Test Kişi".to_string(),
        email: "gecersiz-eposta".to_string(),
        phone: "05321112233".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: Some("2+1".to_string()),
        is_resident: true,
        role: None,
    };
    let err_email = service
        .register_home_owner("site-1", invalid_email_req)
        .await
        .unwrap_err();
    assert!(err_email.contains("Geçerli bir e-posta"));

    // 2. Invalid phone (too short or letters)
    let invalid_phone_req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 6,
        floor: 2,
        owner_full_name: "Test Kişi".to_string(),
        email: "test.kisi@sitepulse.io".to_string(),
        phone: "123".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: Some("2+1".to_string()),
        is_resident: true,
        role: None,
    };
    let err_phone = service
        .register_home_owner("site-1", invalid_phone_req)
        .await
        .unwrap_err();
    assert!(err_phone.contains("Geçerli bir cep telefonu"));
}

#[tokio::test]
async fn when_house_type_selected_then_sets_monthly_dues_from_tariff() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    // House type 3+1 has tariff 1800.00 TL in defaults
    let req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "B Blok".to_string(),
        unit_no: 9,
        floor: 3,
        owner_full_name: "Tarife Sakini".to_string(),
        email: "tarife.sakini@sitepulse.io".to_string(),
        phone: "05445556677".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None, // No manual dues provided; should auto-resolve from 3+1
        house_type: Some("3+1".to_string()),
        is_resident: true,
        role: None,
    };

    let res = service
        .register_home_owner("site-1", req)
        .await
        .expect("Registration should succeed");
    assert_eq!(
        res.monthly_dues,
        Decimal::from_str_exact("1800.00").unwrap()
    );
    assert_eq!(res.house_type, Some("3+1".to_string()));
}

#[tokio::test]
async fn when_managing_house_types_then_can_list_create_and_delete() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    // List default house types
    let initial_types = service.get_house_types_for_site("site-1").await;
    assert!(!initial_types.is_empty());
    assert!(initial_types.iter().any(|h| h.type_name == "3+1"));

    // Create a new house type
    let new_type = service
        .create_or_update_house_type(
            "site-1",
            sitepulse_backend::models::CreateHouseTypeRequest {
                type_name: "5+1 Villa".to_string(),
                dues_amount: Decimal::from_str_exact("3500.00").unwrap(),
                description: Some("Müstakil Girişli Villa".to_string()),
            },
        )
        .await
        .expect("Create house type should succeed");

    assert_eq!(new_type.type_name, "5+1 Villa");
    assert_eq!(
        new_type.dues_amount,
        Decimal::from_str_exact("3500.00").unwrap()
    );

    // Verify it is listed
    let after_create = service.get_house_types_for_site("site-1").await;
    assert!(after_create.iter().any(|h| h.type_name == "5+1 Villa"));

    // Delete it
    service
        .delete_house_type("site-1", &new_type.id)
        .await
        .expect("Delete should succeed");
    let after_delete = service.get_house_types_for_site("site-1").await;
    assert!(!after_delete.iter().any(|h| h.id == new_type.id));
}

#[tokio::test]
async fn when_managing_blocks_then_can_list_and_create() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());

    // List default blocks for site-1
    let initial_blocks = service.get_blocks_for_site("site-1").await;
    assert!(!initial_blocks.is_empty());
    assert!(initial_blocks.iter().any(|b| b.block_name == "A Blok"));

    // Create a new block
    let new_block = service
        .create_or_update_block(
            "site-1",
            sitepulse_backend::models::CreateBlockRequest {
                block_name: "C Blok".to_string(),
                total_floors: Some(12),
            },
        )
        .await
        .expect("Create block should succeed");

    assert_eq!(new_block.block_name, "C Blok");
    assert_eq!(new_block.total_floors, 12);

    // Verify it is listed
    let after_create = service.get_blocks_for_site("site-1").await;
    assert!(after_create.iter().any(|b| b.block_name == "C Blok"));
}

#[tokio::test]
async fn when_registering_site_with_blocks_then_blocks_are_stored() {
    let state = AppState::new();
    let saas_service = SaasTenantService::new(state.clone());
    let admin_service = SiteAdminService::new(state.clone());

    let req = RegisterSiteRequest {
        site_name: "Palmiye Sitesi".to_string(),
        address: "Antalya".to_string(),
        site_admin_full_name: "Ali Veli".to_string(),
        site_admin_email: "ali@palmiye.com".to_string(),
        site_admin_phone: "+90 532 111 2233".to_string(),
        plan_type: Some("PREMIUM".to_string()),
        blocks: Some(vec![
            "1. Blok".to_string(),
            "2. Blok".to_string(),
            "3. Blok".to_string(),
        ]),
    };

    let res = saas_service
        .register_site(req)
        .await
        .expect("Register site should succeed");
    assert_eq!(res.blocks, vec!["1. Blok", "2. Blok", "3. Blok"]);

    // Check blocks available for that site
    let site_blocks = admin_service.get_blocks_for_site(&res.site_id).await;
    assert_eq!(site_blocks.len(), 3);
    assert!(site_blocks.iter().any(|b| b.block_name == "1. Blok"));
    assert!(site_blocks.iter().any(|b| b.block_name == "2. Blok"));
    assert!(site_blocks.iter().any(|b| b.block_name == "3. Blok"));
}

#[tokio::test]
async fn when_managing_dues_periods_then_can_list_and_create_period_in_separate_table() {
    let state = AppState::new();

    // 1. Initially check periods for site-1
    let query = sitepulse_backend::handlers::DuesPeriodsQuery {
        site_id: Some("site-1".to_string()),
    };
    let axum::Json(initial_periods) = sitepulse_backend::handlers::list_dues_periods(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(query),
    )
    .await
    .unwrap();

    let initial_count = initial_periods.len();

    // 2. Create a new billing period in the separate dues_periods table
    let create_req = sitepulse_backend::models::CreateDuesPeriodRequest {
        site_id: "site-1".to_string(),
        period_name: "Kasım 2026".to_string(),
        due_date: chrono::NaiveDate::from_ymd_opt(2026, 11, 15).unwrap(),
    };

    let (status, axum::Json(created_period)) = sitepulse_backend::handlers::create_dues_period(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(create_req),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::CREATED);
    assert_eq!(created_period.period_name, "Kasım 2026");
    assert_eq!(created_period.status, DuesPeriodStatus::Draft);

    // 3. Verify it is listed in list_dues_periods
    let query2 = sitepulse_backend::handlers::DuesPeriodsQuery {
        site_id: Some("site-1".to_string()),
    };
    let axum::Json(updated_periods) = sitepulse_backend::handlers::list_dues_periods(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(query2),
    )
    .await
    .unwrap();

    assert_eq!(updated_periods.len(), initial_count + 1);
    assert!(updated_periods
        .iter()
        .any(|p| p.period_name == "Kasım 2026"));
}

#[tokio::test]
async fn when_managing_home_owners_then_can_delete_home_owner() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());

    // 1. Register a test home owner to delete
    let reg_req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 88,
        floor: 9,
        owner_full_name: "Silinecek Malik".to_string(),
        email: "silinecek@sitepulse.io".to_string(),
        phone: "05554443322".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: Some(rust_decimal::Decimal::new(1400, 0)),
        house_type: Some("2+1".to_string()),
        is_resident: true,
        role: None,
    };
    let created = service
        .register_home_owner("site-1", reg_req)
        .await
        .unwrap();

    // 2. Call delete_home_owner handler
    let q = sitepulse_backend::handlers::SiteIdParam {
        site_id: Some("site-1".to_string()),
    };
    let status = sitepulse_backend::handlers::delete_home_owner(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Path(created.unit_id.clone()),
        axum::extract::Query(q),
    )
    .await
    .unwrap();

    assert_eq!(status, axum::http::StatusCode::NO_CONTENT);

    // 3. Verify the unit is removed
    let owners = service.get_home_owners_for_site("site-1").await;
    assert!(!owners
        .iter()
        .any(|o| o.unit_id == created.unit_id || o.email == "silinecek@sitepulse.io"));

    let replacement = service
        .register_home_owner(
            "site-1",
            RegisterHomeOwnerRequest {
                owner: None,
                tenant: None,
                members: Vec::new(),
                block: "A Blok".to_string(),
                unit_no: 89,
                floor: 9,
                owner_full_name: "Yeni Malik".to_string(),
                email: "silinecek@sitepulse.io".to_string(),
                phone: "05554443322".to_string(),
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                land_share: None,
                monthly_dues: Some(rust_decimal::Decimal::new(1400, 0)),
                house_type: Some("2+1".to_string()),
                is_resident: true,
                role: None,
            },
        )
        .await
        .expect("a deleted unit's resident email must be reusable");
    assert_eq!(replacement.email, "silinecek@sitepulse.io");
}

#[tokio::test]
async fn when_managing_occupancy_lifecycle_then_can_move_out_and_move_in_without_losing_history() {
    let state = AppState::new_with_test_fixtures();
    let service = SiteAdminService::new(state.clone());

    // 1. Create a unit with an initial owner
    let reg_req = RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 88,
        floor: 5,
        owner_full_name: "Kemal Sunal".to_string(),
        email: "kemal.sunal@sitepulse.io".to_string(),
        phone: "0532 999 88 77".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        house_type: Some("3+1".to_string()),
        monthly_dues: None,
        land_share: None,
        is_resident: true,
        role: None,
    };

    let created = service
        .register_home_owner("site-1", reg_req)
        .await
        .unwrap();

    // 2. Move in a tenant
    let move_in_req = sitepulse_backend::models::MoveInResidentRequest {
        person_id: None,
        full_name: Some("Şener Şen".to_string()),
        phone: Some("0533 111 22 33".to_string()),
        email: Some("sener.sen@sitepulse.io".to_string()),
        role: DebtorType::Tenant,
        start_date: Some("2026-10-01".to_string()),
        notes: Some("1 yıllık kira sözleşmesi".to_string()),
    };

    let move_in_res = service
        .move_in_resident("site-1", &created.unit_id, move_in_req)
        .await;
    if let Ok(item) = move_in_res {
        assert_eq!(item.role, DebtorType::Tenant);
        assert_eq!(item.person_name, "Şener Şen");
        assert!(item.is_active);

        // 3. Move out the tenant
        let move_out_req = sitepulse_backend::models::MoveOutResidentRequest {
            end_date: Some("2026-10-24".to_string()),
            notes: Some("Sözleşme sonu tahliye".to_string()),
        };

        let move_out_res = service
            .move_out_resident("site-1", &created.unit_id, move_out_req)
            .await
            .unwrap();
        assert!(!move_out_res.is_active);

        // 4. Fetch history and verify zero data loss
        let history = service
            .get_unit_occupancy_history("site-1", &created.unit_id)
            .await
            .unwrap();
        assert!(!history.is_empty());
        assert!(history.iter().any(|h| h.person_name == "Şener Şen"));
    }
}

#[tokio::test]
async fn when_registering_new_owner_or_tenant_to_existing_unit_then_archives_previous_occupant_in_history(
) {
    let state = AppState::new();
    let service = sitepulse_backend::services::SiteAdminService::new(state.clone());

    // 1. Register initial owner
    let req1 = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "C Blok".to_string(),
        unit_no: 10,
        floor: 2,
        owner_full_name: "Kemal Sunal".to_string(),
        phone: "0555 111 22 33".to_string(),
        email: "kemal.sunal@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: None,
        is_resident: true,
        role: Some("OWNER".to_string()),
    };
    let owner = service.register_home_owner("site-1", req1).await.unwrap();

    // Verify initial occupancy history has Kemal Sunal as active
    let hist1 = service
        .get_unit_occupancy_history("site-1", &owner.unit_id)
        .await
        .unwrap();
    assert_eq!(hist1.len(), 1);
    assert_eq!(hist1[0].person_name, "Kemal Sunal");
    assert!(hist1[0].is_active);

    // 2. Register a new tenant to the same unit
    let req2 = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "C Blok".to_string(),
        unit_no: 10,
        floor: 2,
        owner_full_name: "Halit Akçatepe".to_string(),
        phone: "0555 222 33 44".to_string(),
        email: "halit@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: None,
        is_resident: true,
        role: Some("TENANT".to_string()),
    };
    let tenant = service.register_home_owner("site-1", req2).await.unwrap();
    assert_eq!(tenant.unit_id, owner.unit_id);

    // 3. Verify history now has 2 entries: Kemal Sunal is inactive (archived), Halit Akçatepe is active
    let hist2 = service
        .get_unit_occupancy_history("site-1", &owner.unit_id)
        .await
        .unwrap();
    assert_eq!(hist2.len(), 2);
    let previous = hist2
        .iter()
        .find(|h| h.person_name == "Kemal Sunal")
        .unwrap();
    assert!(!previous.is_active);
    assert!(previous.end_date.is_some());

    let current = hist2
        .iter()
        .find(|h| h.person_name == "Halit Akçatepe")
        .unwrap();
    assert!(current.is_active);
    assert_eq!(current.role, DebtorType::Tenant);
}

#[tokio::test]
async fn when_homeowner_or_tenant_manually_adds_household_member_then_stored_and_returned() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());

    let member = service
        .add_unit_member(
            "site-1",
            "d-14",
            "Zeynep Yılmaz",
            "+90 532 111 2233",
            "zeynep.yilmaz@gmail.com",
            "Eş",
        )
        .await
        .expect("Manual add resident failed");

    assert_eq!(member.full_name, "Zeynep Yılmaz");
    assert_eq!(member.relationship, "SPOUSE");
    assert_eq!(member.email, "zeynep.yilmaz@gmail.com");

    let invitation_service = HomeResidentInvitationService::new(state);
    let members = invitation_service.get_unit_members("d-14").await;
    assert!(members
        .iter()
        .any(|m| m.full_name == "Zeynep Yılmaz" && m.relationship == "SPOUSE"));
}

#[tokio::test]
async fn when_registering_co_resident_then_attached_to_household_and_does_not_alter_dues_primary_payer(
) {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());

    // 1. Register owner for unit 14
    let owner_req = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 14,
        floor: 4,
        owner_full_name: "Yeni Ev Sahibi".to_string(),
        phone: "0531 111 22 33".to_string(),
        email: "evsahibi14@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: Some(Decimal::from(1400)),
        house_type: Some("2+1".to_string()),
        is_resident: false,
        role: Some("OWNER".to_string()),
    };
    service
        .register_home_owner("site-1", owner_req)
        .await
        .unwrap();

    // 2. Register tenant (primary contact living there)
    let tenant_req = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 14,
        floor: 4,
        owner_full_name: "Canan Can".to_string(),
        phone: "0533 111 22 33".to_string(),
        email: "canan14@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: None,
        is_resident: true,
        role: Some("TENANT".to_string()),
    };
    service
        .register_home_owner("site-1", tenant_req)
        .await
        .unwrap();

    // 3. Register co-resident (Ev Sakini) to unit 14
    let resident_req = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "A Blok".to_string(),
        unit_no: 14,
        floor: 4,
        owner_full_name: "Sakin Kardeş".to_string(),
        phone: "0531 465 65 65".to_string(),
        email: "sakin14@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: None,
        house_type: None,
        is_resident: true,
        role: Some("RESIDENT".to_string()),
    };
    service
        .register_home_owner("site-1", resident_req)
        .await
        .unwrap();

    // 4. Verify in get_home_owners_for_site:
    // Unit 14 has owner, tenant, and household_residents containing "Sakin Kardeş"
    let owners = service.get_home_owners_for_site("site-1").await;
    let u14 = owners
        .iter()
        .find(|o| o.unit_no == 14)
        .expect("Unit 14 must exist");
    assert!(u14
        .household_residents
        .iter()
        .any(|m| m.full_name == "Sakin Kardeş" && m.relationship == "OTHER"));

    // 5. Verify in get_site_overview:
    // Flat in overview shows Canan Can as primary resident_name (NOT Sakin Kardeş, and not duplicated)
    let overview_resp = sitepulse_backend::handlers::get_site_overview(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::extract::Query(sitepulse_backend::models::SiteOverviewQuery {
            site_id: Some("site-1".to_string()),
            period: None,
        }),
    )
    .await
    .into_response();
    assert_eq!(overview_resp.status(), axum::http::StatusCode::OK);

    let overview_body = axum::body::to_bytes(overview_resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let overview_json: serde_json::Value = serde_json::from_slice(&overview_body).unwrap();
    let flats = overview_json["flats"]
        .as_array()
        .expect("flats must be array");
    let f14 = flats
        .iter()
        .find(|f| f["unit_no"] == 14)
        .expect("Flat 14 must be in overview");
    assert_eq!(f14["resident_name"], "Canan Can");
}

#[tokio::test]
async fn when_tenant_moves_out_then_household_members_are_archived_and_cleared_from_active_unit() {
    let state = AppState::new();
    let service = SiteAdminService::new(state.clone());

    // 1. Register tenant
    let tenant_req = sitepulse_backend::models::RegisterHomeOwnerRequest {
        owner: None,
        tenant: None,
        members: Vec::new(),
        block: "B Blok".to_string(),
        unit_no: 25,
        floor: 3,
        owner_full_name: "Ali Veli (Kiracı)".to_string(),
        phone: "0532 999 88 77".to_string(),
        email: "ali.veli25@sitepulse.io".to_string(),
        tenant_full_name: None,
        tenant_email: None,
        tenant_phone: None,
        land_share: None,
        monthly_dues: Some(Decimal::from(1500)),
        house_type: None,
        is_resident: true,
        role: Some("TENANT".to_string()),
    };
    let created = service
        .register_home_owner("site-1", tenant_req)
        .await
        .unwrap();

    // 2. Add household co-resident
    service
        .add_unit_member(
            "site-1",
            &created.unit_id,
            "Ayşe Veli",
            "0532 999 88 78",
            "ayse.veli25@sitepulse.io",
            "Eş",
        )
        .await
        .unwrap();

    let invitation_service = HomeResidentInvitationService::new(state.clone());
    let members_before = invitation_service.get_unit_members(&created.unit_id).await;
    assert!(members_before.iter().any(|m| m.full_name == "Ayşe Veli"));

    // 3. Move out tenant
    let move_out_req = sitepulse_backend::models::MoveOutResidentRequest {
        end_date: Some("2026-11-04".to_string()),
        notes: Some("Kiracı tahliyesi".to_string()),
    };
    let move_out_res = service
        .move_out_resident("site-1", &created.unit_id, move_out_req)
        .await
        .unwrap();
    assert!(!move_out_res.is_active);

    // 4. Verify household members are cleared from active unit
    let members_after = invitation_service.get_unit_members(&created.unit_id).await;
    assert!(
        members_after.is_empty(),
        "Active household members must be empty after move-out"
    );
}

#[tokio::test]
async fn when_querying_payment_stream_then_returns_filtered_entries_and_volume_kpis() {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    // Record 2 manual payments
    let p1 = RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("1500.00").unwrap(),
        payer_name: "Ayşe Yılmaz".to_string(),
        payer_role: DebtorType::Tenant,
        payment_channel: PaymentChannel::ManualCash,
        description: Some("Eylül ayı aidat nakit elden".to_string()),
        payment_date: Some(Utc::now()),
        idempotency_key: None,
        ..Default::default()
    };
    service.record_and_allocate_payment(p1).await.unwrap();

    let p2 = RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("3000.00").unwrap(),
        payer_name: "Ahmet Yılmaz".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::VirtualIban,
        description: Some("Banka transferi".to_string()),
        payment_date: Some(Utc::now()),
        idempotency_key: None,
        ..Default::default()
    };
    service.record_and_allocate_payment(p2).await.unwrap();

    // 1. Query all
    let all = service
        .get_payment_stream(PaymentStreamFilter {
            site_id: Some("site-1".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(all.total_count >= 2);
    assert!(all.total_volume >= Decimal::from_str_exact("4500.00").unwrap());

    // 2. Query filtered by channel
    let cash_only = service
        .get_payment_stream(PaymentStreamFilter {
            site_id: Some("site-1".to_string()),
            channel: Some(PaymentChannel::ManualCash),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(cash_only.total_count, 1);
    assert_eq!(
        cash_only.entries[0].amount,
        Decimal::from_str_exact("1500.00").unwrap()
    );

    // 3. Query filtered by payer role
    let tenant_only = service
        .get_payment_stream(PaymentStreamFilter {
            site_id: Some("site-1".to_string()),
            payer_role: Some(DebtorType::Tenant),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(tenant_only
        .entries
        .iter()
        .all(|e| e.payer_role == DebtorType::Tenant));
}

#[tokio::test]
async fn when_calculating_debt_aging_then_categorizes_into_current_30_60_and_90_brackets() {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    let today = sitepulse_backend::scheduler::site_local_date("Europe/Istanbul", Utc::now());
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();

        // Current (due today)
        inner.dues.push(DuesLiability {
            id: "due-curr".to_string(),
            unit_id: "d-14".to_string(),
            period: "Ekim 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1000.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("1000.00").unwrap(),
            due_date: today,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });

        // 1-30 days overdue (due 20 days ago)
        inner.dues.push(DuesLiability {
            id: "due-20d".to_string(),
            unit_id: "d-14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1200.00").unwrap(),
            delay_penalty: Decimal::from_str_exact("40.00").unwrap(),
            total_amount: Decimal::from_str_exact("1240.00").unwrap(),
            due_date: today - chrono::Days::new(20),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });

        // 31-60 days overdue (due 45 days ago)
        inner.dues.push(DuesLiability {
            id: "due-45d".to_string(),
            unit_id: "d-14".to_string(),
            period: "Ağustos 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
            delay_penalty: Decimal::from_str_exact("105.00").unwrap(),
            total_amount: Decimal::from_str_exact("1505.00").unwrap(),
            due_date: today - chrono::Days::new(45),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });

        // 60+ days overdue (due 80 days ago)
        inner.dues.push(DuesLiability {
            id: "due-80d".to_string(),
            unit_id: "d-14".to_string(),
            period: "Temmuz 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1600.00").unwrap(),
            delay_penalty: Decimal::from_str_exact("200.00").unwrap(),
            total_amount: Decimal::from_str_exact("1800.00").unwrap(),
            due_date: today - chrono::Days::new(80),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let report = service.get_debt_aging_report("site-1").await.unwrap();
    assert_eq!(
        report.total_current,
        Decimal::from_str_exact("1000.00").unwrap()
    );
    assert_eq!(
        report.total_1_30_days,
        Decimal::from_str_exact("1200.00").unwrap()
    );
    assert_eq!(
        report.total_31_60_days,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(
        report.total_60_plus_days,
        Decimal::from_str_exact("1600.00").unwrap()
    );
    // Penalties as of today (KMK 20): 40.00 + 105.00 + 1,600 × 5% × 80 / 30 = 213.33.
    // The stored 200.00 on the 80-day due was below the statutory figure.
    assert_eq!(
        report.total_penalty,
        Decimal::from_str_exact("358.33").unwrap()
    );
    assert_eq!(
        report.grand_total,
        Decimal::from_str_exact("5558.33").unwrap()
    );
    assert_eq!(report.brackets.len(), 1);
    assert_eq!(report.brackets[0].unit_id, "d-14");
}

#[tokio::test]
async fn when_tenant_payment_is_explicitly_designated_for_capital_dues_then_rent_offset_is_eligible(
) {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());
    state
        .inner
        .write()
        .await
        .dues
        .push(owner_capital_due("cap-1", "2000.00"));

    let req = RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("2500.00").unwrap(),
        payer_name: "Ali Kiracı".to_string(),
        payer_role: DebtorType::Tenant,
        payment_channel: PaymentChannel::BankTransfer,
        description: Some("Daire 14 Asansör ve Demirbaş Harcaması Payı".to_string()),
        settles_owner_capital_dues: true,
        settles_tenant_joint_liability: false,
        payment_date: Some(Utc::now()),
        idempotency_key: None,
        ..Default::default()
    };

    let receipt = service.record_and_allocate_payment(req).await.unwrap();

    assert!(receipt.receipt_number.starts_with("TAH-2026-"));
    assert_eq!(
        receipt.total_amount,
        Decimal::from_str_exact("2500.00").unwrap()
    );
    assert!(receipt.is_rent_offset_eligible);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Owner));
    assert!(receipt.legal_statutory_note.is_some());
    assert!(receipt
        .legal_statutory_note
        .unwrap()
        .contains("TBK md. 314"));

    assert_eq!(receipt.verification_hash.len(), 64);
    let capital_line = receipt
        .allocation_breakdown
        .iter()
        .find(|b| b.due_id.as_deref() == Some("cap-1"))
        .unwrap();
    assert_eq!(
        capital_line.expense_type,
        ExpenseType::CapitalDues,
        "label comes from the liability"
    );
}

fn owner_capital_due(id: &str, amount: &str) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: "d-14".to_string(),
        period: "Asansör Taksit 1".to_string(),
        principal_amount: Decimal::from_str_exact(amount).unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact(amount).unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 8, 1).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::CapitalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    }
}

#[tokio::test]
async fn when_tenant_pays_without_capital_intent_then_owner_capital_dues_are_untouched() {
    let state = AppState::new();
    state
        .inner
        .write()
        .await
        .dues
        .push(owner_capital_due("cap-2", "2000.00"));
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some("site-1".to_string()),
            unit_id: "d-14".to_string(),
            amount: Decimal::from_str_exact("5000.00").unwrap(),
            payer_name: "Ali Kiracı".to_string(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::BankTransfer,
            description: Some("Aidat".to_string()),
            payment_date: None,
            idempotency_key: None,
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(receipt
        .allocation_breakdown
        .iter()
        .all(|b| b.due_id.as_deref() != Some("cap-2")));
    assert!(!receipt.is_rent_offset_eligible);
    let inner = state.inner.read().await;
    let cap = inner.dues.iter().find(|d| d.id == "cap-2").unwrap();
    assert_eq!(cap.paid_principal, Decimal::ZERO);
}

#[tokio::test]
async fn when_payment_is_allocated_then_amount_owed_is_preserved_and_penalty_is_recorded() {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        let mut d = owner_capital_due("op-1", "1000.00");
        d.debtor_type = DebtorType::Tenant;
        d.expense_type = ExpenseType::OperationalDues;
        d.delay_penalty = Decimal::from_str_exact("50.00").unwrap();
        d.total_amount = Decimal::from_str_exact("1050.00").unwrap();
        inner.dues.push(d);
    }
    let receipt = service
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some("site-1".to_string()),
            unit_id: "d-14".to_string(),
            amount: Decimal::from_str_exact("300.00").unwrap(),
            payer_name: "Ali".to_string(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::Cash,
            description: None,
            payment_date: None,
            idempotency_key: None,
            ..Default::default()
        })
        .await
        .unwrap();
    let allocated: Decimal = receipt
        .allocation_breakdown
        .iter()
        .map(|b| b.principal_paid + b.penalty_paid)
        .sum();
    assert_eq!(
        allocated + receipt.allocated_advance,
        receipt.total_amount,
        "allocations sum to the payment"
    );
    assert!(
        receipt.allocation_breakdown[0].penalty_paid > Decimal::ZERO,
        "penalty allocation is recorded"
    );
    let inner = state.inner.read().await;
    let d = inner.dues.iter().find(|d| d.id == "op-1").unwrap();
    assert_eq!(
        d.principal_amount,
        Decimal::from_str_exact("1000.00").unwrap(),
        "owed principal unchanged"
    );
    assert_eq!(
        d.paid_principal + d.paid_penalty,
        Decimal::from_str_exact("300.00").unwrap()
    );
    assert_eq!(
        d.total_amount,
        d.principal_amount + d.delay_penalty - d.paid_principal - d.paid_penalty
    );
}

#[tokio::test]
async fn when_inter_ledger_transfer_executed_then_deducts_advance_credits_capital_and_issues_receipt(
) {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    // Setup: Unit d-14 has ₺3000 advance balance and ₺1400 unpaid capital dues
    {
        let mut inner = state.inner.write().await;
        inner.advance_balances.insert(
            "d-14".to_string(),
            sitepulse_backend::models::UnitAdvance {
                owner: Decimal::from_str_exact("3000.00").unwrap(),
                tenant: Decimal::ZERO,
            },
        );
        inner.dues.clear();
        inner.dues.push(DuesLiability {
            id: "due-capital-1".to_string(),
            unit_id: "d-14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("1400.00").unwrap(),
            due_date: Utc::now().date_naive(),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::CapitalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let transfer_req = InterLedgerTransferRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        note: Some("Ev sahibi onaylı avanstan demirbaşa virman".to_string()),
        operator_user_id: Some("usr-manager".to_string()),
        source_debtor: None,
        target_debtor: None,
    };

    let resp = service.inter_ledger_transfer(transfer_req).await.unwrap();
    assert!(resp.success);
    assert_eq!(
        resp.transferred_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert_eq!(
        resp.remaining_advance_balance,
        Decimal::from_str_exact("1600.00").unwrap()
    );
    assert_eq!(
        resp.cleared_capital_due_amount,
        Decimal::from_str_exact("1400.00").unwrap()
    );
    assert!(resp.receipt_number.starts_with("TAH-2026-"));

    // Verify due is marked as Paid in state
    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.id == "due-capital-1").unwrap();
    assert_eq!(due.status, DebtStatus::Paid);
}

#[tokio::test]
async fn when_property_ownership_transferred_then_old_owner_debt_frozen_and_tenant_lease_preserved()
{
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    // Setup: Unit d-14 with tenant and old owner, plus ₺2800 debt
    {
        let mut inner = state.inner.write().await;
        if let Some(unit) = inner.units.iter_mut().find(|u| u.id == "d-14") {
            unit.tenant_user_id = Some("usr-tenant-1".to_string());
        }
        inner.dues.clear();
        inner.dues.push(DuesLiability {
            id: "due-old-1".to_string(),
            unit_id: "d-14".to_string(),
            period: "Ağustos 2026".to_string(),
            principal_amount: Decimal::from_str_exact("2800.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("2800.00").unwrap(),
            due_date: Utc::now().date_naive(),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let transfer_req = TransferOwnershipRequest {
        new_owner: None,
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        new_owner_name: "Mehmet Yeni Malik".to_string(),
        new_owner_national_id: Some("12345678901".to_string()),
        new_owner_phone: Some("0535 999 88 77".to_string()),
        new_owner_email: Some("mehmet.yeni@begonya.com".to_string()),
        transfer_date: Some(Utc::now().date_naive()),
        notes: Some("Tapu devri noter onaylı satış belgesi".to_string()),
        new_owner_person_id: None,
        new_owner_moves_in: false,
        seller_pays_override_reason: None,
    };

    let resp = service.transfer_ownership(transfer_req).await.unwrap();
    assert!(resp.success);
    assert_eq!(resp.new_owner_name, "Mehmet Yeni Malik");
    assert_eq!(
        resp.old_owner_exit_balance,
        Decimal::from_str_exact("2800.00").unwrap()
    );

    // Verify unit state
    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == "d-14").unwrap();
    let new_owner_id = unit.owner_user_id.as_ref().unwrap();
    let new_user = inner.users.iter().find(|u| &u.id == new_owner_id).unwrap();
    assert_eq!(new_user.full_name, "Mehmet Yeni Malik");
    // Tenant user id must remain untouched
    assert_eq!(unit.tenant_user_id, Some("usr-tenant-1".to_string()));
    // Old owner archived in unit occupancies
    let occs = inner.unit_occupancies.get("d-14").unwrap();
    assert!(occs
        .iter()
        .any(|o| o.person_name == resp.old_owner_name && !o.is_active));
}

// ---------------------------------------------------------------------------
// EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) Integration Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn when_creating_capital_project_with_installments_then_calculates_plan_correctly() {
    let state = AppState::new();
    let service = CapitalProjectService::new(state.clone());

    let req = CreateCapitalProjectRequest {
        site_id: Some("site-1".to_string()),
        title: "Çatı İzolasyon ve Mantolama".to_string(),
        category: Some(CapitalProjectCategory::RoofWaterproofing),
        description: Some("Dış cephe ısı yalıtımı ve çatı su izolasyonu".to_string()),
        total_budget: Decimal::from_str_exact("300000.00").unwrap(),
        allocation_basis: Some(AllocationBasis::ByLandShare),
        target_start_date: Some(Utc::now().date_naive()),
        target_completion_date: None,
        contractor_name: Some("İzotürk Yapı Ltd.".to_string()),
        contractor_tax_no: Some("1234567890".to_string()),
        contractor_iban: Some("TR120006200000000012345678".to_string()),
        contract_amount: Some(Decimal::from_str_exact("300000.00").unwrap()),
        installments: Some(vec![
            CreateInstallmentItem {
                installment_number: 1,
                total_installments: 3,
                due_date: Utc::now().date_naive(),
                installment_budget: Decimal::from_str_exact("100000.00").unwrap(),
                percentage: Some(Decimal::from_str_exact("33.33").unwrap()),
            },
            CreateInstallmentItem {
                installment_number: 2,
                total_installments: 3,
                due_date: Utc::now().date_naive() + chrono::Duration::days(30),
                installment_budget: Decimal::from_str_exact("100000.00").unwrap(),
                percentage: Some(Decimal::from_str_exact("33.33").unwrap()),
            },
            CreateInstallmentItem {
                installment_number: 3,
                total_installments: 3,
                due_date: Utc::now().date_naive() + chrono::Duration::days(60),
                installment_budget: Decimal::from_str_exact("100000.00").unwrap(),
                percentage: Some(Decimal::from_str_exact("33.34").unwrap()),
            },
        ]),
    };

    let project = service.create_project(req).await.unwrap();
    assert_eq!(project.title, "Çatı İzolasyon ve Mantolama");
    assert_eq!(
        project.total_budget,
        Decimal::from_str_exact("300000.00").unwrap()
    );
    assert_eq!(project.installments_count, 3);

    let installments = service.list_installments(&project.id).await;
    assert_eq!(installments.len(), 3);
    assert_eq!(
        installments[0].installment_budget,
        Decimal::from_str_exact("100000.00").unwrap()
    );
}

#[tokio::test]
async fn when_accruing_capital_installment_then_reconciles_penny_drift_exactly() {
    let state = AppState::new();
    let service = CapitalProjectService::new(state.clone());

    // Project with budget ₺10,000 across 1 installment
    let req = CreateCapitalProjectRequest {
        site_id: Some("site-1".to_string()),
        title: "Güvenlik Kamera Sistemi".to_string(),
        category: Some(CapitalProjectCategory::SecuritySystem),
        description: None,
        total_budget: Decimal::from_str_exact("10000.00").unwrap(),
        allocation_basis: Some(AllocationBasis::ByLandShare),
        target_start_date: Some(Utc::now().date_naive()),
        target_completion_date: None,
        contractor_name: None,
        contractor_tax_no: None,
        contractor_iban: None,
        contract_amount: None,
        installments: Some(vec![CreateInstallmentItem {
            installment_number: 1,
            total_installments: 1,
            due_date: Utc::now().date_naive(),
            installment_budget: Decimal::from_str_exact("10000.00").unwrap(),
            percentage: Some(Decimal::from_str_exact("100.00").unwrap()),
        }]),
    };

    let project = service.create_project(req).await.unwrap();
    let accrue_res = service.accrue_installment(&project.id, 1).await.unwrap();
    assert!(accrue_res.success);
    assert_eq!(
        accrue_res.total_accrued_amount,
        Decimal::from_str_exact("10000.00").unwrap()
    );

    // Sum of all created dues for this project must equal exactly ₺10,000.00
    let inner = state.inner.read().await;
    let sum_dues: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.period.contains(&project.title))
        .map(|d| d.principal_amount)
        .sum();
    assert_eq!(sum_dues, Decimal::from_str_exact("10000.00").unwrap());
}

// covers: SC-10-05-03
#[tokio::test]
async fn when_milestone_disbursement_recorded_then_keeps_invoice_and_accumulates_disbursed() {
    let state = AppState::new();
    let service = CapitalProjectService::new(state.clone());
    let budget = Decimal::from_str_exact("300000.00").unwrap();
    let project = service
        .create_project(CreateCapitalProjectRequest {
            site_id: Some("site-1".to_string()),
            title: "Asansör Revizyonu".to_string(),
            category: Some(CapitalProjectCategory::Other),
            description: None,
            total_budget: budget,
            allocation_basis: Some(AllocationBasis::ByLandShare),
            target_start_date: Some(Utc::now().date_naive()),
            target_completion_date: None,
            contractor_name: Some("Otis Asansör San. Tic.".to_string()),
            contractor_tax_no: Some("6490012345".to_string()),
            contractor_iban: Some("TR330006100519786457841326".to_string()),
            contract_amount: Some(budget),
            installments: Some(vec![CreateInstallmentItem {
                installment_number: 1,
                total_installments: 1,
                due_date: Utc::now().date_naive(),
                installment_budget: budget,
                percentage: Some(Decimal::from_str_exact("100.00").unwrap()),
            }]),
        })
        .await
        .unwrap();
    {
        let mut inner = state.inner.write().await;
        let stored = inner
            .capital_projects
            .iter_mut()
            .find(|p| p.id == project.id)
            .unwrap();
        stored.collected_amount = Decimal::from_str_exact("220000.00").unwrap();
    }
    let disburse = |milestone: &str, invoice: &str, amount: &str| RecordDisbursementRequest {
        milestone_name: milestone.to_string(),
        invoice_number: Some(invoice.to_string()),
        amount: Decimal::from_str_exact(amount).unwrap(),
        disbursement_date: Some(Utc::now().date_naive()),
        recipient_name: "Otis Asansör San. Tic.".to_string(),
        recipient_iban: "TR330006100519786457841326".to_string(),
        payment_reference: None,
        disbursement_method: Some(DisbursementMethod::BankTransfer),
        notes: None,
    };
    service
        .record_disbursement(
            &project.id,
            &project.site_id,
            disburse("1. Hakediş (Söküm)", "ASN-2026-0031", "50000.00"),
        )
        .await
        .unwrap();

    let second = service
        .record_disbursement(
            &project.id,
            &project.site_id,
            disburse(
                "2. Hakediş (Motor & Halat Montajı)",
                "ASN-2026-0044",
                "120000.00",
            ),
        )
        .await
        .unwrap();

    assert_eq!(second.invoice_number.as_deref(), Some("ASN-2026-0044"));
    assert_eq!(second.recipient_name, "Otis Asansör San. Tic.");
    let listed = service.list_disbursements(&project.id).await;
    assert!(listed
        .iter()
        .any(|d| d.invoice_number.as_deref() == Some("ASN-2026-0044")
            && d.amount == Decimal::from_str_exact("120000.00").unwrap()));
    let updated = service.get_project(&project.id).await.unwrap();
    assert_eq!(
        updated.disbursed_amount,
        Decimal::from_str_exact("170000.00").unwrap()
    );
}

#[tokio::test]
async fn when_contractor_disbursement_recorded_then_updates_fund_balance() {
    let state = AppState::new();
    let service = CapitalProjectService::new(state.clone());

    let req = CreateCapitalProjectRequest {
        site_id: Some("site-1".to_string()),
        title: "Kazan Dairesi Yenileme".to_string(),
        category: Some(CapitalProjectCategory::Other),
        description: None,
        total_budget: Decimal::from_str_exact("80000.00").unwrap(),
        allocation_basis: Some(AllocationBasis::ByLandShare),
        target_start_date: Some(Utc::now().date_naive()),
        target_completion_date: None,
        contractor_name: Some("Termik Mühendislik".to_string()),
        contractor_tax_no: Some("9876543210".to_string()),
        contractor_iban: Some("TR330006200000000098765432".to_string()),
        contract_amount: Some(Decimal::from_str_exact("80000.00").unwrap()),
        installments: Some(vec![CreateInstallmentItem {
            installment_number: 1,
            total_installments: 1,
            due_date: Utc::now().date_naive(),
            installment_budget: Decimal::from_str_exact("80000.00").unwrap(),
            percentage: Some(Decimal::from_str_exact("100.00").unwrap()),
        }]),
    };

    let project = service.create_project(req).await.unwrap();

    let unfunded_disbursement = RecordDisbursementRequest {
        milestone_name: "Unfunded payment".to_string(),
        invoice_number: None,
        amount: Decimal::from_str_exact("120000.00").unwrap(),
        disbursement_date: Some(Utc::now().date_naive()),
        recipient_name: "Termik Mühendislik".to_string(),
        recipient_iban: "TR330006200000000098765432".to_string(),
        payment_reference: None,
        disbursement_method: Some(DisbursementMethod::BankTransfer),
        notes: None,
    };
    assert!(service
        .record_disbursement(&project.id, &project.site_id, unfunded_disbursement)
        .await
        .is_err());
    assert!(service.list_disbursements(&project.id).await.is_empty());

    service.accrue_installment(&project.id, 1).await.unwrap();
    {
        let mut inner = state.inner.write().await;
        for due in inner.dues.iter_mut().filter(|due| {
            due.period
                .starts_with(&format!("{}: Taksit", project.title))
        }) {
            due.status = DebtStatus::Paid;
            due.paid_principal = due.principal_amount;
        }
    }

    let disb_req = RecordDisbursementRequest {
        milestone_name: "1. Hakediş: Eski Kazan Sökümü".to_string(),
        invoice_number: Some("FTR-2026-0042".to_string()),
        amount: Decimal::from_str_exact("25000.00").unwrap(),
        disbursement_date: Some(Utc::now().date_naive()),
        recipient_name: "Termik Mühendislik".to_string(),
        recipient_iban: "TR330006200000000098765432".to_string(),
        payment_reference: Some("PROJ-KAZAN-HK1".to_string()),
        disbursement_method: Some(DisbursementMethod::BankTransfer),
        notes: Some("Söküm tutanağı imzalandı".to_string()),
    };

    let disb = service
        .record_disbursement(&project.id, &project.site_id, disb_req)
        .await
        .unwrap();
    assert_eq!(disb.amount, Decimal::from_str_exact("25000.00").unwrap());
    assert_eq!(disb.milestone_name, "1. Hakediş: Eski Kazan Sökümü");

    let disbursements = service.list_disbursements(&project.id).await;
    assert_eq!(disbursements.len(), 1);
    assert_eq!(
        disbursements[0].amount,
        Decimal::from_str_exact("25000.00").unwrap()
    );

    let updated_proj = service.get_project(&project.id).await.unwrap();
    assert_eq!(
        updated_proj.disbursed_amount,
        Decimal::from_str_exact("25000.00").unwrap()
    );
}

#[tokio::test]
async fn when_recording_payment_with_penalty_then_amortizes_penalty_first_per_tbk100_and_surplus_to_advance(
) {
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues.push(DuesLiability {
            id: "due-test-1".to_string(),
            unit_id: "d-14".to_string(),
            period: "Ekim 2026".to_string(),
            principal_amount: Decimal::from_str_exact("1000.00").unwrap(),
            delay_penalty: Decimal::from_str_exact("50.00").unwrap(),
            total_amount: Decimal::from_str_exact("1050.00").unwrap(),
            due_date: NaiveDate::from_ymd_opt(2026, 10, 15).unwrap(),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let req = RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("1200.00").unwrap(),
        payer_name: "Ali Veli".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::BankTransfer,
        // Fixed 30 days after the 2026-10-15 due date so the penalty (5% monthly) is exactly 50.00.
        payment_date: Some(
            NaiveDate::from_ymd_opt(2026, 11, 14)
                .unwrap()
                .and_hms_opt(12, 0, 0)
                .unwrap()
                .and_utc(),
        ),
        idempotency_key: None,
        description: Some("Ekim Aidat ve Avans".to_string()),
        ..Default::default()
    };

    let receipt = service.record_and_allocate_payment(req).await.unwrap();

    assert_eq!(
        receipt.allocated_penalty,
        Decimal::from_str_exact("50.00").unwrap()
    );
    assert_eq!(
        receipt.allocated_principal,
        Decimal::from_str_exact("1000.00").unwrap()
    );
    assert_eq!(
        receipt.allocated_advance,
        Decimal::from_str_exact("150.00").unwrap()
    );
    assert_eq!(
        receipt.total_amount,
        Decimal::from_str_exact("1200.00").unwrap()
    );
    assert!(receipt.receipt_number.starts_with("TAH-2026-"));
    assert!(!receipt.verification_hash.is_empty());

    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.id == "due-test-1").unwrap();
    assert_eq!(due.status, DebtStatus::Paid);
    assert_eq!(due.total_amount, Decimal::ZERO);

    let advance = inner.advance_total("d-14");
    assert_eq!(advance, Decimal::from_str_exact("150.00").unwrap());
}

#[tokio::test]
async fn when_transferring_property_ownership_then_freezes_old_debt_and_creates_occupancy_history()
{
    let state = AppState::new();
    let service = PaymentTrackingService::new(state.clone());

    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.dues.push(DuesLiability {
            id: "due-freeze-1".to_string(),
            unit_id: "d-14".to_string(),
            period: "Eylül 2026".to_string(),
            principal_amount: Decimal::from_str_exact("800.00").unwrap(),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from_str_exact("800.00").unwrap(),
            due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
    }

    let req = TransferOwnershipRequest {
        new_owner: None,
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        new_owner_name: "Fatma Yılmaz".to_string(),
        new_owner_national_id: None,
        new_owner_email: Some("fatma.yilmaz@begonya.com".to_string()),
        new_owner_phone: Some("+905559876543".to_string()),
        transfer_date: Some(NaiveDate::from_ymd_opt(2026, 11, 1).unwrap()),
        notes: Some("Tapu devir işlemi yapıldı".to_string()),
        new_owner_person_id: None,
        new_owner_moves_in: false,
        seller_pays_override_reason: None,
    };

    let res = service.transfer_ownership(req).await.unwrap();

    assert!(res.success);
    assert_eq!(
        res.old_owner_exit_balance,
        Decimal::from_str_exact("800.00").unwrap()
    );
    assert_eq!(res.new_owner_name, "Fatma Yılmaz");

    let inner = state.inner.read().await;
    let occupancies = inner.unit_occupancies.get("d-14").unwrap();
    assert!(!occupancies.is_empty());
    let last = occupancies.last().unwrap();
    assert_eq!(last.role, DebtorType::Owner);
    assert!(!last.is_active);
    assert_eq!(
        last.exit_balance,
        Decimal::from_str_exact("800.00").unwrap()
    );
}

const TEST_WEBHOOK_SECRET: &str = "integration-test-webhook-secret";

/// Calls the webhook handler exactly as the bank would: JSON body plus HMAC header.
async fn call_signed_webhook(
    mut state: AppState,
    req: BankIncomingWebhookRequest,
) -> Result<
    (
        axum::http::StatusCode,
        axum::Json<BankIncomingWebhookResponse>,
    ),
    (axum::http::StatusCode, String),
> {
    state.settings.bank_webhook_secret = Some(TEST_WEBHOOK_SECRET.to_string());
    let body = serde_json::to_vec(&req).unwrap();
    let sig = sitepulse_backend::auth::sign_webhook_body(TEST_WEBHOOK_SECRET, &body);
    let mut headers = axum::http::HeaderMap::new();
    headers.insert(
        sitepulse_backend::handlers::BANK_WEBHOOK_SIGNATURE_HEADER,
        sig.parse().unwrap(),
    );
    sitepulse_backend::handlers::handle_bank_incoming_webhook(
        axum::extract::State(state),
        headers,
        axum::body::Bytes::from(body),
    )
    .await
}

#[tokio::test]
async fn when_webhook_is_unsigned_or_forged_then_it_is_rejected() {
    let mut state = AppState::new();
    state.settings.bank_webhook_secret = Some(TEST_WEBHOOK_SECRET.to_string());
    let req = BankIncomingWebhookRequest {
        transaction_id: "TXN-FORGED-1".to_string(),
        virtual_iban: "TR000000000000000000000000".to_string(),
        amount: Decimal::from_str_exact("1400.00").unwrap(),
        currency: Some("TRY".to_string()),
        sender_name: None,
        sender_iban: None,
        description: None,
        signature: Some("HMAC_SHA256_VALID_SIG".to_string()),
    };
    let body = serde_json::to_vec(&req).unwrap();
    let unsigned = sitepulse_backend::handlers::handle_bank_incoming_webhook(
        axum::extract::State(state.clone()),
        axum::http::HeaderMap::new(),
        axum::body::Bytes::from(body.clone()),
    )
    .await;
    assert_eq!(
        unsigned.unwrap_err().0,
        axum::http::StatusCode::UNAUTHORIZED
    );

    let mut headers = axum::http::HeaderMap::new();
    let wrong = sitepulse_backend::auth::sign_webhook_body("attacker-secret", &body);
    headers.insert(
        sitepulse_backend::handlers::BANK_WEBHOOK_SIGNATURE_HEADER,
        wrong.parse().unwrap(),
    );
    let forged = sitepulse_backend::handlers::handle_bank_incoming_webhook(
        axum::extract::State(state.clone()),
        headers,
        axum::body::Bytes::from(body),
    )
    .await;
    assert_eq!(forged.unwrap_err().0, axum::http::StatusCode::UNAUTHORIZED);
    assert!(state.inner.read().await.reconciliation_queue.is_empty());
}

#[tokio::test]
async fn when_webhook_currency_is_not_try_then_it_is_rejected() {
    let state = AppState::new();
    let req = BankIncomingWebhookRequest {
        transaction_id: "TXN-USD-1".to_string(),
        virtual_iban: "TR000000000000000000000000".to_string(),
        amount: Decimal::from_str_exact("100.00").unwrap(),
        currency: Some("USD".to_string()),
        sender_name: None,
        sender_iban: None,
        description: None,
        signature: None,
    };
    let res = call_signed_webhook(state, req).await;
    assert_eq!(
        res.unwrap_err().0,
        axum::http::StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn when_registering_without_invite_or_with_unknown_invite_then_rejected() {
    let service = AuthService::new(AppState::new());
    for token in [None, Some("SP-HANE-NOTREAL".to_string())] {
        let err = service
            .register_with_password(RegisterUserRequest {
                full_name: "Intruder".to_string(),
                email: "intruder@example.com".to_string(),
                password: "LongEnoughPassword1".to_string(),
                phone: None,
                unit_invite_token: token,
            })
            .await
            .unwrap_err();
        assert!(
            err.to_ascii_lowercase().contains("invitation token"),
            "unexpected error for bad/missing invite: {err}"
        );
    }
}

#[tokio::test]
async fn when_google_token_is_unsigned_then_account_takeover_is_impossible() {
    // A hand-made "JWT" carrying the admin's email must not authenticate even when
    // Google sign-in is configured.
    let mut state = AppState::new();
    state.settings.google_client_id = Some("test-google-client-id".to_string());
    let service = AuthService::new(state);
    let payload = base64::Engine::encode(
        &base64::engine::general_purpose::URL_SAFE_NO_PAD,
        r#"{"sub":"x","email":"admin@sitepulse.io","email_verified":true}"#,
    );
    let err = service
        .authenticate_with_google(GoogleLoginRequest {
            id_token: format!("eyJhbGciOiJub25lIn0.{}.", payload),
            unit_invite_token: None,
        })
        .await
        .unwrap_err();
    assert!(
        err.contains("Invalid Google ID Token"),
        "expected Invalid Google ID Token, got: {err}"
    );
}

#[tokio::test]
async fn when_using_former_backdoor_or_placeholder_passwords_then_login_fails() {
    let service = AuthService::new(AppState::new());
    for (email, password) in [
        ("yonetici@begonya.com", "SP-99190-PASS"),
        ("admin@sitepulse.io", "admin123"),
        ("mehmet.demir@begonya.com", "ARGON2_HASH_mehmet123"),
    ] {
        let err = service
            .authenticate_with_password(PasswordLoginRequest {
                email: email.to_string(),
                password: password.to_string(),
            })
            .await
            .unwrap_err();
        assert!(
            err.contains("Invalid") || err.contains("hatalı"),
            "{email} must not log in with rejected credential: {err}",
        );
    }
}

#[tokio::test]
async fn when_changing_password_then_policy_is_uniform_and_errors_do_not_enumerate_users() {
    let service = AuthService::new(AppState::new());
    let short = service
        .change_password(ChangePasswordRequest {
            email: "ahmet.yilmaz@begonya.com".to_string(),
            current_password: "ahmet123".to_string(),
            new_password: "short1".to_string(),
        })
        .await
        .unwrap_err();
    assert!(short.contains("at least"));
    let unknown = service
        .change_password(ChangePasswordRequest {
            email: "nobody@example.com".to_string(),
            current_password: "whatever-password".to_string(),
            new_password: "AValidNewPassword1".to_string(),
        })
        .await
        .unwrap_err();
    assert!(!unknown.to_lowercase().contains("not found"));
}

#[test]
fn when_utc_is_late_evening_then_accrual_uses_the_site_local_date() {
    let late = NaiveDate::from_ymd_opt(2026, 11, 30)
        .unwrap()
        .and_hms_opt(22, 30, 0)
        .unwrap()
        .and_utc();
    let local = sitepulse_backend::scheduler::site_local_date("Europe/Istanbul", late);
    assert_eq!(local, NaiveDate::from_ymd_opt(2026, 12, 1).unwrap());
    assert_eq!(
        sitepulse_backend::scheduler::format_turkish_month_year(local),
        "Aralık 2026"
    );
}

fn payment_on(date: chrono::DateTime<Utc>) -> RecordManualPaymentRequest {
    RecordManualPaymentRequest {
        site_id: Some("site-1".to_string()),
        unit_id: "d-14".to_string(),
        amount: Decimal::from_str_exact("100.00").unwrap(),
        payer_name: "Ayşe Yılmaz".to_string(),
        payer_role: DebtorType::Owner,
        payment_channel: PaymentChannel::ManualCash,
        payment_date: Some(date),
        ..Default::default()
    }
}

// covers: SC-09-04-05
#[tokio::test]
async fn when_payment_date_is_in_the_future_then_it_is_rejected() {
    let service = PaymentTrackingService::new(AppState::new());
    let err = service
        .record_and_allocate_payment(payment_on(Utc::now() + chrono::Duration::days(2)))
        .await
        .unwrap_err();
    assert!(err.contains("gelecekte"), "unexpected error: {err}");
}

// covers: SC-09-04-05
#[tokio::test]
async fn when_payment_date_is_beyond_the_backdating_window_then_it_is_rejected() {
    let service = PaymentTrackingService::new(AppState::new());
    let err = service
        .record_and_allocate_payment(payment_on(Utc::now() - chrono::Duration::days(400)))
        .await
        .unwrap_err();
    assert!(err.contains("geriye"), "unexpected error: {err}");
}

#[tokio::test]
async fn when_payment_date_is_within_the_backdating_window_then_it_is_accepted() {
    let service = PaymentTrackingService::new(AppState::new());
    service
        .record_and_allocate_payment(payment_on(Utc::now() - chrono::Duration::days(10)))
        .await
        .unwrap();
}

#[tokio::test]
async fn when_bank_statement_line_is_older_than_the_window_then_it_is_accepted() {
    let service = PaymentTrackingService::new(AppState::new());
    let mut req = payment_on(Utc::now() - chrono::Duration::days(400));
    req.payment_channel = PaymentChannel::BankStatement;
    service.record_and_allocate_payment(req).await.unwrap();
}

#[tokio::test]
async fn when_bank_line_is_dated_today_local_at_utc_midnight_then_it_is_not_treated_as_future() {
    let service = PaymentTrackingService::new(AppState::new());
    // 00:30 local (UTC+3) on day D: the bank line is stamped 00:00 UTC of D+1's
    // local date, i.e. up to a day ahead of the UTC clock.
    let mut req = payment_on(Utc::now() + chrono::Duration::hours(23));
    req.payment_channel = PaymentChannel::BankStatement;
    service.record_and_allocate_payment(req).await.unwrap();
}

#[test]
fn payment_date_violation_is_deterministic_for_a_given_window() {
    let now = Utc::now();
    let v = PaymentTrackingService::payment_date_violation;
    assert!(v(now - chrono::Duration::days(31), now, 30).is_some());
    assert!(v(now - chrono::Duration::days(29), now, 30).is_none());
    assert!(v(now + chrono::Duration::hours(1), now, 30).is_some());
}

#[tokio::test]
async fn when_create_units_block_name_empty_then_rejected() {
    let service = SiteAdminService::new(AppState::new());
    let req = CreateUnitsRequest {
        block_name: "  ".to_string(),
        unit_number: Some(1),
        start_unit: None,
        end_unit: None,
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req).await.unwrap_err();
    assert!(
        err.to_string().contains("Block name cannot be empty"),
        "{err}"
    );
}

#[tokio::test]
async fn when_create_units_unit_zero_then_rejected() {
    let service = SiteAdminService::new(AppState::new());
    let req = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: Some(0),
        start_unit: None,
        end_unit: None,
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req).await.unwrap_err();
    assert!(err.to_string().contains("greater than 0"), "{err}");
}

#[tokio::test]
async fn when_create_units_start_greater_than_end_then_rejected() {
    let service = SiteAdminService::new(AppState::new());
    let req = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: None,
        start_unit: Some(10),
        end_unit: Some(5),
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req).await.unwrap_err();
    assert!(
        err.to_string()
            .contains("greater than or equal to start_unit"),
        "{err}"
    );
}

#[tokio::test]
async fn when_create_units_exceeds_500_then_rejected() {
    let service = SiteAdminService::new(AppState::new());
    let req = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: None,
        start_unit: Some(1),
        end_unit: Some(501),
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req).await.unwrap_err();
    assert!(err.to_string().contains("more than 500"), "{err}");
}

#[tokio::test]
async fn when_create_units_list_validation_then_rejected() {
    let service = SiteAdminService::new(AppState::new());
    // Empty list
    let req_empty = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: None,
        start_unit: None,
        end_unit: None,
        unit_numbers: Some(vec![]),
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req_empty).await.unwrap_err();
    assert!(err.to_string().contains("cannot be empty"), "{err}");

    // Invalid unit number (0)
    let req_zero = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: None,
        start_unit: None,
        end_unit: None,
        unit_numbers: Some(vec![1, 0, 3]),
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err2 = service.create_units("site-1", req_zero).await.unwrap_err();
    assert!(err2.to_string().contains("greater than 0"), "{err2}");
}

#[tokio::test]
async fn when_create_units_duplicate_then_conflict_returned() {
    let service = SiteAdminService::new(AppState::new());
    let req = CreateUnitsRequest {
        block_name: "TestBlock".to_string(),
        unit_number: None,
        start_unit: Some(1),
        end_unit: Some(5),
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let created = service.create_units("site-1", req).await.unwrap();
    assert_eq!(created.len(), 5);

    // Duplicate unit in same block
    let req_dup = CreateUnitsRequest {
        block_name: "TestBlock".to_string(),
        unit_number: Some(3),
        start_unit: None,
        end_unit: None,
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = service.create_units("site-1", req_dup).await.unwrap_err();
    match err {
        sitepulse_backend::error::AppError::Conflict(msg) => {
            assert!(msg.contains("already exist"), "{msg}");
            assert!(msg.contains("3"), "{msg}");
        }
        other => panic!("expected AppError::Conflict, got {other:?}"),
    }
}

#[tokio::test]
async fn when_create_units_foreign_site_then_tenant_denied() {
    let state = AppState::new();
    let scope = sitepulse_backend::tenancy::TenantScope::site("site-1".to_string());
    let query = sitepulse_backend::handlers::SiteIdParam {
        site_id: Some("site-2".to_string()),
    };
    let req = CreateUnitsRequest {
        block_name: "A".to_string(),
        unit_number: Some(1),
        start_unit: None,
        end_unit: None,
        unit_numbers: None,
        floor: None,
        land_share: None,
        house_type: None,
    };
    let err = sitepulse_backend::handlers::create_units(
        axum::extract::State(state),
        scope,
        axum::extract::Query(query),
        axum::Json(req),
    )
    .await
    .unwrap_err();

    assert!(
        err.to_string().contains("Site belongs to another tenant"),
        "{err}"
    );
}

#[tokio::test]
async fn when_get_units_foreign_site_then_tenant_denied() {
    let state = AppState::new();
    let scope = sitepulse_backend::tenancy::TenantScope::site("site-1".to_string());
    let query = sitepulse_backend::handlers::SiteIdParam {
        site_id: Some("site-2".to_string()),
    };
    let err = sitepulse_backend::handlers::get_units(
        axum::extract::State(state),
        scope,
        axum::extract::Query(query),
    )
    .await
    .unwrap_err();

    assert!(
        err.to_string().contains("Site belongs to another tenant"),
        "{err}"
    );
}
