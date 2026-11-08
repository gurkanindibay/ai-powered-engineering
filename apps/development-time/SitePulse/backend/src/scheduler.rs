use std::time::Duration;
use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::handlers::apply_advance_payments_offset;
use crate::models::{DebtStatus, DuesLiability};
use crate::state::AppState;

/// Formats a naive date into standard Turkish month and year, e.g. "Ekim 2026".
pub fn format_turkish_month_year(date: NaiveDate) -> String {
    let month_name = match date.month() {
        1 => "Ocak",
        2 => "Şubat",
        3 => "Mart",
        4 => "Nisan",
        5 => "Mayıs",
        6 => "Haziran",
        7 => "Temmuz",
        8 => "Ağustos",
        9 => "Eylül",
        10 => "Ekim",
        11 => "Kasım",
        12 => "Aralık",
        _ => "Bilinmeyen",
    };
    format!("{} {}", month_name, date.year())
}

/// Today's date in a site's time zone (falls back to Europe/Istanbul).
pub fn site_local_date(timezone: &str, now: chrono::DateTime<Utc>) -> NaiveDate {
    let tz: chrono_tz::Tz = timezone.parse().unwrap_or(chrono_tz::Europe::Istanbul);
    now.with_timezone(&tz).date_naive()
}

/// Monthly dues for a unit: the tariff of its house type in its own site.
pub fn tariff_for(inner: &crate::state::AppStateInner, unit: &crate::models::IndependentUnit) -> Option<Decimal> {
    let house_type = unit.house_type.as_deref()?;
    inner
        .house_types
        .iter()
        .find(|h| crate::auth::same_id(&h.site_id, &unit.site_id) && h.type_name.eq_ignore_ascii_case(house_type))
        .map(|h| h.dues_amount)
}

/// The party liable for a unit's operational dues (EPIC-08 / KMK): the tenant
/// when the unit has one, otherwise the owner (owner-occupied or vacant unit).
pub fn operational_debtor_for(unit: &crate::models::IndependentUnit) -> &'static str {
    if unit.tenant_user_id.is_some() {
        "TENANT"
    } else {
        "OWNER"
    }
}

/// Outcome of one site/period operational dues accrual.
#[derive(Debug, Clone, Default)]
pub struct SiteAccrualOutcome {
    /// Units of the site that were considered.
    pub units_in_site: usize,
    /// Liabilities newly created by this call.
    pub newly_accrued: usize,
    /// Sum of the newly created liabilities.
    pub total_amount: Decimal,
    /// Units skipped because they have no house-type tariff and no explicit amount.
    pub skipped_without_tariff: usize,
}

/// Builds the operational dues liabilities a site still needs for `period`.
///
/// This is the single accrual rule shared by the background scheduler and the
/// manual `POST /api/v1/dues/accrue-period` endpoint (AF-15):
/// * only units of `site_id` are considered;
/// * a unit that already has an `OPERATIONAL_DUES` liability for the period is skipped
///   (the same key as the `uq_unit_period_expense` index);
/// * the amount is `amount_override` when positive, otherwise the unit's house-type
///   tariff; a unit with neither is skipped instead of receiving an invented amount;
/// * the debtor follows [`operational_debtor_for`].
pub fn build_operational_accruals(
    inner: &crate::state::AppStateInner,
    site_id: &str,
    period: &str,
    due_date: NaiveDate,
    amount_override: Option<Decimal>,
) -> (Vec<DuesLiability>, SiteAccrualOutcome) {
    let mut outcome = SiteAccrualOutcome::default();
    let mut to_accrue = Vec::new();
    for unit in inner.units.iter().filter(|u| crate::auth::same_id(&u.site_id, site_id)) {
        outcome.units_in_site += 1;
        let already = inner
            .dues
            .iter()
            .any(|d| d.unit_id == unit.id && d.period == period && d.expense_type == "OPERATIONAL_DUES");
        if already {
            continue;
        }
        let amount = match amount_override.filter(|a| *a > Decimal::ZERO) {
            Some(a) => a,
            None => match tariff_for(inner, unit) {
                Some(a) => a,
                None => {
                    tracing::warn!("[Accrual] Unit {} in site {} has no house-type tariff; dues not accrued", unit.id, site_id);
                    outcome.skipped_without_tariff += 1;
                    continue;
                }
            },
        };
        to_accrue.push(DuesLiability {
            id: String::new(),
            unit_id: unit.id.clone(),
            period: period.to_string(),
            principal_amount: amount,
            delay_penalty: Decimal::ZERO,
            total_amount: amount,
            due_date,
            status: DebtStatus::Pending,
            paid_principal: Decimal::ZERO,
            paid_penalty: Decimal::ZERO,
            debtor_type: operational_debtor_for(unit).to_string(),
            expense_type: "OPERATIONAL_DUES".to_string(),
        });
    }
    (to_accrue, outcome)
}

