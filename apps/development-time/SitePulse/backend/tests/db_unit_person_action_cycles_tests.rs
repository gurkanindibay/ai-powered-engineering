#![allow(dead_code)]
//! PostgreSQL tests that perform every unit and person action several times in a row and read
//! the status, the occupancy history, the audit trail and the person cards back after each run
//! (STORY-08-12 and STORY-12-09). Moving a person out also moves their dependents out.
//!
//! ```text
//! cargo test --test db_unit_person_action_cycles_tests -- --ignored --test-threads=1
//! ```
//!
//! They run the real router on a throwaway database and need PostgreSQL and `DB_PASS`.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use deadpool_postgres::Pool;
use serde_json::{json, Value};
use sitepulse_backend::{app::build_router, auth, db, state::AppState};
use tower::ServiceExt;

/// A password generated per test run, so no credential is committed.
fn manager_password() -> &'static str {
    static PASSWORD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PASSWORD.get_or_init(|| {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        format!("Cy{}-{nanos}-aA1", std::process::id())
    })
}
const IGNORE: &str = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate";

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
}

impl TestDb {
    async fn create(tag: &str) -> Self {
        let admin =
            db::create_pool_for("postgres").expect("DB_PASS is required for the PostgreSQL tests");
        let name = format!("sp_cyc_{}_{}", tag, std::process::id());
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
        let hash = auth::hash_password(manager_password()).expect("hash");
        pool.get()
            .await
            .expect("connection")
            .execute(
                "WITH s AS (SELECT id FROM sites WHERE deleted_at IS NULL),
                      p AS (INSERT INTO persons (full_name, email, person_type, site_id)
                            SELECT 'Manager ' || id, 'cycle' || id || '@tenant.test', 'SITE_MANAGER', id FROM s
                            RETURNING id, email)
                 INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                 SELECT s.id, p.id, p.email, $1, 'SITE_MANAGER', FALSE
                 FROM s JOIN p ON p.email = 'cycle' || s.id || '@tenant.test'",
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

    async fn int(&self, sql: &str) -> i64 {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn text(&self, sql: &str) -> String {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn exec(&self, sql: &str) {
        let client = self.pool.get().await.expect("connection");
        client.batch_execute(sql).await.expect(sql);
    }
}

/// A throwaway database, the router and one logged-in manager per site.
struct Env {
    t: TestDb,
    app: Router,
    token: String,
    foreign_token: String,
    site: i64,
    unit: i64,
    owner: i64,
    seq: std::cell::Cell<u32>,
}

impl Env {
    async fn new(tag: &str) -> Self {
        let t = TestDb::create(tag).await;
        let site = t
            .int("SELECT id FROM sites WHERE slug = 'begonya-sitesi'")
            .await;
        let other = t
            .int("SELECT id FROM sites WHERE slug = 'kardelen-rezidans'")
            .await;
        let unit = t
            .int(
                "SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id JOIN sites s ON s.id = u.site_id
                 WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok' AND u.unit_number = 14",
            )
            .await;
        let owner = t
            .int(&format!(
                "SELECT owner_person_id FROM units WHERE id = {unit}"
            ))
            .await;
        let state = AppState::with_pool(Some(t.pool.clone()));
        state.reload_from_db().await.expect("load state");
        let app = build_router(state);
        let token = login(&app, &format!("cycle{site}@tenant.test")).await;
        let foreign_token = login(&app, &format!("cycle{other}@tenant.test")).await;
        Self {
            t,
            app,
            token,
            foreign_token,
            site,
            unit,
            owner,
            seq: std::cell::Cell::new(0),
        }
    }

    /// A number that is unique within the test, for names, emails and phones.
    fn next(&self) -> u32 {
        self.seq.set(self.seq.get() + 1);
        self.seq.get()
    }

    async fn req(
        &self,
        token: &str,
        method: &str,
        uri: &str,
        body: Option<Value>,
    ) -> (StatusCode, Value) {
        let mut req = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {token}"));
        let body = match body {
            Some(b) => {
                req = req.header("content-type", "application/json");
                Body::from(b.to_string())
            }
            None => Body::empty(),
        };
        let resp = self
            .app
            .clone()
            .oneshot(req.body(body).expect("request"))
            .await
            .expect("response");
        let status = resp.status();
        let bytes = to_bytes(resp.into_body(), 4 * 1024 * 1024)
            .await
            .expect("body");
        let json = serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into_owned()));
        (status, json)
    }

    async fn call(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        self.req(&self.token.clone(), method, uri, body).await
    }

    async fn ok(&self, method: &str, uri: &str, body: Option<Value>) -> Value {
        let (status, json) = self.call(method, uri, body).await;
        assert!(status.is_success(), "{method} {uri} -> {status}: {json}");
        json
    }

    async fn step_up(&self) {
        let (status, body) = self
            .call(
                "POST",
                "/api/v1/auth/step-up",
                Some(json!({ "password": manager_password() })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "step-up: {body}");
    }

    // ---------------------------------------------------------------- unit actions

    fn unit_uri(&self, suffix: &str) -> String {
        format!(
            "/api/v1/site-admin/units/{}/{suffix}?site_id={}",
            self.unit, self.site
        )
    }

    async fn command_raw(&self, body: Value) -> (StatusCode, Value) {
        self.call("POST", &self.unit_uri("occupancy-transitions"), Some(body))
            .await
    }

    async fn command(&self, body: Value) -> Value {
        let (status, json) = self.command_raw(body).await;
        assert_eq!(status, StatusCode::OK, "command: {json}");
        json
    }

    async fn vacate(&self) {
        self.command(json!({ "command": "MOVE_OUT" })).await;
    }

    /// A new tenant (TENANT_MOVE_IN on a vacant unit); returns the opened session.
    async fn tenant_in(&self, name: &str) -> Value {
        let n = self.next();
        self.ok(
            "POST",
            &self.unit_uri("move-in"),
            Some(json!({
                "role": "TENANT", "full_name": name,
                "email": format!("tenant{n}@cycles.test"), "phone": format!("0533{:07}", n)
            })),
        )
        .await
    }

    async fn move_out(&self) -> Value {
        self.ok(
            "POST",
            &self.unit_uri("move-out"),
            Some(json!({ "notes": "cycle" })),
        )
        .await
    }

    /// The unit's occupancy as the state endpoint reports it, and its allowed commands.
    async fn state(&self) -> (String, Vec<String>) {
        let s = self
            .ok("GET", &self.unit_uri("occupancy-state"), None)
            .await;
        let allowed = s["allowed_commands"]
            .as_array()
            .expect("allowed_commands")
            .iter()
            .map(|c| c.as_str().unwrap_or_default().to_string())
            .collect();
        (
            s["occupancy"].as_str().unwrap_or_default().to_string(),
            allowed,
        )
    }

    /// Asserts the state endpoint and the stored status agree, and returns the status.
    async fn assert_status(&self, expected: &str) {
        let (occupancy, allowed) = self.state().await;
        assert_eq!(occupancy, expected, "state endpoint");
        assert_eq!(self.db_status().await, expected, "stored status");
        assert!(!allowed.is_empty(), "a unit always offers a command");
        let allows = |c: &str| allowed.iter().any(|a| a == c);
        match expected {
            "VACANT" => assert!(
                allows("OWNER_MOVE_IN") && !allows("MOVE_OUT"),
                "{allowed:?}"
            ),
            "TENANT_OCCUPIED" => assert!(
                allows("MOVE_OUT") && allows("REPLACE_TENANT") && allows("OWNER_TAKES_BACK"),
                "{allowed:?}"
            ),
            "OWNER_OCCUPIED" => assert!(
                allows("MOVE_OUT") && allows("OWNER_RENTS_OUT") && !allows("OWNER_MOVE_IN"),
                "{allowed:?}"
            ),
            other => panic!("unexpected status {other}"),
        }
    }

    async fn db_status(&self) -> String {
        self.t
            .text(&format!(
                "SELECT occupancy_status FROM units WHERE id = {}",
                self.unit
            ))
            .await
    }

    /// The occupancy history, oldest session first.
    async fn history(&self) -> Vec<Value> {
        let mut items = self
            .ok("GET", &self.unit_uri("occupancy-history"), None)
            .await
            .as_array()
            .expect("history array")
            .clone();
        items.sort_by_key(|i| i["id"].as_i64().unwrap_or_default());
        items
    }

    async fn active_sessions(&self) -> usize {
        self.history()
            .await
            .iter()
            .filter(|i| i["is_active"] == true)
            .count()
    }

    /// Roles of the sessions, oldest first, e.g. `OWNER,TENANT`.
    async fn roles(&self) -> String {
        self.history()
            .await
            .iter()
            .map(|i| i["role"].as_str().unwrap_or("?").to_string())
            .collect::<Vec<_>>()
            .join(",")
    }

    async fn ownerships(&self) -> String {
        self.t
            .text(&format!(
                "SELECT COALESCE(string_agg(id || ':' || person_id || ':' || is_active || ':' || COALESCE(end_date::text, '-'), ',' ORDER BY id), '')
                 FROM unit_ownerships WHERE unit_id = {}",
                self.unit
            ))
            .await
    }

    async fn fingerprint(&self) -> String {
        let unit = self.unit;
        self.t
            .text(&format!(
                "SELECT COALESCE((SELECT string_agg(id || ':' || person_id || ':' || occupancy_type || ':' || is_active || ':' || COALESCE(end_date::text, '-'), ',' ORDER BY id)
                                  FROM unit_occupancies WHERE unit_id = {unit}), '')
                 || '|' || COALESCE((SELECT string_agg(id || ':' || person_id || ':' || is_active, ',' ORDER BY id)
                                  FROM unit_ownerships WHERE unit_id = {unit}), '')
                 || '|' || (SELECT COALESCE(owner_person_id::text, '-') || ':' || occupancy_status FROM units WHERE id = {unit})
                 || '|' || (SELECT count(*) FROM occupancy_transitions WHERE unit_id = {unit})"
            ))
            .await
    }

    async fn audit(&self) -> Vec<(String, String, String)> {
        let line = self
            .t
            .text(&format!(
                "SELECT COALESCE(string_agg(command || ':' || from_occupancy || ':' || to_occupancy, ',' ORDER BY id), '')
                 FROM occupancy_transitions WHERE unit_id = {}",
                self.unit
            ))
            .await;
        line.split(',')
            .filter(|s| !s.is_empty())
            .map(|s| {
                let mut p = s.split(':');
                (
                    p.next().unwrap_or_default().to_string(),
                    p.next().unwrap_or_default().to_string(),
                    p.next().unwrap_or_default().to_string(),
                )
            })
            .collect()
    }

    async fn live_persons(&self) -> i64 {
        self.t
            .int(&format!(
                "SELECT count(*) FROM persons WHERE site_id = {} AND deleted_at IS NULL",
                self.site
            ))
            .await
    }

    // ---------------------------------------------------------------- household

    fn members_uri(&self) -> String {
        format!(
            "/api/v1/home-residents/members/{}?site_id={}",
            self.unit, self.site
        )
    }

    async fn roster(&self) -> Vec<Value> {
        self.ok("GET", &self.members_uri(), None)
            .await
            .as_array()
            .expect("roster array")
            .clone()
    }

    /// Adds a new person as a household member; returns the response (person_id, resident_id).
    async fn add_member(&self, name: &str, relationship: &str) -> Value {
        let n = self.next();
        let (status, json) = self
            .call(
                "POST",
                &self.members_uri(),
                Some(json!({
                    "person": { "kind": "new", "card": {
                        "full_name": name, "phone": format!("0532{:07}", n),
                        "email": format!("member{n}@cycles.test") } },
                    "relationship": relationship
                })),
            )
            .await;
        assert_eq!(status, StatusCode::CREATED, "add member: {json}");
        json
    }

    async fn add_existing_member(&self, person_id: i64, relationship: &str) -> (StatusCode, Value) {
        self.call(
            "POST",
            &self.members_uri(),
            Some(
                json!({ "person": { "kind": "existing", "person_id": person_id },
                         "relationship": relationship }),
            ),
        )
        .await
    }

    async fn primary_contact(&self) -> Option<i64> {
        let client = self.t.pool.get().await.expect("connection");
        let row = client
            .query_one(
                &format!(
                    "SELECT primary_contact_person_id FROM units WHERE id = {}",
                    self.unit
                ),
                &[],
            )
            .await
            .expect("primary contact");
        row.get::<_, Option<i64>>(0)
    }

    async fn set_primary_contact(&self, person_id: i64) {
        self.ok(
            "PUT",
            &self.unit_uri("responsible-contact"),
            Some(json!({ "person_id": person_id })),
        )
        .await;
    }

    /// Members stored against a session, live or archived.
    async fn members_of_session(&self, session_id: i64) -> i64 {
        self.t
            .int(&format!(
                "SELECT count(*) FROM occupancy_members WHERE occupancy_id = {session_id}"
            ))
            .await
    }

    // ---------------------------------------------------------------- person actions

    fn person_uri(&self, person: i64, suffix: &str) -> String {
        format!(
            "/api/v1/site-admin/persons/{person}{suffix}{}site_id={}",
            if suffix.contains('?') { "&" } else { "?" },
            self.site
        )
    }

    async fn create_person(&self, card: Value) -> (StatusCode, Value) {
        self.call(
            "POST",
            &format!("/api/v1/site-admin/persons?site_id={}", self.site),
            Some(json!({ "card": card, "confirm_distinct": true })),
        )
        .await
    }

    async fn new_person(&self, name: &str) -> i64 {
        let n = self.next();
        let (status, created) = self
            .create_person(json!({
                "full_name": name, "phone": format!("0531{:07}", n),
                "email": format!("person{n}@cycles.test")
            }))
            .await;
        assert_eq!(status, StatusCode::CREATED, "create person: {created}");
        created["card"]["person_id"].as_i64().expect("person id")
    }

    async fn card(&self, person: i64) -> Value {
        self.ok("GET", &self.person_uri(person, "/card"), None)
            .await
    }

    /// `relation:active` pairs of the person's unit relations on the card, oldest first.
    async fn relations(&self, person: i64) -> Vec<String> {
        let mut rows = self
            .t
            .text(&format!(
                "SELECT COALESCE(string_agg(relation || ':' || active || ':' || (end_date IS NOT NULL), ',' ORDER BY start_date, relation), '')
                 FROM v_person_unit_relations WHERE person_id = {person} AND unit_id = {}",
                self.unit
            ))
            .await
            .split(',')
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect::<Vec<_>>();
        rows.sort();
        rows
    }

    async fn person_count(&self) -> i64 {
        self.live_persons().await
    }

    fn done(self) -> impl std::future::Future<Output = ()> {
        self.t.drop_db()
    }
}

async fn login(app: &Router, email: &str) -> String {
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    json!({ "email": email, "password": manager_password() }).to_string(),
                ))
                .expect("request"),
        )
        .await
        .expect("response");
    let status = resp.status();
    let bytes = to_bytes(resp.into_body(), 1 << 20).await.expect("body");
    let body: Value = serde_json::from_slice(&bytes).unwrap_or_default();
    assert_eq!(status, StatusCode::OK, "login {email}: {body}");
    body["access_token"].as_str().expect("token").to_string()
}

