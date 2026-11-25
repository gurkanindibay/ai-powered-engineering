//! PostgreSQL regression: capital installment accrual bills only the site's active units.
//!
//! Archiving a unit closes its history and cancels its open dues, so a later installment
//! must neither bill it nor reserve a land-share slice for it.
//! The `rust-db-test` harness gate runs this target with `--ignored`.

use chrono::NaiveDate;
use rust_decimal::Decimal;
use sitepulse_backend::models::{
    AllocationBasis, CapitalProjectCategory, CreateCapitalProjectRequest, CreateInstallmentItem,
};
use sitepulse_backend::services::CapitalProjectService;
use sitepulse_backend::state::AppState;

const BUDGET: &str = "1000.00";

fn money(value: &str) -> Decimal {
    Decimal::from_str_exact(value).expect("decimal literal")
}

#[tokio::test]
#[ignore = "needs PostgreSQL (DB_PASS); run by the rust-db-test gate"]
// covers: SC-10-02-01
async fn when_a_unit_is_archived_then_installment_accrual_does_not_charge_it() {
    let db = crate::test_db::create("capital_archived").await;
    let client = db.pool.get().await.expect("test connection");
    let site: i64 = client
        .query_one("SELECT id FROM sites WHERE slug = 'begonya-sitesi'", &[])
        .await
        .expect("seeded site")
        .get(0);
    let active: Vec<i64> = client
        .query(
            "SELECT id FROM units WHERE site_id = $1 AND deleted_at IS NULL ORDER BY id",
            &[&site],
        )
        .await
        .expect("site units")
        .iter()
        .map(|row| row.get(0))
        .collect();
    assert!(
        active.len() >= 2,
        "the seeded site needs at least two units"
    );
    let archived = active[0];
    client
        .execute(
            "UPDATE units SET deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
            &[&archived],
        )
        .await
        .expect("archive one unit");
    drop(client);

    let state = AppState::with_pool(Some(db.pool.clone()));
    state
        .reload_from_db()
        .await
        .expect("load state from PostgreSQL");
    let service = CapitalProjectService::new(state);
    let today = NaiveDate::from_ymd_opt(2026, 12, 1).expect("fixed fixture date");
    let project = service
        .create_project(CreateCapitalProjectRequest {
            site_id: Some(site.to_string()),
            title: "Archived unit regression".to_string(),
            category: Some(CapitalProjectCategory::Other),
            description: None,
            total_budget: money(BUDGET),
            allocation_basis: Some(AllocationBasis::ByLandShare),
            target_start_date: Some(today),
            target_completion_date: None,
            contractor_name: None,
            contractor_tax_no: None,
            contractor_iban: None,
            contract_amount: None,
            installments: Some(vec![CreateInstallmentItem {
                installment_number: 1,
                total_installments: 1,
                due_date: today,
                installment_budget: money(BUDGET),
                percentage: Some(money("100.00")),
            }]),
        })
        .await
        .expect("create capital project");

    let accrued = service
        .accrue_installment(&project.id, 1)
        .await
        .expect("accrue installment");
    assert_eq!(
        accrued.charged_units_count,
        i64::try_from(active.len() - 1).expect("unit count"),
        "the archived unit must not be counted as charged"
    );

    let client = db.pool.get().await.expect("test connection");
    let archived_dues: i64 = client
        .query_one(
            "SELECT COUNT(*) FROM dues_liabilities
              WHERE unit_id = $1 AND expense_type = 'CAPITAL_DUES'",
            &[&archived],
        )
        .await
        .expect("archived unit liabilities")
        .get(0);
    assert_eq!(
        archived_dues, 0,
        "an archived unit must not receive a liability"
    );
    let billed: Decimal = client
        .query_one(
            "SELECT COALESCE(SUM(d.principal_amount), 0)::NUMERIC(15,2)
               FROM dues_liabilities d JOIN units u ON u.id = d.unit_id
              WHERE u.site_id = $1 AND d.expense_type = 'CAPITAL_DUES'",
            &[&site],
        )
        .await
        .expect("billed total")
        .get(0);
    assert_eq!(
        billed,
        money(BUDGET),
        "the live units' shares must add up to the installment budget"
    );

    drop(client);
    let _ = db
        .admin
        .get()
        .await
        .expect("admin connection")
        .batch_execute(&format!("DROP DATABASE IF EXISTS {} WITH (FORCE)", db.name))
        .await;
}
