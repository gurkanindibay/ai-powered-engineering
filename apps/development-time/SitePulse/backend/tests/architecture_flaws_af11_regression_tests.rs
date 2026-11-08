//! Regression tests for the second backend architecture audit (AF-11 .. AF-20).
//! See `docs/BACKEND_ARCHITECTURE_FLAWS_REPORT.md`, section "Second Audit".

use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::{
    app::build_router,
    auth,
    handlers,
    models::{
        AccrueDuesPeriodRequest, BankIncomingWebhookRequest, DebtStatus, DuesLiability, IndependentUnit,
        Role, SiteBankAccount,
    },
    services::CapitalProjectService,
    state::AppState,
};
use tower::ServiceExt;

const WEBHOOK_SECRET: &str = "af11-regression-webhook-secret-0123456789";
const SITE2_BANK_IBAN: &str = "TR550020500009863791600002";

/// Demo fixtures plus the capital project `cproj-1` and its `d-14` dues. Seeded
/// explicitly: the implicit seeding in `state.rs` keys off the test binary name.
async fn fixture_state() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.accrue_test_due();
        if !inner.dues.iter().any(|d| d.unit_id == "d-14") {
            inner.dues.push(DuesLiability {
                id: "af-d14-op".to_string(),
                unit_id: "d-14".to_string(),
                period: "Eylül 2026".to_string(),
                principal_amount: Decimal::from_str_exact("1400.00").unwrap(),
                delay_penalty: Decimal::ZERO,
                total_amount: Decimal::from_str_exact("1400.00").unwrap(),
                due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                debtor_type: "OWNER".to_string(),
                expense_type: "OPERATIONAL_DUES".to_string(),
            });
        }
    }
    state
}

/// A unit of a second tenant whose block/flat number collides with site-1's `d-14`.
fn site2_unit() -> IndependentUnit {
    IndependentUnit {
        id: "unit-9001".to_string(),
        site_id: "site-2".to_string(),
        block_id: "A".to_string(),
        unit_number: 14,
        floor: 4,
        land_share: 1000,
        owner_user_id: None,
        tenant_user_id: None,
        virtual_iban: None,
        house_type: None,
    }
}

async fn state_with_second_tenant() -> AppState {
    let state = fixture_state().await;
    {
        let mut inner = state.inner.write().await;
        inner.units.push(site2_unit());
        inner.site_bank_accounts.push(SiteBankAccount {
            id: "sba-site-2".to_string(),
            site_id: "site-2".to_string(),
            bank_code: "KUVEYT_TURK".to_string(),
            bank_name: "Kuveyt Türk".to_string(),
            iban: SITE2_BANK_IBAN.to_string(),
            account_holder: "Site 2 Yönetimi".to_string(),
            statement_format: "EXCEL".to_string(),
            is_active: true,
            configured_by: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        });
    }
    state
}

async fn send(state: &AppState, method: &str, uri: &str, token: &str, body: Option<serde_json::Value>) -> StatusCode {
    let mut builder = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {}", token));
    let body = match body {
        Some(v) => {
            builder = builder.header("content-type", "application/json");
            Body::from(serde_json::to_vec(&v).unwrap())
        }
        None => Body::empty(),
    };
    build_router(state.clone()).oneshot(builder.body(body).unwrap()).await.unwrap().status()
}

async fn signed_webhook(
    state: &AppState,
    req: BankIncomingWebhookRequest,
) -> Result<(StatusCode, axum::Json<sitepulse_backend::models::BankIncomingWebhookResponse>), (StatusCode, String)> {
    std::env::set_var("SITEPULSE_BANK_WEBHOOK_SECRET", WEBHOOK_SECRET);
    let body = serde_json::to_vec(&req).unwrap();
    let sig = auth::sign_webhook_body(WEBHOOK_SECRET, &body);
    let mut headers = axum::http::HeaderMap::new();
    headers.insert(handlers::BANK_WEBHOOK_SIGNATURE_HEADER, sig.parse().unwrap());
    handlers::handle_bank_incoming_webhook(axum::extract::State(state.clone()), headers, axum::body::Bytes::from(body)).await
}

