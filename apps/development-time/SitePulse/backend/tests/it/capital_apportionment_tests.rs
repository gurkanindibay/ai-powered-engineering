//! Capital-project apportionment: shares are confined to the project's site,
//! sum exactly to the budget, and the unit share summary reports exactly what
//! accrual charges.

use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::CapitalProjectService;
use sitepulse_backend::state::AppState;

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn unit(id: &str, site_id: &str, unit_number: i32, land_share: i32) -> IndependentUnit {
    IndependentUnit {
        id: id.to_string(),
        site_id: site_id.to_string(),
        block_id: "A".to_string(),
        unit_number,
        floor: 1,
        land_share,
        owner_user_id: None,
        tenant_user_id: None,
        virtual_iban: None,
        house_type: None,
        monthly_tariff_override: None,

        created_on: None,
    }
}

/// Replaces the seeded units with three units on `site-90` (land shares 1:1:1)
/// and two units on another tenant's `site-91`.
async fn state_with_two_sites() -> AppState {
    let state = AppState::new();
    {
        let mut inner = state.inner.write().await;
        inner.units = vec![
            unit("x-1", "site-90", 1, 1),
            unit("x-2", "site-90", 2, 1),
            unit("x-3", "site-90", 3, 1),
            unit("y-1", "site-91", 1, 5),
            unit("y-2", "site-91", 2, 5),
        ];
    }
    state
}

fn project_request(
    site_id: &str,
    title: &str,
    budget: &str,
    basis: AllocationBasis,
) -> CreateCapitalProjectRequest {
    CreateCapitalProjectRequest {
        site_id: Some(site_id.to_string()),
        title: title.to_string(),
        category: Some(CapitalProjectCategory::Other),
        description: None,
        total_budget: d(budget),
        allocation_basis: Some(basis),
        target_start_date: Some(crate::support::site_today()),
        target_completion_date: None,
        contractor_name: None,
        contractor_tax_no: None,
        contractor_iban: None,
        contract_amount: None,
        installments: Some(vec![CreateInstallmentItem {
            installment_number: 1,
            total_installments: 1,
            due_date: crate::support::site_today(),
            installment_budget: d(budget),
            percentage: Some(d("100.00")),
        }]),
    }
}

#[tokio::test]
// covers: SC-10-02-01
async fn when_accruing_installment_then_only_project_site_units_are_charged() {
    let state = state_with_two_sites().await;
    let service = CapitalProjectService::new(state.clone());
    let project = service
        .create_project(project_request(
            "site-90",
            "Roof Repair",
            "100.00",
            AllocationBasis::ByLandShare,
        ))
        .await
        .unwrap();

    let res = service.accrue_installment(&project.id, 1).await.unwrap();
    assert_eq!(
        res.charged_units_count, 3,
        "site-91 units must not be charged for a site-90 project"
    );

    let inner = state.inner.read().await;
    let charged: Vec<(&str, Decimal)> = inner
        .dues
        .iter()
        .filter(|due| due.expense_type == ExpenseType::CapitalDues)
        .map(|due| (due.unit_id.as_str(), due.principal_amount))
        .collect();
    assert!(charged.iter().all(|(unit_id, _)| unit_id.starts_with("x-")));
    // 100.00 / 3: largest remainder gives the odd cent to the first equal claimant.
    assert_eq!(
        charged,
        vec![
            ("x-1", d("33.34")),
            ("x-2", d("33.33")),
            ("x-3", d("33.33"))
        ]
    );
}

#[tokio::test]
// covers: SC-10-01-01
async fn when_summarizing_shares_then_matches_accrued_amounts_and_sums_to_budget() {
    let state = state_with_two_sites().await;
    let service = CapitalProjectService::new(state.clone());
    let project = service
        .create_project(project_request(
            "site-90",
            "Facade Insulation",
            "1000.00",
            AllocationBasis::EqualPerUnit,
        ))
        .await
        .unwrap();
    service.accrue_installment(&project.id, 1).await.unwrap();

    let summary = service.get_unit_capital_shares(&project.id).await.unwrap();
    assert_eq!(summary.len(), 3);
    let total: Decimal = summary.iter().map(|s| s.total_project_share).sum();
    assert_eq!(
        total,
        d("1000.00"),
        "the summary previously skipped the remainder correction"
    );
    for row in &summary {
        assert_eq!(
            row.total_project_share, row.total_accrued,
            "unit {}",
            row.unit_id
        );
    }
}

#[tokio::test]
async fn when_summarizing_then_other_projects_dues_are_not_attributed() {
    let state = state_with_two_sites().await;
    let service = CapitalProjectService::new(state.clone());
    let first = service
        .create_project(project_request(
            "site-90",
            "Elevator Revision",
            "300.00",
            AllocationBasis::EqualPerUnit,
        ))
        .await
        .unwrap();
    let second = service
        .create_project(project_request(
            "site-90",
            "Garden Lighting",
            "60.00",
            AllocationBasis::EqualPerUnit,
        ))
        .await
        .unwrap();
    service.accrue_installment(&first.id, 1).await.unwrap();
    service.accrue_installment(&second.id, 1).await.unwrap();

    let summary = service.get_unit_capital_shares(&second.id).await.unwrap();
    for row in &summary {
        assert_eq!(
            row.total_accrued,
            d("20.00"),
            "unit {} picked up another project's dues",
            row.unit_id
        );
    }
}

