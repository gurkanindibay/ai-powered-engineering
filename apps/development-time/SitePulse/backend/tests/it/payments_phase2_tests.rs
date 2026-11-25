//! SPEC-007 acceptance tests (in-memory): işletme projesi lifecycle and accrual
//! basis (R5), card payments through the provider (R4), the resident statement
//! (R2) and the receipt PDF and verification (R3). Virman reversal (R1) is in
//! payment_ledger_hardening_tests.rs. PostgreSQL behaviour is covered by the
//! schema-integrity gate and the API system check.

use axum::extract::{Json, Query, State};
use chrono::{Datelike, Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::card_payment_service::{self, CardPaymentError};
use sitepulse_backend::services::operating_budget_service::{allocate_by_weight, BudgetError};
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";
const ACTOR: &str = "user:usr-site-manager-1 <mehmet.demir@begonya.com>";

fn operator(id: &str) -> sitepulse_backend::authorization::AuthzContext {
    let token =
        sitepulse_backend::auth::issue_token(id, "", Role::SiteManager, SITE, None).unwrap();
    let mut claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    claims.role = Role::SiteManager;
    claims.site_id = SITE.to_string();
    sitepulse_backend::authorization::AuthzContext {
        claims,
        permissions: Permission::permissions_for_role(Role::SiteManager),
        request_id: "spec-006".to_string(),
        stepped_up: false,
    }
}

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

/// Today in the site's time zone, the date every service works with.
fn today() -> NaiveDate {
    crate::support::site_today()
}

/// Site 1 with two units: A-14 (land share 24, 3+1, ₺1.800) and A-15 (land share 12,
/// 2+1, ₺1.400); no dues, payments or budgets.
async fn site_with_two_units() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner.payment_idempotency.clear();
        let mut second = inner
            .units
            .iter()
            .find(|u| u.id == "d-14")
            .cloned()
            .unwrap();
        second.id = "d-15".to_string();
        second.unit_number = 15;
        second.land_share = 12;
        second.house_type = Some("2+1".to_string());
        second.virtual_iban = None;
        inner.units.push(second);
    }
    state
}

fn line(category: &str, amount: &str, key: &str) -> BudgetLineInput {
    BudgetLineInput {
        category: category.to_string(),
        description: None,
        annual_amount: d(amount),
        allocation_key: Some(key.to_string()),
        unit_weights: Vec::new(),
    }
}

fn budget_request(year: i32, lines: Vec<BudgetLineInput>) -> CreateOperatingBudgetRequest {
    CreateOperatingBudgetRequest {
        site_id: None,
        fiscal_year: year,
        period_start: None,
        period_end: None,
        notes: None,
        lines,
    }
}

// ---------------------------------------------------------------------------
// R5: işletme projesi
// ---------------------------------------------------------------------------

#[test]
fn when_an_amount_is_split_by_weight_then_the_parts_add_up_to_the_kurus() {
    let parts = allocate_by_weight(d("1000.00"), &[1, 1, 1]);
    assert_eq!(parts, vec![d("333.34"), d("333.33"), d("333.33")]);
    let parts = allocate_by_weight(d("100.00"), &[24, 12, 7]);
    assert_eq!(parts.iter().copied().sum::<Decimal>(), d("100.00"));
    assert_eq!(parts, vec![d("55.81"), d("27.91"), d("16.28")]);
}

#[tokio::test]
async fn when_a_draft_budget_is_created_then_unit_shares_follow_land_share_and_equal_keys() {
    let state = site_with_two_units().await;
    let budget = OperatingBudgetService::new(state)
        .create_draft(
            SITE,
            budget_request(
                today().year(),
                vec![
                    line("CLEANING", "36000.00", "LAND_SHARE"),
                    line("MANAGEMENT_FEE", "2400.00", "EQUAL"),
                ],
            ),
            ACTOR,
        )
        .await
        .unwrap();
    assert_eq!(budget.status, "DRAFT");
    assert_eq!(budget.total_annual_amount, d("38400.00"));
    // First budget: measured against the current tariffs' yearly run-rate (1.800 + 1.400) x 12.
    assert_eq!(budget.baseline_annual_amount, d("38400.00"));
    assert_eq!(budget.increase_rate, Some(Decimal::ZERO));
    let a14 = budget.share_of("d-14").unwrap();
    let a15 = budget.share_of("d-15").unwrap();
    assert_eq!(a14.annual_amount, d("25200.00")); // 24/36 of 36.000 + 1.200
    assert_eq!(a15.annual_amount, d("13200.00")); // 12/36 of 36.000 + 1.200
    assert_eq!(a14.monthly_amount, d("2100.00"));
    assert_eq!(a15.monthly_amount, d("1100.00"));
}

