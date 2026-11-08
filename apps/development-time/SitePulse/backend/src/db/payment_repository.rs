use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use crate::models::{
    DebtStatus, DuesLiability, PaymentEntry,
    PaymentReceipt,
};
use super::base::{require_id, DbResult};
pub async fn save_payment_receipt(
    pool: &Pool,
    receipt: &PaymentReceipt,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &receipt.site_id)?;
    let unit_id_num = require_id("entity", &receipt.unit_id)?;
    let breakdown_json_str = serde_json::to_string(&receipt.allocation_breakdown)?;

    // Receipts are append-only (V16): an existing receipt is never rewritten.
    let row = client
        .query_opt(
            r#"
            INSERT INTO payment_receipts (
                site_id, unit_id, receipt_number, sequence_number,
                payer_name, payer_role, on_behalf_of_name, on_behalf_of_role,
                total_amount, payment_channel, channel_reference,
                allocated_principal, allocated_penalty, allocated_advance,
                allocation_breakdown, is_rent_offset_eligible, legal_statutory_note,
                verification_hash, issued_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19)
            ON CONFLICT (site_id, receipt_number) DO NOTHING
            RETURNING id
            "#,
            &[
                &site_id_num,
                &unit_id_num,
                &receipt.receipt_number,
                &receipt.sequence_number,
                &receipt.payer_name,
                &receipt.payer_role,
                &receipt.on_behalf_of_name,
                &receipt.on_behalf_of_role,
                &receipt.total_amount,
                &receipt.payment_channel,
                &receipt.channel_reference,
                &receipt.allocated_principal,
                &receipt.allocated_penalty,
                &receipt.allocated_advance,
                &breakdown_json_str,
                &receipt.is_rent_offset_eligible,
                &receipt.legal_statutory_note,
                &receipt.verification_hash,
                &receipt.issued_at,
            ],
        )
        .await?;
    let receipt_id: i64 = match row {
        Some(r) => r.get(0),
        None => client
            .query_one(
                "SELECT id FROM payment_receipts WHERE site_id = $1 AND receipt_number = $2",
                &[&site_id_num, &receipt.receipt_number],
            )
            .await?
            .get(0),
    };
    info!("Saved payment receipt {} (id: {}) to PostgreSQL", receipt.receipt_number, receipt_id);
    Ok(receipt_id)
}

pub async fn get_next_receipt_sequence(
    pool: &Pool,
    site_id: &str,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let row = client
        .query_one(
            "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM payment_receipts WHERE site_id = $1",
            &[&site_id_num],
        )
        .await?;
    let next_seq: i64 = row.get(0);
    Ok(next_seq)
}





pub async fn claim_bank_webhook_transaction(pool: &Pool, transaction_id: &str) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let n = client
        .execute(
            "INSERT INTO processed_bank_webhooks (transaction_id) VALUES ($1) ON CONFLICT (transaction_id) DO NOTHING",
            &[&transaction_id],
        )
        .await?;
    Ok(n == 1)
}

/// Gives a claimed webhook transaction back when processing failed before the
/// payment committed, so the bank's retry is applied instead of being ignored.
/// (The payment itself is idempotent on `BANK:<transaction_id>`.)
pub async fn release_bank_webhook_transaction(pool: &Pool, transaction_id: &str) -> DbResult<()> {
    let client = pool.get().await?;
    client
        .execute("DELETE FROM processed_bank_webhooks WHERE transaction_id = $1", &[&transaction_id])
        .await?;
    Ok(())
}





pub async fn tx_find_idempotent_receipt(tx: &deadpool_postgres::Transaction<'_>, site_id: i64, key: &str) -> DbResult<Option<i64>> {
    Ok(tx
        .query_opt(
            "SELECT receipt_id FROM payment_idempotency_keys WHERE site_id = $1 AND idempotency_key = $2",
            &[&site_id, &key],
        )
        .await?
        .map(|r| r.get(0)))
}

