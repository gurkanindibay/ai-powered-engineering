//! PostgreSQL system coverage for advance exit settlement decisions.
//!
//! Run with `cargo nextest run --locked --profile db --test it -E 'test(/db_advance_exit_settlements_tests::/)' --run-ignored ignored-only --test-threads 4`.

use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use sitepulse_backend::{
    models::{
        CreateAdvanceExitSettlementRequest, DebtorType, DecideAdvanceExitSettlementRequest,
        IndependentUnit, PaymentChannel, RecordManualPaymentRequest,
    },
    services::{
        advance_exit_settlement_service::AdvanceExitSettlementService,
        finance_common::{Caller, FinanceError},
        PaymentTrackingService,
    },
    state::AppState,
};

/// Today in the site's time zone, the date every service works with.
fn site_today() -> chrono::NaiveDate {
    crate::support::site_today()
}

struct TestDb {
    name: String,
    admin: Pool,
    owner: Pool,
    pool: Pool,
}

impl TestDb {
    async fn create() -> Self {
        let crate::test_db::TestDatabase {
            name,
            admin,
            owner,
            pool,
        } = crate::test_db::create("advance_exit").await;
        Self {
            name,
            admin,
            owner,
            pool,
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

    async fn seed_advance(&self, unit_id: i64, debtor: &str, amount: Decimal) {
        let client = self.owner.get().await.expect("test connection");
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

    /// Seeds a seller advance that has already left the unit's role bucket for a
    /// person-scoped hold, with the same ledger entries a title transfer writes.
    async fn seed_hold(&self, unit_id: i64, person_id: i64, debtor: &str, amount: Decimal) {
        self.seed_advance(unit_id, debtor, amount).await;
        let client = self.owner.get().await.expect("test connection");
        client
            .batch_execute("SET sitepulse.allow_ledger_purge = 'on'")
            .await
            .expect("enable test cleanup");
        client
            .execute(
                "DELETE FROM person_advance_holds WHERE unit_id = $1 AND debtor_type = $2",
                &[&unit_id, &debtor],
            )
            .await
            .expect("clear test advance hold");
        if amount > Decimal::ZERO {
            client
                .execute(
                    "INSERT INTO person_advance_holds
                        (site_id, unit_id, person_id, debtor_type, balance)
                     SELECT site_id, id, $2, $3, $4 FROM units WHERE id = $1",
                    &[&unit_id, &person_id, &debtor, &amount],
                )
                .await
                .expect("seed person advance hold");
            client
                .execute(
                    "INSERT INTO advance_ledger_entries
                        (unit_id, debtor_type, person_id, entry_type, amount, description)
                     VALUES ($1, $2, $3, 'TITLE_TRANSFER_HOLD', $4, 'Test: seller advance held')",
                    &[&unit_id, &debtor, &person_id, &amount],
                )
                .await
                .expect("seed hold ledger");
            client
                .execute(
                    "UPDATE advance_balances SET balance = 0 WHERE unit_id = $1 AND debtor_type = $2",
                    &[&unit_id, &debtor],
                )
                .await
                .expect("empty the role bucket");
            client
                .execute(
                    "INSERT INTO advance_ledger_entries
                        (unit_id, debtor_type, entry_type, amount, description)
                     VALUES ($1, $2, 'TITLE_TRANSFER_DEBIT', $3, 'Test: role bucket handed over')",
                    &[&unit_id, &debtor, &amount],
                )
                .await
                .expect("seed role-bucket ledger");
        }
    }

    async fn unit(&self) -> (i64, String) {
        let row = self
            .owner
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

    async fn departing_tenant(&self, unit_id: i64, site_id: &str, debt: Decimal) -> i64 {
        let client = self.owner.get().await.expect("test connection");
        let site_id = site_id.parse::<i64>().expect("numeric site id");
        let person_id: i64 = client
            .query_one(
                "INSERT INTO persons (site_id, full_name, person_type)
                 VALUES ($1, 'Exit Settlement Test Tenant', 'HOME_RESIDENT') RETURNING id",
                &[&site_id],
            )
            .await
            .expect("create test tenant")
            .get(0);
        let occupancy_id: i64 = client
            .query_one(
                "INSERT INTO unit_occupancies
                    (unit_id, person_id, occupancy_type, start_date, end_date, is_active, exit_balance)
                 VALUES ($1, $2, 'TENANT', CURRENT_DATE - 30, CURRENT_DATE - 1, FALSE, $3)
                 RETURNING id",
                &[&unit_id, &person_id, &debt],
            )
            .await
            .expect("create closed test occupancy")
            .get(0);
        if debt > Decimal::ZERO {
            client
                .execute(
                    "INSERT INTO dues_liabilities
                        (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id,
                         principal_amount, due_date, status)
                     VALUES ($1, 'Exit settlement test', 'TENANT', 'OPERATIONAL_DUES', $2, $3,
                             $4, CURRENT_DATE - 1, 'PENDING')",
                    &[&unit_id, &person_id, &occupancy_id, &debt],
                )
                .await
                .expect("create frozen exit due");
        }
        person_id
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
        beneficiary_person_id: Some("1".to_string()),
        note: Some("Move-out settlement".to_string()),
    }
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-09-05-03, SC-09-05-04, SC-09-05-05, SC-09-05-06
async fn exit_settlement_payout_transfer_and_stale_balance_are_atomic() {
    let db = TestDb::create().await;
    let (unit, site_id) = db.unit().await;
    let amount = Decimal::new(10000, 2);
    db.seed_advance(unit, "TENANT", amount).await;
    db.seed_advance(unit, "OWNER", amount).await;
    let state = AppState::with_pool(Some(db.pool.clone()));
    {
        let mut inner = state.inner.write().await;
        inner.adjust_advance(&unit.to_string(), "TENANT", amount);
        inner.adjust_advance(&unit.to_string(), "OWNER", amount);
    }
    let service = AdvanceExitSettlementService::new(&state);
    let requester = caller(&site_id, "requester");
    let checker = caller(&site_id, "checker");

    let owner_id: i64 = db
        .owner
        .get()
        .await
        .expect("test connection")
        .query_one("SELECT owner_person_id FROM units WHERE id = $1", &[&unit])
        .await
        .expect("seeded owner")
        .get(0);
    let indebted_tenant = db
        .departing_tenant(unit, &site_id, Decimal::new(30000, 2))
        .await;
    let mut blocked_request = request("PAYOUT", "TENANT", None, Decimal::new(100, 2));
    blocked_request.beneficiary_person_id = Some(indebted_tenant.to_string());
    assert!(matches!(
        service
            .create(&requester, &unit.to_string(), blocked_request)
            .await,
        Err(FinanceError::Conflict(_))
    ));
    state
        .reload_from_db()
        .await
        .expect("load the frozen exit debt for the normal collection service");
    let liability_id: String = db
        .owner
        .get()
        .await
        .expect("test connection")
        .query_one(
            "SELECT id::text FROM dues_liabilities WHERE liable_person_id = $1 ORDER BY id DESC LIMIT 1",
            &[&indebted_tenant],
        )
        .await
        .expect("frozen exit liability")
        .get(0);
    let payment_amount = {
        let inner = state.inner.read().await;
        let liability = inner
            .dues
            .iter()
            .find(|due| due.id == liability_id)
            .cloned()
            .expect("frozen liability in read model");
        sitepulse_backend::services::DuesCalculationService::new()
            .calculate_delay_penalty(liability, site_today())
            .total_amount
    };
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(site_id.clone()),
            unit_id: unit.to_string(),
            amount: payment_amount,
            payer_name: "Exit Settlement Test Tenant".to_string(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::BankTransfer,
            ..Default::default()
        })
        .await
        .expect("pay frozen exit debt through normal collection");
    let mut unblocked_request = request("PAYOUT", "TENANT", None, Decimal::new(100, 2));
    unblocked_request.beneficiary_person_id = Some(indebted_tenant.to_string());
    let unblocked = service
        .create(&requester, &unit.to_string(), unblocked_request)
        .await
        .expect("allow settlement after the frozen debt is paid");
    assert_eq!(unblocked.status, "PENDING");
    let tenant_balance: Decimal = db
        .owner
        .get()
        .await
        .expect("test connection")
        .query_one(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = 'TENANT'",
            &[&unit],
        )
        .await
        .expect("tenant advance remains available")
        .get(0);
    assert_eq!(tenant_balance, amount);
    service
        .decide(
            &checker,
            unblocked.id,
            DecideAdvanceExitSettlementRequest {
                approve: false,
                payment_reference: None,
                note: Some("Release the reservation for the remaining assertions".to_string()),
            },
        )
        .await
        .expect("reject the second request and release its reservation");
    let tenant_id = db.departing_tenant(unit, &site_id, Decimal::ZERO).await;
    {
        let mut inner = state.inner.write().await;
        inner.reserve_exit_advance(&unit.to_string(), "TENANT", Decimal::new(5000, 2));
        assert_eq!(
            inner.available_advance_of(&unit.to_string(), "TENANT"),
            Decimal::new(5000, 2)
        );
        inner.release_exit_advance_reservation(&unit.to_string(), "TENANT", Decimal::new(5000, 2));
        assert_eq!(
            inner.available_advance_of(&unit.to_string(), "TENANT"),
            amount
        );
    }
    let mut unrelated_tenant = request("PAYOUT", "TENANT", None, Decimal::new(100, 2));
    unrelated_tenant.beneficiary_person_id = Some(owner_id.to_string());
    assert!(matches!(
        service
            .create(&requester, &unit.to_string(), unrelated_tenant)
            .await,
        Err(FinanceError::NotFound(_))
    ));

    let mut payout_request = request("PAYOUT", "TENANT", None, Decimal::new(4000, 2));
    payout_request.beneficiary_person_id = Some(tenant_id.to_string());
    let payout = service
        .create(&requester, &unit.to_string(), payout_request.clone())
        .await
        .expect("create payout request");
    let retried_payout = service
        .create(&requester, &unit.to_string(), payout_request)
        .await
        .expect("idempotent retry returns the original request");
    assert_eq!(retried_payout.id, payout.id);
    assert_eq!(
        state
            .inner
            .read()
            .await
            .available_advance_of(&unit.to_string(), "TENANT"),
        Decimal::new(6000, 2)
    );
    let unit_projection = IndependentUnit {
        id: unit.to_string(),
        site_id: site_id.clone(),
        block_id: "A Blok".to_string(),
        unit_number: 14,
        floor: 0,
        land_share: 1,
        owner_user_id: None,
        tenant_user_id: None,
        virtual_iban: None,
        house_type: None,
        monthly_tariff_override: None,

        created_on: None,
    };
    let inner = state.inner.read().await;
    let statement = sitepulse_backend::services::resident_statement::build_statement(
        &inner,
        &unit_projection,
        Some("TENANT"),
        site_today(),
    );
    assert_eq!(statement.debtors[0].advance_balance, Decimal::new(6000, 2));
    drop(inner);
    let mut changed_payload = request("PAYOUT", "TENANT", None, Decimal::new(5000, 2));
    changed_payload.request_key = retried_payout.request_key.clone();
    changed_payload.beneficiary_person_id = Some(tenant_id.to_string());
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
    let client = db.owner.get().await.expect("test connection");
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
    assert_eq!(
        state
            .inner
            .read()
            .await
            .advance_of(&unit.to_string(), "TENANT"),
        Decimal::new(6000, 2)
    );
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

    let mut transfer_request = request("TRANSFER", "TENANT", Some("OWNER"), Decimal::new(2000, 2));
    transfer_request.beneficiary_person_id = Some(tenant_id.to_string());
    let transfer = service
        .create(&requester, &unit.to_string(), transfer_request)
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
    let client = db.owner.get().await.expect("test connection");
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
    assert_eq!(
        state
            .inner
            .read()
            .await
            .advance_of(&unit.to_string(), "TENANT"),
        Decimal::new(4000, 2)
    );
    assert_eq!(
        state
            .inner
            .read()
            .await
            .advance_of(&unit.to_string(), "OWNER"),
        Decimal::new(12000, 2)
    );
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

    let mut stale_request = request("PAYOUT", "TENANT", None, Decimal::new(3000, 2));
    stale_request.beneficiary_person_id = Some(tenant_id.to_string());
    let stale = service
        .create(&requester, &unit.to_string(), stale_request)
        .await
        .expect("create request before external balance change");
    let client = db.owner.get().await.expect("test connection");
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

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-13-03-06
async fn seller_advance_held_after_a_title_transfer_is_paid_only_to_the_seller() {
    let db = TestDb::create().await;
    let (unit, site_id) = db.unit().await;
    let seller: i64 = db
        .owner
        .get()
        .await
        .expect("test connection")
        .query_one("SELECT owner_person_id FROM units WHERE id = $1", &[&unit])
        .await
        .expect("seeded owner")
        .get(0);
    // The title transfer already happened: the seller's 500.00 left the role
    // bucket, so the buyer's owner advance is zero.
    db.seed_hold(unit, seller, "OWNER", Decimal::new(50000, 2))
        .await;
    let state = AppState::with_pool(Some(db.pool.clone()));
    state.reload_from_db().await.expect("load the hold");
    {
        let inner = state.inner.read().await;
        assert_eq!(
            inner.advance_of(&unit.to_string(), "OWNER"),
            Decimal::ZERO,
            "the buyer's role bucket starts empty"
        );
        assert_eq!(
            inner.held_advance_of(&unit.to_string(), &seller.to_string(), "OWNER"),
            Decimal::new(50000, 2),
            "the advance is still the seller's"
        );
    }
    let service = AdvanceExitSettlementService::new(&state);
    let requester = caller(&site_id, "requester");
    let checker = caller(&site_id, "checker");
    let mut payout_request = request("PAYOUT", "OWNER", None, Decimal::new(50000, 2));
    payout_request.beneficiary_person_id = Some(seller.to_string());
    let payout = service
        .create(&requester, &unit.to_string(), payout_request)
        .await
        .expect("the seller can claim the advance held for them");
    let approved = service
        .decide(
            &checker,
            payout.id,
            DecideAdvanceExitSettlementRequest {
                approve: true,
                payment_reference: Some("BANK-REF-SELLER-1".to_string()),
                note: None,
            },
        )
        .await
        .expect("approve the seller payout");
    assert_eq!(approved.status, "APPROVED");

    let client = db.owner.get().await.expect("test connection");
    let held: Decimal = client
        .query_one(
            "SELECT COALESCE((SELECT balance FROM person_advance_holds
                               WHERE unit_id = $1 AND person_id = $2 AND debtor_type = 'OWNER'), 0)::NUMERIC(15,2)",
            &[&unit, &seller],
        )
        .await
        .expect("read the seller hold")
        .get(0);
    assert_eq!(held, Decimal::ZERO, "the payout spends the seller's hold");
    let role_bucket: Decimal = client
        .query_one(
            "SELECT COALESCE((SELECT balance FROM advance_balances
                               WHERE unit_id = $1 AND debtor_type = 'OWNER'), 0)::NUMERIC(15,2)",
            &[&unit],
        )
        .await
        .expect("read the buyer bucket")
        .get(0);
    assert_eq!(
        role_bucket,
        Decimal::ZERO,
        "the payout never touches the buyer's advance"
    );
    let disbursements: i64 = client
        .query_one(
            "SELECT COUNT(*) FROM advance_exit_disbursements WHERE settlement_id = $1",
            &[&payout.id],
        )
        .await
        .expect("read the disbursement")
        .get(0);
    assert_eq!(disbursements, 1);
    let hold_ledger: i64 = client
        .query_one(
            "SELECT COUNT(*) FROM advance_ledger_entries
              WHERE person_id = $1 AND entry_type = 'EXIT_PAYOUT_DEBIT'",
            &[&seller],
        )
        .await
        .expect("read the hold ledger")
        .get(0);
    assert_eq!(hold_ledger, 1, "the hold movement names the seller");
    let violations: i64 = client
        .query_one("SELECT COUNT(*) FROM v_integrity_violations", &[])
        .await
        .expect("check the ledger views")
        .get(0);
    assert_eq!(violations, 0, "the held advance reconciles with its ledger");
    drop(client);

    assert_eq!(
        state
            .inner
            .read()
            .await
            .held_advance_of(&unit.to_string(), &seller.to_string(), "OWNER"),
        Decimal::ZERO
    );

    db.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-13-03-06
async fn pending_requests_of_one_holder_cannot_count_the_same_hold_twice() {
    let db = TestDb::create().await;
    let (unit, site_id) = db.unit().await;
    let owner: i64 = db
        .owner
        .get()
        .await
        .expect("test connection")
        .query_one("SELECT owner_person_id FROM units WHERE id = $1", &[&unit])
        .await
        .expect("seeded owner")
        .get(0);
    db.seed_hold(unit, owner, "OWNER", Decimal::new(20000, 2))
        .await;
    let state = AppState::with_pool(Some(db.pool.clone()));
    state.reload_from_db().await.expect("load the hold");
    let service = AdvanceExitSettlementService::new(&state);
    let requester = caller(&site_id, "requester");

    for key in ["held-request-1", "held-request-2"] {
        let mut pending = request("PAYOUT", "OWNER", None, Decimal::new(10000, 2));
        pending.request_key = key.to_string();
        pending.beneficiary_person_id = Some(owner.to_string());
        service
            .create(&requester, &unit.to_string(), pending)
            .await
            .expect("each request fits the hold at the time it is made");
    }

    // The hold shrinks outside this service and the buyer's own advance arrives:
    // 100.00 of the 200.00 is gone, and 100.00 sits in the unit's owner bucket.
    let client = db.owner.get().await.expect("test connection");
    client
        .batch_execute("SET sitepulse.allow_ledger_purge = 'on'")
        .await
        .expect("enable test ledger writes");
    client
        .execute(
            "UPDATE person_advance_holds SET balance = $3
              WHERE unit_id = $1 AND person_id = $2 AND debtor_type = 'OWNER'",
            &[&unit, &owner, &Decimal::new(10000, 2)],
        )
        .await
        .expect("shrink the hold");
    client
        .execute(
            "INSERT INTO advance_ledger_entries
                (unit_id, debtor_type, person_id, entry_type, amount, description)
             VALUES ($1, 'OWNER', $2, 'EXIT_PAYOUT_DEBIT', $3, 'Test: hold spent elsewhere')",
            &[&unit, &owner, &Decimal::new(10000, 2)],
        )
        .await
        .expect("record the external hold spend");
    client
        .execute(
            "INSERT INTO advance_balances (unit_id, debtor_type, balance)
             VALUES ($1, 'OWNER', $2)
             ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance",
            &[&unit, &Decimal::new(10000, 2)],
        )
        .await
        .expect("seed the buyer bucket");
    client
        .execute(
            "INSERT INTO advance_ledger_entries
                (unit_id, debtor_type, entry_type, amount, description)
             VALUES ($1, 'OWNER', 'PAYMENT_SURPLUS', $2, 'Test: buyer advance')",
            &[&unit, &Decimal::new(10000, 2)],
        )
        .await
        .expect("record the buyer advance");
    drop(client);

    // The two pending payouts already claim 100.00 of the hold and 100.00 of the
    // bucket, so nothing is left for a third request from the same person.
    let mut third = request("PAYOUT", "OWNER", None, Decimal::new(10000, 2));
    third.request_key = "held-request-3".to_string();
    third.beneficiary_person_id = Some(owner.to_string());
    assert!(matches!(
        service.create(&requester, &unit.to_string(), third).await,
        Err(FinanceError::Conflict(_))
    ));

    db.drop_db().await;
}
