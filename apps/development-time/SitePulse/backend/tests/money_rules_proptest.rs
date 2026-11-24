//! Property-based tests (`proptest`) for the six core SitePulse money rules:
//! 1. Allocation (`dues_ledger::allocate_waterfall`)
//! 2. Proration (`domain::occupancy_proration::split_monthly_dues`)
//! 3. Installments (`domain::installments::{schedule, evaluate}`)
//! 4. Heat share (`domain::heat_share::split`)
//! 5. Late fees (`DuesCalculationService::{calculate_delay_penalty, penalty_through}`)
//! 6. Capital apportionment (`domain::apportionment::apportion`)
//!
//! Invariants checked across all six:
//! - Totals preserved to the kuruş (scale <= 2, zero drift)
//! - No negative balances, shares, penalties, or surpluses
//! - Idempotency (re-running is a fixed point)
//! - Order-independence of totals (permuting inputs preserves totals)

use chrono::{Days, NaiveDate};
use proptest::prelude::*;
use rust_decimal::Decimal;
use sitepulse_backend::domain::apportionment::apportion;
use sitepulse_backend::domain::heat_share::{self, HeatInput};
use sitepulse_backend::domain::installments;
use sitepulse_backend::domain::occupancy_proration::{
    split_monthly_dues, OccupancySpan, ResponsibleParty,
};
use sitepulse_backend::models::{DebtStatus, DebtorType, DuesLiability, ExpenseType};
use sitepulse_backend::services::dues_ledger;
use sitepulse_backend::services::DuesCalculationService;

fn kurus(cents: i64) -> Decimal {
    Decimal::new(cents, 2)
}

fn make_due(
    id: &str,
    principal: Decimal,
    penalty: Decimal,
    due_date: NaiveDate,
    debtor_type: DebtorType,
    expense_type: ExpenseType,
) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: "unit-1".to_string(),
        period: id.to_string(),
        principal_amount: principal,
        delay_penalty: penalty,
        total_amount: principal + penalty,
        due_date,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type,
        expense_type,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    }
}

type DueSpec = (i64, i64, u32, bool, bool);

fn due_strategy() -> impl Strategy<Value = DueSpec> {
    (
        0i64..=500_000, // principal cents
        0i64..=50_000,  // penalty cents
        0u32..=365,     // days offset from base
        any::<bool>(),  // is_capital
        any::<bool>(),  // is_owner_debtor
    )
}

