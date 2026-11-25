//! İşletme projesi (operating budget) lifecycle, SPEC-007 R5.
//!
//! KMK 35/37 as amended by Law 7579 (RG 22.05.2026): the kat malikleri genel kurulu
//! approves the işletme projesi; without one the manager issues an *interim* project
//! whose increase over the existing amount may not exceed the yeniden değerleme oranı
//! and which must reach the assembly within three months. An approved project is
//! served on the owners; it becomes final when the 7-day objection window has passed
//! without an upheld objection. Operational dues are accrued from the budget in force
//! and point to it as their legal basis (İİK 68/1).

use chrono::{Datelike, Months, NaiveDate, Utc};
use rust_decimal::{Decimal, RoundingStrategy};

use crate::models::{
    ApproveBudgetRequest, BudgetComplianceStatus, BudgetLineInput, BudgetObjection,
    BudgetServiceRecord, CreateOperatingBudgetRequest, FileBudgetObjectionRequest, IndependentUnit,
    IssueInterimBudgetRequest, OperatingBudget, OperatingBudgetLine, OperatingBudgetUnitShare,
    RecordBudgetServiceRequest, RejectBudgetRequest, ResolveBudgetObjectionRequest,
    RevaluationRate, ALLOCATION_KEYS, BUDGET_APPROVED, BUDGET_CATEGORIES, BUDGET_DRAFT,
    BUDGET_FINAL, BUDGET_INTERIM, BUDGET_REJECTED, BUDGET_SUPERSEDED, SERVICE_METHODS,
};
use crate::state::{AppState, AppStateInner};

/// Days after service in which an owner may object (KMK 37/3).
pub const OBJECTION_WINDOW_DAYS: u64 = 7;
/// Months an interim budget has to reach the assembly (KMK 37/2 as amended).
pub const INTERIM_DEADLINE_MONTHS: u32 = 3;

/// Why a budget operation was refused; the handler maps it to an HTTP status.
#[derive(Debug, Clone, PartialEq)]
pub enum BudgetError {
    NotFound(String),
    Invalid(String),
    /// The request conflicts with the budget's state or the law (409).
    Conflict(String),
    Storage(String),
}

impl std::fmt::Display for BudgetError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BudgetError::NotFound(m)
            | BudgetError::Invalid(m)
            | BudgetError::Conflict(m)
            | BudgetError::Storage(m) => f.write_str(m),
        }
    }
}

type BudgetResult<T> = Result<T, BudgetError>;

/// The amount and legal basis of one unit's operational dues for a due date.
#[derive(Debug, Clone, PartialEq)]
pub struct DuesBasis {
    pub amount: Decimal,
    /// The operating budget the amount comes from; `None` for a legacy tariff.
    pub operating_budget_id: Option<String>,
}

/// The operational dues of `unit` due on `due_date`: the unit's monthly share of the
/// budget in force, or (only where the site does not require a budget) its
/// per-unit override, else its house-type tariff. `Err` explains why nothing may be accrued.
pub fn operational_dues_basis(
    inner: &AppStateInner,
    unit: &IndependentUnit,
    due_date: NaiveDate,
) -> Result<DuesBasis, String> {
    if let Some(budget) = budget_in_force(inner, &unit.site_id, due_date) {
        return match budget.share_of(&unit.id) {
            Some(share) => Ok(DuesBasis {
                amount: share.monthly_amount,
                operating_budget_id: Some(budget.id.clone()),
            }),
            None => Err(format!(
                "Unit {} has no share in operating budget {} ({}); revise the budget to include it",
                unit.id, budget.id, budget.fiscal_year
            )),
        };
    }
    if site_requires_budget(inner, &unit.site_id)
        && !in_budget_transition(inner, &unit.site_id, due_date)
    {
        return Err(format!(
            "No operating budget (işletme projesi) is in force on {} for this site; issue an interim budget or record the assembly's approval first",
            due_date
        ));
    }
    crate::scheduler::tariff_for(inner, unit)
        .map(|amount| DuesBasis {
            amount,
            operating_budget_id: None,
        })
        .ok_or_else(|| {
            format!(
                "Unit {} has no per-unit tariff and no house-type tariff",
                unit.id
            )
        })
}

pub fn budget_in_force<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
    date: NaiveDate,
) -> Option<&'a OperatingBudget> {
    inner
        .operating_budgets
        .iter()
        .filter(|b| crate::auth::same_id(&b.site_id, site_id) && b.is_in_force() && b.covers(date))
        .max_by_key(|b| {
            (
                b.status == BUDGET_FINAL || b.status == BUDGET_APPROVED,
                b.period_start,
            )
        })
}

