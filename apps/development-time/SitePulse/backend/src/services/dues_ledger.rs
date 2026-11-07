//! Dues ledger arithmetic shared by every payment path.
//!
//! A liability keeps what was *owed* (`principal_amount`, `delay_penalty`) separate
//! from what was *paid* (`paid_principal`, `paid_penalty`), matching the PostgreSQL
//! model. Payments never reduce the amount owed; they only increase the paid
//! amounts. `total_amount` is always the outstanding balance.

use rust_decimal::Decimal;

use crate::models::{DebtStatus, DuesLiability};

pub const DEBTOR_OWNER: &str = "OWNER";
pub const DEBTOR_TENANT: &str = "TENANT";
pub const EXPENSE_OPERATIONAL: &str = "OPERATIONAL_DUES";
pub const EXPENSE_CAPITAL: &str = "CAPITAL_DUES";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Settlement {
    pub principal: Decimal,
    pub penalty: Decimal,
}

impl Settlement {
    pub fn total(&self) -> Decimal {
        self.principal + self.penalty
    }
}

pub fn outstanding_principal(d: &DuesLiability) -> Decimal {
    (d.principal_amount - d.paid_principal).max(Decimal::ZERO)
}

pub fn outstanding_penalty(d: &DuesLiability) -> Decimal {
    (d.delay_penalty - d.paid_penalty).max(Decimal::ZERO)
}

pub fn outstanding(d: &DuesLiability) -> Decimal {
    outstanding_principal(d) + outstanding_penalty(d)
}

/// Recomputes `total_amount` (outstanding) and marks the liability paid when settled.
pub fn refresh(d: &mut DuesLiability) {
    d.total_amount = outstanding(d);
    if d.total_amount <= Decimal::ZERO {
        d.status = DebtStatus::Paid;
    }
}

/// Whether a payer in `payer_role` may settle this liability. Owners may pay
/// anything for their unit; a tenant may only pay tenant liabilities (capital
/// dues are owner-only under KMK and the V12 `chk_dues_capital_owner_only` rule).
pub fn payer_may_settle(d: &DuesLiability, payer_role: &str) -> bool {
    if payer_role.eq_ignore_ascii_case(DEBTOR_OWNER) {
        return true;
    }
    d.debtor_type.eq_ignore_ascii_case(DEBTOR_TENANT) && !d.expense_type.eq_ignore_ascii_case(EXPENSE_CAPITAL)
}

/// Pays up to `amount` against one liability: its penalty first, then principal.
pub fn settle(d: &mut DuesLiability, amount: Decimal) -> Settlement {
    let mut remaining = amount.max(Decimal::ZERO);
    let penalty = outstanding_penalty(d).min(remaining);
    remaining -= penalty;
    let principal = outstanding_principal(d).min(remaining);
    d.paid_penalty += penalty;
    d.paid_principal += principal;
    refresh(d);
    Settlement { principal, penalty }
}

/// One line of a waterfall allocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AllocationLine {
    pub due_index: usize,
    pub settlement: Settlement,
}

/// Four-tier waterfall over the given liabilities (oldest first):
/// tier 1 settles every outstanding penalty, tier 2 settles principal FIFO.
/// Returns the allocation lines (one per liability touched, both tiers merged)
/// and the unallocated remainder, which the caller credits to the advance ledger.
pub fn allocate_waterfall(
    dues: &mut [DuesLiability],
    candidate_indices: &[usize],
    amount: Decimal,
) -> (Vec<AllocationLine>, Decimal) {
    let mut order: Vec<usize> = candidate_indices.to_vec();
    order.sort_by_key(|&i| (dues[i].due_date, dues[i].id.clone()));
    let mut remaining = amount.max(Decimal::ZERO);
    let mut lines: Vec<AllocationLine> = Vec::new();

    let add = |lines: &mut Vec<AllocationLine>, idx: usize, s: Settlement| {
        if s.total() <= Decimal::ZERO {
            return;
        }
        if let Some(l) = lines.iter_mut().find(|l| l.due_index == idx) {
            l.settlement.principal += s.principal;
            l.settlement.penalty += s.penalty;
        } else {
            lines.push(AllocationLine { due_index: idx, settlement: s });
        }
    };

    // Tier 1: penalties.
    for &idx in &order {
        if remaining <= Decimal::ZERO {
            break;
        }
        let pay = outstanding_penalty(&dues[idx]).min(remaining);
        if pay > Decimal::ZERO {
            dues[idx].paid_penalty += pay;
            refresh(&mut dues[idx]);
            remaining -= pay;
            add(&mut lines, idx, Settlement { principal: Decimal::ZERO, penalty: pay });
        }
    }
    // Tier 2: principal, FIFO.
    for &idx in &order {
        if remaining <= Decimal::ZERO {
            break;
        }
        let pay = outstanding_principal(&dues[idx]).min(remaining);
        if pay > Decimal::ZERO {
            dues[idx].paid_principal += pay;
            refresh(&mut dues[idx]);
            remaining -= pay;
            add(&mut lines, idx, Settlement { principal: pay, penalty: Decimal::ZERO });
        }
    }
    (lines, remaining)
}