#[tokio::test]
async fn when_an_interim_budget_exceeds_the_revaluation_rate_then_it_is_refused_and_the_assembly_can_approve_it(
) {
    let state = site_with_two_units().await;
    let service = OperatingBudgetService::new(state.clone());
    // 38.400 -> 50.000 is +30.2%, above the 2026 rate of 25.49%.
    let budget = service
        .create_draft(
            SITE,
            budget_request(2026, vec![line("PERSONNEL", "50000.00", "LAND_SHARE")]),
            ACTOR,
        )
        .await
        .unwrap();
    let err = service
        .issue_interim(SITE, &budget.id, IssueInterimBudgetRequest::default())
        .await
        .unwrap_err();
    match err {
        BudgetError::Conflict(m) => assert!(
            m.contains("revaluation rate") && m.contains("25.49"),
            "{}",
            m
        ),
        other => panic!("expected a conflict, got {:?}", other),
    }
    assert_eq!(service.get(SITE, &budget.id).await.unwrap().status, "DRAFT");

    let approved = service
        .approve(
            SITE,
            &budget.id,
            ApproveBudgetRequest {
                assembly_decision_ref: "Karar 2026/3".to_string(),
                assembly_decision_date: today() - Days::new(1),
            },
        )
        .await
        .unwrap();
    assert_eq!(approved.status, "APPROVED");
    assert_eq!(
        approved.assembly_decision_ref.as_deref(),
        Some("Karar 2026/3")
    );
}

#[tokio::test]
async fn when_an_interim_budget_is_within_the_cap_then_it_is_in_force_with_a_three_month_deadline()
{
    let state = site_with_two_units().await;
    let service = OperatingBudgetService::new(state.clone());
    // +20%: within 25.49%.
    let budget = service
        .create_draft(
            SITE,
            budget_request(2026, vec![line("PERSONNEL", "46080.00", "LAND_SHARE")]),
            ACTOR,
        )
        .await
        .unwrap();
    let issued_on = NaiveDate::from_ymd_opt(2026, 1, 10).unwrap();
    let interim = service
        .issue_interim(
            SITE,
            &budget.id,
            IssueInterimBudgetRequest {
                issued_on: Some(issued_on),
            },
        )
        .await
        .unwrap();
    assert_eq!(interim.status, "INTERIM");
    assert_eq!(interim.cap_rate, Some(d("25.4900")));
    assert_eq!(
        interim.interim_deadline,
        Some(NaiveDate::from_ymd_opt(2026, 4, 10).unwrap())
    );

    // The assembly later approves a different budget for the same year: the interim is superseded.
    let assembly = service
        .create_draft(
            SITE,
            budget_request(2026, vec![line("PERSONNEL", "40000.00", "LAND_SHARE")]),
            ACTOR,
        )
        .await
        .unwrap();
    service
        .approve(
            SITE,
            &assembly.id,
            ApproveBudgetRequest {
                assembly_decision_ref: "Karar 2026/1".into(),
                assembly_decision_date: issued_on,
            },
        )
        .await
        .unwrap();
    assert_eq!(
        service.get(SITE, &budget.id).await.unwrap().status,
        "SUPERSEDED"
    );
}

async fn accrue(
    state: &AppState,
    _label: &str,
    amount: &str,
    due: NaiveDate,
) -> Result<AccrueDuesPeriodResponse, (axum::http::StatusCode, String)> {
    let amt = if amount.is_empty() || amount == "0" {
        None
    } else {
        Some(d(amount))
    };
    sitepulse_backend::handlers::accrue_monthly_dues(
        State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        Json(AccrueDuesPeriodRequest {
            site_id: SITE.to_string(),
            // A period is a canonical month (STORY-07-08): the one of the due date.
            period: sitepulse_backend::domain::billing_period::BillingPeriod::of_date(due).key(),
            amount: amt,
            due_date: due,
        }),
    )
    .await
    .map(|(_, Json(r))| r)
}

#[tokio::test]
async fn when_a_budget_is_in_force_then_dues_are_accrued_from_unit_shares_with_the_budget_as_legal_basis(
) {
    let state = site_with_two_units().await;
    let service = OperatingBudgetService::new(state.clone());
    let year = today().year();
    let budget = service
        .create_draft(
            SITE,
            budget_request(
                year,
                vec![
                    line("CLEANING", "36000.00", "LAND_SHARE"),
                    line("MANAGEMENT_FEE", "2400.00", "EQUAL"),
                ],
            ),
            ACTOR,
        )
        .await
        .unwrap();
    service
        .issue_interim(SITE, &budget.id, IssueInterimBudgetRequest::default())
        .await
        .unwrap();

    let due = today() + Days::new(10);
    let resp = accrue(&state, "Test Dönemi", "0", due).await.unwrap();
    assert_eq!(resp.newly_accrued_units_count, 2);
    assert_eq!(resp.total_amount_accrued, d("3200.00"));
    assert_eq!(
        resp.operating_budget_id.as_deref(),
        Some(budget.id.as_str())
    );
    assert!(resp.legal_basis_warning.is_none());
    {
        let inner = state.inner.read().await;
        let a14 = inner.dues.iter().find(|x| x.unit_id == "d-14").unwrap();
        assert_eq!(a14.principal_amount, d("2100.00"));
        assert_eq!(a14.debtor_type, DebtorType::Owner);
        assert_eq!(inner.dues_budget_basis.get(&a14.id), Some(&budget.id));
    }

    // A typed amount is refused while a budget is in force.
    let (status, msg) = accrue(&state, "Başka Dönem", "999.00", due)
        .await
        .unwrap_err();
    assert_eq!(status, axum::http::StatusCode::CONFLICT, "{}", msg);
}