fn closed(item: &Value) -> bool {
    item["is_active"] == false && !item["end_date"].is_null()
}

// ==================================================================== unit actions

// covers: SC-08-12-01
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn tenant_move_in_and_move_out_repeated_keep_one_history_row_per_tenant() {
    let e = Env::new("tenant_cycles").await;
    e.assert_status("OWNER_OCCUPIED").await;
    e.vacate().await;
    e.assert_status("VACANT").await;
    assert_eq!(e.active_sessions().await, 0);
    let before = e.ownerships().await;

    for i in 1..=3usize {
        let opened = e.tenant_in(&format!("Kiraci {i}")).await;
        e.assert_status("TENANT_OCCUPIED").await;
        assert_eq!(opened["role"], "TENANT");
        assert_eq!(
            e.active_sessions().await,
            1,
            "one active session after move-in {i}"
        );
        assert_eq!(
            e.history().await.len(),
            1 + i,
            "history grows by one row per tenant"
        );

        let closed_item = e.move_out().await;
        assert_eq!(
            closed_item["id"], opened["id"],
            "move-out closes the tenant's own session"
        );
        e.assert_status("VACANT").await;
        assert_eq!(
            e.active_sessions().await,
            0,
            "no session after move-out {i}"
        );
    }

    let history = e.history().await;
    assert_eq!(e.roles().await, "OWNER,TENANT,TENANT,TENANT");
    assert!(
        history.iter().all(closed),
        "every session is closed: {history:?}"
    );
    let names: Vec<_> = history
        .iter()
        .map(|h| h["person_name"].as_str().unwrap_or(""))
        .collect();
    assert_eq!(&names[1..], ["Kiraci 1", "Kiraci 2", "Kiraci 3"]);
    assert_eq!(e.ownerships().await, before, "the deed is untouched");
    assert_eq!(
        e.t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {}",
            e.unit
        ))
        .await,
        e.owner
    );
    e.done().await;
}

