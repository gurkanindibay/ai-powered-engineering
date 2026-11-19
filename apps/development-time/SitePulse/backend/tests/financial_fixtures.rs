//! Runs the shared financial fixture (harness/fixtures/financial_cases.json)
//! against the real backend services, plus property checks over random inputs.
//! The same fixture is run against the Flutter use case, so both
//! implementations are held to one set of expected numbers.

use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::Deserialize;
use sitepulse_backend::models::{DebtStatus, DebtorType, DuesLiability, ExpenseType};
use sitepulse_backend::services::dues_ledger;
use sitepulse_backend::services::DuesCalculationService;

#[derive(Deserialize)]
struct Fixture {
    penalty_cases: Vec<PenaltyCase>,
    allocation_cases: Vec<AllocationCase>,
}

#[derive(Deserialize)]
struct PenaltyCase {
    name: String,
    principal: Decimal,
    due_date: NaiveDate,
    evaluation_date: NaiveDate,
    expected_penalty: Decimal,
    expected_total: Decimal,
    expected_status: String,
}

#[derive(Deserialize)]
struct DueSpec {
    id: String,
    principal: Decimal,
    penalty: Decimal,
    due_date: NaiveDate,
    debtor_type: String,
    expense_type: String,
}

#[derive(Deserialize)]
struct Line {
    due_id: String,
    principal: Decimal,
    penalty: Decimal,
}

#[derive(Deserialize)]
struct AllocationCase {
    name: String,
    payer_role: String,
    payment: Decimal,
    dues: Vec<DueSpec>,
    expected_lines: Vec<Line>,
    expected_advance: Decimal,
    expected_outstanding: std::collections::HashMap<String, Decimal>,
}

fn fixture() -> Fixture {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../harness/fixtures/financial_cases.json");
    serde_json::from_str(&std::fs::read_to_string(&path).expect("fixture file"))
        .expect("valid fixture")
}

fn liability(
    id: &str,
    principal: Decimal,
    penalty: Decimal,
    due_date: NaiveDate,
    debtor: &str,
    expense: &str,
) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: "1".to_string(),
        period: id.to_string(),
        principal_amount: principal,
        delay_penalty: penalty,
        total_amount: principal + penalty,
        due_date,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::from_str_loose(debtor),
        expense_type: ExpenseType::from_str_loose(expense),
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
    }
}

#[test]
fn penalty_cases_match_the_fixture() {
    let svc = DuesCalculationService::new();
    for c in fixture().penalty_cases {
        let d = liability(
            "x",
            c.principal,
            Decimal::ZERO,
            c.due_date,
            "TENANT",
            "OPERATIONAL_DUES",
        );
        let r = svc.calculate_delay_penalty(d, c.evaluation_date);
        assert_eq!(r.delay_penalty, c.expected_penalty, "{}: penalty", c.name);
        assert_eq!(r.total_amount, c.expected_total, "{}: total", c.name);
        assert_eq!(
            format!("{:?}", r.status).to_uppercase(),
            c.expected_status,
            "{}: status",
            c.name
        );
    }
}

#[test]
fn allocation_cases_match_the_fixture() {
    for c in fixture().allocation_cases {
        let mut dues: Vec<DuesLiability> = c
            .dues
            .iter()
            .map(|d| {
                liability(
                    &d.id,
                    d.principal,
                    d.penalty,
                    d.due_date,
                    &d.debtor_type,
                    &d.expense_type,
                )
            })
            .collect();
        let candidates = dues_ledger::open_dues_for(&dues, |_| true, &c.payer_role);
        let (lines, advance) = dues_ledger::allocate_waterfall(&mut dues, &candidates, c.payment);
        let mut got: Vec<(String, Decimal, Decimal)> = lines
            .iter()
            .map(|l| {
                (
                    dues[l.due_index].id.clone(),
                    l.settlement.principal,
                    l.settlement.penalty,
                )
            })
            .collect();
        got.sort();
        let mut want: Vec<(String, Decimal, Decimal)> = c
            .expected_lines
            .iter()
            .map(|l| (l.due_id.clone(), l.principal, l.penalty))
            .collect();
        want.sort();
        assert_eq!(got, want, "{}: allocation lines", c.name);
        assert_eq!(advance, c.expected_advance, "{}: advance", c.name);
        for d in &dues {
            assert_eq!(
                Some(&d.total_amount),
                c.expected_outstanding.get(&d.id),
                "{}: outstanding of {}",
                c.name,
                d.id
            );
        }
    }
}