pub async fn tx_store_idempotency_key(tx: &deadpool_postgres::Transaction<'_>, site_id: i64, key: &str, receipt_id: i64) -> DbResult<()> {
    tx.execute(
        "INSERT INTO payment_idempotency_keys (site_id, idempotency_key, receipt_id) VALUES ($1, $2, $3)",
        &[&site_id, &key, &receipt_id],
    )
    .await?;
    Ok(())
}

/// Locks the unit row and checks that it belongs to the site.
pub async fn tx_lock_unit(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64, site_id: i64) -> DbResult<bool> {
    Ok(tx
        .query_opt("SELECT id FROM units WHERE id = $1 AND site_id = $2 FOR UPDATE", &[&unit_id, &site_id])
        .await?
        .is_some())
}

/// Open liabilities of a unit, oldest first, locked for update.
pub async fn tx_load_open_dues(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64) -> DbResult<Vec<DuesLiability>> {
    let rows = tx
        .query(
            r#"
            SELECT id, period, principal_amount, delay_penalty, paid_principal, paid_penalty,
                   due_date, status, debtor_type, expense_type, penalty_accrued_through
            FROM dues_liabilities
            WHERE unit_id = $1 AND status NOT IN ('PAID', 'CANCELLED')
            ORDER BY due_date, id
            FOR UPDATE
            "#,
            &[&unit_id],
        )
        .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let status: String = r.get(7);
            let mut d = DuesLiability {
                id: r.get::<_, i64>(0).to_string(),
                unit_id: unit_id.to_string(),
                period: r.get(1),
                principal_amount: r.get(2),
                delay_penalty: r.get(3),
                total_amount: Decimal::ZERO,
                due_date: r.get(6),
                status: if status == "OVERDUE" { DebtStatus::Overdue } else { DebtStatus::Pending },
                paid_principal: r.get(4),
                paid_penalty: r.get(5),
                debtor_type: r.get(8),
                expense_type: r.get(9),
                penalty_accrued_through: r.get(10),
            };
            crate::services::dues_ledger::refresh(&mut d);
            d
        })
        .collect())
}

/// Next receipt sequence for a site. The counter row is locked by the UPDATE
/// until commit, so concurrent payments serialize and never share a number.
pub async fn tx_next_receipt_sequence(tx: &deadpool_postgres::Transaction<'_>, site_id: i64) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO receipt_counters (site_id, last_sequence)
            VALUES ($1, COALESCE((SELECT MAX(sequence_number) FROM payment_receipts WHERE site_id = $1), 0) + 1)
            ON CONFLICT (site_id) DO UPDATE SET last_sequence = receipt_counters.last_sequence + 1
            RETURNING last_sequence
            "#,
            &[&site_id],
        )
        .await?;
    Ok(row.get(0))
}

pub async fn tx_insert_receipt(tx: &deadpool_postgres::Transaction<'_>, receipt: &PaymentReceipt, site_id: i64, unit_id: i64) -> DbResult<i64> {
    let breakdown = serde_json::to_string(&receipt.allocation_breakdown)?;
    let row = tx
        .query_one(
            r#"
            INSERT INTO payment_receipts (
                site_id, unit_id, receipt_number, sequence_number,
                payer_name, payer_role, on_behalf_of_name, on_behalf_of_role,
                total_amount, payment_channel, channel_reference,
                allocated_principal, allocated_penalty, allocated_advance,
                allocation_breakdown, is_rent_offset_eligible, legal_statutory_note,
                verification_hash, issued_at, payer_person_id, on_behalf_of_person_id
            )
            SELECT $1, $2, $3, $4, $5, $6::text, $7, $8::text, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19,
                   (SELECT p.person_id FROM sp_unit_party_at($2, $6::text, ($19::timestamptz)::date) p),
                   CASE WHEN $8::text = 'OWNER'
                        THEN (SELECT p.person_id FROM sp_unit_party_at($2, 'OWNER', ($19::timestamptz)::date) p) END
            RETURNING id
            "#,
            &[
                &site_id,
                &unit_id,
                &receipt.receipt_number,
                &receipt.sequence_number,
                &receipt.payer_name,
                &receipt.payer_role,
                &receipt.on_behalf_of_name,
                &receipt.on_behalf_of_role,
                &receipt.total_amount,
                &receipt.payment_channel,
                &receipt.channel_reference,
                &receipt.allocated_principal,
                &receipt.allocated_penalty,
                &receipt.allocated_advance,
                &breakdown,
                &receipt.is_rent_offset_eligible,
                &receipt.legal_statutory_note,
                &receipt.verification_hash,
                &receipt.issued_at,
            ],
        )
        .await?;
    Ok(row.get(0))
}