// ---------------------------------------------------------------------------
// AF-11: capital project object-level authorization
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af11_foreign_manager_cannot_read_or_accrue_another_sites_capital_project() {
    let state = state_with_second_tenant().await;
    let dues_before = state.inner.read().await.dues.len();
    let foreign = auth::issue_token("mgr-2", "mgr2@site2.io", Role::SiteManager, "site-2", None);

    for uri in [
        "/api/v1/capital-projects/cproj-1",
        "/api/v1/capital-projects/cproj-1/installments",
        "/api/v1/capital-projects/cproj-1/disbursements",
        "/api/v1/capital-projects/cproj-1/unit-shares",
    ] {
        assert_eq!(send(&state, "GET", uri, &foreign, None).await, StatusCode::NOT_FOUND, "{}", uri);
    }
    let accrue = send(
        &state,
        "POST",
        "/api/v1/capital-projects/cproj-1/accrue-installment",
        &foreign,
        Some(serde_json::json!({ "installment_number": 2 })),
    )
    .await;
    assert_eq!(accrue, StatusCode::NOT_FOUND);
    let disburse = send(
        &state,
        "POST",
        "/api/v1/capital-projects/cproj-1/disbursements",
        &foreign,
        Some(serde_json::json!({
            "milestone_name": "x", "amount": "10.00", "recipient_name": "x", "recipient_iban": "TR00"
        })),
    )
    .await;
    assert_eq!(disburse, StatusCode::NOT_FOUND);
    assert_eq!(state.inner.read().await.dues.len(), dues_before, "no liability may be created cross-tenant");

    let own = auth::issue_token("mgr-1", "mgr1@site1.io", Role::SiteManager, "site-1", None);
    assert_eq!(send(&state, "GET", "/api/v1/capital-projects/cproj-1", &own, None).await, StatusCode::OK);
}

// ---------------------------------------------------------------------------
// AF-12: capital allocation stays inside the project's site
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af12_installment_accrual_and_unit_shares_cover_only_the_projects_site() {
    let state = state_with_second_tenant().await;
    let service = CapitalProjectService::new(state.clone());

    let res = service.accrue_installment("cproj-1", 2).await.unwrap();
    assert_eq!(res.total_accrued_amount, Decimal::from_str_exact("120000.00").unwrap());

    let inner = state.inner.read().await;
    assert!(
        !inner.dues.iter().any(|d| d.unit_id == "unit-9001"),
        "site-2 unit must not be charged for site-1's project"
    );
    let site1_units: Vec<String> = inner.units.iter().filter(|u| u.site_id == "site-1").map(|u| u.id.clone()).collect();
    let charged: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.expense_type == "CAPITAL_DUES" && d.period.contains("Taksit 2/3"))
        .inspect(|d| assert!(site1_units.contains(&d.unit_id)))
        .map(|d| d.principal_amount)
        .sum();
    assert_eq!(charged, Decimal::from_str_exact("120000.00").unwrap(), "zero-cent drift within the site");
    drop(inner);

    let shares = service.get_unit_capital_shares("cproj-1").await.unwrap();
    assert!(!shares.is_empty());
    assert!(shares.iter().all(|s| s.unit_id != "unit-9001"));
    assert!(
        shares.iter().all(|s| s.owner_phone.as_deref() != Some("+90 532 111 22 33") || s.owner_name != "Kat Maliki"),
        "no fabricated contact data for unknown owners"
    );
}

// ---------------------------------------------------------------------------
// AF-13: capital installment accrual is idempotent under concurrency
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af13_concurrent_installment_accruals_charge_exactly_once() {
    let state = fixture_state().await;
    let a = CapitalProjectService::new(state.clone());
    let b = CapitalProjectService::new(state.clone());
    let (ra, rb) = tokio::join!(a.accrue_installment("cproj-1", 3), b.accrue_installment("cproj-1", 3));
    assert_eq!(ra.is_ok() as u8 + rb.is_ok() as u8, 1, "exactly one accrual may succeed: {:?} / {:?}", ra, rb);

    let inner = state.inner.read().await;
    let total: Decimal = inner
        .dues
        .iter()
        .filter(|d| d.period.contains("Taksit 3/3"))
        .map(|d| d.principal_amount)
        .sum();
    assert_eq!(total, Decimal::from_str_exact("120000.00").unwrap());
}