#[tokio::test]
async fn when_a_site_requires_a_budget_and_none_is_in_force_then_accrual_is_refused() {
    let state = site_with_two_units().await;
    OperatingBudgetService::new(state.clone())
        .set_policy(SITE, true)
        .await
        .unwrap();
    let (status, msg) = accrue(&state, "Test Dönemi", "0", today() + Days::new(5))
        .await
        .unwrap_err();
    assert_eq!(status, axum::http::StatusCode::CONFLICT);
    assert!(msg.contains("işletme projesi"), "{}", msg);
    assert!(state.inner.read().await.dues.is_empty());
}

#[tokio::test]
async fn when_no_budget_exists_then_legacy_tariff_accrual_carries_a_kmk37_warning() {
    let state = site_with_two_units().await;
    let resp = accrue(&state, "Test Dönemi", "0", today() + Days::new(5))
        .await
        .unwrap();
    assert_eq!(resp.total_amount_accrued, d("3200.00")); // 1.800 + 1.400 tariffs
    assert!(resp.legal_basis_warning.unwrap().contains("KMK 37"));
}

#[tokio::test]
async fn when_a_unit_has_no_tariff_then_manual_accrual_skips_it_instead_of_charging_a_fixed_amount()
{
    let state = site_with_two_units().await;
    {
        let mut inner = state.inner.write().await;
        let mut untariffed = inner
            .units
            .iter()
            .find(|u| u.id == "d-15")
            .cloned()
            .unwrap();
        untariffed.id = "d-16".to_string();
        untariffed.unit_number = 16;
        untariffed.house_type = None;
        inner.units.push(untariffed);
    }
    // The manager's dialog sends no amount: the request body omits it.
    let tariff_due = today() + Days::new(5);
    let tariff_period =
        sitepulse_backend::domain::billing_period::BillingPeriod::of_date(tariff_due);
    let request: AccrueDuesPeriodRequest = serde_json::from_value(serde_json::json!({
        "site_id": SITE,
        "period": tariff_period.key(),
        "due_date": tariff_due.to_string(),
    }))
    .unwrap();
    assert_eq!(request.amount, None);
    let (_, Json(resp)) = sitepulse_backend::handlers::accrue_monthly_dues(
        State(state.clone()),
        sitepulse_backend::tenancy::TenantScope::platform(),
        Json(request),
    )
    .await
    .unwrap();

    assert_eq!(resp.newly_accrued_units_count, 2);
    assert_eq!(resp.total_amount_accrued, d("3200.00")); // 1.800 + 1.400 tariffs
    assert_eq!(resp.skipped_units.len(), 1, "{:?}", resp.skipped_units);
    assert!(resp.skipped_units[0].contains("no house-type tariff"));
    assert!(resp.message.contains("1 daire atlandı"), "{}", resp.message);
    let inner = state.inner.read().await;
    let charged = |unit: &str| {
        inner
            .dues
            .iter()
            .find(|d| d.unit_id == unit && d.period == tariff_period.label())
            .map(|d| d.principal_amount)
    };
    assert_eq!(charged("d-14"), Some(d("1800.00")));
    assert_eq!(charged("d-15"), Some(d("1400.00")));
    assert_eq!(
        charged("d-16"),
        None,
        "no invented amount for a unit without a tariff"
    );
}

#[tokio::test]
async fn when_an_approved_budget_is_served_and_the_window_closes_then_it_becomes_final_unless_an_objection_is_upheld(
) {
    let state = site_with_two_units().await;
    let service = OperatingBudgetService::new(state.clone());
    let decided = today() - Days::new(30);
    let budget = service
        .create_draft(
            SITE,
            budget_request(
                today().year(),
                vec![line("ENERGY", "12000.00", "LAND_SHARE")],
            ),
            ACTOR,
        )
        .await
        .unwrap();
    service
        .approve(
            SITE,
            &budget.id,
            ApproveBudgetRequest {
                assembly_decision_ref: "Karar 7".into(),
                assembly_decision_date: decided,
            },
        )
        .await
        .unwrap();
    let served_on = today() - Days::new(20);
    for unit in ["d-14", "d-15"] {
        service
            .record_service(
                SITE,
                &budget.id,
                RecordBudgetServiceRequest {
                    unit_id: unit.into(),
                    recipient_name: "Kat Maliki".into(),
                    method: "REGISTERED_MAIL".into(),
                    served_on,
                },
            )
            .await
            .unwrap();
    }
    // Objection after the 7-day window is refused.
    let late = service
        .file_objection(
            SITE,
            &budget.id,
            FileBudgetObjectionRequest {
                unit_id: "d-15".into(),
                objector_name: "Ayşe".into(),
                filed_on: Some(today()),
                reason: "Tutar yüksek".into(),
            },
        )
        .await
        .unwrap_err();
    assert!(matches!(late, BudgetError::Conflict(_)));
    // An objection inside the window that is upheld blocks finalization.
    let with_objection = service
        .file_objection(
            SITE,
            &budget.id,
            FileBudgetObjectionRequest {
                unit_id: "d-15".into(),
                objector_name: "Ayşe".into(),
                filed_on: Some(served_on + Days::new(3)),
                reason: "Pay hatalı".into(),
            },
        )
        .await
        .unwrap();
    let objection_id = with_objection.objections[0].id.clone();
    assert!(
        matches!(service.finalize(SITE, &budget.id, today()).await.unwrap_err(), BudgetError::Conflict(m) if m.contains("still open"))
    );
    service
        .resolve_objection(
            SITE,
            &budget.id,
            &objection_id,
            ResolveBudgetObjectionRequest {
                status: "DISMISSED".into(),
                resolution_note: None,
            },
        )
        .await
        .unwrap();
    let fin = service.finalize(SITE, &budget.id, today()).await.unwrap();
    assert_eq!(fin.status, "FINAL");
    assert_eq!(fin.objection_deadline, Some(served_on + Days::new(7)));
}

