//! STORY-07-13: a back-dated start residing date posts supplementary charges for the days
//! nobody was billed, without touching a closed month.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::dues_calculation_service::DuesCalculationService;
use sitepulse_backend::services::dues_ledger::allocate_waterfall;
use sitepulse_backend::services::supplementary_charge_service::SupplementaryChargeService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-supplementary";
const UNIT: &str = "1";

fn date(value: &str) -> NaiveDate {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").expect("valid fixture date")
}

fn amount(value: &str) -> Decimal {
    Decimal::from_str_exact(value).expect("valid fixture amount")
}

fn period_row(id: &str, name: &str, due: &str, status: DuesPeriodStatus) -> DuesPeriod {
    DuesPeriod {
        id: id.to_string(),
        site_id: SITE.to_string(),
        period_name: name.to_string(),
        due_date: date(due),
        status,
        created_at: None,
    }
}

fn opened_owner(start: &str) -> OccupancyHistoryItem {
    OccupancyHistoryItem {
        id: 1,
        unit_id: 1,
        person_id: 1,
        person_name: "Fixture owner".to_string(),
        person_phone: None,
        person_email: None,
        role: DebtorType::Owner,
        start_date: start.to_string(),
        end_date: None,
        is_active: true,
        exit_balance: Decimal::ZERO,
        notes: None,
        created_at: Utc::now(),
    }
}

async fn state_with(proration_enabled: bool, periods: Vec<DuesPeriod>) -> AppState {
    let state = AppState::new_empty();
    let mut inner = state.inner.write().await;
    inner.sites.push(Site {
        id: SITE.to_string(),
        name: "Supplementary fixture".to_string(),
        address: String::new(),
        slug: "supplementary-fixture".to_string(),
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
        unit_number: 3,
        floor: 1,
        land_share: 1,
        owner_user_id: None,
        tenant_user_id: None,
        virtual_iban: None,
        house_type: Some("2+1".to_string()),
        monthly_tariff_override: None,

        created_on: Some(date("2026-01-01")),
    });
    inner.house_types.push(HouseTypeTariff {
        id: "tariff-1".to_string(),
        site_id: SITE.to_string(),
        type_name: "2+1".to_string(),
        dues_amount: amount("1500.00"),
        description: None,
    });
    inner.dues_periods = periods;
    drop(inner);
    state
}

async fn post(state: &AppState, start: &str, today: &str) -> Vec<DuesLiability> {
    SupplementaryChargeService::new(state.clone())
        .post_for_opened_session(SITE, &opened_owner(start), date(today))
        .await
        .expect("supplementary charges post")
}

// covers: SC-07-09-07
#[tokio::test]
async fn when_the_month_is_open_then_the_charge_is_posted_in_that_month() {
    let state = state_with(
        true,
        vec![period_row(
            "1",
            "Ekim 2026",
            "2026-10-10",
            DuesPeriodStatus::Active,
        )],
    )
    .await;

    let posted = post(&state, "2026-10-11", "2026-11-19").await;

    assert_eq!(posted.len(), 1);
    assert_eq!(posted[0].period, "Ekim 2026");
    assert_eq!(posted[0].principal_amount, amount("1016.13"));
    assert_eq!(posted[0].debtor_type, DebtorType::Owner);
    assert_eq!(posted[0].due_date, date("2026-10-10"));
    assert_eq!(posted[0].effective_due_date, Some(date("2026-11-19")));
    assert_eq!(posted[0].fee_due_date(), date("2026-11-19"));
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues_source_period
            .get(&posted[0].id)
            .map(String::as_str),
        Some("2026-10")
    );
}

// covers: SC-07-09-08
#[tokio::test]
async fn when_the_month_is_closed_then_the_charge_refers_to_it_but_is_posted_in_the_current_period()
{
    let state = state_with(
        true,
        vec![
            period_row("1", "Ekim 2026", "2026-10-10", DuesPeriodStatus::Closed),
            period_row("2", "Kasım 2026", "2026-11-10", DuesPeriodStatus::Active),
        ],
    )
    .await;

    let posted = post(&state, "2026-10-11", "2026-11-19").await;

    let by_source: Vec<(String, Decimal)> = {
        let inner = state.inner.read().await;
        posted
            .iter()
            .map(|due| {
                (
                    inner.dues_source_period[&due.id].clone(),
                    due.principal_amount,
                )
            })
            .collect()
    };
    assert_eq!(
        by_source,
        vec![
            ("2026-10".to_string(), amount("1016.13")),
            ("2026-11".to_string(), amount("1500.00")),
        ]
    );
    assert!(posted.iter().all(|due| due.period == "Kasım 2026"));
    // The closed month received no liability of its own.
    let inner = state.inner.read().await;
    assert!(inner.dues.iter().all(|due| due.period != "Ekim 2026"));
}

// covers: SC-13-01-14, SC-13-12-03
#[tokio::test]
async fn when_the_charge_is_created_late_then_its_late_fee_counts_from_the_creation_date() {
    let state = state_with(
        true,
        vec![
            period_row("1", "Ekim 2026", "2026-10-10", DuesPeriodStatus::Closed),
            period_row("2", "Kasım 2026", "2026-11-10", DuesPeriodStatus::Active),
        ],
    )
    .await;

    let posted = post(&state, "2026-10-11", "2026-11-19").await;

    let service = DuesCalculationService::new();
    let fees_at = |day: &str| -> Vec<Decimal> {
        posted
            .iter()
            .map(|due| {
                service
                    .calculate_delay_penalty(due.clone(), date(day))
                    .delay_penalty
            })
            .collect()
    };
    assert!(posted
        .iter()
        .all(|due| due.effective_due_date == Some(date("2026-11-19"))));
    assert_eq!(fees_at("2026-11-19"), vec![amount("0.00"), amount("0.00")]);
    assert_eq!(
        fees_at("2026-11-29"),
        vec![amount("16.94"), amount("25.00")]
    );
}

