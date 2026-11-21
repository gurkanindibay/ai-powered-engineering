//! In-memory advance-balance offset.
//!
//! This is the database-less ledger rule (tests and demo mode) and the shape the
//! in-memory read model is kept in. With PostgreSQL the offset is computed and
//! booked as a same-debtor virman receipt in one tenant-bound transaction and
//! mirrored here from the committed result (see `services::advance_offset_service`).
//!
//! The former `ledger_snapshot` / `persist_ledger_changes` pair is gone: it
//! wrote *absolute* paid amounts and balances from memory back to PostgreSQL,
//! so a stale copy could overwrite a committed payment or re-credit a spent
//! advance.

use rust_decimal::Decimal;

use crate::models::{
    BankTransactionItem, DebtStatus, DuesLiability, ReconciliationMatch, ReconciliationStatus,
};

/// Adds the resident-facing record of one offset ("Avans Mahsubu") to the
/// in-memory reconciliation view, once per liability and kind (full/partial).
pub fn record_offset_match(
    inner: &mut crate::state::AppStateInner,
    site_id: &str,
    unit_id: &str,
    due: &DuesLiability,
    amount: Decimal,
) {
    let full = due.status == DebtStatus::Paid;
    let offset_txn_id = if full {
        format!("TXN-ADV-OFFSET-{}", due.id)
    } else {
        format!("TXN-ADV-PARTIAL-{}", due.id)
    };
    if inner
        .reconciliation_queue
        .iter()
        .any(|m| m.transaction.transaction_id == offset_txn_id)
    {
        return;
    }
    let unit = inner
        .units
        .iter()
        .find(|u| crate::auth::same_id(&u.id, unit_id))
        .cloned();
    let resident_name = unit
        .as_ref()
        .and_then(|u| u.owner_user_id.as_ref())
        .and_then(|uid| inner.users.iter().find(|user| &user.id == uid))
        .map(|user| user.full_name.clone());
    let match_seq = inner.reconciliation_queue.len() + 1;
    let period = due.period.clone();
    inner.reconciliation_queue.push(ReconciliationMatch {
        match_id: if full {
            format!("MATCH-OFFSET-{}", match_seq)
        } else {
            format!("MATCH-OFFSET-PARTIAL-{}", match_seq)
        },
        site_id: site_id.to_string(),
        transaction: BankTransactionItem {
            transaction_id: offset_txn_id,
            date: crate::services::finance_common::site_today(inner, site_id),
            amount,
            currency: "TRY".to_string(),
            description: if full {
                format!("Avans Mahsubu: {} Aidatı", period)
            } else {
                format!("Kısmi Avans Mahsubu: {} Aidatı", period)
            },
            sender_name: Some("Otomatik Avans Mahsubu".to_string()),
            sender_iban: None,
            reference_no: Some(due.id.clone()),
        },
        matched_unit_id: Some(unit_id.to_string()),
        matched_block: unit.as_ref().map(|u| u.block_id.clone()),
        matched_unit_number: unit.as_ref().map(|u| u.unit_number),
        matched_resident_name: resident_name,
        confidence_score: 100,
        matched_due_id: Some(due.id.clone()),
        outstanding_balance: Some(amount),
        amount_matches_balance: full,
        status: ReconciliationStatus::Approved,
        status_code: ReconciliationStatus::Approved.as_str().to_string(),
        notes: Some(if full {
            format!(
                "{} aidatı avans bakiyenizden otomatik mahsup edildi",
                period
            )
        } else {
            format!(
                "₺{:.2} tutarındaki avans {} aidatından mahsup edildi",
                amount, period
            )
        }),
        assigned_unit_id: None,
        assigned_debtor_role: None,
    });
}

/// Domain Service / Rule: Advance Balance Auto-Offsetting (in-memory ledger).
/// When dues liabilities exist or arrive for a unit, available advance balance
/// (Avans Bakiye) is automatically deducted against the debt (FIFO order by
/// due_date). Each liability is offset only from its own debtor's advance
/// (O-1): a tenant's surplus never silently pays the owner's dues; that takes an
/// explicit TENANT -> OWNER inter-ledger transfer.
///
/// `None` offsets every unit of every site: only the platform scheduler and
/// the database-less mode may do that. Tenant code uses
/// [`apply_advance_payments_offset_for_site`].
pub fn apply_advance_payments_offset(
    inner: &mut crate::state::AppStateInner,
    target_unit_id: Option<&str>,
) -> (usize, Decimal) {
    let unit_ids: Vec<String> = match target_unit_id {
        Some(u) => vec![u.to_string()],
        None => inner.units.iter().map(|u| u.id.clone()).collect(),
    };
    offset_units(inner, unit_ids)
}

/// Offsets every unit of one site, and only that site.
pub fn apply_advance_payments_offset_for_site(
    inner: &mut crate::state::AppStateInner,
    site_id: &str,
) -> (usize, Decimal) {
    let unit_ids: Vec<String> = inner
        .units
        .iter()
        .filter(|u| crate::auth::same_id(&u.site_id, site_id))
        .map(|u| u.id.clone())
        .collect();
    offset_units(inner, unit_ids)
}

fn offset_units(
    inner: &mut crate::state::AppStateInner,
    unit_ids: Vec<String>,
) -> (usize, Decimal) {
    let mut auto_settled_count = 0;
    let mut total_offset_amount = Decimal::ZERO;

    for u_id in unit_ids {
        let mut buckets = match inner.advance_balances.get(&u_id) {
            Some(adv) => *adv,
            _ => continue,
        };
        for debtor in ["OWNER", "TENANT"] {
            let reserved = inner
                .pending_exit_advance_reservations
                .get(&(u_id.clone(), debtor.to_string()))
                .copied()
                .unwrap_or(Decimal::ZERO);
            let bucket = buckets.bucket_mut(debtor);
            *bucket = (*bucket - reserved).max(Decimal::ZERO);
        }
        if buckets.total() <= Decimal::ZERO {
            continue;
        }
        // A unit without a known site is never offset: no tenant is guessed.
        let unit_site_id = match inner.units.iter().find(|u| u.id == u_id) {
            Some(u) => u.site_id.clone(),
            None => continue,
        };
        let today = crate::services::finance_common::site_today(inner, &unit_site_id);

        let mut unpaid_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == u_id && d.status.is_collectable())
            .map(|(i, _)| i)
            .collect();
        // FIFO: oldest liability first.
        unpaid_indices.sort_by_key(|&i| inner.dues[i].due_date);

        let mut settled: Vec<(DuesLiability, Decimal)> = Vec::new();
        for idx in unpaid_indices {
            let debtor = inner.dues[idx].debtor_type;
            let advance = buckets.bucket_mut(debtor.as_str());
            if *advance <= Decimal::ZERO {
                continue;
            }
            let due = &mut inner.dues[idx];
            // KMK 20 segmented accrual: bring the penalty up to today before the
            // offset changes the principal it accrues on.
            *due = crate::services::DuesCalculationService::new()
                .calculate_delay_penalty(due.clone(), today);
            let amount = (*advance).min(due.total_amount);
            let taken = crate::services::dues_ledger::settle(due, amount).total();
            if taken <= Decimal::ZERO {
                continue;
            }
            *advance -= taken;
            total_offset_amount += taken;
            if due.status == DebtStatus::Paid {
                auto_settled_count += 1;
            }
            settled.push((due.clone(), taken));
        }
        inner.advance_balances.insert(u_id.clone(), buckets);
        for (due, taken) in settled {
            record_offset_match(inner, &unit_site_id, &u_id, &due, taken);
        }
    }

    (auto_settled_count, total_offset_amount)
}
