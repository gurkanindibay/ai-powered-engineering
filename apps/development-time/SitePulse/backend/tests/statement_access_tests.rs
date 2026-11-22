//! HTTP acceptance tests for the resident statement route (Issue #295, SPEC-007 R2).
//!
//! The statement is a historical record, so a former owner or tenant whose only
//! remaining tie to the unit is an unpaid charge keeps read access to it, and the
//! response carries only their own section. Every other unit route keeps the
//! current-relationship rule.

mod support;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use chrono::{Days, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::{app::build_router, models::*, state::AppState};
use tower::ServiceExt;

const SITE: &str = "site-1";
const UNIT: &str = "d-14";

fn d(value: &str) -> Decimal {
    Decimal::from_str_exact(value).expect("decimal literal")
}

fn person(id: &str, person_id: i64, name: &str, role: Role) -> User {
    User {
        id: id.to_string(),
        site_id: SITE.to_string(),
        full_name: name.to_string(),
        email: format!("{id}@sitepulse.local"),
        phone: "05550000000".to_string(),
        password_hash: None,
        role,
        must_change_password: false,
        auth_provider: AuthProvider::Local,
        google_sub: None,
        avatar_url: None,
        created_at: Utc::now(),
        person_id: Some(person_id),
    }
}

fn due(
    due_id: &str,
    liable_person_id: i64,
    debtor_type: DebtorType,
    period: &str,
    today: chrono::NaiveDate,
) -> DuesLiability {
    DuesLiability {
        id: due_id.to_string(),
        unit_id: UNIT.to_string(),
        period: period.to_string(),
        principal_amount: d("1016.13"),
        delay_penalty: Decimal::ZERO,
        total_amount: d("1016.13"),
        due_date: today - Days::new(30),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: Some(today),
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: Some(liable_person_id),
    }
}

/// An approved correction on `due_id`, attributed to whoever that liability
/// names as liable.
fn correction(
    id: i64,
    due_id: &str,
    debtor_type: DebtorType,
    period: &str,
    reason: &str,
) -> sitepulse_backend::models::AccrualCorrection {
    sitepulse_backend::models::AccrualCorrection {
        id,
        site_id: SITE.to_string(),
        unit_id: UNIT.to_string(),
        due_id: due_id.to_string(),
        period: period.to_string(),
        debtor_type: debtor_type.as_str().to_string(),
        kind: sitepulse_backend::models::CORRECTION_CANCEL.to_string(),
        amount: d("900.00"),
        new_due_date: None,
        new_debtor_type: None,
        reason: reason.to_string(),
        requested_by: "usr-site-manager-1".to_string(),
        requested_at: Utc::now(),
        status: sitepulse_backend::models::REQUEST_APPROVED.to_string(),
        decided_by: Some("usr-site-manager-2".to_string()),
        decided_at: Some(Utc::now()),
        decision_note: None,
        principal_before: Some(d("900.00")),
        penalty_before: None,
        paid_before: None,
        penalty_reversed: None,
        advance_credited: None,
        replacement_due_id: None,
        replacement_shares: Vec::new(),
        replacement_due_ids: Vec::new(),
    }
}

/// Unit A-14 after Dan Yılmaz moved out: the unit is vacant, Ben Kaya owns it,
/// and Dan still owes his October tenant share.
async fn state_after_move_out() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .dues
            .retain(|due| !sitepulse_backend::auth::same_id(&due.unit_id, UNIT));
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner
            .users
            .push(person("person-102", 102, "Ben Kaya", Role::HomeOwner));
        inner
            .users
            .push(person("person-201", 201, "Dan Yılmaz", Role::HomeResident));
        inner
            .users
            .push(person("person-202", 202, "Mert Kılıç", Role::HomeResident));
        inner.users.push(person(
            "person-203",
            203,
            "Selin Arslan",
            Role::HomeResident,
        ));
        let today = Utc::now().date_naive();
        let unit = inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .expect("fixture unit");
        unit.owner_user_id = Some("person-102".to_string());
        unit.tenant_user_id = None;
        inner.dues.push(due(
            "due-dan-oct",
            201,
            DebtorType::Tenant,
            "Ekim 2026",
            today,
        ));
        // Another tenant of this site still owes a charge carrying an approved
        // correction: Dan was a tenant too, but the correction is not his.
        inner.dues.push(due(
            "due-selin-dec",
            203,
            DebtorType::Tenant,
            "Aralık 2026",
            today,
        ));
        inner.finance.corrections.push(correction(
            9101,
            "due-selin-dec",
            DebtorType::Tenant,
            "Aralık 2026",
            "other-tenant-reason",
        ));
    }
    state
}

