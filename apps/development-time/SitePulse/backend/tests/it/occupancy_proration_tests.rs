//! STORY-07-09 acceptance coverage for occupancy-aware dues proration.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::domain::accrual_schedule::AccrualSchedule;
use sitepulse_backend::models::*;
use sitepulse_backend::scheduler::run_periodic_accrual_for_all_sites;
use sitepulse_backend::services::dues_calculation_service::DuesCalculationService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-proration";
const UNIT: &str = "unit-proration";

fn date(value: &str) -> NaiveDate {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("valid fixture date")
}

fn amount(value: &str) -> Decimal {
    Decimal::from_str_exact(value).expect("valid fixture amount")
}

fn now(value: &str) -> chrono::DateTime<Utc> {
    date(value)
        .and_hms_opt(9, 0, 0)
        .expect("valid fixture time")
        .and_utc()
}

fn history(role: DebtorType, starts_on: &str, ends_before: Option<&str>) -> OccupancyHistoryItem {
    OccupancyHistoryItem {
        id: 1,
        unit_id: 1,
        person_id: 1,
        person_name: "Fixture resident".to_string(),
        person_phone: None,
        person_email: None,
        role,
        start_date: starts_on.to_string(),
        end_date: ends_before.map(str::to_string),
        is_active: ends_before.is_none(),
        exit_balance: Decimal::ZERO,
        notes: None,
        created_at: Utc::now(),
    }
}

async fn state_with_unit(
    monthly_amount: &str,
    proration_enabled: bool,
    created_on: &str,
    tenant_user_id: Option<&str>,
    occupancies: Vec<OccupancyHistoryItem>,
) -> AppState {
    let state = AppState::new_empty();
    let mut inner = state.inner.write().await;
    inner.sites.push(Site {
        id: SITE.to_string(),
        name: "Proration fixture".to_string(),
        address: String::new(),
        slug: "proration-fixture".to_string(),
        status: SiteStatus::Active,
        plan_type: PlanType::Standard,
        license_end_date: date("2027-12-31"),
        timezone: "Europe/Istanbul".to_string(),
        proration_enabled,
        tax_id: None,
        tax_office: None,
    });
    inner.units.push(IndependentUnit {
        id: UNIT.to_string(),
        site_id: SITE.to_string(),
        block_id: "block-1".to_string(),
        unit_number: 14,
        floor: 1,
        land_share: 1,
        owner_user_id: Some("owner-1".to_string()),
        tenant_user_id: tenant_user_id.map(str::to_string),
        virtual_iban: None,
        house_type: Some("2+1".to_string()),
        monthly_tariff_override: None,
        created_on: Some(date(created_on)),
    });
    inner.house_types.push(HouseTypeTariff {
        id: "tariff-1".to_string(),
        site_id: SITE.to_string(),
        type_name: "2+1".to_string(),
        dues_amount: amount(monthly_amount),
        description: None,
    });
    inner.unit_occupancies.insert(UNIT.to_string(), occupancies);
    drop(inner);
    state
}

async fn dues(state: &AppState, period: &str) -> Vec<DuesLiability> {
    state
        .inner
        .read()
        .await
        .dues
        .iter()
        .filter(|due| due.unit_id == UNIT && due.period == period)
        .cloned()
        .collect()
}

async fn manual_accrue(state: &AppState) {
    let request = AccrueDuesPeriodRequest {
        site_id: SITE.to_string(),
        period: "2026-10".to_string(),
        due_date: date("2026-10-15"),
        amount: None,
    };
    let (status, _) = sitepulse_backend::handlers::accrue_monthly_dues(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(request),
    )
    .await
    .expect("manual accrual succeeds");
    assert_eq!(status, axum::http::StatusCode::OK);
}

async fn move_tenant_in_on_october_11(state: &AppState) {
    let mut inner = state.inner.write().await;
    inner
        .units
        .iter_mut()
        .find(|unit| unit.id == UNIT)
        .expect("fixture unit")
        .tenant_user_id = Some("tenant-1".to_string());
    inner.unit_occupancies.insert(
        UNIT.to_string(),
        vec![history(DebtorType::Tenant, "2026-10-11", None)],
    );
}