// covers: SC-08-12-02
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn owner_rents_out_and_takes_back_repeatedly() {
    let e = Env::new("rent_cycles").await;
    e.assert_status("OWNER_OCCUPIED").await;
    for i in 1..=3usize {
        let n = e.next();
        let rented = e
            .command(
                json!({ "command": "OWNER_RENTS_OUT", "full_name": format!("Kiraci {i}"),
                "email": format!("rent{n}@cycles.test"), "phone": format!("0533{:07}", n) }),
            )
            .await;
        assert_eq!(
            rented["to_state"]["occupancy"], "TENANT_OCCUPIED",
            "{rented}"
        );
        e.assert_status("TENANT_OCCUPIED").await;
        assert_eq!(
            e.history().await.len(),
            2 * i,
            "owner session closed, tenant opened"
        );
        assert_eq!(e.active_sessions().await, 1);

        let back = e.command(json!({ "command": "OWNER_TAKES_BACK" })).await;
        assert_eq!(back["to_state"]["occupancy"], "OWNER_OCCUPIED", "{back}");
        e.assert_status("OWNER_OCCUPIED").await;
        assert_eq!(
            e.history().await.len(),
            2 * i + 1,
            "tenant closed, owner session opened"
        );
        assert_eq!(e.active_sessions().await, 1);
    }
    let history = e.history().await;
    assert_eq!(
        e.roles().await,
        "OWNER,TENANT,OWNER,TENANT,OWNER,TENANT,OWNER"
    );
    let (last, rest) = history.split_last().expect("history");
    assert!(rest.iter().all(closed), "{rest:?}");
    assert!(last["is_active"] == true && last["end_date"].is_null());
    assert_eq!(
        last["person_id"].as_i64(),
        Some(e.owner),
        "the owner is back"
    );
    e.done().await;
}

// covers: SC-08-12-03
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn replacing_the_tenant_repeatedly_settles_each_outgoing_tenant_once() {
    let e = Env::new("replace_cycles").await;
    e.vacate().await;
    let mut current = e.tenant_in("Kiraci 0").await;
    for i in 1..=3usize {
        let session = current["id"].as_i64().expect("session");
        let tenant = current["person_id"].as_i64().expect("tenant");
        let owed = 1000 + 250 * i as i64;
        e.t.exec(&format!(
            "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, status)
             VALUES ({}, 'Donem {i}', 'TENANT', 'OPERATIONAL_DUES', {tenant}, {session}, {owed}.00, CURRENT_DATE, 'PENDING')",
            e.unit
        ))
        .await;
        let n = e.next();
        let result = e
            .command(
                json!({ "command": "REPLACE_TENANT", "full_name": format!("Kiraci {i}"),
                "email": format!("replace{n}@cycles.test"), "phone": format!("0533{:07}", n) }),
            )
            .await;
        assert_eq!(result["from_state"]["occupancy"], "TENANT_OCCUPIED");
        assert_eq!(result["to_state"]["occupancy"], "TENANT_OCCUPIED");
        assert_eq!(
            result["closed"]["id"].as_i64(),
            Some(session),
            "the outgoing session closes"
        );
        assert_eq!(
            result["closed"]["exit_balance"],
            format!("{owed}.00"),
            "{result}"
        );
        current = result["opened"].clone();
        assert_ne!(current["id"].as_i64(), Some(session));
        e.assert_status("TENANT_OCCUPIED").await;
        assert_eq!(e.active_sessions().await, 1);
    }
    let history = e.history().await;
    assert_eq!(e.roles().await, "OWNER,TENANT,TENANT,TENANT,TENANT");
    let tenants: Vec<_> = history
        .iter()
        .filter(|h| h["role"] == "TENANT")
        .map(|h| h["person_id"].as_i64())
        .collect();
    let mut unique = tenants.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(
        unique.len(),
        tenants.len(),
        "every tenant appears exactly once"
    );
    assert_eq!(history.iter().filter(|h| h["is_active"] == true).count(), 1);
    assert_eq!(
        history.last().expect("last")["is_active"],
        true,
        "only the latest tenant is active"
    );
    e.done().await;
}

