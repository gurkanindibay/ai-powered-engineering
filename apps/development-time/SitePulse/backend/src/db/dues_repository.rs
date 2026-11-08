use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{parse_id_to_i64, require_id, DbResult};
use crate::models::{DebtStatus, DuesLiability, DuesPeriodStatus};
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
            info!(
                "Saved dues period '{}' (numeric ID: {}) for site {} to PostgreSQL",
                period.period_name, id_num, period.site_id
            );
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
            info!(
                "Saved dues period '{}' (auto-assigned ID: {}) for site {} to PostgreSQL",
                period.period_name, new_id, period.site_id
            );
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
            INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty, penalty_accrued_through)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (id) DO UPDATE SET
                unit_id = EXCLUDED.unit_id,
                period = EXCLUDED.period,
                principal_amount = EXCLUDED.principal_amount,
                due_date = EXCLUDED.due_date,
                status = EXCLUDED.status,
                delay_penalty = EXCLUDED.delay_penalty,
                penalty_accrued_through = EXCLUDED.penalty_accrued_through
            "#,
            &[
                &due_id_num,
                &unit_id_num,
                &due.period,
                &due.principal_amount,
                &due.due_date,
                &status_str,
                &due.delay_penalty,
                &due.penalty_accrued_through,
            ],
        )
        .await?;
    info!(
        "Saved due liability {} (numeric ID: {}) for unit {} to PostgreSQL",
        due.id, due_id_num, unit_id_num
    );
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
    info!(
        "Updated dues liability {} (numeric ID: {}) to status {} in PostgreSQL",
        due_id, due_id_num, status
    );
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

