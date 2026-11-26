//! PostgreSQL tests for STORY-07-08: a site's accrual is one transaction, every liability is
//! linked to its period row, and another spelling of the same month is a duplicate.
//!
//! ```text
//! cargo nextest run --locked --profile db --test it -E 'test(/db_accrual_atomic_tests::/)' --run-ignored ignored-only --test-threads 4
//! ```
//!
//! They run the real router on a throwaway database and need PostgreSQL and `DB_PASS`.

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use axum::Router;
use chrono::NaiveDate;
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use serde_json::{json, Value};
use sitepulse_backend::{
    app::build_router,
    auth, db,
    models::{DebtStatus, DebtorType, DuesLiability, ExpenseType},
    state::AppState,
};
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
    other_site: i64,
    other_token: String,
}

impl Env {
    async fn new(tag: &str) -> Self {
        let crate::test_db::TestDatabase { name, admin, pool } = crate::test_db::create(tag).await;
        let hash = auth::hash_password(manager_password()).expect("hash");
        pool.get()
            .await
            .expect("connection")
            .execute(
                "WITH s AS (SELECT id FROM sites WHERE deleted_at IS NULL),
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
        let other_site: i64 = pool
            .get()
            .await
            .expect("connection")
            .query_one("SELECT id FROM sites WHERE slug = 'kardelen-rezidans'", &[])
            .await
            .expect("other site")
            .get(0);
        let state = AppState::with_pool(Some(pool.clone()));
        state.reload_from_db().await.expect("load state");
        let app = build_router(state.clone());
        let token = login(&app, &format!("accrual{site}@tenant.test")).await;
        let other_token = login(&app, &format!("accrual{other_site}@tenant.test")).await;
        Self {
            name,
            admin,
            pool,
            state,
            app,
            token,
            site,
            other_site,
            other_token,
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
        self.call_as(&self.token, method, uri, body).await
    }

    async fn call_as(
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

    async fn accrue(&self, period: &str, due: &str) -> (StatusCode, Value) {
        self.call(
            "POST",
            "/api/v1/dues/accrue-period",
            Some(json!({
                "site_id": self.site.to_string(),
                "period": period,
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
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'",
            env.site
        ))
        .await,
        0,
        "no liability in the database"
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_periods WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
        0,
        "no period row"
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_accrual_runs WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
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
    let liability_rows = env
        .int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'",
            env.site
        ))
        .await;
    assert_eq!(liability_rows, units, "one liability per tariffed unit");
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             JOIN dues_periods dp ON dp.id = dl.dues_period_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'
               AND dp.site_id = {} AND dp.period_key = '2026-10'",
            env.site, env.site
        ))
        .await,
        units,
        "every liability links to this site's canonical period row"
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_periods WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
        1,
        "retry leaves exactly one period row"
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_accrual_runs WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
        1,
        "retry leaves exactly one run record"
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
        .int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'",
            env.site
        ))
        .await;
    assert!(rows > 0);

