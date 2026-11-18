//! SPEC-009 acceptance tests (in-memory). One or more scenarios per requirement
//! (R1–R15), including two-site isolation. PostgreSQL round trips of every
//! record are in `finance_store_pg_tests.rs` (opt-in).

use chrono::{Datelike, Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::domain::TrIban;
use sitepulse_backend::models::*;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::analytics_service::AnalyticsService;
use sitepulse_backend::services::assembly_service::AssemblyService;
use sitepulse_backend::services::autopay_service::AutopayService;
use sitepulse_backend::services::bank_matching_service::BankMatchingService;
use sitepulse_backend::services::budget_compliance_service::BudgetComplianceService;
use sitepulse_backend::services::collections_service::CollectionsService;
use sitepulse_backend::services::dunning_service::DunningService;
use sitepulse_backend::services::finance_common::{Caller, FinanceError};
use sitepulse_backend::services::heat_share_service::HeatShareService;
use sitepulse_backend::services::kvkk_service::KvkkService;
use sitepulse_backend::services::lease_service::LeaseService;
use sitepulse_backend::services::notification_service::NotificationService;
use sitepulse_backend::services::plan_service::PlanService;
use sitepulse_backend::services::portfolio_service::PortfolioService;
use sitepulse_backend::services::receipt_document::render_text_document;
use sitepulse_backend::services::resident_request_service::ResidentRequestService;
use sitepulse_backend::services::{
    CardPaymentService, OperatingBudgetService, PaymentTrackingService,
};
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

/// Today in the site's time zone, the date every SPEC-009 service works with.
fn today() -> NaiveDate {
    sitepulse_backend::scheduler::site_local_date("Europe/Istanbul", Utc::now())
}

fn days_ago(n: u64) -> NaiveDate {
    today() - Days::new(n)
}

fn caller(user: &str, role: Role) -> Caller {
    Caller {
        site_id: SITE.to_string(),
        user_id: user.to_string(),
        email: format!("{}@begonya.com", user),
        role,
        unit_id: None,
    }
}

fn manager() -> Caller {
    caller("usr-site-manager-1", Role::SiteManager)
}
fn manager2() -> Caller {
    caller("usr-site-manager-2", Role::SiteManager)
}
fn auditor() -> Caller {
    caller("usr-auditor-1", Role::Auditor)
}
fn owner() -> Caller {
    Caller {
        unit_id: Some("d-14".into()),
        ..caller("usr-home-owner-1", Role::HomeOwner)
    }
}
fn tenant() -> Caller {
    Caller {
        unit_id: Some("d-15".into()),
        ..caller("usr-tenant-15", Role::HomeResident)
    }
}

fn liability(
    id: &str,
    unit: &str,
    period: &str,
    amount: &str,
    due: NaiveDate,
    debtor: DebtorType,
    kind: ExpenseType,
) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: unit.to_string(),
        period: period.to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: due,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: debtor,
        expense_type: kind,
        penalty_accrued_through: None,
    }
}

/// Site 1 with A-14 (owner Ahmet, land share 24, 3+1) and A-15 (owner Ahmet,
/// tenant Zeynep, land share 12, 2+1), a second manager and an auditor; no dues.
async fn fixture() -> AppState {
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
        second.id = "d-15".into();
        second.unit_number = 15;
        second.land_share = 12;
        second.house_type = Some("2+1".into());
        second.virtual_iban = None;
        second.tenant_user_id = Some("usr-tenant-15".into());
        inner.units.push(second);
        let base = inner
            .users
            .iter()
            .find(|u| u.id == "usr-site-manager-1")
            .cloned()
            .unwrap();
        for (id, name, role, phone) in [
            (
                "usr-site-manager-2",
                "Selin Ak",
                Role::SiteManager,
                "+90 533 000 00 01",
            ),
            (
                "usr-auditor-1",
                "Kemal Denetçi",
                Role::Auditor,
                "+90 533 000 00 02",
            ),
            (
                "usr-tenant-15",
                "Zeynep Kaya",
                Role::HomeResident,
                "+90 542 333 44 55",
            ),
        ] {
            let mut u = base.clone();
            u.id = id.into();
            u.full_name = name.into();
            u.email = format!("{}@begonya.com", id);
            u.role = role;
            u.phone = phone.into();
            inner.users.push(u);
        }
    }
    state
}

async fn push_due(state: &AppState, due: DuesLiability) {
    state.inner.write().await.dues.push(due);
}

async fn due_of(state: &AppState, id: &str) -> DuesLiability {
    state
        .inner
        .read()
        .await
        .dues
        .iter()
        .find(|d| d.id == id)
        .cloned()
        .unwrap()
}

/// An approved budget for this year, in force, covering both units.
async fn approved_budget(state: &AppState) -> OperatingBudget {
    let svc = OperatingBudgetService::new(state.clone());
    let draft = svc
        .create_draft(
            SITE,
            CreateOperatingBudgetRequest {
                fiscal_year: today().year(),
                lines: vec![
                    BudgetLineInput {
                        category: "CLEANING".into(),
                        description: None,
                        annual_amount: d("36000.00"),
                        allocation_key: Some("LAND_SHARE".into()),
                        unit_weights: Vec::new(),
                    },
                    BudgetLineInput {
                        category: "RESERVE".into(),
                        description: None,
                        annual_amount: d("12000.00"),
                        allocation_key: Some("EQUAL".into()),
                        unit_weights: Vec::new(),
                    },
                ],
                ..CreateOperatingBudgetRequest::default()
            },
            "user:usr-site-manager-1 <m@x>",
        )
        .await
        .unwrap();
    svc.approve(
        SITE,
        &draft.id,
        ApproveBudgetRequest {
            assembly_decision_ref: "KD-2026/1".into(),
            assembly_decision_date: today(),
        },
    )
    .await
    .unwrap()
}

// ---------------------------------------------------------------------------
// R1: allocation keys, transition, legal basis
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-01-01
async fn when_a_budget_line_uses_house_type_or_meter_keys_then_shares_follow_the_weights() {
    let state = fixture().await;
    let svc = OperatingBudgetService::new(state.clone());
    let line = |key: &str, weights: Vec<UnitWeight>| BudgetLineInput {
        category: "ENERGY".into(),
        description: None,
        annual_amount: d("3200.00"),
        allocation_key: Some(key.into()),
        unit_weights: weights,
    };
    // HOUSE_TYPE: 1800 vs 1400 tariffs -> 1800/3200 and 1400/3200.
    let b = svc
        .create_draft(
            SITE,
            CreateOperatingBudgetRequest {
                fiscal_year: 2031,
                lines: vec![line("HOUSE_TYPE", vec![])],
                ..Default::default()
            },
            "a",
        )
        .await
        .unwrap();
    let share = |id: &str| {
        b.unit_shares
            .iter()
            .find(|s| s.unit_id == id)
            .unwrap()
            .annual_amount
    };
    assert_eq!(share("d-14"), d("1800.00"));
    assert_eq!(share("d-15"), d("1400.00"));
    // METER needs a weight for every unit.
    let missing = svc
        .create_draft(
            SITE,
            CreateOperatingBudgetRequest {
                fiscal_year: 2032,
                lines: vec![line(
                    "METER",
                    vec![UnitWeight {
                        unit_id: "d-14".into(),
                        weight: 3,
                    }],
                )],
                ..Default::default()
            },
            "a",
        )
        .await;
    assert!(missing.is_err());
    let metered = svc
        .create_draft(
            SITE,
            CreateOperatingBudgetRequest {
                fiscal_year: 2033,
                lines: vec![line(
                    "CUSTOM",
                    vec![
                        UnitWeight {
                            unit_id: "d-14".into(),
                            weight: 3,
                        },
                        UnitWeight {
                            unit_id: "d-15".into(),
                            weight: 1,
                        },
                    ],
                )],
                ..Default::default()
            },
            "a",
        )
        .await
        .unwrap();
    assert_eq!(
        metered
            .unit_shares
            .iter()
            .find(|s| s.unit_id == "d-14")
            .unwrap()
            .annual_amount,
        d("2400.00")
    );
    assert_eq!(metered.lines[0].unit_weights.len(), 2);
}

