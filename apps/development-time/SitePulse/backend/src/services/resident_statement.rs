//! Resident account statement (hesap ekstresi) with debt aging, SPEC-007 R2.
//!
//! Each debtor (owner, tenant) sees only their own liabilities, advance and
//! receipts; site staff see both. Figures are as of today: the KMK 20 penalty is
//! accrued to date, amounts are what is still unpaid.

use chrono::NaiveDate;
use rust_decimal::Decimal;

use crate::models::{
    IndependentUnit, ResidentStatement, Role, StatementCorrection, StatementDebtor,
    StatementOpenItem, StatementReceipt, CORRECTION_REISSUE, CORRECTION_SPLIT_REISSUE,
    LEDGER_KIND_COLLECTION, REQUEST_APPROVED,
};
use crate::services::dues_ledger::{self, DEBTOR_OWNER, DEBTOR_TENANT};
use crate::state::AppStateInner;

/// TBK 147/1: periodic payments are time-barred after five years.
const LIMITATION_DAYS: i64 = 5 * 365;

/// The debtor a signed-in resident is on `unit`, or `None` for site staff.
pub fn caller_debtor_role(
    claims: &crate::auth::Claims,
    unit: &IndependentUnit,
    viewer_person_id: Option<i64>,
) -> Option<&'static str> {
    if claims.is_site_staff() {
        return None;
    }
    // Units reference parties as `person-<id>`; a durable person id beats the login id.
    if let Some(person_ref) = viewer_person_id.map(|id| format!("person-{id}")) {
        if unit.tenant_user_id.as_deref() == Some(person_ref.as_str()) {
            return Some(DEBTOR_TENANT);
        }
        if unit.owner_user_id.as_deref() == Some(person_ref.as_str()) {
            return Some(DEBTOR_OWNER);
        }
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
    let viewer_person_id = viewer.and_then(|debtor| {
        let user_id = if debtor == DEBTOR_TENANT {
            unit.tenant_user_id.as_ref()
        } else {
            unit.owner_user_id.as_ref()
        }?;
        inner
            .users
            .iter()
            .find(|user| &user.id == user_id)
            .and_then(|user| user.person_id)
            .or_else(|| {
                user_id
                    .strip_prefix("person-")
                    .and_then(|p| p.parse::<i64>().ok())
            })
    });
    build_statement_for_person(inner, unit, viewer, viewer_person_id, today)
}

