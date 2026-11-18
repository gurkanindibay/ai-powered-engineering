//! Resident account statement (hesap ekstresi) with debt aging, SPEC-007 R2.
//!
//! Each debtor (owner, tenant) sees only their own liabilities, advance and
//! receipts; site staff see both. Figures are as of today: the KMK 20 penalty is
//! accrued to date, amounts are what is still unpaid.

use chrono::NaiveDate;
use rust_decimal::Decimal;

use crate::models::{
    IndependentUnit, ResidentStatement, Role, StatementCorrection, StatementDebtor,
    StatementOpenItem, StatementReceipt, CORRECTION_REISSUE, LEDGER_KIND_COLLECTION,
    REQUEST_APPROVED,
};
use crate::services::dues_ledger::{self, DEBTOR_OWNER, DEBTOR_TENANT};
use crate::state::AppStateInner;

/// TBK 147/1: periodic payments are time-barred after five years.
const LIMITATION_DAYS: i64 = 5 * 365;

/// The debtor a signed-in resident is on `unit`, or `None` for site staff.
pub fn caller_debtor_role(
    claims: &crate::auth::Claims,
    unit: &IndependentUnit,
) -> Option<&'static str> {
    if claims.is_site_staff() {
        return None;
    }
    if unit
        .tenant_user_id
        .as_deref()
        .map(|t| crate::auth::same_id(t, &claims.sub))
        .unwrap_or(false)
    {
        return Some(DEBTOR_TENANT);
    }
    if unit
        .owner_user_id
        .as_deref()
        .map(|o| crate::auth::same_id(o, &claims.sub))
        .unwrap_or(false)
    {
        return Some(DEBTOR_OWNER);
    }
    // A household member: the tenant household when the unit is let, else the owner's.
    match claims.role {
        Role::HomeResident if unit.tenant_user_id.is_some() => Some(DEBTOR_TENANT),
        _ => Some(DEBTOR_OWNER),
    }
}