fn assert_only_original_owner_liability(due: &[DuesLiability]) {
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].debtor_type, DebtorType::Owner);
    assert_eq!(due[0].principal_amount, amount("1400.00"));
}

// covers: SC-07-09-01
#[tokio::test]
async fn when_a_tenant_moves_in_mid_month_then_scheduler_splits_by_actual_days() {
    let state = state_with_unit(
        "1400.00",
        true,
        "2026-01-01",
        Some("tenant-1"),
        vec![history(DebtorType::Tenant, "2026-10-11", None)],
    )
    .await;
    let (_, count) = run_periodic_accrual_for_all_sites(&state, now("2026-10-20")).await;
    assert_eq!(count, 2);

    let due = dues(&state, "Ekim 2026").await;
    let owner = due
        .iter()
        .find(|row| row.debtor_type == DebtorType::Owner)
        .expect("owner share");
    let tenant = due
        .iter()
        .find(|row| row.debtor_type == DebtorType::Tenant)
        .expect("tenant share");
    assert_eq!(owner.principal_amount, amount("451.61"));
    assert_eq!(tenant.principal_amount, amount("948.39"));
    assert_eq!(
        owner.principal_amount + tenant.principal_amount,
        amount("1400.00")
    );
}

// covers: SC-07-09-01
#[tokio::test]
async fn when_manual_accrual_runs_then_it_uses_the_same_occupancy_shares_as_the_scheduler() {
    let state = state_with_unit(
        "1400.00",
        true,
        "2026-01-01",
        Some("tenant-1"),
        vec![history(DebtorType::Tenant, "2026-10-11", None)],
    )
    .await;
    let request = AccrueDuesPeriodRequest {
        site_id: SITE.to_string(),
        period: "2026-10".to_string(),
        due_date: date("2026-10-15"),
        amount: None,
    };
    let (status, _) = sitepulse_backend::handlers::accrue_monthly_dues(
        axum::extract::State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        axum::Json(request),
    )
    .await
    .expect("manual accrual succeeds");
    assert_eq!(status, axum::http::StatusCode::OK);
    let due = dues(&state, "Ekim 2026").await;
    assert_eq!(due.len(), 2);
    assert!(due.iter().any(|row| {
        row.debtor_type == DebtorType::Owner && row.principal_amount == amount("451.61")
    }));
    assert!(due.iter().any(|row| {
        row.debtor_type == DebtorType::Tenant && row.principal_amount == amount("948.39")
    }));
}

// covers: SC-07-09-02
#[tokio::test]
async fn when_a_unit_is_created_mid_month_then_scheduler_charges_only_remaining_days() {
    let state = state_with_unit("1800.00", true, "2026-11-16", None, Vec::new()).await;
    let (_, count) = run_periodic_accrual_for_all_sites(&state, now("2026-11-20")).await;
    assert_eq!(count, 1);
    let due = dues(&state, "Kasım 2026").await;
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].principal_amount, amount("900.00"));
    assert_eq!(due[0].debtor_type, DebtorType::Owner);
}

// covers: SC-07-09-04
#[tokio::test]
async fn when_proration_is_disabled_then_scheduler_keeps_the_full_month_rule() {
    let state = state_with_unit(
        "1400.00",
        false,
        "2026-01-01",
        Some("tenant-1"),
        vec![history(DebtorType::Tenant, "2026-10-11", None)],
    )
    .await;
    let (_, count) = run_periodic_accrual_for_all_sites(&state, now("2026-10-20")).await;
    assert_eq!(count, 1);
    let due = dues(&state, "Ekim 2026").await;
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].principal_amount, amount("1400.00"));
    assert_eq!(due[0].debtor_type, DebtorType::Tenant);
}

// covers: SC-07-09-05
#[tokio::test]
async fn when_scheduler_retries_after_tenant_moves_in_then_existing_unit_charge_blocks_rerun() {
    for proration_enabled in [false, true] {
        let state =
            state_with_unit("1400.00", proration_enabled, "2026-01-01", None, Vec::new()).await;
        let (_, first_count) = run_periodic_accrual_for_all_sites(&state, now("2026-10-20")).await;
        assert_eq!(first_count, 1);
        move_tenant_in_on_october_11(&state).await;

        let (_, retry_count) = run_periodic_accrual_for_all_sites(&state, now("2026-10-20")).await;
        assert_eq!(retry_count, 0);
        assert_only_original_owner_liability(&dues(&state, "Ekim 2026").await);
    }
}

