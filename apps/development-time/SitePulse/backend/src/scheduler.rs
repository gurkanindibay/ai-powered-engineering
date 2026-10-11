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

/// Runs periodic accrual across all sites idempotently.
/// If all units in a site already have liabilities for `period`, duplicate accrual is prevented.
/// Automatically runs advance payment offset for all units that have surplus balance.
pub async fn run_periodic_accrual_for_all_sites(
    state: &AppState,
    current_date: NaiveDate,
) -> (usize, usize) {
    let period = format_turkish_month_year(current_date);
    let due_date = NaiveDate::from_ymd_opt(current_date.year(), current_date.month(), 15)
        .unwrap_or(current_date);
    let default_due_amount = Decimal::new(1400, 0); // ₺1.400,00 standard monthly due

    let mut inner = state.inner.write().await;
    let site_ids: Vec<String> = inner.sites.iter().map(|s| s.id.clone()).collect();

    let mut total_newly_accrued = 0;
    let mut total_sites_accrued = 0;

    for site_id in site_ids {
        let units_in_site: Vec<_> = inner
            .units
            .iter()
            .filter(|u| u.site_id == site_id)
            .cloned()
            .collect();

        if units_in_site.is_empty() {
            continue;
        }

        // Duplicate guard: check unaccrued units
        let mut site_newly_accrued = 0;
        for unit in &units_in_site {
            let already_accrued = inner
                .dues
                .iter()
                .any(|d| d.unit_id == unit.id && d.period == period);

            if !already_accrued {
                let due_id = format!("DUE-{}-{}", unit.id, Uuid::new_v4().simple());
                inner.dues.push(DuesLiability {
                    id: due_id,
                    unit_id: unit.id.clone(),
                    period: period.clone(),
                    principal_amount: default_due_amount,
                    delay_penalty: Decimal::ZERO,
                    total_amount: default_due_amount,
                    due_date,
                    status: DebtStatus::Pending,
                });
                site_newly_accrued += 1;
            }
        }

        if site_newly_accrued > 0 {
            total_sites_accrued += 1;
            total_newly_accrued += site_newly_accrued;
            tracing::info!(
                "🗓️ [Scheduler] Accrued {} units for site '{}' for period '{}'",
                site_newly_accrued,
                site_id,
                period
            );
        }
    }

    if total_newly_accrued > 0 {
        let (auto_settled_count, total_offset) = apply_advance_payments_offset(&mut inner, None);
        tracing::info!(
            "💰 [Scheduler] Automatically offset advance payments: {} units settled, total ₺{}",
            auto_settled_count,
            total_offset
        );
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

        let today = Utc::now().date_naive();
        let (sites_accrued, units_accrued) = run_periodic_accrual_for_all_sites(&state, today).await;

        if units_accrued > 0 {
            tracing::info!(
                "✅ [Scheduler] Batch accrual tick complete: {} sites, {} units accrued",
                sites_accrued,
                units_accrued
            );
        }
    }
}