/// SPEC-009 R1: a site migrating mid-year may accrue the legacy tariff until its
/// transition date; such liabilities have no legal basis and are reported.
pub fn in_budget_transition(inner: &AppStateInner, site_id: &str, due_date: NaiveDate) -> bool {
    inner
        .finance
        .budget_transitions
        .iter()
        .any(|(s, until)| crate::auth::same_id(s, site_id) && due_date <= *until)
}

pub fn site_requires_budget(inner: &AppStateInner, site_id: &str) -> bool {
    inner
        .budget_required_sites
        .iter()
        .any(|s| crate::auth::same_id(s, site_id))
}

/// Splits `amount` over `weights` to the kuruş with the largest-remainder method,
/// so the parts always add up to `amount` exactly.
pub fn allocate_by_weight(amount: Decimal, weights: &[i64]) -> Vec<Decimal> {
    let total_weight: i64 = weights.iter().sum();
    if weights.is_empty() || total_weight <= 0 {
        return vec![Decimal::ZERO; weights.len()];
    }
    let hundred = Decimal::from(100);
    let total_cents = (amount * hundred).round();
    let mut parts: Vec<(usize, Decimal, Decimal)> = weights
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let exact = total_cents * Decimal::from(*w) / Decimal::from(total_weight);
            let floor = exact.floor();
            (i, floor, exact - floor)
        })
        .collect();
    let assigned: Decimal = parts.iter().map(|p| p.1).sum();
    let mut leftover = (total_cents - assigned)
        .to_string()
        .parse::<i64>()
        .unwrap_or(0);
    let mut order: Vec<usize> = (0..parts.len()).collect();
    order.sort_by(|&a, &b| parts[b].2.cmp(&parts[a].2).then(a.cmp(&b)));
    for &i in order.iter().cycle().take(parts.len().max(1) * 2) {
        if leftover <= 0 {
            break;
        }
        parts[i].1 += Decimal::ONE;
        leftover -= 1;
    }
    parts.sort_by_key(|p| p.0);
    parts
        .into_iter()
        .map(|(_, cents, _)| cents / hundred)
        .collect()
}

/// Per-unit yearly and monthly shares of a budget's lines.
pub fn compute_unit_shares(
    inner: &AppStateInner,
    units: &[IndependentUnit],
    lines: &[OperatingBudgetLine],
) -> Vec<OperatingBudgetUnitShare> {
    let mut annual = vec![Decimal::ZERO; units.len()];
    for line in lines {
        let weights: Vec<i64> = line_weights(inner, units, line).unwrap_or_else(|_| {
            units
                .iter()
                .map(|u| i64::from(u.land_share.max(1)))
                .collect()
        });
        for (i, part) in allocate_by_weight(line.annual_amount, &weights)
            .into_iter()
            .enumerate()
        {
            annual[i] += part;
        }
    }
    units
        .iter()
        .zip(annual)
        .map(|(u, yearly)| OperatingBudgetUnitShare {
            unit_id: u.id.clone(),
            unit_label: inner.unit_label(&u.block_id, u.unit_number),
            land_share: u.land_share.max(1),
            annual_amount: yearly,
            monthly_amount: (yearly / Decimal::from(12))
                .round_dp_with_strategy(2, RoundingStrategy::MidpointAwayFromZero),
        })
        .collect()
}

fn percent_increase(baseline: Decimal, total: Decimal) -> Option<Decimal> {
    (baseline > Decimal::ZERO).then(|| {
        ((total - baseline) * Decimal::from(100) / baseline)
            .round_dp_with_strategy(4, RoundingStrategy::MidpointNearestEven)
    })
}

pub struct OperatingBudgetService {
    state: AppState,
}