// ---------------------------------------------------------------------------
// R4: card payments
// ---------------------------------------------------------------------------

fn event(intent: &PaymentIntent, status: &str) -> ProviderWebhookEvent {
    ProviderWebhookEvent {
        provider: intent.provider.clone(),
        provider_ref: intent.provider_ref.clone(),
        status: status.to_string(),
        amount: intent.amount,
        fee_amount: None,
        three_ds_status: Some("Y".to_string()),
        failure_reason: None,
    }
}

async fn owner_owing(amount: &str) -> AppState {
    let state = site_with_two_units().await;
    state.inner.write().await.dues.push(DuesLiability {
        id: "op-1".to_string(),
        unit_id: "d-14".to_string(),
        period: "Kasım 2026".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: today() + Days::new(5),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    });
    state
}

#[tokio::test]
async fn when_a_card_payment_is_captured_then_it_is_recorded_once_through_the_ingestion_path() {
    let state = owner_owing("1800.00").await;
    let service = CardPaymentService::new(state.clone());
    let intent = service
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("1800.00"),
                ..Default::default()
            },
            Some("OWNER"),
            ACTOR,
        )
        .await
        .unwrap();
    assert_eq!(intent.status, "CREATED");
    assert_eq!(intent.provider, "SANDBOX");
    assert!(intent
        .checkout_url
        .as_deref()
        .unwrap()
        .contains(&intent.provider_ref));

    service
        .apply_provider_event(event(&intent, "AUTHORIZED"))
        .await
        .unwrap();
    let captured = service
        .apply_provider_event(event(&intent, "CAPTURED"))
        .await
        .unwrap();
    assert_eq!(captured.status, "CAPTURED");
    let number = captured.receipt_number.clone().unwrap();
    assert!(number.starts_with("TAH-"));
    // A repeated notification changes nothing.
    let again = service
        .apply_provider_event(event(&intent, "CAPTURED"))
        .await
        .unwrap();
    assert_eq!(again.receipt_number.as_deref(), Some(number.as_str()));
    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    let receipt = &inner.payment_receipts[0];
    assert_eq!(receipt.payment_channel, PaymentChannel::CreditCard);
    assert_eq!(
        inner.dues.iter().find(|x| x.id == "op-1").unwrap().status,
        DebtStatus::Paid
    );
}

#[tokio::test]
// Backend coverage: SC-13-05-17 owner payment allocation through the card capture path.
async fn when_an_owner_card_payment_targets_a_joint_tenant_balance_then_only_that_debt_is_paid() {
    let state = owner_owing("100.00").await;
    let owner_person_id;
    {
        let mut inner = state.inner.write().await;
        let unit = inner.units.iter().find(|unit| unit.id == "d-14").unwrap();
        owner_person_id = inner
            .users
            .iter()
            .find(|user| Some(&user.id) == unit.owner_user_id.as_ref())
            .and_then(|user| user.person_id)
            .unwrap();
        inner.dues.push(DuesLiability {
            id: "tenant-card-due".to_string(),
            unit_id: "d-14".to_string(),
            period: "October 2026".to_string(),
            principal_amount: d("100.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("100.00"),
            due_date: today() + Days::new(5),
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
        inner.joint_liability_owners.insert(
            "tenant-card-due".to_string(),
            vec![JointLiabilityOwner {
                person_id: owner_person_id,
                tenant_person_id: None,
                start_date: today(),
                end_date: Some(today() + Days::new(5)),
            }],
        );
    }
    let service = CardPaymentService::new(state.clone());
    let intent = service
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("100.00"),
                pays_tenant_liability: true,
                designation: Some(PaymentDesignation {
                    due_ids: vec!["tenant-card-due".to_string()],
                    ..PaymentDesignation::default()
                }),
                ..Default::default()
            },
            Some("OWNER"),
            ACTOR,
        )
        .await
        .unwrap();
    assert_eq!(intent.debtor_type, "TENANT");
    assert!(intent.pays_tenant_liability);
    let captured = service
        .apply_provider_event(event(&intent, "CAPTURED"))
        .await
        .unwrap();
    assert_eq!(captured.status, "CAPTURED");
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "op-1")
            .unwrap()
            .paid_principal,
        Decimal::ZERO
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "tenant-card-due")
            .unwrap()
            .paid_principal,
        d("100.00")
    );
    let receipt = inner.payment_receipts.last().unwrap();
    assert_eq!(receipt.payer_role, DebtorType::Owner);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Tenant));
}