pub fn build_statement(
    inner: &AppStateInner,
    unit: &IndependentUnit,
    viewer: Option<&str>,
    today: NaiveDate,
) -> ResidentStatement {
    let calc = crate::services::DuesCalculationService::new();
    let name_of = |uid: &Option<String>| {
        uid.as_ref()
            .and_then(|id| inner.users.iter().find(|u| &u.id == id))
            .map(|u| u.full_name.clone())
    };
    let mut debtors = Vec::new();
    for debtor in [DEBTOR_OWNER, DEBTOR_TENANT] {
        if viewer.map(|v| v != debtor).unwrap_or(false) {
            continue;
        }
        let mut items: Vec<StatementOpenItem> = inner
            .dues
            .iter()
            .filter(|d| {
                crate::auth::same_id(&d.unit_id, &unit.id)
                    && d.status.is_collectable()
                    && d.debtor_type.as_str() == debtor
            })
            .map(|stored| {
                let d = calc.calculate_delay_penalty(stored.clone(), today);
                let principal = dues_ledger::outstanding_principal(&d);
                let penalty = dues_ledger::outstanding_penalty(&d);
                let days_overdue = (today - d.due_date).num_days().max(0);
                StatementOpenItem {
                    due_id: d.id.clone(),
                    period: d.period.clone(),
                    expense_type: d.expense_type.as_str().to_string(),
                    due_date: d.due_date,
                    days_overdue,
                    principal_outstanding: principal,
                    penalty_outstanding: penalty,
                    total_outstanding: principal + penalty,
                    operating_budget_id: inner.dues_budget_basis.get(&d.id).cloned(),
                    limitation_warning: days_overdue > LIMITATION_DAYS,
                }
            })
            .filter(|i| i.total_outstanding > Decimal::ZERO)
            .collect();
        items.sort_by_key(|i| i.due_date);
        // Pending exit settlements reserve part of the advance; the statement shows
        // only what the debtor can still use.
        let advance = inner.available_advance_of(&unit.id, debtor);
        let holder = if debtor == DEBTOR_TENANT {
            name_of(&unit.tenant_user_id)
        } else {
            name_of(&unit.owner_user_id)
        };
        if debtor == DEBTOR_TENANT && holder.is_none() && items.is_empty() && advance.is_zero() {
            continue;
        }
        let mut row = StatementDebtor {
            debtor_type: debtor.to_string(),
            name: holder.unwrap_or_else(|| {
                if debtor == DEBTOR_TENANT {
                    "Kiracı"
                } else {
                    "Kat Maliki"
                }
                .to_string()
            }),
            current_due: Decimal::ZERO,
            overdue_1_30_days: Decimal::ZERO,
            overdue_31_60_days: Decimal::ZERO,
            overdue_61_90_days: Decimal::ZERO,
            overdue_90_plus_days: Decimal::ZERO,
            principal_outstanding: Decimal::ZERO,
            penalty_outstanding: Decimal::ZERO,
            total_outstanding: Decimal::ZERO,
            advance_balance: advance,
            open_items: Vec::new(),
        };
        for i in &items {
            let bucket = match i.days_overdue {
                0 => &mut row.current_due,
                1..=30 => &mut row.overdue_1_30_days,
                31..=60 => &mut row.overdue_31_60_days,
                61..=90 => &mut row.overdue_61_90_days,
                _ => &mut row.overdue_90_plus_days,
            };
            *bucket += i.principal_outstanding;
            row.principal_outstanding += i.principal_outstanding;
            row.penalty_outstanding += i.penalty_outstanding;
            row.total_outstanding += i.total_outstanding;
        }
        row.open_items = items;
        debtors.push(row);
    }

    let mut receipts: Vec<StatementReceipt> = inner
        .payment_receipts
        .iter()
        .filter(|r| crate::auth::same_id(&r.unit_id, &unit.id))
        .filter(|r| match viewer {
            None => true,
            Some(v) => {
                r.payer_role.as_str() == v || r.on_behalf_of_role.map(|x| x.as_str()) == Some(v)
            }
        })
        .map(|r| StatementReceipt {
            receipt_number: r.receipt_number.clone(),
            receipt_type: r.receipt_type.clone(),
            issued_at: r.issued_at,
            payer_role: r.payer_role.as_str().to_string(),
            payment_channel: r.payment_channel.as_str().to_string(),
            total_amount: r.total_amount,
            reversed: r.receipt_type == LEDGER_KIND_COLLECTION
                && inner
                    .payment_receipts
                    .iter()
                    .any(|x| x.reverses_receipt_id == Some(r.id)),
        })
        .collect();
    receipts.sort_by_key(|r| std::cmp::Reverse(r.issued_at));
    receipts.truncate(50);

    let mut corrections: Vec<StatementCorrection> = inner
        .finance
        .corrections
        .iter()
        .filter(|c| {
            c.status == REQUEST_APPROVED
                && crate::auth::same_id(&c.unit_id, &unit.id)
                && viewer.is_none_or(|v| c.debtor_type == v)
        })
        .map(|c| StatementCorrection {
            correction_id: c.id,
            period: c.period.clone(),
            kind: c.kind.clone(),
            original_amount: c.principal_before.unwrap_or(c.amount),
            credited_amount: if c.kind == CORRECTION_REISSUE {
                c.principal_before.unwrap_or_default()
            } else {
                c.amount
            },
            reason: c.reason.clone(),
            decided_at: c.decided_at,
        })
        .collect();
    corrections.sort_by_key(|c| std::cmp::Reverse(c.correction_id));

    ResidentStatement {
        corrections,
        unit_id: unit.id.clone(),
        unit_label: inner.unit_label(&unit.block_id, unit.unit_number),
        as_of: today,
        debtors,
        receipts,
    }
}
