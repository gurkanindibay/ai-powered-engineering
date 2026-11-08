use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use crate::models::{
    DebtStatus, DuesLiability, PaymentEntry,
    PaymentReceipt,
};
use super::base::{require_id, DbResult};

/// Column list read by [`receipt_from_row`] (keep the two in step).
pub const RECEIPT_COLUMNS: &str = "id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, \
     on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference, \
     allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text, \
     is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at, \
     receipt_type, reverses_receipt_id, advance_debtor_type, issuer_name, issuer_address, issuer_tax_id, issuer_tax_office";

pub fn receipt_from_row(r: &tokio_postgres::Row) -> PaymentReceipt {
    let breakdown: Option<String> = r.get(15);
    PaymentReceipt {
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
        receipt_type: r.get(20),
        reverses_receipt_id: r.get(21),
        advance_debtor_type: r.get(22),
        issuer_name: r.get(23),
        issuer_address: r.get(24),
        issuer_tax_id: r.get(25),
        issuer_tax_office: r.get(26),
    }
}

/// Full-sync writer for a receipt held in memory. Receipts are append-only (V16):
/// an existing receipt is never rewritten.
pub async fn save_payment_receipt(
    pool: &Pool,
    receipt: &PaymentReceipt,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &receipt.site_id)?;
    let unit_id_num = require_id("entity", &receipt.unit_id)?;
    let breakdown_json_str = serde_json::to_string(&receipt.allocation_breakdown)?;
    let row = client
        .query_opt(
            r#"
            INSERT INTO payment_receipts (
                site_id, unit_id, receipt_number, sequence_number,
                payer_name, payer_role, on_behalf_of_name, on_behalf_of_role,
                total_amount, payment_channel, channel_reference,
                allocated_principal, allocated_penalty, allocated_advance,
                allocation_breakdown, is_rent_offset_eligible, legal_statutory_note,
                verification_hash, issued_at, receipt_type, reverses_receipt_id, advance_debtor_type,
                issuer_name, issuer_address, issuer_tax_id, issuer_tax_office
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19,
                    $20, $21, $22, $23, $24, $25, $26)
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
                &receipt.receipt_type,
                &receipt.reverses_receipt_id,
                &receipt.advance_debtor_type,
                &receipt.issuer_name,
                &receipt.issuer_address,
                &receipt.issuer_tax_id,
                &receipt.issuer_tax_office,
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
            "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM payment_receipts WHERE site_id = $1 AND receipt_type = 'COLLECTION'",
            &[&site_id_num],
        )
        .await?;
    let next_seq: i64 = row.get(0);
    Ok(next_seq)
}

// ---------------------------------------------------------------------------
// Bank webhook claims (O-3): one row per (receiving account | site, transaction).
// ---------------------------------------------------------------------------

/// Where a bank notification was received, resolved before it is processed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WebhookScope {
    pub site_id: Option<i64>,
    pub site_bank_account_id: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebhookClaim {
    /// First delivery: the claim row id.
    Claimed(i64),
    /// Already claimed. `same_payload` is false when the transaction id was reused
    /// with different content (amount, IBANs or description).
    Duplicate { receipt_id: Option<i64>, same_payload: bool },
}

pub async fn claim_bank_webhook_transaction(
    pool: &Pool,
    scope: &WebhookScope,
    transaction_id: &str,
    payload_hash: &str,
) -> DbResult<WebhookClaim> {
    let client = pool.get().await?;
    let inserted = client
        .query_opt(
            r#"
            INSERT INTO processed_bank_webhooks (transaction_id, site_id, site_bank_account_id, payload_hash)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (scope_key, transaction_id) DO NOTHING
            RETURNING id
            "#,
            &[&transaction_id, &scope.site_id, &scope.site_bank_account_id, &payload_hash],
        )
        .await?;
    if let Some(r) = inserted {
        return Ok(WebhookClaim::Claimed(r.get(0)));
    }
    let existing = client
        .query_one(
            r#"
            SELECT receipt_id, payload_hash FROM processed_bank_webhooks
            WHERE scope_key = COALESCE('A' || $1::bigint::text, 'S' || $2::bigint::text, '-') AND transaction_id = $3
            "#,
            &[&scope.site_bank_account_id, &scope.site_id, &transaction_id],
        )
        .await?;
    let stored_hash: Option<String> = existing.get(1);
    Ok(WebhookClaim::Duplicate {
        receipt_id: existing.get(0),
        // Pre-V17 claims carry no hash; they are trusted as the same delivery.
        same_payload: stored_hash.as_deref().map(|h| h == payload_hash).unwrap_or(true),
    })
}

