//! PostgreSQL-backed tests for the production persistence path: multi-tenant
//! guardrails, read-only GETs, transactional advance offsets and loud failures.
//!
//! Every other Rust test runs on the in-memory state. These run the real router
//! on a throwaway database (created and dropped per test), so they need
//! PostgreSQL and `DB_PASS` (plus `DB_HOST`/`DB_PORT`/`DB_USER` if not default):
//!
//! ```text
//! cargo test --test db_tenant_isolation_tests -- --ignored --test-threads=1
//! ```
//!
//! The verification gate `rust-db-test` (scripts/run_tests.py) runs them; with
//! `--skip-db` the gate is reported as SKIPPED, never as passed.

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
        let admin =
            db::create_pool_for("postgres").expect("DB_PASS is required for the PostgreSQL tests");
        let name = format!("sp_rust_{}_{}", tag, std::process::id());
        let client = admin.get().await.expect("admin connection");
        for sql in [
            format!("DROP DATABASE IF EXISTS {} WITH (FORCE)", name),
            format!("CREATE DATABASE {}", name),
        ] {
            client
                .batch_execute(&sql)
                .await
                .expect("create throwaway database");
        }
        drop(client);
        let pool = db::create_pool_for(&name).expect("pool");
        db::init_db(&pool).await.expect("migrations");
        db::seed_test_data(&pool).await.expect("test seed");
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
