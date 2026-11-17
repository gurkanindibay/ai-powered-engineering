#![allow(dead_code)]
//! PostgreSQL tests for STORY-07-08: a site's accrual is one transaction, every liability is
//! linked to its period row, and another spelling of the same month is a duplicate.
//!
//! ```text
//! cargo test --test db_accrual_atomic_tests -- --ignored --test-threads=1
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

const IGNORE: &str = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate";

/// A password generated per test run, so no credential is committed.
fn manager_password() -> &'static str {
    static PASSWORD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    PASSWORD.get_or_init(|| {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        format!("Ac{}-{nanos}-aA1", std::process::id())
    })
}

struct Env {
    name: String,
    admin: Pool,
    pool: Pool,
    state: AppState,
    app: Router,
    token: String,
    site: i64,
}

impl Env {
    async fn new(tag: &str) -> Self {
        let admin =
            db::create_pool_for("postgres").expect("DB_PASS is required for the PostgreSQL tests");
        let name = format!("sp_acc_{}_{}", tag, std::process::id());
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
                "WITH s AS (SELECT id FROM sites WHERE slug = 'begonya-sitesi'),
                      p AS (INSERT INTO persons (full_name, email, person_type, site_id)
                            SELECT 'Manager ' || id, 'accrual' || id || '@tenant.test', 'SITE_MANAGER', id FROM s
                            RETURNING id, email)
                 INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                 SELECT s.id, p.id, p.email, $1, 'SITE_MANAGER', FALSE
                 FROM s JOIN p ON p.email = 'accrual' || s.id || '@tenant.test'",
                &[&hash],
            )
            .await
            .expect("seed site manager");
        let site: i64 = pool
            .get()
            .await
            .expect("connection")
            .query_one("SELECT id FROM sites WHERE slug = 'begonya-sitesi'", &[])
            .await
            .expect("site")
            .get(0);
        let state = AppState::with_pool(Some(pool.clone()));
        state.reload_from_db().await.expect("load state");
        let app = build_router(state.clone());
        let token = login(&app, &format!("accrual{site}@tenant.test")).await;
        Self {
            name,
            admin,
            pool,
            state,
            app,
            token,
            site,
        }
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

    async fn exec(&self, sql: &str) {
        let client = self.pool.get().await.expect("connection");
        client.batch_execute(sql).await.expect(sql);
    }

