use std::time::Duration;
use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::handlers::apply_advance_payments_offset;
use crate::models::{DebtStatus, DebtorType, DuesLiability, ExpenseType};
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
/// * The amount is the unit's house-type tariff; units without a tariff are
///   skipped with a warning instead of receiving an invented amount.
/// * The tenant is liable when the unit has one; a vacant unit's dues fall to
///   the owner (KMK), so vacancy changes the debtor rather than being ignored.
/// * With PostgreSQL the liability is inserted first (the unique index
///   `uq_unit_period_expense` is the duplicate guard) and only then added to
///   memory with its database id, so accruals survive restarts.
pub async fn run_periodic_accrual_for_all_sites(state: &AppState, now: chrono::DateTime<Utc>) -> (usize, usize) {
    // 1. Inspect state with a READ lock to collect units needing accrual without blocking readers
    let candidates: Vec<(String, DuesLiability)> = {
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
                    .any(|d| d.unit_id == unit.id && d.period == period && d.expense_type == ExpenseType::OperationalDues);
                if already {
                    continue;
                }
                let Some(amount) = tariff_for(&inner, unit) else {
                    tracing::warn!("[Scheduler] Unit {} in site {} has no house-type tariff; dues not accrued", unit.id, site_id);
                    continue;
                };
                let debtor = if unit.tenant_user_id.is_some() { DebtorType::Tenant } else { DebtorType::Owner };
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
                    debtor_type: debtor,
                    expense_type: ExpenseType::OperationalDues,
                }));
            }
        }
        to_accrue
    };

    if candidates.is_empty() {
        return (0, 0);
    }

    // 2. Perform DB operations without holding the global memory lock
    let mut persisted_dues: Vec<(String, DuesLiability)> = Vec::new();
    let mut sites_accrued_set = std::collections::HashSet::new();

    for (site_id, mut due) in candidates {
        if let Some(ref pool) = state.pool {
            match crate::db::insert_accrued_due(pool, &due).await {
                Ok(Some(id)) => {
                    due.id = id.to_string();
                    sites_accrued_set.insert(site_id.clone());
                    persisted_dues.push((site_id, due));
                }
                Ok(None) => continue, // already accrued in DB
                Err(e) => {
                    tracing::error!("[Scheduler] Accrual for unit {} failed: {}", due.unit_id, e);
                    continue;
                }
            }
        } else {
            sites_accrued_set.insert(site_id.clone());
            persisted_dues.push((site_id, due));
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

        for (site_id, mut due) in persisted_dues {
            if due.id.is_empty() {
                let max_d = inner.dues.iter().filter_map(|d| crate::db::parse_id_to_i64(&d.id)).max().unwrap_or(0);
                due.id = (max_d + 1).to_string();
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