pub async fn tx_insert_entry(tx: &deadpool_postgres::Transaction<'_>, entry: &PaymentEntry, site_id: i64, unit_id: i64) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO payment_entries (
                site_id, unit_id, payer_name, payer_role, receipt_id,
                amount, payment_channel, settlement_status, description,
                external_reference, payment_date, created_at, payer_person_id, occupancy_id
            )
            SELECT $1, $2, $3, $4::text, $5, $6, $7, $8, $9, $10, $11, $12, p.person_id, p.occupancy_id
            FROM (SELECT 1) AS one
            LEFT JOIN LATERAL sp_unit_party_at($2, $4::text, ($11::timestamptz)::date) p ON TRUE
            RETURNING id
            "#,
            &[
                &site_id,
                &unit_id,
                &entry.payer_name,
                &entry.payer_role,
                &entry.receipt_id,
                &entry.amount,
                &entry.payment_channel,
                &entry.settlement_status,
                &entry.description,
                &entry.external_reference,
                &entry.payment_date,
                &entry.created_at,
            ],
        )
        .await?;
    Ok(row.get(0))
}

/// Turns an open UNMATCHED/PENDING entry of this unit into the settled entry of
/// `receipt_id` (match-all, SPEC-005 R2) instead of inserting a duplicate.
/// Returns `None` when no such open entry with exactly `amount` exists.
pub async fn tx_claim_unmatched_entry(
    tx: &deadpool_postgres::Transaction<'_>,
    entry_id: i64,
    site_id: i64,
    unit_id: i64,
    amount: Decimal,
    receipt_id: i64,
) -> DbResult<Option<i64>> {
    let row = tx
        .query_opt(
            r#"
            UPDATE payment_entries e
            SET settlement_status = 'SETTLED',
                receipt_id = $5,
                payer_person_id = COALESCE(e.payer_person_id,
                    (SELECT p.person_id FROM sp_unit_party_at(e.unit_id, e.payer_role, e.payment_date::date) p)),
                occupancy_id = COALESCE(e.occupancy_id,
                    (SELECT p.occupancy_id FROM sp_unit_party_at(e.unit_id, e.payer_role, e.payment_date::date) p))
            WHERE e.id = $1 AND e.site_id = $2 AND e.unit_id = $3 AND e.amount = $4
              AND e.settlement_status IN ('UNMATCHED', 'PENDING') AND e.receipt_id IS NULL
            RETURNING e.id
            "#,
            &[&entry_id, &site_id, &unit_id, &amount, &receipt_id],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

/// Records a settlement on a liability (paid amounts only; owed amounts untouched
/// except that the accrued penalty is brought up to date) plus its allocation row.
pub async fn tx_settle_due(
    tx: &deadpool_postgres::Transaction<'_>,
    entry_id: i64,
    due: &DuesLiability,
    principal: Decimal,
    penalty: Decimal,
) -> DbResult<()> {
    let due_id = require_id("dues liability", &due.id)?;
    let status = if due.status == DebtStatus::Paid { "PAID" } else { "PARTIALLY_PAID" };
    let n = tx
        .execute(
            r#"
            UPDATE dues_liabilities
            SET delay_penalty  = $2,
                penalty_accrued_through = COALESCE($6, penalty_accrued_through),
                paid_principal = paid_principal + $3,
                paid_penalty   = paid_penalty + $4,
                paid_amount    = paid_amount + $3 + $4,
                status         = $5,
                payment_date   = CURRENT_TIMESTAMP,
                version        = version + 1
            WHERE id = $1
            "#,
            &[&due_id, &due.delay_penalty, &principal, &penalty, &status, &due.penalty_accrued_through],
        )
        .await?;
    if n != 1 {
        return Err(format!("dues liability {} disappeared during payment", due_id).into());
    }
    tx.execute(
        "INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at)
         VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)",
        &[&entry_id, &due_id, &principal, &penalty],
    )
    .await?;
    Ok(())
}

/// Credits a unit's advance balance for one debtor type by `amount` (an increment,
/// never an overwrite) and writes the matching ledger entry. Returns the new balance.
pub async fn tx_credit_advance(
    tx: &deadpool_postgres::Transaction<'_>,
    unit_id: i64,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference: Option<&str>,
    description: Option<&str>,
) -> DbResult<Decimal> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id, debtor_type) DO UPDATE SET
                balance = advance_balances.balance + EXCLUDED.balance,
                updated_at = CURRENT_TIMESTAMP
            RETURNING balance
            "#,
            &[&unit_id, &debtor_type, &amount],
        )
        .await?;
    tx.execute(
        "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)",
        &[&unit_id, &debtor_type, &entry_type, &amount, &reference, &description],
    )
    .await?;
    Ok(row.get(0))
}

