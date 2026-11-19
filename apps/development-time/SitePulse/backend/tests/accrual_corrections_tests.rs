//! STORY-07-11 acceptance tests (in-memory): accrual corrections with cancel,
//! re-issue and credit note. Scenarios: `.specify/features/EPIC-07/STORY-07-11-*.feature`.

use chrono::{Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::accounting_service::AccountingService;
use sitepulse_backend::services::correction_service::{plan_correction, CorrectionService};
use sitepulse_backend::services::finance_common::{Caller, FinanceError};
use sitepulse_backend::services::occupancy_service::OccupancyService;
use sitepulse_backend::services::resident_statement::build_statement;
use sitepulse_backend::services::PaymentTrackingService;
use sitepulse_backend::state::AppState;

const SITE: &str = "site-1";
const UNIT: &str = "d-14";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn today() -> NaiveDate {
    sitepulse_backend::scheduler::site_local_date("Europe/Istanbul", Utc::now())
}

fn manager(user: &str) -> Caller {
    Caller {
        site_id: SITE.to_string(),
        user_id: user.to_string(),
        email: format!("{}@begonya.com", user),
        role: Role::SiteManager,
        unit_id: None,
    }
}

fn first_manager() -> Caller {
    manager("usr-site-manager-1")
}

fn second_manager() -> Caller {
    manager("usr-site-manager-2")
}

fn liability(id: &str, amount: &str, due: NaiveDate) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: "2026-10".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: due,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
    }
}

/// Site 1 with unit A-14 and no liabilities, advances or receipts.
async fn fixture() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner.payment_idempotency.clear();
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
        .find(|due| due.id == id)
        .cloned()
        .unwrap()
}

async fn pay(state: &AppState, amount: &str) {
    PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: UNIT.into(),
            amount: d(amount),
            payer_name: "Ahmet Yılmaz".into(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::VirtualIban,
            ..Default::default()
        })
        .await
        .unwrap();
}

fn request(
    due_id: &str,
    kind: &str,
    amount: Option<&str>,
    reason: &str,
) -> RequestCorrectionRequest {
    RequestCorrectionRequest {
        due_id: due_id.into(),
        kind: kind.into(),
        amount: amount.map(d),
        due_date: None,
        debtor_type: None,
        replacement_shares: Vec::new(),
        reason: reason.into(),
    }
}

fn approve() -> DecideRequest {
    DecideRequest {
        approve: true,
        note: None,
    }
}

async fn receivable_and_advance(state: &AppState) -> (Decimal, Decimal, bool) {
    let tb = AccountingService::new(state)
        .trial_balance(SITE, None, None)
        .await;
    let balance = |code: &str| {
        tb.rows
            .iter()
            .find(|r| r.account_code == code)
            .map(|r| r.balance)
            .unwrap_or_default()
    };
    (balance("120"), balance("340"), tb.balanced)
}

// covers: SC-07-11-01
#[tokio::test]
async fn when_a_liability_with_a_payment_is_cancelled_then_the_payment_moves_to_the_advance_balance(
) {
    let state = fixture().await;
    push_due(&state, liability("c-1", "1400.00", today())).await;
    pay(&state, "600.00").await;
    let receipts_before =
        serde_json::to_string(&state.inner.read().await.payment_receipts).unwrap();
    assert_eq!(due_of(&state, "c-1").await.paid_principal, d("600.00"));

    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("c-1", "CANCEL", None, "duplicate charge"),
        )
        .await
        .unwrap();
    assert_eq!(requested.status, REQUEST_PENDING);
    assert_eq!(due_of(&state, "c-1").await.status, DebtStatus::Pending);
    let approved = corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    assert_eq!(approved.status, REQUEST_APPROVED);
    assert_eq!(approved.advance_credited, Some(d("600.00")));
    assert_eq!(approved.principal_before, Some(d("1400.00")));
    let cancelled = due_of(&state, "c-1").await;
    assert_eq!(cancelled.status, DebtStatus::Cancelled);
    assert_eq!(cancelled.principal_amount, d("1400.00"));
    assert_eq!(cancelled.total_amount, Decimal::ZERO);
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "OWNER"),
        d("600.00")
    );
    // The receipt is never altered.
    assert_eq!(
        serde_json::to_string(&state.inner.read().await.payment_receipts).unwrap(),
        receipts_before
    );
    // The ledger keeps the accrual and shows the reversing entry; it still balances.
    let journal = AccountingService::new(&state)
        .journal(SITE, None, None)
        .await;
    let reversal = journal
        .iter()
        .find(|e| e.source == "CANCELLATION")
        .expect("reversing entry");
    assert_eq!(
        reversal
            .lines
            .iter()
            .find(|l| l.account_code == "120")
            .unwrap()
            .credit,
        d("1400.00")
    );
    let (receivable, advance, balanced) = receivable_and_advance(&state).await;
    assert!(balanced);
    assert_eq!(receivable, Decimal::ZERO);
    assert_eq!(advance, d("600.00"));
}