/// Unit A-14 after Ben Kaya sold it to Gül Tanrıverdi on 2026-12-20 with Dan
/// still renting: Ben owes his December owner share, Gül owns the unit now, and
/// Dan owes his December tenant share.
async fn state_after_sale() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .dues
            .retain(|due| !sitepulse_backend::auth::same_id(&due.unit_id, UNIT));
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner
            .users
            .push(person("person-102", 102, "Ben Kaya", Role::HomeOwner));
        inner
            .users
            .push(person("person-201", 201, "Dan Yılmaz", Role::HomeResident));
        inner
            .users
            .push(person("person-300", 300, "Gül Tanrıverdi", Role::HomeOwner));
        let today = Utc::now().date_naive();
        let unit = inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .expect("fixture unit");
        unit.owner_user_id = Some("person-300".to_string());
        unit.tenant_user_id = Some("person-201".to_string());
        inner.dues.push(due(
            "due-ben-dec",
            102,
            DebtorType::Owner,
            "Aralık 2026",
            today,
        ));
        inner.dues.push(due(
            "due-gul-dec",
            300,
            DebtorType::Owner,
            "Aralık 2026",
            today,
        ));
        inner.dues.push(due(
            "due-dan-dec",
            201,
            DebtorType::Tenant,
            "Aralık 2026",
            today,
        ));
        // One approved correction on each owner charge: the seller must see only
        // his own, the buyer only hers, and staff both.
        inner.finance.corrections.push(correction(
            9001,
            "due-gul-dec",
            DebtorType::Owner,
            "Aralık 2026",
            "secret-reason-current-owner",
        ));
        inner.finance.corrections.push(correction(
            9002,
            "due-ben-dec",
            DebtorType::Owner,
            "Aralık 2026",
            "seller-reason",
        ));
    }
    state
}