#[tokio::test]
async fn when_the_provider_amount_differs_or_a_resident_pays_another_debtor_then_it_is_refused() {
    let state = owner_owing("500.00").await;
    let service = CardPaymentService::new(state.clone());
    let intent = service
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("500.00"),
                ..Default::default()
            },
            Some("OWNER"),
            ACTOR,
        )
        .await
        .unwrap();
    let mut wrong = event(&intent, "CAPTURED");
    wrong.amount = d("5.00");
    assert!(matches!(
        service.apply_provider_event(wrong).await.unwrap_err(),
        CardPaymentError::Conflict(_)
    ));
    assert!(state.inner.read().await.payment_receipts.is_empty());

    let other = service
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("10.00"),
                debtor_type: Some("TENANT".into()),
                ..Default::default()
            },
            Some("OWNER"),
            ACTOR,
        )
        .await
        .unwrap_err();
    assert!(matches!(other, CardPaymentError::Invalid(_)));

    let failed = service
        .apply_provider_event(ProviderWebhookEvent {
            failure_reason: Some("Yetersiz bakiye".into()),
            ..event(&intent, "FAILED")
        })
        .await
        .unwrap();
    assert_eq!(failed.status, "FAILED");
    assert_eq!(failed.failure_reason.as_deref(), Some("Yetersiz bakiye"));
}

#[test]
fn when_a_provider_body_is_signed_then_only_that_body_verifies() {
    let body = br#"{"provider":"SANDBOX"}"#;
    let sig = card_payment_service::sign_provider_body(body);
    assert!(card_payment_service::verify_provider_signature(
        body,
        Some(&sig)
    ));
    assert!(!card_payment_service::verify_provider_signature(
        b"{}",
        Some(&sig)
    ));
    assert!(!card_payment_service::verify_provider_signature(body, None));
}

#[tokio::test]
async fn when_a_card_receipt_is_reversed_then_the_intent_is_refunded() {
    let state = owner_owing("300.00").await;
    let service = CardPaymentService::new(state.clone());
    let intent = service
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("300.00"),
                ..Default::default()
            },
            None,
            ACTOR,
        )
        .await
        .unwrap();
    let captured = service
        .apply_provider_event(event(&intent, "CAPTURED"))
        .await
        .unwrap();
    let number = captured.receipt_number.unwrap();
    PaymentTrackingService::new(state.clone())
        .reverse_payment(
            ReversePaymentRequest {
                site_id: Some(SITE.into()),
                receipt: number.clone(),
                reason: "Kart itirazı".into(),
            },
            &operator("usr-site-manager-1"),
        )
        .await
        .unwrap();
    let refunded = service
        .refund_for_receipt(SITE, &number)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(refunded.status, "REFUNDED");
}

// ---------------------------------------------------------------------------
// R2: resident statement
// ---------------------------------------------------------------------------

#[tokio::test]
async fn when_a_statement_is_built_then_items_are_aged_and_each_debtor_sees_only_their_own() {
    let state = site_with_two_units().await;
    {
        let mut inner = state.inner.write().await;
        let mk = |id: &str, debtor: &str, days_ago: u64, amount: &str| DuesLiability {
            id: id.to_string(),
            unit_id: "d-14".to_string(),
            period: id.to_string(),
            principal_amount: d(amount),
            delay_penalty: Decimal::ZERO,
            total_amount: d(amount),
            due_date: today() - Days::new(days_ago),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::from_str_loose(debtor),
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        };
        inner.dues.push(mk("o-current", "OWNER", 0, "100.00"));
        inner.dues.push(mk("o-45", "OWNER", 45, "200.00"));
        inner.dues.push(mk("o-120", "OWNER", 120, "300.00"));
        inner.dues.push(mk("t-10", "TENANT", 10, "50.00"));
    }
    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == "d-14").unwrap();
    let staff = resident_statement::build_statement(&inner, unit, None, today());
    let owner = staff
        .debtors
        .iter()
        .find(|x| x.debtor_type == "OWNER")
        .unwrap();
    assert_eq!(owner.current_due, d("100.00"));
    assert_eq!(owner.overdue_31_60_days, d("200.00"));
    assert_eq!(owner.overdue_90_plus_days, d("300.00"));
    assert_eq!(owner.principal_outstanding, d("600.00"));
    assert!(
        owner.penalty_outstanding > Decimal::ZERO,
        "overdue items accrue the KMK 20 penalty"
    );
    assert_eq!(
        owner.total_outstanding,
        owner.principal_outstanding + owner.penalty_outstanding
    );
    assert_eq!(
        owner.open_items.first().unwrap().due_id,
        "o-120",
        "oldest first"
    );
    assert!(staff.debtors.iter().any(|x| x.debtor_type == "TENANT"));

    let own = resident_statement::build_statement(&inner, unit, Some("OWNER"), today());
    assert_eq!(own.debtors.len(), 1);
    assert_eq!(own.debtors[0].debtor_type, "OWNER");
}