// covers: SC-08-12-04
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn owner_move_out_and_move_in_repeated_keep_the_owner_and_the_deed() {
    let e = Env::new("owner_cycles").await;
    let deed = e.ownerships().await;
    for i in 1..=3usize {
        e.command(json!({ "command": "MOVE_OUT" })).await;
        e.assert_status("VACANT").await;
        assert_eq!(e.active_sessions().await, 0);
        let opened = e.command(json!({ "command": "OWNER_MOVE_IN" })).await;
        assert_eq!(
            opened["opened"]["person_id"].as_i64(),
            Some(e.owner),
            "{opened}"
        );
        e.assert_status("OWNER_OCCUPIED").await;
        assert_eq!(e.active_sessions().await, 1);
        assert_eq!(
            e.ownerships().await,
            deed,
            "no ownership row changes in cycle {i}"
        );
        let history = e.history().await;
        assert_eq!(history.len(), 1 + i);
        assert_eq!(
            history.iter().filter(|h| closed(h)).count(),
            i,
            "one closed session per cycle"
        );
    }
    assert_eq!(e.roles().await, "OWNER,OWNER,OWNER,OWNER");
    e.done().await;
}

// covers: SC-08-12-05
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn title_transfer_repeated_keeps_every_previous_owner_in_the_history() {
    let e = Env::new("title_cycles").await;
    let persons_before = e.live_persons().await;
    let mut previous = vec![e.owner];
    for i in 1..=3 {
        e.step_up().await;
        let n = e.next();
        let (status, body) = e
            .call(
                "POST",
                &format!("/api/v1/site-admin/units/{}/transfer-ownership", e.unit),
                Some(
                    json!({ "unit_id": e.unit.to_string(), "new_owner_name": format!("Alici {i}"),
                    "new_owner_email": format!("buyer{n}@cycles.test") }),
                ),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "transfer {i}: {body}");
        let buyer =
            e.t.int(&format!(
                "SELECT id FROM persons WHERE email = 'buyer{n}@cycles.test'"
            ))
            .await;
        assert_eq!(
            e.t.int(&format!(
                "SELECT owner_person_id FROM units WHERE id = {}",
                e.unit
            ))
            .await,
            buyer,
            "the owner is the latest buyer"
        );
        e.assert_status("VACANT").await;
        for old in &previous {
            assert_eq!(
                e.t.int(&format!(
                    "SELECT count(*) FROM unit_ownerships WHERE unit_id = {} AND person_id = {old} AND NOT is_active AND end_date IS NOT NULL",
                    e.unit
                ))
                .await,
                1,
                "previous owner {old} has one closed period after transfer {i}"
            );
        }
        assert_eq!(
            e.t.int(&format!(
                "SELECT count(*) FROM unit_ownerships WHERE unit_id = {} AND is_active AND person_id = {buyer}",
                e.unit
            ))
            .await,
            1
        );
        previous.push(buyer);
        assert_eq!(
            e.live_persons().await,
            persons_before + i,
            "no card is deleted"
        );
    }
    e.done().await;
}

