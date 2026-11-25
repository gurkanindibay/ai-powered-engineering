//! STORY-08-05: the sale clearance statement, the mid-month sale split and the four-eyes
//! seller-pays override. Scenarios: `.specify/features/EPIC-08/STORY-08-05-*.feature`.
//!
//! The statement and the split run in memory. The override and the accrual that follows it need
//! PostgreSQL: `cargo nextest run --locked --profile db --test it -E 'test(/sale_clearance_tests::/)' --run-ignored ignored-only --test-threads 4`.

use chrono::NaiveDate;
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::capital_project_service::CapitalProjectService;
use sitepulse_backend::services::correction_service::CorrectionService;
use sitepulse_backend::services::finance_common::{Caller, FinanceError};
use sitepulse_backend::services::occupancy_service::OccupancyService;
use sitepulse_backend::services::sale_clearance_service::SaleClearanceService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";
const UNIT: &str = "d-14";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).expect("valid decimal")
}

fn date(s: &str) -> NaiveDate {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").expect("valid date")
}

fn manager(site: &str, user: &str) -> Caller {
    Caller {
        site_id: site.to_string(),
        user_id: user.to_string(),
        email: format!("{user}@sitepulse.test"),
        role: Role::SiteManager,
        unit_id: None,
    }
}

fn operational(id: &str, period: &str, principal: &str, penalty: &str, due: &str) -> DuesLiability {
    let total = d(principal) + d(penalty);
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: period.to_string(),
        principal_amount: d(principal),
        delay_penalty: d(penalty),
        total_amount: total,
        due_date: date(due),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    }
}

/// Site 1 reduced to unit A-14, with no liabilities or advances.
async fn fixture() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.units.retain(|u| u.site_id != SITE || u.id == UNIT);
        inner.dues.clear();
        inner.advance_balances.clear();
    }
    state
}

fn project_request(site: &str) -> CreateCapitalProjectRequest {
    CreateCapitalProjectRequest {
        site_id: Some(site.to_string()),
        title: "Cephe".to_string(),
        category: Some(CapitalProjectCategory::FacadeInsulation),
        description: None,
        total_budget: d("6000.00"),
        allocation_basis: Some(AllocationBasis::EqualPerUnit),
        target_start_date: Some(date("2026-12-01")),
        target_completion_date: None,
        contractor_name: None,
        contractor_tax_no: None,
        contractor_iban: None,
        contract_amount: None,
        installments: Some(
            (1..=3)
                .map(|n| CreateInstallmentItem {
                    installment_number: n,
                    total_installments: 3,
                    due_date: date("2026-12-10") + chrono::Months::new(n as u32 - 1),
                    installment_budget: d("2000.00"),
                    percentage: None,
                })
                .collect(),
        ),
    }
}

#[tokio::test]
// covers: SC-08-05-04, SC-13-03-19, SC-13-12-02
async fn statement_itemizes_seller_debt_advance_and_installments_not_yet_accrued() {
    let state = fixture().await;
    let capital = CapitalProjectService::new(state.clone());
    let project = capital
        .create_project(project_request(SITE))
        .await
        .expect("project");
    capital
        .accrue_installment(&project.id, 1)
        .await
        .expect("installment 1");
    {
        let mut inner = state.inner.write().await;
        inner.dues.push(operational(
            "op-nov",
            "2026-11",
            "1500.00",
            "100.00",
            "2026-11-10",
        ));
        inner.dues.push(operational(
            "op-dec",
            "2026-12",
            "1500.00",
            "25.00",
            "2026-12-10",
        ));
        // The capital installment carries a late fee of 33.33.
        for due in inner
            .dues
            .iter_mut()
            .filter(|due| due.expense_type == ExpenseType::CapitalDues)
        {
            due.delay_penalty = d("33.33");
            due.total_amount += d("33.33");
        }
        inner.adjust_advance(UNIT, "OWNER", d("0.00"));
    }

    let statement = SaleClearanceService::new(&state)
        .statement(&manager(SITE, "m1"), UNIT, date("2026-12-20"))
        .await
        .expect("statement");

    assert_eq!(statement.debts.len(), 3);
    assert_eq!(statement.open_debt_principal, d("5000.00"));
    assert_eq!(statement.open_debt_fee, d("158.33"));
    assert_eq!(statement.open_debt_total, d("5158.33"));
    assert_eq!(statement.advance, d("0.00"));
    assert_eq!(statement.upcoming_installments.len(), 2);
    assert!(statement
        .upcoming_installments
        .iter()
        .all(|i| i.amount == d("2000.00")));
    assert_eq!(statement.upcoming_installments_total, d("4000.00"));
    assert!(statement.notice.contains("seller-pays override"));

    // The total is the ledger's: the sum of the seller's outstanding owner liabilities.
    let ledger: Decimal = state
        .inner
        .read()
        .await
        .dues
        .iter()
        .filter(|due| due.debtor_type == DebtorType::Owner)
        .map(|due| due.total_amount)
        .sum();
    assert_eq!(statement.open_debt_total, ledger);

    let csv = SaleClearanceService::render_csv(&statement);
    assert!(csv.starts_with("section,description,due_date,principal,fee,total\n"));
    assert!(csv.contains("open_debt_total,Seller open debt,,5000.00,158.33,5158.33"));
    assert!(csv.contains("not_yet_accrued_total"));
}

