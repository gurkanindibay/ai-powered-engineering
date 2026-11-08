//! Ledger application service: persists in-memory ledger changes and applies
//! advance-balance offsets.
//!
//! These functions used to live in the HTTP handlers module, which forced the
//! scheduler to depend on `handlers`. Both now depend on this module instead.
//! `handlers` re-exports them so existing call sites keep compiling.

use chrono::Utc;
use rust_decimal::Decimal;

use crate::models::{
    BankTransactionItem, DebtStatus, ReconciliationMatch, ReconciliationStatus, UnitAdvance,
};

/// Snapshot of the in-memory ledger (liability payment state and advance
/// balances), used to persist exactly what an in-memory operation changed.
pub struct LedgerSnapshot {
    dues: std::collections::HashMap<String, (Decimal, Decimal, Decimal, DebtStatus)>,
    advances: std::collections::HashMap<String, UnitAdvance>,
}

pub fn ledger_snapshot(inner: &crate::state::AppStateInner) -> LedgerSnapshot {
    LedgerSnapshot {
        dues: inner
            .dues
            .iter()
            .map(|d| {
                (
                    d.id.clone(),
                    (d.paid_principal, d.paid_penalty, d.delay_penalty, d.status),
                )
            })
            .collect(),
        advances: inner.advance_balances.clone(),
    }
}