// covers: SC-07-11-02
#[tokio::test]
async fn when_a_liability_is_reissued_then_the_original_is_cancelled_and_the_new_one_refers_to_it()
{
    let state = fixture().await;
    let due_date = today() + Days::new(10);
    push_due(&state, liability("r-1", "1800.00", due_date)).await;
    // The original was accrued from operating budget 7 (its KMK 37 legal basis).
    state
        .inner
        .write()
        .await
        .dues_budget_basis
        .insert("r-1".to_string(), "7".to_string());

    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("r-1", "REISSUE", Some("1400.00"), "wrong house type"),
        )
        .await
        .unwrap();
    let approved = corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    assert_eq!(due_of(&state, "r-1").await.status, DebtStatus::Cancelled);
    let new_id = approved.replacement_due_id.clone().expect("replacement");
    let replacement = due_of(&state, &new_id).await;
    assert_eq!(replacement.principal_amount, d("1400.00"));
    assert_eq!(replacement.period, "2026-10");
    assert_eq!(replacement.due_date, due_date);
    assert_eq!(replacement.status, DebtStatus::Pending);
    assert_eq!(
        state
            .inner
            .read()
            .await
            .dues_budget_basis
            .get(&new_id)
            .map(String::as_str),
        Some("7"),
        "the re-issued liability keeps the original's operating budget"
    );
    let listed = corrections.list(SITE).await;
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].due_id, "r-1");
    assert_eq!(
        listed[0].replacement_due_id.as_deref(),
        Some(new_id.as_str())
    );
    let (receivable, _, balanced) = receivable_and_advance(&state).await;
    assert!(balanced);
    assert_eq!(receivable, d("1400.00"));
}