/// Unit A-14 after Ben Kaya sold it to Gül Tanrıverdi, with Dan still renting.
/// Ben's only remaining tie is joint liability for Dan's tenant charge, and his
/// account role is the resident one — so the role he owes under must come from
/// the joint liability, not from his login.
async fn state_after_joint_only_former_owner() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner
            .dues
            .retain(|due| !sitepulse_backend::auth::same_id(&due.unit_id, UNIT));
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner
            .users
            .push(person("person-102", 102, "Ben Kaya", Role::HomeResident));
        inner
            .users
            .push(person("person-201", 201, "Dan Yılmaz", Role::HomeResident));
        inner
            .users
            .push(person("person-300", 300, "Gül Tanrıverdi", Role::HomeOwner));
        let today = Utc::now().date_naive();
        let unit = inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .expect("fixture unit");
        unit.owner_user_id = Some("person-300".to_string());
        unit.tenant_user_id = Some("person-201".to_string());
        inner.dues.push(due(
            "due-dan-jan",
            201,
            DebtorType::Tenant,
            "Ocak 2027",
            today,
        ));
        inner.joint_liability_owners.insert(
            "due-dan-jan".to_string(),
            vec![JointLiabilityOwner {
                person_id: 102,
                tenant_person_id: Some(201),
                start_date: today - Days::new(60),
                end_date: None,
            }],
        );
    }
    state
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
    if let Some(token) = bearer {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    let body = body
        .map(|value| Body::from(value.to_string()))
        .unwrap_or_else(|| Body::from("{}"));
    let response = app
        .oneshot(builder.body(body).expect("request"))
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    (status, String::from_utf8_lossy(&bytes).into_owned())
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: a former debtor reads only their own statement)
async fn former_tenant_reads_only_their_own_section_after_move_out() {
    let state = state_after_move_out().await;
    let dan = support::token(&state, "person-201", Role::HomeResident, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&dan),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "former tenant statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only Dan's own section: {body}");
    assert_eq!(debtors[0]["name"], "Dan Yılmaz", "{body}");
    assert_eq!(debtors[0]["is_former"], true, "{body}");
    assert_eq!(debtors[0]["liable_person_id"], 201, "{body}");
    let items = debtors[0]["open_items"].as_array().expect("open items");
    assert_eq!(items.len(), 1, "Dan's own charge only: {body}");
    assert_eq!(items[0]["due_id"], "due-dan-oct", "{body}");
    let corrections = statement["corrections"].as_array().expect("corrections");
    assert!(
        corrections.is_empty(),
        "no other tenant's correction: {body}"
    );
    assert!(!body.contains("other-tenant-reason"), "{body}");
}

#[tokio::test]
// covers: SC-13-10-05 (Issue #295: historical statement access does not widen other unit routes)
async fn former_tenant_keeps_no_access_to_other_unit_routes() {
    let state = state_after_move_out().await;
    let dan = support::token(&state, "person-201", Role::HomeResident, SITE, None).await;
    for path in [
        "/api/v1/residents/d-14/dashboard",
        "/api/v1/units/d-14/virtual-iban",
    ] {
        let (status, body) = call(build_router(state.clone()), "GET", path, Some(&dan), None).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{path} for a former tenant: {body}"
        );
    }
}

#[tokio::test]
async fn a_person_without_a_charge_on_the_unit_gets_no_statement() {
    let state = state_after_move_out().await;
    let mert = support::token(&state, "person-202", Role::HomeResident, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&mert),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "unrelated person: {body}");
}

