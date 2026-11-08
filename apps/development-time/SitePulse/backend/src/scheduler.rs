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

/// Runs the monthly accrual for every site, idempotently.
///
/// * Each site's period is derived from *its* local date (site `timezone`).
/// * The amount is the unit's monthly share of the operating budget in force
///   (SPEC-007 R5), recorded as the liability's legal basis; a site without a
///   budget that does not require one falls back to its house-type tariff.
///   Units with neither are skipped with a warning instead of an invented amount.
/// * The tenant is liable when the unit has one; a vacant unit's dues fall to
///   the owner (KMK), so vacancy changes the debtor rather than being ignored.
/// * With PostgreSQL the liability is inserted first (the unique index
///   `uq_unit_period_expense` is the duplicate guard) and only then added to
///   memory with its database id, so accruals survive restarts.
pub async fn run_periodic_accrual_for_all_sites(state: &AppState, now: chrono::DateTime<Utc>) -> (usize, usize) {
    // Occupancy from PostgreSQL when available: a tenant without a user account
    // is not visible on the in-memory unit.
    let tenanted = match state.pool {
        Some(ref pool) => match crate::db::tenanted_unit_ids(pool, "").await {
            Ok(t) => Some(t),
            Err(e) => {
                tracing::error!("[Scheduler] Occupancy could not be read; accrual skipped: {}", e);
                return (0, 0);
            }
        },
        None => None,
    };
    // 1. Inspect state with a READ lock to collect units needing accrual without blocking readers
    let candidates: Vec<(String, DuesLiability, Option<String>)> = {
        let inner = state.inner.read().await;
        let sites: Vec<(String, String)> = inner.sites.iter().map(|s| (s.id.clone(), s.timezone.clone())).collect();
        let mut to_accrue = Vec::new();

        for (site_id, timezone) in sites {
            let local = site_local_date(&timezone, now);
            let period = format_turkish_month_year(local);
            let due_date = NaiveDate::from_ymd_opt(local.year(), local.month(), 15).unwrap_or(local);
            let units_in_site: Vec<_> = inner.units.iter().filter(|u| u.site_id == site_id).collect();

            for unit in units_in_site {
                let already = inner
                    .dues
                    .iter()
                    .any(|d| d.unit_id == unit.id && d.period == period && d.expense_type == "OPERATIONAL_DUES");
                if already {
                    continue;
                }
                let basis = match crate::services::operating_budget_service::operational_dues_basis(&inner, unit, due_date) {
                    Ok(b) => b,
                    Err(reason) => {
                        tracing::warn!("[Scheduler] Unit {} in site {}: dues not accrued: {}", unit.id, site_id, reason);
                        continue;
                    }
                };
                let amount = basis.amount;
                let let_to_tenant = tenanted.as_ref().map(|t| t.contains(&unit.id)).unwrap_or(unit.tenant_user_id.is_some());
                let debtor = if let_to_tenant { "TENANT" } else { "OWNER" };
                to_accrue.push((site_id.clone(), DuesLiability {
                    id: String::new(),
                    unit_id: unit.id.clone(),
                    period: period.clone(),
                    principal_amount: amount,
                    delay_penalty: Decimal::ZERO,
                    total_amount: amount,
                    due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type: debtor.to_string(),
                    expense_type: "OPERATIONAL_DUES".to_string(),
                    penalty_accrued_through: None,
                }, basis.operating_budget_id));
            }
        }
        to_accrue
    };

    if candidates.is_empty() {
        return (0, 0);
    }

    // 2. Perform DB operations without holding the global memory lock
    let mut persisted_dues: Vec<(String, DuesLiability, Option<String>)> = Vec::new();
    let mut sites_accrued_set = std::collections::HashSet::new();

    for (site_id, mut due, basis) in candidates {
        if let Some(ref pool) = state.pool {
            match crate::db::insert_accrued_due(pool, &due).await {
                Ok(Some(id)) => {
                    due.id = id.to_string();
                    if let Some(ref b) = basis {
                        if let Err(e) = crate::db::set_due_budget_basis(pool, &due.id, b).await {
                            tracing::error!("[Scheduler] Legal basis of liability {} not saved: {}", due.id, e);
                        }
                    }
                    sites_accrued_set.insert(site_id.clone());
                    persisted_dues.push((site_id, due, basis));
                }
                Ok(None) => continue, // already accrued in DB
                Err(e) => {
                    tracing::error!("[Scheduler] Accrual for unit {} failed: {}", due.unit_id, e);
                    continue;
                }
            }
        } else {
            sites_accrued_set.insert(site_id.clone());
            persisted_dues.push((site_id, due, basis));
        }
    }

    if persisted_dues.is_empty() {
        return (0, 0);
    }

    // 3. Briefly acquire WRITE lock to record new liabilities and apply advance offsets
    let total_sites_accrued = sites_accrued_set.len();
    let total_newly_accrued = persisted_dues.len();

    {
        let mut inner = state.inner.write().await;
        let ledger_before = crate::handlers::ledger_snapshot(&inner);

        for (site_id, mut due, basis) in persisted_dues {
            if due.id.is_empty() {
                let max_d = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
                due.id = (max_d + 1).to_string();
            }
            if let Some(b) = basis {
                inner.dues_budget_basis.insert(due.id.clone(), b);
            }
            let p = due.period.clone();
            let u_id = due.unit_id.clone();
            inner.dues.push(due);
            tracing::info!("[Scheduler] Accrued unit {} for site '{}' for period '{}'", u_id, site_id, p);
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
    }

    (total_sites_accrued, total_newly_accrued)
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

/// Daily debt aging snapshot worker (O-8, regulatory report F17): once per
/// calendar day (UTC) it writes every site's aging report to
/// `debt_aging_snapshots`, so collection trends survive restarts.
pub async fn start_debt_aging_snapshot_worker(state: AppState) {
    let mut ticker = tokio::time::interval(Duration::from_secs(3600));
    let mut last_day: Option<NaiveDate> = None;
    loop {
        ticker.tick().await;
        let today = Utc::now().date_naive();
        if last_day == Some(today) || state.pool.is_none() {
            continue;
        }
        match crate::services::PaymentTrackingService::new(state.clone()).snapshot_debt_aging(None).await {
            Ok(rows) => {
                last_day = Some(today);
                tracing::info!("[Scheduler] Debt aging snapshot for {}: {} rows", today, rows);
            }
            Err(e) => tracing::error!("[Scheduler] Debt aging snapshot failed: {}", e),
        }
    }
}
