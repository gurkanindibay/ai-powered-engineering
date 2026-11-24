use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use std::collections::HashSet;
use tracing::info;

use super::base::{parse_id_to_i64, require_id, DbResult};
use crate::models::{CapitalDuesSummaryDto, DebtStatus, DuesLiability, DuesPeriodStatus};

/// Reads one unit's outstanding capital liabilities grouped by project.
pub async fn fetch_unit_capital_dues_from_db(
    pool: &Pool,
    site_id: &str,
    unit_id: &str,
) -> DbResult<Vec<CapitalDuesSummaryDto>> {
    let invalid_id = |kind: &str| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("Invalid {kind} identifier"),
        )
    };
    let site_id = parse_id_to_i64(site_id).ok_or_else(|| invalid_id("site"))?;
    let unit_id = parse_id_to_i64(unit_id).ok_or_else(|| invalid_id("unit"))?;
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_tenant_read(&mut client, site_id).await?;
    let rows = tx
        .query(
            r#"
            SELECT cp.id::text, cp.title,
                   COALESCE(SUM(GREATEST(
                       dl.principal_amount + dl.delay_penalty
                       - dl.paid_principal - dl.paid_penalty, 0
                   )), 0)::numeric AS outstanding_balance
            FROM capital_projects cp
            LEFT JOIN dues_liabilities dl
              ON dl.capital_project_id = cp.id
             AND dl.unit_id = $2
             AND dl.status <> 'CANCELLED'
            WHERE cp.site_id = $1
            GROUP BY cp.id, cp.title
            HAVING COALESCE(SUM(GREATEST(
                       dl.principal_amount + dl.delay_penalty
                       - dl.paid_principal - dl.paid_penalty, 0
                   )), 0) > 0
            ORDER BY cp.title
            "#,
            &[&site_id, &unit_id],
        )
        .await?;
    let summaries = rows
        .iter()
        .map(|row| CapitalDuesSummaryDto {
            project_id: row.get(0),
            project_title: row.get(1),
            outstanding_balance: row.get(2),
        })
        .collect();
    tx.commit().await?;
    Ok(summaries)
}