// covers: SC-08-12-06
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn every_executed_command_is_audited_in_order() {
    let e = Env::new("audit_chain").await;
    e.vacate().await;
    e.tenant_in("Kiraci 1").await;
    let n = e.next();
    e.command(
        json!({ "command": "REPLACE_TENANT", "full_name": "Kiraci 2",
        "email": format!("audit{n}@cycles.test") }),
    )
    .await;
    e.command(json!({ "command": "OWNER_TAKES_BACK" })).await;
    e.step_up().await;
    let (status, body) = e
        .call(
            "POST",
            &format!("/api/v1/site-admin/units/{}/transfer-ownership", e.unit),
            Some(
                json!({ "unit_id": e.unit.to_string(), "new_owner_name": "Alici",
                "new_owner_email": "audit.buyer@cycles.test" }),
            ),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let audit = e.audit().await;
    let commands: Vec<_> = audit.iter().map(|a| a.0.as_str()).collect();
    assert_eq!(
        commands,
        [
            "MOVE_OUT",
            "TENANT_MOVE_IN",
            "REPLACE_TENANT",
            "OWNER_TAKES_BACK",
            "TITLE_TRANSFER"
        ],
        "{audit:?}"
    );
    for pair in audit.windows(2) {
        assert_eq!(
            pair[0].2, pair[1].1,
            "to-state of {} is the from-state of {}",
            pair[0].0, pair[1].0
        );
    }
    assert_eq!(audit.last().expect("last").2, e.db_status().await);
    e.done().await;
}

// covers: SC-08-12-07
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn a_repeated_command_that_is_no_longer_legal_is_rejected_and_changes_nothing() {
    let e = Env::new("illegal_repeat").await;
    e.vacate().await;
    let before = e.fingerprint().await;
    let history_before = e.history().await.len();
    for _ in 0..2 {
        for command in [
            json!({ "command": "MOVE_OUT" }),
            json!({ "command": "OWNER_TAKES_BACK" }),
        ] {
            let (status, body) = e.command_raw(command.clone()).await;
            assert_eq!(status, StatusCode::CONFLICT, "{command} -> {body}");
            assert!(
                body.to_string().contains("VACANT"),
                "the error names the current state: {body}"
            );
        }
        let (status, _) = e
            .call(
                "POST",
                &e.unit_uri("move-out"),
                Some(json!({ "notes": "again" })),
            )
            .await;
        assert!(
            status.is_client_error(),
            "a second move-out is refused: {status}"
        );
        assert_eq!(e.fingerprint().await, before, "nothing changed");
    }
    assert_eq!(e.history().await.len(), history_before);
    e.assert_status("VACANT").await;
    e.done().await;
}

// covers: SC-08-12-08
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn household_members_added_edited_and_removed_repeatedly_keep_roster_and_contact() {
    let e = Env::new("household_cycles").await;
    for i in 1..=3 {
        let member = e.add_member(&format!("Uye {i}"), "SPOUSE").await;
        let person = member["person_id"].as_i64().expect("person id");
        let resident = member["resident_id"]
            .as_str()
            .expect("resident id")
            .to_string();
        let roster = e.roster().await;
        assert_eq!(
            roster.len(),
            1,
            "only the new member is on the roster: {roster:?}"
        );

        // Edit the member.
        let (status, body) = e
            .call(
                "PUT",
                &format!("/api/v1/home-residents/members/{}/{resident}?site_id={}", e.unit, e.site),
                Some(json!({ "full_name": format!("Uye {i} Yeni"), "phone": format!("0532{:07}", 900 + i),
                    "email": format!("uye{i}.yeni@cycles.test"), "relationship": "CHILD" })),
            )
            .await;
        assert!(status.is_success(), "edit member: {status} {body}");
        let roster = e.roster().await;
        assert_eq!(
            roster[0]["full_name"],
            format!("Uye {i} Yeni"),
            "{roster:?}"
        );

        // Primary contact.
        e.set_primary_contact(person).await;
        assert_eq!(e.primary_contact().await, Some(person));

        // Adding the same card again never duplicates the person or the roster entry.
        let cards = e.live_persons().await;
        let (status, again) = e.add_existing_member(person, "CHILD").await;
        assert!(
            status.is_success() || status == StatusCode::CONFLICT,
            "{status} {again}"
        );
        assert_eq!(e.live_persons().await, cards, "no second card");
        assert_eq!(
            e.roster().await.len(),
            1,
            "the member is on the roster once"
        );

        // Remove.
        let (status, body) = e
            .call(
                "DELETE",
                &format!(
                    "/api/v1/home-residents/members/{}/{resident}?site_id={}",
                    e.unit, e.site
                ),
                None,
            )
            .await;
        assert!(status.is_success(), "remove: {status} {body}");
        assert!(
            e.roster().await.is_empty(),
            "roster is empty after removal {i}"
        );
        assert_eq!(
            e.primary_contact().await,
            None,
            "primary contact cleared on removal"
        );
    }
    e.done().await;
}

// covers: SC-08-12-09
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn move_out_archives_the_household_of_the_closed_session_each_time() {
    let e = Env::new("archive_cycles").await;
    e.vacate().await;
    let mut closed_sessions = vec![];
    let first = e.tenant_in("Kiraci 0").await;
    e.add_member("Uye 0", "SPOUSE").await;
    let mut current = first["id"].as_i64().expect("session");
    for i in 1..=2 {
        e.move_out().await;
        closed_sessions.push(current);
        assert!(
            e.roster().await.is_empty(),
            "live roster empty after move-out"
        );
        let opened = e.tenant_in(&format!("Kiraci {i}")).await;
        current = opened["id"].as_i64().expect("session");
        assert!(
            e.roster().await.is_empty(),
            "a new tenant starts without the old household"
        );
        e.add_member(&format!("Uye {i}"), "CHILD").await;
        let roster = e.roster().await;
        assert_eq!(roster.len(), 1);
        assert_eq!(roster[0]["full_name"], format!("Uye {i}"));
        for session in &closed_sessions {
            assert_eq!(
                e.members_of_session(*session).await,
                1,
                "archived member of session {session}"
            );
        }
    }
    e.done().await;
}

// covers: SC-08-12-10
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_a_tenant_moves_out_all_dependents_move_out_with_them() {
    let e = Env::new("tenant_dependents").await;
    e.vacate().await;
    let tenant = e.tenant_in("Kiraci").await;
    let session = tenant["id"].as_i64().expect("session");
    let spouse = e.add_member("Es", "SPOUSE").await;
    e.add_member("Cocuk 1", "CHILD").await;
    e.add_member("Cocuk 2", "CHILD").await;
    e.set_primary_contact(spouse["person_id"].as_i64().expect("spouse"))
        .await;
    assert_eq!(e.roster().await.len(), 3);

    let closed_item = e.move_out().await;
    assert_eq!(closed_item["id"].as_i64(), Some(session));
    e.assert_status("VACANT").await;
    assert!(
        e.roster().await.is_empty(),
        "no dependent remains on the roster"
    );
    assert_eq!(
        e.members_of_session(session).await,
        3,
        "the dependents stay on the closed session"
    );
    assert_eq!(
        e.primary_contact().await,
        None,
        "the unit has no dependent as primary contact"
    );
    for who in ["Es", "Cocuk 1", "Cocuk 2"] {
        let person =
            e.t.int(&format!(
                "SELECT id FROM persons WHERE site_id = {} AND full_name = '{who}'",
                e.site
            ))
            .await;
        assert_eq!(
            e.relations(person).await,
            ["HOUSEHOLD_MEMBER:false:true"],
            "{who} is moved out"
        );
    }
    assert!(closed(e.history().await.last().expect("last")));
    e.done().await;
}

// covers: SC-08-12-11
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_an_owner_who_lives_in_the_unit_moves_out_their_dependents_move_out_too() {
    let e = Env::new("owner_dependents").await;
    let session =
        e.t.int(&format!(
            "SELECT id FROM unit_occupancies WHERE unit_id = {} AND is_active",
            e.unit
        ))
        .await;
    e.add_member("Es", "SPOUSE").await;
    e.add_member("Cocuk", "CHILD").await;
    assert_eq!(e.roster().await.len(), 2);

    e.command(json!({ "command": "MOVE_OUT" })).await;
    e.assert_status("VACANT").await;
    assert!(e.roster().await.is_empty());
    assert_eq!(
        e.members_of_session(session).await,
        2,
        "archived against the closed owner session"
    );
    assert_eq!(
        e.t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {}",
            e.unit
        ))
        .await,
        e.owner,
        "the owner stays on record"
    );
    e.done().await;
}

