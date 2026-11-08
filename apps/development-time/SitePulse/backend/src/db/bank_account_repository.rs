use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tracing::info;

use crate::models::{BankStatementFormat, SiteBankAccount};
use super::base::{parse_id_to_i64, require_id};
pub async fn save_site_bank_account(
    pool: &Pool,
    account: &SiteBankAccount,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let maybe_id = parse_id_to_i64(&account.id);
    let site_id_num = require_id("entity", &account.site_id)?;
    let config_by_num = account.configured_by.as_deref().and_then(parse_id_to_i64);

    match maybe_id {
        Some(id_num) if id_num > 0 => {
            client
                .execute(
                    r#"
                    INSERT INTO site_bank_accounts (id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                    ON CONFLICT (id) DO UPDATE SET
                        site_id = EXCLUDED.site_id,
                        bank_code = EXCLUDED.bank_code,
                        bank_name = EXCLUDED.bank_name,
                        iban = EXCLUDED.iban,
                        account_holder = EXCLUDED.account_holder,
                        statement_format = EXCLUDED.statement_format,
                        is_active = EXCLUDED.is_active,
                        configured_by = EXCLUDED.configured_by,
                        updated_at = CURRENT_TIMESTAMP
                    "#,
                    &[
                        &id_num,
                        &site_id_num,
                        &account.bank_code,
                        &account.bank_name,
                        &account.iban,
                        &account.account_holder,
                        &account.statement_format,
                        &account.is_active,
                        &config_by_num,
                        &account.created_at,
                        &account.updated_at,
                    ],
                )
                .await?;
            info!("Saved site bank account {} (numeric ID: {}) to PostgreSQL", account.id, id_num);
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                    RETURNING id
                    "#,
                    &[
                        &site_id_num,
                        &account.bank_code,
                        &account.bank_name,
                        &account.iban,
                        &account.account_holder,
                        &account.statement_format,
                        &account.is_active,
                        &config_by_num,
                        &account.created_at,
                        &account.updated_at,
                    ],
                )
                .await?;
            let new_id: i64 = row.get(0);
            info!("Saved site bank account (auto-assigned ID: {}) to PostgreSQL", new_id);
        }
    }
    Ok(())
}

pub async fn get_active_site_bank_account(
    pool: &Pool,
    site_id: &str,
) -> Result<Option<SiteBankAccount>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let row = client
        .query_opt(
            "SELECT id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at FROM site_bank_accounts WHERE site_id = $1 AND is_active = TRUE ORDER BY updated_at DESC LIMIT 1",
            &[&site_id_num],
        )
        .await?;

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: i64 = row.get(1);
        let bank_code: String = row.get(2);
        let bank_name: String = row.get(3);
        let iban: String = row.get(4);
        let account_holder: String = row.get(5);
        let statement_format: BankStatementFormat = row.get(6);
        let is_active: bool = row.get(7);
        let configured_by: Option<i64> = row.get(8);
        let created_at: Option<DateTime<Utc>> = row.get(9);
        let updated_at: Option<DateTime<Utc>> = row.get(10);

        return Ok(Some(SiteBankAccount {
            id: id.to_string(),
            site_id: site_id.to_string(),
            bank_code,
            bank_name,
            iban,
            account_holder,
            statement_format,
            is_active,
            configured_by: configured_by.map(|c| c.to_string()),
            created_at: created_at.unwrap_or_else(Utc::now),
            updated_at: updated_at.unwrap_or_else(Utc::now),
        }));
    }
    Ok(None)
}