#[tokio::test]
// covers: SC-07-09-03
// Backend coverage: SC-13-05-18 late move-out split correction and four-eyes approval.
async fn when_a_paid_month_is_split_then_approval_reissues_both_roles_and_credits_the_excess() {
    let state = fixture().await;
    let mut paid_due = liability("split-1", "1400.00", today());
    paid_due.debtor_type = DebtorType::Tenant;
    paid_due.status = DebtStatus::Paid;
    paid_due.paid_principal = d("1400.00");
    paid_due.total_amount = Decimal::ZERO;
    let effective_date = NaiveDate::from_ymd_opt(2026, 10, 21).expect("fixture date");
    {
        let mut inner = state.inner.write().await;
        inner.dues.push(paid_due);
        inner
            .dues_budget_basis
            .insert("split-1".to_string(), "budget-split".to_string());
        inner
            .sites
            .iter_mut()
            .find(|site| site.id == SITE)
            .expect("fixture site")
            .proration_enabled = true;
        inner.dues_periods.push(DuesPeriod {
            id: "period-split".to_string(),
            site_id: SITE.to_string(),
            period_name: "2026-10".to_string(),
            due_date: NaiveDate::from_ymd_opt(2026, 10, 15).expect("fixture date"),
            status: DuesPeriodStatus::Active,
            created_at: None,
        });
        inner.unit_occupancies.insert(
            UNIT.to_string(),
            vec![OccupancyHistoryItem {
                id: 80,
                unit_id: 14,
                person_id: 12,
                person_name: "Tenant fixture".to_string(),
                person_phone: None,
                person_email: None,
                role: DebtorType::Tenant,
                start_date: "2026-10-01".to_string(),
                end_date: Some("2026-10-21".to_string()),
                is_active: false,
                exit_balance: Decimal::ZERO,
                notes: None,
                created_at: Utc::now(),
            }],
        );
    }

    let corrections = CorrectionService::new(&state);
    let requested = OccupancyService::new(state.clone())
        .request_open_period_split(&first_manager(), UNIT, effective_date)
        .await
        .unwrap()
        .expect("move-out requests a split correction");
    assert_eq!(requested.kind, CORRECTION_SPLIT_REISSUE);
    assert_eq!(requested.replacement_shares.len(), 2);
    assert!(requested
        .replacement_shares
        .iter()
        .any(|share| { share.debtor_type == DebtorType::Tenant && share.amount == d("903.23") }));
    assert!(requested
        .replacement_shares
        .iter()
        .any(|share| { share.debtor_type == DebtorType::Owner && share.amount == d("496.77") }));
    assert_eq!(due_of(&state, "split-1").await.status, DebtStatus::Paid);

    let approved = corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();
    assert_eq!(approved.status, REQUEST_APPROVED);
    assert_eq!(approved.advance_credited, Some(d("1400.00")));
    assert_eq!(approved.replacement_due_ids.len(), 2);
    assert_eq!(
        due_of(&state, "split-1").await.status,
        DebtStatus::Cancelled
    );

    let mut replacements = Vec::new();
    for id in &approved.replacement_due_ids {
        replacements.push(due_of(&state, id).await);
    }
    assert_eq!(replacements.len(), 2);
    assert!(replacements.iter().any(|due| {
        due.debtor_type == DebtorType::Tenant && due.principal_amount == d("903.23")
    }));
    assert!(replacements.iter().any(|due| {
        due.debtor_type == DebtorType::Owner && due.principal_amount == d("496.77")
    }));
    {
        let inner = state.inner.read().await;
        assert!(approved.replacement_due_ids.iter().all(|id| {
            inner.dues_budget_basis.get(id).map(String::as_str) == Some("budget-split")
        }));
    }
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "TENANT"),
        d("496.77")
    );
}

// covers: SC-07-11-03
#[tokio::test]
async fn when_a_credit_note_is_approved_then_the_amount_and_the_late_fee_drop_in_proportion() {
    let state = fixture().await;
    let mut due = liability("n-1", "1400.00", today() - Days::new(10));
    due.delay_penalty = d("23.33");
    due.total_amount = d("1423.33");
    push_due(&state, due).await;

    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("n-1", "CREDIT_NOTE", Some("700.00"), "budget revision"),
        )
        .await
        .unwrap();
    let approved = corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    let reduced = due_of(&state, "n-1").await;
    assert_eq!(reduced.principal_amount, d("700.00"));
    assert_eq!(reduced.delay_penalty, d("11.67"));
    assert_eq!(reduced.total_amount, d("711.67"));
    assert_eq!(approved.penalty_reversed, Some(d("11.66")));
    assert_eq!(approved.advance_credited, Some(Decimal::ZERO));
    let (receivable, _, balanced) = receivable_and_advance(&state).await;
    assert!(balanced);
    assert_eq!(receivable, d("711.67"));
}

// covers: SC-07-11-04
#[tokio::test]
async fn when_the_requester_approves_their_own_correction_then_it_is_forbidden_and_nothing_changes()
{
    let state = fixture().await;
    push_due(&state, liability("f-1", "1400.00", today())).await;
    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("f-1", "CANCEL", None, "wrong unit"),
        )
        .await
        .unwrap();

    let refused = corrections
        .decide(&first_manager(), requested.id, approve())
        .await;
    assert!(matches!(refused, Err(FinanceError::Forbidden(_))));
    assert_eq!(due_of(&state, "f-1").await.status, DebtStatus::Pending);
    assert_eq!(corrections.list(SITE).await[0].status, REQUEST_PENDING);
}

// covers: SC-07-11-05
#[tokio::test]
async fn when_a_credit_note_is_approved_then_the_resident_statement_shows_it_with_the_reason() {
    let state = fixture().await;
    push_due(&state, liability("s-1", "1400.00", today() + Days::new(5))).await;
    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("s-1", "CREDIT_NOTE", Some("700.00"), "budget revision"),
        )
        .await
        .unwrap();
    corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    let inner = state.inner.read().await;
    let unit = inner.units.iter().find(|u| u.id == UNIT).unwrap();
    let statement = build_statement(&inner, unit, None, today());
    assert_eq!(statement.corrections.len(), 1);
    let line = &statement.corrections[0];
    assert_eq!(line.kind, "CREDIT_NOTE");
    assert_eq!(line.period, "2026-10");
    assert_eq!(line.original_amount, d("1400.00"));
    assert_eq!(line.credited_amount, d("700.00"));
    assert_eq!(line.reason, "budget revision");
}