/// Indices of a unit's open liabilities that `payer_role` may settle.
pub fn open_dues_for(dues: &[DuesLiability], unit_matches: impl Fn(&str) -> bool, payer_role: &str) -> Vec<usize> {
    dues.iter()
        .enumerate()
        .filter(|(_, d)| d.status != DebtStatus::Paid && unit_matches(&d.unit_id) && payer_may_settle(d, payer_role))
        .map(|(i, _)| i)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    fn due(id: &str, principal: &str, penalty: &str, day: u32, debtor: &str, expense: &str) -> DuesLiability {
        let p = Decimal::from_str_exact(principal).unwrap();
        let pen = Decimal::from_str_exact(penalty).unwrap();
        DuesLiability {
            id: id.to_string(),
            unit_id: "14".to_string(),
            period: id.to_string(),
            principal_amount: p,
            delay_penalty: pen,
            total_amount: p + pen,
            due_date: NaiveDate::from_ymd_opt(2026, 9, day).unwrap(),
            status: DebtStatus::Overdue,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: debtor.to_string(),
            expense_type: expense.to_string(),
        }
    }

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap()
    }

    #[test]
    fn payment_records_paid_amounts_and_never_reduces_the_debt() {
        let mut dues = vec![due("a", "1400.00", "23.33", 15, DEBTOR_TENANT, EXPENSE_OPERATIONAL)];
        let (lines, rest) = allocate_waterfall(&mut dues, &[0], d("500.00"));
        assert_eq!(rest, Decimal::ZERO);
        assert_eq!(dues[0].principal_amount, d("1400.00"), "amount owed is preserved");
        assert_eq!(dues[0].paid_penalty, d("23.33"), "penalty is paid first and recorded");
        assert_eq!(dues[0].paid_principal, d("476.67"));
        assert_eq!(dues[0].total_amount, d("923.33"));
        assert_eq!(lines[0].settlement, Settlement { principal: d("476.67"), penalty: d("23.33") });
    }

    #[test]
    fn allocations_sum_to_the_payment_and_surplus_is_returned() {
        let mut dues = vec![
            due("b", "100.00", "5.00", 20, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
            due("a", "100.00", "10.00", 10, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
        ];
        let (lines, rest) = allocate_waterfall(&mut dues, &[0, 1], d("300.00"));
        let allocated: Decimal = lines.iter().map(|l| l.settlement.total()).sum();
        assert_eq!(allocated + rest, d("300.00"));
        assert_eq!(rest, d("85.00"));
        assert!(dues.iter().all(|x| x.status == DebtStatus::Paid));
        for x in &dues {
            assert!(x.paid_principal <= x.principal_amount && x.paid_penalty <= x.delay_penalty);
        }
    }

    #[test]
    fn tenant_cannot_settle_owner_capital_dues() {
        let dues = vec![
            due("cap", "500.00", "0.00", 1, DEBTOR_OWNER, EXPENSE_CAPITAL),
            due("op", "100.00", "0.00", 2, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
        ];
        assert_eq!(open_dues_for(&dues, |_| true, DEBTOR_TENANT), vec![1]);
        assert_eq!(open_dues_for(&dues, |_| true, DEBTOR_OWNER), vec![0, 1]);
    }

    #[test]
    fn settle_single_liability_penalty_first() {
        let mut x = due("a", "100.00", "10.00", 1, DEBTOR_TENANT, EXPENSE_OPERATIONAL);
        let s = settle(&mut x, d("15.00"));
        assert_eq!(s, Settlement { principal: d("5.00"), penalty: d("10.00") });
        assert_eq!(x.total_amount, d("95.00"));
    }
}
