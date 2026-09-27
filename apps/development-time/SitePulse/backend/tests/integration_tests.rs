use chrono::NaiveDate;
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

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
    };

    let evaluation_date = NaiveDate::from_ymd_opt(2026, 9, 25).unwrap();
    let result = service.calculate_delay_penalty(base_dues, evaluation_date);

    assert_eq!(result.status, DebtStatus::Overdue);
    assert_eq!(result.delay_penalty, Decimal::from_str_exact("23.33").unwrap());
    assert_eq!(result.total_amount, Decimal::from_str_exact("1423.33").unwrap());
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
    };

    let evaluation_date = NaiveDate::from_ymd_opt(2026, 9, 10).unwrap();
    let result = service.calculate_delay_penalty(base_dues, evaluation_date);

    assert_eq!(result.status, DebtStatus::Pending);
    assert_eq!(result.delay_penalty, Decimal::ZERO);
    assert_eq!(result.total_amount, Decimal::from_str_exact("1400.00").unwrap());
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
    };

    let res = service.register_site(req).await.expect("Site registration failed");
    assert_eq!(res.site_name, "Yıldız Park Evleri");
    assert_eq!(res.slug, "yildiz-park-evleri");
    assert_eq!(res.admin_email, "kemal.sunal@yildizpark.com");
    assert!(res.temporary_password.starts_with("SP-"));
    assert!(res.must_change_password);
}

#[tokio::test]
async fn when_duplicate_email_then_throws_exception() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    let req = RegisterSiteRequest {
        site_name: "Deneme Sitesi".to_string(),
        address: "Ataşehir".to_string(),
        site_admin_full_name: "Mehmet Demir".to_string(),
        site_admin_email: "mehmet.demir@begonya.com".to_string(), // duplicate seed email
        site_admin_phone: "+90 532 000 0000".to_string(),
        plan_type: None,
    };

    let res = service.register_site(req).await;
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert!(err.contains("already exists") || err.contains("zaten mevcut"));
}

#[tokio::test]
async fn when_registering_home_owner_then_provisions_user_with_resident_password() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    let req = RegisterHomeOwnerRequest {
        block: "A Blok".to_string(),
        unit_no: 22,
        floor: 6,
        owner_full_name: "Canan Dağ".to_string(),
        email: "canan.dag@begonya.com".to_string(),
        phone: "+90 532 444 5566".to_string(),
        land_share: Some("1/24".to_string()),
        monthly_dues: Some(Decimal::from_str_exact("1400.00").unwrap()),
        is_resident: true,
    };

    let res = service.register_home_owner("site-1", req).await.expect("Registration failed");
    assert_eq!(res.owner_full_name, "Canan Dağ");
    assert!(res.temporary_password.unwrap().starts_with("SP-SAKIN-"));
    assert!(res.must_change_password);
}

#[tokio::test]
async fn when_duplicate_email_for_home_owner_then_throws_exception() {
    let state = AppState::new();
    let service = SiteAdminService::new(state);

    let req = RegisterHomeOwnerRequest {
        block: "A Blok".to_string(),
        unit_no: 14,
        floor: 4,
        owner_full_name: "Ahmet Yılmaz".to_string(),
        email: "ahmet.yilmaz@begonya.com".to_string(), // duplicate seed
        phone: "+90 532 111 22 33".to_string(),
        land_share: None,
        monthly_dues: None,
        is_resident: true,
    };

    let res = service.register_home_owner("site-1", req).await;
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert!(err.contains("already exists") || err.contains("zaten mevcut"));
}

#[tokio::test]
async fn when_generating_invite_link_then_returns_valid_url_and_token() {
    let state = AppState::new();
    let service = RegistrationApprovalService::new(state);

    let res = service.generate_invitation_link("site-1").await;
    assert!(res.token.starts_with("SP-INV-"));
    assert!(res.join_url.contains("https://sitepulse.app/join/begonya-sitesi?token="));
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

    let res = service.submit_self_registration("begonya-sitesi", req).await.expect("Submit failed");
    assert_eq!(res.status, "PENDING");
    assert_eq!(res.full_name, "Murat Güven");
}

#[tokio::test]
async fn when_approving_pending_registration_then_provisions_user_and_returns_credentials() {
    let state = AppState::new();
    let service = RegistrationApprovalService::new(state);

    let res = service.approve_registration("req-seed-01").await.expect("Approval failed");
    assert_eq!(res.status, "APPROVED");
    assert!(res.temporary_password.starts_with("SP-SAKIN-"));
    assert_eq!(res.email, "kerem.yilmaz@gmail.com");
}