#[tokio::test]
async fn a_credit_note_beyond_what_was_paid_moves_the_excess_to_the_advance_balance() {
    let state = fixture().await;
    push_due(&state, liability("e-1", "1000.00", today() + Days::new(5))).await;
    pay(&state, "800.00").await;
    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("e-1", "CREDIT_NOTE", Some("500.00"), "budget revision"),
        )
        .await
        .unwrap();
    let approved = corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    let reduced = due_of(&state, "e-1").await;
    assert_eq!(reduced.principal_amount, d("500.00"));
    assert_eq!(reduced.paid_principal, d("500.00"));
    assert_eq!(reduced.status, DebtStatus::Paid);
    assert_eq!(approved.advance_credited, Some(d("300.00")));
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "OWNER"),
        d("300.00")
    );
    let (receivable, advance, balanced) = receivable_and_advance(&state).await;
    assert!(balanced);
    assert_eq!(receivable, Decimal::ZERO);
    assert_eq!(advance, d("300.00"));
}

#[tokio::test]
async fn a_cancelled_payment_credit_is_offset_against_the_debtors_other_open_liabilities() {
    let state = fixture().await;
    push_due(&state, liability("o-1", "1400.00", today() + Days::new(5))).await;
    let mut other = liability("o-2", "900.00", today() + Days::new(20));
    other.period = "2026-11".into();
    push_due(&state, other).await;
    pay(&state, "600.00").await;

    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("o-1", "CANCEL", None, "duplicate charge"),
        )
        .await
        .unwrap();
    corrections
        .decide(&second_manager(), requested.id, approve())
        .await
        .unwrap();

    let other = due_of(&state, "o-2").await;
    assert_eq!(other.paid_principal, d("600.00"));
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "OWNER"),
        Decimal::ZERO
    );
}

#[tokio::test]
async fn a_correction_needs_a_reason_and_only_one_may_wait_per_liability() {
    let state = fixture().await;
    push_due(&state, liability("v-1", "1400.00", today())).await;
    let corrections = CorrectionService::new(&state);

    let short = corrections
        .request(&first_manager(), request("v-1", "CANCEL", None, "no"))
        .await;
    assert!(matches!(short, Err(FinanceError::Invalid(_))));
    let credit_without_amount = corrections
        .request(
            &first_manager(),
            request("v-1", "CREDIT_NOTE", None, "budget revision"),
        )
        .await;
    assert!(matches!(
        credit_without_amount,
        Err(FinanceError::Invalid(_))
    ));
    let whole = corrections
        .request(
            &first_manager(),
            request("v-1", "CREDIT_NOTE", Some("1400.00"), "budget revision"),
        )
        .await;
    assert!(matches!(whole, Err(FinanceError::Conflict(_))));

    corrections
        .request(
            &first_manager(),
            request("v-1", "CANCEL", None, "wrong unit"),
        )
        .await
        .unwrap();
    let second = corrections
        .request(
            &second_manager(),
            request("v-1", "CANCEL", None, "wrong unit"),
        )
        .await;
    assert!(matches!(second, Err(FinanceError::Conflict(_))));
}

#[tokio::test]
async fn a_rejected_correction_leaves_the_liability_as_it_was_and_a_cancelled_one_cannot_be_corrected_again(
) {
    let state = fixture().await;
    push_due(&state, liability("x-1", "1400.00", today())).await;
    let corrections = CorrectionService::new(&state);
    let first = corrections
        .request(
            &first_manager(),
            request("x-1", "CANCEL", None, "wrong unit"),
        )
        .await
        .unwrap();
    let rejected = corrections
        .decide(
            &second_manager(),
            first.id,
            DecideRequest {
                approve: false,
                note: Some("the charge is right".into()),
            },
        )
        .await
        .unwrap();
    assert_eq!(rejected.status, REQUEST_REJECTED);
    assert_eq!(due_of(&state, "x-1").await.status, DebtStatus::Pending);

    let again = corrections
        .request(
            &first_manager(),
            request("x-1", "CANCEL", None, "wrong unit"),
        )
        .await
        .unwrap();
    corrections
        .decide(&second_manager(), again.id, approve())
        .await
        .unwrap();
    let after = corrections
        .request(
            &first_manager(),
            request("x-1", "CANCEL", None, "wrong unit"),
        )
        .await;
    assert!(matches!(after, Err(FinanceError::Conflict(_))));
    assert_eq!(corrections.list(SITE).await.len(), 2);
}