    let (status, body) = env.accrue("ekim 2026", "2026-10-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["already_accrued"], true);
    assert_eq!(body["period_key"], "2026-10");
    assert_eq!(body["period"], "Ekim 2026");
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'",
            env.site
        ))
        .await,
        rows
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_periods WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
        1
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             JOIN dues_periods dp ON dp.id = dl.dues_period_id
             WHERE u.site_id = {} AND dl.period_key = '2026-10'
               AND dp.site_id = {} AND dp.period_key = '2026-10'",
            env.site, env.site
        ))
        .await,
        rows,
        "each existing liability remains linked to its sole period row"
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_accrual_runs WHERE site_id = {} AND period_key = '2026-10'",
            env.site
        ))
        .await,
        1,
        "a spelling-only retry does not create another run"
    );
    // The database refuses a second operational liability for the same key.
    let duplicate = env
        .pool
        .get()
        .await
        .expect("connection")
        .execute(
            "INSERT INTO dues_liabilities (unit_id, period, period_key, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type, liable_person_id)
             SELECT unit_id, 'ekim 2026', '2026-10', 1, due_date, 'PENDING', 0, debtor_type, expense_type, liable_person_id
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

// covers: SC-13-03-09
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn a_tenant_inside_the_month_stores_rows_that_sum_to_the_tariff() {
    let _ = IGNORE;
    let env = Env::new("mid_month_tenant").await;
    let unit: i64 = env
        .int(&format!(
            "SELECT min(id) FROM units WHERE site_id = {} AND owner_person_id IS NOT NULL AND deleted_at IS NULL",
            env.site
        ))
        .await;
    let tenant: i64 = env
        .int(&format!(
            "INSERT INTO persons (full_name, site_id, person_type) VALUES ('Aylin Kaya', {}, 'HOME_RESIDENT') RETURNING id",
            env.site
        ))
        .await;
    let unit_id = unit.to_string();
    // Days 6-15 belong to the tenant, so the owner holds days 1-5 and 16-30: one debt for
    // the owner, not two rows the period's unique index would collapse to one.
    let history = [sitepulse_backend::models::OccupancyHistoryItem {
        id: 1,
        unit_id: unit,
        person_id: tenant,
        person_name: "Aylin Kaya".to_string(),
        person_phone: None,
        person_email: None,
        role: DebtorType::Tenant,
        start_date: "2031-01-06".to_string(),
        end_date: Some("2031-01-16".to_string()),
        is_active: false,
        exit_balance: Decimal::ZERO,
        notes: None,
        created_at: NaiveDate::from_ymd_opt(2026, 1, 1)
            .and_then(|date| date.and_hms_opt(0, 0, 0))
            .expect("fixed timestamp")
            .and_utc(),
    }];
    let tariff = Decimal::from_str_exact("1500.00").expect("tariff");
    let period =
        sitepulse_backend::domain::billing_period::BillingPeriod::parse("2031-01").expect("period");
    let shares = sitepulse_backend::services::occupancy_service::accrual_shares(
        tariff,
        period,
        Some(NaiveDate::from_ymd_opt(2026, 1, 1).expect("past date")),
        &history,
        true,
        NaiveDate::from_ymd_opt(2031, 1, 15).expect("accrual date"),
    );
    assert_eq!(
        shares.len(),
        2,
        "one owner share and one tenant share: {shares:?}"
    );
    let due_date = NaiveDate::from_ymd_opt(2031, 1, 10).expect("due date");
    let dues: Vec<(DuesLiability, Option<String>)> = shares
        .iter()
        .map(|(debtor_type, amount, liable_person)| {
            (
                DuesLiability {
                    id: String::new(),
                    unit_id: unit_id.clone(),
                    period: "Ocak 2031".to_string(),
                    delay_penalty: Decimal::ZERO,
                    total_amount: *amount,
                    principal_amount: *amount,
                    due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type: *debtor_type,
                    expense_type: ExpenseType::OperationalDues,
                    penalty_accrued_through: None,
                    grace_days: 0,
                    effective_due_date: Some(due_date),
                    liable_person_id: *liable_person,
                },
                None,
            )
        })
        .collect();
    db::commit_accrual_batch(
        &env.pool,
        &db::AccrualBatch {
            site_id: &env.site.to_string(),
            period_key: "2031-01",
            period_label: "Ocak 2031",
            due_date,
            source: "MANUAL",
            dues: &dues,
            skipped: &[],
        },
    )
    .await
    .expect("store the period's liabilities");

    let client = env.pool.get().await.expect("connection");
    let row = client
        .query_one(
            "SELECT count(*), COALESCE(SUM(principal_amount), 0)
               FROM dues_liabilities
              WHERE unit_id = $1 AND period = 'Ocak 2031' AND status <> 'CANCELLED'",
            &[&unit],
        )
        .await
        .expect("stored rows");
    assert_eq!(
        row.get::<_, i64>(0),
        2,
        "a silently dropped row would hide the loss"
    );
    assert_eq!(
        row.get::<_, Decimal>(1),
        tariff,
        "the period stores the whole tariff"
    );
    drop(client);
    env.drop_db().await;
}

// covers: SC-07-08-04
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn empty_accrual_with_skipped_units_still_records_a_run() {
    let env = Env::new("empty_skipped").await;
    let site_id = env.site.to_string();
    let period_key = "2099-03";
    let due_date = NaiveDate::from_ymd_opt(2099, 3, 15).expect("fixture date");
    let skipped = vec!["unit 123: no eligible tariff".to_string()];
    let batch = db::AccrualBatch {
        site_id: &site_id,
        period_key,
        period_label: period_key,
        due_date,
        source: "SCHEDULER",
        dues: &[],
        skipped: &skipped,
    };

    db::commit_accrual_batch(&env.pool, &batch)
        .await
        .expect("skipped-only accrual is recorded");

    let client = env.pool.get().await.expect("connection");
    let row = client
        .query_one(
            "SELECT accrued_count, skipped_units FROM dues_accrual_runs WHERE site_id = $1 AND period_key = $2",
            &[&env.site, &period_key],
        )
        .await
        .expect("skipped-only run exists");
    assert_eq!(row.get::<_, i32>(0), 0);
    assert_eq!(row.get::<_, Vec<String>>(1), skipped);
    drop(client);
    env.drop_db().await;
}

// covers: SC-07-08-03
#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn two_sites_accrue_in_a_row_each_with_its_own_period_row() {
    let env = Env::new("twosites").await;
    // The second site gets two units with a tariff of its own and an owner.
    env.exec(&format!(
        "WITH b AS (INSERT INTO blocks (site_id, block_name) VALUES ({site}, 'K Blok') RETURNING id),
              h AS (INSERT INTO house_types (site_id, type_name, dues_amount) VALUES ({site}, '2+1', 1100.00) ON CONFLICT (site_id, type_name) DO UPDATE SET dues_amount = EXCLUDED.dues_amount RETURNING id),
              p AS (INSERT INTO persons (site_id, full_name, email, person_type) VALUES ({site}, 'Owner K', 'owner_k{site}@tenant.test', 'HOME_OWNER') RETURNING id)
         INSERT INTO units (block_id, site_id, unit_number, floor, land_share, house_type, house_type_id, owner_person_id)
         SELECT b.id, {site}, n, 1, 1, '2+1', h.id, p.id FROM b, h, p, generate_series(1, 2) n",
        site = env.other_site
    ))
    .await;
    env.state.reload_from_db().await.expect("reload");
    for (token, site) in [
        (env.token.clone(), env.site),
        (env.other_token.clone(), env.other_site),
    ] {
        let (status, body) = env
            .call_as(
                &token,
                "POST",
                "/api/v1/dues/accrue-period",
                Some(json!({
                    "site_id": site.to_string(),
                    "period": "2026-10",
                    "due_date": "2026-10-15",
                })),
            )
            .await;
        assert_eq!(status, StatusCode::OK, "site {site}: {body}");
        assert!(
            body["newly_accrued_units_count"].as_i64().unwrap_or(0) > 0,
            "{body}"
        );
        let accrued_units = body["newly_accrued_units_count"].as_i64().unwrap_or(0);
        assert_eq!(
            env.int(&format!(
                "SELECT count(*) FROM dues_periods WHERE site_id = {site} AND period_key = '2026-10'"
            ))
            .await,
            1,
            "site {site} owns one independent period row"
        );
        assert_eq!(
            env.int(&format!(
                "SELECT count(*) FROM dues_liabilities dl
                 JOIN units u ON u.id = dl.unit_id
                 JOIN dues_periods dp ON dp.id = dl.dues_period_id
                 WHERE u.site_id = {site} AND dl.period_key = '2026-10'
                   AND dp.site_id = {site} AND dp.period_key = '2026-10'"
            ))
            .await,
            accrued_units,
            "all site {site} liabilities link to that site's period row"
        );
    }
    // A later period of the first site, after the second site took its first.
    let (status, body) = env.accrue("2026-11", "2026-11-15").await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let november_units = body["newly_accrued_units_count"].as_i64().unwrap_or(0);
    assert_eq!(
        env.int(
            "SELECT count(DISTINCT id) FROM dues_periods WHERE period_key IN ('2026-10','2026-11')"
        )
        .await,
        3
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_periods WHERE site_id = {} AND period_key = '2026-10'",
            env.other_site
        ))
        .await,
        1
    );
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities dl
             JOIN units u ON u.id = dl.unit_id
             JOIN dues_periods dp ON dp.id = dl.dues_period_id
             WHERE u.site_id = {} AND dl.period_key = '2026-11'
               AND dp.site_id = {} AND dp.period_key = '2026-11'",
            env.site, env.site
        ))
        .await,
        november_units,
        "the first site can accrue its own later period after the second site"
    );
    env.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn a_first_accrual_batch_keeps_both_debtor_shares_and_blocks_a_rerun() {
    let env = Env::new("shares").await;
    let unit = env
        .int(&format!(
            "SELECT id FROM units WHERE site_id = {} AND deleted_at IS NULL AND house_type_id IS NOT NULL ORDER BY id LIMIT 1",
            env.site
        ))
        .await;
    let site_id = env.site.to_string();
    let unit_id = unit.to_string();
    let period_key = "2099-01";
    let period_label = period_key;
    let due_date = NaiveDate::from_ymd_opt(2099, 1, 15).expect("fixture date");
    let dues: Vec<(DuesLiability, Option<String>)> = [DebtorType::Owner, DebtorType::Tenant]
        .into_iter()
        .map(|debtor_type| {
            let share = Decimal::from(600);
            (
                DuesLiability {
                    id: String::new(),
                    unit_id: unit_id.clone(),
                    period: period_label.to_string(),
                    principal_amount: share,
                    delay_penalty: Decimal::ZERO,
                    total_amount: share,
                    due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type,
                    expense_type: ExpenseType::OperationalDues,
                    penalty_accrued_through: None,
                    grace_days: 0,
                    effective_due_date: None,
                    liable_person_id: None,
                },
                None,
            )
        })
        .collect();
    let batch = db::AccrualBatch {
        site_id: &site_id,
        period_key,
        period_label,
        due_date,
        source: "SCHEDULER",
        dues: &dues,
        skipped: &[],
    };

    let first = db::commit_accrual_batch(&env.pool, &batch)
        .await
        .expect("first owner and tenant shares commit");
    assert_eq!(first.due_ids.len(), 2);
    assert!(first.due_ids.iter().all(Option::is_some));
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities WHERE unit_id = {unit} AND period_key = '{period_key}' AND capital_project_id IS NULL"
        ))
        .await,
        2
    );

    let rerun = db::commit_accrual_batch(&env.pool, &batch)
        .await
        .expect("an existing unit-period prevents a second accrual");
    assert_eq!(rerun.due_ids, vec![None, None]);
    assert_eq!(
        env.int(&format!(
            "SELECT count(*) FROM dues_liabilities WHERE unit_id = {unit} AND period_key = '{period_key}' AND capital_project_id IS NULL"
        ))
        .await,
        2
    );
    env.drop_db().await;
}