#[tokio::test]
async fn when_generating_unit_invite_link_then_returns_unit_scoped_url_and_token() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state);

    let res = service.generate_unit_invite_link("d-14", Some("Aile Bireyi".to_string())).await;
    assert!(res.token.starts_with("SP-HANE-"));
    assert!(res.invite_url.contains("units/d-14?token="));
    assert!(res.security_notice.contains("A Blok D:14 yetkisi tanımlar"));
}

#[tokio::test]
async fn when_registering_home_resident_then_assigns_home_resident_role_and_unit_scope() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state);

    let invite = service.generate_unit_invite_link("d-14", Some("Kardeş".to_string())).await;

    let req = RegisterHomeResidentRequest {
        token: invite.token,
        full_name: "Selin Yılmaz".to_string(),
        email: "selin.yilmaz@gmail.com".to_string(),
        phone: Some("+90 535 888 9900".to_string()),
        relationship: Some("Kardeş".to_string()),
    };

    let res = service.register_home_resident(req).await.expect("Registration failed");
    assert_eq!(res.role, "HOME_RESIDENT");
    assert!(res.permission_scope.contains("UNIT_ONLY (d-14)"));
    assert!(res.temporary_password.starts_with("SP-HANE-"));
}

#[tokio::test]
async fn when_duplicate_email_for_home_resident_then_throws_exception() {
    let state = AppState::new();
    let service = HomeResidentInvitationService::new(state);

    let invite = service.generate_unit_invite_link("d-14", None).await;

    let req = RegisterHomeResidentRequest {
        token: invite.token,
        full_name: "Ahmet Yılmaz".to_string(),
        email: "ahmet.yilmaz@begonya.com".to_string(), // duplicate seed
        phone: None,
        relationship: None,
    };

    let res = service.register_home_resident(req).await;
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert!(err.contains("already exists") || err.contains("zaten mevcut"));
}

#[tokio::test]
async fn when_valid_password_registration_then_can_authenticate() {
    let state = AppState::new();
    let service = AuthService::new(state);

    let reg_req = RegisterUserRequest {
        full_name: "Emre Aydın".to_string(),
        email: "emre.aydin@gmail.com".to_string(),
        password: "SuperSecretPassword123".to_string(),
        phone: Some("+90 532 999 8877".to_string()),
        unit_invite_token: None,
    };

    let reg_res = service.register_with_password(reg_req).await.expect("Register failed");
    assert_eq!(reg_res.user.full_name, "Emre Aydın");

    let login_req = PasswordLoginRequest {
        email: "emre.aydin@gmail.com".to_string(),
        password: "SuperSecretPassword123".to_string(),
    };

    let login_res = service.authenticate_with_password(login_req).await.expect("Login failed");
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

    let res = service.authenticate_with_password(login_req).await;
    assert!(res.is_err());
    let err = res.unwrap_err();
    assert!(err.contains("Invalid") || err.contains("hatalı"));
}

#[tokio::test]
async fn when_valid_google_id_token_then_authenticates_and_links_account() {
    let state = AppState::new();
    let service = AuthService::new(state);

    let req = GoogleLoginRequest {
        id_token: "mock-google-token:sub-998877:google.ahmet@gmail.com:Ahmet Yılmaz Google".to_string(),
        unit_invite_token: None,
    };

    let res = service.authenticate_with_google(req).await.expect("Google auth failed");
    assert_eq!(res.user.email, "google.ahmet@gmail.com");
    assert_eq!(res.user.auth_provider, "GOOGLE");
}

#[test]
fn when_resident_role_then_has_unit_restricted_permissions() {
    let permissions = Permission::permissions_for_role(Role::HomeResident);
    assert!(permissions.contains(&Permission::UnitRead));
    assert!(permissions.contains(&Permission::UnitPay));
    assert!(!permissions.contains(&Permission::SiteManage));
    assert!(!permissions.contains(&Permission::LedgerManageAll));
    assert!(!permissions.contains(&Permission::TenantManage));
}

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
    };

    let reg_res = service.register_site(reg_req).await.expect("Site registration failed");
    let site_id = reg_res.site_id;

    // Delete the action-free site
    let del_res = service.delete_site(&site_id).await;
    assert!(del_res.is_ok());

    // Verify it is no longer in the site list
    let all_sites = service.get_all_sites().await;
    assert!(!all_sites.iter().any(|s| s.site_id == site_id));
}

#[tokio::test]
async fn when_deleting_site_with_active_units_or_actions_then_strictly_rejected() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    // "site-1" (Begonya Sitesi) has active units (d-14), dues (b-101), and pending registrations
    let del_res = service.delete_site("site-1").await;
    assert!(del_res.is_err());
    let err_msg = del_res.unwrap_err();
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

#[tokio::test]
async fn when_resetting_admin_password_for_non_existent_site_then_fails() {
    let state = AppState::new();
    let service = SaasTenantService::new(state);

    let reset_res = service.reset_site_admin_password("invalid-site-id").await;
    assert!(reset_res.is_err());
}