#[test]
fn the_credit_note_plan_rounds_the_remaining_late_fee_half_away_from_zero() {
    let mut due = liability("p-1", "1400.00", today());
    due.delay_penalty = d("23.33");
    let plan = plan_correction(&due, "CREDIT_NOTE", d("700.00")).unwrap();
    assert_eq!(plan.penalty, d("11.67"));
    assert_eq!(plan.penalty_reversed, d("11.66"));
    assert!(!plan.cancel);
    let cancel = plan_correction(&due, "CANCEL", d("1400.00")).unwrap();
    assert!(cancel.cancel);
    assert_eq!(cancel.penalty_reversed, d("23.33"));
}

// covers: SC-05-02-01
#[tokio::test]
async fn approving_the_same_correction_twice_concurrently_applies_it_once() {
    let state = fixture().await;
    push_due(&state, liability("k-1", "1000.00", today() + Days::new(5))).await;
    pay(&state, "800.00").await;
    let corrections = CorrectionService::new(&state);
    let requested = corrections
        .request(
            &first_manager(),
            request("k-1", "CREDIT_NOTE", Some("500.00"), "budget revision"),
        )
        .await
        .unwrap();
    let other = manager("usr-site-manager-3");
    let approver = second_manager();
    let (a, b) = tokio::join!(
        corrections.decide(&approver, requested.id, approve()),
        corrections.decide(&other, requested.id, approve()),
    );
    assert_eq!(
        [a.is_ok(), b.is_ok()].iter().filter(|ok| **ok).count(),
        1,
        "exactly one approval wins"
    );
    assert!(matches!(
        a.err().or(b.err()),
        Some(FinanceError::Conflict(_))
    ));
    assert_eq!(due_of(&state, "k-1").await.principal_amount, d("500.00"));
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "OWNER"),
        d("300.00")
    );

    // A later approval, for example a retry after a failure, changes nothing.
    let again = corrections
        .decide(&second_manager(), requested.id, approve())
        .await;
    assert!(matches!(again, Err(FinanceError::Conflict(_))));
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "OWNER"),
        d("300.00")
    );
}

