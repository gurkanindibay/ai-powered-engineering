//! Writes of an approved accrual correction (STORY-07-11).
//!
//! The liability change, the replacement liability and the advance credit are
//! one transaction: either the whole correction is stored or none of it.

use deadpool_postgres::Pool;
use rust_decimal::Decimal;

use super::payment_repository::tx_credit_advance;
use super::{require_id, DbResult};
use crate::models::{AccrualCorrection, DuesLiability};

/// What an approved correction does to the database.
pub struct CorrectionWrite<'a> {
    pub site_id: &'a str,
    pub due_id: &'a str,
    pub unit_id: &'a str,
    /// `OWNER` or `TENANT`: whose advance balance receives `advance_credit`.
    pub debtor_type: &'a str,
    /// `true`: the liability is set to CANCELLED and its amounts stay as they were.
    pub cancel: bool,
    /// The owed and paid amounts after a credit note (ignored when `cancel`).
    pub principal: Decimal,
    pub penalty: Decimal,
    pub paid_principal: Decimal,
    pub paid_penalty: Decimal,
    pub advance_credit: Decimal,
    /// Reference stored on the advance ledger entry (`KOR-<id>`).
    pub reference: &'a str,
    pub description: &'a str,
    /// The corrected liability of a re-issue.
    pub replacement: Option<&'a DuesLiability>,
    /// The correction being approved, with its decision and snapshot fields set.
    pub correction: &'a AccrualCorrection,
}

/// How an approval ended.
pub enum Approval {
    /// Applied; the id of the replacement liability, if any.
    Applied(Option<i64>),
    /// Another approval or rejection won; nothing was changed.
    AlreadyDecided,
}

/// Rejects a pending correction. Returns `false` when it was no longer pending.
pub async fn reject_accrual_correction(
    pool: &Pool,
    correction: &AccrualCorrection,
) -> DbResult<bool> {
    let client = pool.get().await?;
    let changed = client
        .execute(
            "UPDATE accrual_corrections
             SET status = 'REJECTED', decided_by = $2, decided_at = $3, decision_note = $4
             WHERE id = $1 AND status = 'PENDING'",
            &[
                &correction.id,
                &correction.decided_by,
                &correction.decided_at,
                &correction.decision_note,
            ],
        )
        .await?;
    Ok(changed == 1)
}

/// Approves the correction and applies it, all in one transaction. The first
/// statement claims the correction (`PENDING` to `APPROVED`); a concurrent or
/// repeated approval finds no pending row and changes nothing, so the liability
/// change and the advance credit happen exactly once.
pub async fn apply_accrual_correction(
    pool: &Pool,
    write: &CorrectionWrite<'_>,
) -> DbResult<Approval> {
    let site = require_id("site", write.site_id)?;
    let due = require_id("dues liability", write.due_id)?;
    let unit = require_id("unit", write.unit_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;

    let c = write.correction;
    let claimed = tx
        .execute(
            r#"
            UPDATE accrual_corrections
            SET status = 'APPROVED', decided_by = $2, decided_at = $3, decision_note = $4,
                principal_before = $5, penalty_before = $6, paid_before = $7,
                penalty_reversed = $8, advance_credited = $9
            WHERE id = $1 AND status = 'PENDING'
            "#,
            &[
                &c.id,
                &c.decided_by,
                &c.decided_at,
                &c.decision_note,
                &c.principal_before,
                &c.penalty_before,
                &c.paid_before,
                &c.penalty_reversed,
                &c.advance_credited,
            ],
        )
        .await?;
    if claimed != 1 {
        return Ok(Approval::AlreadyDecided);
    }

    let changed = if write.cancel {
        tx.execute(
            "UPDATE dues_liabilities SET status = 'CANCELLED', version = version + 1
             WHERE id = $1 AND status <> 'CANCELLED'",
            &[&due],
        )
        .await?
    } else {
        let paid = write.paid_principal + write.paid_penalty;
        tx.execute(
            r#"
            UPDATE dues_liabilities
            SET principal_amount = $2::numeric,
                delay_penalty = $3::numeric,
                paid_principal = $4::numeric,
                paid_penalty = $5::numeric,
                paid_amount = $6::numeric,
                status = CASE
                    WHEN $4::numeric >= $2::numeric AND $5::numeric >= $3::numeric THEN 'PAID'
                    WHEN $6::numeric > 0 THEN 'PARTIALLY_PAID'
                    WHEN status = 'PAID' THEN 'PENDING'
                    ELSE status END,
                version = version + 1
            WHERE id = $1 AND status <> 'CANCELLED'
            "#,
            &[
                &due,
                &write.principal,
                &write.penalty,
                &write.paid_principal,
                &write.paid_penalty,
                &paid,
            ],
        )
        .await?
    };
    if changed != 1 {
        return Err(format!(
            "Liability {} was not corrected: it does not exist or is already cancelled",
            write.due_id
        )
        .into());
    }

    if write.advance_credit > Decimal::ZERO {
        tx_credit_advance(
            &tx,
            unit,
            write.debtor_type,
            "ADJUSTMENT_CREDIT",
            write.advance_credit,
            Some(write.reference),
            Some(write.description),
        )
        .await?;
    }

    let replacement_id = match write.replacement {
        Some(r) => {
            let row = tx
                .query_one(
                    r#"
                    INSERT INTO dues_liabilities
                        (unit_id, period, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type)
                    VALUES ($1, $2, $3, $4, 'PENDING', 0, $5, $6)
                    RETURNING id
                    "#,
                    &[
                        &unit,
                        &r.period,
                        &r.principal_amount,
                        &r.due_date,
                        &r.debtor_type,
                        &r.expense_type,
                    ],
                )
                .await?;
            Some(row.get::<_, i64>(0))
        }
        None => None,
    };
    if let Some(id) = replacement_id {
        tx.execute(
            "UPDATE accrual_corrections SET replacement_due_id = $2 WHERE id = $1",
            &[&c.id, &id],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(Approval::Applied(replacement_id))
}