#[tokio::test]
async fn when_receipt_viewer_shares_a_name_but_not_person_id_then_receipt_is_hidden() {
    let state = site_with_two_units().await;
    let (owner_person_id, owner_name) = {
        let inner = state.inner.read().await;
        let unit = inner.units.iter().find(|unit| unit.id == "d-14").unwrap();
        let owner = inner
            .users
            .iter()
            .find(|user| Some(&user.id) == unit.owner_user_id.as_ref())
            .unwrap();
        (owner.person_id.unwrap(), owner.full_name.clone())
    };
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.to_string()),
            unit_id: "d-14".to_string(),
            amount: d("100.00"),
            payer_name: owner_name.clone(),
            payer_role: DebtorType::Owner,
            ..RecordManualPaymentRequest::default()
        })
        .await
        .unwrap();
    assert_eq!(receipt.payer_person_id, Some(owner_person_id));

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|unit| unit.id == "d-14").unwrap();
    let own_statement = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("OWNER"),
        Some(owner_person_id),
        today(),
    );
    assert!(own_statement
        .receipts
        .iter()
        .any(|item| item.receipt_number == receipt.receipt_number));
    let same_name_account = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("OWNER"),
        Some(owner_person_id + 100_000),
        today(),
    );
    assert!(!same_name_account
        .receipts
        .iter()
        .any(|item| item.receipt_number == receipt.receipt_number));
}

#[tokio::test]
// Backend coverage: SC-13-05-06 (tenant debt remains singular) and SC-13-05-17 (owner sees joint balance without tenant receipts).
async fn when_a_tenant_liability_has_an_owner_link_then_owner_sees_only_its_joint_balance() {
    let state = site_with_two_units().await;
    let today = today();
    let owner_person_id;
    {
        let mut inner = state.inner.write().await;
        let unit = inner.units.iter().find(|unit| unit.id == "d-14").unwrap();
        owner_person_id = inner
            .users
            .iter()
            .find(|user| Some(&user.id) == unit.owner_user_id.as_ref())
            .and_then(|user| user.person_id)
            .unwrap();
        inner.dues.push(DuesLiability {
            id: "tenant-joint-due".to_string(),
            unit_id: "d-14".to_string(),
            period: "October 2026".to_string(),
            principal_amount: d("4500.00"),
            delay_penalty: d("297.50"),
            total_amount: d("4797.50"),
            due_date: today - Days::new(30),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
        inner.joint_liability_owners.insert(
            "tenant-joint-due".to_string(),
            vec![JointLiabilityOwner {
                person_id: owner_person_id,
                tenant_person_id: None,
                start_date: today - Days::new(60),
                end_date: Some(today),
            }],
        );
    }

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|unit| unit.id == "d-14").unwrap();
    let owner = resident_statement::build_statement(&inner, unit, Some("OWNER"), today);
    let owner_debtor = owner.debtors.first().unwrap();
    assert_eq!(owner_debtor.total_outstanding, Decimal::ZERO);
    assert_eq!(owner_debtor.jointly_liable_total, d("4797.50"));
    assert_eq!(owner_debtor.jointly_liable_open_items.len(), 1);
    assert_eq!(owner.receipts.len(), 0);

    let tenant = resident_statement::build_statement(&inner, unit, Some("TENANT"), today);
    assert_eq!(tenant.debtors.len(), 1);
    assert_eq!(tenant.debtors[0].total_outstanding, d("4797.50"));
    assert_eq!(tenant.debtors[0].jointly_liable_total, Decimal::ZERO);
}

#[tokio::test]
// covers: SC-13-25-07, SC-13-14-09 (Issue #295: unit statement groups open items by liable person)
async fn when_unit_has_former_and_current_debtors_then_each_receives_distinct_statement_entry() {
    let state = site_with_two_units().await;
    let today = today();
    {
        let mut inner = state.inner.write().await;
        let make_user = |id: &str, pid: i64, name: &str, role: Role| User {
            id: id.to_string(),
            site_id: SITE.to_string(),
            full_name: name.to_string(),
            email: format!("{id}@sitepulse.local"),
            phone: "05550000000".to_string(),
            password_hash: None,
            role,
            must_change_password: false,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: Some(pid),
        };
        inner
            .users
            .push(make_user("person-101", 101, "Ada Kaya", Role::HomeOwner));
        inner
            .users
            .push(make_user("person-102", 102, "Ben Kaya", Role::HomeOwner));
        inner.users.push(make_user(
            "person-201",
            201,
            "Dan Yılmaz",
            Role::HomeResident,
        ));
        inner
            .users
            .push(make_user("person-203", 203, "Eli Şen", Role::HomeResident));

        let unit = inner.units.iter_mut().find(|u| u.id == "d-14").unwrap();
        unit.owner_user_id = Some("person-102".to_string());
        unit.tenant_user_id = Some("person-203".to_string());

        // Ada (former owner): February due
        inner.dues.push(DuesLiability {
            id: "due-ada-feb".to_string(),
            unit_id: "d-14".to_string(),
            period: "Şubat 2027".to_string(),
            principal_amount: d("800.00"),
            delay_penalty: d("78.67"),
            total_amount: d("878.67"),
            due_date: today - Days::new(60),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(101),
        });

        // Ben (current owner): April due
        inner.dues.push(DuesLiability {
            id: "due-ben-apr".to_string(),
            unit_id: "d-14".to_string(),
            period: "Nisan 2027".to_string(),
            principal_amount: d("500.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("500.00"),
            due_date: today,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(102),
        });

        // Dan (former tenant): February due
        inner.dues.push(DuesLiability {
            id: "due-dan-feb".to_string(),
            unit_id: "d-14".to_string(),
            period: "Şubat 2027".to_string(),
            principal_amount: d("750.00"),
            delay_penalty: d("73.75"),
            total_amount: d("823.75"),
            due_date: today - Days::new(60),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(201),
        });

        // Eli (current tenant): April due
        inner.dues.push(DuesLiability {
            id: "due-eli-apr".to_string(),
            unit_id: "d-14".to_string(),
            period: "Nisan 2027".to_string(),
            principal_amount: d("400.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("400.00"),
            due_date: today,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(203),
        });
    }

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == "d-14").unwrap();
    let statement = resident_statement::build_statement(&inner, unit, None, today);

    assert_eq!(statement.debtors.len(), 4);

    let ben = &statement.debtors[0];
    assert_eq!(ben.debtor_type, "OWNER");
    assert_eq!(ben.name, "Ben Kaya");
    assert_eq!(ben.principal_outstanding, d("500.00"));
    assert_eq!(ben.total_outstanding, d("500.00"));
    assert_eq!(ben.open_items.len(), 1);
    assert_eq!(ben.open_items[0].due_id, "due-ben-apr");

    let ada = &statement.debtors[1];
    assert_eq!(ada.debtor_type, "OWNER");
    assert_eq!(ada.name, "Ada Kaya");
    assert_eq!(ada.principal_outstanding, d("800.00"));
    assert_eq!(ada.penalty_outstanding, d("78.67"));
    assert_eq!(ada.total_outstanding, d("878.67"));
    assert_eq!(ada.open_items.len(), 1);
    assert_eq!(ada.open_items[0].due_id, "due-ada-feb");

    let eli = &statement.debtors[2];
    assert_eq!(eli.debtor_type, "TENANT");
    assert_eq!(eli.name, "Eli Şen");
    assert_eq!(eli.principal_outstanding, d("400.00"));
    assert_eq!(eli.total_outstanding, d("400.00"));
    assert_eq!(eli.open_items.len(), 1);
    assert_eq!(eli.open_items[0].due_id, "due-eli-apr");

    let dan = &statement.debtors[3];
    assert_eq!(dan.debtor_type, "TENANT");
    assert_eq!(dan.name, "Dan Yılmaz");
    assert_eq!(dan.principal_outstanding, d("750.00"));
    assert_eq!(dan.penalty_outstanding, d("73.75"));
    assert_eq!(dan.total_outstanding, d("823.75"));
    assert_eq!(dan.open_items.len(), 1);
    assert_eq!(dan.open_items[0].due_id, "due-dan-feb");

    // A signed-in current owner sees only their own section, not the predecessor's.
    let ben_view = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("OWNER"),
        Some(102),
        today,
    );
    assert_eq!(ben_view.debtors.len(), 1);
    assert_eq!(ben_view.debtors[0].name, "Ben Kaya");
    assert!(!ben_view.debtors[0].is_former);
    assert_eq!(ben_view.debtors[0].open_items[0].due_id, "due-ben-apr");

    // A former owner with outstanding items sees only their own section.
    let ada_view = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("OWNER"),
        Some(101),
        today,
    );
    assert_eq!(ada_view.debtors.len(), 1);
    assert_eq!(ada_view.debtors[0].name, "Ada Kaya");
    assert!(ada_view.debtors[0].is_former);
    assert_eq!(ada_view.debtors[0].open_items[0].due_id, "due-ada-feb");

    // A signed-in current tenant sees only their own section, not the predecessor's.
    let eli_view = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("TENANT"),
        Some(203),
        today,
    );
    assert_eq!(eli_view.debtors.len(), 1);
    assert_eq!(eli_view.debtors[0].name, "Eli Şen");
    assert!(!eli_view.debtors[0].is_former);
    assert_eq!(eli_view.debtors[0].open_items[0].due_id, "due-eli-apr");

    // A former tenant with outstanding items sees only their own section.
    let dan_view = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("TENANT"),
        Some(201),
        today,
    );
    assert_eq!(dan_view.debtors.len(), 1);
    assert_eq!(dan_view.debtors[0].name, "Dan Yılmaz");
    assert!(dan_view.debtors[0].is_former);
    assert_eq!(dan_view.debtors[0].open_items[0].due_id, "due-dan-feb");
}

