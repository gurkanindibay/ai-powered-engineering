//! Operating budget (işletme projesi) persistence, SPEC-007 R5.

use deadpool_postgres::Pool;
use rust_decimal::Decimal;

use super::{require_id, DbResult};
use crate::models::{
    BudgetObjection, BudgetServiceRecord, OperatingBudget, OperatingBudgetLine, OperatingBudgetUnitShare, RevaluationRate,
};

/// Inserts a new budget with its lines and unit shares in one transaction.
/// Fills the line ids and returns the budget id.
pub async fn insert_operating_budget(pool: &Pool, budget: &mut OperatingBudget) -> DbResult<i64> {
    let site = require_id("site", &budget.site_id)?;
    let previous = budget.previous_budget_id.as_deref().map(|p| require_id("operating budget", p)).transpose()?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let id: i64 = tx
        .query_one(
            r#"
            INSERT INTO operating_budgets (site_id, fiscal_year, period_start, period_end, status, previous_budget_id,
                                           baseline_annual_amount, total_annual_amount, increase_rate, notes, created_by, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            RETURNING id
            "#,
            &[
                &site,
                &budget.fiscal_year,
                &budget.period_start,
                &budget.period_end,
                &budget.status,
                &previous,
                &budget.baseline_annual_amount,
                &budget.total_annual_amount,
                &budget.increase_rate,
                &budget.notes,
                &budget.created_by,
                &budget.created_at,
            ],
        )
        .await?
        .get(0);
    for line in budget.lines.iter_mut() {
        let line_id: i64 = tx
            .query_one(
                "INSERT INTO operating_budget_lines (budget_id, category, description, annual_amount, allocation_key)
                 VALUES ($1, $2, $3, $4, $5) RETURNING id",
                &[&id, &line.category, &line.description, &line.annual_amount, &line.allocation_key],
            )
            .await?
            .get(0);
        line.id = line_id.to_string();
    }
    for share in &budget.unit_shares {
        let unit = require_id("unit", &share.unit_id)?;
        tx.execute(
            "INSERT INTO operating_budget_unit_shares (budget_id, unit_id, land_share, annual_amount, monthly_amount)
             VALUES ($1, $2, $3, $4, $5)",
            &[&id, &unit, &share.land_share, &share.annual_amount, &share.monthly_amount],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(id)
}

/// Writes the lifecycle fields of several budgets in one transaction (a budget
/// coming into force and the one it supersedes change together). Superseded
/// budgets are written first so the one-in-force index never sees two.
pub async fn update_budget_headers(pool: &Pool, budgets: &[OperatingBudget]) -> DbResult<()> {
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let mut ordered: Vec<&OperatingBudget> = budgets.iter().collect();
    ordered.sort_by_key(|b| !matches!(b.status.as_str(), "SUPERSEDED" | "REJECTED"));
    for b in ordered {
        let id = require_id("operating budget", &b.id)?;
        let n = tx
            .execute(
                r#"
                UPDATE operating_budgets SET status = $2, cap_rate = $3, assembly_decision_ref = $4,
                       assembly_decision_date = $5, interim_issued_on = $6, interim_deadline = $7,
                       objection_deadline = $8, notes = $9, updated_at = CURRENT_TIMESTAMP
                WHERE id = $1
                "#,
                &[
                    &id,
                    &b.status,
                    &b.cap_rate,
                    &b.assembly_decision_ref,
                    &b.assembly_decision_date,
                    &b.interim_issued_on,
                    &b.interim_deadline,
                    &b.objection_deadline,
                    &b.notes,
                ],
            )
            .await?;
        if n != 1 {
            return Err(format!("operating budget {} not found", b.id).into());
        }
    }
    tx.commit().await?;
    Ok(())
}

pub async fn delete_draft_budget(pool: &Pool, budget_id: &str) -> DbResult<()> {
    let id = require_id("operating budget", budget_id)?;
    let client = pool.get().await?;
    let n = client.execute("DELETE FROM operating_budgets WHERE id = $1 AND status = 'DRAFT'", &[&id]).await?;
    if n != 1 {
        return Err(format!("draft budget {} not found", budget_id).into());
    }
    Ok(())
}

pub async fn upsert_budget_service(pool: &Pool, budget_id: &str, r: &BudgetServiceRecord) -> DbResult<i64> {
    let id = require_id("operating budget", budget_id)?;
    let unit = require_id("unit", &r.unit_id)?;
    let client = pool.get().await?;
    let row = client
        .query_one(
            r#"
            INSERT INTO budget_service_records (budget_id, unit_id, recipient_name, method, served_on)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (budget_id, unit_id) DO UPDATE SET
                recipient_name = EXCLUDED.recipient_name, method = EXCLUDED.method, served_on = EXCLUDED.served_on
            RETURNING id
            "#,
            &[&id, &unit, &r.recipient_name, &r.method, &r.served_on],
        )
        .await?;
    Ok(row.get(0))
}

/// Inserts an objection (empty id) or updates its resolution.
pub async fn save_budget_objection(pool: &Pool, budget_id: &str, o: &BudgetObjection) -> DbResult<i64> {
    let id = require_id("operating budget", budget_id)?;
    let client = pool.get().await?;
    if o.id.is_empty() {
        let unit = require_id("unit", &o.unit_id)?;
        let row = client
            .query_one(
                "INSERT INTO budget_objections (budget_id, unit_id, objector_name, filed_on, reason, status)
                 VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
                &[&id, &unit, &o.objector_name, &o.filed_on, &o.reason, &o.status],
            )
            .await?;
        return Ok(row.get(0));
    }
    let oid = require_id("objection", &o.id)?;
    client
        .execute(
            "UPDATE budget_objections SET status = $3, resolved_on = $4, resolution_note = $5 WHERE id = $1 AND budget_id = $2",
            &[&oid, &id, &o.status, &o.resolved_on, &o.resolution_note],
        )
        .await?;
    Ok(oid)
}

pub async fn upsert_revaluation_rate(pool: &Pool, r: &RevaluationRate) -> DbResult<()> {
    let client = pool.get().await?;
    client
        .execute(
            "INSERT INTO revaluation_rates (year, rate, source) VALUES ($1, $2, $3)
             ON CONFLICT (year) DO UPDATE SET rate = EXCLUDED.rate, source = EXCLUDED.source",
            &[&r.year, &r.rate, &r.source],
        )
        .await?;
    Ok(())
}

pub async fn set_site_budget_policy(pool: &Pool, site_id: &str, require: bool) -> DbResult<()> {
    let site = require_id("site", site_id)?;
    let client = pool.get().await?;
    let n = client.execute("UPDATE sites SET require_operating_budget = $2 WHERE id = $1", &[&site, &require]).await?;
    if n != 1 {
        return Err(format!("site {} not found", site_id).into());
    }
    Ok(())
}

/// Records the operating budget a dues liability was accrued from.
pub async fn set_due_budget_basis(pool: &Pool, due_id: &str, budget_id: &str) -> DbResult<()> {
    let due = require_id("dues liability", due_id)?;
    let budget = require_id("operating budget", budget_id)?;
    let client = pool.get().await?;
    client.execute("UPDATE dues_liabilities SET operating_budget_id = $2 WHERE id = $1", &[&due, &budget]).await?;
    Ok(())
}

/// Everything SPEC-007 R5 keeps in memory: budgets (with lines, shares, service
/// records, objections), revaluation rates, required-budget sites, and the
/// legal basis of each liability.
pub struct BudgetSnapshot {
    pub budgets: Vec<OperatingBudget>,
    pub rates: Vec<RevaluationRate>,
    pub required_sites: Vec<String>,
    pub due_basis: Vec<(String, String)>,
}

pub async fn load_budget_snapshot(pool: &Pool, unit_label: impl Fn(i64) -> String) -> DbResult<BudgetSnapshot> {
    let client = pool.get().await?;
    let mut budgets: Vec<OperatingBudget> = client
        .query(
            r#"
            SELECT id, site_id, fiscal_year, period_start, period_end, status, previous_budget_id,
                   baseline_annual_amount, total_annual_amount, increase_rate, cap_rate, assembly_decision_ref,
                   assembly_decision_date, interim_issued_on, interim_deadline, objection_deadline, notes,
                   created_by, created_at
            FROM operating_budgets ORDER BY id
            "#,
            &[],
        )
        .await?
        .iter()
        .map(|r| OperatingBudget {
            id: r.get::<_, i64>(0).to_string(),
            site_id: r.get::<_, i64>(1).to_string(),
            fiscal_year: r.get(2),
            period_start: r.get(3),
            period_end: r.get(4),
            status: r.get(5),
            previous_budget_id: r.get::<_, Option<i64>>(6).map(|v| v.to_string()),
            baseline_annual_amount: r.get(7),
            total_annual_amount: r.get(8),
            increase_rate: r.get(9),
            cap_rate: r.get(10),
            assembly_decision_ref: r.get(11),
            assembly_decision_date: r.get(12),
            interim_issued_on: r.get(13),
            interim_deadline: r.get(14),
            objection_deadline: r.get(15),
            notes: r.get(16),
            created_by: r.get(17),
            created_at: r.get(18),
            lines: Vec::new(),
            unit_shares: Vec::new(),
            service_records: Vec::new(),
            objections: Vec::new(),
        })
        .collect();
    let index = |budgets: &Vec<OperatingBudget>, id: i64| budgets.iter().position(|b| b.id == id.to_string());

    for r in client
        .query("SELECT id, budget_id, category, description, annual_amount, allocation_key FROM operating_budget_lines ORDER BY id", &[])
        .await?
    {
        if let Some(i) = index(&budgets, r.get(1)) {
            budgets[i].lines.push(OperatingBudgetLine {
                id: r.get::<_, i64>(0).to_string(),
                category: r.get(2),
                description: r.get(3),
                annual_amount: r.get(4),
                allocation_key: r.get(5),
            });
        }
    }
    for r in client
        .query(
            "SELECT budget_id, unit_id, land_share, annual_amount, monthly_amount FROM operating_budget_unit_shares ORDER BY budget_id, unit_id",
            &[],
        )
        .await?
    {
        if let Some(i) = index(&budgets, r.get(0)) {
            let unit: i64 = r.get(1);
            budgets[i].unit_shares.push(OperatingBudgetUnitShare {
                unit_id: unit.to_string(),
                unit_label: unit_label(unit),
                land_share: r.get(2),
                annual_amount: r.get(3),
                monthly_amount: r.get(4),
            });
        }
    }
    for r in client
        .query("SELECT id, budget_id, unit_id, recipient_name, method, served_on FROM budget_service_records ORDER BY id", &[])
        .await?
    {
        if let Some(i) = index(&budgets, r.get(1)) {
            budgets[i].service_records.push(BudgetServiceRecord {
                id: r.get::<_, i64>(0).to_string(),
                unit_id: r.get::<_, i64>(2).to_string(),
                recipient_name: r.get(3),
                method: r.get(4),
                served_on: r.get(5),
            });
        }
    }
    for r in client
        .query(
            "SELECT id, budget_id, unit_id, objector_name, filed_on, reason, status, resolved_on, resolution_note FROM budget_objections ORDER BY id",
            &[],
        )
        .await?
    {
        if let Some(i) = index(&budgets, r.get(1)) {
            budgets[i].objections.push(BudgetObjection {
                id: r.get::<_, i64>(0).to_string(),
                unit_id: r.get::<_, i64>(2).to_string(),
                objector_name: r.get(3),
                filed_on: r.get(4),
                reason: r.get(5),
                status: r.get(6),
                resolved_on: r.get(7),
                resolution_note: r.get(8),
            });
        }
    }
    let rates = client
        .query("SELECT year, rate, source FROM revaluation_rates ORDER BY year", &[])
        .await?
        .iter()
        .map(|r| RevaluationRate { year: r.get(0), rate: r.get::<_, Decimal>(1), source: r.get(2) })
        .collect();
    let required_sites = client
        .query("SELECT id FROM sites WHERE require_operating_budget", &[])
        .await?
        .iter()
        .map(|r| r.get::<_, i64>(0).to_string())
        .collect();
    let due_basis = client
        .query("SELECT id, operating_budget_id FROM dues_liabilities WHERE operating_budget_id IS NOT NULL", &[])
        .await?
        .iter()
        .map(|r| (r.get::<_, i64>(0).to_string(), r.get::<_, i64>(1).to_string()))
        .collect();
    Ok(BudgetSnapshot { budgets, rates, required_sites, due_basis })
}
