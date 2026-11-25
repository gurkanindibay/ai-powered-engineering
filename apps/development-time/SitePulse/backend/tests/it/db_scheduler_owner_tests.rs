//! PostgreSQL coverage for who the scheduled accrual treats as a unit's titled owner.
//!
//! Run with `cargo nextest run --locked --profile db --test it -E 'test(/db_scheduler_owner_tests::/)' --run-ignored ignored-only`.

use chrono::{TimeZone, Utc};
use sitepulse_backend::{scheduler::run_accrual_with_report, state::AppState};

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-13-01-08
async fn scheduled_accrual_reads_unit_ownership_from_the_database() {
    let crate::test_db::TestDatabase { name, admin, pool } =
        crate::test_db::create("scheduler_owner").await;
    let client = pool.get().await.expect("test connection");
    let rows = client
        .query(
            "SELECT u.id, u.site_id FROM units u JOIN blocks b ON b.id = u.block_id
               JOIN sites s ON s.id = u.site_id
              WHERE s.slug = 'begonya-sitesi' AND u.owner_person_id IS NOT NULL
                AND u.deleted_at IS NULL
              ORDER BY u.id LIMIT 2",
            &[],
        )
        .await
        .expect("seed units");
    assert_eq!(rows.len(), 2, "the seed has two owned units");
    let owned: i64 = rows[0].get(0);
    let ownerless: i64 = rows[1].get(0);
    let site: i64 = rows[0].get(1);
    client
        .execute(
            "UPDATE sites SET proration_enabled = TRUE WHERE id = $1",
            &[&site],
        )
        .await
        .expect("enable proration");

    let state = AppState::with_pool(Some(pool.clone()));
    state.reload_from_db().await.expect("load the read model");
    // The read model can lag the units table: `owned` got its owner after the load,
    // and `ownerless` lost its owner after the load.
    {
        let mut inner = state.inner.write().await;
        for unit in inner.units.iter_mut() {
            if unit.id == owned.to_string() {
                unit.owner_user_id = None;
            }
        }
    }
    client
        .execute(
            "UPDATE units SET owner_person_id = NULL WHERE id = $1",
            &[&ownerless],
        )
        .await
        .expect("remove the title");

    let report =
        run_accrual_with_report(&state, Utc.with_ymd_and_hms(2031, 1, 2, 9, 0, 0).unwrap()).await;

    let (charged_owned, charged_ownerless): (i64, i64) = {
        let row = client
            .query_one(
                "SELECT COUNT(*) FILTER (WHERE unit_id = $1), COUNT(*) FILTER (WHERE unit_id = $2)
                   FROM dues_liabilities WHERE due_date >= DATE '2030-01-01'",
                &[&owned, &ownerless],
            )
            .await
            .expect("count accrued liabilities");
        (row.get(0), row.get(1))
    };

    drop(client);
    drop(state);
    drop(pool);
    if let Ok(client) = admin.get().await {
        let _ = client
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await;
    }

    assert!(
        charged_owned > 0,
        "a unit the database says is owned must be charged: {} liabilities accrued",
        report.liabilities()
    );
    assert_eq!(
        charged_ownerless, 0,
        "a unit the database says has no owner must not be charged"
    );
}
