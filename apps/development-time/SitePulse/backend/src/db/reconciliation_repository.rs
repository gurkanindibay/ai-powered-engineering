use deadpool_postgres::Pool;
use tracing::info;

use crate::models::ReconciliationMatch;
use super::base::{parse_id_to_i64, require_id};
pub async fn save_reconciliation_match_for_site(
    pool: &Pool,
    m: &ReconciliationMatch,
    site_id: &str,
    bank_account_id: Option<i64>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let status_str = m.status.db_code();
    let confidence_i32 = m.confidence_score as i32;
    let matched_unit_num = m.matched_unit_id.as_deref().and_then(parse_id_to_i64);
    let matched_due_num = m.matched_due_id.as_deref().and_then(parse_id_to_i64);
    let site_id_num = require_id("entity", site_id)?;
    client
        .execute(
            r#"
            INSERT INTO reconciliation_queue (
                match_id, transaction_id, txn_date, amount, currency, description,
                sender_name, sender_iban, reference_no, matched_unit_id, matched_block,
                matched_unit_number, matched_resident_name, confidence_score, matched_due_id,
                outstanding_balance, amount_matches_balance, status, notes,
                site_id, site_bank_account_id, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, CURRENT_TIMESTAMP)
            ON CONFLICT (match_id) DO UPDATE SET
                status = EXCLUDED.status,
                notes = EXCLUDED.notes
            "#,
            &[
                &m.match_id,
                &m.transaction.transaction_id,
                &m.transaction.date,
                &m.transaction.amount,
                &m.transaction.currency,
                &m.transaction.description,
                &m.transaction.sender_name,
                &m.transaction.sender_iban,
                &m.transaction.reference_no,
                &matched_unit_num,
                &m.matched_block,
                &m.matched_unit_number,
                &m.matched_resident_name,
                &confidence_i32,
                &matched_due_num,
                &m.outstanding_balance,
                &m.amount_matches_balance,
                &status_str,
                &m.notes,
                &site_id_num,
                &bank_account_id,
            ],
        )
        .await?;
    info!("Saved reconciliation match {} to PostgreSQL", m.match_id);
    Ok(())
}

pub async fn save_reconciliation_match(
    pool: &Pool,
    m: &ReconciliationMatch,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // The site is derived from the matched unit; never defaulted to site 1.
    let unit = m
        .matched_unit_id
        .as_deref()
        .ok_or("reconciliation match has no unit; use save_reconciliation_match_for_site")?;
    let unit_id = require_id("unit", unit)?;
    let client = pool.get().await?;
    let site: i64 = client
        .query_opt("SELECT site_id FROM units WHERE id = $1", &[&unit_id])
        .await?
        .and_then(|r| r.get::<_, Option<i64>>(0))
        .ok_or_else(|| format!("unit {} has no site", unit_id))?;
    drop(client);
    save_reconciliation_match_for_site(pool, m, &site.to_string(), None).await
}


pub async fn update_reconciliation_status(
    pool: &Pool,
    match_id: &str,
    status: crate::models::ReconciliationStatus,
    notes: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let code = status.db_code();
    client
        .execute(
            "UPDATE reconciliation_queue SET status = $2, notes = COALESCE($3, notes) WHERE match_id = $1",
            &[&match_id, &code, &notes],
        )
        .await?;
    info!("Updated reconciliation match {} status to {} in PostgreSQL", match_id, code);
    Ok(())
}