// covers: SC-07-09-06
#[tokio::test]
async fn when_manual_accrual_retries_after_tenant_moves_in_then_existing_unit_charge_blocks_rerun()
{
    for proration_enabled in [false, true] {
        let state =
            state_with_unit("1400.00", proration_enabled, "2026-01-01", None, Vec::new()).await;
        manual_accrue(&state).await;
        assert_only_original_owner_liability(&dues(&state, "Ekim 2026").await);
        move_tenant_in_on_october_11(&state).await;

        manual_accrue(&state).await;
        assert_only_original_owner_liability(&dues(&state, "Ekim 2026").await);
    }
}

#[tokio::test]
async fn when_site_manager_enables_proration_then_policy_is_saved_for_accrual() {
    let state = state_with_unit("1400.00", false, "2026-01-01", None, Vec::new()).await;
    sitepulse_backend::services::occupancy_service::OccupancyService::new(state.clone())
        .set_proration_policy(SITE, true)
        .await
        .expect("policy update succeeds");
    let inner = state.inner.read().await;
    let site = inner
        .sites
        .iter()
        .find(|site| site.id == SITE)
        .expect("site");
    assert!(site.proration_enabled);
}

/// An occupancy row for a named person, so a split can be asserted per debtor.
fn resident(
    role: DebtorType,
    person_id: i64,
    starts_on: &str,
    ends_before: Option<&str>,
) -> OccupancyHistoryItem {
    OccupancyHistoryItem {
        id: person_id,
        unit_id: 1,
        person_id,
        person_name: format!("Resident {person_id}"),
        person_phone: None,
        person_email: None,
        role,
        start_date: starts_on.to_string(),
        end_date: ends_before.map(str::to_string),
        is_active: ends_before.is_none(),
        exit_balance: Decimal::ZERO,
        notes: None,
        created_at: date("2026-01-01")
            .and_hms_opt(0, 0, 0)
            .expect("fixed timestamp")
            .and_utc(),
    }
}

/// The EPIC-13 fixture timeline accrues with a due day of 10, so a mid-month accrual
/// makes the effective due date the accrual date.
async fn with_due_day_10(state: &AppState) {
    state.inner.write().await.site_accrual_schedules.insert(
        SITE.to_string(),
        AccrualSchedule {
            due_day: 10,
            ..AccrualSchedule::default()
        },
    );
}

fn share_of(due: &[DuesLiability], person_id: i64) -> Option<Decimal> {
    due.iter()
        .find(|row| row.liable_person_id == Some(person_id))
        .map(|row| row.principal_amount)
}

// covers: SC-13-01-10
#[tokio::test]
async fn when_a_primary_resident_starts_mid_period_then_only_the_days_after_it_are_charged() {
    let state = state_with_unit(
        "1500.00",
        true,
        "2026-01-01",
        None,
        vec![resident(DebtorType::Owner, 1, "2026-11-02", None)],
    )
    .await;
    run_periodic_accrual_for_all_sites(&state, now("2026-11-10")).await;

    assert!(
        dues(&state, "Ekim 2026").await.is_empty(),
        "the days before 2026-11-02 are charged to nobody"
    );
    let kasim = dues(&state, "Kasım 2026").await;
    assert_eq!(kasim.len(), 1);
    assert_eq!(kasim[0].debtor_type, DebtorType::Owner);
    assert_eq!(
        kasim[0].principal_amount,
        amount("1450.00"),
        "29 of 30 days"
    );
    assert_eq!(kasim[0].liable_person_id, Some(1));
}