/// Persists candidate liabilities DB-first and returns those actually created.
///
/// With PostgreSQL every row is inserted with a database-generated id
/// (`insert_accrued_due`, `RETURNING id`); a row the unique index rejects was
/// accrued already and is dropped. Ids are never invented by the application while
/// a database is attached (AF-14). Without a pool the candidates pass through and
/// receive in-memory ids in [`record_accruals`].
pub async fn persist_accruals(state: &AppState, candidates: Vec<DuesLiability>) -> Result<Vec<DuesLiability>, String> {
    let Some(ref pool) = state.pool else {
        return Ok(candidates);
    };
    let mut created = Vec::with_capacity(candidates.len());
    for mut due in candidates {
        match crate::db::insert_accrued_due(pool, &due).await {
            Ok(Some(id)) => {
                due.id = id.to_string();
                created.push(due);
            }
            Ok(None) => continue,
            Err(e) => return Err(format!("Accrual for unit {} failed: {}", due.unit_id, e)),
        }
    }
    Ok(created)
}

/// Adds persisted liabilities to memory. Re-checks the duplicate key under the write
/// lock, because the candidates were built under a read lock that has been released.
pub fn record_accruals(inner: &mut crate::state::AppStateInner, dues: Vec<DuesLiability>) -> Vec<DuesLiability> {
    let mut recorded = Vec::new();
    for mut due in dues {
        let duplicate = inner
            .dues
            .iter()
            .any(|d| d.unit_id == due.unit_id && d.period == due.period && d.expense_type == due.expense_type);
        if duplicate {
            continue;
        }
        if due.id.is_empty() {
            let max_d = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
            due.id = (max_d + 1).to_string();
        }
        inner.dues.push(due.clone());
        recorded.push(due);
    }
    recorded
}

/// Runs the monthly accrual for every site, idempotently.
///
/// * Each site's period is derived from *its* local date (site `timezone`).
/// * The rules are those of [`build_operational_accruals`].
/// * With PostgreSQL the liability is inserted first (the unique index
///   `uq_unit_period_expense` is the duplicate guard) and only then added to
///   memory with its database id, so accruals survive restarts.
pub async fn run_periodic_accrual_for_all_sites(state: &AppState, now: chrono::DateTime<Utc>) -> (usize, usize) {
    // 1. Inspect state with a READ lock to collect units needing accrual without blocking readers
    let candidates: Vec<(String, DuesLiability)> = {
        let inner = state.inner.read().await;
        let mut to_accrue = Vec::new();
        for site in &inner.sites {
            let local = site_local_date(&site.timezone, now);
            let period = format_turkish_month_year(local);
            let due_date = NaiveDate::from_ymd_opt(local.year(), local.month(), 15).unwrap_or(local);
            let (dues, _) = build_operational_accruals(&inner, &site.id, &period, due_date, None);
            to_accrue.extend(dues.into_iter().map(|d| (site.id.clone(), d)));
        }
        to_accrue
    };

    if candidates.is_empty() {
        return (0, 0);
    }

    // 2. Perform DB operations without holding the global memory lock
    let mut persisted: Vec<(String, DuesLiability)> = Vec::new();
    for (site_id, due) in candidates {
        match persist_accruals(state, vec![due]).await {
            Ok(rows) => persisted.extend(rows.into_iter().map(|d| (site_id.clone(), d))),
            Err(e) => tracing::error!("[Scheduler] {}", e),
        }
    }

    if persisted.is_empty() {
        return (0, 0);
    }

    // 3. Briefly acquire WRITE lock to record new liabilities and apply advance offsets
    let mut inner = state.inner.write().await;
    let ledger_before = crate::handlers::ledger_snapshot(&inner);
    let mut sites_accrued = std::collections::HashSet::new();
    let mut total_newly_accrued = 0;
    for (site_id, due) in persisted {
        let recorded = record_accruals(&mut inner, vec![due]);
        for d in &recorded {
            tracing::info!("[Scheduler] Accrued unit {} for site '{}' for period '{}'", d.unit_id, site_id, d.period);
        }
        if !recorded.is_empty() {
            sites_accrued.insert(site_id);
            total_newly_accrued += recorded.len();
        }
    }

    let (auto_settled_count, total_offset) = apply_advance_payments_offset(&mut inner, None);
    if auto_settled_count > 0 {
        tracing::info!("[Scheduler] Advance offset: {} dues settled, total ₺{}", auto_settled_count, total_offset);
        if let Some(ref pool) = state.pool {
            if let Err(e) = crate::handlers::persist_ledger_changes(pool, &ledger_before, &inner).await {
                tracing::error!("[Scheduler] {}", e);
            }
        }
    }

    (sites_accrued.len(), total_newly_accrued)
}

/// Embedded Tokio background scheduler daemon.
/// Periodically evaluates whether a new period requires accrual across all sites.
pub async fn start_automated_dues_accrual_scheduler(state: AppState) {
    tracing::info!("⏱️ [Scheduler] Automated monthly dues accrual background worker started");

    let mut ticker = tokio::time::interval(Duration::from_secs(60));
    loop {
        ticker.tick().await;

        let is_enabled = {
            let inner = state.inner.read().await;
            inner.auto_scheduler_enabled
        };

        if !is_enabled {
            continue;
        }

        let (sites_accrued, units_accrued) = run_periodic_accrual_for_all_sites(&state, Utc::now()).await;

        if units_accrued > 0 {
            tracing::info!(
                "✅ [Scheduler] Batch accrual tick complete: {} sites, {} units accrued",
                sites_accrued,
                units_accrued
            );
        }
    }
}
