//! PostgreSQL system coverage for advance exit settlement decisions.
//!
//! Run with `cargo test --test db_advance_exit_settlements_tests -- --ignored --test-threads=1`.

use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use sitepulse_backend::{
    db,
    models::{CreateAdvanceExitSettlementRequest, DecideAdvanceExitSettlementRequest},
    services::{
        advance_exit_settlement_service::AdvanceExitSettlementService,
        finance_common::{Caller, FinanceError},
    },
    state::AppState,
};

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
}

impl TestDb {
    async fn create() -> Self {
        let admin =
            db::create_pool_for("postgres").expect("DB_PASS is required for PostgreSQL tests");
        let name = format!("sp_exit_{}", std::process::id());
        let client = admin.get().await.expect("admin connection");
        client
            .batch_execute(&format!(
                "DROP DATABASE IF EXISTS {name} WITH (FORCE); CREATE DATABASE {name};"
            ))
            .await
            .expect("create throwaway database");
        drop(client);
        let pool = db::create_pool_for(&name).expect("test database pool");
        db::init_db(&pool).await.expect("apply migrations");
        db::seed_test_data(&pool).await.expect("seed test data");
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

    async fn seed_advance(&self, unit_id: i64, debtor: &str, amount: Decimal) {
        let client = self.pool.get().await.expect("test connection");
        client
            .batch_execute("SET sitepulse.allow_ledger_purge = 'on'")
            .await
            .expect("enable test cleanup");
        client
            .execute(
                "DELETE FROM advance_ledger_entries WHERE unit_id = $1 AND debtor_type = $2",
                &[&unit_id, &debtor],
            )
            .await
            .expect("clear test advance ledger");
        client
            .execute(
                "INSERT INTO advance_balances (unit_id, debtor_type, balance) VALUES ($1, $2, $3)
                 ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance",
                &[&unit_id, &debtor, &amount],
            )
            .await
            .expect("seed advance balance");
        if amount > Decimal::ZERO {
            client
                .execute(
                    "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description)
                     VALUES ($1, $2, 'PAYMENT_SURPLUS', $3, 'Test seed')",
                    &[&unit_id, &debtor, &amount],
                )
                .await
                .expect("seed append-only ledger");
        }
    }

    async fn unit(&self) -> (i64, String) {
        let row = self
            .pool
            .get()
            .await
            .expect("test connection")
            .query_one(
                "SELECT u.id, u.site_id::text
                   FROM units u JOIN blocks b ON b.id = u.block_id JOIN sites s ON s.id = u.site_id
                  WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok' AND u.unit_number = 14",
                &[],
            )
            .await
            .expect("seed unit");
        (row.get(0), row.get(1))
    }
}

fn caller(site_id: &str, user_id: &str) -> Caller {
    Caller {
        site_id: site_id.to_string(),
        user_id: user_id.to_string(),
        email: format!("{user_id}@sitepulse.test"),
        role: sitepulse_backend::models::Role::SiteManager,
        unit_id: None,
    }
}

fn request(
    kind: &str,
    source: &str,
    target: Option<&str>,
    amount: Decimal,
) -> CreateAdvanceExitSettlementRequest {
    CreateAdvanceExitSettlementRequest {
        request_key: format!(
            "{}-{}-{}-{}",
            kind,
            source,
            target.unwrap_or("none"),
            amount
        ),
        kind: kind.to_string(),
        source_debtor: source.to_string(),
        target_debtor: target.map(str::to_string),
        amount,
        beneficiary_name: "Departing Resident".to_string(),
        beneficiary_person_id: None,
        note: Some("Move-out settlement".to_string()),
    }
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
async fn exit_settlement_payout_transfer_and_stale_balance_are_atomic() {
    let db = TestDb::create().await;
    let (unit, site_id) = db.unit().await;
    let amount = Decimal::new(10000, 2);
    db.seed_advance(unit, "TENANT", amount).await;
    db.seed_advance(unit, "OWNER", amount).await;
    let state = AppState::with_pool(Some(db.pool.clone()));
    let service = AdvanceExitSettlementService::new(&state);
    let requester = caller(&site_id, "requester");
    let checker = caller(&site_id, "checker");

    let owner_id: i64 = db
        .pool
        .get()
        .await
        .expect("test connection")
        .query_one("SELECT owner_person_id FROM units WHERE id = $1", &[&unit])
        .await
        .expect("seeded owner")
        .get(0);
    let mut unrelated_tenant = request("PAYOUT", "TENANT", None, Decimal::new(100, 2));
    unrelated_tenant.beneficiary_person_id = Some(owner_id.to_string());
    assert!(matches!(
        service
            .create(&requester, &unit.to_string(), unrelated_tenant)
            .await,
        Err(FinanceError::NotFound(_))
    ));

    let payout_request = request("PAYOUT", "TENANT", None, Decimal::new(4000, 2));
    let payout = service
        .create(&requester, &unit.to_string(), payout_request.clone())
        .await
        .expect("create payout request");
    let retried_payout = service
        .create(&requester, &unit.to_string(), payout_request)
        .await
        .expect("idempotent retry returns the original request");
    assert_eq!(retried_payout.id, payout.id);
    let mut changed_payload = request("PAYOUT", "TENANT", None, Decimal::new(5000, 2));
    changed_payload.request_key = retried_payout.request_key.clone();
    assert!(matches!(
        service
            .create(&requester, &unit.to_string(), changed_payload)
            .await,
        Err(FinanceError::Conflict(_))
    ));
    let self_approval = service
        .decide(
            &requester,
            payout.id,
            DecideAdvanceExitSettlementRequest {
                approve: true,
                payment_reference: Some("bank-ref-001".to_string()),
                note: None,
            },
        )
        .await;
    assert!(matches!(self_approval, Err(FinanceError::Forbidden(_))));
    let paid = service
        .decide(
            &checker,
            payout.id,
            DecideAdvanceExitSettlementRequest {
                approve: true,
                payment_reference: Some("bank-ref-001".to_string()),
                note: None,
            },
        )
        .await
        .expect("approve payout");
    assert_eq!(paid.status, "APPROVED");
    assert_eq!(paid.beneficiary_name, "Departing Resident");
    let client = db.pool.get().await.expect("test connection");
    let disbursement_count: i64 = client
        .query_one(
            "SELECT COUNT(*) FROM advance_exit_disbursements WHERE settlement_id = $1",
            &[&payout.id],
        )
        .await
        .expect("read disbursement")
        .get(0);
    let tenant_balance: Decimal = client
        .query_one(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = 'TENANT'",
            &[&unit],
        )
        .await
        .expect("read tenant balance")
        .get(0);
    assert_eq!(disbursement_count, 1);
    assert_eq!(tenant_balance, Decimal::new(6000, 2));
    assert!(matches!(
        service
            .decide(
                &checker,
                payout.id,
                DecideAdvanceExitSettlementRequest {
                    approve: true,
                    payment_reference: Some("bank-ref-001".into()),
                    note: None
                },
            )
            .await,
        Err(FinanceError::Conflict(_))
    ));
    drop(client);

    let transfer = service
        .create(
            &requester,
            &unit.to_string(),
            request("TRANSFER", "TENANT", Some("OWNER"), Decimal::new(2000, 2)),
        )
        .await
        .expect("create transfer request");
    service
        .decide(
            &checker,
            transfer.id,
            DecideAdvanceExitSettlementRequest {
                approve: true,
                payment_reference: None,
                note: None,
            },
        )
        .await
        .expect("approve transfer");
    let client = db.pool.get().await.expect("test connection");
    let tenant_balance: Decimal = client
        .query_one(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = 'TENANT'",
            &[&unit],
        )
        .await
        .expect("read transferred tenant balance")
        .get(0);
    let owner_balance: Decimal = client
        .query_one(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = 'OWNER'",
            &[&unit],
        )
        .await
        .expect("read transferred owner balance")
        .get(0);
    assert_eq!(tenant_balance, Decimal::new(4000, 2));
    assert_eq!(owner_balance, Decimal::new(12000, 2));
    let exit_transfer_entries: i64 = client
        .query_one(
            "SELECT COUNT(*) FROM advance_ledger_entries WHERE reference_id = $1 AND entry_type IN ('EXIT_TRANSFER_DEBIT', 'EXIT_TRANSFER_CREDIT')",
            &[&format!("EXIT-SETTLEMENT-{}", transfer.id)],
        )
        .await
        .expect("read transfer ledger")
        .get(0);
    assert_eq!(exit_transfer_entries, 2);
    drop(client);

    let stale = service
        .create(
            &requester,
            &unit.to_string(),
            request("PAYOUT", "TENANT", None, Decimal::new(3000, 2)),
        )
        .await
        .expect("create request before external balance change");
    let client = db.pool.get().await.expect("test connection");
    client
        .execute(
            "UPDATE advance_balances SET balance = $2 WHERE unit_id = $1 AND debtor_type = 'TENANT'",
            &[&unit, &Decimal::new(1000, 2)],
        )
        .await
        .expect("simulate advance spent elsewhere");
    client
        .execute(
            "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description)
             VALUES ($1, 'TENANT', 'ADJUSTMENT_DEBIT', $2, 'Simulated external spend')",
            &[&unit, &Decimal::new(3000, 2)],
        )
        .await
        .expect("record simulated external spend");
    drop(client);
    assert!(matches!(
        service
            .decide(
                &checker,
                stale.id,
                DecideAdvanceExitSettlementRequest {
                    approve: true,
                    payment_reference: Some("bank-ref-002".into()),
                    note: None
                },
            )
            .await,
        Err(FinanceError::Conflict(_))
    ));
    let pending = service
        .list(&checker)
        .await
        .expect("list site settlements")
        .into_iter()
        .find(|item| item.id == stale.id)
        .expect("stale settlement remains");
    assert_eq!(pending.status, "PENDING");

    db.drop_db().await;
}