// covers: SC-08-12-12
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn dependents_follow_every_action_that_closes_a_session() {
    let e = Env::new("dependents_cycles").await;
    e.vacate().await;
    let first = e.tenant_in("Kiraci 1").await;
    let mut closed_sessions = vec![first["id"].as_i64().expect("session")];
    e.add_member("Uye 1a", "SPOUSE").await;
    e.add_member("Uye 1b", "CHILD").await;

    // REPLACE_TENANT
    let n = e.next();
    let replaced = e
        .command(
            json!({ "command": "REPLACE_TENANT", "full_name": "Kiraci 2",
            "email": format!("dep{n}@cycles.test") }),
        )
        .await;
    assert!(
        e.roster().await.is_empty(),
        "replace tenant: previous dependents are gone"
    );
    closed_sessions.push(replaced["opened"]["id"].as_i64().expect("session"));
    e.add_member("Uye 2a", "SPOUSE").await;
    e.add_member("Uye 2b", "CHILD").await;

    // OWNER_TAKES_BACK
    let back = e.command(json!({ "command": "OWNER_TAKES_BACK" })).await;
    assert!(
        e.roster().await.is_empty(),
        "owner takes back: previous dependents are gone"
    );
    closed_sessions.push(back["opened"]["id"].as_i64().expect("session"));
    e.add_member("Uye 3a", "SPOUSE").await;
    e.add_member("Uye 3b", "CHILD").await;

    // TITLE_TRANSFER (the owner session closes and the unit is vacant)
    e.step_up().await;
    let (status, body) = e
        .call(
            "POST",
            &format!("/api/v1/site-admin/units/{}/transfer-ownership", e.unit),
            Some(
                json!({ "unit_id": e.unit.to_string(), "new_owner_name": "Alici",
                "new_owner_email": "dep.buyer@cycles.test" }),
            ),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert!(
        e.roster().await.is_empty(),
        "title transfer: previous dependents are gone"
    );

    for session in &closed_sessions {
        assert_eq!(
            e.members_of_session(*session).await,
            2,
            "session {session} keeps its own two dependents"
        );
    }
    assert_eq!(
        e.t.int("SELECT count(*) FROM (SELECT person_id FROM occupancy_members WHERE person_id IS NOT NULL GROUP BY person_id HAVING count(*) > 1) d").await,
        0,
        "no dependent is attached to two sessions"
    );
    e.done().await;
}

// covers: SC-08-12-13
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn a_dependent_with_a_person_card_keeps_the_card_when_moved_out() {
    let e = Env::new("dependent_card").await;
    e.vacate().await;
    e.tenant_in("Kiraci 1").await;
    let member = e.add_member("Zeynep Aydin", "SPOUSE").await;
    let card = member["person_id"].as_i64().expect("card");
    assert_eq!(e.relations(card).await, ["HOUSEHOLD_MEMBER:true:false"]);

    e.move_out().await;
    assert!(e.roster().await.is_empty());
    assert_eq!(
        e.t.int(&format!(
            "SELECT count(*) FROM persons WHERE id = {card} AND deleted_at IS NULL"
        ))
        .await,
        1,
        "the card still exists"
    );
    assert_eq!(
        e.relations(card).await,
        ["HOUSEHOLD_MEMBER:false:true"],
        "the relation is closed"
    );

    e.tenant_in("Kiraci 2").await;
    let (status, body) = e.add_existing_member(card, "SPOUSE").await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(e.roster().await.len(), 1);
    let relations = e.relations(card).await;
    assert_eq!(
        relations,
        ["HOUSEHOLD_MEMBER:false:true", "HOUSEHOLD_MEMBER:true:false"]
    );
    e.done().await;
}

// ==================================================================== person actions

// covers: SC-12-09-01
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn creating_the_same_person_repeatedly_never_produces_a_second_card() {
    let e = Env::new("create_repeat").await;
    let card = json!({ "full_name": "Ayse Demir", "phone": "05329990001", "email": "ayse.demir@cycles.test" });
    let (status, created) = e.create_person(card.clone()).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let id = created["card"]["person_id"].as_i64().expect("id");
    let version = created["card"]["version"].clone();
    for _ in 0..2 {
        let (status, taken) = e.create_person(card.clone()).await;
        assert_eq!(status, StatusCode::CONFLICT, "{taken}");
        assert_eq!(taken["error"]["code"], "PERSON_IDENTITY_TAKEN");
    }
    assert_eq!(
        e.t.int("SELECT count(*) FROM persons WHERE email = 'ayse.demir@cycles.test'")
            .await,
        1
    );
    assert_eq!(
        e.card(id).await["card"]["version"],
        version,
        "the version did not move"
    );
    e.done().await;
}

// covers: SC-12-09-02
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn editing_a_card_repeatedly_raises_the_version_once_per_edit() {
    let e = Env::new("edit_repeat").await;
    let id = e.new_person("Ayse Demir").await;
    let mut version = e.card(id).await["card"]["version"]
        .as_i64()
        .expect("version");
    assert_eq!(version, 0);
    for i in 1..=3 {
        let (status, edited) = e
            .call(
                "PATCH",
                &e.person_uri(id, ""),
                Some(json!({ "full_name": format!("Ayse Demir {i}"), "phone": format!("0530000000{i}"),
                    "email": format!("ayse{i}@cycles.test"), "version": version })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "edit {i}: {edited}");
        assert_eq!(
            edited["card"]["version"].as_i64(),
            Some(version + 1),
            "{edited}"
        );
        version = edited["card"]["version"].as_i64().expect("version");
    }
    let card = e.card(id).await;
    assert_eq!(card["card"]["version"], 3);
    assert_eq!(card["card"]["full_name"], "Ayse Demir 3");
    assert_eq!(card["card"]["phone"], "05300000003");
    assert_eq!(card["card"]["email"], "ayse3@cycles.test");

    let (status, stale) = e
        .call(
            "PATCH",
            &e.person_uri(id, ""),
            Some(json!({ "full_name": "Late Edit", "version": 1 })),
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT, "{stale}");
    assert_eq!(stale["error"]["code"], "PERSON_VERSION_CONFLICT");
    assert_eq!(e.card(id).await["card"]["full_name"], "Ayse Demir 3");
    assert_eq!(e.card(id).await["card"]["version"], 3);
    e.done().await;
}

// covers: SC-12-09-03
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn opening_and_removing_a_login_repeatedly_keeps_the_login_status_correct() {
    let e = Env::new("login_cycles").await;
    let id = e.new_person("Can Ozturk").await;
    assert_eq!(e.card(id).await["card"]["login"], "NONE");
    let login = e.person_uri(id, "/login");
    let mut last_link = None;
    for round in 1..=2 {
        let delivery = e.ok("POST", &login, None).await;
        assert_ne!(
            card_login(&e, id).await,
            "NONE",
            "login is open in round {round}: {delivery}"
        );
        assert_eq!(
            e.t.int(&format!("SELECT count(*) FROM account_activations WHERE user_id IN (SELECT id FROM users WHERE person_id = {id}) AND used_at IS NULL AND expires_at > now()")).await,
            1,
            "exactly one usable link in round {round}"
        );
        let link = delivery.to_string();
        assert_ne!(
            Some(link.clone()),
            last_link,
            "round {round} issues a new link"
        );
        last_link = Some(link);

        e.step_up().await;
        let (status, _) = e.call("DELETE", &login, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "removal in round {round}");
        assert_eq!(
            card_login(&e, id).await,
            "NONE",
            "no login after removal {round}"
        );
        assert_eq!(
            e.t.int(&format!("SELECT count(*) FROM account_activations WHERE user_id IN (SELECT id FROM users WHERE person_id = {id}) AND used_at IS NULL")).await,
            0
        );
    }
    let (_, bare) = e
        .create_person(json!({ "full_name": "No Mail Person" }))
        .await;
    let bare_id = bare["card"]["person_id"].as_i64().expect("id");
    let (status, _) = e.call("POST", &e.person_uri(bare_id, "/login"), None).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a card without an email gets no login"
    );
    e.done().await;
}

async fn card_login(e: &Env, person: i64) -> String {
    e.card(person).await["card"]["login"]
        .as_str()
        .unwrap_or("?")
        .to_string()
}

// covers: SC-12-09-04
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn opening_the_login_twice_in_a_row_reuses_the_same_account() {
    let e = Env::new("login_twice").await;
    let id = e.new_person("Can Ozturk").await;
    let login = e.person_uri(id, "/login");
    e.ok("POST", &login, None).await;
    e.ok("POST", &login, None).await;
    assert_eq!(
        e.t.int(&format!(
            "SELECT count(*) FROM users WHERE person_id = {id}"
        ))
        .await,
        1
    );
    assert_eq!(
        e.t.int(&format!("SELECT count(*) FROM account_activations WHERE user_id IN (SELECT id FROM users WHERE person_id = {id}) AND used_at IS NULL AND expires_at > now()")).await,
        1,
        "the older link is no longer usable"
    );
    e.done().await;
}

// covers: SC-12-09-05
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn a_persons_card_follows_the_unit_actions_and_keeps_the_relation_history() {
    let e = Env::new("card_history").await;
    let selin = e.new_person("Selin Demir").await;
    e.vacate().await;
    for stay in 1..=2 {
        e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": selin } })).await;
        let mut expected = vec!["TENANT:false:true"; stay - 1];
        expected.push("TENANT:true:false");
        assert_eq!(e.relations(selin).await, expected, "stay {stay}");
        e.command(json!({ "command": "MOVE_OUT" })).await;
        e.assert_status("VACANT").await;
    }
    assert_eq!(
        e.relations(selin).await,
        ["TENANT:false:true", "TENANT:false:true"],
        "one closed stay per move-out"
    );

    // Selin moves in a third time and buys the unit.
    e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": selin } })).await;
    e.step_up().await;
    let (status, body) = e
        .call(
            "POST",
            &format!("/api/v1/site-admin/units/{}/transfer-ownership", e.unit),
            Some(json!({ "unit_id": e.unit.to_string(), "new_owner": { "kind": "existing", "person_id": selin } })),
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let relations = e.relations(selin).await;
    assert!(
        relations.contains(&"OWNER:true:false".to_string()),
        "{relations:?}"
    );
    assert_eq!(
        relations
            .iter()
            .filter(|r| r.starts_with("TENANT:false:true"))
            .count(),
        3,
        "{relations:?}"
    );
    let card = e.card(selin).await;
    assert!(
        card["units"].as_array().map_or(0, Vec::len) >= 4,
        "the card lists every relation: {card}"
    );
    let previous = e.relations(e.owner).await;
    assert!(
        previous.iter().any(|r| r == "OWNER:false:true"),
        "previous owner: {previous:?}"
    );
    e.done().await;
}

// covers: SC-12-09-06
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn choosing_the_same_existing_person_repeatedly_creates_no_new_card() {
    let e = Env::new("same_card").await;
    let zeynep = e.new_person("Zeynep Kaya").await;
    let cards = e.person_count().await;

    // As a household member of the owner.
    let (status, body) = e.add_existing_member(zeynep, "RELATIVE").await;
    assert_eq!(status, StatusCode::CREATED, "{body}");
    assert_eq!(e.person_count().await, cards);
    assert_eq!(e.relations(zeynep).await, ["HOUSEHOLD_MEMBER:true:false"]);

    // The owner and the household leave; the same card moves in as tenant.
    e.command(json!({ "command": "MOVE_OUT" })).await;
    assert_eq!(e.relations(zeynep).await, ["HOUSEHOLD_MEMBER:false:true"]);
    e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": zeynep } })).await;
    assert_eq!(e.person_count().await, cards);
    assert_eq!(
        e.relations(zeynep).await,
        ["HOUSEHOLD_MEMBER:false:true", "TENANT:true:false"]
    );

    e.move_out().await;
    assert_eq!(e.person_count().await, cards);
    e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": zeynep } })).await;
    assert_eq!(
        e.person_count().await,
        cards,
        "no new card after the last action"
    );
    assert_eq!(
        e.relations(zeynep).await,
        [
            "HOUSEHOLD_MEMBER:false:true",
            "TENANT:false:true",
            "TENANT:true:false"
        ]
    );
    assert!(e.card(zeynep).await["card"]["unit_labels"]
        .as_array()
        .is_some_and(|l| !l.is_empty()));
    e.done().await;
}

// covers: SC-12-09-07
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn contact_preferences_saved_repeatedly_keep_the_last_values() {
    let e = Env::new("prefs_cycles").await;
    let id = e.new_person("Ayse Demir").await;
    for (channel, language, emergency) in [
        ("SMS", "en", Some(("Fatma Demir", "05321112233"))),
        ("WHATSAPP", "tr", None),
        ("PHONE", "en", Some(("Ali Demir", "05324445566"))),
    ] {
        let (status, saved) = e
            .call(
                "PUT",
                &e.person_uri(id, "/preferences"),
                Some(
                    json!({ "preferred_channel": channel, "preferred_language": language,
                    "emergency_contact_name": emergency.map(|e| e.0),
                    "emergency_contact_phone": emergency.map(|e| e.1) }),
                ),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "{saved}");
        let profile = e.ok("GET", &e.person_uri(id, ""), None).await;
        let prefs = &profile["record"]["preferences"];
        assert_eq!(prefs["preferred_channel"], channel, "{profile}");
        assert_eq!(prefs["preferred_language"], language);
        assert_eq!(
            prefs["emergency_contact_name"],
            json!(emergency.map(|e| e.0))
        );
    }
    let (status, _) = e
        .call(
            "PUT",
            &e.person_uri(id, "/preferences"),
            Some(json!({ "preferred_channel": "PIGEON", "preferred_language": "tr" })),
        )
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let profile = e.ok("GET", &e.person_uri(id, ""), None).await;
    assert_eq!(
        profile["record"]["preferences"]["preferred_channel"], "PHONE",
        "an invalid save changes nothing"
    );
    e.done().await;
}

// covers: SC-12-09-08
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn setting_the_national_id_repeatedly_keeps_it_masked_and_unique() {
    let e = Env::new("national_id").await;
    let ayse = e.new_person("Ayse Demir").await;
    let mehmet = e.new_person("Mehmet Demir").await;
    let tckn = "10000000146";
    let recorded =
        e.t.int(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {} AND national_id_masked IS NOT NULL",
            e.site
        ))
        .await;
    e.step_up().await;
    for round in 1..=2 {
        let (status, body) = e
            .call(
                "PUT",
                &e.person_uri(ayse, "/national-id"),
                Some(json!({ "national_id": tckn })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "round {round}: {body}");
        let masked = body["national_id_masked"].as_str().expect("masked");
        assert!(!masked.contains(tckn) && masked.ends_with("46"), "{masked}");
        let card = e.card(ayse).await;
        assert_eq!(
            card["card"]["masked_national_id"], masked,
            "the card shows only the masked id"
        );
        assert!(
            !card.to_string().contains(tckn),
            "the full id never appears"
        );
    }
    assert_eq!(
        e.t.int(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {} AND national_id_masked IS NOT NULL",
            e.site
        ))
        .await,
        recorded + 1,
        "the repeated value stays one record"
    );
    let (status, body) = e
        .call(
            "PUT",
            &e.person_uri(mehmet, "/national-id"),
            Some(json!({ "national_id": tckn })),
        )
        .await;
    assert!(
        status.is_client_error(),
        "the same id on another card is refused: {status} {body}"
    );
    assert!(e.card(mehmet).await["card"]["masked_national_id"].is_null());
    e.done().await;
}

// covers: SC-12-09-09
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn duplicate_cards_are_merged_and_the_survivor_keeps_the_history() {
    let e = Env::new("merge_cycles").await;
    let survivor = e.new_person("Selin Demir").await;
    let duplicate = e.new_person("Selin Demir (kopya)").await;
    e.vacate().await;
    // The neighbour lived here under the duplicate card first, then under the survivor.
    e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": duplicate } })).await;
    e.command(json!({ "command": "MOVE_OUT" })).await;
    e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": survivor } })).await;
    let stays = e.history().await.len();

    e.step_up().await;
    let merge = e.person_uri(duplicate, "/merge");
    let target = survivor.to_string();
    let (status, body) = e
        .call("POST", &merge, Some(json!({ "target_person_id": target })))
        .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        e.t.int(&format!("SELECT count(*) FROM persons WHERE id = {duplicate} AND deleted_at IS NULL AND merged_into_person_id IS NULL")).await,
        0,
        "the duplicate no longer exists as a card"
    );
    assert_eq!(
        e.relations(duplicate).await,
        Vec::<String>::new(),
        "the duplicate holds no relations"
    );
    let relations = e.relations(survivor).await;
    assert_eq!(
        relations,
        ["TENANT:false:true", "TENANT:true:false"],
        "the survivor owns both stays"
    );

    // The merge cannot be repeated.
    let before = e.fingerprint().await;
    for _ in 0..2 {
        e.step_up().await;
        let (status, body) = e
            .call("POST", &merge, Some(json!({ "target_person_id": target })))
            .await;
        assert!(status.is_client_error(), "repeat merge: {status} {body}");
    }
    assert_eq!(e.fingerprint().await, before);
    assert_eq!(
        e.history().await.len(),
        stays,
        "the unit's history still lists both stays"
    );
    e.done().await;
}

