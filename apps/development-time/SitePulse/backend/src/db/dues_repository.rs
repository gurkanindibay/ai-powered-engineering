use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use crate::models::{DebtStatus, DuesLiability, DuesPeriodStatus};
use super::base::{parse_id_to_i64, require_id, DbResult};
pub async fn save_dues_period(
    pool: &Pool,
    period: &crate::models::DuesPeriod,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &period.site_id)?;
    let maybe_id = parse_id_to_i64(&period.id);

    match maybe_id {
        Some(id_num) if id_num > 0 => {
            client
                .execute(
                    r#"
                    INSERT INTO dues_periods (id, site_id, period_name, due_date, status)
                    VALUES ($1, $2, $3, $4, $5)
                    ON CONFLICT (site_id, period_name) DO UPDATE SET
                        due_date = EXCLUDED.due_date,
                        status = EXCLUDED.status
                    "#,
                    &[
                        &id_num,
                        &site_id_num,
                        &period.period_name,
                        &period.due_date,
                        &period.status,
                    ],
                )
                .await?;
            info!("Saved dues period '{}' (numeric ID: {}) for site {} to PostgreSQL", period.period_name, id_num, period.site_id);
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO dues_periods (site_id, period_name, due_date, status)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (site_id, period_name) DO UPDATE SET
                        due_date = EXCLUDED.due_date,
                        status = EXCLUDED.status
                    RETURNING id
                    "#,
                    &[
                        &site_id_num,
                        &period.period_name,
                        &period.due_date,
                        &period.status,
                    ],
                )
                .await?;
            let new_id: i64 = row.get(0);
            info!("Saved dues period '{}' (auto-assigned ID: {}) for site {} to PostgreSQL", period.period_name, new_id, period.site_id);
        }
    }
    Ok(())
}

#[allow(dead_code)]
pub async fn get_dues_periods_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<crate::models::DuesPeriod>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let rows = client
        .query(
            "SELECT id, site_id, period_name, due_date, status, created_at FROM dues_periods WHERE site_id = $1 ORDER BY due_date ASC",
            &[&site_id_num],
        )
        .await?;
    let mut list = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let s_id: i64 = row.get(1);
        let period_name: String = row.get(2);
        let due_date: NaiveDate = row.get(3);
        let status: DuesPeriodStatus = row.get(4);
        let created_at: Option<DateTime<Utc>> = row.get(5);
        list.push(crate::models::DuesPeriod {
            id: id.to_string(),
            site_id: s_id.to_string(),
            period_name,
            due_date,
            status,
            created_at,
        });
    }
    Ok(list)
}

pub async fn save_due_liability(
    pool: &Pool,
    due: &DuesLiability,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let status_str = match due.status {
        DebtStatus::Paid => "PAID",
        DebtStatus::Overdue => "OVERDUE",
        DebtStatus::Pending => "PENDING",
    };
    let due_id_num = require_id("entity", &due.id)?;
    let unit_id_num = require_id("entity", &due.unit_id)?;

    client
        .execute(
            r#"
            INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (id) DO UPDATE SET
                unit_id = EXCLUDED.unit_id,
                period = EXCLUDED.period,
                principal_amount = EXCLUDED.principal_amount,
                due_date = EXCLUDED.due_date,
                status = EXCLUDED.status,
                delay_penalty = EXCLUDED.delay_penalty
            "#,
            &[
                &due_id_num,
                &unit_id_num,
                &due.period,
                &due.principal_amount,
                &due.due_date,
                &status_str,
                &due.delay_penalty,
            ],
        )
        .await?;
    info!("Saved due liability {} (numeric ID: {}) for unit {} to PostgreSQL", due.id, due_id_num, unit_id_num);
    Ok(())
}

pub async fn update_due_liability(
    pool: &Pool,
    due_id: &str,
    status: &str,
    paid_amount: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let due_id_num = require_id("entity", due_id)?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET status = $2,
                paid_amount = CASE 
                    WHEN $3 > 0::numeric THEN LEAST(paid_amount + $3, principal_amount + delay_penalty)
                    WHEN $2 = 'PAID' THEN principal_amount + delay_penalty
                    ELSE paid_amount
                END,
                paid_principal = CASE
                    WHEN $3 > 0::numeric THEN LEAST(paid_principal + $3, principal_amount)
                    WHEN $2 = 'PAID' THEN principal_amount
                    ELSE paid_principal
                END,
                payment_date = CURRENT_TIMESTAMP
            WHERE id = $1
            "#,
            &[&due_id_num, &status, &paid_amount],
        )
        .await?;
    info!("Updated dues liability {} (numeric ID: {}) to status {} in PostgreSQL", due_id, due_id_num, status);
    Ok(())
}

pub async fn record_due_allocation(
    pool: &Pool,
    due_id_num: i64,
    allocated_principal: Decimal,
    allocated_penalty: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET paid_principal = LEAST(paid_principal + $2, principal_amount),
                paid_penalty = LEAST(paid_penalty + $3, delay_penalty),
                paid_amount = LEAST(paid_amount + $2 + $3, principal_amount + delay_penalty),
                status = CASE
                    WHEN (paid_principal + $2 >= principal_amount) AND (paid_penalty + $3 >= delay_penalty) THEN 'PAID'
                    ELSE 'PARTIALLY_PAID'
                END,
                payment_date = CURRENT_TIMESTAMP
            WHERE id = $1
            "#,
            &[&due_id_num, &allocated_principal, &allocated_penalty],
        )
        .await?;
    Ok(())
}


