#![allow(dead_code)]
//! PostgreSQL-backed tests for the unified person API (task-33): scoped search,
//! card create/edit, reference-based commands and the primary contact.
//!
//! ```text
//! cargo test --test db_person_api_tests -- --ignored --test-threads=1
//! ```

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

const IGNORE: &str = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate";

/// Gives the unit an active occupancy (when it has none) so households can be used.
async fn ensure_occupancy(t: &TestDb, unit: i64) {
    t.exec(&format!(
        "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active)
         SELECT id, COALESCE(tenant_person_id, owner_person_id),
                CASE WHEN tenant_person_id IS NULL THEN 'OWNER' ELSE 'TENANT' END, CURRENT_DATE, TRUE
         FROM units WHERE id = {unit} AND NOT EXISTS
             (SELECT 1 FROM unit_occupancies WHERE unit_id = {unit} AND is_active = TRUE)"
    ))
    .await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-12-05-02, SC-12-05-03
async fn person_cards_are_created_edited_and_stay_in_their_site() {
    let t = TestDb::create("person_card").await;
    let a = t.site_id("begonya-sitesi").await;
    let b = t.site_id("kardelen-rezidans").await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let foreign = manager_token(&app, b).await;
    let create = format!("/api/v1/site-admin/persons?site_id={a}");
    let card = serde_json::json!({"full_name": "  Ayse   Demir ", "phone": "05329990001", "email": "Ayse.Demir@rust.test"});

    let (status, created) = call(
        &app,
        "POST",
        &create,
        &token,
        Some(serde_json::json!({"card": card})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    assert_eq!(created["card"]["full_name"], "Ayse Demir");
    assert_eq!(created["card"]["email"], "ayse.demir@rust.test");
    assert_eq!(created["card"]["roles"], serde_json::json!([]));
    let id = created["card"]["person_id"].as_i64().unwrap();

    // Same email: a hard duplicate that cannot be overridden.
    let (status, taken) = call(&app, "POST", &create, &token, Some(serde_json::json!({
        "card": {"full_name": "Other Name", "email": "ayse.demir@rust.test"}, "confirm_distinct": true
    }))).await;
    assert_eq!(status, StatusCode::CONFLICT, "{taken}");
    assert_eq!(taken["error"]["code"], "PERSON_IDENTITY_TAKEN");

    // Same phone, different email: a soft duplicate, accepted once confirmed.
    let phone_twin = serde_json::json!({"full_name": "Mehmet Demir", "phone": "05329990001"});
    let (status, dup) = call(
        &app,
        "POST",
        &create,
        &token,
        Some(serde_json::json!({"card": phone_twin})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{dup}");
    assert_eq!(dup["error"]["code"], "PERSON_POSSIBLE_DUPLICATE");
    assert_eq!(dup["error"]["details"]["overridable"], true);
    let (status, _) = call(
        &app,
        "POST",
        &create,
        &token,
        Some(serde_json::json!({"card": phone_twin, "confirm_distinct": true})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);

    // Edits need the current version.
    let patch = format!("/api/v1/site-admin/persons/{id}?site_id={a}");
    let (status, edited) = call(
        &app,
        "PATCH",
        &patch,
        &token,
        Some(serde_json::json!({"full_name": "Ayse Y. Demir", "version": 0})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{edited}");
    assert_eq!(edited["card"]["version"], 1);
    let (status, stale) = call(
        &app,
        "PATCH",
        &patch,
        &token,
        Some(serde_json::json!({"full_name": "Late Edit", "version": 0})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{stale}");
    assert_eq!(stale["error"]["code"], "PERSON_VERSION_CONFLICT");

    // Search finds the card in its own site only.
    let (status, found) = call(
        &app,
        "GET",
        &format!("/api/v1/site-admin/persons/search?site_id={a}&q=ayse"),
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(found["total"], 1, "{found}");
    let (_, other) = call(
        &app,
        "GET",
        &format!("/api/v1/site-admin/persons/search?site_id={b}&q=ayse"),
        &foreign,
        None,
    )
    .await;
    assert_eq!(other["total"], 0, "{other}");

    // Another site's manager cannot read or edit the card.
    let card_uri = format!("/api/v1/site-admin/persons/{id}/card?site_id={b}");
    let (status, _) = call(&app, "GET", &card_uri, &foreign, None).await;
    assert!(
        matches!(status, StatusCode::NOT_FOUND | StatusCode::FORBIDDEN),
        "{status}"
    );
    let (status, _) = call(
        &app,
        "PATCH",
        &format!("/api/v1/site-admin/persons/{id}?site_id={b}"),
        &foreign,
        Some(serde_json::json!({"full_name": "Hijack", "version": 1})),
    )
    .await;
    assert!(
        matches!(status, StatusCode::NOT_FOUND | StatusCode::FORBIDDEN),
        "{status}"
    );
    assert_eq!(
        t.scalar_text(&format!("SELECT full_name FROM persons WHERE id = {id}"))
            .await,
        "Ayse Y. Demir"
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-12-05-01, SC-12-05-06
async fn search_reports_role_eligibility_for_a_unit() {
    let t = TestDb::create("person_eligibility").await;
    let a = t.site_id("begonya-sitesi").await;
    let unit = t.unit_of(a).await;
    ensure_occupancy(&t, unit).await;
    let owner_name = t.scalar_text(&format!(
        "SELECT p.full_name FROM units u JOIN persons p ON p.id = u.owner_person_id WHERE u.id = {unit}"
    )).await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let needle = owner_name.split_whitespace().next().unwrap().to_lowercase();
    let (status, found) = call(
        &app,
        "GET",
        &format!(
        "/api/v1/site-admin/persons/search?site_id={a}&q={needle}&context=tenant&unit_id={unit}&page=1&limit=50"),
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{found}");
    let owner = found["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|i| i["card"]["full_name"] == owner_name)
        .expect("owner is listed");
    assert_eq!(owner["eligibility"]["allowed"], false, "{owner}");
    assert_eq!(owner["eligibility"]["code"], "OWNER_CANNOT_BE_TENANT");
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-12-05-04, SC-12-05-05
async fn household_by_reference_and_primary_contact_by_person() {
    let t = TestDb::create("person_household").await;
    let a = t.site_id("begonya-sitesi").await;
    let b = t.site_id("kardelen-rezidans").await;
    let unit = t.unit_of(a).await;
    ensure_occupancy(&t, unit).await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let members = format!("/api/v1/home-residents/members/{unit}?site_id={a}");

    // A new card created together with the member.
    let (status, member) = call(&app, "POST", &members, &token, Some(serde_json::json!({
        "person": {"kind": "new", "card": {"full_name": "Zeynep Aydin", "phone": "05328880002"}},
        "relationship": "SPOUSE"
    }))).await;
    assert_eq!(status, StatusCode::CREATED, "{member}");
    let person_id = member["person_id"]
        .as_i64()
        .expect("member is linked to a card");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {a} AND full_name = 'Zeynep Aydin'"
        ))
        .await,
        1
    );

    // The same card again does not create a second person.
    let (status, _) = call(
        &app,
        "POST",
        &members,
        &token,
        Some(serde_json::json!({
            "person": {"kind": "existing", "person_id": person_id}, "relationship": "SPOUSE"
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {a} AND full_name = 'Zeynep Aydin'"
        ))
        .await,
        1
    );

    // Primary contact by person; a stranger is refused.
    let contact = format!("/api/v1/site-admin/units/{unit}/responsible-contact?site_id={a}");
    let (status, saved) = call(
        &app,
        "PUT",
        &contact,
        &token,
        Some(serde_json::json!({"person_id": person_id})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{saved}");
    assert_eq!(saved["primary_responsible_name"], "Zeynep Aydin");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT primary_contact_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        person_id
    );
    let stranger = t.scalar_i64(&format!(
        "SELECT id FROM persons WHERE site_id = {a} AND id NOT IN (SELECT person_id FROM v_person_unit_relations WHERE unit_id = {unit}) ORDER BY id LIMIT 1")).await;
    let (status, _) = call(
        &app,
        "PUT",
        &contact,
        &token,
        Some(serde_json::json!({"person_id": stranger})),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // A card of another site cannot be added to this household.
    let foreign_card = t
        .scalar_i64(&format!(
            "SELECT id FROM persons WHERE site_id = {b} ORDER BY id LIMIT 1"
        ))
        .await;
    let (status, _) = call(
        &app,
        "POST",
        &members,
        &token,
        Some(serde_json::json!({
            "person": {"kind": "existing", "person_id": foreign_card}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Removing the member clears the primary contact.
    let member_id = member["resident_id"].as_str().unwrap();
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/v1/home-residents/members/{unit}/{member_id}?site_id={a}"),
        &token,
        None,
    )
    .await;
    assert!(status.is_success(), "{status}");
    assert_eq!(t.scalar_i64(&format!("SELECT count(*) FROM units WHERE id = {unit} AND primary_contact_person_id IS NOT NULL")).await, 0);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn logins_open_with_an_activation_link_and_removal_needs_step_up() {
    let t = TestDb::create("person_login").await;
    let a = t.site_id("begonya-sitesi").await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let (status, created) = call(&app, "POST", &format!("/api/v1/site-admin/persons?site_id={a}"), &token, Some(serde_json::json!({
        "card": {"full_name": "Can Ozturk", "phone": "05327770003", "email": "can.ozturk@rust.test"}}))).await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let id = created["card"]["person_id"].as_i64().unwrap();
    let login = format!("/api/v1/site-admin/persons/{id}/login?site_id={a}");
    let (status, delivery) = call(&app, "POST", &login, &token, None).await;
    assert_eq!(status, StatusCode::OK, "{delivery}");
    assert_eq!(t.scalar_i64(&format!("SELECT count(*) FROM users WHERE person_id = {id} AND is_active AND password_hash IS NULL")).await, 1);
    assert_eq!(t.scalar_i64(&format!("SELECT count(*) FROM account_activations WHERE user_id IN (SELECT id FROM users WHERE person_id = {id}) AND used_at IS NULL")).await, 1);

    // Without a recent step-up the login stays.
    let (status, _) = call(&app, "DELETE", &login, &token, None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM users WHERE person_id = {id} AND is_active"
        ))
        .await,
        1
    );

    // After a step-up the login is removed and its link no longer works.
    let (status, _) = call(
        &app,
        "POST",
        "/api/v1/auth/step-up",
        &token,
        Some(serde_json::json!({ "password": MANAGER_PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&app, "DELETE", &login, &token, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM users WHERE person_id = {id} AND is_active"
        ))
        .await,
        0
    );
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM account_activations WHERE user_id IN (SELECT id FROM users WHERE person_id = {id}) AND used_at IS NULL"
        ))
        .await,
        0
    );

    // A card without an email cannot receive a login.
    let (_, bare) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/persons?site_id={a}"),
        &token,
        Some(serde_json::json!({
        "card": {"full_name": "No Mail Person"}})),
    )
    .await;
    let bare_id = bare["card"]["person_id"].as_i64().unwrap();
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/persons/{bare_id}/login?site_id={a}"),
        &token,
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-12-05-04
async fn registration_accepts_person_references_for_owner_and_members() {
    let t = TestDb::create("person_register").await;
    let a = t.site_id("begonya-sitesi").await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let (_, helper) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/persons?site_id={a}"),
        &token,
        Some(serde_json::json!({
        "card": {"full_name": "Household Helper", "phone": "05326660004"}})),
    )
    .await;
    let helper_id = helper["card"]["person_id"].as_i64().unwrap();
    let body = serde_json::json!({
        "block": "Z", "unit_no": 901, "floor": 3, "is_resident": true,
        "owner": {"kind": "new", "card": {"full_name": "Selin Korkmaz", "phone": "05325550005", "email": "selin.korkmaz@rust.test"}},
        "members": [{"person": {"kind": "existing", "person_id": helper_id}, "relationship": "OTHER"}]
    });
    let (status, unit) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/home-owners?site_id={a}"),
        &token,
        Some(body.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{unit}");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {a} AND full_name = 'Selin Korkmaz'"
        ))
        .await,
        1
    );
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM occupancy_members WHERE person_id = {helper_id}"
        ))
        .await,
        1
    );

    // The same owner on another unit reuses the card and its login.
    let owner_id = t
        .scalar_i64(&format!(
            "SELECT id FROM persons WHERE site_id = {a} AND full_name = 'Selin Korkmaz'"
        ))
        .await;
    let again = serde_json::json!({
        "block": "Z", "unit_no": 902, "floor": 3, "is_resident": true,
        "owner": {"kind": "existing", "person_id": owner_id}
    });
    let (status, second) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/home-owners?site_id={a}"),
        &token,
        Some(again),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{second}");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM users WHERE person_id = {owner_id} AND is_active"
        ))
        .await,
        1
    );
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM persons WHERE site_id = {a} AND full_name = 'Selin Korkmaz'"
        ))
        .await,
        1
    );

    // A similar new owner is reported as a coded duplicate and nothing is created.
    let twin = serde_json::json!({
        "block": "Z", "unit_no": 903, "floor": 3, "is_resident": true,
        "owner": {"kind": "new", "card": {"full_name": "Selin K.", "phone": "05325550005", "email": "selin.twin@rust.test"}}
    });
    let (status, dup) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/home-owners?site_id={a}"),
        &token,
        Some(twin),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{dup}");
    assert_eq!(dup["error"]["code"], "PERSON_POSSIBLE_DUPLICATE");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM units WHERE site_id = {a} AND unit_number = 903"
        ))
        .await,
        0
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn title_transfer_honors_new_owner_reference_and_clears_the_old_primary_contact() {
    let t = TestDb::create("person_transfer").await;
    let a = t.site_id("begonya-sitesi").await;
    let unit = t.unit_of(a).await;
    let old_owner = t
        .scalar_i64(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await;
    t.exec(&format!(
        "UPDATE units SET primary_contact_person_id = {old_owner} WHERE id = {unit}"
    ))
    .await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, a).await;
    let (status, _) = call(
        &app,
        "POST",
        "/api/v1/auth/step-up",
        &token,
        Some(serde_json::json!({ "password": MANAGER_PASSWORD })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let uri = format!("/api/v1/site-admin/units/{unit}/transfer-ownership?site_id={a}");
    // The phone matches an existing person of the site: a soft duplicate.
    let buyer = serde_json::json!({"kind": "new", "card": {"full_name": "Yeni Malik", "phone": "05321002030", "email": "yeni.malik@rust.test"}});
    let (status, dup) = call(
        &app,
        "POST",
        &uri,
        &token,
        Some(serde_json::json!({"unit_id": unit.to_string(), "new_owner": buyer})),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "{dup}");
    assert_eq!(dup["error"]["code"], "PERSON_POSSIBLE_DUPLICATE");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        old_owner
    );

    let mut confirmed = buyer.clone();
    confirmed["confirm_distinct"] = serde_json::json!(true);
    let (status, done) = call(
        &app,
        "POST",
        &uri,
        &token,
        Some(serde_json::json!({"unit_id": unit.to_string(), "new_owner": confirmed})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{done}");
    let new_owner = t
        .scalar_i64(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await;
    assert_ne!(new_owner, old_owner);
    assert_eq!(
        t.scalar_text(&format!(
            "SELECT full_name FROM persons WHERE id = {new_owner}"
        ))
        .await,
        "Yeni Malik"
    );
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM units WHERE id = {unit} AND primary_contact_person_id IS NOT NULL"
        ))
        .await,
        0,
        "the previous owner must not stay the primary contact"
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-12-05-02
async fn role_free_card_has_no_stored_role_and_leaves_the_ledger_intact() {
    let t = TestDb::create("person_role_free").await;
    let site = t.site_id("begonya-sitesi").await;
    let app = build_router(t.state().await);
    let token = manager_token(&app, site).await;
    let before = t.ledger_fingerprint().await;

    let (status, created) = call(
        &app,
        "POST",
        &format!("/api/v1/site-admin/persons?site_id={site}"),
        &token,
        Some(
            serde_json::json!({"card": {"full_name": "Role Free", "email": "role.free@rust.test"}}),
        ),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{created}");
    let id = created["card"]["person_id"].as_i64().unwrap();

    let stored = t
        .scalar_text(&format!(
            "SELECT COALESCE(person_type, 'NULL') FROM persons WHERE id = {id}"
        ))
        .await;
    assert_eq!(stored, "NULL", "a role-free card stores no role");
    assert_eq!(
        t.scalar_i64(&format!(
            "SELECT count(*) FROM v_person_roles WHERE person_id = {id} AND derived_role IS NULL"
        ))
        .await,
        1
    );
    assert_eq!(t.ledger_fingerprint().await, before, "ledger is untouched");
    t.drop_db().await;
}