#[tokio::test]
// covers: SC-08-05-04
async fn statement_leaves_out_paid_and_cancelled_liabilities_and_counts_the_advance() {
    let state = fixture().await;
    {
        let mut inner = state.inner.write().await;
        let mut paid = operational("op-paid", "2026-09", "1500.00", "0.00", "2026-09-10");
        paid.paid_principal = d("1500.00");
        paid.status = DebtStatus::Paid;
        let mut cancelled = operational("op-cancelled", "2026-10", "1500.00", "0.00", "2026-10-10");
        cancelled.status = DebtStatus::Cancelled;
        let mut part = operational("op-part", "2026-11", "1500.00", "30.00", "2026-11-10");
        part.paid_principal = d("500.00");
        inner.dues.extend([paid, cancelled, part]);
        inner.adjust_advance(UNIT, "OWNER", d("250.00"));
        inner.adjust_advance(UNIT, "TENANT", d("90.00"));
    }
    let statement = SaleClearanceService::new(&state)
        .statement(&manager(SITE, "m1"), UNIT, date("2026-12-20"))
        .await
        .expect("statement");
    assert_eq!(statement.debts.len(), 1);
    assert_eq!(statement.open_debt_principal, d("1000.00"));
    assert_eq!(statement.open_debt_fee, d("30.00"));
    assert_eq!(statement.advance, d("250.00"));
    assert!(statement.upcoming_installments.is_empty());
}

#[tokio::test]
async fn statement_of_a_unit_of_another_site_is_not_found() {
    let state = fixture().await;
    let result = SaleClearanceService::new(&state)
        .statement(&manager("site-other", "m1"), UNIT, date("2026-12-20"))
        .await;
    assert!(matches!(result, Err(FinanceError::NotFound(_))));
}