/// Links a claimed webhook to the receipt its payment issued.
pub async fn attach_bank_webhook_receipt(pool: &Pool, claim_id: i64, receipt_id: i64) -> DbResult<()> {
    let client = pool.get().await?;
    client
        .execute("UPDATE processed_bank_webhooks SET receipt_id = $2 WHERE id = $1", &[&claim_id, &receipt_id])
        .await?;
    Ok(())
}

/// Gives a claimed webhook transaction back when processing failed before the
/// payment committed, so the bank's retry is applied instead of being ignored.
/// (The payment itself is idempotent on its `BANK:` key.)
pub async fn release_bank_webhook_transaction(pool: &Pool, claim_id: i64) -> DbResult<()> {
    let client = pool.get().await?;
    client
        .execute("DELETE FROM processed_bank_webhooks WHERE id = $1 AND receipt_id IS NULL", &[&claim_id])
        .await?;
    Ok(())
}

/// Resolves the receiving site and bank account of a destination IBAN: a site
/// account's IBAN, or a unit's virtual IBAN (then the site's active account).
pub async fn resolve_webhook_scope(pool: &Pool, destination_iban: &str) -> DbResult<WebhookScope> {
    let client = pool.get().await?;
    let row = client
        .query_opt(
            r#"
            SELECT a.site_id, a.id FROM site_bank_accounts a
            WHERE upper(replace(a.iban, ' ', '')) = $1
            UNION ALL
            SELECT u.site_id, (SELECT a.id FROM site_bank_accounts a WHERE a.site_id = u.site_id AND a.is_active LIMIT 1)
            FROM units u WHERE upper(replace(u.virtual_iban, ' ', '')) = $1
            LIMIT 1
            "#,
            &[&destination_iban],
        )
        .await?;
    Ok(row
        .map(|r| WebhookScope { site_id: Some(r.get(0)), site_bank_account_id: r.get(1) })
        .unwrap_or_default())
}

pub async fn load_idempotency_keys(pool: &Pool) -> DbResult<Vec<(String, String, i64)>> {
    let client = pool.get().await?;
    Ok(client
        .query("SELECT site_id, idempotency_key, receipt_id FROM payment_idempotency_keys", &[])
        .await?
        .into_iter()
        .map(|r| (r.get::<_, i64>(0).to_string(), r.get(1), r.get(2)))
        .collect())
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

fn due_from_row(r: &tokio_postgres::Row, unit_id: i64) -> DuesLiability {
    let status: String = r.get(7);
    let mut d = DuesLiability {
        id: r.get::<_, i64>(0).to_string(),
        unit_id: unit_id.to_string(),
        period: r.get(1),
        principal_amount: r.get(2),
        delay_penalty: r.get(3),
        total_amount: Decimal::ZERO,
        due_date: r.get(6),
        status: match status.as_str() {
            "PAID" => DebtStatus::Paid,
            "OVERDUE" => DebtStatus::Overdue,
            _ => DebtStatus::Pending,
        },
        paid_principal: r.get(4),
        paid_penalty: r.get(5),
        debtor_type: r.get(8),
        expense_type: r.get(9),
        penalty_accrued_through: r.get(10),
    };
    crate::services::dues_ledger::refresh(&mut d);
    d
}

const DUE_COLUMNS: &str = "id, period, principal_amount, delay_penalty, paid_principal, paid_penalty, \
     due_date, status, debtor_type, expense_type, penalty_accrued_through";

/// Open liabilities of a unit, oldest first, locked for update.
pub async fn tx_load_open_dues(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64) -> DbResult<Vec<DuesLiability>> {
    let rows = tx
        .query(
            &format!(
                "SELECT {} FROM dues_liabilities WHERE unit_id = $1 AND status NOT IN ('PAID', 'CANCELLED') \
                 ORDER BY due_date, id FOR UPDATE",
                DUE_COLUMNS
            ),
            &[&unit_id],
        )
        .await?;
    Ok(rows.iter().map(|r| due_from_row(r, unit_id)).collect())
}

/// Next receipt sequence for a site and series (`COLLECTION` = TAH, `REVERSAL` =
/// IAD). The counter row is locked by the UPDATE until commit, so concurrent
/// payments serialize and never share a number.
pub async fn tx_next_receipt_sequence(tx: &deadpool_postgres::Transaction<'_>, site_id: i64, receipt_type: &str) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO receipt_counters (site_id, receipt_type, last_sequence)
            VALUES ($1, $2::text, COALESCE((SELECT MAX(sequence_number) FROM payment_receipts
                                            WHERE site_id = $1 AND receipt_type = $2::text), 0) + 1)
            ON CONFLICT (site_id, receipt_type) DO UPDATE SET last_sequence = receipt_counters.last_sequence + 1
            RETURNING last_sequence
            "#,
            &[&site_id, &receipt_type],
        )
        .await?;
    Ok(row.get(0))
}

