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

/// Liabilities among `candidates` that a payment designates (TBK 101).
///
/// An explicit designation names due ids, periods (case-insensitive) and/or an
/// expense type; a liability matches when it satisfies every criterion given.
/// Without one, `description_hint` (bank narrative) designates the liabilities
/// whose period text it contains, e.g. "Eylül 2026 Aidatı".
pub fn designated_dues(
    dues: &[DuesLiability],
    candidates: &[usize],
    designation: Option<&crate::models::PaymentDesignation>,
    description_hint: Option<&str>,
) -> Vec<usize> {
    if let Some(des) = designation.filter(|d| !d.is_empty()) {
        return candidates
            .iter()
            .copied()
            .filter(|&i| {
                let d = &dues[i];
                (des.due_ids.is_empty() || des.due_ids.iter().any(|id| crate::auth::same_id(id, &d.id)))
                    && (des.periods.is_empty() || des.periods.iter().any(|p| fold_turkish(p.trim()) == fold_turkish(d.period.trim())))
                    && des.expense_type.as_deref().is_none_or(|e| e.eq_ignore_ascii_case(&d.expense_type))
            })
            .collect();
    }
    let Some(hint) = description_hint.map(fold_turkish).filter(|h| !h.trim().is_empty()) else {
        return Vec::new();
    };
    candidates
        .iter()
        .copied()
        .filter(|&i| {
            let period = fold_turkish(dues[i].period.trim());
            !period.is_empty() && hint.contains(&period)
        })
        .collect()
}

/// Case- and diacritic-insensitive form of Turkish text for matching bank
/// narratives, which arrive upper-cased and often ASCII-only ("EKIM 2026",
/// "EYLUL 2026"): lower-cases and maps ı/i̇/ş/ğ/ü/ö/ç to their ASCII letters.
pub fn fold_turkish(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| *c != '\u{0307}')
        .map(|c| match c {
            'ı' => 'i',
            'ş' => 's',
            'ğ' => 'g',
            'ü' => 'u',
            'ö' => 'o',
            'ç' => 'c',
            other => other,
        })
        .collect()
}

/// TBK 101–102 allocation: the designated liabilities first (each with the TBK
/// 100 penalty-first waterfall), then the payer's other candidates oldest first.
/// Returns the merged allocation lines and the unallocated remainder.
pub fn allocate_with_designation(
    dues: &mut [DuesLiability],
    candidates: &[usize],
    designated: &[usize],
    amount: Decimal,
) -> (Vec<AllocationLine>, Decimal) {
    let first: Vec<usize> = candidates.iter().copied().filter(|i| designated.contains(i)).collect();
    let rest: Vec<usize> = candidates.iter().copied().filter(|i| !designated.contains(i)).collect();
    let (mut lines, remainder) = allocate_waterfall(dues, &first, amount);
    let (more, remainder) = allocate_waterfall(dues, &rest, remainder);
    lines.extend(more);
    (lines, remainder)
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
            penalty_accrued_through: None,
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

    fn two_months() -> Vec<DuesLiability> {
        vec![
            due("Ağustos 2026", "1400.00", "0.00", 1, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
            due("Eylül 2026", "1400.00", "0.00", 2, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
        ]
    }

    #[test]
    fn designated_period_is_settled_before_older_dues() {
        let mut dues = two_months();
        let des = crate::models::PaymentDesignation { periods: vec!["eylül 2026".to_string()], ..Default::default() };
        let designated = designated_dues(&dues, &[0, 1], Some(&des), None);
        assert_eq!(designated, vec![1]);
        let (lines, rest) = allocate_with_designation(&mut dues, &[0, 1], &designated, d("1400.00"));
        assert_eq!(rest, Decimal::ZERO);
        assert_eq!(dues[1].status, DebtStatus::Paid, "the designated (newer) month is paid");
        assert_ne!(dues[0].status, DebtStatus::Paid, "the older month stays open");
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn designation_remainder_falls_back_to_oldest_first() {
        let mut dues = two_months();
        let des = crate::models::PaymentDesignation { due_ids: vec!["Eylül 2026".to_string()], ..Default::default() };
        let designated = designated_dues(&dues, &[0, 1], Some(&des), None);
        let (lines, rest) = allocate_with_designation(&mut dues, &[0, 1], &designated, d("2000.00"));
        assert_eq!(rest, Decimal::ZERO);
        assert_eq!(dues[1].status, DebtStatus::Paid);
        assert_eq!(dues[0].paid_principal, d("600.00"));
        assert_eq!(lines[0].due_index, 1, "designated line first");
    }

    #[test]
    fn bank_narrative_designates_the_named_period() {
        let dues = two_months();
        assert_eq!(designated_dues(&dues, &[0, 1], None, Some("EYLÜL 2026 AİDATI FAST")), vec![1]);
        assert_eq!(designated_dues(&dues, &[0, 1], None, Some("A BLOK D14 EYLUL 2026")), vec![1], "ASCII-only narrative");
        assert_eq!(designated_dues(&dues, &[0, 1], None, Some("Eylül 2026 Aidatı FAST Ödemesi")), vec![1]);
        assert_eq!(designated_dues(&dues, &[0, 1], None, Some("aidat")), Vec::<usize>::new());
        assert_eq!(designated_dues(&dues, &[0, 1], None, None), Vec::<usize>::new());
    }

    #[test]
    fn turkish_folding_matches_upper_and_ascii_forms() {
        assert_eq!(fold_turkish("EKİM 2026"), fold_turkish("Ekim 2026"));
        assert_eq!(fold_turkish("EKIM 2026"), fold_turkish("Ekim 2026"));
        assert_eq!(fold_turkish("ŞUBAT"), "subat");
        assert_eq!(fold_turkish("Ağustos"), "agustos");
    }

    #[test]
    fn designation_never_lets_a_tenant_pay_owner_capital() {
        let dues = vec![
            due("cap", "500.00", "0.00", 1, DEBTOR_OWNER, EXPENSE_CAPITAL),
            due("op", "100.00", "0.00", 2, DEBTOR_TENANT, EXPENSE_OPERATIONAL),
        ];
        let candidates = open_dues_for(&dues, |_| true, DEBTOR_TENANT);
        let des = crate::models::PaymentDesignation { due_ids: vec!["cap".to_string()], ..Default::default() };
        assert!(designated_dues(&dues, &candidates, Some(&des), None).is_empty());
    }
}
