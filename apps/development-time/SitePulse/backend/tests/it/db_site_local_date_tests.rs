//! PostgreSQL tests: date-dependent SQL takes the site-local date from the
//! injected `Clock` as a bound parameter, never the database session's
//! `CURRENT_DATE` (UTC). At 22:30 UTC Istanbul is already on the next day, so
//! the `OVERDUE` status and the closing end dates must use that date.
//!
//! They need PostgreSQL and `DB_PASS`; the verification gate `rust-db-test`
//! runs them:
//!
//! ```text
//! cargo nextest run --locked --profile db --test it -E 'test(/db_site_local_date_tests::/)' --run-ignored ignored-only
//! ```

use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::db;
use sitepulse_backend::domain::clock::Clock;

const SITE_TIMEZONE: &str = "Europe/Istanbul";

#[derive(Debug)]
struct FixedClock(DateTime<Utc>);

impl Clock for FixedClock {
    fn now(&self) -> DateTime<Utc> {
        self.0
    }
}

/// 2026-11-30 22:30 UTC is 2026-12-01 01:30 in Istanbul.
fn late_istanbul_evening() -> FixedClock {
    FixedClock(
        Utc.with_ymd_and_hms(2026, 11, 30, 22, 30, 0)
            .single()
            .expect("valid instant"),
    )
}

fn date(month: u32, day: u32) -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, month, day).expect("valid date")
}

async fn drop_db(database: crate::test_db::TestDatabase) {
    let crate::test_db::TestDatabase { name, admin, pool } = database;
    drop(pool);
    if let Ok(client) = admin.get().await {
        let _ = client
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await;
    }
}

/// Marks a seeded due as fully paid with `due_date`, reverses the payment and
/// returns the recomputed status.
async fn status_after_reversal(
    tx: &deadpool_postgres::Transaction<'_>,
    due_id: i64,
    due_date: NaiveDate,
    today: NaiveDate,
) -> String {
    let row = tx
        .query_one(
            "UPDATE dues_liabilities
             SET due_date = $2, effective_due_date = $2, paid_principal = principal_amount, paid_penalty = delay_penalty,
                 paid_amount = principal_amount + delay_penalty, status = 'PAID'
             WHERE id = $1
             RETURNING principal_amount, delay_penalty",
            &[&due_id, &due_date],
        )
        .await
        .expect("mark due paid");
    let principal: Decimal = row.get(0);
    let penalty: Decimal = row.get(1);
    db::tx_unsettle_due(tx, due_id, principal, penalty, today)
        .await
        .expect("unsettle due");
    tx.query_one(
        "SELECT status FROM dues_liabilities WHERE id = $1",
        &[&due_id],
    )
    .await
    .expect("read status")
    .get(0)
}

// covers: SC-13-05-19
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_a_payment_is_reversed_late_in_the_istanbul_evening_then_overdue_uses_the_istanbul_date(
) {
    let clock = late_istanbul_evening();
    let today = clock.today_in(SITE_TIMEZONE);
    assert_eq!(today, date(12, 1));
    assert_eq!(clock.now().date_naive(), date(11, 30));

    let database = crate::test_db::create("site_local_overdue").await;
    let mut client = database.pool.get().await.expect("connection");
    let tx = client.transaction().await.expect("transaction");
    let row = tx
        .query_one(
            "SELECT id, site_id FROM units WHERE deleted_at IS NULL ORDER BY id LIMIT 1",
            &[],
        )
        .await
        .expect("a seeded unit");
    let (unit_id, site_id): (i64, i64) = (row.get(0), row.get(1));
    db::tx_bind_tenant(&tx, site_id).await.expect("bind tenant");
    let due_id: i64 = tx
        .query_one(
            "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type)
             VALUES ($1, 'SITE-LOCAL-DATE', 100.00, $2, 'PENDING', 'OWNER') RETURNING id",
            &[&unit_id, &date(11, 30)],
        )
        .await
        .expect("insert due")
        .get(0);

    // Due on the UTC date: already matured on the Istanbul date.
    assert_eq!(
        status_after_reversal(&tx, due_id, date(11, 30), today).await,
        "OVERDUE"
    );
    // Due on the Istanbul date itself: not yet overdue.
    assert_eq!(
        status_after_reversal(&tx, due_id, date(12, 1), today).await,
        "PENDING"
    );

    tx.rollback().await.expect("rollback");
    drop(client);
    drop_db(database).await;
}