/// Inserts a receipt and fills its id, payer identity and issuer snapshot (O-5:
/// the site's name, address and tax details at issue time).
pub async fn tx_insert_receipt(tx: &deadpool_postgres::Transaction<'_>, receipt: &mut PaymentReceipt, site_id: i64, unit_id: i64) -> DbResult<i64> {
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
                verification_hash, issued_at, payer_person_id, on_behalf_of_person_id,
                receipt_type, reverses_receipt_id, advance_debtor_type,
                issuer_name, issuer_address, issuer_tax_id, issuer_tax_office
            )
            SELECT $1, $2, $3, $4, $5, $6::text, $7, $8::text, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19,
                   (SELECT p.person_id FROM sp_unit_party_at($2, $6::text, ($19::timestamptz)::date) p),
                   CASE WHEN $8::text = 'OWNER'
                        THEN (SELECT p.person_id FROM sp_unit_party_at($2, 'OWNER', ($19::timestamptz)::date) p) END,
                   $20, $21, $22,
                   s.name, s.address, s.tax_id, s.tax_office
            FROM sites s WHERE s.id = $1
            RETURNING id, issuer_name, issuer_address, issuer_tax_id, issuer_tax_office
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
                &receipt.receipt_type,
                &receipt.reverses_receipt_id,
                &receipt.advance_debtor_type,
            ],
        )
        .await?;
    receipt.id = row.get(0);
    receipt.issuer_name = row.get(1);
    receipt.issuer_address = row.get(2);
    receipt.issuer_tax_id = row.get(3);
    receipt.issuer_tax_office = row.get(4);
    Ok(receipt.id)
}

pub async fn tx_insert_entry(tx: &deadpool_postgres::Transaction<'_>, entry: &PaymentEntry, site_id: i64, unit_id: i64) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO payment_entries (
                site_id, unit_id, payer_name, payer_role, receipt_id,
                amount, payment_channel, settlement_status, description,
                external_reference, payment_date, created_at, payer_person_id, occupancy_id,
                entry_type, reverses_entry_id, reversal_reason, recorded_by
            )
            SELECT $1, $2, $3, $4::text, $5, $6, $7, $8, $9, $10, $11, $12, p.person_id, p.occupancy_id, $13, $14, $15, $16
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
                &entry.entry_type,
                &entry.reverses_entry_id,
                &entry.reversal_reason,
                &entry.recorded_by,
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
        .query_opt(&format!("SELECT {} FROM payment_receipts WHERE id = $1", RECEIPT_COLUMNS), &[&receipt_id])
        .await?;
    Ok(row.as_ref().map(receipt_from_row))
}

