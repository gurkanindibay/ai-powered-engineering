//! Capital-project apportionment: shares are confined to the project's site,
//! sum exactly to the budget, and the unit share summary reports exactly what
//! accrual charges.

use chrono::Utc;
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
        target_start_date: Some(Utc::now().date_naive()),
        target_completion_date: None,
        contractor_name: None,
        contractor_tax_no: None,
        contractor_iban: None,
        contract_amount: None,
        installments: Some(vec![CreateInstallmentItem {
            installment_number: 1,
            total_installments: 1,
            due_date: Utc::now().date_naive(),
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
