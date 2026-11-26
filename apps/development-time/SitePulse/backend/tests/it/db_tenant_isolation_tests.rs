//! PostgreSQL-backed tests for the production persistence path: multi-tenant
//! guardrails, read-only GETs, transactional advance offsets and loud failures.
//!
//! Every other Rust test runs on the in-memory state. These run the real router
//! on a throwaway database (created and dropped per test), so they need
//! PostgreSQL and `DB_PASS` (plus `DB_HOST`/`DB_PORT`/`DB_USER` if not default):
//!
//! ```text
//! cargo nextest run --locked --profile db --test it -E 'test(/db_tenant_isolation_tests::/)' --run-ignored ignored-only --test-threads 4
//! ```
//!
//! The verification gate `rust-db-test` (scripts/run_tests.py) runs them; with
//! `--skip-db` the gate is reported as SKIPPED, never as passed.

use std::sync::OnceLock;

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use deadpool_postgres::Pool;
use sitepulse_backend::{app::build_router, auth, db, state::AppState};
use tower::ServiceExt;

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
}

impl TestDb {
    async fn create(tag: &str) -> Self {
        let crate::test_db::TestDatabase { name, admin, pool } = crate::test_db::create(tag).await;
        // One real site manager per site: tokens are session-backed, so the
        // tests log in through /api/v1/auth/login instead of minting tokens.
        let hash = auth::hash_password(MANAGER_PASSWORD).expect("hash");
        pool.get()
            .await
            .expect("connection")
            .execute(
                "WITH s AS (SELECT id FROM sites WHERE deleted_at IS NULL),
                      p AS (INSERT INTO persons (full_name, email, person_type)
                            SELECT 'Manager ' || id, 'manager' || id || '@tenant.test', 'SITE_MANAGER' FROM s
                            RETURNING id, email)
                 INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                 SELECT s.id, p.id, p.email, $1, 'SITE_MANAGER', FALSE
                 FROM s JOIN p ON p.email = 'manager' || s.id || '@tenant.test'",
                &[&hash],
            )
            .await
            .expect("seed site managers");
        Self { name, admin, pool }
    }

    async fn drop_db(self) {
        drop(self.pool);
        if let Ok(client) = self.admin.get().await {
            let _ = client
                .batch_execute(&format!(
                    "DROP DATABASE IF EXISTS {} WITH (FORCE)",
                    self.name
                ))
                .await;
        }
    }

    async fn scalar_i64(&self, sql: &str) -> i64 {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn scalar_text(&self, sql: &str) -> String {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn exec(&self, sql: &str) {
        let client = self.pool.get().await.expect("connection");
        client.batch_execute(sql).await.expect(sql);
    }

    async fn state(&self) -> AppState {
        let state = AppState::with_pool(Some(self.pool.clone()));
        state.reload_from_db().await.expect("load state");
        state
    }

    async fn site_id(&self, slug: &str) -> i64 {
        self.scalar_i64(&format!("SELECT id FROM sites WHERE slug = '{}'", slug))
            .await
    }

    /// A unit of the site, its id as text.
    async fn unit_of(&self, site: i64) -> i64 {
        self.scalar_i64(&format!(
            "SELECT id FROM units WHERE site_id = {} ORDER BY id LIMIT 1",
            site
        ))
        .await
    }

    /// A fingerprint of every liability's payment state and every advance.
    async fn ledger_fingerprint(&self) -> String {
        self.scalar_text(
            "SELECT COALESCE((SELECT string_agg(id || ':' || status || ':' || paid_principal || ':' || paid_penalty, ',' ORDER BY id) FROM dues_liabilities), '')
             || '|' || COALESCE((SELECT string_agg(unit_id || ':' || debtor_type || ':' || balance, ',' ORDER BY unit_id, debtor_type) FROM advance_balances), '')
             || '|' || (SELECT count(*) FROM advance_ledger_entries)
             || '|' || (SELECT count(*) FROM payment_receipts)",
        )
        .await
    }
}

const MANAGER_PASSWORD: &str = "Tenant-Manager-123";

/// The password of the residents that [`seed_resident`] creates. It is derived
/// per test process so the seeding never adds a hard-coded credential to the
/// source: code scanning flags a literal used as a password, and a throwaway
/// database gives nothing for a stable value to protect.
fn resident_password() -> &'static str {
    static PASSWORD: OnceLock<String> = OnceLock::new();
    PASSWORD.get_or_init(|| format!("Resident-{}", uuid::Uuid::new_v4()))
}

/// Logs in as the seeded manager of `site` and returns a session-backed token.
async fn manager_token(app: &Router, site: i64) -> String {
    login(
        app,
        &format!("manager{}@tenant.test", site),
        MANAGER_PASSWORD,
    )
    .await
}

/// Logs in through /api/v1/auth/login and returns the access token.
async fn login(app: &Router, email: &str, password: &str) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({ "email": email, "password": password }).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap_or_default();
    assert_eq!(status, StatusCode::OK, "login as {}: {}", email, json);
    json["access_token"]
        .as_str()
        .expect("access_token")
        .to_string()
}