// covers: SC-12-09-10
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn person_actions_of_another_site_are_refused_every_time() {
    let e = Env::new("foreign_site").await;
    let id = e.new_person("Ayse Demir").await;
    e.ok("POST", &e.person_uri(id, "/login"), None).await;
    let other_site =
        e.t.int("SELECT id FROM sites WHERE slug = 'kardelen-rezidans'")
            .await;
    let survivor = e.new_person("Hedef Kart").await;
    let before = (
        e.card(id).await,
        e.t.int(&format!(
            "SELECT count(*) FROM users WHERE person_id = {id} AND is_active"
        ))
        .await,
        e.fingerprint().await,
    );
    let foreign = |suffix: &str| {
        format!(
            "/api/v1/site-admin/persons/{id}{suffix}{}site_id={other_site}",
            if suffix.contains('?') { "&" } else { "?" }
        )
    };
    for _ in 0..2 {
        let calls = [
            ("GET", foreign("/card"), None),
            (
                "PATCH",
                foreign(""),
                Some(json!({ "full_name": "Hijack", "version": 1 })),
            ),
            ("POST", foreign("/login"), None),
            ("DELETE", foreign("/login"), None),
            (
                "POST",
                foreign("/merge"),
                Some(json!({ "target_person_id": survivor.to_string() })),
            ),
        ];
        for (method, uri, body) in calls {
            let (status, resp) = e.req(&e.foreign_token.clone(), method, &uri, body).await;
            assert!(
                matches!(status, StatusCode::NOT_FOUND | StatusCode::FORBIDDEN),
                "{method} {uri} -> {status} {resp}"
            );
        }
    }
    assert_eq!(e.card(id).await, before.0, "the card is unchanged");
    assert_eq!(
        e.t.int(&format!(
            "SELECT count(*) FROM users WHERE person_id = {id} AND is_active"
        ))
        .await,
        before.1,
        "the login status is unchanged"
    );
    assert_eq!(
        e.fingerprint().await,
        before.2,
        "the unit history is unchanged"
    );
    e.done().await;
}