pub async fn get_payment_receipt_by_id(pool: &Pool, receipt_id: i64) -> DbResult<Option<PaymentReceipt>> {
    let client = pool.get().await?;
    let row = client
        .query_opt(
            r#"
            SELECT id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role,
                   on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference,
                   allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text,
                   is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at
            FROM payment_receipts WHERE id = $1
            "#,
            &[&receipt_id],
        )
        .await?;
    let Some(r) = row else { return Ok(None) };
    let breakdown: Option<String> = r.get(15);
    Ok(Some(PaymentReceipt {
        id: r.get(0),
        site_id: r.get::<_, i64>(1).to_string(),
        unit_id: r.get::<_, i64>(2).to_string(),
        receipt_number: r.get(3),
        sequence_number: r.get(4),
        payer_name: r.get(5),
        payer_role: r.get(6),
        on_behalf_of_name: r.get(7),
        on_behalf_of_role: r.get(8),
        total_amount: r.get(9),
        payment_channel: r.get(10),
        channel_reference: r.get(11),
        allocated_principal: r.get(12),
        allocated_penalty: r.get(13),
        allocated_advance: r.get(14),
        allocation_breakdown: breakdown.and_then(|b| serde_json::from_str(&b).ok()).unwrap_or_default(),
        is_rent_offset_eligible: r.get(16),
        legal_statutory_note: r.get(17),
        verification_hash: r.get(18),
        issued_at: r.get(19),
    }))
}

/// Locks and returns one debtor's advance balance for a unit (0 when absent).
pub async fn tx_lock_advance(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64, debtor_type: &str) -> DbResult<Decimal> {
    Ok(tx
        .query_opt(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2 FOR UPDATE",
            &[&unit_id, &debtor_type],
        )
        .await?
        .map(|r| r.get(0))
        .unwrap_or(Decimal::ZERO))
}

/// Debits an advance balance (never below zero) and writes the ledger entry.
pub async fn tx_debit_advance(
    tx: &deadpool_postgres::Transaction<'_>,
    unit_id: i64,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference: Option<&str>,
    description: Option<&str>,
) -> DbResult<Decimal> {
    let row = tx
        .query_opt(
            "UPDATE advance_balances SET balance = balance - $3, updated_at = CURRENT_TIMESTAMP
             WHERE unit_id = $1 AND debtor_type = $2 AND balance >= $3 RETURNING balance",
            &[&unit_id, &debtor_type, &amount],
        )
        .await?
        .ok_or("insufficient advance balance")?;
    tx.execute(
        "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)",
        &[&unit_id, &debtor_type, &entry_type, &amount, &reference, &description],
    )
    .await?;
    Ok(row.get(0))
}