/// Small deterministic PRNG so property runs are reproducible without extra crates.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn cents(&mut self, max: u64) -> Decimal {
        Decimal::new((self.next() % max) as i64, 2)
    }
}

#[test]
fn waterfall_properties_hold_for_random_inputs() {
    let mut rng = Lcg(0x5EED);
    let base = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    for case in 0..2000 {
        let n = 1 + (rng.next() % 5) as usize;
        let mut dues: Vec<DuesLiability> = (0..n)
            .map(|i| {
                let capital = rng.next().is_multiple_of(4);
                liability(
                    &format!("d{}", i),
                    rng.cents(500_000),
                    rng.cents(20_000),
                    base + chrono::Days::new(rng.next() % 300),
                    if capital || rng.next().is_multiple_of(2) {
                        "OWNER"
                    } else {
                        "TENANT"
                    },
                    if capital {
                        "CAPITAL_DUES"
                    } else {
                        "OPERATIONAL_DUES"
                    },
                )
            })
            .collect();
        let owed: Vec<(Decimal, Decimal)> = dues
            .iter()
            .map(|d| (d.principal_amount, d.delay_penalty))
            .collect();
        let role = if rng.next().is_multiple_of(2) {
            "OWNER"
        } else {
            "TENANT"
        };
        let payment = rng.cents(1_000_000) + Decimal::new(1, 2);
        let candidates = dues_ledger::open_dues_for(&dues, |_| true, role);
        let (lines, surplus) = dues_ledger::allocate_waterfall(&mut dues, &candidates, payment);

        let allocated: Decimal = lines.iter().map(|l| l.settlement.total()).sum();
        assert_eq!(
            allocated + surplus,
            payment,
            "case {}: allocations + surplus == payment",
            case
        );
        assert!(surplus >= Decimal::ZERO);
        for (d, (principal, penalty)) in dues.iter().zip(owed) {
            assert_eq!(
                d.principal_amount, principal,
                "case {}: owed principal is never reduced",
                case
            );
            assert_eq!(
                d.delay_penalty, penalty,
                "case {}: owed penalty is never reduced",
                case
            );
            assert!(
                d.paid_principal >= Decimal::ZERO && d.paid_principal <= d.principal_amount,
                "case {}: paid <= owed",
                case
            );
            assert!(
                d.paid_penalty >= Decimal::ZERO && d.paid_penalty <= d.delay_penalty,
                "case {}: paid <= owed",
                case
            );
            assert_eq!(
                d.total_amount,
                principal + penalty - d.paid_principal - d.paid_penalty,
                "case {}: outstanding",
                case
            );
            if role == "TENANT" && d.expense_type == ExpenseType::CapitalDues {
                assert_eq!(
                    d.paid_principal + d.paid_penalty,
                    Decimal::ZERO,
                    "case {}: tenant never pays capital",
                    case
                );
            }
        }
        if surplus > Decimal::ZERO {
            assert!(
                candidates
                    .iter()
                    .all(|&i| dues[i].total_amount == Decimal::ZERO),
                "case {}: surplus only when eligible dues are settled",
                case
            );
        }
    }
}

// covers: SC-01-01-01
#[test]
fn penalty_keeps_kurus_precision_and_does_not_drift_across_recalculations() {
    let svc = DuesCalculationService::new();
    let d = |s: &str| Decimal::from_str_exact(s).unwrap();
    let mut running = DuesLiability {
        id: "1".to_string(),
        unit_id: "14".to_string(),
        period: "Eylül 2026".to_string(),
        principal_amount: d("1450.00"),
        delay_penalty: Decimal::ZERO,
        total_amount: Decimal::ZERO,
        due_date: NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Tenant,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
    };
    for day in 16..=28 {
        let evaluation = NaiveDate::from_ymd_opt(2026, 9, day).unwrap();
        running = svc.calculate_delay_penalty(running, evaluation);
        // Recalculating the same day is a fixed point.
        let again = svc.calculate_delay_penalty(running.clone(), evaluation);
        assert_eq!(again.delay_penalty, running.delay_penalty);
        assert_eq!(again.total_amount, running.total_amount);
        // Kurus precision, and the total is exactly principal + penalty.
        assert!(running.delay_penalty.normalize().scale() <= 2);
        assert!(running.total_amount.normalize().scale() <= 2);
        assert_eq!(
            running.total_amount,
            running.principal_amount + running.delay_penalty
        );
    }
    // 1450.00 * 5% / 30 = 2.4166.. -> 2.42 per daily segment, summed exactly.
    assert_eq!(running.delay_penalty, d("2.42") * Decimal::from(13));
}