impl OperatingBudgetService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn list(&self, site_id: &str) -> Vec<OperatingBudget> {
        let inner = self.state.inner.read().await;
        let mut out: Vec<OperatingBudget> = inner
            .operating_budgets
            .iter()
            .filter(|b| crate::auth::same_id(&b.site_id, site_id))
            .cloned()
            .collect();
        out.sort_by(|a, b| {
            b.fiscal_year
                .cmp(&a.fiscal_year)
                .then(b.created_at.cmp(&a.created_at))
        });
        out
    }

    pub async fn get(&self, site_id: &str, budget_id: &str) -> BudgetResult<OperatingBudget> {
        let inner = self.state.inner.read().await;
        find(&inner, site_id, budget_id).cloned()
    }

    /// A DRAFT budget with its lines and the unit shares they produce.
    pub async fn create_draft(
        &self,
        site_id: &str,
        req: CreateOperatingBudgetRequest,
        actor: &str,
    ) -> BudgetResult<OperatingBudget> {
        if !(2000..=2100).contains(&req.fiscal_year) {
            return Err(BudgetError::Invalid(
                "fiscal_year must be between 2000 and 2100".into(),
            ));
        }
        let period_start = req
            .period_start
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(req.fiscal_year, 1, 1).unwrap_or_default());
        let period_end = req.period_end.unwrap_or_else(|| {
            NaiveDate::from_ymd_opt(req.fiscal_year, 12, 31).unwrap_or_default()
        });
        if period_end < period_start {
            return Err(BudgetError::Invalid(
                "period_end is before period_start".into(),
            ));
        }
        if req.lines.is_empty() {
            return Err(BudgetError::Invalid(
                "A budget needs at least one expense line".into(),
            ));
        }
        let lines = req
            .lines
            .iter()
            .enumerate()
            .map(|(i, l)| validate_line(i, l))
            .collect::<BudgetResult<Vec<_>>>()?;
        let total: Decimal = lines.iter().map(|l| l.annual_amount).sum();

        // With PostgreSQL the in-memory unit list can hold rows that are not this
        // site's units in the database; share the budget only across the canonical
        // tenant-scoped inventory so every share has a unit that can be served.
        let canonical_units =
            crate::db::unit_repository::canonical_unit_ids(self.state.db_pool(), site_id)
                .await
                .map_err(storage)?;

        let mut budget = {
            let inner = self.state.inner.read().await;
            if !inner
                .sites
                .iter()
                .any(|s| crate::auth::same_id(&s.id, site_id))
            {
                return Err(BudgetError::NotFound(format!(
                    "Site not found: {}",
                    site_id
                )));
            }
            let mut units: Vec<IndependentUnit> = Vec::new();
            for u in inner
                .units
                .iter()
                .filter(|u| crate::auth::same_id(&u.site_id, site_id))
            {
                if canonical_units
                    .as_ref()
                    .is_none_or(|ids| ids.contains(&u.id))
                {
                    units.push(u.clone());
                } else {
                    tracing::warn!(
                        site_id = %site_id,
                        unit_id = %u.id,
                        "Unit is outside the canonical database inventory; excluded from budget share calculation"
                    );
                }
            }
            if units.is_empty() {
                return Err(BudgetError::Conflict(
                    "The site has no units to share the budget".into(),
                ));
            }
            units.sort_by(|a, b| {
                a.block_id
                    .cmp(&b.block_id)
                    .then(a.unit_number.cmp(&b.unit_number))
            });
            for l in &lines {
                line_weights(&inner, &units, l)?;
            }
            let previous = inner
                .operating_budgets
                .iter()
                .filter(|b| {
                    crate::auth::same_id(&b.site_id, site_id)
                        && (b.is_in_force() || b.status == BUDGET_SUPERSEDED)
                        && b.period_start < period_start
                })
                .max_by_key(|b| b.period_start);
            let baseline = match previous {
                Some(p) => p.total_annual_amount,
                // A site's first budget is measured against its current tariffs' yearly run-rate.
                None => {
                    units
                        .iter()
                        .filter_map(|u| crate::scheduler::tariff_for(&inner, u))
                        .sum::<Decimal>()
                        * Decimal::from(12)
                }
            };
            OperatingBudget {
                id: String::new(),
                site_id: site_id.to_string(),
                fiscal_year: req.fiscal_year,
                period_start,
                period_end,
                status: BUDGET_DRAFT.to_string(),
                previous_budget_id: previous.map(|p| p.id.clone()),
                baseline_annual_amount: baseline,
                total_annual_amount: total,
                increase_rate: percent_increase(baseline, total),
                cap_rate: None,
                assembly_decision_ref: None,
                assembly_decision_date: None,
                interim_issued_on: None,
                interim_deadline: None,
                objection_deadline: None,
                notes: req.notes.clone().filter(|n| !n.trim().is_empty()),
                created_by: actor.to_string(),
                created_at: Utc::now(),
                unit_shares: compute_unit_shares(&inner, &units, &lines),
                lines,
                service_records: Vec::new(),
                objections: Vec::new(),
            }
        };

        if let Some(ref pool) = self.state.pool {
            budget.id = crate::db::insert_operating_budget(pool, &mut budget)
                .await
                .map_err(storage)?
                .to_string();
        } else {
            let inner = self.state.inner.read().await;
            budget.id = next_id(inner.operating_budgets.iter().map(|b| b.id.as_str()));
            let mut line_id = 0;
            for l in budget.lines.iter_mut() {
                line_id += 1;
                l.id = line_id.to_string();
            }
        }
        self.state
            .inner
            .write()
            .await
            .operating_budgets
            .push(budget.clone());
        Ok(budget)
    }

    /// Deletes a DRAFT (nothing was issued from it).
    pub async fn delete_draft(&self, site_id: &str, budget_id: &str) -> BudgetResult<()> {
        let id = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_DRAFT {
                return Err(BudgetError::Conflict(format!(
                    "Only a draft can be deleted; budget {} is {}",
                    b.id, b.status
                )));
            }
            b.id.clone()
        };
        if let Some(ref pool) = self.state.pool {
            crate::db::delete_draft_budget(pool, &id)
                .await
                .map_err(storage)?;
        }
        self.state
            .inner
            .write()
            .await
            .operating_budgets
            .retain(|b| b.id != id);
        Ok(())
    }

    /// The manager's interim budget (DRAFT -> INTERIM). Refused when the increase
    /// over the baseline exceeds that year's revaluation rate: such an increase
    /// needs the assembly's decision (`approve`).
    pub async fn issue_interim(
        &self,
        site_id: &str,
        budget_id: &str,
        req: IssueInterimBudgetRequest,
    ) -> BudgetResult<OperatingBudget> {
        let issued_on = match req.issued_on {
            Some(date) => date,
            None => {
                crate::services::finance_common::site_today_in_state(&self.state, site_id).await
            }
        };
        let updated = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_DRAFT {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {}; only a draft can be issued as interim",
                    b.id, b.status
                )));
            }
            let mut b = b.clone();
            let year = b.period_start.year();
            let rate = inner.revaluation_rates.get(&year).map(|r| r.rate);
            if let Some(increase) = b.increase_rate.filter(|i| *i > Decimal::ZERO) {
                let cap = rate.ok_or_else(|| {
                    BudgetError::Conflict(format!(
                        "No revaluation rate (yeniden değerleme oranı) is recorded for {}; an interim increase of {}% cannot be checked. Record the rate or have the assembly approve the budget",
                        year, increase
                    ))
                })?;
                if increase > cap {
                    return Err(BudgetError::Conflict(format!(
                        "The interim budget raises the yearly amount by {}% (₺{:.2} -> ₺{:.2}), above the {} revaluation rate of {}%. KMK 37: only the assembly can approve this increase",
                        increase.round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven), b.baseline_annual_amount, b.total_annual_amount, year, cap
                    )));
                }
            }
            b.cap_rate = rate;
            b.status = BUDGET_INTERIM.to_string();
            b.interim_issued_on = Some(issued_on);
            b.interim_deadline = issued_on.checked_add_months(Months::new(INTERIM_DEADLINE_MONTHS));
            b
        };
        self.bring_into_force(updated).await
    }

    /// The assembly's approval (DRAFT/INTERIM -> APPROVED), with the decision it rests on.
    pub async fn approve(
        &self,
        site_id: &str,
        budget_id: &str,
        req: ApproveBudgetRequest,
    ) -> BudgetResult<OperatingBudget> {
        let decision = req.assembly_decision_ref.trim().to_string();
        if decision.chars().count() < 3 {
            return Err(BudgetError::Invalid(
                "assembly_decision_ref (karar defteri reference) is required".into(),
            ));
        }
        let updated = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_DRAFT && b.status != BUDGET_INTERIM {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {} and cannot be approved",
                    b.id, b.status
                )));
            }
            // "Future" is judged in the site's time zone (an Istanbul evening is already tomorrow in UTC+3).
            if req.assembly_decision_date
                > crate::services::finance_common::site_today(&inner, site_id)
            {
                return Err(BudgetError::Invalid(
                    "The assembly decision date is in the future".into(),
                ));
            }
            let mut b = b.clone();
            b.status = BUDGET_APPROVED.to_string();
            b.assembly_decision_ref = Some(decision);
            b.assembly_decision_date = Some(req.assembly_decision_date);
            b
        };
        self.bring_into_force(updated).await
    }

    /// Puts `budget` in force; another in-force budget of the same year is superseded.
    async fn bring_into_force(&self, budget: OperatingBudget) -> BudgetResult<OperatingBudget> {
        let superseded: Vec<OperatingBudget> = {
            let inner = self.state.inner.read().await;
            inner
                .operating_budgets
                .iter()
                .filter(|o| {
                    o.id != budget.id
                        && crate::auth::same_id(&o.site_id, &budget.site_id)
                        && o.fiscal_year == budget.fiscal_year
                        && o.is_in_force()
                })
                .cloned()
                .map(|mut o| {
                    o.status = BUDGET_SUPERSEDED.to_string();
                    o
                })
                .collect()
        };
        let mut changed = superseded.clone();
        changed.push(budget.clone());
        if let Some(ref pool) = self.state.pool {
            crate::db::update_budget_headers(pool, &changed)
                .await
                .map_err(storage)?;
        }
        let mut inner = self.state.inner.write().await;
        for c in changed {
            if let Some(slot) = inner.operating_budgets.iter_mut().find(|b| b.id == c.id) {
                *slot = c;
            }
        }
        Ok(budget)
    }

    pub async fn reject(
        &self,
        site_id: &str,
        budget_id: &str,
        req: RejectBudgetRequest,
    ) -> BudgetResult<OperatingBudget> {
        let reason = req.reason.trim();
        if reason.chars().count() < 3 {
            return Err(BudgetError::Invalid(
                "A rejection reason of at least 3 characters is required".into(),
            ));
        }
        let updated = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if !matches!(
                b.status.as_str(),
                BUDGET_DRAFT | BUDGET_INTERIM | BUDGET_APPROVED
            ) {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {} and cannot be rejected",
                    b.id, b.status
                )));
            }
            let mut b = b.clone();
            b.status = BUDGET_REJECTED.to_string();
            let note = format!("Reddedildi: {}", reason);
            b.notes = Some(match b.notes.take() {
                Some(n) => format!("{}\n{}", n, note),
                None => note,
            });
            b
        };
        self.save_header(updated).await
    }

    /// Service of an approved budget on one owner; the objection window runs
    /// from the latest service date.
    pub async fn record_service(
        &self,
        site_id: &str,
        budget_id: &str,
        req: RecordBudgetServiceRequest,
    ) -> BudgetResult<OperatingBudget> {
        let method = req.method.trim().to_uppercase();
        if !SERVICE_METHODS.contains(&method.as_str()) {
            return Err(BudgetError::Invalid(format!(
                "method must be one of {}",
                SERVICE_METHODS.join(", ")
            )));
        }
        if req.recipient_name.trim().is_empty() {
            return Err(BudgetError::Invalid("recipient_name is required".into()));
        }
        let site_today = {
            let inner = self.state.inner.read().await;
            crate::services::finance_common::site_today(&inner, site_id)
        };
        if req.served_on > site_today {
            return Err(BudgetError::Invalid("served_on is in the future".into()));
        }
        let (mut budget, unit_id) = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_APPROVED {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {}; only an approved budget is served",
                    b.id, b.status
                )));
            }
            let unit_id = b
                .share_of(&req.unit_id)
                .map(|s| s.unit_id.clone())
                .ok_or_else(|| {
                    BudgetError::NotFound(format!(
                        "Unit {} has no share in budget {}",
                        req.unit_id, b.id
                    ))
                })?;
            if let Some(decided) = b.assembly_decision_date {
                if req.served_on < decided {
                    return Err(BudgetError::Invalid(
                        "served_on is before the assembly decision".into(),
                    ));
                }
            }
            (b.clone(), unit_id)
        };
        let mut record = BudgetServiceRecord {
            id: String::new(),
            unit_id: unit_id.clone(),
            recipient_name: req.recipient_name.trim().to_string(),
            method,
            served_on: req.served_on,
        };
        budget.service_records.retain(|r| r.unit_id != unit_id);
        budget.objection_deadline = budget
            .service_records
            .iter()
            .map(|r| r.served_on)
            .chain(std::iter::once(record.served_on))
            .max()
            .and_then(|d| d.checked_add_days(chrono::Days::new(OBJECTION_WINDOW_DAYS)));
        if let Some(ref pool) = self.state.pool {
            record.id = crate::db::upsert_budget_service(pool, &budget.id, &record)
                .await
                .map_err(storage)?
                .to_string();
            crate::db::update_budget_headers(pool, std::slice::from_ref(&budget))
                .await
                .map_err(storage)?;
        } else {
            record.id = format!("{}-{}", budget.id, unit_id);
        }
        budget.service_records.push(record);
        self.replace(budget).await
    }

    pub async fn file_objection(
        &self,
        site_id: &str,
        budget_id: &str,
        req: FileBudgetObjectionRequest,
    ) -> BudgetResult<OperatingBudget> {
        let reason = req.reason.trim().to_string();
        if reason.chars().count() < 3 {
            return Err(BudgetError::Invalid(
                "An objection reason of at least 3 characters is required".into(),
            ));
        }
        if req.objector_name.trim().is_empty() {
            return Err(BudgetError::Invalid("objector_name is required".into()));
        }
        let filed_on = match req.filed_on {
            Some(date) => date,
            None => {
                crate::services::finance_common::site_today_in_state(&self.state, site_id).await
            }
        };
        let (mut budget, unit_id) = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_APPROVED {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {}; objections are filed against an approved budget",
                    b.id, b.status
                )));
            }
            let unit_id = b
                .share_of(&req.unit_id)
                .map(|s| s.unit_id.clone())
                .ok_or_else(|| {
                    BudgetError::NotFound(format!(
                        "Unit {} has no share in budget {}",
                        req.unit_id, b.id
                    ))
                })?;
            if let Some(served) = b.service_records.iter().find(|r| r.unit_id == unit_id) {
                let last_day = served.served_on + chrono::Days::new(OBJECTION_WINDOW_DAYS);
                if filed_on > last_day {
                    return Err(BudgetError::Conflict(format!(
                        "The 7-day objection window for this unit closed on {} (served {})",
                        last_day, served.served_on
                    )));
                }
            }
            (b.clone(), unit_id)
        };
        let mut objection = BudgetObjection {
            id: String::new(),
            unit_id,
            objector_name: req.objector_name.trim().to_string(),
            filed_on,
            reason,
            status: "OPEN".to_string(),
            resolved_on: None,
            resolution_note: None,
        };
        if let Some(ref pool) = self.state.pool {
            objection.id = crate::db::save_budget_objection(pool, &budget.id, &objection)
                .await
                .map_err(storage)?
                .to_string();
        } else {
            objection.id = format!("{}-{}", budget.id, budget.objections.len() + 1);
        }
        budget.objections.push(objection);
        self.replace(budget).await
    }

    pub async fn resolve_objection(
        &self,
        site_id: &str,
        budget_id: &str,
        objection_id: &str,
        req: ResolveBudgetObjectionRequest,
    ) -> BudgetResult<OperatingBudget> {
        let status = req.status.trim().to_uppercase();
        if status != "UPHELD" && status != "DISMISSED" {
            return Err(BudgetError::Invalid(
                "status must be UPHELD or DISMISSED".into(),
            ));
        }
        let resolved_on =
            crate::services::finance_common::site_today_in_state(&self.state, site_id).await;
        let mut budget = {
            let inner = self.state.inner.read().await;
            find(&inner, site_id, budget_id)?.clone()
        };
        let objection = budget
            .objections
            .iter_mut()
            .find(|o| o.id == objection_id)
            .ok_or_else(|| {
                BudgetError::NotFound(format!("Objection {} not found", objection_id))
            })?;
        if objection.status != "OPEN" {
            return Err(BudgetError::Conflict(format!(
                "Objection {} is already {}",
                objection.id, objection.status
            )));
        }
        objection.status = status;
        objection.resolved_on = Some(resolved_on);
        objection.resolution_note = req.resolution_note.clone().filter(|n| !n.trim().is_empty());
        let saved = objection.clone();
        if let Some(ref pool) = self.state.pool {
            crate::db::save_budget_objection(pool, &budget.id, &saved)
                .await
                .map_err(storage)?;
        }
        self.replace(budget).await
    }

    /// APPROVED -> FINAL: every unit served, the objection window closed, and no
    /// objection open or upheld (an upheld one means the budget must be revised).
    pub async fn finalize(
        &self,
        site_id: &str,
        budget_id: &str,
        today: NaiveDate,
    ) -> BudgetResult<OperatingBudget> {
        let updated = {
            let inner = self.state.inner.read().await;
            let b = find(&inner, site_id, budget_id)?;
            if b.status != BUDGET_APPROVED {
                return Err(BudgetError::Conflict(format!(
                    "Budget {} is {}; only an approved budget becomes final",
                    b.id, b.status
                )));
            }
            let unserved: Vec<&str> = b
                .unit_shares
                .iter()
                .filter(|s| !b.service_records.iter().any(|r| r.unit_id == s.unit_id))
                .map(|s| s.unit_label.as_str())
                .collect();
            if !unserved.is_empty() {
                return Err(BudgetError::Conflict(format!(
                    "{} unit(s) have not been served the budget yet: {}",
                    unserved.len(),
                    unserved
                        .iter()
                        .take(5)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(", ")
                )));
            }
            match b.objection_deadline {
                Some(deadline) if today > deadline => {}
                Some(deadline) => {
                    return Err(BudgetError::Conflict(format!(
                        "The objection window is open until {}",
                        deadline
                    )));
                }
                None => return Err(BudgetError::Conflict("No service has been recorded".into())),
            }
            if let Some(o) = b.objections.iter().find(|o| o.status == "OPEN") {
                return Err(BudgetError::Conflict(format!(
                    "Objection {} by {} is still open",
                    o.id, o.objector_name
                )));
            }
            if let Some(o) = b.objections.iter().find(|o| o.status == "UPHELD") {
                return Err(BudgetError::Conflict(format!(
                    "Objection {} by {} was upheld; the budget must be revised and approved again",
                    o.id, o.objector_name
                )));
            }
            let mut b = b.clone();
            b.status = BUDGET_FINAL.to_string();
            b
        };
        self.save_header(updated).await
    }

    pub async fn compliance(&self, site_id: &str, today: NaiveDate) -> BudgetComplianceStatus {
        let inner = self.state.inner.read().await;
        let required = site_requires_budget(&inner, site_id);
        let in_force = budget_in_force(&inner, site_id, today).cloned();
        let mut warnings = Vec::new();
        match in_force {
            None => warnings.push(format!(
                "No işletme projesi is in force on {}. KMK 37 (Law 7579): dues need an assembly-approved budget or the manager's interim budget",
                today
            )),
            Some(ref b) => {
                if b.status == BUDGET_INTERIM {
                    if let Some(deadline) = b.interim_deadline {
                        if today > deadline {
                            warnings.push(format!("The interim budget's 3-month deadline to reach the assembly passed on {}", deadline));
                        } else {
                            warnings.push(format!("Interim budget: put it to the assembly by {}", deadline));
                        }
                    }
                }
                if b.status == BUDGET_APPROVED {
                    let open = b.objections.iter().filter(|o| o.status == "OPEN").count();
                    if open > 0 {
                        warnings.push(format!("{} objection(s) to the approved budget are open", open));
                    }
                    let unserved = b.unit_shares.len().saturating_sub(b.service_records.len());
                    if unserved > 0 {
                        warnings.push(format!("{} owner(s) have not been served the approved budget", unserved));
                    }
                }
            }
        }
        BudgetComplianceStatus {
            site_id: site_id.to_string(),
            as_of: today,
            require_operating_budget: required,
            budget_in_force: in_force,
            warnings,
        }
    }

    pub async fn set_policy(&self, site_id: &str, require: bool) -> Result<(), String> {
        if let Some(ref pool) = self.state.pool {
            crate::db::set_site_budget_policy(pool, site_id, require)
                .await
                .map_err(|e| e.to_string())?;
        }
        let mut inner = self.state.inner.write().await;
        inner
            .budget_required_sites
            .retain(|s| !crate::auth::same_id(s, site_id));
        if require {
            inner.budget_required_sites.push(site_id.to_string());
        }
        Ok(())
    }

    pub async fn revaluation_rates(&self) -> Vec<RevaluationRate> {
        let inner = self.state.inner.read().await;
        let mut rates: Vec<RevaluationRate> = inner.revaluation_rates.values().cloned().collect();
        rates.sort_by_key(|r| r.year);
        rates
    }

    pub async fn set_revaluation_rate(
        &self,
        rate: RevaluationRate,
    ) -> Result<RevaluationRate, String> {
        if !(2000..=2100).contains(&rate.year) {
            return Err("year must be between 2000 and 2100".into());
        }
        if rate.rate < Decimal::ZERO || rate.rate > Decimal::from(1000) || rate.rate.scale() > 4 {
            return Err("rate is a percentage between 0 and 1000 with at most 4 decimals".into());
        }
        if let Some(ref pool) = self.state.pool {
            crate::db::upsert_revaluation_rate(pool, &rate)
                .await
                .map_err(|e| e.to_string())?;
        }
        self.state
            .inner
            .write()
            .await
            .revaluation_rates
            .insert(rate.year, rate.clone());
        Ok(rate)
    }

    async fn save_header(&self, budget: OperatingBudget) -> BudgetResult<OperatingBudget> {
        if let Some(ref pool) = self.state.pool {
            crate::db::update_budget_headers(pool, std::slice::from_ref(&budget))
                .await
                .map_err(storage)?;
        }
        self.replace(budget).await
    }

    async fn replace(&self, budget: OperatingBudget) -> BudgetResult<OperatingBudget> {
        let mut inner = self.state.inner.write().await;
        if let Some(slot) = inner
            .operating_budgets
            .iter_mut()
            .find(|b| b.id == budget.id)
        {
            *slot = budget.clone();
        }
        Ok(budget)
    }
}