#[tokio::test]
// covers: SC-08-05-05, SC-13-03-16
async fn mid_month_sale_splits_the_month_by_days_through_a_four_eyes_correction() {
    let state = fixture().await;
    state.inner.write().await.dues.push(operational(
        "op-dec",
        "2026-12",
        "1500.00",
        "0.00",
        "2026-12-10",
    ));
    let first = manager(SITE, "m1");
    let second = manager(SITE, "m2");
    let occupancy = OccupancyService::new(state.clone());

    let correction = occupancy
        .request_sale_split(&first, UNIT, 11, 22, date("2026-12-20"))
        .await
        .expect("request")
        .expect("a split is requested");
    assert_eq!(correction.kind, CORRECTION_SPLIT_REISSUE);
    assert_eq!(correction.replacement_shares.len(), 2);
    assert_eq!(correction.replacement_shares[0].amount, d("919.35"));
    assert_eq!(correction.replacement_shares[0].liable_person_id, Some(11));
    assert_eq!(correction.replacement_shares[1].amount, d("580.65"));
    assert_eq!(correction.replacement_shares[1].liable_person_id, Some(22));

    // The requester cannot approve their own split.
    let corrections = CorrectionService::new(&state);
    assert!(corrections
        .decide(
            &first,
            correction.id,
            DecideRequest {
                approve: true,
                note: None
            }
        )
        .await
        .is_err());
    let approved = corrections
        .decide(
            &second,
            correction.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .expect("approve");
    assert_eq!(approved.replacement_due_ids.len(), 2);

    let inner = state.inner.read().await;
    let original = inner
        .dues
        .iter()
        .find(|due| due.id == "op-dec")
        .expect("original");
    assert_eq!(original.status, DebtStatus::Cancelled);
    let replacements: Vec<&DuesLiability> = approved
        .replacement_due_ids
        .iter()
        .filter_map(|id| inner.dues.iter().find(|due| &due.id == id))
        .collect();
    assert_eq!(replacements[0].principal_amount, d("919.35"));
    assert_eq!(replacements[0].due_date, date("2026-12-10"));
    assert_eq!(replacements[1].principal_amount, d("580.65"));
    assert_eq!(replacements[1].due_date, date("2026-12-20"));
    let total: Decimal = replacements.iter().map(|due| due.principal_amount).sum();
    assert_eq!(total, d("1500.00"));
    assert!(replacements
        .iter()
        .all(|due| due.debtor_type == DebtorType::Owner));
}

#[tokio::test]
// covers: SC-08-05-05
async fn sale_split_is_skipped_without_one_open_liability_or_on_the_first_day() {
    let state = fixture().await;
    let occupancy = OccupancyService::new(state.clone());
    let manager = manager(SITE, "m1");
    // Nothing accrued for the month.
    assert!(occupancy
        .request_sale_split(&manager, UNIT, 11, 22, date("2026-12-20"))
        .await
        .expect("request")
        .is_none());
    state.inner.write().await.dues.push(operational(
        "op-dec",
        "2026-12",
        "1500.00",
        "0.00",
        "2026-12-10",
    ));
    // A sale on the first day leaves the whole month to the buyer.
    assert!(occupancy
        .request_sale_split(&manager, UNIT, 11, 22, date("2026-12-01"))
        .await
        .expect("request")
        .is_none());
}

#[tokio::test]
async fn split_shares_of_one_role_must_name_distinct_people() {
    let state = fixture().await;
    state.inner.write().await.dues.push(operational(
        "op-dec",
        "2026-12",
        "1500.00",
        "0.00",
        "2026-12-10",
    ));
    let share = |amount: &str, person: Option<i64>| CorrectionReplacementShare {
        debtor_type: DebtorType::Owner,
        amount: d(amount),
        liable_person_id: person,
        due_date: None,
    };
    let request = |shares: Vec<CorrectionReplacementShare>| RequestCorrectionRequest {
        due_id: "op-dec".to_string(),
        kind: CORRECTION_SPLIT_REISSUE.to_string(),
        amount: None,
        due_date: None,
        debtor_type: None,
        replacement_shares: shares,
        reason: "sale split check".to_string(),
    };
    let corrections = CorrectionService::new(&state);
    let caller = manager(SITE, "m1");
    for shares in [
        vec![share("700.00", None), share("800.00", None)],
        vec![share("700.00", Some(1)), share("800.00", Some(1))],
    ] {
        assert!(matches!(
            corrections.request(&caller, request(shares)).await,
            Err(FinanceError::Invalid(_))
        ));
    }
}

// ---------------------------------------------------------------------------
// PostgreSQL: the seller-pays override and the accrual that follows it
// ---------------------------------------------------------------------------

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
}

