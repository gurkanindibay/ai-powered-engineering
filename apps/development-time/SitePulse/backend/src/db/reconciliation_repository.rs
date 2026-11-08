use chrono::NaiveDate;
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{parse_id_to_i64, require_id, DbResult};
use crate::models::{BankTransactionItem, ReconciliationMatch, ReconciliationStatus};
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
    info!(
        "Updated reconciliation match {} status to {} in PostgreSQL",
        match_id, code
    );
    Ok(())
}

pub async fn fetch_reconciliation_queue_from_db(
    pool: &Pool,
    site_id: Option<&str>,
) -> DbResult<Vec<ReconciliationMatch>> {
    let client = pool.get().await?;
    let rows = if let Some(sid) = site_id {
        let site_num = parse_id_to_i64(sid).unwrap_or(0);
        client
            .query(
                "SELECT match_id, transaction_id, txn_date, amount, currency, description, \
                 sender_name, sender_iban, reference_no, matched_unit_id, matched_block, \
                 matched_unit_number, matched_resident_name, confidence_score, matched_due_id, \
                 outstanding_balance, amount_matches_balance, status, notes, site_id \
                 FROM reconciliation_queue WHERE site_id = $1 ORDER BY txn_date ASC",
                &[&site_num],
            )
            .await?
    } else {
        client
            .query(
                "SELECT match_id, transaction_id, txn_date, amount, currency, description, \
                 sender_name, sender_iban, reference_no, matched_unit_id, matched_block, \
                 matched_unit_number, matched_resident_name, confidence_score, matched_due_id, \
                 outstanding_balance, amount_matches_balance, status, notes, site_id \
                 FROM reconciliation_queue ORDER BY txn_date ASC",
                &[],
            )
            .await?
    };

    let mut list = Vec::new();
    for row in rows {
        let match_id: String = row.get(0);
        let transaction_id: String = row.get(1);
        let txn_date: NaiveDate = row.get(2);
        let amount: Decimal = row.get(3);
        let currency: String = row.get(4);
        let description: String = row.get(5);
        let sender_name: Option<String> = row.get(6);
        let sender_iban: Option<String> = row.get(7);
        let reference_no: Option<String> = row.get(8);
        let matched_unit_id: Option<i64> = row.get(9);
        let matched_block: Option<String> = row.get(10);
        let matched_unit_number: Option<i32> = row.get(11);
        let matched_resident_name: Option<String> = row.get(12);
        let confidence_score: i32 = row.get(13);
        let matched_due_id: Option<i64> = row.get(14);
        let outstanding_balance: Option<Decimal> = row.get(15);
        let amount_matches_balance: bool = row.get(16);
        let status_str: String = row.get(17);
        let notes: Option<String> = row.get(18);
        let site_id_num: Option<i64> = row.get(19);
        let s_id = site_id_num
            .map(|s| s.to_string())
            .unwrap_or_else(|| "1".to_string());

        let status = ReconciliationStatus::from_db_code(&status_str);
        let status_code = status.as_str().to_string();

        list.push(ReconciliationMatch {
            match_id,
            site_id: s_id,
            transaction: BankTransactionItem {
                transaction_id,
                date: txn_date,
                amount,
                currency,
                description,
                sender_name,
                sender_iban,
                reference_no,
            },
            matched_unit_id: matched_unit_id.map(|v| v.to_string()),
            matched_block,
            matched_unit_number,
            matched_resident_name,
            confidence_score: confidence_score as u8,
            matched_due_id: matched_due_id.map(|v| v.to_string()),
            outstanding_balance,
            amount_matches_balance,
            status,
            status_code,
            notes,
        });
    }
    Ok(list)
}