/// Stores a unit's total advance balance without touching other debtors' credit.
///
/// `advance_balances` is per (unit, debtor_type) while the in-memory view keeps one
/// total per unit. The TENANT bucket is set so that all buckets add up to `total`
/// (owner credit is never overwritten), and every change is written to
/// `advance_ledger_entries` so the balance stays tied to its ledger.
pub async fn save_advance_balance(pool: &Pool, unit_id: &str, total: Decimal) -> DbResult<()> {
    let unit = require_id("unit", unit_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let rows = tx
        .query("SELECT debtor_type, balance FROM advance_balances WHERE unit_id = $1 FOR UPDATE", &[&unit])
        .await?;
    let mut tenant = Decimal::ZERO;
    let mut owner = Decimal::ZERO;
    for r in rows {
        let kind: String = r.get(0);
        let bal: Decimal = r.get(1);
        if kind == "TENANT" { tenant = bal } else { owner += bal }
    }
    if total >= owner {
        let new_tenant = total - owner;
        let delta = new_tenant - tenant;
        if delta != Decimal::ZERO {
            tx.execute(
                "INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at) VALUES ($1, 'TENANT', $2, CURRENT_TIMESTAMP)
                 ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance, updated_at = CURRENT_TIMESTAMP",
                &[&unit, &new_tenant],
            )
            .await?;
            let entry_type = if delta > Decimal::ZERO { "PAYMENT_SURPLUS" } else { "OFFSET_APPLIED" };
            tx.execute(
                "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description, created_at)
                 VALUES ($1, 'TENANT', $2, $3, 'Advance balance change', CURRENT_TIMESTAMP)",
                &[&unit, &entry_type, &delta.abs()],
            )
            .await?;
        }
    } else {
        if tenant != Decimal::ZERO {
            let zero = Decimal::ZERO;
            tx.execute(
                "INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at) VALUES ($1, 'TENANT', $2, CURRENT_TIMESTAMP)
                 ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance, updated_at = CURRENT_TIMESTAMP",
                &[&unit, &zero],
            )
            .await?;
            tx.execute(
                "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description, created_at)
                 VALUES ($1, 'TENANT', 'OFFSET_APPLIED', $2, 'Advance balance change', CURRENT_TIMESTAMP)",
                &[&unit, &tenant],
            )
            .await?;
        }
        let delta_owner = total - owner;
        tx.execute(
            "INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at) VALUES ($1, 'OWNER', $2, CURRENT_TIMESTAMP)
             ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance, updated_at = CURRENT_TIMESTAMP",
            &[&unit, &total],
        )
        .await?;
        let entry_type = if delta_owner > Decimal::ZERO { "PAYMENT_SURPLUS" } else { "OFFSET_APPLIED" };
        tx.execute(
            "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description, created_at)
             VALUES ($1, 'OWNER', $2, $3, 'Advance balance change', CURRENT_TIMESTAMP)",
            &[&unit, &entry_type, &delta_owner.abs()],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

/// Writes a liability's payment state (absolute values from the ledger).
pub async fn sync_due_payment_state(pool: &Pool, due: &DuesLiability) -> DbResult<()> {
    let id = require_id("dues liability", &due.id)?;
    let status = match due.status {
        DebtStatus::Paid => "PAID",
        _ if due.paid_principal + due.paid_penalty > Decimal::ZERO => "PARTIALLY_PAID",
        DebtStatus::Overdue => "OVERDUE",
        DebtStatus::Pending => "PENDING",
    };
    let client = pool.get().await?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET delay_penalty  = GREATEST(delay_penalty, $2, $4),
                paid_principal = $3,
                paid_penalty   = $4,
                paid_amount    = $3 + $4,
                status         = $5,
                payment_date   = CASE WHEN $3 + $4 > paid_amount THEN CURRENT_TIMESTAMP ELSE payment_date END,
                version        = version + 1
            WHERE id = $1
            "#,
            &[&id, &due.delay_penalty, &due.paid_principal, &due.paid_penalty, &status],
        )
        .await?;
    Ok(())
}

pub async fn save_advance_balance_with_type(
    pool: &Pool,
    unit_id: &str,
    debtor_type: &str,
    balance: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    client
        .execute(
            r#"
            INSERT INTO advance_balances (unit_id, balance, debtor_type, updated_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id, debtor_type) DO UPDATE SET
                balance = EXCLUDED.balance,
                updated_at = CURRENT_TIMESTAMP
            "#,
            &[&unit_id_num, &balance, &debtor_type],
        )
        .await?;
    info!("Saved advance balance (₺{}) for unit {} ({}) to PostgreSQL", balance, unit_id, debtor_type);
    Ok(())
}

pub async fn save_advance_ledger_entry(
    pool: &Pool,
    unit_id: &str,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference_id: Option<&str>,
    description: Option<&str>,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    let row = client
        .query_one(
            r#"
            INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)
            RETURNING id
            "#,
            &[&unit_id_num, &debtor_type, &entry_type, &amount, &reference_id, &description],
        )
        .await?;
    let entry_id: i64 = row.get(0);
    Ok(entry_id)
}


/// Inserts an accrued liability and returns its id, or `None` when the unit
/// already has one for this period and expense type (`uq_unit_period_expense`).
pub async fn insert_accrued_due(pool: &Pool, due: &DuesLiability) -> DbResult<Option<i64>> {
    let unit = require_id("unit", &due.unit_id)?;
    let client = pool.get().await?;
    let row = client
        .query_opt(
            r#"
            INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type)
            VALUES ($1, $2, $3, $4, 'PENDING', 0, $5, $6)
            ON CONFLICT (unit_id, period, expense_type) WHERE capital_project_id IS NULL DO NOTHING
            RETURNING id
            "#,
            &[&unit, &due.period, &due.principal_amount, &due.due_date, &due.debtor_type, &due.expense_type],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