// covers: SC-05-02-01
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn concurrent_accruals_for_one_unit_commit_once_and_leave_no_duplicate_balance() {
    let env = Env::new("concurrent_unit").await;
    let unit = env.int(&format!(
        "SELECT id FROM units WHERE site_id = {} AND deleted_at IS NULL AND house_type_id IS NOT NULL ORDER BY id LIMIT 1",
        env.site
    )).await;
    let site_id = env.site.to_string();
    let unit_id = unit.to_string();
    let period_key = "2099-02";
    let due_date = NaiveDate::from_ymd_opt(2099, 2, 15).expect("fixture date");
    let dues = vec![(
        DuesLiability {
            id: String::new(),
            unit_id: unit_id.clone(),
            period: period_key.to_string(),
            principal_amount: Decimal::from(600),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from(600),
            due_date,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        },
        None,
    )];
    let batch = db::AccrualBatch {
        site_id: &site_id,
        period_key,
        period_label: period_key,
        due_date,
        source: "SCHEDULER",
        dues: &dues,
        skipped: &[],
    };
    let (first, second) = tokio::join!(
        db::commit_accrual_batch(&env.pool, &batch),
        db::commit_accrual_batch(&env.pool, &batch),
    );
    let outcomes = [
        first.expect("first transaction"),
        second.expect("second transaction"),
    ];
    assert_eq!(
        outcomes
            .iter()
            .filter(|o| o.due_ids.iter().any(Option::is_some))
            .count(),
        1,
        "exactly one transaction inserts the liability"
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|o| o.due_ids.iter().all(Option::is_none))
            .count(),
        1,
        "the conflicting transaction is rejected as a clean no-op"
    );
    assert_eq!(env.int(&format!(
        "SELECT count(*) FROM dues_liabilities WHERE unit_id = {unit} AND period_key = '{period_key}' AND capital_project_id IS NULL"
    )).await, 1, "the unit balance is represented once");
    assert_eq!(
        env.int(&format!(
        "SELECT count(*) FROM dues_accrual_runs WHERE site_id = {} AND period_key = '{period_key}'",
        env.site
    ))
        .await,
        1,
        "the site period has a single committed run"
    );
    env.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn joint_liability_owner_intervals_do_not_overlap_on_transfer_day_and_exclude_day_one_seller()
{
    let env = Env::new("joint_overlap").await;
    let unit = env
        .int(&format!(
            "SELECT id FROM units WHERE site_id = {} AND deleted_at IS NULL ORDER BY id LIMIT 1",
            env.site
        ))
        .await;

    // Create 3 persons to represent:
    // 1. Owner who sold on day 1 (2026-12-01) -> 0 days in Dec 2026
    // 2. Seller who owned from 2026-12-01 until 2026-12-15 (transferred on day 15) -> 14 days
    // 3. Buyer who acquired on 2026-12-15 -> 17 days
    let client = env.pool.get().await.expect("connection");
    let p1: i64 = client
        .query_one(
            "INSERT INTO persons (full_name, email, person_type, site_id) VALUES ('Day1 Seller', 'p1@test.local', 'HOME_OWNER', $1) RETURNING id",
            &[&env.site],
        )
        .await
        .expect("insert p1")
        .get(0);
    let p2: i64 = client
        .query_one(
            "INSERT INTO persons (full_name, email, person_type, site_id) VALUES ('Mid-Month Seller', 'p2@test.local', 'HOME_OWNER', $1) RETURNING id",
            &[&env.site],
        )
        .await
        .expect("insert p2")
        .get(0);
    let p3: i64 = client
        .query_one(
            "INSERT INTO persons (full_name, email, person_type, site_id) VALUES ('Mid-Month Buyer', 'p3@test.local', 'HOME_OWNER', $1) RETURNING id",
            &[&env.site],
        )
        .await
        .expect("insert p3")
        .get(0);

    // Set tenant on the unit
    client
        .execute(
            "UPDATE units SET tenant_person_id = $1, owner_person_id = $2 WHERE id = $3",
            &[&p1, &p3, &unit],
        )
        .await
        .expect("update unit");

    // Clear existing occupancies for this unit and insert tenant occupancy for p1
    client
        .execute("DELETE FROM unit_occupancies WHERE unit_id = $1", &[&unit])
        .await
        .expect("clear occupancies");
    client
        .execute(
            "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active)
             VALUES ($1, $2, 'TENANT', DATE '2026-12-01', TRUE)",
            &[&unit, &p1],
        )
        .await
        .expect("insert tenant occupancy");

    // Clear existing ownerships for this unit
    client
        .execute("DELETE FROM unit_ownerships WHERE unit_id = $1", &[&unit])
        .await
        .expect("clear ownerships");

    // Insert the 3 ownership records:
    // p1: start 2025-01-01, end 2026-12-01 (sold on day 1)
    // p2: start 2026-12-01, end 2026-12-15 (seller)
    // p3: start 2026-12-15, end NULL (buyer)
    client
        .execute(
            "INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, end_date, is_active)
             VALUES ($1, $2, 100.0, DATE '2025-01-01', DATE '2026-12-01', FALSE),
                    ($1, $3, 100.0, DATE '2026-12-01', DATE '2026-12-15', FALSE),
                    ($1, $4, 100.0, DATE '2026-12-15', NULL, TRUE)",
            &[&unit, &p1, &p2, &p3],
        )
        .await
        .expect("insert ownerships");

    let site_id = env.site.to_string();
    let unit_id = unit.to_string();
    let period_key = "2026-12";
    let period_label = "Aralık 2026";
    let due_date = NaiveDate::from_ymd_opt(2026, 12, 15).expect("fixture date");
    let dues = vec![(
        DuesLiability {
            id: String::new(),
            unit_id: unit_id.clone(),
            period: period_label.to_string(),
            principal_amount: Decimal::from(1000),
            delay_penalty: Decimal::ZERO,
            total_amount: Decimal::from(1000),
            due_date,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(p1),
        },
        None,
    )];
    let batch = db::AccrualBatch {
        site_id: &site_id,
        period_key,
        period_label,
        due_date,
        source: "SCHEDULER",
        dues: &dues,
        skipped: &[],
    };

    let result = db::commit_accrual_batch(&env.pool, &batch)
        .await
        .expect("commit accrual batch");
    assert_eq!(result.due_ids.len(), 1);
    let due_id = result.due_ids[0].expect("due created");

    let joint_owners = result
        .joint_owners
        .get(&due_id.to_string())
        .expect("joint owners found");

    // p1 (sold on day 1) must be completely excluded
    assert!(
        !joint_owners.iter().any(|o| o.person_id == p1),
        "Day 1 seller should not be included"
    );

    // Exactly p2 and p3 must be present
    assert_eq!(joint_owners.len(), 2, "Expected seller and buyer");

    let seller = joint_owners
        .iter()
        .find(|o| o.person_id == p2)
        .expect("seller");
    assert_eq!(
        seller.start_date,
        NaiveDate::from_ymd_opt(2026, 12, 1).unwrap()
    );
    assert_eq!(
        seller.end_date,
        Some(NaiveDate::from_ymd_opt(2026, 12, 14).unwrap())
    );

    let buyer = joint_owners
        .iter()
        .find(|o| o.person_id == p3)
        .expect("buyer");
    assert_eq!(
        buyer.start_date,
        NaiveDate::from_ymd_opt(2026, 12, 15).unwrap()
    );
    assert_eq!(
        buyer.end_date,
        Some(NaiveDate::from_ymd_opt(2026, 12, 31).unwrap())
    );

    // Also verify persistence in DB table dues_liability_joint_owners
    let rows = client
        .query(
            "SELECT owner_person_id, liable_from, liable_through FROM dues_liability_joint_owners WHERE due_id = $1 ORDER BY liable_from",
            &[&due_id],
        )
        .await
        .expect("query joint owners table");
    assert_eq!(rows.len(), 2);
    let r1_pid: i64 = rows[0].get(0);
    let r1_from: NaiveDate = rows[0].get(1);
    let r1_through: NaiveDate = rows[0].get(2);
    assert_eq!(r1_pid, p2);
    assert_eq!(r1_from, NaiveDate::from_ymd_opt(2026, 12, 1).unwrap());
    assert_eq!(r1_through, NaiveDate::from_ymd_opt(2026, 12, 14).unwrap());

    let r2_pid: i64 = rows[1].get(0);
    let r2_from: NaiveDate = rows[1].get(1);
    let r2_through: NaiveDate = rows[1].get(2);
    assert_eq!(r2_pid, p3);
    assert_eq!(r2_from, NaiveDate::from_ymd_opt(2026, 12, 15).unwrap());
    assert_eq!(r2_through, NaiveDate::from_ymd_opt(2026, 12, 31).unwrap());

    env.drop_db().await;
}
