use std::time::Duration;
use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::Decimal;
use uuid::Uuid;

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
/// * The amount is the unit's house-type tariff; units without a tariff are
///   skipped with a warning instead of receiving an invented amount.
/// * The tenant is liable when the unit has one; a vacant unit's dues fall to
///   the owner (KMK), so vacancy changes the debtor rather than being ignored.
/// * With PostgreSQL the liability is inserted first (the unique index
///   `uq_unit_period_expense` is the duplicate guard) and only then added to
///   memory with its database id, so accruals survive restarts.
pub async fn run_periodic_accrual_for_all_sites(state: &AppState, now: chrono::DateTime<Utc>) -> (usize, usize) {
    let mut inner = state.inner.write().await;
    let ledger_before = crate::handlers::ledger_snapshot(&inner);
    let sites: Vec<(String, String)> = inner.sites.iter().map(|s| (s.id.clone(), s.timezone.clone())).collect();

    let mut total_newly_accrued = 0;
    let mut total_sites_accrued = 0;

    for (site_id, timezone) in sites {
        let local = site_local_date(&timezone, now);
        let period = format_turkish_month_year(local);
        let due_date = NaiveDate::from_ymd_opt(local.year(), local.month(), 15).unwrap_or(local);
        let units_in_site: Vec<_> = inner.units.iter().filter(|u| u.site_id == site_id).cloned().collect();

        let mut site_newly_accrued = 0;
        for unit in &units_in_site {
            let already = inner
                .dues
                .iter()
                .any(|d| d.unit_id == unit.id && d.period == period && d.expense_type == "OPERATIONAL_DUES");
            if already {
                continue;
            }
            let Some(amount) = tariff_for(&inner, unit) else {
                tracing::warn!("[Scheduler] Unit {} in site {} has no house-type tariff; dues not accrued", unit.id, site_id);
                continue;
            };
            let debtor = if unit.tenant_user_id.is_some() { "TENANT" } else { "OWNER" };
            let mut due = DuesLiability {
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
            };
            if let Some(ref pool) = state.pool {
                match crate::db::insert_accrued_due(pool, &due).await {
                    Ok(Some(id)) => due.id = id.to_string(),
                    Ok(None) => continue, // already accrued in the database
                    Err(e) => {
                        tracing::error!("[Scheduler] Accrual for unit {} failed: {}", unit.id, e);
                        continue;
                    }
                }
            } else {
                due.id = format!("DUE-{}-{}", unit.id, Uuid::new_v4().simple());
            }
            inner.dues.push(due);
            site_newly_accrued += 1;
        }

        if site_newly_accrued > 0 {
            total_sites_accrued += 1;
            total_newly_accrued += site_newly_accrued;
            tracing::info!("[Scheduler] Accrued {} units for site '{}' for period '{}'", site_newly_accrued, site_id, period);
        }
    }

    if total_newly_accrued > 0 {
        let (auto_settled_count, total_offset) = apply_advance_payments_offset(&mut inner, None);
        tracing::info!("[Scheduler] Advance offset: {} dues settled, total ₺{}", auto_settled_count, total_offset);
        if let Some(ref pool) = state.pool {
            if let Err(e) = crate::handlers::persist_ledger_changes(pool, &ledger_before, &inner).await {
                tracing::error!("[Scheduler] {}", e);
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