#[tokio::test]
async fn when_units_have_negative_land_share_then_apportionment_is_rejected() {
    let state = AppState::new();
    {
        let mut inner = state.inner.write().await;
        inner.units = vec![unit("x-1", "site-90", 1, 2), unit("x-2", "site-90", 2, -1)];
    }
    let service = CapitalProjectService::new(state);
    let project = service
        .create_project(project_request(
            "site-90",
            "Boiler",
            "10.00",
            AllocationBasis::ByLandShare,
        ))
        .await
        .unwrap();
    assert!(service.accrue_installment(&project.id, 1).await.is_err());
}

#[tokio::test]
#[ignore = "requires PostgreSQL"]
async fn when_site_has_archived_unit_then_capital_accrual_excludes_it_and_shares_sum_to_budget() {
    let test_db = crate::test_db::create("cap_archived_unit").await;
    let client = test_db.owner.get().await.expect("db connection");

    let site_row = client
        .query_one("SELECT id FROM sites WHERE slug = 'begonya-sitesi'", &[])
        .await
        .expect("seeded site");
    let site_id_num: i64 = site_row.get("id");
    let site_id_str = site_id_num.to_string();

    // The seeded site has two units; add live units until it has three, so one can
    // be archived and the shares still have to be split across several live units.
    for extra in 1..=3 {
        let active: i64 = client
            .query_one(
                "SELECT COUNT(*) FROM units WHERE site_id = $1 AND deleted_at IS NULL",
                &[&site_id_num],
            )
            .await
            .expect("count active units")
            .get(0);
        if active >= 3 {
            break;
        }
        client
            .execute(
                "INSERT INTO units (site_id, block_id, unit_number, floor)
                 SELECT site_id, block_id, 900 + $2::int, floor FROM units
                  WHERE site_id = $1 AND deleted_at IS NULL ORDER BY id LIMIT 1",
                &[&site_id_num, &extra],
            )
            .await
            .expect("add a live unit");
    }
    let unit_rows = client
        .query(
            "SELECT id, land_share FROM units WHERE site_id = $1 AND deleted_at IS NULL ORDER BY id",
            &[&site_id_num],
        )
        .await
        .expect("active units");
    assert!(
        unit_rows.len() >= 3,
        "expected at least 3 active units in seeded site"
    );

    // Soft-delete the first unit
    let archived_unit_id: i64 = unit_rows[0].get("id");
    client
        .execute(
            "UPDATE units SET deleted_at = NOW() WHERE id = $1",
            &[&archived_unit_id],
        )
        .await
        .expect("soft-delete unit");

    // Build AppState backed by the test DB
    let mut state = AppState::new();
    state.pool = Some(test_db.pool.clone());

    // Populate in-memory units and owners so service can initialize project & fallback state
    {
        let mut inner = state.inner.write().await;
        for row in &unit_rows {
            let u_id: i64 = row.get("id");
            let ls: i32 = row.get("land_share");
            inner.units.push(IndependentUnit {
                id: u_id.to_string(),
                site_id: site_id_str.clone(),
                block_id: "A".to_string(),
                unit_number: u_id as i32,
                floor: 1,
                land_share: ls,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: None,
                house_type: None,
                monthly_tariff_override: None,
                created_on: None,
            });
        }
    }

    let service = CapitalProjectService::new(state);
    let budget_str = "35000.00";
    let req = project_request(
        &site_id_str,
        "Facade Renovation",
        budget_str,
        AllocationBasis::ByLandShare,
    );

    let project = service.create_project(req).await.expect("project created");
    service
        .accrue_installment(&project.id, 1)
        .await
        .expect("accrue installment 1");

    // Verify in DB
    let p_num: i64 = project.id.parse().expect("parsed project id");
    let liabilities = client
        .query(
            "SELECT unit_id, principal_amount FROM dues_liabilities WHERE capital_project_id = $1 AND installment_number = 1",
            &[&p_num],
        )
        .await
        .expect("accrued liabilities");

    // 1. Archived unit received no liability
    let billed_unit_ids: Vec<i64> = liabilities.iter().map(|r| r.get("unit_id")).collect();
    assert!(
        !billed_unit_ids.contains(&archived_unit_id),
        "archived unit {archived_unit_id} must not be charged"
    );

    // 2. All live units received a liability
    let expected_live_count = unit_rows.len() - 1;
    assert_eq!(
        liabilities.len(),
        expected_live_count,
        "every live unit must receive a liability"
    );

    // 3. Sum of liabilities across live units equals installment budget (105000 / 3 = 35000)
    let total_accrued: Decimal = liabilities
        .iter()
        .map(|r| r.get::<_, Decimal>("principal_amount"))
        .sum();
    let expected_installment_budget = d("35000.00");
    assert_eq!(
        total_accrued, expected_installment_budget,
        "sum of shares must equal installment budget exactly"
    );

    test_db.drop_db().await;
}