impl TestDb {
    /// `tag` keeps the database name unique per test: the rust-db-test gate runs these tests on
    /// several threads of one process, so the process id alone collides.
    async fn create(tag: &str) -> Self {
        let crate::test_db::TestDatabase { name, admin, pool } = crate::test_db::create(tag).await;
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
}

async fn capital_debtor(pool: &Pool, unit: i64, project: i64, installment: i32) -> Option<i64> {
    pool.get()
        .await
        .expect("connection")
        .query_one(
            "SELECT liable_person_id FROM dues_liabilities
              WHERE unit_id = $1 AND capital_project_id = $2 AND installment_number = $3",
            &[&unit, &project, &installment],
        )
        .await
        .expect("capital liability")
        .get(0)
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-08-05-06, SC-08-05-07, SC-13-03-05, SC-13-12-02
async fn only_an_approved_override_makes_the_seller_pay_later_installments() {
    let db = TestDb::create("approved_override").await;
    let client = db.pool.get().await.expect("connection");
    let row = client
        .query_one(
            "SELECT u.id, u.site_id, u.owner_person_id
               FROM units u JOIN blocks b ON b.id = u.block_id JOIN sites s ON s.id = u.site_id
              WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok' AND u.unit_number = 14",
            &[],
        )
        .await
        .expect("seeded unit");
    let (unit, site, seller): (i64, i64, i64) = (row.get(0), row.get(1), row.get(2));
    let buyer: i64 = client
        .query_one(
            "INSERT INTO persons (site_id, full_name, person_type)
             VALUES ($1, 'Sale Clearance Buyer', 'HOME_OWNER') RETURNING id",
            &[&site],
        )
        .await
        .expect("buyer")
        .get(0);
    // The sale has happened: the buyer is the owner on record.
    client
        .execute(
            "UPDATE units SET owner_person_id = $2 WHERE id = $1",
            &[&unit, &buyer],
        )
        .await
        .expect("record the sale");
    drop(client);

    let state = AppState::with_pool(Some(db.pool.clone()));
    state.reload_from_db().await.expect("load state");
    let site_id = site.to_string();
    let requester = manager(&site_id, "requester");
    let checker = manager(&site_id, "checker");
    let service = SaleClearanceService::new(&state);
    let capital = CapitalProjectService::new(state.clone());
    let project = capital
        .create_project(project_request(&site_id))
        .await
        .expect("project");
    let project_id: i64 = project.id.parse().expect("numeric project id");
    let override_request = || RequestSellerPaysOverrideRequest {
        buyer_person_id: buyer,
        transfer_date: date("2026-12-20"),
        reason: "Contract says the seller pays".to_string(),
    };

    // No override: the owner on record at accrual (the buyer) is billed.
    capital.accrue_installment(&project.id, 1).await.expect("1");
    assert_eq!(
        capital_debtor(&db.pool, unit, project_id, 1).await,
        Some(buyer)
    );

    // Pending: still the buyer. The requester cannot approve it.
    let pending = service
        .request_for_seller(&requester, &unit.to_string(), seller, override_request())
        .await
        .expect("request");
    assert_eq!(pending.status, "PENDING");
    assert!(matches!(
        service
            .request_for_seller(&requester, &unit.to_string(), seller, override_request())
            .await,
        Err(FinanceError::Conflict(_))
    ));
    assert!(matches!(
        service
            .decide(
                &requester,
                pending.id,
                DecideSellerPaysOverrideRequest {
                    approve: true,
                    note: None
                }
            )
            .await,
        Err(FinanceError::Forbidden(_))
    ));
    capital.accrue_installment(&project.id, 2).await.expect("2");
    assert_eq!(
        capital_debtor(&db.pool, unit, project_id, 2).await,
        Some(buyer)
    );

    // Rejected: still the buyer.
    let rejected = service
        .decide(
            &checker,
            pending.id,
            DecideSellerPaysOverrideRequest {
                approve: false,
                note: Some("not agreed".to_string()),
            },
        )
        .await
        .expect("reject");
    assert_eq!(rejected.status, "REJECTED");
    assert!(matches!(
        service
            .decide(
                &checker,
                pending.id,
                DecideSellerPaysOverrideRequest {
                    approve: true,
                    note: None
                }
            )
            .await,
        Err(FinanceError::Conflict(_))
    ));

    // Approved by a second manager: the next installment is billed to the seller.
    let second = service
        .request_for_seller(&requester, &unit.to_string(), seller, override_request())
        .await
        .expect("second request");
    let approved = service
        .decide(
            &checker,
            second.id,
            DecideSellerPaysOverrideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .expect("approve");
    assert_eq!(approved.status, "APPROVED");
    assert_eq!(
        approved.decided_by.as_deref(),
        Some(checker.actor().as_str())
    );
    capital.accrue_installment(&project.id, 3).await.expect("3");
    assert_eq!(
        capital_debtor(&db.pool, unit, project_id, 3).await,
        Some(seller)
    );
    // Debt accrued before the approval stays where it was.
    assert_eq!(
        capital_debtor(&db.pool, unit, project_id, 1).await,
        Some(buyer)
    );

    let listed = service.list(&requester).await.expect("list");
    assert_eq!(listed.len(), 2);
    let statement = service
        .statement(&requester, &unit.to_string(), date("2026-12-20"))
        .await
        .expect("statement");
    assert_eq!(
        statement.override_request.map(|o| o.status),
        Some("APPROVED".to_string())
    );
    db.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-08-05-09
async fn a_rejected_override_request_leaves_the_seller_as_the_owner() {
    use sitepulse_backend::services::sale_clearance_service::TransferFlowError;

    let db = TestDb::create("rejected_override").await;
    let client = db.pool.get().await.expect("connection");
    let row = client
        .query_one(
            "SELECT u.id, u.site_id, u.owner_person_id
               FROM units u JOIN blocks b ON b.id = u.block_id JOIN sites s ON s.id = u.site_id
              WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok' AND u.unit_number = 14",
            &[],
        )
        .await
        .expect("seeded unit");
    let (unit, site, seller): (i64, i64, i64) = (row.get(0), row.get(1), row.get(2));
    let buyer: i64 = client
        .query_one(
            "INSERT INTO persons (site_id, full_name, person_type)
             VALUES ($1, 'Atomic Sale Buyer', 'HOME_OWNER') RETURNING id",
            &[&site],
        )
        .await
        .expect("buyer")
        .get(0);
    let other_buyer: i64 = client
        .query_one(
            "INSERT INTO persons (site_id, full_name, person_type)
             VALUES ($1, 'Second Buyer', 'HOME_OWNER') RETURNING id",
            &[&site],
        )
        .await
        .expect("second buyer")
        .get(0);
    drop(client);

    let state = AppState::with_pool(Some(db.pool.clone()));
    state.reload_from_db().await.expect("load state");
    let site_id = site.to_string();
    let unit_id = unit.to_string();
    let requester = manager(&site_id, "requester");
    let service = SaleClearanceService::new(&state);
    let transfer = |buyer_id: i64, unit_ref: &str, reason: &str| {
        (
            TransferOwnershipRequest {
                new_owner: None,
                site_id: Some(site_id.clone()),
                unit_id: unit_ref.to_string(),
                new_owner_name: "Atomic Sale Buyer".to_string(),
                new_owner_national_id: None,
                new_owner_email: None,
                new_owner_phone: None,
                transfer_date: Some(date("2026-12-20")),
                notes: None,
                new_owner_person_id: Some(buyer_id),
                new_owner_moves_in: false,
                seller_pays_override_reason: Some(reason.to_string()),
            },
            Some(reason.to_string()),
        )
    };
    let owner_user = || async {
        let inner = state.inner.read().await;
        inner
            .units
            .iter()
            .find(|u| u.id == unit_id)
            .and_then(|u| u.owner_user_id.clone())
    };
    let owner_before = owner_user().await;

    // A reason that is too short is refused before anything moves.
    let (payload, reason) = transfer(buyer, &unit_id, "no");
    assert!(matches!(
        service
            .transfer_with_follow_ups(&requester, payload, reason)
            .await,
        Err(TransferFlowError::Override(FinanceError::Invalid(_)))
    ));
    assert_eq!(owner_user().await, owner_before);
    assert_eq!(service.list(&requester).await.expect("list").len(), 0);

    // A pending request for the same buyer makes the combined request a duplicate.
    service
        .request_for_seller(
            &requester,
            &unit_id,
            seller,
            RequestSellerPaysOverrideRequest {
                buyer_person_id: buyer,
                transfer_date: date("2026-12-20"),
                reason: "Contract says the seller pays".to_string(),
            },
        )
        .await
        .expect("first request");
    let (payload, reason) = transfer(buyer, &unit_id, "Contract says the seller pays");
    assert!(matches!(
        service
            .transfer_with_follow_ups(&requester, payload, reason)
            .await,
        Err(TransferFlowError::Override(FinanceError::Conflict(_)))
    ));
    assert_eq!(owner_user().await, owner_before);
    assert_eq!(service.list(&requester).await.expect("list").len(), 1);

    // A transfer that fails after the request was stored discards that request again. The
    // seller is read from the database, so dropping the unit from the in-memory state makes
    // the transfer itself fail while the override request still passes validation.
    state.inner.write().await.units.retain(|u| u.id != unit_id);
    let (payload, reason) = transfer(other_buyer, &unit_id, "Another seller-pays reason");
    assert!(matches!(
        service
            .transfer_with_follow_ups(&requester, payload, reason)
            .await,
        Err(TransferFlowError::Transfer(_))
    ));
    assert_eq!(service.list(&requester).await.expect("list").len(), 1);
    db.drop_db().await;
}