#[tokio::test]
// covers: SC-11-01-02
async fn when_a_site_requiring_a_budget_is_in_transition_then_the_tariff_accrues_and_is_reported_without_basis(
) {
    let state = fixture().await;
    state
        .inner
        .write()
        .await
        .budget_required_sites
        .push(SITE.into());
    let unit = state
        .inner
        .read()
        .await
        .units
        .iter()
        .find(|u| u.id == "d-14")
        .cloned()
        .unwrap();
    {
        let inner = state.inner.read().await;
        assert!(
            sitepulse_backend::services::operating_budget_service::operational_dues_basis(
                &inner,
                &unit,
                today()
            )
            .is_err()
        );
    }
    let report = BudgetComplianceService::new(&state)
        .set_transition(
            &manager(),
            SetTransitionRequest {
                transition_days: 30,
            },
        )
        .await
        .unwrap();
    assert!(report.in_transition);
    assert!(BudgetComplianceService::new(&state)
        .set_transition(
            &manager(),
            SetTransitionRequest {
                transition_days: 91
            }
        )
        .await
        .is_err());
    {
        let inner = state.inner.read().await;
        let basis = sitepulse_backend::services::operating_budget_service::operational_dues_basis(
            &inner,
            &unit,
            today(),
        )
        .unwrap();
        assert_eq!(basis.operating_budget_id, None);
    }
    push_due(
        &state,
        liability(
            "t-1",
            "d-14",
            "Bu ay",
            "1800.00",
            today(),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let report = BudgetComplianceService::new(&state).legal_basis(SITE).await;
    assert_eq!(report.operational_liabilities, 1);
    assert_eq!(report.with_legal_basis, 0);
    assert_eq!(report.without_basis[0].due_id, "t-1");
}

// ---------------------------------------------------------------------------
// R2: KVKK
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-02-01
async fn when_a_privacy_notice_is_published_then_residents_acknowledge_it_and_set_channel_consents()
{
    let state = fixture().await;
    let kvkk = KvkkService::new(&state);
    assert!(
        kvkk.acknowledge(&owner()).await.is_err(),
        "nothing to acknowledge yet"
    );
    let notice = kvkk
        .publish_notice(
            &manager(),
            PublishPrivacyNoticeRequest {
                title: "Aydınlatma Metni".into(),
                body: "Kişisel verileriniz aidat tahsilatı amacıyla işlenir.".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(notice.version, 1);
    let status = kvkk.acknowledge(&owner()).await.unwrap();
    assert!(status.acknowledged);
    let status = kvkk
        .update_consents(
            &owner(),
            UpdateConsentsRequest {
                consents: vec![ConsentUpdate {
                    channel: "SMS".into(),
                    granted: false,
                }],
            },
        )
        .await
        .unwrap();
    assert!(
        !status
            .consents
            .iter()
            .find(|c| c.channel == "SMS")
            .unwrap()
            .granted
    );
    assert!(
        status
            .consents
            .iter()
            .find(|c| c.channel == "EMAIL")
            .unwrap()
            .granted
    );
    assert!(kvkk
        .update_consents(
            &owner(),
            UpdateConsentsRequest {
                consents: vec![ConsentUpdate {
                    channel: "LETTER".into(),
                    granted: false
                }]
            }
        )
        .await
        .is_err());
}

#[tokio::test]
// covers: SC-11-02-02
async fn when_a_non_staff_role_exports_debtors_then_names_are_masked_and_every_export_is_logged() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "x-1",
            "d-14",
            "Ekim",
            "1800.00",
            days_ago(20),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let kvkk = KvkkService::new(&state);
    let staff = kvkk.debtor_export(&manager()).await.unwrap();
    assert!(!staff.masked);
    assert_eq!(staff.rows[0].debtor_name, "Ahmet Yılmaz");
    assert_eq!(staff.rows[0].overdue_amount, d("1800.00"));
    let masked = kvkk.debtor_export(&auditor()).await.unwrap();
    assert!(masked.masked);
    assert_eq!(masked.rows[0].debtor_name, "A*** Y***");
    let resident = kvkk.debtor_export(&owner()).await.unwrap();
    assert!(resident.masked);
    let log = kvkk.access_log(&manager(), 50).await;
    assert_eq!(
        log.iter()
            .filter(|e| e.resource == "DEBTOR_EXPORT" && e.action == ACCESS_EXPORT)
            .count(),
        3
    );
}

#[tokio::test]
// covers: SC-11-02-03
async fn when_retention_is_reviewed_then_ledger_records_keep_ten_years_and_old_logs_are_purged() {
    let state = fixture().await;
    let kvkk = KvkkService::new(&state);
    assert!(matches!(
        kvkk.set_retention(
            &manager(),
            SetRetentionPolicyRequest {
                category: "FINANCIAL_RECORDS".into(),
                retention_months: 24
            }
        )
        .await,
        Err(FinanceError::Conflict(_))
    ));
    kvkk.set_retention(
        &manager(),
        SetRetentionPolicyRequest {
            category: "ACCESS_LOG".into(),
            retention_months: 1,
        },
    )
    .await
    .unwrap();
    let mut old = kvkk
        .log_access(&manager(), ACCESS_VIEW, "STATEMENT", None, None)
        .await
        .unwrap();
    old.occurred_at = Utc::now() - chrono::Duration::days(60);
    state.inner.write().await.finance.access_log[0] = old;
    let review = kvkk.retention_review(&manager(), false).await.unwrap();
    assert_eq!(
        review
            .rows
            .iter()
            .find(|r| r.category == "ACCESS_LOG")
            .unwrap()
            .records_past_retention,
        1
    );
    let purged = kvkk.retention_review(&manager(), true).await.unwrap();
    assert_eq!(purged.purged, 1);
    assert!(state.inner.read().await.finance.access_log.is_empty());
}

// ---------------------------------------------------------------------------
// R3: KMK 22
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-03-01
async fn when_a_tenant_has_a_lease_then_owner_operational_debts_are_claimable_up_to_the_unpaid_rent(
) {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "o-1",
            "d-15",
            "Ekim",
            "20000.00",
            days_ago(30),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    push_due(
        &state,
        liability(
            "c-1",
            "d-15",
            "Çatı",
            "50000.00",
            days_ago(30),
            DebtorType::Owner,
            ExpenseType::CapitalDues,
        ),
    )
    .await;
    let leases = LeaseService::new(&state);
    leases
        .upsert(
            &manager(),
            UpsertLeaseRequest {
                unit_id: "d-15".into(),
                tenant_name: "Zeynep Kaya".into(),
                tenant_user_ref: None,
                monthly_rent: d("15000.00"),
                lease_start: today() - Days::new(10),
                lease_end: None,
                rent_paid_through: Some(today() + Days::new(5)),
            },
        )
        .await
        .unwrap();
    let report = leases.joint_exposure(SITE).await;
    let row = &report.rows[0];
    assert_eq!(
        row.owner_open_operational,
        d("20000.00"),
        "capital dues are not common expenses"
    );
    assert_eq!(row.rent_cap, d("15000.00"), "the next rent instalment only");
    assert_eq!(row.claimable_from_tenant, d("15000.00"));
    assert!(report.legal_note.contains("KMK 22"));
}

#[tokio::test]
// covers: SC-11-03-02
async fn when_a_tenant_pays_owner_capital_dues_then_the_receipt_cites_kmk22_and_a_rent_certificate_is_issued(
) {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "c-2",
            "d-15",
            "Çatı 1/2",
            "2500.00",
            days_ago(5),
            DebtorType::Owner,
            ExpenseType::CapitalDues,
        ),
    )
    .await;
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-15".into(),
            amount: d("2500.00"),
            payer_name: "Zeynep Kaya".into(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::BankTransfer,
            description: Some("DEMİRBAŞ çatı katılımı".into()),
            settles_owner_capital_dues: true,
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(receipt.is_rent_offset_eligible);
    assert!(receipt
        .legal_statutory_note
        .as_deref()
        .unwrap()
        .contains("KMK Madde 22"));
    // R15: the v2 hash covers the payer and allocation lines.
    assert_eq!(
        receipt.verification_hash,
        PaymentTrackingService::compute_verification_hash_v2(&receipt)
    );
    let doc = LeaseService::new(&state)
        .rent_deduction_certificate(SITE, &receipt.receipt_number)
        .await
        .unwrap();
    assert_eq!(doc.title, "KİRA BEDELİNDEN MAHSUP BELGESİ");
    let bytes = render_text_document(&doc).unwrap();
    assert!(bytes.starts_with(b"%PDF"));
}

// ---------------------------------------------------------------------------
// R4: notifications and dunning
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-04-01
async fn when_dunning_runs_then_the_due_step_is_sent_once_and_disputed_items_are_paused() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "dn-1",
            "d-14",
            "Ekim",
            "1800.00",
            days_ago(12),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    push_due(
        &state,
        liability(
            "dn-2",
            "d-14",
            "Kasım",
            "1800.00",
            days_ago(12),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    ResidentRequestService::new(&state)
        .create_dispute(
            &owner(),
            "d-14",
            CreateDisputeRequest {
                due_id: "dn-2".into(),
                reason: "Bu dönemi nakit ödedim".into(),
            },
        )
        .await
        .unwrap();
    let dunning = DunningService::new(&state);
    let report = dunning.run(SITE, None).await.unwrap();
    assert_eq!(report.examined, 2);
    assert_eq!(report.paused, 1);
    assert_eq!(report.actions.len(), 1);
    assert_eq!(report.actions[0].channel, "SMS", "D+10 step");
    assert_eq!(report.sent, 1);
    let again = dunning.run(SITE, None).await.unwrap();
    assert!(again.actions.is_empty(), "a step runs once per liability");
    let later = dunning
        .run(SITE, Some(today() + Days::new(20)))
        .await
        .unwrap();
    assert_eq!(later.actions[0].kind, "WRITTEN_WARNING");
    let letter = dunning.notice_letter(SITE, "dn-1").await.unwrap();
    assert!(render_text_document(&letter).unwrap().starts_with(b"%PDF"));
}

#[tokio::test]
// covers: SC-11-04-02
async fn when_a_resident_opts_out_of_sms_then_reminders_are_blocked_but_legal_notices_go_out() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "dn-3",
            "d-14",
            "Ekim",
            "1800.00",
            days_ago(12),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    KvkkService::new(&state)
        .update_consents(
            &owner(),
            UpdateConsentsRequest {
                consents: vec![ConsentUpdate {
                    channel: "SMS".into(),
                    granted: false,
                }],
            },
        )
        .await
        .unwrap();
    let report = DunningService::new(&state).run(SITE, None).await.unwrap();
    assert_eq!(report.blocked, 1);
    let log = state.inner.read().await.finance.notifications.clone();
    assert!(log[0]
        .block_reason
        .as_deref()
        .unwrap()
        .contains("opted out"));
    let later = DunningService::new(&state)
        .run(SITE, Some(today() + Days::new(20)))
        .await
        .unwrap();
    assert_eq!(
        later.sent, 1,
        "the written warning does not depend on consent"
    );
}

#[tokio::test]
// covers: SC-11-04-03
async fn when_a_debt_notice_targets_a_group_channel_then_it_is_blocked_and_logged() {
    let state = fixture().await;
    let n = NotificationService::new(&state);
    let blocked = n
        .broadcast(
            &manager(),
            "WHATSAPP_GROUP",
            "DEBT_REMINDER",
            "Borçlu listesi",
            "...",
        )
        .await
        .unwrap();
    assert_eq!(blocked.status, NOTIFY_BLOCKED);
    assert!(blocked.block_reason.unwrap().contains("KVKK"));
    let ok = n
        .broadcast(
            &manager(),
            "NOTICE_BOARD",
            "SYSTEM",
            "Asansör bakımı",
            "Yarın 10:00",
        )
        .await
        .unwrap();
    assert_eq!(ok.status, NOTIFY_SENT);
    assert_eq!(n.list(&manager(), 10).await.len(), 2);
    assert!(
        n.list(&owner(), 10).await.is_empty(),
        "residents see only their own messages"
    );
}

#[tokio::test]
async fn when_a_site_announcement_is_published_then_residents_can_read_it() {
    let state = fixture().await;
    let service = NotificationService::new(&state);
    let announcement = service
        .broadcast(
            &manager(),
            "NOTICE_BOARD",
            "ANNOUNCEMENT",
            "Planlı Su Kesintisi",
            "Salı 10:00-14:00",
        )
        .await
        .unwrap();

    assert_eq!(announcement.status, NOTIFY_SENT);
    let resident_notices = service.list(&owner(), 10).await;
    assert_eq!(resident_notices.len(), 1);
    assert_eq!(resident_notices[0].subject, "Planlı Su Kesintisi");
    assert_eq!(resident_notices[0].body, "Salı 10:00-14:00");
}

// ---------------------------------------------------------------------------
// R5: virman requests and disputes
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-05-01
async fn when_a_tenant_requests_a_virman_and_staff_approve_then_the_owner_debt_is_settled_from_the_tenant_advance(
) {
    let state = fixture().await;
    // Due today: no KMK 20 penalty has accrued, so 400 settles it exactly.
    push_due(
        &state,
        liability(
            "vc-1",
            "d-15",
            "Çatı",
            "400.00",
            today(),
            DebtorType::Owner,
            ExpenseType::CapitalDues,
        ),
    )
    .await;
    state.inner.write().await.advance_balances.insert(
        "d-15".into(),
        UnitAdvance {
            owner: Decimal::ZERO,
            tenant: d("500.00"),
        },
    );
    let svc = ResidentRequestService::new(&state);
    assert!(matches!(
        svc.create_virman_request(
            &tenant(),
            "d-15",
            CreateVirmanRequest {
                amount: d("100.00"),
                source_debtor: Some("OWNER".into()),
                note: None
            }
        )
        .await,
        Err(FinanceError::Forbidden(_))
    ));
    assert!(matches!(
        svc.create_virman_request(
            &tenant(),
            "d-15",
            CreateVirmanRequest {
                amount: d("900.00"),
                source_debtor: None,
                note: None
            }
        )
        .await,
        Err(FinanceError::Conflict(_))
    ));
    let req = svc
        .create_virman_request(
            &tenant(),
            "d-15",
            CreateVirmanRequest {
                amount: d("400.00"),
                source_debtor: None,
                note: Some("Kira mahsubu".into()),
            },
        )
        .await
        .unwrap();
    assert_eq!(req.source_debtor, "TENANT");
    let decided = svc
        .decide_virman(
            &manager(),
            req.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(decided.status, REQUEST_APPROVED);
    assert!(decided.receipt_number.is_some());
    assert_eq!(due_of(&state, "vc-1").await.status, DebtStatus::Paid);
    assert!(svc
        .decide_virman(
            &manager(),
            req.id,
            DecideRequest {
                approve: true,
                note: None
            }
        )
        .await
        .is_err());
}

#[tokio::test]
// covers: SC-11-05-02
async fn when_a_dispute_is_resolved_then_dunning_resumes() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "ds-1",
            "d-15",
            "Ekim",
            "900.00",
            days_ago(4),
            DebtorType::Tenant,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let svc = ResidentRequestService::new(&state);
    assert!(matches!(
        svc.create_dispute(
            &owner(),
            "d-15",
            CreateDisputeRequest {
                due_id: "ds-1".into(),
                reason: "Kiracının borcu bana yazılmış".into()
            }
        )
        .await,
        Err(FinanceError::Forbidden(_))
    ));
    let dispute = svc
        .create_dispute(
            &tenant(),
            "d-15",
            CreateDisputeRequest {
                due_id: "ds-1".into(),
                reason: "Tutar yanlış hesaplanmış".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(
        DunningService::new(&state)
            .run(SITE, None)
            .await
            .unwrap()
            .paused,
        1
    );
    svc.resolve_dispute(
        &manager(),
        dispute.id,
        ResolveDisputeRequest {
            accept: false,
            note: "Tutar doğru".into(),
        },
    )
    .await
    .unwrap();
    assert_eq!(
        DunningService::new(&state)
            .run(SITE, None)
            .await
            .unwrap()
            .actions
            .len(),
        1
    );
}

// ---------------------------------------------------------------------------
// R6: autopay
// ---------------------------------------------------------------------------

async fn saved_card(state: &AppState) -> SavedPaymentMethod {
    push_due(
        state,
        liability(
            "ap-0",
            "d-14",
            "Önceki",
            "100.00",
            today() + Days::new(10),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let cards = CardPaymentService::new(state.clone());
    let intent = cards
        .create_intent(
            "d-14",
            CreatePaymentIntentRequest {
                amount: d("100.00"),
                debtor_type: None,
                payer_name: None,
                designation: None,
            },
            Some("OWNER"),
            "user:usr-home-owner-1 <a@b>",
        )
        .await
        .unwrap();
    AutopayService::new(state)
        .set_intent_options(&intent.id, Some(3), true)
        .await
        .unwrap();
    assert!(
        AutopayService::new(state)
            .set_intent_options(&intent.id, Some(5), false)
            .await
            .is_err(),
        "5 instalments are not offered"
    );
    cards
        .apply_provider_event(ProviderWebhookEvent {
            provider: intent.provider.clone(),
            provider_ref: intent.provider_ref.clone(),
            status: INTENT_CAPTURED.into(),
            amount: intent.amount,
            fee_amount: None,
            three_ds_status: Some("Y".into()),
            failure_reason: None,
        })
        .await
        .unwrap();
    let methods = state.inner.read().await.finance.payment_methods.clone();
    assert_eq!(methods.len(), 1, "the sandbox saved the card's token");
    assert_eq!(methods[0].last4, "4242");
    methods[0].clone()
}

#[tokio::test]
// covers: SC-11-06-01
async fn when_autopay_runs_then_due_items_are_charged_once_through_the_ingestion_path() {
    let state = fixture().await;
    let card = saved_card(&state).await;
    push_due(
        &state,
        liability(
            "ap-1",
            "d-14",
            "Bu ay",
            "1800.00",
            today(),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let autopay = AutopayService::new(&state);
    let mandate = autopay
        .create_mandate(
            &owner(),
            "d-14",
            CreateMandateRequest {
                payment_method_id: card.id,
                debtor_type: None,
                max_amount: None,
            },
        )
        .await
        .unwrap();
    assert!(autopay
        .create_mandate(
            &owner(),
            "d-14",
            CreateMandateRequest {
                payment_method_id: card.id,
                debtor_type: None,
                max_amount: None
            }
        )
        .await
        .is_err());
    let report = autopay.run(SITE, None).await.unwrap();
    assert_eq!(report.charged, 1);
    assert!(report.attempts[0].receipt_number.is_some());
    assert_eq!(due_of(&state, "ap-1").await.status, DebtStatus::Paid);
    assert_eq!(
        autopay.run(SITE, None).await.unwrap().attempts.len(),
        0,
        "charged once"
    );
    let overview = autopay.overview(&owner(), "d-14").await.unwrap();
    assert_eq!(overview.mandates[0].id, mandate.id);
    let json = serde_json::to_string(&overview.payment_methods[0]).unwrap();
    assert!(
        !json.contains("tok_"),
        "the provider token never leaves the backend"
    );
}

#[tokio::test]
// covers: SC-11-06-02
async fn when_a_card_is_declined_then_the_due_stays_open_and_is_retried_and_an_expired_card_suspends_the_mandate(
) {
    let state = fixture().await;
    let card = saved_card(&state).await;
    {
        let mut inner = state.inner.write().await;
        inner.finance.payment_methods[0].token_ref = "tok_decline_1".into();
    }
    push_due(
        &state,
        liability(
            "ap-2",
            "d-14",
            "Bu ay",
            "1800.00",
            today(),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let autopay = AutopayService::new(&state);
    autopay
        .create_mandate(
            &owner(),
            "d-14",
            CreateMandateRequest {
                payment_method_id: card.id,
                debtor_type: None,
                max_amount: None,
            },
        )
        .await
        .unwrap();
    let first = autopay.run(SITE, None).await.unwrap();
    assert_eq!(first.declined, 1);
    assert_eq!(
        first.attempts[0].next_retry_on,
        Some(today() + Days::new(2))
    );
    assert!(first.attempts[0].receipt_number.is_none());
    assert_ne!(due_of(&state, "ap-2").await.status, DebtStatus::Paid);
    assert!(
        autopay.run(SITE, None).await.unwrap().attempts.is_empty(),
        "not before the retry date"
    );
    let retry = autopay
        .run(SITE, Some(today() + Days::new(2)))
        .await
        .unwrap();
    assert_eq!(retry.attempts[0].attempt_no, 2);
    assert_eq!(
        retry.attempts[0].next_retry_on,
        Some(today() + Days::new(5))
    );
    {
        let mut inner = state.inner.write().await;
        inner.finance.payment_methods[0].token_ref = "tok_expired".into();
    }
    let expired = autopay
        .run(SITE, Some(today() + Days::new(5)))
        .await
        .unwrap();
    assert_eq!(expired.suspended, 1);
    assert_eq!(
        state.inner.read().await.finance.mandates[0].status,
        MANDATE_SUSPENDED
    );
}

// ---------------------------------------------------------------------------
// R7: expenses, ledger, account report, reserve fund
// ---------------------------------------------------------------------------

fn iban() -> String {
    TrIban::from_bban("0006200000000000000001")
        .unwrap()
        .into_string()
}

async fn vendor(state: &AppState) -> Vendor {
    AccountingService::new(state)
        .create_vendor(
            &manager(),
            CreateVendorRequest {
                name: "Temiz A.Ş.".into(),
                tax_id: "0010180009".into(),
                iban: Some(iban()),
                email: None,
                phone: None,
            },
        )
        .await
        .unwrap()
}

fn expense(vendor: i64, number: &str, net: &str, category: &str) -> CreateExpenseRequest {
    CreateExpenseRequest {
        vendor_id: vendor,
        invoice_number: number.into(),
        invoice_date: today(),
        due_date: None,
        category: category.into(),
        description: None,
        net_amount: d(net),
        vat_amount: Decimal::ZERO,
        document_ref: None,
    }
}

#[tokio::test]
// covers: SC-11-07-01
async fn when_an_expense_is_approved_then_four_eyes_and_the_auditor_threshold_apply() {
    let state = fixture().await;
    let acc = AccountingService::new(&state);
    assert!(
        acc.create_vendor(
            &manager(),
            CreateVendorRequest {
                name: "X".into(),
                tax_id: "0010180006".into(),
                iban: None,
                email: None,
                phone: None
            }
        )
        .await
        .is_err(),
        "VKN checksum"
    );
    let v = vendor(&state).await;
    let small = acc
        .create_expense(&manager(), expense(v.id, "F-1", "10000.00", "CLEANING"))
        .await
        .unwrap();
    assert!(matches!(
        acc.approve_expense(&manager(), small.invoice.id).await,
        Err(FinanceError::Forbidden(_))
    ));
    let approved = acc
        .approve_expense(&manager2(), small.invoice.id)
        .await
        .unwrap();
    assert_eq!(approved.invoice.status, EXPENSE_APPROVED);
    let paid = acc
        .pay_expense(
            &manager(),
            small.invoice.id,
            PayExpenseRequest {
                amount: d("4000.00"),
                paid_on: None,
                method: None,
                reference: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(paid.invoice.status, EXPENSE_PARTIALLY_PAID);
    assert!(acc
        .pay_expense(
            &manager(),
            small.invoice.id,
            PayExpenseRequest {
                amount: d("7000.00"),
                paid_on: None,
                method: None,
                reference: None
            }
        )
        .await
        .is_err());

    let large = acc
        .create_expense(&manager(), expense(v.id, "F-2", "30000.00", "MAINTENANCE"))
        .await
        .unwrap();
    let after_manager = acc
        .approve_expense(&manager2(), large.invoice.id)
        .await
        .unwrap();
    assert_eq!(after_manager.invoice.status, EXPENSE_PENDING);
    assert!(after_manager.needs_auditor);
    let after_auditor = acc
        .approve_expense(&auditor(), large.invoice.id)
        .await
        .unwrap();
    assert_eq!(after_auditor.invoice.status, EXPENSE_APPROVED);
    assert!(
        acc.create_expense(&manager(), expense(v.id, "F-2", "1.00", "OTHER"))
            .await
            .is_err(),
        "duplicate invoice"
    );
}

#[tokio::test]
// covers: SC-11-07-02
async fn when_the_ledger_is_derived_then_the_trial_balance_balances_and_receivables_equal_open_dues(
) {
    let state = fixture().await;
    approved_budget(&state).await;
    push_due(
        &state,
        liability(
            "gl-1",
            "d-14",
            "Ekim",
            "1800.00",
            days_ago(40),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    push_due(
        &state,
        liability(
            "gl-2",
            "d-15",
            "Kasım",
            "1400.00",
            today(),
            DebtorType::Tenant,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    {
        let mut inner = state.inner.write().await;
        let due = inner.dues.iter_mut().find(|d| d.id == "gl-1").unwrap();
        due.delay_penalty = d("90.00");
        due.total_amount = d("1890.00");
    }
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-15".into(),
            amount: d("1500.00"),
            payer_name: "Zeynep Kaya".into(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::VirtualIban,
            ..Default::default()
        })
        .await
        .unwrap();
    let acc = AccountingService::new(&state);
    let v = vendor(&state).await;
    let e = acc
        .create_expense(&manager(), expense(v.id, "F-9", "2000.00", "CLEANING"))
        .await
        .unwrap();
    acc.approve_expense(&manager2(), e.invoice.id)
        .await
        .unwrap();
    acc.pay_expense(
        &manager(),
        e.invoice.id,
        PayExpenseRequest {
            amount: d("2000.00"),
            paid_on: None,
            method: None,
            reference: None,
        },
    )
    .await
    .unwrap();
    assert!(
        acc.create_journal_entry(
            &manager(),
            CreateJournalEntryRequest {
                entry_date: None,
                kind: Some("RESERVE_ALLOCATION".into()),
                description: "Yedek akçe".into(),
                lines: vec![
                    JournalLineInput {
                        account_code: "690".into(),
                        debit: d("500.00"),
                        credit: Decimal::ZERO
                    },
                    JournalLineInput {
                        account_code: "549".into(),
                        debit: Decimal::ZERO,
                        credit: d("400.00")
                    }
                ]
            }
        )
        .await
        .is_err(),
        "unbalanced"
    );
    acc.create_journal_entry(
        &manager(),
        CreateJournalEntryRequest {
            entry_date: None,
            kind: Some("RESERVE_ALLOCATION".into()),
            description: "Yedek akçe ayrıldı".into(),
            lines: vec![
                JournalLineInput {
                    account_code: "690".into(),
                    debit: d("500.00"),
                    credit: Decimal::ZERO,
                },
                JournalLineInput {
                    account_code: "549".into(),
                    debit: Decimal::ZERO,
                    credit: d("500.00"),
                },
            ],
        },
    )
    .await
    .unwrap();

    let tb = acc.trial_balance(SITE, None, None).await;
    assert!(tb.balanced);
    let receivable = tb
        .rows
        .iter()
        .find(|r| r.account_code == "120")
        .unwrap()
        .balance;
    let open: Decimal = state
        .inner
        .read()
        .await
        .dues
        .iter()
        .map(sitepulse_backend::services::dues_ledger::outstanding)
        .sum();
    assert_eq!(receivable, open);
    assert_eq!(
        tb.rows
            .iter()
            .find(|r| r.account_code == "340")
            .unwrap()
            .balance,
        d("100.00"),
        "the tenant's surplus is an advance"
    );
    assert_eq!(
        tb.rows
            .iter()
            .find(|r| r.account_code == "320")
            .unwrap()
            .balance,
        Decimal::ZERO
    );

    let bva = acc.budget_vs_actual(SITE, today().year()).await;
    let cleaning = bva.rows.iter().find(|r| r.category == "CLEANING").unwrap();
    assert_eq!(cleaning.budgeted, d("36000.00"));
    assert_eq!(cleaning.actual, d("2000.00"));
    let reserve = acc.reserve_fund(SITE, today().year()).await;
    assert_eq!(reserve.target, d("12000.00"));
    assert_eq!(reserve.balance, d("500.00"));
    let report = acc.account_report(SITE, today().year()).await.unwrap();
    assert!(report.trial_balance_balanced);
    assert_eq!(report.receivables_outstanding, open);
    assert!(
        render_text_document(&AccountingService::account_report_document(&report))
            .unwrap()
            .starts_with(b"%PDF")
    );
}

// ---------------------------------------------------------------------------
// R8: collections
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-08-01
async fn when_a_case_reaches_enforcement_then_it_needs_a_legal_basis_and_the_lawyer_reads_the_pack_by_token(
) {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "cl-1",
            "d-14",
            "Ağustos",
            "1800.00",
            days_ago(70),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let col = CollectionsService::new(&state);
    let case = col
        .open_case(
            &manager(),
            OpenCaseRequest {
                unit_id: "d-14".into(),
                debtor_type: None,
                due_ids: vec![],
                note: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(case.case.status, "REMINDED");
    assert!(!case.evidence_ready);
    assert!(
        col.open_case(
            &manager(),
            OpenCaseRequest {
                unit_id: "d-14".into(),
                debtor_type: None,
                due_ids: vec![],
                note: None
            }
        )
        .await
        .is_err(),
        "already in a case"
    );
    let id = case.case.id;
    col.advance(
        &manager(),
        id,
        AdvanceCaseRequest {
            to_status: "NOTICE_SENT".into(),
            note: None,
            occurred_on: None,
            lawyer_name: None,
            lawyer_contact: None,
        },
    )
    .await
    .unwrap();
    assert!(
        col.advance(
            &manager(),
            id,
            AdvanceCaseRequest {
                to_status: "REMINDED".into(),
                note: None,
                occurred_on: None,
                lawyer_name: None,
                lawyer_contact: None
            }
        )
        .await
        .is_err(),
        "cases move forward"
    );
    assert!(
        col.advance(
            &manager(),
            id,
            AdvanceCaseRequest {
                to_status: "LAWYER_ASSIGNED".into(),
                note: None,
                occurred_on: None,
                lawyer_name: None,
                lawyer_contact: None
            }
        )
        .await
        .is_err(),
        "a lawyer is named"
    );
    col.advance(
        &manager(),
        id,
        AdvanceCaseRequest {
            to_status: "LAWYER_ASSIGNED".into(),
            note: None,
            occurred_on: None,
            lawyer_name: Some("Av. Deniz Ak".into()),
            lawyer_contact: Some("deniz@hukuk.example".into()),
        },
    )
    .await
    .unwrap();
    assert!(matches!(
        col.advance(
            &manager(),
            id,
            AdvanceCaseRequest {
                to_status: "ICRA_FILED".into(),
                note: None,
                occurred_on: None,
                lawyer_name: None,
                lawyer_contact: None
            }
        )
        .await,
        Err(FinanceError::Conflict(_))
    ));
    assert!(col.evidence_pack(SITE, id).await.is_err());
    // Give the liability its legal basis.
    let budget = approved_budget(&state).await;
    state
        .inner
        .write()
        .await
        .dues_budget_basis
        .insert("cl-1".into(), budget.id.clone());
    let filed = col
        .advance(
            &manager(),
            id,
            AdvanceCaseRequest {
                to_status: "ICRA_FILED".into(),
                note: None,
                occurred_on: None,
                lawyer_name: None,
                lawyer_contact: None,
            },
        )
        .await
        .unwrap();
    assert!(filed.evidence_ready);
    let pack = col.evidence_pack(SITE, id).await.unwrap();
    assert!(pack.items[0].legal_basis.contains("KD-2026/1"));
    assert!(pack.items[0].penalty_accrued > Decimal::ZERO);
    assert!(
        render_text_document(&CollectionsService::evidence_document(&pack))
            .unwrap()
            .starts_with(b"%PDF")
    );
    let grant = col.grant_lawyer_access(&manager(), id).await.unwrap();
    assert!(col.pack_by_token("wrong").await.is_err());
    assert_eq!(col.pack_by_token(&grant.token).await.unwrap().case_id, id);
    let stored = state.inner.read().await.finance.cases[0]
        .lawyer_token_digest
        .clone()
        .unwrap();
    assert_ne!(stored, grant.token, "only the digest is stored");
    assert!(KvkkService::new(&state)
        .access_log(&manager(), 10)
        .await
        .iter()
        .any(|e| e.resource == "EVIDENCE_PACK"));
}

#[tokio::test]
// covers: SC-11-08-02
async fn when_an_owner_was_enforced_three_times_in_two_years_then_the_kmk25_flag_is_raised() {
    let state = fixture().await;
    let budget = approved_budget(&state).await;
    let col = CollectionsService::new(&state);
    let mut last = None;
    for i in 0..3 {
        let id = format!("k25-{}", i);
        push_due(
            &state,
            liability(
                &id,
                "d-14",
                &format!("Dönem {}", i),
                "1000.00",
                days_ago(60),
                DebtorType::Owner,
                ExpenseType::OperationalDues,
            ),
        )
        .await;
        state
            .inner
            .write()
            .await
            .dues_budget_basis
            .insert(id.clone(), budget.id.clone());
        let case = col
            .open_case(
                &manager(),
                OpenCaseRequest {
                    unit_id: "d-14".into(),
                    debtor_type: None,
                    due_ids: vec![id],
                    note: None,
                },
            )
            .await
            .unwrap();
        let v = col
            .advance(
                &manager(),
                case.case.id,
                AdvanceCaseRequest {
                    to_status: "ICRA_FILED".into(),
                    note: None,
                    occurred_on: None,
                    lawyer_name: None,
                    lawyer_contact: None,
                },
            )
            .await
            .unwrap();
        last = Some(v);
    }
    let last = last.unwrap();
    assert_eq!(last.kmk25_enforcements_in_two_years, 3);
    assert!(last.kmk25_threshold_reached);
}

// ---------------------------------------------------------------------------
// R9: bank matching
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-09-01
async fn when_a_transfer_bypasses_the_virtual_iban_then_phone_and_block_unit_hints_rank_the_units()
{
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "bm-1",
            "d-15",
            "Ekim",
            "1400.00",
            days_ago(3),
            DebtorType::Tenant,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let svc = BankMatchingService::new(&state);
    let out = svc
        .suggest(
            SITE,
            MatchRequest {
                transfers: vec![
                    TransferToMatch {
                        reference: Some("T1".into()),
                        amount: d("1400.00"),
                        description: "AIDAT 0542 333 44 55".into(),
                        sender_name: None,
                    },
                    TransferToMatch {
                        reference: Some("T2".into()),
                        amount: d("100.00"),
                        description: "A BLOK D:14 EKIM".into(),
                        sender_name: Some("Ahmet Yılmaz".into()),
                    },
                ],
            },
        )
        .await
        .unwrap();
    assert_eq!(out[0].candidates[0].unit_id, "d-15");
    assert_eq!(
        out[0].candidates[0].confidence, 95,
        "phone 85 + exact open amount 10"
    );
    assert_eq!(out[1].candidates[0].unit_id, "d-14");
    assert!(out[1].candidates[0]
        .reasons
        .iter()
        .any(|r| r == "blok/daire"));
}

#[tokio::test]
// covers: SC-11-09-02
async fn when_the_daily_reconciliation_runs_then_differences_and_unmatched_lines_are_stored() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "br-1",
            "d-14",
            "Ekim",
            "1000.00",
            days_ago(3),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-14".into(),
            amount: d("1000.00"),
            payer_name: "Ahmet Yılmaz".into(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::BankTransfer,
            ..Default::default()
        })
        .await
        .unwrap();
    let svc = BankMatchingService::new(&state);
    let run = svc
        .daily_reconciliation(
            &manager(),
            DailyReconciliationRequest {
                business_date: today(),
                bank_closing_balance: Some(d("51050.00")),
                lines: vec![
                    BankLine {
                        reference: Some(receipt.receipt_number.clone()),
                        amount: d("1000.00"),
                        description: None,
                    },
                    BankLine {
                        reference: None,
                        amount: d("50.00"),
                        description: Some("faiz".into()),
                    },
                ],
            },
        )
        .await
        .unwrap();
    assert_eq!(run.difference, d("50.00"));
    assert_eq!(run.details["matched"], 1);
    assert_eq!(
        run.details["unmatched_bank_lines"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    let feed = svc
        .create_feed(
            &manager(),
            CreateBankFeedRequest {
                provider: "SANDBOX".into(),
                account_iban: iban(),
                credential_ref: Some("vault:site-1/bank".into()),
            },
        )
        .await
        .unwrap();
    assert!(svc
        .create_feed(
            &manager(),
            CreateBankFeedRequest {
                provider: "SANDBOX".into(),
                account_iban: iban(),
                credential_ref: Some("my secret password".into())
            }
        )
        .await
        .is_err());
    let (synced, fetched) = svc.sync_feed(&manager(), feed.id).await.unwrap();
    assert_eq!(fetched, 0);
    assert!(synced.last_synced_at.is_some());
}

// ---------------------------------------------------------------------------
// R10: plans, waivers, write-offs
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-10-01
async fn when_a_waiver_is_approved_by_a_second_person_then_what_is_owed_drops_and_the_ledger_still_balances(
) {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "wv-1",
            "d-14",
            "Temmuz",
            "1000.00",
            days_ago(90),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    {
        let mut inner = state.inner.write().await;
        let due = inner.dues.iter_mut().find(|d| d.id == "wv-1").unwrap();
        due.delay_penalty = d("150.00");
        due.total_amount = d("1150.00");
    }
    let plans = PlanService::new(&state);
    assert!(plans
        .request_adjustment(
            &manager(),
            RequestAdjustmentRequest {
                due_id: "wv-1".into(),
                kind: "PENALTY_WAIVER".into(),
                amount: Some(d("200.00")),
                reason: "Hastalık nedeniyle".into()
            },
            "MANUAL"
        )
        .await
        .is_err());
    let adj = plans
        .request_adjustment(
            &manager(),
            RequestAdjustmentRequest {
                due_id: "wv-1".into(),
                kind: "PENALTY_WAIVER".into(),
                amount: None,
                reason: "Hastalık nedeniyle".into(),
            },
            "MANUAL",
        )
        .await
        .unwrap();
    assert_eq!(adj.amount, d("150.00"));
    assert!(matches!(
        plans
            .decide_adjustment(
                &manager(),
                adj.id,
                DecideRequest {
                    approve: true,
                    note: None
                }
            )
            .await,
        Err(FinanceError::Forbidden(_))
    ));
    let approved = plans
        .decide_adjustment(
            &manager2(),
            adj.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(approved.penalty_before, Some(d("150.00")));
    let due = due_of(&state, "wv-1").await;
    assert_eq!(due.delay_penalty, Decimal::ZERO);
    assert_eq!(due.total_amount, d("1000.00"));
    let write_off = plans
        .request_adjustment(
            &manager(),
            RequestAdjustmentRequest {
                due_id: "wv-1".into(),
                kind: "PRINCIPAL_WRITE_OFF".into(),
                amount: None,
                reason: "Zamanaşımı riski, tahsil edilemez".into(),
            },
            "MANUAL",
        )
        .await
        .unwrap();
    plans
        .decide_adjustment(
            &auditor(),
            write_off.id,
            DecideRequest {
                approve: true,
                note: Some("Denetçi onayı".into()),
            },
        )
        .await
        .unwrap();
    assert_eq!(due_of(&state, "wv-1").await.status, DebtStatus::Paid);
    let tb = AccountingService::new(&state)
        .trial_balance(SITE, None, None)
        .await;
    assert!(tb.balanced);
    assert_eq!(
        tb.rows
            .iter()
            .find(|r| r.account_code == "120")
            .unwrap()
            .balance,
        Decimal::ZERO
    );
    assert_eq!(
        tb.rows
            .iter()
            .find(|r| r.account_code == "689")
            .unwrap()
            .balance,
        d("1000.00")
    );
}

#[tokio::test]
// covers: SC-11-10-02
async fn when_a_plan_is_kept_it_completes_and_waives_the_penalty_and_when_late_it_breaks() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "pl-1",
            "d-14",
            "Mayıs",
            "600.00",
            days_ago(120),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    push_due(
        &state,
        liability(
            "pl-2",
            "d-14",
            "Haziran",
            "300.00",
            days_ago(90),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let plans = PlanService::new(&state);
    let req = |approver: &str| CreatePaymentPlanRequest {
        unit_id: "d-14".into(),
        debtor_type: None,
        due_ids: vec![],
        installment_count: 3,
        first_due_date: today(),
        grace_days: Some(5),
        waive_penalty_on_completion: true,
        approved_by: approver.into(),
        note: None,
    };
    assert!(matches!(
        plans
            .create_plan(&manager(), req("usr-site-manager-1"))
            .await,
        Err(FinanceError::Forbidden(_))
    ));
    let plan = plans
        .create_plan(&manager(), req("usr-site-manager-2"))
        .await
        .unwrap();
    assert_eq!(
        plan.installments.iter().map(|i| i.amount).sum::<Decimal>(),
        d("900.00")
    );
    assert!(
        DunningService::new(&state)
            .run(SITE, None)
            .await
            .unwrap()
            .paused
            == 2,
        "plan items are paused"
    );
    // Late: nothing paid 40 days after the first instalment.
    let broken = plans
        .run(SITE, Some(today() + Days::new(40)))
        .await
        .unwrap();
    assert_eq!(broken.broken, vec![plan.plan.id]);

    // A second plan that is paid in full completes and waives the accrued penalty.
    {
        let mut inner = state.inner.write().await;
        let due = inner.dues.iter_mut().find(|d| d.id == "pl-1").unwrap();
        due.delay_penalty = d("40.00");
        due.total_amount = d("640.00");
    }
    let second = plans
        .create_plan(&manager(), req("usr-site-manager-2"))
        .await
        .unwrap();
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-14".into(),
            amount: second.plan.total_amount,
            payer_name: "Ahmet Yılmaz".into(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::BankTransfer,
            ..Default::default()
        })
        .await
        .unwrap();
    let done = plans.run(SITE, None).await.unwrap();
    assert_eq!(done.completed, vec![second.plan.id]);
}

// ---------------------------------------------------------------------------
// R11: heat-share
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-11-01
async fn when_a_heating_period_is_approved_then_shares_add_up_and_the_occupant_is_billed() {
    let state = fixture().await;
    let heat = HeatShareService::new(&state);
    let period = heat
        .create_period(
            &manager(),
            CreateHeatPeriodRequest {
                label: "Ocak".into(),
                period_start: days_ago(40),
                period_end: days_ago(10),
                total_cost: d("10000.00"),
                consumption_share_percent: None,
                due_date: today() + Days::new(15),
            },
        )
        .await
        .unwrap();
    let id = period.period.id;
    heat.record_readings(
        &manager(),
        id,
        RecordReadingsRequest {
            readings: vec![MeterReadingInput {
                unit_id: "d-14".into(),
                area_weight: Some(100),
                previous_reading: d("10"),
                current_reading: d("40"),
            }],
        },
    )
    .await
    .unwrap();
    assert!(
        matches!(
            heat.approve(&manager(), id).await,
            Err(FinanceError::Conflict(_))
        ),
        "a reading is missing"
    );
    let view = heat
        .record_readings(
            &manager(),
            id,
            RecordReadingsRequest {
                readings: vec![MeterReadingInput {
                    unit_id: "d-15".into(),
                    area_weight: Some(100),
                    previous_reading: d("5"),
                    current_reading: d("15"),
                }],
            },
        )
        .await
        .unwrap();
    assert_eq!(
        view.shares.iter().map(|s| s.total_amount).sum::<Decimal>(),
        d("10000.00")
    );
    let approved = heat.approve(&manager(), id).await.unwrap();
    let a15 = approved
        .shares
        .iter()
        .find(|s| s.unit_id == "d-15")
        .unwrap();
    assert_eq!(a15.consumption_amount, d("1750.00"));
    assert_eq!(a15.fixed_amount, d("1500.00"));
    let due = due_of(&state, a15.due_id.as_deref().unwrap()).await;
    assert_eq!(
        due.debtor_type,
        DebtorType::Tenant,
        "the occupant pays heating"
    );
    assert_eq!(due.principal_amount, d("3250.00"));
    assert!(heat
        .record_readings(&manager(), id, RecordReadingsRequest { readings: vec![] })
        .await
        .is_err());
}

// ---------------------------------------------------------------------------
// R12: assembly and decisions book
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-12-01
async fn when_the_assembly_accepts_a_budget_item_then_a_numbered_decision_approves_the_budget() {
    let state = fixture().await;
    let draft = OperatingBudgetService::new(state.clone())
        .create_draft(
            SITE,
            CreateOperatingBudgetRequest {
                fiscal_year: 2034,
                lines: vec![BudgetLineInput {
                    category: "CLEANING".into(),
                    description: None,
                    annual_amount: d("12000.00"),
                    allocation_key: None,
                    unit_weights: vec![],
                }],
                ..Default::default()
            },
            "a",
        )
        .await
        .unwrap();
    let asm = AssemblyService::new(&state);
    let meeting = asm
        .create_meeting(
            &manager(),
            CreateMeetingRequest {
                kind: None,
                call_number: None,
                scheduled_at: Utc::now() - chrono::Duration::days(1),
                location: "Site toplantı salonu".into(),
                agenda: vec![AgendaItemInput {
                    title: "2034 işletme projesi".into(),
                    description: None,
                    rule: Some("SIMPLE".into()),
                    linked_budget_id: Some(draft.id.clone()),
                }],
            },
        )
        .await
        .unwrap();
    let item = meeting.agenda[0].id;
    assert!(
        asm.cast_votes(
            &manager(),
            item,
            CastVotesRequest {
                votes: vec![VoteInput {
                    unit_id: "d-14".into(),
                    vote: "YES".into()
                }]
            }
        )
        .await
        .is_err(),
        "not held yet"
    );
    let held = asm
        .record_attendance(
            &manager(),
            meeting.meeting.id,
            RecordAttendanceRequest {
                attendance: vec![
                    AttendanceInput {
                        unit_id: "d-14".into(),
                        attendee_name: "Ahmet Yılmaz".into(),
                        is_proxy: false,
                    },
                    AttendanceInput {
                        unit_id: "d-15".into(),
                        attendee_name: "Vekil".into(),
                        is_proxy: true,
                    },
                ],
                held_on: None,
            },
        )
        .await
        .unwrap();
    assert!(held.quorum.has_quorum);
    asm.cast_votes(
        &manager(),
        item,
        CastVotesRequest {
            votes: vec![
                VoteInput {
                    unit_id: "d-14".into(),
                    vote: "YES".into(),
                },
                VoteInput {
                    unit_id: "d-15".into(),
                    vote: "kabul".into(),
                },
            ],
        },
    )
    .await
    .unwrap();
    let decision = asm
        .close_item(
            &manager(),
            item,
            CloseAgendaItemRequest {
                decision_text: "İşletme projesi oybirliği ile kabul edildi.".into(),
                attachment_ref: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(decision.outcome, "ACCEPTED");
    assert_eq!(decision.decision_number, 1);
    assert_eq!(decision.yes_land_share, 36);
    let budget = state
        .inner
        .read()
        .await
        .operating_budgets
        .iter()
        .find(|b| b.id == draft.id)
        .cloned()
        .unwrap();
    assert_eq!(budget.status, BUDGET_APPROVED);
    assert!(budget
        .assembly_decision_ref
        .unwrap()
        .starts_with("Karar No 1"));
    assert_eq!(
        state
            .inner
            .read()
            .await
            .finance
            .budget_decisions
            .get(&draft.id),
        Some(&decision.id)
    );
    let recorded = asm
        .record_decision(
            &manager(),
            RecordDecisionRequest {
                decided_on: today(),
                title: "Kapı değişimi".into(),
                text: "Bina giriş kapısı değiştirilecek".into(),
                outcome: None,
                linked_budget_id: None,
                attachment_ref: None,
            },
        )
        .await
        .unwrap();
    assert_eq!(recorded.decision_number, 2);
}

// ---------------------------------------------------------------------------
// R13: portfolio
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-13-01
async fn when_a_management_company_invoices_its_sites_then_each_period_is_invoiced_once_and_only_members_see_the_portfolio(
) {
    let state = fixture().await;
    let p = PortfolioService::new(&state);
    let company = p
        .create_company(CreateCompanyRequest {
            name: "Begonya Yönetim Ltd.".into(),
            tax_id: "0010180009".into(),
            tax_office: "Kadıköy".into(),
            address: None,
        })
        .await
        .unwrap();
    p.attach_site(
        company.id,
        AttachSiteRequest {
            site_id: SITE.into(),
            monthly_fee: d("5000.00"),
            vat_rate: None,
        },
    )
    .await
    .unwrap();
    assert!(p
        .attach_site(
            company.id,
            AttachSiteRequest {
                site_id: SITE.into(),
                monthly_fee: d("1.00"),
                vat_rate: None
            }
        )
        .await
        .is_err());
    p.add_member(
        company.id,
        AddMemberRequest {
            user_ref: "usr-site-manager-1".into(),
        },
    )
    .await
    .unwrap();
    let summary = p.summary(&manager(), company.id).await.unwrap();
    assert_eq!(summary.sites.len(), 1);
    assert_eq!(summary.total_monthly_fees, d("5000.00"));
    assert!(matches!(
        p.summary(&owner(), company.id).await,
        Err(FinanceError::Forbidden(_))
    ));
    let invoices = p
        .issue_invoices(
            company.id,
            IssueFeeInvoicesRequest {
                period: "2027-01".into(),
            },
        )
        .await
        .unwrap();
    assert_eq!(invoices.len(), 1);
    assert_eq!(invoices[0].vat_amount, d("1000.00"));
    assert_eq!(invoices[0].document_type, "E_ARSIV");
    assert_eq!(invoices[0].integrator_uuid.len(), 36);
    assert!(p
        .issue_invoices(
            company.id,
            IssueFeeInvoicesRequest {
                period: "2027-01".into()
            }
        )
        .await
        .unwrap()
        .is_empty());
    assert!(p
        .issue_invoices(
            company.id,
            IssueFeeInvoicesRequest {
                period: "2027-13".into()
            }
        )
        .await
        .is_err());
}

// ---------------------------------------------------------------------------
// R14: analytics
// ---------------------------------------------------------------------------

#[tokio::test]
// covers: SC-11-14-01
async fn when_analytics_are_computed_then_rates_channels_forecast_and_risky_units_are_reported() {
    let state = fixture().await;
    approved_budget(&state).await;
    push_due(
        &state,
        liability(
            "an-1",
            "d-14",
            "Önceki",
            "1800.00",
            days_ago(95),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    push_due(
        &state,
        liability(
            "an-2",
            "d-15",
            "Bu ay",
            "1400.00",
            today(),
            DebtorType::Tenant,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-15".into(),
            amount: d("1400.00"),
            payer_name: "Zeynep Kaya".into(),
            payer_role: DebtorType::Tenant,
            payment_channel: PaymentChannel::VirtualIban,
            ..Default::default()
        })
        .await
        .unwrap();
    let a = AnalyticsService::new(&state)
        .collections(SITE, Some(6), None)
        .await;
    let this_month = a.months.last().unwrap();
    assert_eq!(this_month.on_time_rate, Some(d("100.00")));
    assert_eq!(a.zero_touch_share_percent, Some(d("100.00")));
    assert_eq!(a.cash_flow_forecast.len(), 6);
    assert_eq!(a.at_risk_units[0].unit_id, "d-14");
}

// ---------------------------------------------------------------------------
// Tenant isolation and the daily job
// ---------------------------------------------------------------------------

#[tokio::test]
async fn when_another_site_acts_then_it_never_sees_or_changes_this_sites_records() {
    let state = fixture().await;
    let v = vendor(&state).await;
    let acc = AccountingService::new(&state);
    let e = acc
        .create_expense(&manager(), expense(v.id, "F-iso", "100.00", "OTHER"))
        .await
        .unwrap();
    let other = Caller {
        site_id: "site-2".into(),
        ..manager2()
    };
    assert!(acc.expenses("site-2").await.is_empty());
    assert!(matches!(
        acc.approve_expense(&other, e.invoice.id).await,
        Err(FinanceError::NotFound(_))
    ));
    assert!(acc.vendors("site-2").await.is_empty());
    push_due(
        &state,
        liability(
            "iso-1",
            "d-14",
            "Ekim",
            "100.00",
            days_ago(40),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    assert!(CollectionsService::new(&state)
        .open_case(
            &other,
            OpenCaseRequest {
                unit_id: "d-14".into(),
                debtor_type: None,
                due_ids: vec![],
                note: None
            }
        )
        .await
        .is_err());
    assert_eq!(
        DunningService::new(&state)
            .run("site-2", None)
            .await
            .unwrap()
            .examined,
        0
    );
    assert!(KvkkService::new(&state)
        .debtor_export(&other)
        .await
        .unwrap()
        .rows
        .is_empty());
}

#[tokio::test]
async fn when_the_daily_collections_job_runs_then_every_step_completes_without_error() {
    let state = fixture().await;
    push_due(
        &state,
        liability(
            "job-1",
            "d-14",
            "Ekim",
            "1800.00",
            days_ago(4),
            DebtorType::Owner,
            ExpenseType::OperationalDues,
        ),
    )
    .await;
    let (_, _, dunning, _) = sitepulse_backend::scheduler::run_daily_collections(&state).await;
    assert_eq!(dunning, 1);
    let (_, _, again, _) = sitepulse_backend::scheduler::run_daily_collections(&state).await;
    assert_eq!(again, 0);
}

#[test]
fn when_a_run_is_just_after_local_midnight_then_the_site_day_is_the_new_local_day() {
    use chrono::{NaiveDate, TimeZone, Utc};
    use std::collections::HashMap;
    // 21:30 UTC on 16 Nov is 00:30 on 17 Nov in Istanbul (UTC+3) but still 16 Nov in UTC.
    let now = Utc.with_ymd_and_hms(2026, 11, 16, 21, 30, 0).unwrap();
    let sites = vec![
        ("istanbul".to_string(), "Europe/Istanbul".to_string()),
        ("utc".to_string(), "UTC".to_string()),
    ];
    let mut last_run: HashMap<String, NaiveDate> = HashMap::new();
    let due = sitepulse_backend::scheduler::sites_due_today(&sites, now, &last_run);
    let day = |id: &str| due.iter().find(|(s, _)| s == id).map(|(_, d)| *d);
    assert_eq!(day("istanbul"), NaiveDate::from_ymd_opt(2026, 11, 17));
    assert_eq!(day("utc"), NaiveDate::from_ymd_opt(2026, 11, 16));

    // Once each site ran for its day, none is due again at the same instant.
    last_run.insert(
        "istanbul".into(),
        NaiveDate::from_ymd_opt(2026, 11, 17).unwrap(),
    );
    last_run.insert("utc".into(), NaiveDate::from_ymd_opt(2026, 11, 16).unwrap());
    assert!(sitepulse_backend::scheduler::sites_due_today(&sites, now, &last_run).is_empty());
    // Three hours later UTC rolls over, Istanbul does not.
    let later = now + chrono::Duration::hours(3);
    let due = sitepulse_backend::scheduler::sites_due_today(&sites, later, &last_run);
    assert_eq!(due.len(), 1);
    assert_eq!(due[0].0, "utc");
}
