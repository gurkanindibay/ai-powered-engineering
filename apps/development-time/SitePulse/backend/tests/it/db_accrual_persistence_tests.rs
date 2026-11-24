//! PostgreSQL round trips for the EPIC-07 accrual migrations V38 and V40–V43.
//!
//! Each test creates a disposable database, binds every tenant write/read with
//! `tx_bind_tenant`, then verifies the records survive an application reload.
//! The `rust-db-test` harness gate runs this target with `--ignored`.

use chrono::{NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use sitepulse_backend::{
    db,
    models::{DecidePeriodReopen, RequestPeriodReopen, Role},
    services::{billing_period_service::BillingPeriodService, finance_common::Caller},
    state::AppState,
};

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
    site: i64,
    other_site: i64,
    unit: i64,
    due: i64,
    period: i64,
}

impl TestDb {
    async fn create(tag: &str) -> Self {
        let crate::test_db::TestDatabase { name, admin, pool } = crate::test_db::create(tag).await;
        let client = pool.get().await.expect("test connection");
        let row = client
            .query_one(
                "SELECT s.id, u.id
                   FROM sites s JOIN units u ON u.site_id=s.id AND u.deleted_at IS NULL
                  WHERE s.slug='begonya-sitesi' ORDER BY u.id LIMIT 1",
                &[],
            )
            .await
            .expect("seeded site and unit");
        let site: i64 = row.get(0);
        let unit: i64 = row.get(1);
        let other_site = client
            .query_one("SELECT id FROM sites WHERE slug='kardelen-rezidans'", &[])
            .await
            .expect("second seeded site")
            .get(0);
        let period = client
            .query_one(
                "INSERT INTO dues_periods (site_id,period_name,due_date,status,period_key)
                 VALUES ($1,'November 2026',DATE '2026-11-15','ACTIVE','2026-11') RETURNING id",
                &[&site],
            )
            .await
            .expect("create active test period")
            .get(0);
        let due = client
            .query_one(
                "INSERT INTO dues_liabilities
                    (unit_id,period,debtor_type,expense_type,principal_amount,due_date,status,period_key,dues_period_id)
                 VALUES ($1,'November 2026','OWNER','OPERATIONAL_DUES',100.00,DATE '2026-11-15','PENDING','2026-11',$2)
                 RETURNING id",
                &[&unit, &period],
            )
            .await
            .expect("create test liability")
            .get(0);
        Self {
            name,
            admin,
            pool,
            site,
            other_site,
            unit,
            due,
            period,
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
}

async fn begin_tenant_tx<'a>(
    client: &'a mut deadpool_postgres::Object,
    site: i64,
) -> deadpool_postgres::Transaction<'a> {
    let tx = client
        .transaction()
        .await
        .expect("start tenant transaction");
    db::tx_bind_tenant(&tx, site)
        .await
        .expect("bind tenant RLS");
    tx
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn v38_corrections_and_v41_reevaluation_adjustments_round_trip_with_rls() {
    let db = TestDb::create("correction").await;
    let mut client = db.pool.get().await.expect("test connection");
    let tx = begin_tenant_tx(&mut client, db.site).await;
    let correction: i64 = tx.query_one(
        "INSERT INTO accrual_corrections
            (site_id,unit_id,due_id,period,debtor_type,kind,amount,reason,requested_by,requested_at,status)
         SELECT $1,$2,$3,'2026-11','OWNER','CREDIT_NOTE',10.00,'persistence check','requester',$4,'PENDING'
         RETURNING id",
        &[&db.site, &db.unit, &db.due, &Utc::now()],
    ).await.expect("insert correction").get(0);
    let adjustment: i64 = tx.query_one(
        "INSERT INTO ledger_adjustments
            (site_id,unit_id,due_id,kind,amount,reason,source,requested_by,requested_at,status,decided_by,decided_at)
         VALUES ($1,$2,$3,'PENALTY_REEVALUATION',1.00,'reevaluation test','PAYMENT_DATE','system',$4,'APPROVED','approver',$4)
         RETURNING id",
        &[&db.site, &db.unit, &db.due, &Utc::now()],
    ).await.expect("V41 adjustment constraint accepts new kind and source").get(0);
    tx.commit().await.expect("commit accrual rows");

    let mut client = db.pool.get().await.expect("second-site connection");
    let tx = begin_tenant_tx(&mut client, db.other_site).await;
    let rows: i64 = tx
        .query_one(
            "SELECT count(*) FROM accrual_corrections WHERE id=$1",
            &[&correction],
        )
        .await
        .expect("RLS correction read")
        .get(0);
    let adjustments: i64 = tx
        .query_one(
            "SELECT count(*) FROM ledger_adjustments WHERE id=$1",
            &[&adjustment],
        )
        .await
        .expect("RLS adjustment read")
        .get(0);
    assert_eq!(
        (rows, adjustments),
        (0, 0),
        "a second site cannot read either row"
    );
    tx.commit().await.expect("finish second-site read");

    let mut client = db.pool.get().await.expect("reload connection");
    let tx = begin_tenant_tx(&mut client, db.site).await;
    let correction_status: String = tx
        .query_one(
            "SELECT status FROM accrual_corrections WHERE id=$1",
            &[&correction],
        )
        .await
        .expect("read correction after reconnect")
        .get(0);
    let adjustment_kind: String = tx
        .query_one(
            "SELECT kind FROM ledger_adjustments WHERE id=$1",
            &[&adjustment],
        )
        .await
        .expect("read adjustment after reconnect")
        .get(0);
    assert_eq!(correction_status, "PENDING");
    assert_eq!(adjustment_kind, "PENALTY_REEVALUATION");
    tx.commit().await.expect("finish reload read");
    let reloaded = AppState::with_pool(Some(db.pool.clone()));
    reloaded
        .reload_from_db()
        .await
        .expect("reload corrections and adjustments");
    {
        let inner = reloaded.inner.read().await;
        assert!(inner
            .finance
            .corrections
            .iter()
            .any(|row| row.id == correction));
        assert!(inner
            .finance
            .adjustments
            .iter()
            .any(|row| row.id == adjustment));
    }
    db.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn v40_late_fee_rows_and_v42_schedule_survive_database_reload() {
    let db = TestDb::create("schedule").await;
    let date = NaiveDate::from_ymd_opt(2026, 11, 19).expect("valid fixture date");
    let mut client = db.pool.get().await.expect("test connection");
    let tx = begin_tenant_tx(&mut client, db.site).await;
    tx.execute(
        "UPDATE sites SET accrual_day=5,due_day=20,grace_days=7,catch_up_limit_months=9,go_live_date=$2 WHERE id=$1",
        &[&db.site, &date],
    ).await.expect("persist schedule");
    tx.execute(
        "UPDATE dues_liabilities SET grace_days=7 WHERE id=$1",
        &[&db.due],
    )
    .await
    .expect("persist liability grace");
    let late_fee: i64 = tx.query_one(
        "INSERT INTO late_fee_accruals (site_id,due_id,accrual_date,outstanding_principal,segment_start,segment_base,cumulative_fee,daily_amount)
         VALUES ($1,$2,$3,100.00,$3,0.00,1.00,0.10) RETURNING id",
        &[&db.site, &db.due, &date],
    ).await.expect("persist daily late fee").get(0);
    tx.commit().await.expect("commit fee and grace");

    let reloaded = AppState::with_pool(Some(db.pool.clone()));
    reloaded
        .reload_from_db()
        .await
        .expect("reload persisted state");
    {
        let inner = reloaded.inner.read().await;
        let schedule = inner
            .site_accrual_schedules
            .get(&db.site.to_string())
            .expect("schedule restored after reload");
        assert_eq!(schedule.accrual_day, 5);
        assert_eq!(schedule.due_day, 20);
        assert_eq!(schedule.grace_days, 7);
        assert_eq!(schedule.catch_up_limit_months, 9);
        assert_eq!(schedule.go_live_date, Some(date));
        assert!(inner
            .finance
            .late_fee_accruals
            .iter()
            .any(|row| row.id == late_fee));
    }
    let mut client = db.pool.get().await.expect("readback connection");
    let tx = begin_tenant_tx(&mut client, db.site).await;
    let row = tx.query_one(
        "SELECT s.accrual_day,s.due_day,s.grace_days,s.catch_up_limit_months,s.go_live_date,d.grace_days,l.cumulative_fee
           FROM sites s JOIN dues_liabilities d ON d.unit_id=$2 JOIN late_fee_accruals l ON l.id=$3
          WHERE s.id=$1 AND d.id=$4",
        &[&db.site, &db.unit, &late_fee, &db.due],
    ).await.expect("read back schedule, grace and late fee");
    assert_eq!(row.get::<_, i16>(0), 5);
    assert_eq!(row.get::<_, i16>(1), 20);
    assert_eq!(row.get::<_, i16>(2), 7);
    assert_eq!(row.get::<_, i16>(3), 9);
    assert_eq!(row.get::<_, NaiveDate>(4), date);
    assert_eq!(row.get::<_, i32>(5), 7);
    assert_eq!(row.get::<_, Decimal>(6), Decimal::ONE);
    tx.commit().await.expect("finish tenant readback");

    let mut client = db.pool.get().await.expect("second-site connection");
    let tx = begin_tenant_tx(&mut client, db.other_site).await;
    let hidden: i64 = tx
        .query_one(
            "SELECT count(*) FROM late_fee_accruals WHERE id=$1",
            &[&late_fee],
        )
        .await
        .expect("RLS late-fee read")
        .get(0);
    assert_eq!(hidden, 0, "second site cannot read the late-fee row");
    tx.commit().await.expect("finish second-site read");
    db.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn v43_period_close_snapshot_and_four_eyes_reopen_round_trip_with_rls() {
    let db = TestDb::create("period").await;
    let state = AppState::with_pool(Some(db.pool.clone()));
    state.reload_from_db().await.expect("load period state");
    let caller = Caller {
        site_id: db.site.to_string(),
        user_id: "requester".to_string(),
        email: "requester@sitepulse.test".to_string(),
        role: Role::SiteManager,
        unit_id: None,
    };
    let service = BillingPeriodService::new(&state);
    let snapshot = service
        .close(&caller, &db.period.to_string(), "pg-close")
        .await
        .expect("close period");
    assert_eq!(snapshot.period_id, db.period.to_string());
    let request = service
        .request_reopen(
            &caller,
            &db.period.to_string(),
            RequestPeriodReopen {
                reason: "database verification".to_string(),
            },
            "pg-reopen",
        )
        .await
        .expect("request reopen");
    let checker = Caller {
        user_id: "checker".to_string(),
        email: "checker@sitepulse.test".to_string(),
        ..caller.clone()
    };
    service
        .decide_reopen(
            &checker,
            &request.id,
            DecidePeriodReopen {
                approve: true,
                decision_note: Some("approved".to_string()),
            },
            "pg-decision",
        )
        .await
        .expect("approve reopen");

    let mut client = db.pool.get().await.expect("site read connection");
    let tx = begin_tenant_tx(&mut client, db.site).await;
    let status: String = tx
        .query_one("SELECT status FROM dues_periods WHERE id=$1", &[&db.period])
        .await
        .expect("read reopened period")
        .get(0);
    let snapshot_count: i64 = tx
        .query_one(
            "SELECT count(*) FROM dues_period_snapshots WHERE period_id=$1",
            &[&db.period],
        )
        .await
        .expect("read snapshot")
        .get(0);
    let reopen_status: String = tx
        .query_one(
            "SELECT status FROM dues_period_reopen_requests WHERE id=$1",
            &[&request.id.parse::<i64>().expect("request id")],
        )
        .await
        .expect("read decision")
        .get(0);
    assert_eq!(status, "OPEN");
    assert_eq!(snapshot_count, 1);
    assert_eq!(reopen_status, "APPROVED");
    tx.commit().await.expect("finish site read");
    let mut client = db.pool.get().await.expect("other-site connection");
    let tx = begin_tenant_tx(&mut client, db.other_site).await;
    let hidden: i64 = tx
        .query_one(
            "SELECT count(*) FROM dues_period_snapshots WHERE period_id=$1",
            &[&db.period],
        )
        .await
        .expect("RLS snapshot read")
        .get(0);
    assert_eq!(hidden, 0, "second site cannot read snapshot");
    let hidden_requests: i64 = tx
        .query_one(
            "SELECT count(*) FROM dues_period_reopen_requests WHERE id=$1",
            &[&request.id.parse::<i64>().expect("request id")],
        )
        .await
        .expect("RLS reopen-request read")
        .get(0);
    assert_eq!(hidden_requests, 0, "second site cannot read reopen request");
    tx.commit().await.expect("finish other-site read");
    db.drop_db().await;
}