fn find<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
    budget_id: &str,
) -> BudgetResult<&'a OperatingBudget> {
    inner
        .operating_budgets
        .iter()
        .find(|b| b.id == budget_id && crate::auth::same_id(&b.site_id, site_id))
        .ok_or_else(|| BudgetError::NotFound(format!("Operating budget {} not found", budget_id)))
}

fn validate_line(index: usize, l: &BudgetLineInput) -> BudgetResult<OperatingBudgetLine> {
    let category = l.category.trim().to_uppercase();
    if !BUDGET_CATEGORIES.contains(&category.as_str()) {
        return Err(BudgetError::Invalid(format!(
            "line {}: category must be one of {}",
            index + 1,
            BUDGET_CATEGORIES.join(", ")
        )));
    }
    if l.annual_amount <= Decimal::ZERO || l.annual_amount.scale() > 2 {
        return Err(BudgetError::Invalid(format!(
            "line {}: annual_amount must be positive with at most 2 decimals",
            index + 1
        )));
    }
    let key = l
        .allocation_key
        .as_deref()
        .unwrap_or("LAND_SHARE")
        .trim()
        .to_uppercase();
    if !ALLOCATION_KEYS.contains(&key.as_str()) {
        return Err(BudgetError::Invalid(format!(
            "line {}: allocation_key must be one of {}",
            index + 1,
            ALLOCATION_KEYS.join(", ")
        )));
    }
    Ok(OperatingBudgetLine {
        id: String::new(),
        category,
        description: l.description.clone().filter(|d| !d.trim().is_empty()),
        annual_amount: l.annual_amount,
        unit_weights: if matches!(key.as_str(), "METER" | "CUSTOM") {
            if l.unit_weights.is_empty() {
                return Err(BudgetError::Invalid(format!(
                    "line {}: a {} line needs unit_weights",
                    index + 1,
                    key
                )));
            }
            l.unit_weights.clone()
        } else {
            Vec::new()
        },
        allocation_key: key,
    })
}