/// A receipt by number or numeric id; `site_id` 0 means any site.
pub async fn find_payment_receipt(pool: &Pool, site_id: i64, identifier: &str) -> DbResult<Option<PaymentReceipt>> {
    let client = pool.get().await?;
    let num: Option<i64> = identifier.parse().ok();
    let row = client
        .query_opt(
            &format!(
                "SELECT {} FROM payment_receipts WHERE ($1 = 0 OR site_id = $1) AND (receipt_number = $2 OR id = $3) \
                 ORDER BY (receipt_number = $2) DESC LIMIT 1",
                RECEIPT_COLUMNS
            ),
            &[&site_id, &identifier, &num.unwrap_or(-1)],
        )
        .await?;
    Ok(row.as_ref().map(receipt_from_row))
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

// ---------------------------------------------------------------------------
// Reversals (O-2).
// ---------------------------------------------------------------------------

/// The settled collection entry of a receipt, locked for the reversal.
pub struct ReversibleEntry {
    pub entry_id: i64,
    pub unit_id: i64,
    pub settlement_status: String,
    pub entry_type: String,
    pub receipt: PaymentReceipt,
}

/// Locks a receipt's entry for reversal. `None` when the receipt does not exist
/// in the site or has no ledger entry.
pub async fn tx_lock_entry_of_receipt(
    tx: &deadpool_postgres::Transaction<'_>,
    site_id: i64,
    identifier: &str,
) -> DbResult<Option<ReversibleEntry>> {
    let num: Option<i64> = identifier.parse().ok();
    let receipt_row = tx
        .query_opt(
            &format!(
                "SELECT {} FROM payment_receipts WHERE site_id = $1 AND (receipt_number = $2 OR id = $3) \
                 ORDER BY (receipt_number = $2) DESC LIMIT 1",
                RECEIPT_COLUMNS
            ),
            &[&site_id, &identifier, &num.unwrap_or(-1)],
        )
        .await?;
    let Some(receipt_row) = receipt_row else { return Ok(None) };
    let receipt = receipt_from_row(&receipt_row);
    let entry = tx
        .query_opt(
            "SELECT id, unit_id, settlement_status, entry_type FROM payment_entries WHERE receipt_id = $1 FOR UPDATE",
            &[&receipt.id],
        )
        .await?;
    Ok(entry.map(|e| ReversibleEntry {
        entry_id: e.get(0),
        unit_id: e.get(1),
        settlement_status: e.get(2),
        entry_type: e.get(3),
        receipt,
    }))
}

/// Allocation lines of an entry with their liabilities, liabilities locked.
pub async fn tx_load_entry_allocations(
    tx: &deadpool_postgres::Transaction<'_>,
    entry_id: i64,
) -> DbResult<Vec<(DuesLiability, Decimal, Decimal)>> {
    let rows = tx
        .query(
            &format!(
                "SELECT {}, pa.principal_amount, pa.penalty_amount, d.unit_id FROM payment_allocations pa \
                 JOIN dues_liabilities d ON d.id = pa.dues_liability_id \
                 WHERE pa.payment_entry_id = $1 ORDER BY d.due_date, d.id FOR UPDATE OF d",
                DUE_COLUMNS.split(", ").map(|c| format!("d.{}", c)).collect::<Vec<_>>().join(", ")
            ),
            &[&entry_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| {
            let unit: i64 = r.get(13);
            (due_from_row(r, unit), r.get(11), r.get(12))
        })
        .collect())
}

/// Un-allocates one reversed allocation line: the paid amounts go back down and
/// the status is recomputed from them (PAID / PARTIALLY_PAID / OVERDUE / PENDING).
pub async fn tx_unsettle_due(
    tx: &deadpool_postgres::Transaction<'_>,
    due_id: i64,
    principal: Decimal,
    penalty: Decimal,
) -> DbResult<()> {
    let n = tx
        .execute(
            r#"
            UPDATE dues_liabilities
            SET paid_principal = paid_principal - $2,
                paid_penalty   = paid_penalty - $3,
                paid_amount    = paid_amount - $2 - $3,
                status = CASE
                    WHEN paid_principal - $2 >= principal_amount AND paid_penalty - $3 >= delay_penalty THEN 'PAID'
                    WHEN paid_amount - $2 - $3 > 0 THEN 'PARTIALLY_PAID'
                    WHEN due_date < CURRENT_DATE THEN 'OVERDUE'
                    ELSE 'PENDING' END,
                version = version + 1
            WHERE id = $1 AND status <> 'CANCELLED' AND paid_principal >= $2 AND paid_penalty >= $3
            "#,
            &[&due_id, &principal, &penalty],
        )
        .await?;
    if n != 1 {
        return Err(format!("dues liability {} cannot be un-allocated (cancelled or already reduced)", due_id).into());
    }
    Ok(())
}

/// Moves the original entry SETTLED -> REVERSED (its contra entry must exist).
pub async fn tx_mark_entry_reversed(tx: &deadpool_postgres::Transaction<'_>, entry_id: i64) -> DbResult<()> {
    let n = tx
        .execute(
            "UPDATE payment_entries SET settlement_status = 'REVERSED' WHERE id = $1 AND settlement_status = 'SETTLED'",
            &[&entry_id],
        )
        .await?;
    if n != 1 {
        return Err(format!("payment entry {} is no longer SETTLED", entry_id).into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Debt aging snapshots (O-8).
// ---------------------------------------------------------------------------

/// Stores one site's aging report as of a date. Re-running on the same day
/// replaces that day's rows of the site (a unit paid off since then drops out).
pub async fn save_debt_aging_snapshot(pool: &Pool, site_id: &str, report: &crate::models::DebtAgingReport) -> DbResult<usize> {
    let site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    tx.execute("DELETE FROM debt_aging_snapshots WHERE site_id = $1 AND as_of_date = $2", &[&site, &report.as_of_date])
        .await?;
    let mut written = 0;
    for b in &report.brackets {
        let unit = require_id("unit", &b.unit_id)?;
        written += tx
            .execute(
                r#"
                INSERT INTO debt_aging_snapshots (site_id, unit_id, debtor_type, current_due, overdue_1_30_days,
                    overdue_31_60_days, overdue_60_plus_days, accrued_delay_penalty, total_outstanding, as_of_date)
                SELECT $10, u.id, $2, $3, $4, $5, $6, $7, $8, $9 FROM units u WHERE u.id = $1 AND u.site_id = $10
                "#,
                &[
                    &unit,
                    &b.debtor_type,
                    &b.current_due,
                    &b.overdue_1_30_days,
                    &b.overdue_31_60_days,
                    &b.overdue_60_plus_days,
                    &b.accrued_delay_penalty,
                    &b.total_outstanding,
                    &report.as_of_date,
                    &site,
                ],
            )
            .await? as usize;
    }
    tx.commit().await?;
    Ok(written)
}