/// Persists every liability and advance balance that differs from `before`.
/// Errors are returned (and logged), never discarded.
pub async fn persist_ledger_changes(
    pool: &deadpool_postgres::Pool,
    before: &LedgerSnapshot,
    inner: &crate::state::AppStateInner,
) -> Result<(), String> {
    let mut errors: Vec<String> = Vec::new();
    for d in &inner.dues {
        let now = (d.paid_principal, d.paid_penalty, d.delay_penalty, d.status);
        if before.dues.get(&d.id) != Some(&now) && crate::db::parse_id_to_i64(&d.id).is_some() {
            if let Err(e) = crate::db::sync_due_payment_state(pool, d).await {
                errors.push(format!("dues liability {}: {}", d.id, e));
            }
        }
    }
    for (unit, adv) in &inner.advance_balances {
        let old = before.advances.get(unit).copied().unwrap_or_default();
        for (debtor, now, was) in [
            ("OWNER", adv.owner, old.owner),
            ("TENANT", adv.tenant, old.tenant),
        ] {
            if now != was {
                if let Err(e) = crate::db::save_advance_balance(pool, unit, debtor, now).await {
                    errors.push(format!("advance balance {}/{}: {}", unit, debtor, e));
                }
            }
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        tracing::error!("Ledger persistence failed: {}", errors.join("; "));
        Err(format!(
            "Ledger changes were not fully saved: {}",
            errors.join("; ")
        ))
    }
}

/// Domain Service / Rule: Advance Balance Auto-Offsetting
/// When dues liabilities exist or arrive for a unit, available advance balance
/// (Avans Bakiye) is automatically deducted against the debt (FIFO order by
/// due_date). Each liability is offset only from its own debtor's advance
/// (O-1): a tenant's surplus never silently pays the owner's dues; that takes an
/// explicit TENANT -> OWNER inter-ledger transfer.
pub fn apply_advance_payments_offset(
    inner: &mut crate::state::AppStateInner,
    target_unit_id: Option<&str>,
) -> (usize, Decimal) {
    let unit_ids: Vec<String> = match target_unit_id {
        Some(u) => vec![u.to_string()],
        None => inner.units.iter().map(|u| u.id.clone()).collect(),
    };

    let mut auto_settled_count = 0;
    let mut total_offset_amount = Decimal::ZERO;

    for u_id in unit_ids {
        let mut buckets = match inner.advance_balances.get(&u_id) {
            Some(adv) if adv.total() > Decimal::ZERO => *adv,
            _ => continue,
        };

        // Find all unpaid dues for this unit
        let mut unpaid_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == u_id && d.status != DebtStatus::Paid)
            .map(|(i, _)| i)
            .collect();

        // FIFO: Sort by due_date ascending
        unpaid_indices.sort_by_key(|&i| inner.dues[i].due_date);

        let unit_site_id = inner
            .units
            .iter()
            .find(|u| u.id == *u_id)
            .map(|u| u.site_id.clone())
            .unwrap_or_else(|| "1".to_string());
        let unit_block = inner
            .units
            .iter()
            .find(|u| u.id == *u_id)
            .map(|u| u.block_id.clone())
            .unwrap_or_else(|| "A".to_string());
        let unit_number = inner
            .units
            .iter()
            .find(|u| u.id == *u_id)
            .map(|u| u.unit_number)
            .unwrap_or(1);
        let unit_resident_name = inner
            .units
            .iter()
            .find(|u| u.id == *u_id)
            .and_then(|u| u.owner_user_id.as_ref())
            .and_then(|uid| inner.users.iter().find(|user| &user.id == uid))
            .map(|user| user.full_name.clone());

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
                .calculate_delay_penalty(due.clone(), Utc::now().date_naive());
            let due_amount = due.total_amount;
            let period = due.period.clone();
            let due_id = due.id.clone();

            if *advance >= due_amount {
                // Full settlement of this due liability (penalty first, then principal)
                let settled = crate::services::dues_ledger::settle(due, due_amount);
                *advance -= settled.total();
                total_offset_amount += settled.total();
                auto_settled_count += 1;

                let offset_txn_id = format!("TXN-ADV-OFFSET-{}", due_id);
                if !inner
                    .reconciliation_queue
                    .iter()
                    .any(|m| m.transaction.transaction_id == offset_txn_id)
                {
                    let match_seq = inner.reconciliation_queue.len() + 1;
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-{}", match_seq),
                        site_id: unit_site_id.clone(),
                        transaction: BankTransactionItem {
                            transaction_id: offset_txn_id,
                            date: Utc::now().date_naive(),
                            amount: due_amount,
                            currency: "TRY".to_string(),
                            description: format!("Avans Mahsubu: {} Aidatı", period),
                            sender_name: Some("Otomatik Avans Mahsubu".to_string()),
                            sender_iban: None,
                            reference_no: Some(due_id.clone()),
                        },
                        matched_unit_id: Some(u_id.clone()),
                        matched_block: Some(unit_block.clone()),
                        matched_unit_number: Some(unit_number),
                        matched_resident_name: unit_resident_name.clone(),
                        confidence_score: 100,
                        matched_due_id: Some(due_id),
                        outstanding_balance: Some(due_amount),
                        amount_matches_balance: true,
                        status: ReconciliationStatus::Approved,
                        status_code: ReconciliationStatus::Approved.as_str().to_string(),
                        notes: Some(format!(
                            "{} aidatı avans bakiyenizden otomatik mahsup edildi",
                            period
                        )),
                    });
                }
            } else {
                // Partial deduction
                let partial = crate::services::dues_ledger::settle(due, *advance).total();
                *advance -= partial;
                total_offset_amount += partial;

                let offset_txn_id = format!("TXN-ADV-PARTIAL-{}", due_id);
                if !inner
                    .reconciliation_queue
                    .iter()
                    .any(|m| m.transaction.transaction_id == offset_txn_id)
                {
                    let match_seq = inner.reconciliation_queue.len() + 1;
                    inner.reconciliation_queue.push(ReconciliationMatch {
                        match_id: format!("MATCH-OFFSET-PARTIAL-{}", match_seq),
                        site_id: unit_site_id.clone(),
                        transaction: BankTransactionItem {
                            transaction_id: offset_txn_id,
                            date: Utc::now().date_naive(),
                            amount: partial,
                            currency: "TRY".to_string(),
                            description: format!("Kısmi Avans Mahsubu: {} Aidatı", period),
                            sender_name: Some("Otomatik Avans Mahsubu".to_string()),
                            sender_iban: None,
                            reference_no: Some(due_id.clone()),
                        },
                        matched_unit_id: Some(u_id.clone()),
                        matched_block: Some(unit_block.clone()),
                        matched_unit_number: Some(unit_number),
                        matched_resident_name: unit_resident_name.clone(),
                        confidence_score: 100,
                        matched_due_id: Some(due_id),
                        outstanding_balance: Some(partial),
                        amount_matches_balance: false,
                        status: ReconciliationStatus::Approved,
                        status_code: ReconciliationStatus::Approved.as_str().to_string(),
                        notes: Some(format!(
                            "₺{:.2} tutarındaki avans {} aidatından mahsup edildi",
                            partial, period
                        )),
                    });
                }
            }
        }
        inner.advance_balances.insert(u_id.clone(), buckets);
    }

    (auto_settled_count, total_offset_amount)
}