// ---------------------------------------------------------------------------
// AF-14 / AF-15: manual accrual is site-scoped and follows the scheduler's rules
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af14_af15_manual_accrual_is_site_scoped_owner_liable_and_never_invents_a_tariff() {
    let state = state_with_second_tenant().await;
    {
        let mut inner = state.inner.write().await;
        // site-1 unit, owner-occupied, no house-type tariff
        inner.units.push(IndependentUnit {
            id: "unit-af15".to_string(),
            site_id: "site-1".to_string(),
            block_id: "C".to_string(),
            unit_number: 77,
            floor: 7,
            land_share: 10,
            owner_user_id: None,
            tenant_user_id: None,
            virtual_iban: None,
            house_type: None,
        });
    }

    let req = AccrueDuesPeriodRequest {
        site_id: "site-1".to_string(),
        period: "Aralık 2026".to_string(),
        amount: Decimal::from_str_exact("1000.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 12, 15).unwrap(),
    };
    let _ = handlers::accrue_monthly_dues(axum::extract::State(state.clone()), axum::Json(req)).await.unwrap();
    {
        let inner = state.inner.read().await;
        assert!(!inner.dues.iter().any(|d| d.unit_id == "unit-9001"), "site-2 must not be accrued");
        let due = inner.dues.iter().find(|d| d.unit_id == "unit-af15" && d.period == "Aralık 2026").unwrap();
        assert_eq!(due.debtor_type, "OWNER", "owner-occupied unit: the owner is liable (EPIC-08)");
        assert_eq!(due.expense_type, "OPERATIONAL_DUES");
    }

    // No explicit amount and no tariff: the unit is skipped, no 1400 TL is invented.
    let req = AccrueDuesPeriodRequest {
        site_id: "site-1".to_string(),
        period: "Ocak 2027".to_string(),
        amount: Decimal::ZERO,
        due_date: NaiveDate::from_ymd_opt(2027, 1, 15).unwrap(),
    };
    let _ = handlers::accrue_monthly_dues(axum::extract::State(state.clone()), axum::Json(req)).await.unwrap();
    let inner = state.inner.read().await;
    assert!(!inner.dues.iter().any(|d| d.unit_id == "unit-af15" && d.period == "Ocak 2027"));
}

#[tokio::test]
async fn af14_repeated_manual_accrual_creates_no_duplicates() {
    let state = fixture_state().await;
    let req = || AccrueDuesPeriodRequest {
        site_id: "site-1".to_string(),
        period: "Şubat 2027".to_string(),
        amount: Decimal::from_str_exact("900.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2027, 2, 15).unwrap(),
    };
    let _ = handlers::accrue_monthly_dues(axum::extract::State(state.clone()), axum::Json(req())).await.unwrap();
    let count = state.inner.read().await.dues.iter().filter(|d| d.period == "Şubat 2027").count();
    let (_, axum::Json(second)) =
        handlers::accrue_monthly_dues(axum::extract::State(state.clone()), axum::Json(req())).await.unwrap();
    assert!(second.already_accrued);
    assert_eq!(state.inner.read().await.dues.iter().filter(|d| d.period == "Şubat 2027").count(), count);
}

// ---------------------------------------------------------------------------
// AF-16: webhook fallback matching is confined to the receiving site
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af16_narrative_match_never_credits_a_unit_of_another_site() {
    let state = state_with_second_tenant().await;
    let advance_before = state.inner.read().await.advance_payments.get("d-14").copied();

    // Transfer to site-2's account, narrative names "A Blok Daire 14" (exists in both sites).
    let (status, axum::Json(res)) = signed_webhook(
        &state,
        BankIncomingWebhookRequest {
            transaction_id: "TXN-AF16-1".to_string(),
            virtual_iban: SITE2_BANK_IBAN.to_string(),
            amount: Decimal::from_str_exact("500.00").unwrap(),
            currency: Some("TRY".to_string()),
            sender_name: Some("Bilinmeyen".to_string()),
            sender_iban: None,
            description: Some("A Blok Daire 14 aidat".to_string()),
            signature: None,
        },
    )
    .await
    .unwrap();
    assert_eq!(status, StatusCode::OK);
    assert_ne!(res.matched_unit_id, "d-14", "site-1's unit must not receive site-2's money");

    let inner = state.inner.read().await;
    assert_eq!(inner.advance_payments.get("d-14").copied(), advance_before);
    let queued = inner.reconciliation_queue.iter().find(|m| m.transaction.transaction_id == "TXN-AF16-1").unwrap();
    assert_eq!(queued.site_id, "site-2");
}

#[tokio::test]
async fn af16_unknown_receiving_account_is_unmatched_and_not_assigned_to_a_default_site() {
    let state = fixture_state().await;
    let (_, axum::Json(res)) = signed_webhook(
        &state,
        BankIncomingWebhookRequest {
            transaction_id: "TXN-AF16-2".to_string(),
            virtual_iban: "TR990000000000000000000099".to_string(),
            amount: Decimal::from_str_exact("500.00").unwrap(),
            currency: Some("TRY".to_string()),
            sender_name: Some("Ahmet Yılmaz".to_string()),
            sender_iban: None,
            description: Some("A Blok Daire 14".to_string()),
            signature: None,
        },
    )
    .await
    .unwrap();
    assert_eq!(res.status, "UNMATCHED");
    let inner = state.inner.read().await;
    let queued = inner.reconciliation_queue.iter().find(|m| m.transaction.transaction_id == "TXN-AF16-2").unwrap();
    assert_eq!(queued.site_id, "", "no invented tenant: visible to SaaS admins only");
}

// ---------------------------------------------------------------------------
// AF-18: advance auto-offset never settles CAPITAL_DUES
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af18_auto_offset_settles_operational_dues_only() {
    let state = fixture_state().await;
    let mut inner = state.inner.write().await;
    inner.dues.retain(|d| d.unit_id != "d-14");
    inner.dues.push(DuesLiability {
        id: "cap-af18".to_string(),
        unit_id: "d-14".to_string(),
        period: "Asansör: Taksit 1/1".to_string(),
        principal_amount: Decimal::from_str_exact("700.00").unwrap(),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::from_str_exact("700.00").unwrap(),
        due_date: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: "OWNER".to_string(),
        expense_type: "CAPITAL_DUES".to_string(),
    });
    inner.advance_payments.insert("d-14".to_string(), Decimal::from_str_exact("5000.00").unwrap());

    let (settled, _) = handlers::apply_advance_payments_offset(&mut inner, Some("d-14"));
    assert_eq!(settled, 0);
    let cap = inner.dues.iter().find(|d| d.id == "cap-af18").unwrap();
    assert_ne!(cap.status, DebtStatus::Paid);
    assert_eq!(inner.advance_payments["d-14"], Decimal::from_str_exact("5000.00").unwrap());
}

// ---------------------------------------------------------------------------
// AF-19: deleting a home owner dissociates; memory mirrors the database
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af19_delete_home_owner_keeps_unit_and_financial_history_in_memory() {
    let state = fixture_state().await;
    let dues_before = state.inner.read().await.dues.iter().filter(|d| d.unit_id == "d-14").count();
    assert!(dues_before > 0);

    let status = handlers::delete_home_owner(
        axum::extract::State(state.clone()),
        axum::extract::Path("d-14".to_string()),
        axum::extract::Query(handlers::SiteIdParam { site_id: Some("site-1".to_string()) }),
    )
    .await
    .unwrap();
    assert_eq!(status, StatusCode::NO_CONTENT);

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == "d-14").expect("the physical unit must survive");
    assert!(unit.owner_user_id.is_none());
    assert_eq!(inner.dues.iter().filter(|d| d.unit_id == "d-14").count(), dues_before, "dues history kept");
}

// ---------------------------------------------------------------------------
// AF-20: no default tenant
// ---------------------------------------------------------------------------

#[tokio::test]
async fn af20_dues_periods_require_an_explicit_site() {
    let state = fixture_state().await;
    let res = handlers::list_dues_periods(
        axum::extract::State(state),
        axum::extract::Query(handlers::DuesPeriodsQuery { site_id: None }),
    )
    .await;
    assert_eq!(res.unwrap_err().0, StatusCode::BAD_REQUEST);
}