// covers: SC-12-09-11
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn a_persons_move_out_also_moves_out_their_dependents_and_the_cards_show_it() {
    let e = Env::new("person_dependents").await;
    let selin = e.new_person("Selin Demir").await;
    e.vacate().await;
    let cards_with_selin = e.person_count().await;
    let mut dependents: Vec<i64> = vec![];

    for round in 1..=2 {
        e.command(json!({ "command": "TENANT_MOVE_IN", "person": { "kind": "existing", "person_id": selin } })).await;
        if round == 1 {
            for name in ["Ali Demir", "Mina Demir"] {
                dependents.push(
                    e.add_member(name, "CHILD").await["person_id"]
                        .as_i64()
                        .expect("id"),
                );
            }
        } else {
            assert!(
                e.roster().await.is_empty(),
                "the dependents are not on the roster until added again"
            );
            for id in &dependents {
                let (status, body) = e.add_existing_member(*id, "CHILD").await;
                assert_eq!(status, StatusCode::CREATED, "{body}");
            }
        }
        assert_eq!(e.roster().await.len(), 2);
        e.move_out().await;
        assert!(e.roster().await.is_empty());
        for id in &dependents {
            let relations = e.relations(*id).await;
            assert_eq!(relations.len(), round, "{relations:?}");
            assert!(
                relations.iter().all(|r| r == "HOUSEHOLD_MEMBER:false:true"),
                "{relations:?}"
            );
        }
        assert_eq!(e.relations(selin).await.len(), round);
    }
    assert_eq!(
        e.person_count().await,
        cards_with_selin + 2,
        "nobody is deleted and nobody is duplicated"
    );
    e.done().await;
}