/// PostgreSQL round trip (opt-in, scratch database; see `finance_store_pg_tests`):
/// the three corrections are stored, survive a reload and credit the advance in the database.
#[tokio::test]
async fn corrections_round_trip_through_postgresql() {
    if std::env::var("SITEPULSE_PG_TESTS").as_deref() != Ok("1") {
        println!("SKIPPED accrual_corrections_tests (pg): set SITEPULSE_PG_TESTS=1 and DB_*");
        return;
    }
    let pool = sitepulse_backend::db::create_pool()
        .unwrap()
        .expect("DB_PASS is set");
    sitepulse_backend::db::init_db(&pool).await.unwrap();
    pool.get()
        .await
        .unwrap()
        .batch_execute(include_str!("../db/seed/02-test-seed.sql"))
        .await
        .unwrap();
    let state = AppState::with_pool(Some(pool.clone()));
    {
        let mut inner = state.inner.write().await;
        sitepulse_backend::db::load_all_from_db(&pool, &mut inner)
            .await
            .unwrap();
    }
    let (site, unit) = {
        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| !u.site_id.is_empty())
            .cloned()
            .expect("seeded unit");
        (unit.site_id.clone(), unit.id.clone())
    };
    let first = Caller {
        site_id: site.clone(),
        user_id: "1".into(),
        email: "m@pg".into(),
        role: Role::SiteManager,
        unit_id: None,
    };
    let second = Caller {
        user_id: "990001".into(),
        email: "m2@pg".into(),
        ..first.clone()
    };
    let store = sitepulse_backend::db::finance_store::FinanceStore::new(&state);
    let period = format!("PG-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
    let make = |amount: &str, expense: ExpenseType| {
        let mut due = liability("pending", amount, today() + Days::new(20));
        due.unit_id = unit.clone();
        due.period = period.clone();
        due.expense_type = expense;
        due
    };
    let to_cancel = store
        .insert_due(make("1400.00", ExpenseType::OperationalDues))
        .await
        .unwrap()
        .unwrap();
    // Give the original a canonical period key (STORY-07-08) so the re-issue can be
    // checked to carry it over. The scratch label is unique per run, so is the key.
    pool.get()
        .await
        .unwrap()
        .execute(
            "UPDATE dues_liabilities SET period_key = period WHERE id = $1",
            &[&to_cancel.id.parse::<i64>().unwrap()],
        )
        .await
        .unwrap();
    // ...and an operating budget as its legal basis (KMK 37).
    let budget: i64 = pool
        .get()
        .await
        .unwrap()
        .query_one(
            "INSERT INTO operating_budgets (site_id, fiscal_year, period_start, period_end, created_by)
             VALUES ($1, 2026, DATE '2026-01-01', DATE '2026-12-31', 'pg-test') RETURNING id",
            &[&site.parse::<i64>().unwrap()],
        )
        .await
        .unwrap()
        .get(0);
    pool.get()
        .await
        .unwrap()
        .execute(
            "UPDATE dues_liabilities SET operating_budget_id = $2 WHERE id = $1",
            &[&to_cancel.id.parse::<i64>().unwrap(), &budget],
        )
        .await
        .unwrap();
    state
        .inner
        .write()
        .await
        .dues_budget_basis
        .insert(to_cancel.id.clone(), budget.to_string());
    // A cancelled period can be re-issued: the duplicate guard ignores cancelled rows.
    let corrections = CorrectionService::new(&state);
    let mut split_request = request(
        &to_cancel.id,
        "SPLIT_REISSUE",
        None,
        "correct occupancy shares",
    );
    split_request.replacement_shares = vec![
        CorrectionReplacementShare {
            debtor_type: DebtorType::Owner,
            amount: d("600.00"),
        },
        CorrectionReplacementShare {
            debtor_type: DebtorType::Tenant,
            amount: d("600.00"),
        },
    ];
    let requested = corrections.request(&first, split_request).await.unwrap();
    let approved = corrections
        .decide(&second, requested.id, approve())
        .await
        .unwrap();
    assert_eq!(approved.replacement_due_ids.len(), 2);
    for replacement_id in &approved.replacement_due_ids {
        let row = pool
            .get()
            .await
            .unwrap()
            .query_one(
                "SELECT period_key, operating_budget_id FROM dues_liabilities WHERE id = $1",
                &[&replacement_id.parse::<i64>().unwrap()],
            )
            .await
            .unwrap();
        let carried_key: Option<String> = row.get(0);
        let carried_budget: Option<i64> = row.get(1);
        assert_eq!(carried_key.as_deref(), Some(period.as_str()));
        assert_eq!(carried_budget, Some(budget));
        assert_eq!(
            state
                .inner
                .read()
                .await
                .dues_budget_basis
                .get(replacement_id),
            Some(&budget.to_string())
        );
    }
    let replacement_id = approved.replacement_due_ids[0].clone();

    let credited = corrections
        .request(
            &first,
            request(
                &replacement_id,
                "CREDIT_NOTE",
                Some("200.00"),
                "budget revision",
            ),
        )
        .await
        .unwrap();
    corrections
        .decide(&second, credited.id, approve())
        .await
        .unwrap();

    // Two approvers at once: the correction is claimed in the same transaction as
    // the change, so the advance is credited once.
    let mut paid_due = make("900.00", ExpenseType::OperationalDues);
    paid_due.period = format!("{}b", &period[..9]);
    let paid_due = store.insert_due(paid_due).await.unwrap().unwrap();
    let note = corrections
        .request(
            &first,
            request(&paid_due.id, "CANCEL", None, "duplicate charge"),
        )
        .await
        .unwrap();
    let third = Caller {
        user_id: "990002".into(),
        email: "m3@pg".into(),
        ..first.clone()
    };
    let (x, y) = tokio::join!(
        corrections.decide(&second, note.id, approve()),
        corrections.decide(&third, note.id, approve()),
    );
    assert_eq!([x.is_ok(), y.is_ok()].iter().filter(|ok| **ok).count(), 1);
    let approvals: i64 = pool
        .get()
        .await
        .unwrap()
        .query_one(
            "SELECT count(*) FROM accrual_corrections WHERE id = $1 AND status = 'APPROVED'",
            &[&note.id],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(approvals, 1);

    let stored: (String, rust_decimal::Decimal) = {
        let client = pool.get().await.unwrap();
        let row = client
            .query_one(
                "SELECT status, principal_amount FROM dues_liabilities WHERE id = $1::text::bigint",
                &[&replacement_id],
            )
            .await
            .unwrap();
        (row.get(0), row.get(1))
    };
    assert_eq!(stored.1, d("400.00"));
    let cancelled: String = pool
        .get()
        .await
        .unwrap()
        .query_one(
            "SELECT status FROM dues_liabilities WHERE id = $1::text::bigint",
            &[&to_cancel.id],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(cancelled, "CANCELLED");

    let mut split_due = make("1400.00", ExpenseType::OperationalDues);
    split_due.debtor_type = DebtorType::Tenant;
    split_due.period = format!("{}s", &period[..9]);
    let split_due = store.insert_due(split_due).await.unwrap().unwrap();
    pool.get()
        .await
        .unwrap()
        .execute(
            "UPDATE dues_liabilities SET period_key = period, paid_amount = 1400, paid_principal = 1400, status = 'PAID' WHERE id = $1::text::bigint",
            &[&split_due.id],
        )
        .await
        .unwrap();
    if let Some(due) = state
        .inner
        .write()
        .await
        .dues
        .iter_mut()
        .find(|due| due.id == split_due.id)
    {
        due.status = DebtStatus::Paid;
        due.paid_principal = d("1400.00");
        due.total_amount = Decimal::ZERO;
    }
    let split = corrections
        .request(
            &first,
            RequestCorrectionRequest {
                due_id: split_due.id.clone(),
                kind: CORRECTION_SPLIT_REISSUE.to_string(),
                amount: None,
                due_date: None,
                debtor_type: None,
                replacement_shares: vec![
                    CorrectionReplacementShare {
                        debtor_type: DebtorType::Tenant,
                        amount: d("903.23"),
                    },
                    CorrectionReplacementShare {
                        debtor_type: DebtorType::Owner,
                        amount: d("496.77"),
                    },
                ],
                reason: "Move-out changed the responsible days".to_string(),
            },
        )
        .await
        .unwrap();
    let split_approved = corrections
        .decide(&second, split.id, approve())
        .await
        .unwrap();
    assert_eq!(split_approved.replacement_due_ids.len(), 2);
    assert_eq!(split_approved.advance_credited, Some(d("1400.00")));
    let replacements: i64 = pool
        .get()
        .await
        .unwrap()
        .query_one(
            "SELECT count(*) FROM dues_liabilities WHERE id = ANY($1::bigint[])",
            &[&split_approved
                .replacement_due_ids
                .iter()
                .filter_map(|id| id.parse::<i64>().ok())
                .collect::<Vec<_>>()],
        )
        .await
        .unwrap()
        .get(0);
    assert_eq!(replacements, 2);

    // A reload brings the corrections back; the cancelled liability stays out of memory.
    let reloaded = AppState::with_pool(Some(pool.clone()));
    {
        let mut inner = reloaded.inner.write().await;
        sitepulse_backend::db::load_all_from_db(&pool, &mut inner)
            .await
            .unwrap();
    }
    let listed = CorrectionService::new(&reloaded).list(&site).await;
    assert!(listed
        .iter()
        .any(|c| c.id == approved.id && c.status == REQUEST_APPROVED));
    assert!(listed
        .iter()
        .any(|c| c.id == credited.id && c.penalty_reversed == Some(Decimal::ZERO)));
    assert!(
        reloaded
            .inner
            .read()
            .await
            .dues
            .iter()
            .all(|due| due.id != to_cancel.id),
        "a cancelled liability is not loaded"
    );
    let tb = AccountingService::new(&reloaded)
        .trial_balance(&site, None, None)
        .await;
    assert!(tb.balanced);
}