pub async fn save_dues_period(
    pool: &Pool,
    period: &crate::models::DuesPeriod,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &period.site_id)?;
    let maybe_id = parse_id_to_i64(&period.id);
    let period_key = crate::domain::billing_period::BillingPeriod::parse(&period.period_name)
        .ok()
        .map(|p| p.key());

    match maybe_id {
        Some(id_num) if id_num > 0 => {
            client
                .execute(
                    r#"
                    INSERT INTO dues_periods (id, site_id, period_name, period_key, due_date, status)
                    VALUES ($1, $2, $3, $4, $5, $6)
                    ON CONFLICT (site_id, period_name) DO UPDATE SET
                        due_date = EXCLUDED.due_date,
                        status = EXCLUDED.status
                    "#,
                    &[
                        &id_num,
                        &site_id_num,
                        &period.period_name,
                        &period_key,
                        &period.due_date,
                        &period.status,
                    ],
                )
                .await?;
            // An explicit id leaves the identity sequence behind; later default inserts
            // (the accrual batch) would collide with it.
            client
                .execute(
                    "SELECT setval(pg_get_serial_sequence('dues_periods', 'id'), (SELECT COALESCE(MAX(id), 1) FROM dues_periods))",
                    &[],
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
                    INSERT INTO dues_periods (site_id, period_name, period_key, due_date, status)
                    VALUES ($1, $2, $3, $4, $5)
                    ON CONFLICT (site_id, period_name) DO UPDATE SET
                        due_date = EXCLUDED.due_date,
                        status = EXCLUDED.status
                    RETURNING id
                    "#,
                    &[
                        &site_id_num,
                        &period.period_name,
                        &period_key,
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
        DebtStatus::Cancelled => "CANCELLED",
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

/// Inserts an accrued liability and returns its id, or `None` when the unit
/// already has one for this period and expense type. The canonical period key is set
/// when the label is a month.
pub async fn insert_accrued_due(
    pool: &Pool,
    due: &DuesLiability,
    site_id: &str,
) -> DbResult<Option<i64>> {
    let unit = require_id("unit", &due.unit_id)?;
    let site = require_id("site", site_id)?;
    let key = crate::domain::billing_period::BillingPeriod::parse(&due.period)
        .ok()
        .map(|p| p.key());
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;
    // The unique index ignores cancelled rows (a re-issue replaces one), but
    // accrual never charges a period again once any liability of it exists.
    let existing = tx
        .query_opt(
            "SELECT 1 FROM dues_liabilities
             WHERE unit_id = $1
               AND (period_key = $2 OR (period_key IS NULL AND period = $3))
               AND expense_type = $4 AND capital_project_id IS NULL",
            &[&unit, &key, &due.period, &due.expense_type],
        )
        .await?;
    if existing.is_some() {
        tx.rollback().await?;
        return Ok(None);
    }
    let row = tx
        .query_opt(
            r#"
            INSERT INTO dues_liabilities (unit_id, period, period_key, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type, grace_days, effective_due_date, liable_person_id)
            VALUES ($1, $2, $3, $4, $5, 'PENDING', 0, $6::text, $7, $8, $9,
                    COALESCE($10, CASE WHEN $6::text = 'TENANT' THEN (SELECT tenant_person_id FROM units WHERE id = $1) ELSE (SELECT owner_person_id FROM units WHERE id = $1) END))
            ON CONFLICT DO NOTHING
            RETURNING id
            "#,
            &[&unit, &due.period, &key, &due.principal_amount, &due.due_date, &due.debtor_type, &due.expense_type, &i32::try_from(due.grace_days).unwrap_or(0), &due.fee_due_date(), &due.liable_person_id],
        )
        .await?;
    let Some(row) = row else {
        tx.commit().await?;
        return Ok(None);
    };
    let due_id: i64 = row.get(0);
    if due.debtor_type == crate::models::DebtorType::Tenant {
        let unit_row = tx
            .query_one(
                "SELECT site_id, tenant_person_id FROM units WHERE id = $1",
                &[&unit],
            )
            .await?;
        let site: i64 = unit_row.get(0);
        let tenant_person_id: Option<i64> = unit_row.get(1);
        let period = crate::domain::billing_period::BillingPeriod::parse(&due.period)
            .unwrap_or_else(|_| {
                crate::domain::billing_period::BillingPeriod::of_date(due.due_date)
            });
        let start = period.first_day();
        let end = period.last_day();
        let owners = tx
            .query(
                r#"
                SELECT person_id, GREATEST(start_date, $2::date),
                       LEAST(COALESCE(end_date - 1, $3::date), $3::date)
                FROM unit_ownerships
                WHERE unit_id = $1 AND start_date <= $3
                  AND COALESCE(end_date, 'infinity'::date) >= $2
                  AND GREATEST(start_date, $2::date) <= LEAST(COALESCE(end_date - 1, $3::date), $3::date)
                ORDER BY start_date, person_id
                "#,
                &[&unit, &start, &end],
            )
            .await?;
        for owner in owners {
            let owner_person_id: i64 = owner.get(0);
            let liable_from: NaiveDate = owner.get(1);
            let liable_through: NaiveDate = owner.get(2);
            tx.execute(
                r#"
                INSERT INTO dues_liability_joint_owners
                    (site_id, due_id, owner_person_id, tenant_person_id, liable_from, liable_through)
                VALUES ($1, $2, $3, $4, $5, $6)
                ON CONFLICT (due_id, owner_person_id, liable_from, liable_through) DO NOTHING
                "#,
                &[
                    &site,
                    &due_id,
                    &owner_person_id,
                    &tenant_person_id,
                    &liable_from,
                    &liable_through,
                ],
            )
            .await?;
        }
    }
    tx.commit().await?;
    Ok(Some(due_id))
}

pub async fn load_joint_liability_owners(
    pool: &Pool,
    due_id: &str,
    site_id: &str,
) -> DbResult<Vec<crate::models::JointLiabilityOwner>> {
    let due = require_id("dues liability", due_id)?;
    let site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;
    let rows = tx
        .query(
            "SELECT owner_person_id, tenant_person_id, liable_from, liable_through FROM dues_liability_joint_owners WHERE due_id = $1 ORDER BY liable_from, owner_person_id",
            &[&due],
        )
        .await?;
    let owners = rows
        .iter()
        .map(|row| crate::models::JointLiabilityOwner {
            person_id: row.get(0),
            tenant_person_id: row.get(1),
            start_date: row.get(2),
            end_date: Some(row.get(3)),
        })
        .collect();
    tx.commit().await?;
    Ok(owners)
}

/// One supplementary charge to persist: the liability (posted in `due.period`) and the key of
/// the month it bills.
pub struct SupplementaryInsert<'a> {
    pub due: &'a DuesLiability,
    pub source_period_key: &'a str,
}

/// Persists supplementary charges (STORY-07-13) in one transaction and returns each new id,
/// or `None` where an identical charge already exists. The charge is linked to the billing
/// period row it is posted in, when that row exists.
pub async fn insert_supplementary_dues(
    pool: &Pool,
    site_id: &str,
    charges: &[SupplementaryInsert<'_>],
) -> DbResult<Vec<Option<i64>>> {
    let site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;
    let mut ids = Vec::with_capacity(charges.len());
    for charge in charges {
        let due = charge.due;
        let unit = require_id("unit", &due.unit_id)?;
        let key = crate::domain::billing_period::BillingPeriod::parse(&due.period)
            .ok()
            .map(|period| period.key());
        let row = tx
            .query_opt(
                r#"
                INSERT INTO dues_liabilities
                    (unit_id, period, period_key, dues_period_id, principal_amount, due_date, status,
                     delay_penalty, debtor_type, expense_type, grace_days, source_period,
                     effective_due_date)
                VALUES ($1, $2, $3,
                        (SELECT id FROM dues_periods WHERE site_id = $4 AND period_key = $3),
                        $5, $6, 'PENDING', 0, $7, $8, $9, $10, $11)
                ON CONFLICT DO NOTHING
                RETURNING id
                "#,
                &[
                    &unit,
                    &due.period,
                    &key,
                    &site,
                    &due.principal_amount,
                    &due.due_date,
                    &due.debtor_type,
                    &due.expense_type,
                    &i32::try_from(due.grace_days).unwrap_or(0),
                    &charge.source_period_key,
                    &due.effective_due_date,
                ],
            )
            .await?;
        ids.push(row.map(|r| r.get::<_, i64>(0)));
    }
    tx.commit().await?;
    Ok(ids)
}

/// What one site's accrual commits: the period row, every liability with its budget
/// basis, and the run report, in a single transaction.
pub struct AccrualBatch<'a> {
    pub site_id: &'a str,
    pub period_key: &'a str,
    pub period_label: &'a str,
    pub due_date: NaiveDate,
    /// `MANUAL` or `SCHEDULER`.
    pub source: &'a str,
    pub dues: &'a [(DuesLiability, Option<String>)],
    pub skipped: &'a [String],
}

/// The committed result of an accrual batch.
pub struct CommittedAccrual {
    /// The period row, absent when the batch had nothing to accrue.
    pub period_id: Option<i64>,
    /// The new id per input liability, `None` when the unit already had one for the period.
    pub due_ids: Vec<Option<i64>>,
    /// Jointly liable owners and date ranges for newly created tenant liabilities.
    pub joint_owners: std::collections::HashMap<String, Vec<crate::models::JointLiabilityOwner>>,
    /// Liable person ID per input liability.
    pub liable_person_ids: Vec<Option<i64>>,
}

/// Commits one site's accrual atomically (STORY-07-08): a database error at any liability
/// rolls the whole batch back, including the period row and the run report. Every
/// liability is linked to its period row and records its budget basis in the same insert.
pub async fn commit_accrual_batch(
    pool: &Pool,
    batch: &AccrualBatch<'_>,
) -> DbResult<CommittedAccrual> {
    let site = require_id("site", batch.site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;
    // Serialise accruals of the same site and month only.
    tx.execute(
        "SELECT pg_advisory_xact_lock(7708, hashtext($1::bigint::text || ':' || $2))",
        &[&site, &batch.period_key],
    )
    .await?;
    let mut batch_units = Vec::new();
    for (due, _) in batch.dues {
        let unit = require_id("unit", &due.unit_id)?;
        if !batch_units.contains(&unit) {
            batch_units.push(unit);
        }
    }
    let existing_liability_keys: HashSet<(i64, String)> = if batch_units.is_empty() {
        HashSet::new()
    } else {
        tx.query(
            r#"
            SELECT DISTINCT unit_id, expense_type
            FROM dues_liabilities
            WHERE unit_id = ANY($1)
              AND (period_key = $2 OR (period_key IS NULL AND period = $3))
              AND capital_project_id IS NULL
            "#,
            &[&batch_units, &batch.period_key, &batch.period_label],
        )
        .await?
        .into_iter()
        .map(|row| (row.get(0), row.get(1)))
        .collect()
    };
    let existing = tx
        .query_opt(
            "SELECT id,status FROM dues_periods WHERE site_id = $1 AND period_key = $2 FOR UPDATE",
            &[&site, &batch.period_key],
        )
        .await?;
    if existing
        .as_ref()
        .is_some_and(|row| row.get::<_, String>(1) == "CLOSED")
    {
        return Err(std::io::Error::other("cannot accrue into a closed billing period").into());
    }
    let period_id: Option<i64> = Some(match existing {
        Some(row) => {
            let id: i64 = row.get(0);
            let status: String = row.get(1);
            // A duplicate accrual must stay a true no-op: rewriting an already OPEN
            // period would fire the audit_domain_change trigger and log an event for
            // a request that changed nothing.
            if status != "OPEN" && status != "ACTIVE" {
                tx.execute(
                    "UPDATE dues_periods SET status='OPEN' WHERE id=$1 AND site_id=$2",
                    &[&id, &site],
                )
                .await?;
            }
            id
        }
        None => {
            // The period may exist without a period_key (a legacy seed or a period
            // created before the canonical key). Open it only when it is still a
            // draft; an already open row is left untouched so a duplicate accrual
            // does not write and fire the audit trigger.
            let opened = tx
                .query_opt(
                    r#"
            INSERT INTO dues_periods (site_id, period_name, period_key, due_date, status)
            VALUES ($1, $2, $3, $4, 'OPEN')
            ON CONFLICT (site_id, period_name) DO UPDATE SET period_key = EXCLUDED.period_key, status = 'OPEN'
            WHERE dues_periods.status = 'DRAFT'
            RETURNING id
            "#,
                    &[
                        &site,
                        &batch.period_label,
                        &batch.period_key,
                        &batch.due_date,
                    ],
                )
                .await?;
            match opened {
                Some(row) => row.get(0),
                None => {
                    let row = tx
                        .query_one(
                            "SELECT id, status FROM dues_periods WHERE site_id = $1 AND period_name = $2",
                            &[&site, &batch.period_label],
                        )
                        .await?;
                    let status: String = row.get(1);
                    if status == "CLOSED" {
                        return Err(std::io::Error::other(
                            "cannot accrue into a closed billing period",
                        )
                        .into());
                    }
                    row.get(0)
                }
            }
        }
    });
    let mut due_ids = Vec::with_capacity(batch.dues.len());
    let mut liable_person_ids = Vec::with_capacity(batch.dues.len());
    let mut joint_owners = std::collections::HashMap::new();
    let period = crate::domain::billing_period::BillingPeriod::parse(batch.period_key)
        .map_err(std::io::Error::other)?;
    let period_start = period.first_day();
    let period_end = period.last_day();
    for (due, basis) in batch.dues {
        let unit = require_id("unit", &due.unit_id)?;
        if existing_liability_keys.contains(&(unit, due.expense_type.as_str().to_string())) {
            due_ids.push(None);
            liable_person_ids.push(None);
            continue;
        }
        let budget = basis
            .as_deref()
            .map(|b| require_id("operating budget", b))
            .transpose()?;
        let row = tx
            .query_opt(
                r#"
                INSERT INTO dues_liabilities
                    (unit_id, period, period_key, dues_period_id, principal_amount, due_date, status,
                     delay_penalty, debtor_type, expense_type, operating_budget_id, grace_days, effective_due_date, liable_person_id)
                VALUES ($1, $2, $3, $4, $5, $6, 'PENDING', 0, $7::text, $8, $9, $10, $11,
                        COALESCE($12, CASE WHEN $7::text = 'TENANT' THEN (SELECT tenant_person_id FROM units WHERE id = $1) ELSE (SELECT owner_person_id FROM units WHERE id = $1) END))
                ON CONFLICT DO NOTHING
                RETURNING id, liable_person_id
                "#,
                &[
                    &unit,
                    &batch.period_label,
                    &batch.period_key,
                    &period_id,
                    &due.principal_amount,
                    &due.due_date,
                    &due.debtor_type,
                    &due.expense_type,
                    &budget,
                    &i32::try_from(due.grace_days).unwrap_or(0),
                    &due.fee_due_date(),
                    &due.liable_person_id,
                ],
            )
            .await?;
        let created_id = row.as_ref().map(|r| r.get::<_, i64>(0));
        let created_liable_pid = row.as_ref().and_then(|r| r.get::<_, Option<i64>>(1));
        if due.debtor_type == crate::models::DebtorType::Tenant {
            if let Some(due_id) = created_id {
                let owner_rows = tx
                    .query(
                        r#"
                        SELECT person_id, GREATEST(start_date, $2::date),
                               LEAST(COALESCE(end_date - 1, $3::date), $3::date),
                               (SELECT tenant_person_id FROM units WHERE id = $1)
                        FROM unit_ownerships
                        WHERE unit_id = $1 AND start_date <= $3
                          AND COALESCE(end_date, 'infinity'::date) >= $2
                          AND GREATEST(start_date, $2::date) <= LEAST(COALESCE(end_date - 1, $3::date), $3::date)
                        ORDER BY start_date, person_id
                        "#,
                        &[&unit, &period_start, &period_end],
                    )
                    .await?;
                let mut owners = Vec::with_capacity(owner_rows.len());
                for owner in owner_rows {
                    let person_id: i64 = owner.get(0);
                    let liable_from: NaiveDate = owner.get(1);
                    let liable_through: NaiveDate = owner.get(2);
                    let tenant_person_id: Option<i64> = owner.get(3);
                    tx.execute(
                        r#"
                        INSERT INTO dues_liability_joint_owners
                            (site_id, due_id, owner_person_id, tenant_person_id, liable_from, liable_through)
                        VALUES ($1, $2, $3, $4, $5, $6)
                        ON CONFLICT (due_id, owner_person_id, liable_from, liable_through) DO NOTHING
                        "#,
                        &[&site, &due_id, &person_id, &tenant_person_id, &liable_from, &liable_through],
                    )
                    .await?;
                    owners.push(crate::models::JointLiabilityOwner {
                        person_id,
                        tenant_person_id,
                        start_date: liable_from,
                        end_date: Some(liable_through),
                    });
                }
                if !owners.is_empty() {
                    joint_owners.insert(due_id.to_string(), owners);
                }
            }
        }
        due_ids.push(created_id);
        liable_person_ids.push(created_liable_pid);
    }
    let accrued = due_ids.iter().flatten().count() as i32;
    // A concurrent retry that found all of its liabilities already present is a
    // true no-op. Keep its transaction from creating a second run record, while
    // retaining reports for empty batches that explicitly skipped units.
    if accrued > 0 || !batch.skipped.is_empty() {
        tx.execute(
            r#"
            INSERT INTO dues_accrual_runs (site_id, period_key, source, accrued_count, skipped_units)
            VALUES ($1, $2, $3, $4, $5)
            "#,
            &[
                &site,
                &batch.period_key,
                &batch.source,
                &accrued,
                &batch.skipped,
            ],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(CommittedAccrual {
        period_id,
        due_ids,
        joint_owners,
        liable_person_ids,
    })
}

/// One accrual run as the manager sees it.
#[derive(Debug, Clone, serde::Serialize)]
pub struct AccrualRunRecord {
    pub period_key: String,
    pub period: String,
    pub source: String,
    pub accrued_count: i32,
    pub skipped_units: Vec<String>,
    pub created_at: DateTime<Utc>,
}

/// The latest accrual runs of a site, newest first.
pub async fn list_accrual_runs(
    pool: &Pool,
    site_id: &str,
    limit: i64,
) -> DbResult<Vec<AccrualRunRecord>> {
    let site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site).await?;
    let rows = tx
        .query(
            "SELECT period_key, source, accrued_count, skipped_units, created_at
             FROM dues_accrual_runs WHERE site_id = $1 ORDER BY created_at DESC, id DESC LIMIT $2",
            &[&site, &limit],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| {
            let key: String = r.get(0);
            AccrualRunRecord {
                period: crate::domain::billing_period::BillingPeriod::parse(&key)
                    .map(|p| p.label())
                    .unwrap_or_else(|_| key.clone()),
                period_key: key,
                source: r.get(1),
                accrued_count: r.get(2),
                skipped_units: r.get(3),
                created_at: r.get(4),
            }
        })
        .collect())
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

/// Ids of a site's units that currently have an owner on record.
/// An empty `site_id` means every site.
pub async fn owned_unit_ids(
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
            "SELECT id FROM units WHERE ($1::bigint = 0 OR site_id = $1) AND owner_person_id IS NOT NULL AND deleted_at IS NULL",
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
    today: chrono::NaiveDate,
) -> DbResult<crate::models::DebtAgingReport> {
    let client = pool.get().await?;

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
                    dl.grace_days,
                    dl.effective_due_date,
                    dl.liable_person_id,
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
                    dl.grace_days,
                    dl.effective_due_date,
                    dl.liable_person_id,
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
        let grace_days = u32::try_from(row.get::<_, i32>(13)).unwrap_or(0);
        let effective_due_date: Option<NaiveDate> = row.get(14);
        let liable_person_id: Option<i64> = row.get(15);
        let block_name: String = row.get(16);
        let unit_number: i32 = row.get(17);
        let resident_name: String = row.get(18);

        let status = match status_str.as_str() {
            "PAID" => DebtStatus::Paid,
            "OVERDUE" => DebtStatus::Overdue,
            "CANCELLED" => DebtStatus::Cancelled,
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
            grace_days,
            effective_due_date,
            liable_person_id,
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

/// Logs, once at startup, the liabilities and periods the V37 migration could not resolve to
/// a month (they keep a NULL key and are not covered by the duplicate guard), so they get
/// fixed by hand instead of staying unnoticed.
pub async fn warn_unresolved_period_labels(pool: &Pool) -> DbResult<usize> {
    let client = pool.get().await?;
    let rows = client
        .query(
            "SELECT table_name, count(*), min(period) FROM dues_period_migration_issues GROUP BY table_name",
            &[],
        )
        .await?;
    let mut total = 0usize;
    for row in &rows {
        let table: String = row.get(0);
        let count: i64 = row.get(1);
        let example: String = row.get(2);
        total += usize::try_from(count).unwrap_or(0);
        tracing::warn!(
            "{} row(s) of {} have a period label that is not a month or duplicates another (for example '{}'); see dues_period_migration_issues",
            count,
            table,
            example
        );
    }
    Ok(total)
}