// covers: SC-13-03-02
#[tokio::test]
async fn when_a_tenant_is_replaced_mid_month_then_the_earlier_debt_stays_with_the_old_tenant() {
    let state = state_with_unit(
        "1500.00",
        true,
        "2026-01-01",
        Some("person-2"),
        vec![resident(
            DebtorType::Tenant,
            2,
            "2026-10-11",
            Some("2026-11-15"),
        )],
    )
    .await;
    with_due_day_10(&state).await;
    run_periodic_accrual_for_all_sites(&state, now("2026-10-11")).await;

    let ekim = dues(&state, "Ekim 2026").await;
    let ekim_rows = ekim.len();
    let old_tenant = ekim
        .iter()
        .find(|row| row.liable_person_id == Some(2))
        .expect("October tenant share");
    assert_eq!(
        old_tenant.principal_amount,
        amount("1016.13"),
        "21 of 31 days"
    );
    assert_eq!(old_tenant.effective_due_date, Some(date("2026-10-11")));

    {
        let mut inner = state.inner.write().await;
        inner.unit_occupancies.insert(
            UNIT.to_string(),
            vec![
                resident(DebtorType::Tenant, 2, "2026-10-11", Some("2026-11-15")),
                resident(DebtorType::Tenant, 3, "2026-11-15", None),
            ],
        );
        inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .expect("fixture unit")
            .tenant_user_id = Some("person-3".to_string());
    }
    run_periodic_accrual_for_all_sites(&state, now("2026-11-20")).await;

    let kasim = dues(&state, "Kasım 2026").await;
    assert_eq!(share_of(&kasim, 2), Some(amount("700.00")), "days 1 to 14");
    assert_eq!(share_of(&kasim, 3), Some(amount("800.00")), "days 15 to 30");

    let ekim_after = dues(&state, "Ekim 2026").await;
    assert_eq!(
        ekim_after.len(),
        ekim_rows,
        "the replacement adds no October row"
    );
    assert_eq!(
        share_of(&ekim_after, 2),
        Some(amount("1016.13")),
        "October stays the old tenant's"
    );
    assert_eq!(
        share_of(&ekim_after, 3),
        None,
        "the new tenant owes no October"
    );
    let fee = DuesCalculationService::new()
        .calculate_delay_penalty(old_tenant.clone(), date("2026-11-19"))
        .delay_penalty;
    assert_eq!(fee, amount("66.05"), "39 days from the effective due date");
}

// covers: SC-13-03-07
#[tokio::test]
async fn when_two_tenants_hand_over_on_the_same_day_then_no_day_is_unbilled_or_billed_twice() {
    let state = state_with_unit(
        "1500.00",
        true,
        "2026-01-01",
        Some("person-4"),
        vec![
            resident(DebtorType::Tenant, 3, "2026-11-15", Some("2026-12-12")),
            resident(DebtorType::Tenant, 4, "2026-12-12", None),
        ],
    )
    .await;
    run_periodic_accrual_for_all_sites(&state, now("2026-12-12")).await;

    let aralik = dues(&state, "Aralık 2026").await;
    assert_eq!(aralik.len(), 2, "one row per tenant: {aralik:?}");
    let outgoing = share_of(&aralik, 3).expect("outgoing tenant share");
    let incoming = share_of(&aralik, 4).expect("incoming tenant share");
    assert_eq!(outgoing, amount("532.26"), "days 1 to 11");
    assert_eq!(incoming, amount("967.74"), "days 12 to 31");
    assert_eq!(outgoing + incoming, amount("1500.00"));
}

// covers: SC-13-03-21
#[tokio::test]
async fn when_a_period_is_split_then_every_row_names_the_person_who_owes_it() {
    let state = state_with_unit(
        "1500.00",
        true,
        "2026-01-01",
        Some("person-3"),
        vec![
            resident(DebtorType::Owner, 1, "2026-11-01", Some("2026-11-16")),
            resident(DebtorType::Tenant, 3, "2026-11-16", None),
        ],
    )
    .await;
    run_periodic_accrual_for_all_sites(&state, now("2026-11-20")).await;

    let kasim = dues(&state, "Kasım 2026").await;
    assert_eq!(kasim.len(), 2);
    assert!(
        kasim.iter().all(|row| row.liable_person_id.is_some()),
        "an unnamed liability: {kasim:?}"
    );
    let owner = kasim
        .iter()
        .find(|row| row.debtor_type == DebtorType::Owner)
        .expect("owner share");
    let tenant = kasim
        .iter()
        .find(|row| row.debtor_type == DebtorType::Tenant)
        .expect("tenant share");
    assert_eq!(owner.liable_person_id, Some(1));
    assert_eq!(tenant.liable_person_id, Some(3));
    assert_eq!(owner.principal_amount, amount("750.00"));
    assert_eq!(tenant.principal_amount, amount("750.00"));
}