#[tokio::test]
async fn when_former_tenant_has_open_items_and_unit_is_vacant_then_only_former_tenant_entry_is_produced(
) {
    let state = site_with_two_units().await;
    let today = today();
    {
        let mut inner = state.inner.write().await;
        let make_user = |id: &str, pid: i64, name: &str| User {
            id: id.to_string(),
            site_id: SITE.to_string(),
            full_name: name.to_string(),
            email: format!("{id}@sitepulse.local"),
            phone: "05550000000".to_string(),
            password_hash: None,
            role: Role::HomeResident,
            must_change_password: false,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: Some(pid),
        };
        inner.users.push(make_user("person-201", 201, "Dan Yılmaz"));

        let unit = inner.units.iter_mut().find(|u| u.id == "d-14").unwrap();
        unit.tenant_user_id = None;

        inner.dues.push(DuesLiability {
            id: "due-dan-vacant".to_string(),
            unit_id: "d-14".to_string(),
            period: "Şubat 2027".to_string(),
            principal_amount: d("750.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("750.00"),
            due_date: today - Days::new(60),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: Some(201),
        });
    }

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == "d-14").unwrap();
    let tenant_stmt = resident_statement::build_statement_for_person(
        &inner,
        unit,
        Some("TENANT"),
        Some(201),
        today,
    );

    assert_eq!(tenant_stmt.debtors.len(), 1);
    assert_eq!(tenant_stmt.debtors[0].name, "Dan Yılmaz");
    assert!(tenant_stmt.debtors[0].is_former);
    assert_eq!(tenant_stmt.debtors[0].principal_outstanding, d("750.00"));
}