fn heat_unit_strategy() -> impl Strategy<Value = (u64, u32, u32)> {
    (
        1u64..=1000,   // area_weight
        0u32..=10_000, // prev reading (in 0.1 units)
        0u32..=10_000, // delta reading (in 0.1 units)
    )
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    // 1. Allocation waterfall invariants
    #[test]
    fn prop_allocation_invariants(
        raw_dues in prop::collection::vec(due_strategy(), 1..=8),
        payment_cents in 0i64..=2_000_000,
        owner_pays in any::<bool>(),
    ) {
        let base = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
        let role = if owner_pays { "OWNER" } else { "TENANT" };

        let build_dues = |specs: &[(usize, DueSpec)]| -> Vec<DuesLiability> {
            specs
                .iter()
                .map(|&(idx, (p, pen, day_off, capital, owner_debtor))| {
                    let expense = if capital {
                        ExpenseType::CapitalDues
                    } else {
                        ExpenseType::OperationalDues
                    };
                    let debtor = if capital || owner_debtor {
                        DebtorType::Owner
                    } else {
                        DebtorType::Tenant
                    };
                    make_due(
                        &format!("due-{idx:03}"),
                        kurus(p),
                        kurus(pen),
                        base + Days::new(u64::from(day_off)),
                        debtor,
                        expense,
                    )
                })
                .collect()
        };

        let indexed: Vec<(usize, _)> = raw_dues.iter().copied().enumerate().collect();
        let mut dues = build_dues(&indexed);
        let payment = kurus(payment_cents);

        let candidates = dues_ledger::open_dues_for(&dues, |_| true, role);
        let (lines, surplus) = dues_ledger::allocate_waterfall(&mut dues, &candidates, payment);

        // Totals to the kurus
        let allocated_principal: Decimal = lines.iter().map(|l| l.settlement.principal).sum();
        let allocated_penalty: Decimal = lines.iter().map(|l| l.settlement.penalty).sum();
        let allocated = allocated_principal + allocated_penalty;
        prop_assert_eq!(allocated + surplus, payment);
        prop_assert!(surplus >= Decimal::ZERO);
        prop_assert!(surplus.normalize().scale() <= 2);

        // No negatives, paid <= owed, tenant never pays capital
        for d in &dues {
            prop_assert!(d.paid_principal >= Decimal::ZERO);
            prop_assert!(d.paid_penalty >= Decimal::ZERO);
            prop_assert!(d.total_amount >= Decimal::ZERO);
            prop_assert!(d.paid_principal <= d.principal_amount);
            prop_assert!(d.paid_penalty <= d.delay_penalty);
            prop_assert_eq!(
                d.total_amount,
                d.principal_amount + d.delay_penalty - d.paid_principal - d.paid_penalty
            );
            if !owner_pays && d.expense_type == ExpenseType::CapitalDues {
                prop_assert_eq!(d.paid_principal + d.paid_penalty, Decimal::ZERO);
            }
        }

        // Idempotent with zero additional payment
        let snapshot = dues.clone();
        let candidates_after = dues_ledger::open_dues_for(&dues, |_| true, role);
        let (lines2, surplus2) = dues_ledger::allocate_waterfall(&mut dues, &candidates_after, Decimal::ZERO);
        prop_assert!(lines2.is_empty());
        prop_assert_eq!(surplus2, Decimal::ZERO);
        for (d, s) in dues.iter().zip(snapshot.iter()) {
            prop_assert_eq!(d.paid_principal, s.paid_principal);
            prop_assert_eq!(d.paid_penalty, s.paid_penalty);
            prop_assert_eq!(d.total_amount, s.total_amount);
            prop_assert_eq!(format!("{:?}", d.status), format!("{:?}", s.status));
        }

        // Order-independent totals: reversed input produces same surplus & total allocated
        let mut rev_indexed = indexed;
        rev_indexed.reverse();
        let mut rev_dues = build_dues(&rev_indexed);
        let rev_candidates = dues_ledger::open_dues_for(&rev_dues, |_| true, role);
        let (rev_lines, rev_surplus) =
            dues_ledger::allocate_waterfall(&mut rev_dues, &rev_candidates, payment);
        let rev_allocated: Decimal = rev_lines.iter().map(|l| l.settlement.total()).sum();
        prop_assert_eq!(rev_surplus, surplus);
        prop_assert_eq!(rev_allocated, allocated);
    }

    // 2. Occupancy proration invariants
    #[test]
    fn prop_proration_invariants(
        monthly_cents in 0i64..=1_000_000,
        month in 1u32..=12,
        tenant_start_day in 1u32..=28,
        tenant_len_days in 1u64..=20,
        proration_enabled in any::<bool>(),
    ) {
        let period_start = NaiveDate::from_ymd_opt(2026, month, 1).unwrap();
        let start = NaiveDate::from_ymd_opt(2026, month, tenant_start_day).unwrap();
        let end = start + Days::new(tenant_len_days);
        let spans = vec![OccupancySpan {
            party: ResponsibleParty::Tenant,
            starts_on: start,
            ends_before: Some(end),
        }];
        let monthly = kurus(monthly_cents);
        let shares = split_monthly_dues(
            monthly,
            period_start,
            None,
            &spans,
            proration_enabled,
            period_start,
        )
        .unwrap();

        // Totals to the kurus
        let total: Decimal = shares.iter().map(|s| s.amount).sum();
        prop_assert_eq!(total, monthly);
        for s in &shares {
            prop_assert!(s.amount >= Decimal::ZERO);
            prop_assert!(s.amount.normalize().scale() <= 2);
        }

        // Idempotent
        let again = split_monthly_dues(
            monthly,
            period_start,
            None,
            &spans,
            proration_enabled,
            period_start,
        )
        .unwrap();
        prop_assert_eq!(shares, again);

        // Order-independent totals with non-overlapping owner/tenant spans
        let spans_multi = vec![
            OccupancySpan {
                party: ResponsibleParty::Tenant,
                starts_on: start,
                ends_before: Some(end),
            },
            OccupancySpan {
                party: ResponsibleParty::Owner,
                starts_on: period_start,
                ends_before: Some(start),
            },
        ];
        let mut spans_rev = spans_multi.clone();
        spans_rev.reverse();
        let s1 = split_monthly_dues(monthly, period_start, None, &spans_multi, proration_enabled, period_start).unwrap();
        let s2 = split_monthly_dues(monthly, period_start, None, &spans_rev, proration_enabled, period_start).unwrap();
        prop_assert_eq!(s1.iter().map(|s| s.amount).sum::<Decimal>(), monthly);
        prop_assert_eq!(s2.iter().map(|s| s.amount).sum::<Decimal>(), monthly);
        prop_assert_eq!(s1, s2);
    }

    // 3. Installments invariants
    #[test]
    fn prop_installments_invariants(
        total_cents in 1i64..=5_000_000,
        count in 2u32..=36,
        paid_cents in 0i64..=6_000_000,
        eval_days in 0u64..=1200,
        grace_days in 0u32..=30,
    ) {
        let total = kurus(total_cents);
        let paid = kurus(paid_cents);
        let first_due = NaiveDate::from_ymd_opt(2026, 1, 15).unwrap();
        let as_of = first_due + Days::new(eval_days);

        let sched = installments::schedule(total, count, first_due).unwrap();
        prop_assert_eq!(sched.len(), count as usize);
        prop_assert_eq!(sched.iter().map(|i| i.amount).sum::<Decimal>(), total);
        for inst in &sched {
            prop_assert!(inst.amount >= Decimal::ZERO);
            prop_assert!(inst.amount.normalize().scale() <= 2);
        }

        // Idempotent schedule
        let sched2 = installments::schedule(total, count, first_due).unwrap();
        prop_assert_eq!(&sched, &sched2);

        // Evaluate invariants
        let progress = installments::evaluate(&sched, paid, as_of, grace_days);
        let covered_sum: Decimal = progress.installments.iter().map(|i| i.covered).sum();
        prop_assert_eq!(covered_sum, paid.min(total));
        prop_assert_eq!(progress.completed, paid >= total);
        for row in &progress.installments {
            prop_assert!(row.covered >= Decimal::ZERO);
            prop_assert!(row.covered <= row.amount);
        }

        // Idempotent evaluate
        let progress2 = installments::evaluate(&sched, paid, as_of, grace_days);
        prop_assert_eq!(progress, progress2);
    }

    // 4. Heat share invariants
    #[test]
    fn prop_heat_share_invariants(
        total_cents in 0i64..=5_000_000,
        consumption_pct in 0i64..=100,
        raw_units in prop::collection::vec(heat_unit_strategy(), 1..=10),
    ) {
        let total = kurus(total_cents);
        let pct = Decimal::from(consumption_pct);
        let units: Vec<HeatInput> = raw_units
            .iter()
            .map(|&(area, prev, delta)| HeatInput {
                area_weight: area,
                previous_reading: Decimal::new(i64::from(prev), 1),
                current_reading: Decimal::new(i64::from(prev + delta), 1),
            })
            .collect();

        let shares = heat_share::split(total, pct, &units).unwrap();
        prop_assert_eq!(shares.len(), units.len());

        // Totals to the kurus, no negatives
        let sum_total: Decimal = shares.iter().map(heat_share::HeatShare::total).sum();
        prop_assert_eq!(sum_total, total);
        for s in &shares {
            prop_assert!(s.fixed >= Decimal::ZERO);
            prop_assert!(s.consumption >= Decimal::ZERO);
            prop_assert!(s.fixed.normalize().scale() <= 2);
            prop_assert!(s.consumption.normalize().scale() <= 2);
        }

        // Idempotent
        let again = heat_share::split(total, pct, &units).unwrap();
        prop_assert_eq!(&shares, &again);

        // Order-independent totals
        let mut rev_units = units;
        rev_units.reverse();
        let rev_shares = heat_share::split(total, pct, &rev_units).unwrap();
        prop_assert_eq!(
            rev_shares.iter().map(heat_share::HeatShare::total).sum::<Decimal>(),
            total
        );
        prop_assert_eq!(
            rev_shares.iter().map(|s| s.fixed).sum::<Decimal>(),
            shares.iter().map(|s| s.fixed).sum::<Decimal>()
        );
        prop_assert_eq!(
            rev_shares.iter().map(|s| s.consumption).sum::<Decimal>(),
            shares.iter().map(|s| s.consumption).sum::<Decimal>()
        );
    }

    // 5. Late fees invariants
    #[test]
    fn prop_late_fees_invariants(
        principal_cents in 0i64..=2_000_000,
        days_offset in -30i64..=180,
        payments in prop::collection::vec((0u64..=120, 1i64..=100_000), 0..=5),
    ) {
        let svc = DuesCalculationService::new();
        let due_date = NaiveDate::from_ymd_opt(2026, 3, 1).unwrap();
        let eval_date = if days_offset >= 0 {
            due_date + Days::new(days_offset as u64)
        } else {
            due_date - Days::new((-days_offset) as u64)
        };
        let principal = kurus(principal_cents);
        let due = make_due(
            "late-1",
            principal,
            Decimal::ZERO,
            due_date,
            DebtorType::Tenant,
            ExpenseType::OperationalDues,
        );

        let r1 = svc.calculate_delay_penalty(due, eval_date);
        prop_assert!(r1.delay_penalty >= Decimal::ZERO);
        prop_assert!(r1.total_amount >= Decimal::ZERO);
        prop_assert!(r1.delay_penalty.normalize().scale() <= 2);
        prop_assert_eq!(r1.total_amount, principal + r1.delay_penalty);

        // Idempotent on same date
        let r2 = svc.calculate_delay_penalty(r1.clone(), eval_date);
        prop_assert_eq!(r2.delay_penalty, r1.delay_penalty);
        prop_assert_eq!(r2.total_amount, r1.total_amount);

        // Order-independent payment history for penalty_through
        let pay_list: Vec<(NaiveDate, Decimal)> = payments
            .iter()
            .map(|&(d_off, cents)| (due_date + Days::new(d_off), kurus(cents)))
            .collect();
        let mut rev_pay_list = pay_list.clone();
        rev_pay_list.reverse();
        let through = due_date + Days::new(150);
        let p1 = svc.penalty_through(principal, due_date, through, &pay_list);
        let p2 = svc.penalty_through(principal, due_date, through, &rev_pay_list);
        prop_assert_eq!(p1, p2);
        prop_assert!(p1 >= Decimal::ZERO);
        prop_assert!(p1.normalize().scale() <= 2);
    }

    // 6. Capital apportionment invariants
    #[test]
    fn prop_capital_apportionment_invariants(
        total_cents in 0i64..=10_000_000,
        weights in prop::collection::vec(0u64..=10_000, 1..=20),
    ) {
        let total = kurus(total_cents);
        let shares = apportion(total, &weights).unwrap();
        prop_assert_eq!(shares.len(), weights.len());

        // Totals to the kurus, no negatives
        prop_assert_eq!(shares.iter().copied().sum::<Decimal>(), total);
        for &s in &shares {
            prop_assert!(s >= Decimal::ZERO);
            prop_assert!(s.normalize().scale() <= 2);
        }

        // Idempotent
        let again = apportion(total, &weights).unwrap();
        prop_assert_eq!(&shares, &again);

        // Order-independent totals
        let mut rev_weights = weights;
        rev_weights.reverse();
        let rev_shares = apportion(total, &rev_weights).unwrap();
        prop_assert_eq!(rev_shares.iter().copied().sum::<Decimal>(), total);
    }
}