/// SPEC-009 R1: the weight of each unit for a line, or why it cannot be split.
pub fn line_weights(
    inner: &AppStateInner,
    units: &[IndependentUnit],
    line: &OperatingBudgetLine,
) -> BudgetResult<Vec<i64>> {
    let weights: Vec<i64> = match line.allocation_key.as_str() {
        "EQUAL" => vec![1; units.len()],
        "HOUSE_TYPE" => units
            .iter()
            .map(|u| {
                crate::scheduler::tariff_for(inner, u)
                    .map(|t| (t * Decimal::ONE_HUNDRED).trunc())
                    .and_then(|c| c.to_string().parse::<i64>().ok())
                    .ok_or_else(|| {
                        BudgetError::Invalid(format!(
                            "{} line: unit {} has no house-type tariff to weigh by",
                            line.category, u.id
                        ))
                    })
            })
            .collect::<BudgetResult<_>>()?,
        "METER" | "CUSTOM" => units
            .iter()
            .map(|u| {
                line.unit_weights
                    .iter()
                    .find(|w| crate::auth::same_id(&w.unit_id, &u.id))
                    .map(|w| i64::try_from(w.weight).unwrap_or(i64::MAX))
                    .ok_or_else(|| {
                        BudgetError::Invalid(format!(
                            "{} line: unit {} has no weight",
                            line.category, u.id
                        ))
                    })
            })
            .collect::<BudgetResult<_>>()?,
        _ => units
            .iter()
            .map(|u| i64::from(u.land_share.max(1)))
            .collect(),
    };
    if weights.iter().sum::<i64>() <= 0 {
        return Err(BudgetError::Invalid(format!(
            "{} line: the weights add up to zero",
            line.category
        )));
    }
    Ok(weights)
}

fn next_id<'a>(ids: impl Iterator<Item = &'a str>) -> String {
    (ids.filter_map(crate::db::parse_id_to_i64)
        .max()
        .unwrap_or(0)
        + 1)
    .to_string()
}

fn storage(e: Box<dyn std::error::Error + Send + Sync>) -> BudgetError {
    BudgetError::Storage(format!(
        "Budget was not saved: {}",
        crate::db::describe_db_error(e.as_ref())
    ))
}