#[tokio::test]
// covers: SC-13-12-01
// Backend coverage: SC-13-05-17 (owner payment, payer/debtor receipt identities, and owner statement balance).
async fn when_an_owner_pays_a_linked_tenant_liability_then_the_receipt_names_payer_and_debtor() {
    let state = site_with_two_units().await;
    let tenant_person_id = 9999;
    let owner_person_id;
    {
        let mut inner = state.inner.write().await;
        let owner_id = inner
            .units
            .iter()
            .find(|unit| unit.id == "d-14")
            .and_then(|unit| unit.owner_user_id.as_ref())
            .cloned()
            .unwrap();
        let mut tenant = inner
            .users
            .iter()
            .find(|user| user.id == owner_id)
            .cloned()
            .unwrap();
        tenant.id = "tenant-test".to_string();
        tenant.full_name = "Test Tenant".to_string();
        tenant.email = "tenant@example.test".to_string();
        tenant.person_id = Some(tenant_person_id);
        tenant.role = Role::HomeResident;
        owner_person_id = inner
            .users
            .iter()
            .find(|user| user.id == owner_id)
            .and_then(|user| user.person_id)
            .unwrap();
        inner.users.push(tenant);
        inner
            .units
            .iter_mut()
            .find(|unit| unit.id == "d-14")
            .unwrap()
            .tenant_user_id = Some("tenant-test".to_string());
        inner.dues.push(DuesLiability {
            id: "tenant-payable-due".to_string(),
            unit_id: "d-14".to_string(),
            period: "October 2026".to_string(),
            principal_amount: d("300.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("300.00"),
            due_date: today(),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Tenant,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: Some(today()),
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        });
        inner.joint_liability_owners.insert(
            "tenant-payable-due".to_string(),
            vec![JointLiabilityOwner {
                person_id: owner_person_id,
                tenant_person_id: Some(tenant_person_id),
                start_date: today(),
                end_date: Some(today()),
            }],
        );
    }

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.to_string()),
            unit_id: "d-14".to_string(),
            amount: d("100.00"),
            payer_name: "Can Öztürk".to_string(),
            payer_role: DebtorType::Owner,
            designation: Some(PaymentDesignation {
                due_ids: vec!["tenant-payable-due".to_string()],
                ..PaymentDesignation::default()
            }),
            settles_tenant_joint_liability: true,
            ..RecordManualPaymentRequest::default()
        })
        .await
        .unwrap();
    assert_eq!(receipt.payer_name, "Can Öztürk");
    assert_eq!(receipt.payer_role, DebtorType::Owner);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Tenant));
    assert_eq!(receipt.on_behalf_of_name.as_deref(), Some("Test Tenant"));
    let inner = state.inner.read().await;
    assert_eq!(inner.dues[0].paid_principal, d("100.00"));
}

// ---------------------------------------------------------------------------
// R3: receipt PDF and verification
// ---------------------------------------------------------------------------

#[test]
fn when_amounts_are_formatted_then_turkish_grouping_is_used() {
    assert_eq!(receipt_document::format_try(d("1234567.5")), "1.234.567,50");
    assert_eq!(receipt_document::format_try(d("0.05")), "0,05");
    assert_eq!(receipt_document::format_try(d("999")), "999,00");
}

#[tokio::test]
async fn when_a_receipt_pdf_is_rendered_and_verified_then_the_public_check_discloses_no_payer() {
    let state = owner_owing("1800.00").await;
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-14".into(),
            amount: d("2000.00"),
            payer_name: "Ahmet Yılmaz".into(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::ManualCash,
            ..Default::default()
        })
        .await
        .unwrap();
    let pdf = receipt_document::render_receipt_pdf(&receipt, "A Blok D:14").unwrap();
    assert!(pdf.starts_with(b"%PDF"));
    assert!(
        pdf.len() < 400_000,
        "fonts are subset ({} bytes)",
        pdf.len()
    );

    let Json(ok) = sitepulse_backend::handlers::verify_receipt(
        State(state.clone()),
        Query(sitepulse_backend::handlers::VerifyReceiptQuery {
            no: receipt.receipt_number.clone(),
            h: receipt.verification_hash.clone(),
        }),
    )
    .await;
    assert!(ok.valid);
    assert_eq!(ok.total_amount, Some(d("2000.00")));
    let json = serde_json::to_string(&ok).unwrap();
    assert!(!json.contains("Ahmet"), "no payer data: {}", json);

    let Json(bad) = sitepulse_backend::handlers::verify_receipt(
        State(state),
        Query(sitepulse_backend::handlers::VerifyReceiptQuery {
            no: receipt.receipt_number.clone(),
            h: "0".repeat(64),
        }),
    )
    .await;
    assert!(!bad.valid);
}