/// Stores one debtor's advance balance of a unit (O-1: the in-memory model is per
/// debtor, so no re-split heuristic is needed). The change is written to
/// `advance_ledger_entries` so the balance stays tied to its ledger: payments and
/// transfers record their own typed entries in their transaction; a fall seen here
/// is the automatic advance offset (`OFFSET_APPLIED`), a rise is not backed by a
/// payment and is recorded as `ADJUSTMENT_CREDIT` (V16).
pub async fn save_advance_balance(
    pool: &Pool,
    unit_id: &str,
    debtor_type: &str,
    balance: Decimal,
) -> DbResult<()> {
    let unit = require_id("unit", unit_id)?;
    let debtor = if debtor_type.eq_ignore_ascii_case("OWNER") {
        "OWNER"
    } else {
        "TENANT"
    };
    if balance < Decimal::ZERO {
        return Err(format!(
            "advance balance of unit {} ({}) cannot be negative",
            unit_id, debtor
        )
        .into());
    }
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let current: Decimal = tx
        .query_opt(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2 FOR UPDATE",
            &[&unit, &debtor],
        )
        .await?
        .map(|r| r.get(0))
        .unwrap_or(Decimal::ZERO);
    let delta = balance - current;
    if delta != Decimal::ZERO {
        tx.execute(
            "INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
             ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance, updated_at = CURRENT_TIMESTAMP",
            &[&unit, &debtor, &balance],
        )
        .await?;
        let entry_type = if delta > Decimal::ZERO {
            "ADJUSTMENT_CREDIT"
        } else {
            "OFFSET_APPLIED"
        };
        tx.execute(
            "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description, created_at)
             VALUES ($1, $2, $3, $4, 'Advance balance change', CURRENT_TIMESTAMP)",
            &[&unit, &debtor, &entry_type, &delta.abs()],
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
                penalty_accrued_through = CASE WHEN $6::date IS NULL THEN penalty_accrued_through
                                               ELSE GREATEST(COALESCE(penalty_accrued_through, $6::date), $6::date) END,
                paid_principal = $3,
                paid_penalty   = $4,
                paid_amount    = $3 + $4,
                status         = $5,
                payment_date   = CASE WHEN $3 + $4 > paid_amount THEN CURRENT_TIMESTAMP ELSE payment_date END,
                version        = version + 1
            WHERE id = $1
            "#,
            &[&id, &due.delay_penalty, &due.paid_principal, &due.paid_penalty, &status, &due.penalty_accrued_through],
        )
        .await?;
    Ok(())
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

/// Ids of a site's units that currently have a tenant (operational dues are theirs).
/// An empty `site_id` means every site.
pub async fn tenanted_unit_ids(
    pool: &Pool,
    site_id: &str,
) -> DbResult<std::collections::HashSet<String>> {
    let site: i64 = if site_id.is_empty() {
        0
    } else {
        require_id("site", site_id)?
    };
    let client = pool.get().await?;
    let rows = client
        .query(
            "SELECT id FROM units WHERE ($1::bigint = 0 OR site_id = $1) AND tenant_person_id IS NOT NULL AND deleted_at IS NULL",
            &[&site],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| r.get::<_, i64>(0).to_string())
        .collect())
}

pub async fn fetch_debt_aging_report_from_db(
    pool: &Pool,
    site_id: &str,
) -> DbResult<crate::models::DebtAgingReport> {
    let client = pool.get().await?;
    let today = chrono::Utc::now().date_naive();

    let rows = if site_id != "all" && !site_id.is_empty() {
        let site_num = parse_id_to_i64(site_id).unwrap_or(0);
        client
            .query(
                r#"
                SELECT 
                    dl.id::text,
                    dl.unit_id::text,
                    dl.period,
                    dl.principal_amount,
                    dl.due_date,
                    dl.status,
                    dl.delay_penalty,
                    dl.paid_amount,
                    dl.paid_principal,
                    dl.paid_penalty,
                    dl.debtor_type,
                    dl.expense_type,
                    dl.penalty_accrued_through,
                    b.block_name,
                    u.unit_number,
                    COALESCE(
                        CASE WHEN dl.debtor_type = 'TENANT' THEN tp.full_name ELSE op.full_name END,
                        CASE WHEN dl.debtor_type = 'TENANT' THEN 'Kiracı' ELSE 'Kat Maliki' END
                    ) as resident_name
                FROM dues_liabilities dl
                JOIN units u ON dl.unit_id = u.id
                JOIN blocks b ON u.block_id = b.id
                LEFT JOIN persons op ON u.owner_person_id = op.id
                LEFT JOIN persons tp ON u.tenant_person_id = tp.id
                WHERE dl.status != 'PAID' AND dl.status != 'CANCELLED' AND u.site_id = $1
                "#,
                &[&site_num],
            )
            .await?
    } else {
        client
            .query(
                r#"
                SELECT 
                    dl.id::text,
                    dl.unit_id::text,
                    dl.period,
                    dl.principal_amount,
                    dl.due_date,
                    dl.status,
                    dl.delay_penalty,
                    dl.paid_amount,
                    dl.paid_principal,
                    dl.paid_penalty,
                    dl.debtor_type,
                    dl.expense_type,
                    dl.penalty_accrued_through,
                    b.block_name,
                    u.unit_number,
                    COALESCE(
                        CASE WHEN dl.debtor_type = 'TENANT' THEN tp.full_name ELSE op.full_name END,
                        CASE WHEN dl.debtor_type = 'TENANT' THEN 'Kiracı' ELSE 'Kat Maliki' END
                    ) as resident_name
                FROM dues_liabilities dl
                JOIN units u ON dl.unit_id = u.id
                JOIN blocks b ON u.block_id = b.id
                LEFT JOIN persons op ON u.owner_person_id = op.id
                LEFT JOIN persons tp ON u.tenant_person_id = tp.id
                WHERE dl.status != 'PAID' AND dl.status != 'CANCELLED'
                "#,
                &[],
            )
            .await?
    };

    let calc = crate::services::DuesCalculationService::new();
    let mut brackets_map: std::collections::HashMap<
        (String, crate::models::DebtorType),
        crate::models::DebtAgingBracket,
    > = std::collections::HashMap::new();

    for row in rows {
        let id: String = row.get(0);
        let unit_id: String = row.get(1);
        let period: String = row.get(2);
        let principal_amount: Decimal = row.get(3);
        let due_date: NaiveDate = row.get(4);
        let status_str: String = row.get(5);
        let delay_penalty: Decimal = row.get(6);
        let _paid_amount: Decimal = row.get(7);
        let paid_principal: Decimal = row.get(8);
        let paid_penalty: Decimal = row.get(9);
        let debtor_type_str: String = row.get(10);
        let expense_type_str: String = row.get(11);
        let penalty_accrued_through: Option<NaiveDate> = row.get(12);
        let block_name: String = row.get(13);
        let unit_number: i32 = row.get(14);
        let resident_name: String = row.get(15);

        let status = match status_str.as_str() {
            "PAID" => DebtStatus::Paid,
            "OVERDUE" => DebtStatus::Overdue,
            _ => DebtStatus::Pending,
        };
        let debtor_type = match debtor_type_str.as_str() {
            "OWNER" => crate::models::DebtorType::Owner,
            _ => crate::models::DebtorType::Tenant,
        };
        let expense_type = match expense_type_str.as_str() {
            "CAPITAL_DUES" => crate::models::ExpenseType::CapitalDues,
            _ => crate::models::ExpenseType::OperationalDues,
        };

        let stored = DuesLiability {
            id,
            unit_id: unit_id.clone(),
            period,
            principal_amount,
            delay_penalty,
            total_amount: principal_amount + delay_penalty,
            due_date,
            status,
            paid_principal,
            paid_penalty,
            debtor_type,
            expense_type,
            penalty_accrued_through,
        };

        let due = calc.calculate_delay_penalty(stored, today);
        let block_label = if block_name.to_lowercase().contains("blok") {
            block_name
        } else {
            format!("{} Blok", block_name)
        };
        let unit_label = format!("{} D:{}", block_label, unit_number);
        let key = (unit_id.clone(), debtor_type);

        let bracket = brackets_map
            .entry(key)
            .or_insert_with(|| crate::models::DebtAgingBracket {
                unit_id: unit_id.clone(),
                unit_label,
                resident_name,
                debtor_type,
                current_due: Decimal::ZERO,
                overdue_1_30_days: Decimal::ZERO,
                overdue_31_60_days: Decimal::ZERO,
                overdue_60_plus_days: Decimal::ZERO,
                accrued_delay_penalty: Decimal::ZERO,
                total_outstanding: Decimal::ZERO,
            });

        let principal_remaining = crate::services::dues_ledger::outstanding_principal(&due);
        let penalty = crate::services::dues_ledger::outstanding_penalty(&due);
        bracket.accrued_delay_penalty += penalty;

        let days_overdue = (today - due.due_date).num_days();
        if days_overdue <= 0 {
            bracket.current_due += principal_remaining;
        } else if days_overdue <= 30 {
            bracket.overdue_1_30_days += principal_remaining;
        } else if days_overdue <= 60 {
            bracket.overdue_31_60_days += principal_remaining;
        } else {
            bracket.overdue_60_plus_days += principal_remaining;
        }

        bracket.total_outstanding += principal_remaining + penalty;
    }

    let mut brackets: Vec<crate::models::DebtAgingBracket> = brackets_map.into_values().collect();
    brackets.sort_by_key(|b| std::cmp::Reverse(b.total_outstanding));

    let total_current: Decimal = brackets.iter().map(|b| b.current_due).sum();
    let total_1_30_days: Decimal = brackets.iter().map(|b| b.overdue_1_30_days).sum();
    let total_31_60_days: Decimal = brackets.iter().map(|b| b.overdue_31_60_days).sum();
    let total_60_plus_days: Decimal = brackets.iter().map(|b| b.overdue_60_plus_days).sum();
    let total_penalty: Decimal = brackets.iter().map(|b| b.accrued_delay_penalty).sum();
    let grand_total: Decimal = brackets.iter().map(|b| b.total_outstanding).sum();

    Ok(crate::models::DebtAgingReport {
        as_of_date: today,
        total_current,
        total_1_30_days,
        total_31_60_days,
        total_60_plus_days,
        total_penalty,
        grand_total,
        brackets,
    })
}