#[tokio::test]
async fn site_staff_still_read_every_section() {
    let state = state_after_move_out().await;
    let manager = support::token(
        &state,
        "usr-statement-manager",
        Role::SiteManager,
        SITE,
        None,
    )
    .await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "manager statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    let names: Vec<&str> = debtors
        .iter()
        .map(|debtor| debtor["name"].as_str().unwrap_or_default())
        .collect();
    assert!(names.contains(&"Ben Kaya"), "current owner section: {body}");
    assert!(
        names.contains(&"Dan Yılmaz"),
        "former tenant section: {body}"
    );
    let corrections = statement["corrections"].as_array().expect("corrections");
    assert_eq!(
        corrections.len(),
        1,
        "staff keep the tenant correction too: {body}"
    );
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: a seller reads only their own historical statement)
async fn former_owner_reads_only_their_own_section_after_sale() {
    let state = state_after_sale().await;
    let ben = support::token(&state, "person-102", Role::HomeOwner, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&ben),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "former owner statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only Ben's own section: {body}");
    assert_eq!(debtors[0]["name"], "Ben Kaya", "{body}");
    assert_eq!(debtors[0]["is_former"], true, "{body}");
    assert_eq!(debtors[0]["liable_person_id"], 102, "{body}");
    let items = debtors[0]["open_items"].as_array().expect("open items");
    assert_eq!(items.len(), 1, "Ben's own charge only: {body}");
    assert_eq!(items[0]["due_id"], "due-ben-dec", "{body}");
    let corrections = statement["corrections"].as_array().expect("corrections");
    assert_eq!(corrections.len(), 1, "only Ben's own correction: {body}");
    assert_eq!(
        corrections[0]["correction_id"], 9002,
        "seller's own correction: {body}"
    );
    assert!(!body.contains("secret-reason-current-owner"), "{body}");
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: the new owner never inherits the seller's history)
async fn current_owner_does_not_see_the_former_owner_section() {
    let state = state_after_sale().await;
    let gul = support::token(&state, "person-300", Role::HomeOwner, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&gul),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "current owner statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only Gül's own section: {body}");
    assert_eq!(debtors[0]["name"], "Gül Tanrıverdi", "{body}");
    assert_eq!(debtors[0]["is_former"], false, "{body}");
    assert!(!body.contains("Ben Kaya"), "seller section hidden: {body}");
    assert!(
        !body.contains("due-ben-dec"),
        "seller charge hidden: {body}"
    );
    let corrections = statement["corrections"].as_array().expect("corrections");
    assert_eq!(corrections.len(), 1, "only Gül's own correction: {body}");
    assert_eq!(corrections[0]["correction_id"], 9001, "{body}");
    assert!(
        !body.contains("seller-reason"),
        "seller correction hidden: {body}"
    );
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: staff still read every correction after a sale)
async fn site_staff_read_every_correction_after_a_sale() {
    let state = state_after_sale().await;
    let manager = support::token(
        &state,
        "usr-statement-manager",
        Role::SiteManager,
        SITE,
        None,
    )
    .await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&manager),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "manager statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let corrections = statement["corrections"].as_array().expect("corrections");
    assert_eq!(corrections.len(), 2, "both corrections: {body}");
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: a joint-only predecessor reads their own section)
async fn joint_only_former_owner_reads_only_their_joint_section() {
    let state = state_after_joint_only_former_owner().await;
    let ben = support::token(&state, "person-102", Role::HomeResident, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&ben),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "joint-only former owner: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only Ben's own section: {body}");
    assert_eq!(debtors[0]["liable_person_id"], 102, "{body}");
    assert_eq!(debtors[0]["is_former"], true, "{body}");
    let joint = debtors[0]["jointly_liable_open_items"]
        .as_array()
        .expect("joint items");
    assert_eq!(joint.len(), 1, "joint liability: {body}");
    assert_eq!(joint[0]["due_id"], "due-dan-jan", "{body}");
    assert!(
        debtors[0]["open_items"]
            .as_array()
            .expect("open items")
            .is_empty(),
        "no owner charge of his own: {body}"
    );
}

#[tokio::test]
// covers: SC-13-10-07 (Issue #295: a joint-only predecessor does not read the tenant's section)
async fn current_tenant_does_not_see_the_joint_owners_section() {
    let state = state_after_joint_only_former_owner().await;
    let dan = support::token(&state, "person-201", Role::HomeResident, SITE, None).await;
    let (status, body) = call(
        build_router(state.clone()),
        "GET",
        "/api/v1/residents/d-14/statement",
        Some(&dan),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "current tenant statement: {body}");
    let statement: serde_json::Value = serde_json::from_str(&body).expect("statement JSON");
    let debtors = statement["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only Dan's own section: {body}");
    assert_eq!(debtors[0]["liable_person_id"], 201, "{body}");
    assert!(!body.contains("Ben Kaya"), "joint owner hidden: {body}");
}

#[tokio::test]
// covers: SC-13-10-05 (Issue #295: a former owner keeps no access to other unit routes)
async fn former_owner_keeps_no_access_to_other_unit_routes() {
    let state = state_after_sale().await;
    let ben = support::token(&state, "person-102", Role::HomeOwner, SITE, None).await;
    for path in [
        "/api/v1/residents/d-14/dashboard",
        "/api/v1/units/d-14/virtual-iban",
    ] {
        let (status, body) = call(build_router(state.clone()), "GET", path, Some(&ben), None).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{path} for a former owner: {body}"
        );
    }
}
