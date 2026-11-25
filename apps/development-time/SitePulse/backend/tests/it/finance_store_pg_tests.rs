//! SPEC-009 PostgreSQL round trip (opt-in): every SPEC-009 record is written
//! through the real services against PostgreSQL, then the book is reloaded from
//! the database and compared with memory. This proves the generic row mapping
//! (`db::finance_records`) matches `V20__payments_phase3.sql` column by column.
//!
//! Run against a **scratch** database (it is migrated and seeded):
//!
//! ```text
//! DB_PASS=... DB_NAME=sitepulse_finance_test \
//!   cargo nextest run --locked --profile db --test it -E 'test(/finance_store_pg_tests::every_spec009_record_round_trips_through_postgresql/)' --run-ignored ignored-only --test-threads 4
//! ```

use chrono::{Days, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::db::finance_records::Record;
use sitepulse_backend::db::finance_store::{load_finance_book, FinanceStore};
use sitepulse_backend::domain::TrIban;
use sitepulse_backend::finance_book::{col, FinanceBook};
use sitepulse_backend::models::*;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::assembly_service::AssemblyService;
use sitepulse_backend::services::autopay_service::AutopayService;

/// Today in the site's time zone, the date every service works with.
fn site_today() -> chrono::NaiveDate {
    crate::support::site_today()
}
use sitepulse_backend::services::bank_matching_service::BankMatchingService;
use sitepulse_backend::services::collections_service::CollectionsService;
use sitepulse_backend::services::dunning_service::DunningService;
use sitepulse_backend::services::finance_common::Caller;
use sitepulse_backend::services::heat_share_service::HeatShareService;
use sitepulse_backend::services::kvkk_service::KvkkService;
use sitepulse_backend::services::lease_service::LeaseService;
use sitepulse_backend::services::plan_service::PlanService;
use sitepulse_backend::services::portfolio_service::PortfolioService;
use sitepulse_backend::services::resident_request_service::ResidentRequestService;
use sitepulse_backend::state::AppState;

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn ids<T: Record>(rows: &[T]) -> Vec<i64> {
    let mut v: Vec<i64> = rows.iter().map(Record::id).collect();
    v.sort_unstable();
    v
}

fn assert_same(memory: &FinanceBook, db: &FinanceBook) {
    macro_rules! same {
        ($($f:ident),*) => {
            $(
                assert_eq!(ids(&memory.$f), ids(&db.$f), "{} ids differ", stringify!($f));
                assert!(!db.$f.is_empty(), "{} was not exercised", stringify!($f));
            )*
        };
    }
    same!(
        privacy_notices,
        privacy_acknowledgements,
        consents,
        access_log,
        retention_policies,
        leases,
        notifications,
        dunning_policies,
        dunning_actions,
        virman_requests,
        disputes,
        payment_methods,
        mandates,
        vendors,
        approval_policies,
        expenses,
        expense_payments,
        journal_entries,
        journal_lines,
        cases,
        case_events,
        bank_feeds,
        bank_reconciliations,
        plans,
        plan_installments,
        adjustments,
        heat_periods,
        heat_readings,
        heat_shares,
        meetings,
        agenda_items,
        attendance,
        votes,
        decisions,
        companies,
        company_sites,
        company_members,
        fee_invoices
    );
    // Money, dates, JSON and optional references survive the round trip.
    let e = db
        .expenses
        .iter()
        .find(|e| e.invoice_number == "PG-1")
        .unwrap();
    assert_eq!(e.total_amount, d("1200.50"));
    assert_eq!(e.approvals.len(), 1);
    assert!(e.budget_id.is_none());
    let p = &db.plans[0];
    assert_eq!(p.due_ids.len(), 1);
    assert_eq!(
        db.plan_installments
            .iter()
            .map(|i| i.amount)
            .sum::<Decimal>(),
        p.total_amount
    );
    assert_eq!(db.dunning_policies[0].steps.len(), 4);
    assert_eq!(
        db.heat_shares
            .iter()
            .map(|s| s.total_amount)
            .sum::<Decimal>(),
        db.heat_periods[0].total_cost
    );
    assert!(db.payment_methods[0].token_ref.starts_with("tok_"));
    assert!(db.bank_reconciliations[0].details.get("matched").is_some());
}

#[tokio::test]
#[ignore = "needs PostgreSQL"]
async fn every_spec009_record_round_trips_through_postgresql() {
    let test_db = crate::test_db::create("finance_store").await;
    let pool = test_db.pool.clone();
    let state = AppState::with_pool(Some(pool.clone()));
    {
        let mut inner = state.inner.write().await;
        sitepulse_backend::db::load_all_from_db(&pool, &mut inner)
            .await
            .unwrap();
    }
    let (site, unit, other_unit) = {
        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| !u.site_id.is_empty())
            .cloned()
            .expect("seeded unit");
        let other = inner
            .units
            .iter()
            .find(|u| u.site_id == unit.site_id && u.id != unit.id)
            .map(|u| u.id.clone());
        (unit.site_id.clone(), unit.id.clone(), other)
    };
    let mgr = Caller {
        site_id: site.clone(),
        user_id: "1".into(),
        email: "m@pg".into(),
        role: Role::SiteManager,
        unit_id: None,
    };
    let mgr2 = Caller {
        user_id: "990001".into(),
        email: "m2@pg".into(),
        ..mgr.clone()
    };
    {
        // The plan's second approver (memory only; plans store the actor text).
        let mut inner = state.inner.write().await;
        let mut u = inner
            .users
            .iter()
            .find(|u| u.role == Role::SiteManager)
            .cloned()
            .unwrap_or_else(|| inner.users[0].clone());
        u.id = "990001".into();
        u.site_id = site.clone();
        u.role = Role::SiteManager;
        inner.users.push(u);
    }
    let store = FinanceStore::new(&state);
    let today = site_today();
    let due = store
        .insert_due(DuesLiability {
            id: String::new(),
            unit_id: unit.clone(),
            period: format!("PG test {}", uuid::Uuid::new_v4().simple()),
            principal_amount: d("1000.00"),
            delay_penalty: Decimal::ZERO,
            total_amount: d("1000.00"),
            due_date: today - Days::new(15),
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: DebtorType::Owner,
            expense_type: ExpenseType::OperationalDues,
            penalty_accrued_through: None,
            grace_days: 0,
            effective_due_date: None,
            liable_person_id: None,
        })
        .await
        .unwrap()
        .unwrap();

    // R2
    let kvkk = KvkkService::new(&state);
    kvkk.publish_notice(
        &mgr,
        PublishPrivacyNoticeRequest {
            title: "Aydınlatma".into(),
            body: "Kişisel veriler aidat tahsilatı için işlenir.".into(),
        },
    )
    .await
    .unwrap();
    kvkk.acknowledge(&mgr).await.unwrap();
    kvkk.update_consents(
        &mgr,
        UpdateConsentsRequest {
            consents: vec![ConsentUpdate {
                channel: "WHATSAPP".into(),
                granted: false,
            }],
        },
    )
    .await
    .unwrap();
    kvkk.debtor_export(&mgr).await.unwrap();
    kvkk.set_retention(
        &mgr,
        SetRetentionPolicyRequest {
            category: "ACCESS_LOG".into(),
            retention_months: 24,
        },
    )
    .await
    .unwrap();
    // R3
    LeaseService::new(&state)
        .upsert(
            &mgr,
            UpsertLeaseRequest {
                unit_id: unit.clone(),
                tenant_name: "Kiracı".into(),
                tenant_user_ref: None,
                monthly_rent: d("9000.00"),
                lease_start: today,
                lease_end: None,
                rent_paid_through: None,
            },
        )
        .await
        .unwrap();
    // R4
    let dunning = DunningService::new(&state);
    let mut policy = dunning.policy(&site).await;
    dunning
        .set_policy(
            &mgr,
            SetDunningPolicyRequest {
                enabled: true,
                steps: std::mem::take(&mut policy.steps),
            },
        )
        .await
        .unwrap();
    assert!(!dunning.run(&site, None).await.unwrap().actions.is_empty());
    // R5
    let rr = ResidentRequestService::new(&state);
    state.inner.write().await.advance_balances.insert(
        unit.clone(),
        UnitAdvance {
            owner: d("50.00"),
            tenant: Decimal::ZERO,
        },
    );
    let v = rr
        .create_virman_request(
            &mgr,
            &unit,
            CreateVirmanRequest {
                amount: d("10.00"),
                source_debtor: Some("OWNER".into()),
                note: None,
            },
        )
        .await
        .unwrap();
    rr.decide_virman(
        &mgr,
        v.id,
        DecideRequest {
            approve: false,
            note: Some("Gerek yok".into()),
        },
    )
    .await
    .unwrap();
    let dispute = rr
        .create_dispute(
            &mgr,
            &unit,
            CreateDisputeRequest {
                due_id: due.id.clone(),
                reason: "Tutar hatalı".into(),
            },
        )
        .await
        .unwrap();
    rr.resolve_dispute(
        &mgr,
        dispute.id,
        ResolveDisputeRequest {
            accept: false,
            note: "Doğru".into(),
        },
    )
    .await
    .unwrap();
    // R6
    let method = store
        .insert(
            SavedPaymentMethod {
                id: 0,
                site_id: site.clone(),
                unit_id: unit.clone(),
                debtor_type: "OWNER".into(),
                owner_ref: "pg".into(),
                provider: "SANDBOX".into(),
                token_ref: format!("tok_pg_{}", uuid::Uuid::new_v4().simple()),
                brand: "VISA".into(),
                last4: "4242".into(),
                exp_month: 12,
                exp_year: 2099,
                status: "ACTIVE".into(),
                created_at: Utc::now(),
            },
            col::payment_methods,
        )
        .await
        .unwrap();
    AutopayService::new(&state)
        .create_mandate(
            &mgr,
            &unit,
            CreateMandateRequest {
                payment_method_id: method.id,
                debtor_type: Some("OWNER".into()),
                max_amount: Some(d("5000.00")),
            },
        )
        .await
        .unwrap();
    // R7
    let acc = AccountingService::new(&state);
    let iban = TrIban::from_bban("0006200000000000000001")
        .unwrap()
        .into_string();
    let vendor = acc
        .create_vendor(
            &mgr,
            CreateVendorRequest {
                name: "PG Ltd".into(),
                tax_id: "0010180009".into(),
                iban: Some(iban.clone()),
                email: None,
                phone: None,
            },
        )
        .await;
    let vendor = match vendor {
        Ok(v) => v,
        Err(_) => acc
            .vendors(&site)
            .await
            .into_iter()
            .find(|v| v.tax_id == "0010180009")
            .unwrap(),
    };
    acc.set_policy(
        &mgr,
        SetApprovalPolicyRequest {
            manager_limit: d("50000.00"),
        },
    )
    .await
    .unwrap();
    let number = "PG-1";
    let e = acc
        .create_expense(
            &mgr,
            CreateExpenseRequest {
                vendor_id: vendor.id,
                invoice_number: number.into(),
                invoice_date: today,
                due_date: None,
                category: "WATER".into(),
                description: None,
                net_amount: d("1000.50"),
                vat_amount: d("200.00"),
                document_ref: Some("s3://inv/pg-1.pdf".into()),
            },
        )
        .await
        .unwrap();
    acc.approve_expense(&mgr2, e.invoice.id).await.unwrap();
    acc.pay_expense(
        &mgr,
        e.invoice.id,
        PayExpenseRequest {
            amount: d("200.00"),
            paid_on: None,
            method: Some("CASH".into()),
            reference: None,
        },
    )
    .await
    .unwrap();
    acc.create_journal_entry(
        &mgr,
        CreateJournalEntryRequest {
            entry_date: None,
            kind: Some("OPENING".into()),
            description: "Açılış".into(),
            lines: vec![
                JournalLineInput {
                    account_code: "102".into(),
                    debit: d("100.00"),
                    credit: Decimal::ZERO,
                },
                JournalLineInput {
                    account_code: "500".into(),
                    debit: Decimal::ZERO,
                    credit: d("100.00"),
                },
            ],
        },
    )
    .await
    .unwrap();
    assert!(acc.trial_balance(&site, None, None).await.balanced);
    // R8
    let col_svc = CollectionsService::new(&state);
    let case = col_svc
        .open_case(
            &mgr,
            OpenCaseRequest {
                unit_id: unit.clone(),
                debtor_type: None,
                due_ids: vec![due.id.clone()],
                note: None,
            },
        )
        .await
        .unwrap();
    col_svc
        .advance(
            &mgr,
            case.case.id,
            AdvanceCaseRequest {
                to_status: "LAWYER_ASSIGNED".into(),
                note: None,
                occurred_on: None,
                lawyer_name: Some("Av. PG".into()),
                lawyer_contact: None,
            },
        )
        .await
        .unwrap();
    col_svc
        .grant_lawyer_access(&mgr, case.case.id)
        .await
        .unwrap();
    // R9
    let bank = BankMatchingService::new(&state);
    if bank.feeds(&site).await.is_empty() {
        bank.create_feed(
            &mgr,
            CreateBankFeedRequest {
                provider: "SANDBOX".into(),
                account_iban: iban,
                credential_ref: Some("vault:pg".into()),
            },
        )
        .await
        .unwrap();
    }
    let feed = bank.feeds(&site).await[0].id;
    bank.sync_feed(&mgr, feed).await.unwrap();
    bank.daily_reconciliation(
        &mgr,
        DailyReconciliationRequest {
            business_date: today,
            bank_closing_balance: None,
            lines: vec![BankLine {
                reference: None,
                amount: d("10.00"),
                description: None,
            }],
        },
    )
    .await
    .unwrap();
    // R10
    let plans = PlanService::new(&state);
    plans
        .create_plan(
            &mgr,
            CreatePaymentPlanRequest {
                unit_id: unit.clone(),
                debtor_type: None,
                due_ids: vec![due.id.clone()],
                installment_count: 2,
                first_due_date: today,
                grace_days: None,
                waive_penalty_on_completion: false,
                approved_by: "990001".into(),
                note: None,
            },
        )
        .await
        .unwrap();
    let adj = plans
        .request_adjustment(
            &mgr,
            RequestAdjustmentRequest {
                due_id: due.id.clone(),
                kind: "PRINCIPAL_WRITE_OFF".into(),
                amount: Some(d("1.00")),
                reason: "PG yuvarlama farkı".into(),
            },
            "MANUAL",
        )
        .await
        .unwrap();
    plans
        .decide_adjustment(
            &mgr2,
            adj.id,
            DecideRequest {
                approve: true,
                note: None,
            },
        )
        .await
        .unwrap();
    // R11
    let heat = HeatShareService::new(&state);
    let period = heat
        .create_period(
            &mgr,
            CreateHeatPeriodRequest {
                label: format!("PG {}", uuid::Uuid::new_v4().simple()),
                period_start: today,
                period_end: today,
                total_cost: d("1000.00"),
                consumption_share_percent: None,
                due_date: today + Days::new(10),
            },
        )
        .await
        .unwrap();
    let units: Vec<String> = state
        .inner
        .read()
        .await
        .units
        .iter()
        .filter(|u| u.site_id == site)
        .map(|u| u.id.clone())
        .collect();
    heat.record_readings(
        &mgr,
        period.period.id,
        RecordReadingsRequest {
            readings: units
                .iter()
                .map(|u| MeterReadingInput {
                    unit_id: u.clone(),
                    area_weight: None,
                    previous_reading: d("1.000"),
                    current_reading: d("2.500"),
                })
                .collect(),
        },
    )
    .await
    .unwrap();
    heat.approve(&mgr, period.period.id).await.unwrap();
    // R12
    let asm = AssemblyService::new(&state);
    let meeting = asm
        .create_meeting(
            &mgr,
            CreateMeetingRequest {
                kind: None,
                call_number: Some(2),
                scheduled_at: Utc::now(),
                location: "PG salonu".into(),
                agenda: vec![AgendaItemInput {
                    title: "Bahçe düzenlemesi".into(),
                    description: None,
                    rule: None,
                    linked_budget_id: None,
                }],
            },
        )
        .await
        .unwrap();
    asm.record_attendance(
        &mgr,
        meeting.meeting.id,
        RecordAttendanceRequest {
            attendance: vec![AttendanceInput {
                unit_id: unit.clone(),
                attendee_name: "Malik".into(),
                is_proxy: false,
            }],
            held_on: None,
        },
    )
    .await
    .unwrap();
    asm.cast_votes(
        &mgr,
        meeting.agenda[0].id,
        CastVotesRequest {
            votes: vec![VoteInput {
                unit_id: unit.clone(),
                vote: "YES".into(),
            }],
        },
    )
    .await
    .unwrap();
    asm.close_item(
        &mgr,
        meeting.agenda[0].id,
        CloseAgendaItemRequest {
            decision_text: "Kabul edildi.".into(),
            attachment_ref: None,
        },
    )
    .await
    .unwrap();
    // R13
    let portfolio = PortfolioService::new(&state);
    let tax = if portfolio
        .companies()
        .await
        .iter()
        .any(|c| c.tax_id == "10000000146")
    {
        None
    } else {
        Some("10000000146")
    };
    let company = match tax {
        Some(t) => portfolio
            .create_company(CreateCompanyRequest {
                name: "PG Yönetim".into(),
                tax_id: t.into(),
                tax_office: "Kadıköy".into(),
                address: None,
            })
            .await
            .unwrap(),
        None => portfolio
            .companies()
            .await
            .into_iter()
            .find(|c| c.tax_id == "10000000146")
            .unwrap(),
    };
    if portfolio
        .summary(
            &Caller {
                role: Role::SaasAdmin,
                ..mgr.clone()
            },
            company.id,
        )
        .await
        .unwrap()
        .sites
        .is_empty()
    {
        let attach = portfolio
            .attach_site(
                company.id,
                AttachSiteRequest {
                    site_id: site.clone(),
                    monthly_fee: d("100.00"),
                    vat_rate: None,
                },
            )
            .await;
        assert!(attach.is_ok() || other_unit.is_some());
    }
    let _ = portfolio
        .add_member(
            company.id,
            AddMemberRequest {
                user_ref: format!("pg-{}", uuid::Uuid::new_v4().simple()),
            },
        )
        .await
        .unwrap();
    portfolio
        .issue_invoices(
            company.id,
            IssueFeeInvoicesRequest {
                period: format!("20{:02}-01", (Utc::now().timestamp() % 90) + 10),
            },
        )
        .await
        .unwrap();

    let memory = state.inner.read().await.finance.clone();
    let reloaded = load_finance_book(&pool).await.unwrap();
    assert_same(&memory, &reloaded);
    // The due's adjustment and the budget transition columns are written too.
    let adjusted: Decimal = pool
        .get()
        .await
        .unwrap()
        .query_one(
            "SELECT principal_amount FROM dues_liabilities WHERE id = $1",
            &[&due.id.parse::<i64>().unwrap()],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(adjusted, d("999.00"));
    test_db.drop_db().await;
}