// covers: SC-07-09-09
#[tokio::test]
async fn when_a_month_was_already_billed_then_nothing_is_posted_and_a_repeat_is_idempotent() {
    let state = state_with(
        true,
        vec![period_row(
            "1",
            "Ekim 2026",
            "2026-10-10",
            DuesPeriodStatus::Active,
        )],
    )
    .await;
    state.inner.write().await.dues.push(DuesLiability {
        id: "50".to_string(),
        unit_id: UNIT.to_string(),
        period: "Ekim 2026".to_string(),
        principal_amount: amount("1500.00"),
        delay_penalty: Decimal::ZERO,
        total_amount: amount("1500.00"),
        due_date: date("2026-10-10"),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Tenant,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    });
    assert!(post(&state, "2026-10-11", "2026-11-19").await.is_empty());

    let other = state_with(
        true,
        vec![period_row(
            "1",
            "Ekim 2026",
            "2026-10-10",
            DuesPeriodStatus::Active,
        )],
    )
    .await;
    assert_eq!(post(&other, "2026-10-11", "2026-11-19").await.len(), 1);
    assert!(post(&other, "2026-10-11", "2026-11-19").await.is_empty());
}

#[tokio::test]
async fn when_proration_is_disabled_then_no_charge_is_posted() {
    let state = state_with(
        false,
        vec![period_row(
            "1",
            "Ekim 2026",
            "2026-10-10",
            DuesPeriodStatus::Active,
        )],
    )
    .await;
    assert!(post(&state, "2026-10-11", "2026-11-19").await.is_empty());
}

#[tokio::test]
async fn when_the_current_period_is_also_closed_then_posting_is_refused() {
    let state = state_with(
        true,
        vec![
            period_row("1", "Ekim 2026", "2026-10-10", DuesPeriodStatus::Closed),
            period_row("2", "Kasım 2026", "2026-11-10", DuesPeriodStatus::Closed),
        ],
    )
    .await;
    let result = SupplementaryChargeService::new(state.clone())
        .post_for_opened_session(SITE, &opened_owner("2026-10-11"), date("2026-11-19"))
        .await;
    assert!(result.is_err());
    assert!(state.inner.read().await.dues.is_empty());
}

// covers: SC-07-09-10
#[tokio::test]
async fn when_a_supplementary_charge_refers_to_an_older_month_then_fifo_settles_it_first() {
    let state = state_with(
        true,
        vec![
            period_row("1", "Ekim 2026", "2026-10-10", DuesPeriodStatus::Closed),
            period_row("2", "Kasım 2026", "2026-11-10", DuesPeriodStatus::Active),
        ],
    )
    .await;
    let posted = post(&state, "2026-10-11", "2026-11-19").await;
    let mut dues: Vec<DuesLiability> = posted.into_iter().rev().collect();
    let all: Vec<usize> = (0..dues.len()).collect();

    let (lines, remainder) = allocate_waterfall(&mut dues, &all, amount("1016.13"));

    assert_eq!(remainder, Decimal::ZERO);
    assert_eq!(lines.len(), 1);
    assert_eq!(dues[lines[0].due_index].due_date, date("2026-10-10"));
    assert_eq!(dues[lines[0].due_index].status, DebtStatus::Paid);
}

// covers: SC-07-09-08
#[tokio::test]
async fn when_no_period_can_take_the_charge_then_the_handler_refuses_before_the_transition() {
    use axum::response::IntoResponse;
    use sitepulse_backend::handlers::{apply_occupancy_transition, SiteIdParam};

    let today = sitepulse_backend::scheduler::site_local_date("Europe/Istanbul", Utc::now());
    let month = sitepulse_backend::domain::billing_period::BillingPeriod::of_date(today);
    let state = state_with(
        true,
        vec![DuesPeriod {
            id: "1".to_string(),
            site_id: SITE.to_string(),
            period_name: month.label(),
            due_date: month.last_day(),
            status: DuesPeriodStatus::Closed,
            created_at: None,
        }],
    )
    .await;
    let token =
        sitepulse_backend::auth::issue_token("usr-manager", "", Role::SiteManager, SITE, None)
            .expect("token");
    let ctx = sitepulse_backend::authorization::AuthzContext {
        claims: sitepulse_backend::auth::verify_token(&token).expect("claims"),
        permissions: Permission::permissions_for_role(Role::SiteManager),
        request_id: "supplementary".to_string(),
        stepped_up: false,
    };
    let request = OccupancyTransitionRequest {
        command: sitepulse_backend::domain::unit_state::CommandKind::OwnerMoveIn,
        effective_date: Some(month.first_day()),
        person: None,
        person_id: None,
        full_name: None,
        phone: None,
        email: None,
        owner_person_id: None,
        notes: None,
    };

    let result = apply_occupancy_transition(
        axum::extract::State(state.clone()),
        ctx,
        sitepulse_backend::tenancy::TenantScope::site(SITE),
        axum::extract::Path(UNIT.to_string()),
        axum::extract::Query(SiteIdParam {
            site_id: Some(SITE.to_string()),
        }),
        axum::Json(request),
    )
    .await;

    let response = result
        .expect_err("the whole transition is refused")
        .into_response();
    assert_eq!(response.status(), axum::http::StatusCode::CONFLICT);
    let inner = state.inner.read().await;
    assert!(inner.dues.is_empty());
    assert!(inner
        .unit_occupancies
        .get(UNIT)
        .is_none_or(|h| h.is_empty()));
}