    async fn call(&self, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
        let mut req = Request::builder()
            .method(method)
            .uri(uri)
            .header("authorization", format!("Bearer {}", self.token));
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

    async fn accrue(&self, period: &str, due: &str) -> (StatusCode, Value) {
        self.call(
            "POST",
            "/api/v1/dues/accrue-period",
            Some(json!({
                "site_id": self.site.to_string(),
                "period": period,
                "amount": "0",
                "due_date": due,
            })),
        )
        .await
    }

    async fn memory_dues(&self, label: &str) -> usize {
        self.state
            .inner
            .read()
            .await
            .dues
            .iter()
            .filter(|d| d.period == label)
            .count()
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

// covers: SC-07-08-03
#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn a_failure_partway_through_a_batch_writes_nothing_and_a_rerun_links_every_liability() {
    let _ = IGNORE;
    let env = Env::new("atomic").await;
    let units = env
        .int(&format!(
            "SELECT count(*) FROM units WHERE site_id = {} AND deleted_at IS NULL AND house_type_id IS NOT NULL",
            env.site
        ))
        .await;
    assert!(units >= 2, "the seed needs at least two tariffed units");
    // The database fails while the last liability of the batch is written.
    env.exec(&format!(
        "CREATE FUNCTION fail_last_liability() RETURNS trigger LANGUAGE plpgsql AS $f$
         BEGIN
           IF NEW.period_key = '2026-10'
              AND (SELECT count(*) FROM dues_liabilities WHERE period_key = '2026-10') >= {} THEN
             RAISE EXCEPTION 'injected failure';
           END IF;
           RETURN NEW;
         END $f$;
         CREATE TRIGGER fail_last BEFORE INSERT ON dues_liabilities
           FOR EACH ROW EXECUTE FUNCTION fail_last_liability();",
        units - 1
    ))
    .await;

    let (status, body) = env.accrue("2026-10", "2026-10-15").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(
        env.int("SELECT count(*) FROM dues_liabilities WHERE period_key = '2026-10'")
            .await,
        0,
        "no liability in the database"
    );
    assert_eq!(
        env.int("SELECT count(*) FROM dues_periods WHERE period_key = '2026-10'")
            .await,
        0,
        "no period row"
    );
    assert_eq!(
        env.int("SELECT count(*) FROM dues_accrual_runs").await,
        0,
        "no run report"
    );
    assert_eq!(
        env.memory_dues("Ekim 2026").await,
        0,
        "no liability in memory"
    );

    env.exec("DROP TRIGGER fail_last ON dues_liabilities").await;
    let (status, body) = env.accrue("2026-10", "2026-10-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["period_key"], "2026-10");
    assert_eq!(body["newly_accrued_units_count"], units);
    assert_eq!(
        env.int(
            "SELECT count(*) FROM dues_liabilities dl JOIN dues_periods dp ON dp.id = dl.dues_period_id
             WHERE dl.period_key = '2026-10' AND dp.period_key = '2026-10'"
        )
        .await,
        units,
        "every liability is linked to the period row"
    );
    assert_eq!(env.memory_dues("Ekim 2026").await as i64, units);
    env.drop_db().await;
}

// covers: SC-07-08-01
#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn another_spelling_of_an_accrued_month_creates_nothing_in_the_database() {
    let env = Env::new("spelling").await;
    let (status, body) = env.accrue("2026-10", "2026-10-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let rows = env
        .int("SELECT count(*) FROM dues_liabilities WHERE period_key = '2026-10'")
        .await;
    assert!(rows > 0);

    let (status, body) = env.accrue("ekim 2026", "2026-10-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["already_accrued"], true);
    assert_eq!(body["period_key"], "2026-10");
    assert_eq!(body["period"], "Ekim 2026");
    assert_eq!(
        env.int("SELECT count(*) FROM dues_liabilities WHERE period_key = '2026-10'")
            .await,
        rows
    );
    assert_eq!(
        env.int("SELECT count(*) FROM dues_periods WHERE period_key = '2026-10'")
            .await,
        1
    );
    // The database refuses a second operational liability for the same key.
    let duplicate = env
        .pool
        .get()
        .await
        .expect("connection")
        .execute(
            "INSERT INTO dues_liabilities (unit_id, period, period_key, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type)
             SELECT unit_id, 'ekim 2026', '2026-10', 1, due_date, 'PENDING', 0, debtor_type, expense_type
             FROM dues_liabilities WHERE period_key = '2026-10' LIMIT 1",
            &[],
        )
        .await;
    assert!(
        duplicate.is_err(),
        "uq_unit_period_key_expense must refuse it"
    );
    env.drop_db().await;
}

// covers: SC-07-08-04
#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn skipped_units_are_recorded_where_the_manager_can_read_them() {
    let env = Env::new("skipped").await;
    env.exec(&format!(
        "UPDATE units SET house_type_id = NULL, house_type = NULL
         WHERE id = (SELECT min(id) FROM units WHERE site_id = {} AND deleted_at IS NULL)",
        env.site
    ))
    .await;
    env.state.reload_from_db().await.expect("reload");
    let (status, body) = env.accrue("2026-10", "2026-10-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["skipped_units"].as_array().map(Vec::len), Some(1));

    let (status, runs) = env
        .call(
            "GET",
            &format!("/api/v1/dues/accrual-runs?site_id={}", env.site),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK, "{runs}");
    let run = &runs[0];
    assert_eq!(run["period_key"], "2026-10");
    assert_eq!(run["source"], "MANUAL");
    assert_eq!(run["skipped_units"].as_array().map(Vec::len), Some(1));
    env.drop_db().await;
}