async fn call(
    app: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: Option<serde_json::Value>,
) -> (StatusCode, serde_json::Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {}", token));
    let body = match body {
        Some(b) => {
            req = req.header("content-type", "application/json");
            Body::from(b.to_string())
        }
        None => Body::empty(),
    };
    let resp = app.clone().oneshot(req.body(body).unwrap()).await.unwrap();
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 4 * 1024 * 1024).await.unwrap();
    let json = serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null);
    (status, json)
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn rls_hides_other_tenants_inside_a_bound_transaction() {
    let t = TestDb::create("rls").await;
    let a = t.site_id("begonya-sitesi").await;
    let b = t.site_id("kardelen-rezidans").await;
    assert!(db::rls_guard_installed(&t.pool).await.unwrap());

    let mut client = t.pool.get().await.unwrap();
    let tx = db::begin_tenant_read(&mut client, a).await.unwrap();
    assert_eq!(db::tx_bound_tenant(&tx).await.unwrap(), Some(a));
    let sites: i64 = tx
        .query_one("SELECT count(*) FROM sites", &[])
        .await
        .unwrap()
        .get(0);
    let foreign_units: i64 = tx
        .query_one("SELECT count(*) FROM units WHERE site_id <> $1", &[&a])
        .await
        .unwrap()
        .get(0);
    assert_eq!(sites, 1, "a bound transaction sees only its own site");
    assert_eq!(
        foreign_units, 0,
        "a query without a site filter still sees no foreign units"
    );
    tx.rollback().await.unwrap();

    // A write into another tenant is rejected by WITH CHECK, not just hidden.
    let tx = client.transaction().await.unwrap();
    db::tx_bind_tenant(&tx, a).await.unwrap();
    let err = tx
        .execute(
            "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, 'X', 1)",
            &[&b],
        )
        .await
        .expect_err("cross-tenant insert must fail");
    let message = err
        .as_db_error()
        .map(|e| e.message().to_string())
        .unwrap_or_default();
    assert!(message.contains("row-level security"), "{:?}", err);
    drop(tx);

    // The binding ends with the transaction: the pooled connection is clean.
    let unbound: i64 = client
        .query_one("SELECT count(*) FROM sites", &[])
        .await
        .unwrap()
        .get(0);
    assert!(unbound >= 2);
    drop(client);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn get_views_never_change_the_ledger_and_accrual_offsets_transactionally() {
    let t = TestDb::create("ledger").await;
    let a = t.site_id("begonya-sitesi").await;
    let unit = t.unit_of(a).await;
    let state = t.state().await;
    let app = build_router(state.clone());
    let token = manager_token(&app, a).await;

    // A payment far above the open dues leaves an OWNER advance.
    let (status, receipt) = call(
        &app,
        "POST",
        "/api/v1/payments/record-manual",
        &token,
        Some(serde_json::json!({
            "unit_id": unit.to_string(), "amount": "5000.00", "payer_name": "Owner",
            "payer_role": "OWNER", "payment_channel": "MANUAL_CASH"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{}", receipt);

    // A liability arriving out of band, then a fresh read model.
    t.exec(&format!(
        "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type)
         VALUES ({}, 'RUST-GET-CHECK', 100.00, CURRENT_DATE + 5, 'PENDING', 'OWNER')",
        unit
    ))
    .await;
    state.reload_from_db().await.unwrap();

    let before = t.ledger_fingerprint().await;
    let (s1, _) = call(
        &app,
        "GET",
        &format!("/api/v1/residents/{}/dashboard", unit),
        &token,
        None,
    )
    .await;
    let (s2, _) = call(
        &app,
        "GET",
        &format!("/api/v1/site-admin/overview?site_id={}", a),
        &token,
        None,
    )
    .await;
    assert_eq!((s1, s2), (StatusCode::OK, StatusCode::OK));
    assert_eq!(
        t.ledger_fingerprint().await,
        before,
        "GET requests must not move money"
    );

    // The accrual (a write) offsets the advance: receipt + allocations, no
    // integrity violations, and only this site is touched.
    let (status, res) = call(
        &app,
        "POST",
        "/api/v1/dues/accrue-period",
        &token,
        Some(serde_json::json!({
            "site_id": a.to_string(), "period": "2030-01", "amount": "10.00",
            "due_date": "2030-01-15"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{}", res);
    let open = t
        .scalar_i64(&format!(
            "SELECT count(*) FROM dues_liabilities WHERE unit_id = {} AND debtor_type = 'OWNER' AND status NOT IN ('PAID','CANCELLED')",
            unit
        ))
        .await;
    assert_eq!(open, 0, "the owner's advance settles the owner's open dues");
    let offset_receipts = t
        .scalar_i64(&format!(
            "SELECT count(*) FROM payment_receipts WHERE unit_id = {} AND payment_channel = 'INTER_LEDGER'",
            unit
        ))
        .await;
    assert!(
        offset_receipts >= 1,
        "every offset is documented by a receipt"
    );
    let violations = t
        .scalar_i64("SELECT count(*) FROM v_integrity_violations")
        .await;
    assert_eq!(violations, 0, "allocations must equal paid amounts");
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn tenant_data_never_crosses_sites() {
    let t = TestDb::create("tenant").await;
    let a = t.site_id("begonya-sitesi").await;
    let b = t.site_id("kardelen-rezidans").await;
    let unit_a = t.unit_of(a).await;
    let state = t.state().await;
    let app = build_router(state);

    let (status, _) = call(
        &app,
        "POST",
        "/api/v1/payments/record-manual",
        &manager_token(&app, a).await,
        Some(serde_json::json!({
            "unit_id": unit_a.to_string(), "amount": "77.00", "payer_name": "Private Payer A",
            "payer_role": "OWNER", "payment_channel": "MANUAL_CASH"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    // Site B's manager: no site A payment records leak through any listing.
    let token_b = manager_token(&app, b).await;
    let (status, records) = call(
        &app,
        "GET",
        "/api/v1/payments/homeowner-records",
        &token_b,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        !records.to_string().contains("Private Payer A"),
        "homeowner-records leaked another tenant's payment: {}",
        records
    );
    let (status, stream) = call(&app, "GET", "/api/v1/payments/stream", &token_b, None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!stream.to_string().contains("Private Payer A"));

    // Asking for site A explicitly is refused, as is site A's unit.
    for uri in [
        format!("/api/v1/payments/stream?site_id={}", a),
        format!("/api/v1/payments/homeowner-records?site_id={}", a),
        format!("/api/v1/payments/debt-aging?site_id={}", a),
        format!("/api/v1/residents/{}/dashboard", unit_a),
    ] {
        let (status, _) = call(&app, "GET", &uri, &token_b, None).await;
        assert!(
            status == StatusCode::FORBIDDEN || status == StatusCode::NOT_FOUND,
            "{} returned {} to another tenant",
            uri,
            status
        );
    }
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn financial_reads_fail_loudly_when_the_database_is_gone() {
    let t = TestDb::create("down").await;
    let a = t.site_id("begonya-sitesi").await;
    let state = t.state().await;
    let app = build_router(state);
    let token = manager_token(&app, a).await;
    let (status, _) = call(&app, "GET", "/api/v1/payments/stream", &token, None).await;
    assert_eq!(status, StatusCode::OK);

    let admin = t.admin.clone();
    let name = t.name.clone();
    admin
        .get()
        .await
        .unwrap()
        .batch_execute(&format!("DROP DATABASE {} WITH (FORCE)", name))
        .await
        .unwrap();

    for uri in [
        "/api/v1/payments/stream".to_string(),
        format!("/api/v1/payments/debt-aging?site_id={}", a),
        "/api/v1/payments/homeowner-records".to_string(),
    ] {
        let (status, body) = call(&app, "GET", &uri, &token, None).await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "{} must not serve an empty or cached ledger when PostgreSQL fails: {}",
            uri,
            body
        );
    }
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn household_members_round_trip_and_stay_in_their_site() {
    let t = TestDb::create("household").await;
    let a = t.site_id("begonya-sitesi").await;
    let b = t.site_id("kardelen-rezidans").await;
    let unit = t.unit_of(a).await;
    let state = t.state().await;
    let app = build_router(state);
    let token = manager_token(&app, a).await;

    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/home-residents/members/{}?site_id={}", unit, a),
        &token,
        Some(serde_json::json!({
            "person": {"kind": "new", "card": {
                "full_name": "Ali Kaya", "phone": "05320000001", "email": "ali.kaya@rust.test"
            }}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{}", body);

    let (status, members) = call(
        &app,
        "GET",
        &format!("/api/v1/home-residents/members/{}?site_id={}", unit, a),
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        members.to_string().contains("Ali Kaya"),
        "member not listed: {}",
        members
    );

    let (status, _) = call(
        &app,
        "GET",
        &format!("/api/v1/home-residents/members/{}", unit),
        &manager_token(&app, b).await,
        None,
    )
    .await;
    assert!(
        status == StatusCode::FORBIDDEN || status == StatusCode::NOT_FOUND,
        "another site's manager read the household: {}",
        status
    );
    t.drop_db().await;
}

/// Sender IBANs are stored as (iban -> unit). The handlers used to pass the unit
/// id where the IBAN goes, so every database-backed save failed after the
/// in-memory copy had already been changed.
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn sender_ibans_are_persisted_for_their_unit() {
    let t = TestDb::create("ibans").await;
    let a = t.site_id("begonya-sitesi").await;
    // Unit 14 is owned by the seeded home owner, who adds IBANs for it.
    let unit = t
        .scalar_i64(&format!(
            "SELECT id FROM units WHERE site_id = {} AND unit_number = 14 ORDER BY id LIMIT 1",
            a
        ))
        .await;
    let state = t.state().await;
    let app = build_router(state);
    let token = manager_token(&app, a).await;
    let owner = login(&app, "ahmet.yilmaz@begonya.com", "ahmet123").await;

    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/residents/{}/matching-criteria/ibans", unit),
        &owner,
        Some(serde_json::json!({ "sender_iban": "TR33 0006 1005 1978 6457 8413 26", "label": "Maaş" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{}", body);
    let (status, body) = call(
        &app,
        "POST",
        "/api/v1/bank/remembered-ibans",
        &token,
        Some(serde_json::json!({
            "site_id": a.to_string(), "unit_id": unit.to_string(),
            "sender_iban": "TR12 0006 2000 0000 0000 0000 01"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{}", body);
    let stored = t
        .scalar_i64(&format!(
            "SELECT count(*) FROM unit_sender_ibans WHERE unit_id = {} AND sender_iban IN \
             ('TR330006100519786457841326', 'TR120006200000000000000001')",
            unit
        ))
        .await;
    assert_eq!(stored, 2, "both sender IBANs must be stored for the unit");
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn responsible_contact_persists_without_changing_owner_or_tenant() {
    let t = TestDb::create("responsible_contact").await;
    let site = t.site_id("begonya-sitesi").await;
    let other_site = t.site_id("kardelen-rezidans").await;
    let unit = t.unit_of(site).await;
    let unit_text = unit.to_string();
    t.exec(&format!(
        "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active)
        SELECT id, COALESCE(tenant_person_id, owner_person_id),
               CASE WHEN tenant_person_id IS NULL THEN 'OWNER' ELSE 'TENANT' END, CURRENT_DATE, TRUE
        FROM units WHERE id = {unit} AND NOT EXISTS
            (SELECT 1 FROM unit_occupancies WHERE unit_id = {unit} AND is_active = TRUE)"
    ))
    .await;
    t.exec(&format!(
        "INSERT INTO occupancy_members (occupancy_id, full_name, relationship, phone, email)
        SELECT id, 'Selected Household Contact', 'SPOUSE', '05321112233', 'contact@tenant.test'
        FROM unit_occupancies WHERE unit_id = {unit} AND is_active = TRUE"
    ))
    .await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, site).await;
    let foreign_token = manager_token(&app, other_site).await;
    let list_url = format!("/api/v1/site-admin/home-owners?site_id={site}");
    let (_, before) = call(&app, "GET", &list_url, &token, None).await;
    let before = before
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["unit_id"] == unit_text)
        .unwrap()
        .clone();
    let uri = format!("/api/v1/site-admin/units/{unit}/responsible-contact?site_id={site}");
    let (status, saved) = call(
        &app,
        "PUT",
        &uri,
        &token,
        Some(serde_json::json!({"role":"OWNER", "resident_name":"ignored client identity"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["primary_responsible_name"], before["owner_full_name"]);
    let member = before["household_residents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|member| member["full_name"] == "Selected Household Contact")
        .unwrap();
    let (status, saved) = call(&app, "PUT", &uri, &token, Some(serde_json::json!({
        "role": "RESIDENT", "resident_name": "Selected Household Contact", "member_id": member["resident_id"]
    }))).await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    let fresh_app = build_router(t.state().await);
    let (_, after) = call(&fresh_app, "GET", &list_url, &token, None).await;
    let after = after
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["unit_id"] == unit_text)
        .unwrap();
    assert_eq!(after["primary_responsible_role"], "RESIDENT");
    assert_eq!(
        after["primary_responsible_name"],
        "Selected Household Contact"
    );
    for field in [
        "owner_full_name",
        "email",
        "phone",
        "tenant_full_name",
        "tenant_phone",
        "tenant_email",
        "occupancy_status",
    ] {
        assert_eq!(
            after[field], before[field],
            "identity field changed: {field}"
        );
    }
    let (status, _) = call(&fresh_app, "PUT", &uri, &token, Some(serde_json::json!({"role":"RESIDENT", "resident_name":"unrelated person", "member_id":"-1"}))).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let foreign_uri =
        format!("/api/v1/site-admin/units/{unit}/responsible-contact?site_id={other_site}");
    let (status, _) = call(
        &fresh_app,
        "PUT",
        &foreign_uri,
        &foreign_token,
        Some(serde_json::json!({"role":"OWNER", "resident_name":"foreign"})),
    )
    .await;
    assert!(matches!(
        status,
        StatusCode::NOT_FOUND | StatusCode::FORBIDDEN
    ));
    t.drop_db().await;
}

/// Issue 296: the manager's unit/debtor choice is written on the queue row, is
/// tenant-scoped, and comes back when the queue is reloaded (a restart).
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn reconciliation_assignment_is_persisted_for_its_site_only() {
    let t = TestDb::create("recon_assignment").await;
    let site = t.site_id("begonya-sitesi").await;
    let other_site = t.site_id("kardelen-rezidans").await;
    let unit = t.unit_of(site).await;
    t.exec(&format!(
        "INSERT INTO reconciliation_queue (match_id, transaction_id, txn_date, amount, description, status, site_id) \
         VALUES ('MATCH-ASSIGN-1', 'TX-ASSIGN-1', CURRENT_DATE, 1675.00, 'FAST TRANSFERI', 'UNMATCHED', {site})"
    ))
    .await;

    let site_text = site.to_string();
    let unit_text = unit.to_string();
    let saved = sitepulse_backend::db::save_reconciliation_assignment(
        &t.pool,
        "MATCH-ASSIGN-1",
        &site_text,
        &unit_text,
        sitepulse_backend::models::DebtorType::Owner,
    )
    .await
    .expect("the assignment is stored");
    assert!(saved, "the queue row belongs to the site");

    // A second site can never write the same row.
    let refused = sitepulse_backend::db::save_reconciliation_assignment(
        &t.pool,
        "MATCH-ASSIGN-1",
        &other_site.to_string(),
        &unit_text,
        sitepulse_backend::models::DebtorType::Tenant,
    )
    .await
    .expect("the scoped update runs");
    assert!(!refused, "a foreign site updates no row");

    let queue =
        sitepulse_backend::db::fetch_reconciliation_queue_from_db(&t.pool, Some(&site_text))
            .await
            .expect("the queue reloads");
    let item = queue
        .iter()
        .find(|m| m.match_id == "MATCH-ASSIGN-1")
        .expect("the row survives a reload");
    assert_eq!(item.assigned_unit_id.as_deref(), Some(unit_text.as_str()));
    assert_eq!(
        item.assigned_debtor_role,
        Some(sitepulse_backend::models::DebtorType::Owner)
    );

    // The UPDATE carries the handler's guards, so a confirmation that lands
    // between its read and write cannot be overwritten by a stale assignment.
    t.exec("UPDATE reconciliation_queue SET status = 'APPROVED' WHERE match_id = 'MATCH-ASSIGN-1'")
        .await;
    let approved = sitepulse_backend::db::save_reconciliation_assignment(
        &t.pool,
        "MATCH-ASSIGN-1",
        &site_text,
        &unit_text,
        sitepulse_backend::models::DebtorType::Tenant,
    )
    .await
    .expect("the guarded update runs");
    assert!(!approved, "an approved item takes no assignment");

    t.exec(&format!(
        "UPDATE reconciliation_queue SET status = 'UNMATCHED', matched_unit_id = {unit} \
         WHERE match_id = 'MATCH-ASSIGN-1'"
    ))
    .await;
    let matched = sitepulse_backend::db::save_reconciliation_assignment(
        &t.pool,
        "MATCH-ASSIGN-1",
        &site_text,
        &unit_text,
        sitepulse_backend::models::DebtorType::Owner,
    )
    .await
    .expect("the guarded update runs");
    assert!(
        !matched,
        "an automatically matched item takes no assignment"
    );

    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn the_database_rejects_capital_dues_billed_to_a_tenant() {
    let t = TestDb::create("capital").await;
    let a = t.site_id("begonya-sitesi").await;
    let unit = t.unit_of(a).await;
    let client = t.pool.get().await.expect("connection");
    let insert = |period: &str, debtor: &str, expense_type: &str| {
        format!(
            "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, expense_type)
             VALUES ({}, '{}', 100.00, CURRENT_DATE + 5, 'PENDING', '{}', '{}')",
            unit, period, debtor, expense_type
        )
    };

    // Capital dues are owner-only (KMK, V12 chk_dues_capital_owner_only).
    client
        .batch_execute(&insert("RUST-CAPITAL-OWNER", "OWNER", "CAPITAL_DUES"))
        .await
        .expect("an owner may be billed capital dues");
    client
        .batch_execute(&insert(
            "RUST-OPERATIONAL-TENANT",
            "TENANT",
            "OPERATIONAL_DUES",
        ))
        .await
        .expect("a tenant may be billed operational dues");
    let err = client
        .batch_execute(&insert("RUST-CAPITAL-TENANT", "TENANT", "CAPITAL_DUES"))
        .await
        .expect_err("a tenant must never be billed capital dues");
    let db_error = err
        .as_db_error()
        .expect("the insert fails with a PostgreSQL error");
    assert_eq!(db_error.code().code(), "23514", "{}", err);
    assert_eq!(
        db_error.constraint(),
        Some("chk_dues_capital_owner_only"),
        "{}",
        err
    );

    drop(client);
    t.drop_db().await;
}

/// Seeds a resident login (person + session-backed user) and returns its person id.
async fn seed_resident(t: &TestDb, site: i64, name: &str, email: &str) -> i64 {
    let hash = auth::hash_password(resident_password()).expect("hash");
    let person = t
        .scalar_i64(&format!(
            "INSERT INTO persons (full_name, email, person_type) \
             VALUES ('{name}', '{email}', 'HOME_RESIDENT') RETURNING id"
        ))
        .await;
    t.exec(&format!(
        "INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) \
         VALUES ({site}, {person}, '{email}', '{hash}', 'HOME_RESIDENT', FALSE)"
    ))
    .await;
    person
}

/// Issue #295: the production SQL behind `statement_unit` is the former-debtor
/// gate, so it gets its own PostgreSQL coverage: a former tenant and a joint
/// owner reach their own statement, an unrelated resident does not, and the
/// grant does not widen to another unit route.
// covers: SC-13-03-22 (Issue #489: a held advance grants only its owner's section)
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn statement_access_grants_former_debtors_in_postgresql() {
    let t = TestDb::create("statement_access").await;
    let site = t.site_id("begonya-sitesi").await;
    let unit = t.unit_of(site).await;
    let other_unit = t
        .scalar_i64(&format!(
            "SELECT id FROM units WHERE site_id = {site} AND id <> {unit} ORDER BY id LIMIT 1"
        ))
        .await;
    let former = seed_resident(&t, site, "Eski Kiraci", "former@sitepulse.test").await;
    let joint = seed_resident(&t, site, "Ortak Malik", "joint@sitepulse.test").await;
    let held_owner = seed_resident(&t, site, "Onceki Malik", "held-owner@sitepulse.test").await;
    seed_resident(&t, site, "Ilgisiz Kisi", "stranger@sitepulse.test").await;
    let tenant_due = t
        .scalar_i64(&format!(
            "INSERT INTO dues_liabilities \
                (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, status) \
             VALUES ({unit}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', {former}, 1016.13, CURRENT_DATE - 30, 'PENDING') \
             RETURNING id"
        ))
        .await;
    let joint_due = t
        .scalar_i64(&format!(
            "INSERT INTO dues_liabilities \
                (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, status) \
             VALUES ({unit}, 'Kasim 2026', 'TENANT', 'OPERATIONAL_DUES', {former}, 1016.13, CURRENT_DATE - 10, 'OVERDUE') \
             RETURNING id"
        ))
        .await;
    t.exec(&format!(
        "INSERT INTO dues_liability_joint_owners \
            (site_id, due_id, owner_person_id, tenant_person_id, liable_from, liable_through) \
         VALUES ({site}, {joint_due}, {joint}, {former}, CURRENT_DATE - 60, CURRENT_DATE + 30)"
    ))
    .await;
    t.exec(&format!(
        "INSERT INTO person_advance_holds (site_id, unit_id, person_id, debtor_type, balance) \
         VALUES ({site}, {unit}, {held_owner}, 'OWNER', 425.75)"
    ))
    .await;

    let state = t.state().await;
    let app = build_router(state);
    let statement_uri = format!("/api/v1/residents/{unit}/statement");
    let dashboard_uri = format!("/api/v1/residents/{unit}/dashboard");

    for (who, email) in [
        ("former tenant", "former@sitepulse.test"),
        ("joint owner", "joint@sitepulse.test"),
    ] {
        let token = login(&app, email, resident_password()).await;
        let (status, body) = call(&app, "GET", &statement_uri, &token, None).await;
        assert_eq!(status, StatusCode::OK, "{} statement: {}", who, body);
        let (status, body) = call(&app, "GET", &dashboard_uri, &token, None).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "{} keeps no other unit access: {}",
            who,
            body
        );
    }

    // A resident with no charge on the unit keeps the ordinary current-relationship answer.
    let stranger_token = login(&app, "stranger@sitepulse.test", resident_password()).await;
    let (status, body) = call(&app, "GET", &statement_uri, &stranger_token, None).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "unrelated resident: {}",
        body
    );

    // The grant never crosses a unit boundary: the same former debtor on a
    // different unit, where they owe nothing, is still refused.
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/residents/{other_unit}/statement"),
        &login(&app, "former@sitepulse.test", resident_password()).await,
        None,
    )
    .await;
    assert!(
        status == StatusCode::NOT_FOUND || status == StatusCode::FORBIDDEN,
        "another unit's statement: {} {}",
        status,
        body
    );

    // A paid charge is not a collectable one: the historical rule is about what
    // is still owed, so settling the liabilities closes the statement again.
    t.exec(&format!(
        "UPDATE dues_liabilities SET status = 'PAID', paid_principal = principal_amount, \
                paid_amount = principal_amount \
         WHERE id IN ({tenant_due}, {joint_due})"
    ))
    .await;
    let (status, body) = call(
        &app,
        "GET",
        &statement_uri,
        &login(&app, "joint@sitepulse.test", resident_password()).await,
        None,
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a settled joint liability closes the statement: {}",
        body
    );

    let held_owner_token = login(&app, "held-owner@sitepulse.test", resident_password()).await;
    let (status, body) = call(&app, "GET", &statement_uri, &held_owner_token, None).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "held former owner statement: {body}"
    );
    let debtors = body["debtors"].as_array().expect("debtors");
    assert_eq!(debtors.len(), 1, "only held owner's section: {body}");
    assert_eq!(
        debtors[0]["liable_person_id"], held_owner,
        "person scope: {body}"
    );
    assert_eq!(
        debtors[0]["held_advance_balance"], "425.75",
        "hold amount: {body}"
    );
    let (status, body) = call(&app, "GET", &dashboard_uri, &held_owner_token, None).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "hold does not widen unit access: {body}"
    );

    t.drop_db().await;
}