fn create_statement_debtor(
    debtor_type: &str,
    name: String,
    liable_person_id: Option<i64>,
    is_former: bool,
    advance_balance: Decimal,
    items: Vec<StatementOpenItem>,
    jointly_liable_open_items: Vec<StatementOpenItem>,
) -> StatementDebtor {
    let mut row = StatementDebtor {
        debtor_type: debtor_type.to_string(),
        name,
        liable_person_id,
        is_former,
        current_due: Decimal::ZERO,
        overdue_1_30_days: Decimal::ZERO,
        overdue_31_60_days: Decimal::ZERO,
        overdue_61_90_days: Decimal::ZERO,
        overdue_90_plus_days: Decimal::ZERO,
        principal_outstanding: Decimal::ZERO,
        penalty_outstanding: Decimal::ZERO,
        total_outstanding: Decimal::ZERO,
        advance_balance,
        open_items: Vec::new(),
        jointly_liable_total: jointly_liable_open_items
            .iter()
            .map(|item| item.total_outstanding)
            .sum(),
        jointly_liable_open_items,
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
    row
}

pub fn build_statement_for_person(
    inner: &AppStateInner,
    unit: &IndependentUnit,
    viewer: Option<&str>,
    viewer_person_id: Option<i64>,
    today: NaiveDate,
) -> ResidentStatement {
    let calc = crate::services::DuesCalculationService::new();
    let name_of = |uid: &Option<String>| {
        uid.as_ref()
            .and_then(|id| inner.users.iter().find(|u| &u.id == id))
            .map(|u| u.full_name.clone())
    };
    let name_of_person = |pid: i64| -> Option<String> {
        inner
            .users
            .iter()
            .find(|u| u.person_id == Some(pid) || u.id == format!("person-{pid}"))
            .map(|u| u.full_name.clone())
            .or_else(|| {
                inner
                    .unit_occupancies
                    .values()
                    .flat_map(|items| items.iter())
                    .find(|occ| occ.person_id == pid)
                    .map(|occ| occ.person_name.clone())
            })
    };
    let joint_items_for_owner = |owner_pid: i64| -> Vec<StatementOpenItem> {
        if viewer == Some(DEBTOR_TENANT) {
            return Vec::new();
        }
        let mut joint_items: Vec<StatementOpenItem> = inner
            .dues
            .iter()
            .filter(|due| {
                crate::auth::same_id(&due.unit_id, &unit.id)
                    && due.status.is_collectable()
                    && due.debtor_type.as_str() == DEBTOR_TENANT
                    && inner
                        .joint_liability_owners
                        .get(&due.id)
                        .is_some_and(|owners| {
                            owners.iter().any(|owner| owner.person_id == owner_pid)
                        })
            })
            .map(|stored| {
                let due = calc.calculate_delay_penalty(stored.clone(), today);
                let principal = dues_ledger::outstanding_principal(&due);
                let penalty = dues_ledger::outstanding_penalty(&due);
                let effective_due_date = due.fee_due_date();
                let days_overdue = (today - effective_due_date).num_days().max(0);
                StatementOpenItem {
                    due_id: due.id.clone(),
                    period: due.period.clone(),
                    expense_type: due.expense_type.as_str().to_string(),
                    due_date: due.due_date,
                    effective_due_date,
                    charge_created_late: effective_due_date != due.due_date,
                    days_overdue,
                    principal_outstanding: principal,
                    penalty_outstanding: penalty,
                    total_outstanding: principal + penalty,
                    operating_budget_id: inner.dues_budget_basis.get(&due.id).cloned(),
                    limitation_warning: days_overdue > LIMITATION_DAYS,
                }
            })
            .filter(|item| item.total_outstanding > Decimal::ZERO)
            .collect();
        joint_items.sort_by_key(|item| item.due_date);
        joint_items
    };

    let mut debtors = Vec::new();
    for debtor in [DEBTOR_OWNER, DEBTOR_TENANT] {
        if viewer.map(|v| v != debtor).unwrap_or(false) {
            continue;
        }

        let current_user_id = if debtor == DEBTOR_TENANT {
            unit.tenant_user_id.as_ref()
        } else {
            unit.owner_user_id.as_ref()
        };
        let current_person_id = current_user_id.and_then(|id| {
            inner
                .users
                .iter()
                .find(|u| &u.id == id)
                .and_then(|u| u.person_id)
                .or_else(|| {
                    id.strip_prefix("person-")
                        .and_then(|p| p.parse::<i64>().ok())
                })
        });
        // A holder without a login has no user row; their occupancy history still names them.
        let current_holder_name = current_person_id
            .and_then(name_of_person)
            .or_else(|| name_of(&current_user_id.cloned()));

        // Collect all open items for this role, grouped by liable person.
        let mut items_by_person: std::collections::BTreeMap<Option<i64>, Vec<StatementOpenItem>> =
            std::collections::BTreeMap::new();
        for stored in inner.dues.iter().filter(|d| {
            crate::auth::same_id(&d.unit_id, &unit.id)
                && d.status.is_collectable()
                && d.debtor_type.as_str() == debtor
        }) {
            let d = calc.calculate_delay_penalty(stored.clone(), today);
            let principal = dues_ledger::outstanding_principal(&d);
            let penalty = dues_ledger::outstanding_penalty(&d);
            let effective_due_date = d.fee_due_date();
            let days_overdue = (today - effective_due_date).num_days().max(0);
            let item = StatementOpenItem {
                due_id: d.id.clone(),
                period: d.period.clone(),
                expense_type: d.expense_type.as_str().to_string(),
                due_date: d.due_date,
                effective_due_date,
                charge_created_late: effective_due_date != d.due_date,
                days_overdue,
                principal_outstanding: principal,
                penalty_outstanding: penalty,
                total_outstanding: principal + penalty,
                operating_budget_id: inner.dues_budget_basis.get(&d.id).cloned(),
                limitation_warning: (today - d.due_date).num_days() > LIMITATION_DAYS,
            };
            if item.total_outstanding > Decimal::ZERO {
                items_by_person
                    .entry(stored.liable_person_id)
                    .or_default()
                    .push(item);
            }
        }

        // Also check if any former owners have joint liability on tenant dues for this unit
        if debtor == DEBTOR_OWNER && viewer != Some(DEBTOR_TENANT) {
            for due in inner.dues.iter().filter(|d| {
                crate::auth::same_id(&d.unit_id, &unit.id)
                    && d.status.is_collectable()
                    && d.debtor_type.as_str() == DEBTOR_TENANT
            }) {
                if let Some(owners) = inner.joint_liability_owners.get(&due.id) {
                    for owner in owners {
                        if Some(owner.person_id) != current_person_id {
                            items_by_person.entry(Some(owner.person_id)).or_default();
                        }
                    }
                }
            }
        }

        // Items for current role holder: unattributed items (None) and items stamped with current_person_id.
        let mut current_items = Vec::new();
        if let Some(items) = items_by_person.remove(&None) {
            current_items.extend(items);
        }
        if let Some(cur_pid) = current_person_id {
            if let Some(items) = items_by_person.remove(&Some(cur_pid)) {
                current_items.extend(items);
            }
        }
        current_items.sort_by_key(|i| i.due_date);

        let advance = inner.available_advance_of(&unit.id, debtor);
        let default_role_name = if debtor == DEBTOR_TENANT {
            "Kiracı"
        } else {
            "Kat Maliki"
        };

        // Determine if current role holder entry should be emitted.
        let should_emit_current = if debtor == DEBTOR_TENANT {
            current_holder_name.is_some() || !current_items.is_empty() || !advance.is_zero()
        } else {
            true
        };

        if should_emit_current {
            let current_name = current_holder_name.unwrap_or_else(|| default_role_name.to_string());
            let current_joint = if debtor == DEBTOR_OWNER {
                current_person_id
                    .map(&joint_items_for_owner)
                    .unwrap_or_default()
            } else {
                Vec::new()
            };
            debtors.push(create_statement_debtor(
                debtor,
                current_name,
                current_person_id,
                false,
                advance,
                current_items,
                current_joint,
            ));
        }

        // Now process former debtors (each remaining entry in items_by_person is Some(pid))
        let mut former_entries = Vec::new();
        for (pid_opt, mut former_items) in items_by_person {
            let Some(pid) = pid_opt else { continue };
            former_items.sort_by_key(|i| i.due_date);
            let former_joint = if debtor == DEBTOR_OWNER {
                joint_items_for_owner(pid)
            } else {
                Vec::new()
            };
            if former_items.is_empty() && former_joint.is_empty() {
                continue;
            }
            let earliest_date = former_items
                .first()
                .map(|i| i.due_date)
                .into_iter()
                .chain(former_joint.first().map(|i| i.due_date))
                .min();
            let name = name_of_person(pid).unwrap_or_else(|| default_role_name.to_string());
            let row = create_statement_debtor(
                debtor,
                name,
                Some(pid),
                true,
                Decimal::ZERO,
                former_items,
                former_joint,
            );
            former_entries.push((earliest_date, row));
        }
        former_entries.sort_by_key(|(date, _)| *date);
        for (_, row) in former_entries {
            debtors.push(row);
        }
    }

    // A resident sees only their own section. A predecessor with outstanding
    // items still sees their own (now former) section, never the current
    // holder's; a caller with no attributed section (for example a household
    // member) sees the current holder's section. Site staff keep every section.
    if viewer.is_some() {
        match viewer_person_id {
            Some(pid) if debtors.iter().any(|d| d.liable_person_id == Some(pid)) => {
                debtors.retain(|d| d.liable_person_id == Some(pid));
            }
            _ => debtors.retain(|d| !d.is_former),
        }
    }

    let mut receipts: Vec<StatementReceipt> = inner
        .payment_receipts
        .iter()
        .filter(|r| crate::auth::same_id(&r.unit_id, &unit.id))
        .filter(|r| match viewer {
            None => true,
            Some(_) => viewer_person_id.is_some_and(|person_id| {
                r.payer_person_id == Some(person_id) || r.on_behalf_of_person_id == Some(person_id)
            }),
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
            credited_amount: if c.kind == CORRECTION_REISSUE || c.kind == CORRECTION_SPLIT_REISSUE {
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
