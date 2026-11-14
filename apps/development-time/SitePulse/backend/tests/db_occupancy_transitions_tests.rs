//! PostgreSQL tests for the unit state model (EPIC-08 §3, STORY-08-06..10).
//!
//! One test per row of the transition table, the illegal commands, and the
//! end-to-end flow "tenant moves out, then the owner moves in" asserting that
//! the owner never changes. They run the real router on a throwaway database
//! (created and dropped per test) and need PostgreSQL and `DB_PASS`:
//!
//! ```text
//! cargo test --test db_occupancy_transitions_tests -- --ignored --test-threads=1
//! ```
//!
//! The verification gate `rust-db-test` runs them.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use deadpool_postgres::Pool;
use serde_json::{json, Value};
use sitepulse_backend::{app::build_router, auth, db, state::AppState};
use tower::ServiceExt;

const MANAGER_PASSWORD: &str = "Occupancy-Manager-123";

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
}

impl TestDb {
    async fn create(tag: &str) -> Self {
        let admin =
            db::create_pool_for("postgres").expect("DB_PASS is required for the PostgreSQL tests");
        let name = format!("sp_occ_{}_{}", tag, std::process::id());
        let client = admin.get().await.expect("admin connection");
        for sql in [
            format!("DROP DATABASE IF EXISTS {} WITH (FORCE)", name),
            format!("CREATE DATABASE {}", name),
        ] {
            client.batch_execute(&sql).await.expect("create database");
        }
        drop(client);
        let pool = db::create_pool_for(&name).expect("pool");
        db::init_db(&pool).await.expect("migrations");
        db::seed_test_data(&pool).await.expect("test seed");
        let hash = auth::hash_password(MANAGER_PASSWORD).expect("hash");
        pool.get()
            .await
            .expect("connection")
            .execute(
                "WITH s AS (SELECT id FROM sites WHERE slug = 'begonya-sitesi'),
                      p AS (INSERT INTO persons (full_name, email, person_type, site_id)
                            SELECT 'Occupancy Manager', 'occupancy.manager@sitepulse.test', 'SITE_MANAGER', id FROM s
                            RETURNING id)
                 INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                 SELECT s.id, p.id, 'occupancy.manager@sitepulse.test', $1, 'SITE_MANAGER', FALSE FROM s, p",
                &[&hash],
            )
            .await
            .expect("seed manager");
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

    async fn text(&self, sql: &str) -> String {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn int(&self, sql: &str) -> i64 {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn exec(&self, sql: &str) {
        let client = self.pool.get().await.expect("connection");
        client.batch_execute(sql).await.expect(sql);
    }

    async fn app(&self) -> (Router, String) {
        let state = AppState::with_pool(Some(self.pool.clone()));
        state.reload_from_db().await.expect("load state");
        let app = build_router(state);
        let token = login(&app).await;
        (app, token)
    }

    /// The seeded unit A Blok D:14 and its owner on record.
    async fn unit_and_owner(&self) -> (i64, i64) {
        let unit = self
            .int("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id JOIN sites s ON s.id = u.site_id
                  WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok' AND u.unit_number = 14")
            .await;
        let owner = self
            .int(&format!(
                "SELECT owner_person_id FROM units WHERE id = {unit}"
            ))
            .await;
        (unit, owner)
    }

    async fn status(&self, unit: i64) -> String {
        self.text(&format!(
            "SELECT occupancy_status FROM units WHERE id = {unit}"
        ))
        .await
    }

    /// Every occupancy and ownership row of the unit, for "nothing changed".
    async fn fingerprint(&self, unit: i64) -> String {
        self.text(&format!(
            "SELECT COALESCE((SELECT string_agg(id || ':' || person_id || ':' || occupancy_type || ':' || is_active || ':' || COALESCE(end_date::text, '-'), ',' ORDER BY id)
                              FROM unit_occupancies WHERE unit_id = {unit}), '')
             || '|' || COALESCE((SELECT string_agg(id || ':' || person_id || ':' || is_active, ',' ORDER BY id)
                              FROM unit_ownerships WHERE unit_id = {unit}), '')
             || '|' || (SELECT COALESCE(owner_person_id::text, '-') || ':' || occupancy_status FROM units WHERE id = {unit})"
        ))
        .await
    }

    async fn site(&self) -> i64 {
        self.int("SELECT id FROM sites WHERE slug = 'begonya-sitesi'")
            .await
    }
}

async fn login(app: &Router) -> String {
    let (status, body) = send(
        app,
        "POST",
        "/api/v1/auth/login",
        None,
        Some(json!({ "email": "occupancy.manager@sitepulse.test", "password": MANAGER_PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "login: {body}");
    body["access_token"].as_str().expect("token").to_string()
}

async fn send(
    app: &Router,
    method: &str,
    uri: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, Value) {
    let mut req = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        req = req.header("authorization", format!("Bearer {token}"));
    }
    let body = match body {
        Some(b) => {
            req = req.header("content-type", "application/json");
            Body::from(b.to_string())
        }
        None => Body::empty(),
    };
    let resp = app
        .clone()
        .oneshot(req.body(body).expect("request"))
        .await
        .expect("response");
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 4 * 1024 * 1024)
        .await
        .expect("body");
    (
        status,
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned())),
    )
}

async fn command(
    app: &Router,
    token: &str,
    site: i64,
    unit: i64,
    body: Value,
) -> (StatusCode, Value) {
    send(
        app,
        "POST",
        &format!("/api/v1/site-admin/units/{unit}/occupancy-transitions?site_id={site}"),
        Some(token),
        Some(body),
    )
    .await
}

/// The seeded owner lives in the unit; T5 leaves it vacant with the owner kept.
async fn vacate(app: &Router, token: &str, site: i64, unit: i64) {
    let (status, body) = command(app, token, site, unit, json!({ "command": "MOVE_OUT" })).await;
    assert_eq!(status, StatusCode::OK, "owner move-out: {body}");
}

async fn tenant_move_in(
    app: &Router,
    token: &str,
    site: i64,
    unit: i64,
    name: &str,
    email: &str,
) -> Value {
    let (status, body) = send(
        app,
        "POST",
        &format!("/api/v1/site-admin/units/{unit}/move-in?site_id={site}"),
        Some(token),
        Some(json!({ "role": "TENANT", "full_name": name, "email": email })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "tenant move-in: {body}");
    body
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_tenant_leaves_and_owner_moves_in_then_owner_is_unchanged() {
    let t = TestDb::create("owner_in").await;
    let site = t.site().await;
    let (unit, owner) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let ownerships = t
        .text(&format!("SELECT COALESCE(string_agg(id || ':' || person_id || ':' || is_active, ',' ORDER BY id), '') FROM unit_ownerships WHERE unit_id = {unit}"))
        .await;
    assert_eq!(t.status(unit).await, "VACANT", "the owner moved out");

    // T2: a tenant moves in; the owner stays the owner.
    let opened = tenant_move_in(
        &app,
        &token,
        site,
        unit,
        "Zeynep Kaya",
        "zeynep.kaya@sitepulse.test",
    )
    .await;
    assert_eq!(opened["role"], "TENANT");
    assert_eq!(t.status(unit).await, "TENANT_OCCUPIED");
    let tenant = opened["person_id"].as_i64().expect("tenant id");
    let tenant_session = opened["id"].as_i64().expect("session id");

    // STORY-08-10: the owner owes ₺900 from a vacant period, the tenant ₺1.500.
    t.exec(&format!(
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, status)
         VALUES ({unit}, 'Eylül 2026', 'OWNER', 'OPERATIONAL_DUES', {owner}, 900.00, CURRENT_DATE - 40, 'PENDING');
         INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, status)
         VALUES ({unit}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', {tenant}, {tenant_session}, 1500.00, CURRENT_DATE, 'PENDING');"
    ))
    .await;

    // T4: the tenant moves out with only their own balance.
    let (status, closed) = send(
        &app,
        "POST",
        &format!("/api/v1/site-admin/units/{unit}/move-out?site_id={site}"),
        Some(&token),
        Some(json!({ "notes": "Anahtar teslim edildi" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "move-out: {closed}");
    assert_eq!(closed["exit_balance"], "1500.00");
    assert_eq!(t.status(unit).await, "VACANT");

    // T3: the owner on record moves in; no person data is entered.
    let (status, opened) = send(
        &app,
        "POST",
        &format!("/api/v1/site-admin/units/{unit}/move-in?site_id={site}"),
        Some(&token),
        Some(json!({ "role": "OWNER" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "owner move-in: {opened}");
    assert_eq!(opened["person_id"].as_i64(), Some(owner));
    assert_eq!(opened["role"], "OWNER");
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        owner,
        "the owner of the unit is unchanged"
    );
    assert_eq!(
        t.text(&format!("SELECT COALESCE(string_agg(id || ':' || person_id || ':' || is_active, ',' ORDER BY id), '') FROM unit_ownerships WHERE unit_id = {unit}"))
            .await,
        ownerships,
        "no unit_ownerships row is inserted, closed or modified"
    );
    assert_eq!(
        t.text(&format!("SELECT string_agg(command || ':' || from_occupancy || '>' || to_occupancy, ',' ORDER BY id) FROM occupancy_transitions WHERE unit_id = {unit}"))
            .await,
        "MOVE_OUT:OWNER_OCCUPIED>VACANT,TENANT_MOVE_IN:VACANT>TENANT_OCCUPIED,MOVE_OUT:TENANT_OCCUPIED>VACANT,OWNER_MOVE_IN:VACANT>OWNER_OCCUPIED",
        "every transition is audited"
    );
    // T5: the owner moves out and keeps the deed.
    let (status, _) = command(&app, &token, site, unit, json!({ "command": "MOVE_OUT" })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(t.status(unit).await, "VACANT");
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        owner
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_owner_move_in_names_someone_else_then_it_is_rejected() {
    let t = TestDb::create("not_owner").await;
    let site = t.site().await;
    let (unit, _) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let before = t.fingerprint(unit).await;

    let (status, body) = send(
        &app,
        "POST",
        &format!("/api/v1/site-admin/units/{unit}/move-in?site_id={site}"),
        Some(&token),
        Some(json!({ "role": "OWNER", "full_name": "Mehmet Demir", "email": "mehmet.demir.new@sitepulse.test" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    let other = t
        .int(&format!(
            "SELECT id FROM persons WHERE site_id = {site} AND email = 'mehmet.oz@begonya.com'"
        ))
        .await;
    let (status, _) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "OWNER_MOVE_IN", "owner_person_id": other }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        t.fingerprint(unit).await,
        before,
        "the unit remains VACANT with its owner"
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_command_is_illegal_for_the_state_then_nothing_changes() {
    let t = TestDb::create("illegal").await;
    let site = t.site().await;
    let (unit, _) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let tenant_body = |n: &str| json!({ "command": "TENANT_MOVE_IN", "full_name": n, "email": format!("{n}@x.test") });

    // VACANT: move-out.
    let before = t.fingerprint(unit).await;
    let (status, _) = command(&app, &token, site, unit, json!({ "command": "MOVE_OUT" })).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(t.fingerprint(unit).await, before);

    // OWNER_OCCUPIED: tenant move-in, owner move-in.
    let (status, _) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "OWNER_MOVE_IN" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let before = t.fingerprint(unit).await;
    for body in [tenant_body("ayse"), json!({ "command": "OWNER_MOVE_IN" })] {
        let (status, _) = command(&app, &token, site, unit, body).await;
        assert_eq!(status, StatusCode::CONFLICT);
    }
    assert_eq!(t.fingerprint(unit).await, before);

    // TENANT_OCCUPIED (C2 owner rents out): tenant move-in, owner move-in.
    let (status, body) = command(
        &app,
        &token,
        site,
        unit,
        tenant_body("selin")
            .as_object()
            .map(|o| {
                let mut o = o.clone();
                o.insert("command".into(), json!("OWNER_RENTS_OUT"));
                Value::Object(o)
            })
            .unwrap_or_default(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["closed"]["role"], "OWNER");
    assert_eq!(t.status(unit).await, "TENANT_OCCUPIED");
    let before = t.fingerprint(unit).await;
    for body in [tenant_body("burak"), json!({ "command": "OWNER_MOVE_IN" })] {
        let (status, _) = command(&app, &token, site, unit, body).await;
        assert_eq!(status, StatusCode::CONFLICT);
    }
    assert_eq!(t.fingerprint(unit).await, before);

    // UNOWNED, VACANT: tenant move-in, owner move-in.
    let unowned = t
        .int(&format!(
            "INSERT INTO units (block_id, site_id, unit_number, floor, land_share)
             SELECT block_id, site_id, 99, 9, 1 FROM units WHERE id = {unit} RETURNING id"
        ))
        .await;
    let before = t.fingerprint(unowned).await;
    for body in [tenant_body("cem"), json!({ "command": "OWNER_MOVE_IN" })] {
        let (status, _) = command(&app, &token, site, unowned, body).await;
        assert_eq!(status, StatusCode::CONFLICT);
    }
    assert_eq!(t.fingerprint(unowned).await, before);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_tenant_is_replaced_then_outgoing_tenant_is_settled() {
    let t = TestDb::create("replace").await;
    let site = t.site().await;
    let (unit, owner) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let opened = tenant_move_in(&app, &token, site, unit, "Zeynep Kaya", "zeynep@x.test").await;
    let session = opened["id"].as_i64().expect("session");
    let tenant = opened["person_id"].as_i64().expect("tenant");
    t.exec(&format!(
        "UPDATE unit_occupancies SET start_date = CURRENT_DATE - 60 WHERE id = {session};
         INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, status)
         VALUES ({unit}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', {tenant}, {session}, 1500.00, CURRENT_DATE - 10, 'PENDING');"
    ))
    .await;
    let effective = t.text("SELECT (CURRENT_DATE - 1)::text").await;

    // Effective dates cannot be in the future.
    for date in [t.text("SELECT (CURRENT_DATE + 2)::text").await] {
        let (status, _) = command(&app, &token, site, unit, json!({
            "command": "REPLACE_TENANT", "full_name": "Mehmet Demir", "email": "mehmet.d@x.test", "effective_date": date
        }))
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    // A failed second step (the incoming tenant is the owner) leaves the tenant in place.
    let before = t.fingerprint(unit).await;
    let (status, _) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "REPLACE_TENANT", "person_id": owner }),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        t.fingerprint(unit).await,
        before,
        "the outgoing tenant's session is still open"
    );

    // C1: one transaction, one date, the exit settlement kept.
    let (status, body) = command(&app, &token, site, unit, json!({
        "command": "REPLACE_TENANT", "full_name": "Mehmet Demir", "email": "mehmet.d@x.test", "effective_date": effective
    }))
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["closed"]["end_date"], effective);
    assert_eq!(body["closed"]["exit_balance"], "1500.00");
    assert_eq!(body["opened"]["start_date"], effective);
    assert_eq!(body["to_state"]["occupancy"], "TENANT_OCCUPIED");
    assert_eq!(t.status(unit).await, "TENANT_OCCUPIED");

    // C3: the owner takes the unit back.
    let (status, body) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "OWNER_TAKES_BACK" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["opened"]["person_id"].as_i64(), Some(owner));
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        owner
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_title_is_transferred_then_occupancy_follows_the_state_table() {
    let t = TestDb::create("transfer").await;
    let site = t.site().await;
    let (unit, owner) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    let transfer = |body: Value| {
        let app = app.clone();
        let token = token.clone();
        async move {
            send(
                &app,
                "POST",
                &format!("/api/v1/site-admin/units/{unit}/transfer-ownership"),
                Some(&token),
                Some(body),
            )
            .await
        }
    };

    // A title transfer needs a recent password check.
    let (status, _) = send(
        &app,
        "POST",
        "/api/v1/auth/step-up",
        Some(&token),
        Some(json!({ "password": MANAGER_PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // OWNER_OCCUPIED (seeded) -> VACANT by default; the old owner's session closes.
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    let (status, body) = transfer(json!({ "unit_id": unit.to_string(), "new_owner_name": "Selim Evsahibi", "new_owner_email": "selim@x.test" })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(t.status(unit).await, "VACANT");
    let selim = t
        .int("SELECT id FROM persons WHERE email = 'selim@x.test'")
        .await;
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        selim
    );
    assert_eq!(
        t.int(&format!("SELECT count(*) FROM unit_occupancies WHERE unit_id = {unit} AND person_id = {owner} AND NOT is_active AND end_date IS NOT NULL")).await,
        1
    );

    // VACANT stays VACANT; the new owner then uses owner move-in.
    let (status, _) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "OWNER_MOVE_IN" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // OWNER_OCCUPIED with "new owner moves in".
    let (status, body) = transfer(json!({ "unit_id": unit.to_string(), "new_owner_name": "Ayla Yeni", "new_owner_email": "ayla@x.test", "new_owner_moves_in": true })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let ayla = t
        .int("SELECT id FROM persons WHERE email = 'ayla@x.test'")
        .await;
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    assert_eq!(
        t.int(&format!(
            "SELECT person_id FROM unit_occupancies WHERE unit_id = {unit} AND is_active"
        ))
        .await,
        ayla
    );

    // TENANT_OCCUPIED, the tenant buys the unit.
    let (status, _) = command(
        &app,
        &token,
        site,
        unit,
        json!({ "command": "OWNER_RENTS_OUT", "full_name": "Canan Kaya", "email": "canan@x.test" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let canan = t
        .int("SELECT id FROM persons WHERE email = 'canan@x.test'")
        .await;
    let (status, body) = transfer(json!({ "unit_id": unit.to_string(), "new_owner_name": "Canan Kaya", "new_owner_person_id": canan })).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    assert_eq!(
        t.text(&format!("SELECT occupancy_type || ':' || person_id FROM unit_occupancies WHERE unit_id = {unit} AND is_active")).await,
        format!("OWNER:{canan}")
    );
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        canan
    );
    // A future transfer date is refused.
    let tomorrow = t.text("SELECT (CURRENT_DATE + 2)::text").await;
    let before = t.fingerprint(unit).await;
    let (status, _) = transfer(json!({ "unit_id": unit.to_string(), "new_owner_name": "Late", "new_owner_email": "late@x.test", "transfer_date": tomorrow })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(t.fingerprint(unit).await, before);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_status_or_sessions_are_written_by_hand_then_the_model_holds() {
    let t = TestDb::create("derived").await;
    let (unit, _) = t.unit_and_owner().await;
    let stranger = t
        .int("INSERT INTO persons (full_name, person_type) VALUES ('Stranger', 'HOME_OWNER') RETURNING id")
        .await;

    // occupancy_status is derived from the sessions and cannot drift.
    t.exec(&format!(
        "UPDATE units SET occupancy_status = 'TENANT_OCCUPIED' WHERE id = {unit}"
    ))
    .await;
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    t.exec(&format!(
        "UPDATE unit_occupancies SET is_active = FALSE, end_date = start_date WHERE unit_id = {unit} AND is_active"
    ))
    .await;
    assert_eq!(t.status(unit).await, "VACANT");
    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM v_unit_state_drift WHERE unit_id = {unit}"
        ))
        .await,
        0
    );

    // An OWNER session for someone who is not an owner is refused at commit.
    let client = t.pool.get().await.expect("connection");
    let refused = client
        .batch_execute(&format!(
            "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type) VALUES ({unit}, {stranger}, 'OWNER')"
        ))
        .await;
    assert!(refused.is_err(), "owner session of a non-owner must fail");
    drop(client);
    assert_eq!(t.status(unit).await, "VACANT");

    // The audit trail is append-only.
    t.exec(&format!(
        "INSERT INTO occupancy_transitions (site_id, unit_id, command, from_ownership, from_occupancy, to_ownership, to_occupancy, effective_date)
         SELECT site_id, id, 'MOVE_OUT', 'OWNED', 'TENANT_OCCUPIED', 'OWNED', 'VACANT', CURRENT_DATE FROM units WHERE id = {unit}"
    ))
    .await;
    let client = t.pool.get().await.expect("connection");
    assert!(client
        .batch_execute("DELETE FROM occupancy_transitions")
        .await
        .is_err());
    drop(client);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_state_is_read_then_allowed_commands_follow_the_table() {
    let t = TestDb::create("state").await;
    let site = t.site().await;
    let (unit, owner) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let (status, body) = send(
        &app,
        "GET",
        &format!("/api/v1/site-admin/units/{unit}/occupancy-state?site_id={site}"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["ownership"], "OWNED");
    assert_eq!(body["occupancy"], "VACANT");
    assert_eq!(body["owners"][0]["person_id"].as_i64(), Some(owner));
    assert_eq!(
        body["allowed_commands"],
        json!(["TENANT_MOVE_IN", "OWNER_MOVE_IN", "TITLE_TRANSFER"])
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_registration_is_approved_on_an_occupied_unit_then_it_is_rejected() {
    let t = TestDb::create("approval").await;
    let site = t.site().await;
    let (unit, _) = t.unit_and_owner().await;
    let (app, token) = t.app().await;
    vacate(&app, &token, site, unit).await;
    let opened = tenant_move_in(&app, &token, site, unit, "Selin Demir", "selin@x.test").await;
    t.exec(&format!(
        "INSERT INTO pending_registrations (request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at)
         VALUES ('occ-approval-1', {site}, 'A Blok', 14, 4, 'Second Tenant', 'second.tenant@x.test', '05320000000', TRUE, 'PENDING', CURRENT_TIMESTAMP)"
    ))
    .await;
    let before = t.fingerprint(unit).await;
    let (status, body) = send(
        &app,
        "POST",
        "/api/v1/registration/approve/occ-approval-1",
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(t.fingerprint(unit).await, before);
    assert_eq!(
        t.int(&format!(
            "SELECT person_id FROM unit_occupancies WHERE unit_id = {unit} AND is_active"
        ))
        .await,
        opened["person_id"].as_i64().unwrap_or_default(),
        "Selin Demir remains the active tenant"
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_an_owner_is_registered_then_t1_records_ownership_and_the_unit_can_be_archived() {
    let t = TestDb::create("register").await;
    let site = t.site().await;
    let (app, token) = t.app().await;
    let (status, body) = send(
        &app,
        "POST",
        &format!("/api/v1/site-admin/home-owners?site_id={site}"),
        Some(&token),
        Some(json!({
            "block": "C", "unit_no": 701, "floor": 7, "owner_full_name": "Kayıt Malik",
            "email": "kayit.malik@x.test", "phone": "05321112233", "is_resident": true
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    let unit: i64 = body["unit_id"]
        .as_str()
        .and_then(|u| u.parse().ok())
        .expect("unit id");
    assert_eq!(t.status(unit).await, "OWNER_OCCUPIED");
    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM unit_ownerships WHERE unit_id = {unit} AND is_active"
        ))
        .await,
        1,
        "T1 opens the ownership"
    );
    let (status, body) = send(
        &app,
        "DELETE",
        &format!("/api/v1/site-admin/home-owners/{unit}?site_id={site}"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    t.drop_db().await;
}