// covers: SC-13-05-19
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_a_unit_is_archived_late_in_the_istanbul_evening_then_end_dates_use_the_istanbul_date()
{
    let clock = late_istanbul_evening();
    let today = clock.today_in(SITE_TIMEZONE);

    let database = crate::test_db::create("site_local_end_date").await;
    let mut client = database.pool.get().await.expect("connection");
    let tx = client.transaction().await.expect("transaction");
    let row = tx
        .query_one(
            "SELECT o.unit_id, u.site_id FROM unit_occupancies o JOIN units u ON u.id = o.unit_id
             WHERE o.is_active
               AND EXISTS (SELECT 1 FROM unit_ownerships w WHERE w.unit_id = o.unit_id AND w.is_active)
             ORDER BY o.unit_id LIMIT 1",
            &[],
        )
        .await
        .expect("a seeded unit with an active occupancy and ownership");
    let (unit_id, site_id): (i64, i64) = (row.get(0), row.get(1));
    db::tx_bind_tenant(&tx, site_id).await.expect("bind tenant");
    for table in ["unit_occupancies", "unit_ownerships"] {
        tx.execute(
            &format!("UPDATE {table} SET start_date = $2 WHERE unit_id = $1 AND is_active"),
            &[&unit_id, &date(11, 1)],
        )
        .await
        .expect("pin start date");
    }

    db::tx_close_unit_history(&tx, unit_id, today)
        .await
        .expect("close unit history");

    for table in ["unit_occupancies", "unit_ownerships"] {
        let rows = tx
            .query(
                &format!(
                    "SELECT end_date FROM {table} WHERE unit_id = $1 AND start_date = $2 AND NOT is_active"
                ),
                &[&unit_id, &date(11, 1)],
            )
            .await
            .expect("read closed rows");
        assert!(!rows.is_empty(), "{table}: no row was closed");
        for row in rows {
            let end_date: Option<NaiveDate> = row.get(0);
            assert_eq!(end_date, Some(date(12, 1)), "{table} end date");
        }
    }

    tx.rollback().await.expect("rollback");
    drop(client);
    drop_db(database).await;
}

// covers: SC-13-05-19
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_payment_recorded_late_in_istanbul_evening_then_payment_history_principal_date_uses_istanbul_date(
) {
    let clock = late_istanbul_evening();
    let database = crate::test_db::create("site_local_payment_history").await;
    let mut client = database.pool.get().await.expect("connection");
    let tx = client.transaction().await.expect("transaction");
    let row = tx
        .query_one(
            "SELECT id, site_id FROM units WHERE deleted_at IS NULL ORDER BY id LIMIT 1",
            &[],
        )
        .await
        .expect("a seeded unit");
    let (unit_id, site_id): (i64, i64) = (row.get(0), row.get(1));
    db::tx_bind_tenant(&tx, site_id).await.expect("bind tenant");
    let due_id: i64 = tx
        .query_one(
            "INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type)
             VALUES ($1, 'SITE-LOCAL-PAYMENT', 100.00, $2, 'PENDING', 'OWNER') RETURNING id",
            &[&unit_id, &date(11, 30)],
        )
        .await
        .expect("insert due")
        .get(0);

    let late = clock.now();
    let pe_id: i64 = tx
        .query_one(
            "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status, payment_date, entry_type)
             VALUES ($1, $2, 'Test Resident', 'OWNER', 100.00, 'BANK_TRANSFER', 'SETTLED', $3, 'COLLECTION')
             RETURNING id",
            &[&site_id, &unit_id, &late],
        )
        .await
        .expect("insert payment entry")
        .get(0);

    tx.execute(
        "INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount)
         VALUES ($1, $2, 100.00, 0.00)",
        &[&pe_id, &due_id],
    )
    .await
    .expect("insert allocation");

    let history = db::tx_load_due_principal_payments(&tx, due_id)
        .await
        .expect("load principal payments");
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].0, date(12, 1));
    assert_ne!(history[0].0, late.date_naive());

    tx.rollback().await.expect("rollback");
    drop(client);
    drop_db(database).await;
}

// covers: SC-13-05-19
#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn when_payment_recorded_late_in_istanbul_evening_then_tx_load_payments_for_site_uses_istanbul_date(
) {
    let clock = late_istanbul_evening();
    let database = crate::test_db::create("site_local_load_payments").await;
    let client = database.pool.get().await.expect("connection");
    let row = client
        .query_one(
            "SELECT id, site_id FROM units WHERE deleted_at IS NULL ORDER BY id LIMIT 1",
            &[],
        )
        .await
        .expect("a seeded unit");
    let (unit_id, site_id): (i64, i64) = (row.get(0), row.get(1));

    let late = clock.now();
    let pe_id: i64 = client
        .query_one(
            "INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status, payment_date, entry_type)
             VALUES ($1, $2, 'Test Resident', 'OWNER', 100.00, 'BANK_TRANSFER', 'SETTLED', $3, 'COLLECTION')
             RETURNING id",
            &[&site_id, &unit_id, &late],
        )
        .await
        .expect("insert payment entry")
        .get(0);

    let payments_json = db::fetch_site_payments_from_db(&database.pool, Some(&site_id.to_string()))
        .await
        .expect("load payments");
    let payments = payments_json["payments"]
        .as_array()
        .expect("payments array");
    let pe = payments
        .iter()
        .find(|p| p["transaction_id"].as_str() == Some(&pe_id.to_string()))
        .expect("found payment");
    assert_eq!(pe["date"].as_str(), Some("2026-12-01"));
    assert_ne!(pe["date"].as_str(), Some("2026-11-30"));

    drop(client);
    drop_db(database).await;
}
