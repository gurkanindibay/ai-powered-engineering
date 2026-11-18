use chrono::{Datelike, NaiveDate, Utc};
use rust_decimal::Decimal;
use std::time::Duration;

use crate::domain::billing_period::BillingPeriod;
use crate::models::{DebtStatus, DebtorType, DuesLiability, ExpenseType};
use crate::services::advance_offset_service::{settle_advances, OffsetScope};
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

/// One site's planned accrual for the current period.
struct SiteBatch {
    site_id: String,
    period_key: String,
    period: String,
    due_date: NaiveDate,
    dues: Vec<(DuesLiability, Option<String>)>,
    skipped: Vec<String>,
}

/// Today's date in a site's time zone (falls back to Europe/Istanbul).
pub fn site_local_date(timezone: &str, now: chrono::DateTime<Utc>) -> NaiveDate {
    let tz: chrono_tz::Tz = timezone.parse().unwrap_or(chrono_tz::Europe::Istanbul);
    now.with_timezone(&tz).date_naive()
}

/// Monthly dues for a unit: the tariff of its house type in its own site.
pub fn tariff_for(
    inner: &crate::state::AppStateInner,
    unit: &crate::models::IndependentUnit,
) -> Option<Decimal> {
    let house_type = unit.house_type.as_deref()?;
    inner
        .house_types
        .iter()
        .find(|h| {
            crate::auth::same_id(&h.site_id, &unit.site_id)
                && h.type_name.eq_ignore_ascii_case(house_type)
        })
        .map(|h| h.dues_amount)
}

/// One period the scheduler accrued for a site, with the liabilities it created.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccruedPeriod {
    pub site_id: String,
    pub period_key: String,
    pub liabilities: usize,
}

/// Periods a site's catch-up limit left out: `first_key` to `last_key`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LimitedPeriods {
    pub site_id: String,
    pub first_key: String,
    pub last_key: String,
}

/// What one scheduler run did: every period it accrued (oldest first per site) and the
/// periods it did not accrue because of the catch-up limit.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AccrualRunReport {
    pub periods: Vec<AccruedPeriod>,
    pub limited: Vec<LimitedPeriods>,
}

impl AccrualRunReport {
    pub fn sites(&self) -> usize {
        let mut ids: Vec<&str> = self.periods.iter().map(|p| p.site_id.as_str()).collect();
        ids.sort_unstable();
        ids.dedup();
        ids.len()
    }

    pub fn liabilities(&self) -> usize {
        self.periods.iter().map(|p| p.liabilities).sum()
    }
}

/// Runs the monthly accrual for every site, idempotently, and returns the number of sites and
/// of new liabilities. See [`run_accrual_with_report`].
pub async fn run_periodic_accrual_for_all_sites(
    state: &AppState,
    now: chrono::DateTime<Utc>,
) -> (usize, usize) {
    let report = run_accrual_with_report(state, now).await;
    (report.sites(), report.liabilities())
}

/// Runs the monthly accrual for every site, idempotently.
///
/// * Each site's schedule (accrual day, due day, grace period, catch-up limit; STORY-07-10)
///   and local date (site `timezone`) decide which periods are accrued: the current one once
///   its accrual day has come, plus every earlier period the site has no dues for, oldest
///   first, never further back than the catch-up limit. A catch-up liability keeps its own
///   period's due date, so its late fee runs from that date.
/// * The amount is the unit's monthly share of the operating budget in force
///   (SPEC-007 R5), recorded as the liability's legal basis; a site without a
///   budget that does not require one falls back to its house-type tariff.
///   Units with neither are skipped with a warning instead of an invented amount.
/// * The tenant is liable when the unit has one; a vacant unit's dues fall to
///   the owner (KMK), so vacancy changes the debtor rather than being ignored.
/// * With PostgreSQL the liability is inserted first (the unique index
///   `uq_unit_period_expense` is the duplicate guard) and only then added to
///   memory with its database id, so accruals survive restarts.
pub async fn run_accrual_with_report(
    state: &AppState,
    now: chrono::DateTime<Utc>,
) -> AccrualRunReport {
    let mut report = AccrualRunReport::default();
    // Occupancy from PostgreSQL when available: a tenant without a user account
    // is not visible on the in-memory unit.
    let tenanted = match state.pool {
        Some(ref pool) => match crate::db::tenanted_unit_ids(pool, "").await {
            Ok(t) => Some(t),
            Err(e) => {
                tracing::error!(
                    "[Scheduler] Occupancy could not be read; accrual skipped: {}",
                    e
                );
                return report;
            }
        },
        None => None,
    };
    // 1. Inspect state with a READ lock and plan one batch per site and period.
    let batches: Vec<SiteBatch> = {
        let inner = state.inner.read().await;
        let sites: Vec<(String, String)> = inner
            .sites
            .iter()
            .map(|s| (s.id.clone(), s.timezone.clone()))
            .collect();
        let mut planned = Vec::new();

        for (site_id, timezone) in sites {
            let local = site_local_date(&timezone, now);
            let schedule = inner
                .site_accrual_schedules
                .get(&site_id)
                .copied()
                .unwrap_or_default();
            let units_in_site: Vec<_> = inner
                .units
                .iter()
                .filter(|u| u.site_id == site_id)
                .collect();
            let accrued_periods: std::collections::HashSet<BillingPeriod> = inner
                .dues
                .iter()
                .filter(|d| {
                    d.expense_type == ExpenseType::OperationalDues
                        && units_in_site.iter().any(|u| u.id == d.unit_id)
                })
                .filter_map(|d| BillingPeriod::parse(&d.period).ok())
                .collect();
            let plan = schedule.catch_up_plan(local, accrued_periods.iter().min().copied(), |p| {
                accrued_periods.contains(&p)
            });
            if let Some((first, last)) = plan.limited {
                tracing::warn!(
                    "[Scheduler] Site {}: periods {} to {} were not accrued because of the catch-up limit of {} months",
                    site_id,
                    first.key(),
                    last.key(),
                    schedule.catch_up_limit_months
                );
                report.limited.push(LimitedPeriods {
                    site_id: site_id.clone(),
                    first_key: first.key(),
                    last_key: last.key(),
                });
            }
            for billing_period in plan.periods {
                let period = billing_period.label();
                let due_date = schedule.due_date_for(billing_period);
                let mut batch = SiteBatch {
                    site_id: site_id.clone(),
                    period_key: billing_period.key(),
                    period: period.clone(),
                    due_date,
                    dues: Vec::new(),
                    skipped: Vec::new(),
                };

                for unit in &units_in_site {
                    let already = inner.dues.iter().any(|d| {
                        d.unit_id == unit.id
                            && BillingPeriod::parse(&d.period).ok() == Some(billing_period)
                            && d.expense_type == ExpenseType::OperationalDues
                    });
                    if already {
                        continue;
                    }
                    let basis =
                        match crate::services::operating_budget_service::operational_dues_basis(
                            &inner, unit, due_date,
                        ) {
                            Ok(b) => b,
                            Err(reason) => {
                                tracing::warn!(
                                    "[Scheduler] Unit {} in site {}: dues not accrued: {}",
                                    unit.id,
                                    site_id,
                                    reason
                                );
                                batch.skipped.push(format!(
                                    "{}: {}",
                                    inner.unit_label(&unit.block_id, unit.unit_number),
                                    reason
                                ));
                                continue;
                            }
                        };
                    let amount = basis.amount;
                    let let_to_tenant = tenanted
                        .as_ref()
                        .map(|t| t.contains(&unit.id))
                        .unwrap_or(unit.tenant_user_id.is_some());
                    let debtor = if let_to_tenant {
                        DebtorType::Tenant
                    } else {
                        DebtorType::Owner
                    };
                    batch.dues.push((
                        DuesLiability {
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
                            penalty_accrued_through: None,
                            grace_days: schedule.grace_days,
                        },
                        basis.operating_budget_id,
                    ));
                }
                if !batch.dues.is_empty() || !batch.skipped.is_empty() {
                    planned.push(batch);
                }
            }
        }
        planned
    };

    if batches.is_empty() {
        return report;
    }

    // 2. One transaction per site batch, without holding the global memory lock: a failure
    //    leaves that site with no liability at all, in the database or in memory.
    let mut committed_batches: Vec<(SiteBatch, Option<String>)> = Vec::new();
    for mut batch in batches {
        let mut period_db_id = None;
        if let Some(ref pool) = state.pool {
            let outcome = crate::db::commit_accrual_batch(
                pool,
                &crate::db::AccrualBatch {
                    site_id: &batch.site_id,
                    period_key: &batch.period_key,
                    period_label: &batch.period,
                    due_date: batch.due_date,
                    source: "SCHEDULER",
                    dues: &batch.dues,
                    skipped: &batch.skipped,
                },
            )
            .await;
            match outcome {
                Ok(committed) => {
                    period_db_id = committed.period_id.map(|id| id.to_string());
                    let mut kept = Vec::new();
                    for ((mut due, basis), id) in batch.dues.drain(..).zip(committed.due_ids) {
                        if let Some(id) = id {
                            due.id = id.to_string();
                            kept.push((due, basis));
                        } // else: already accrued in DB
                    }
                    batch.dues = kept;
                }
                Err(e) => {
                    tracing::error!(
                        "[Scheduler] Accrual of period {} for site {} failed and was rolled back: {}",
                        batch.period_key,
                        batch.site_id,
                        e
                    );
                    continue;
                }
            }
        }
        if !batch.dues.is_empty() {
            committed_batches.push((batch, period_db_id));
        }
    }

    if committed_batches.is_empty() {
        return report;
    }

    // 3. Briefly acquire WRITE lock to record the committed liabilities (no I/O under it)
    for (batch, _) in &committed_batches {
        report.periods.push(AccruedPeriod {
            site_id: batch.site_id.clone(),
            period_key: batch.period_key.clone(),
            liabilities: batch.dues.len(),
        });
    }

    {
        let mut inner = state.inner.write().await;
        for (batch, period_db_id) in committed_batches {
            let known = inner.dues_periods.iter().any(|p| {
                crate::auth::same_id(&p.site_id, &batch.site_id)
                    && BillingPeriod::parse(&p.period_name).ok()
                        == BillingPeriod::parse(&batch.period_key).ok()
            });
            if !known {
                let id = period_db_id.unwrap_or_else(|| {
                    (inner
                        .dues_periods
                        .iter()
                        .filter_map(|p| crate::db::parse_id_to_i64(&p.id))
                        .max()
                        .unwrap_or(0)
                        + 1)
                    .to_string()
                });
                inner.dues_periods.push(crate::models::DuesPeriod {
                    id,
                    site_id: batch.site_id.clone(),
                    period_name: batch.period.clone(),
                    due_date: batch.due_date,
                    status: crate::models::DuesPeriodStatus::Active,
                    created_at: Some(Utc::now()),
                });
            }
            for (mut due, basis) in batch.dues {
                if due.id.is_empty() {
                    let max_d = inner
                        .dues
                        .iter()
                        .filter_map(|d| crate::db::parse_id_to_i64(&d.id))
                        .max()
                        .unwrap_or(0);
                    due.id = (max_d + 1).to_string();
                }
                if let Some(b) = basis {
                    inner.dues_budget_basis.insert(due.id.clone(), b);
                }
                tracing::info!(
                    "[Scheduler] Accrued unit {} for site '{}' for period '{}'",
                    due.unit_id,
                    batch.site_id,
                    batch.period_key
                );
                inner.dues.push(due);
            }
        }
    }

    // 4. Offset advances against the new liabilities (transactional per unit).
    sweep_advance_offsets(state).await;

    report
}

/// Platform-wide advance offset after a scheduled accrual. Offsets are write
/// operations: they run on the events that create liabilities or credit
/// advances (accruals, virman reversals), never on reads or on a timer.
pub async fn sweep_advance_offsets(state: &AppState) {
    match settle_advances(state, OffsetScope::Platform).await {
        Ok(summary) if summary.settled_lines > 0 => tracing::info!(
            "[Scheduler] Advance offset: {} liabilities settled, total ₺{}",
            summary.settled_lines,
            summary.total_offset
        ),
        Ok(_) => {}
        Err(e) => tracing::error!("[Scheduler] {}", e),
    }
}

/// Key of the advisory lock that lets only one backend instance run a
/// scheduler tick at a time ("SPSCHED").
const SCHEDULER_LOCK_KEY: i64 = 0x0053_5053_4348_4544;

/// Runs `job` only if this instance wins the cluster-wide scheduler lock.
/// Without a database there is a single instance, so the job always runs.
/// Returns `None` when another instance holds the lock.
pub async fn with_scheduler_lock<F, Fut, T>(state: &AppState, job: F) -> Option<T>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = T>,
{
    let Some(pool) = state.db_pool() else {
        return Some(job().await);
    };
    let client = match pool.get().await {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("[Scheduler] Lock connection unavailable: {}", e);
            return None;
        }
    };
    let acquired = match client
        .query_one("SELECT pg_try_advisory_lock($1)", &[&SCHEDULER_LOCK_KEY])
        .await
    {
        Ok(row) => row.get::<_, bool>(0),
        Err(e) => {
            tracing::error!("[Scheduler] Lock query failed: {}", e);
            return None;
        }
    };
    if !acquired {
        return None;
    }
    let out = job().await;
    if let Err(e) = client
        .execute("SELECT pg_advisory_unlock($1)", &[&SCHEDULER_LOCK_KEY])
        .await
    {
        tracing::error!("[Scheduler] Lock release failed: {}", e);
    }
    Some(out)
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

        let Some((sites_accrued, units_accrued)) = with_scheduler_lock(&state, || async {
            run_periodic_accrual_for_all_sites(&state, Utc::now()).await
        })
        .await
        else {
            continue;
        };

        if units_accrued > 0 {
            tracing::info!(
                "✅ [Scheduler] Batch accrual tick complete: {} sites, {} units accrued",
                sites_accrued,
                units_accrued
            );
        }
    }
}

/// Sites whose local calendar day differs from the day their job last ran, with
/// that local day. Each site rolls over at its own midnight, not at UTC midnight.
pub fn sites_due_today(
    sites: &[(String, String)],
    now: chrono::DateTime<Utc>,
    last_run: &std::collections::HashMap<String, NaiveDate>,
) -> Vec<(String, NaiveDate)> {
    sites
        .iter()
        .map(|(id, tz)| (id.clone(), site_local_date(tz, now)))
        .filter(|(id, day)| last_run.get(id) != Some(day))
        .collect()
}

async fn site_timezones(state: &AppState) -> Vec<(String, String)> {
    let inner = state.inner.read().await;
    inner
        .sites
        .iter()
        .map(|s| (s.id.clone(), s.timezone.clone()))
        .collect()
}

/// Daily debt aging snapshot worker (O-8, regulatory report F17): once per
/// site-local calendar day it writes the site's aging report to
/// `debt_aging_snapshots`, so collection trends survive restarts.
pub async fn start_debt_aging_snapshot_worker(state: AppState) {
    let mut ticker = tokio::time::interval(Duration::from_secs(3600));
    let mut last_run: std::collections::HashMap<String, NaiveDate> = Default::default();
    loop {
        ticker.tick().await;
        if state.pool.is_none() {
            continue;
        }
        let sites = site_timezones(&state).await;
        for (site, day) in sites_due_today(&sites, Utc::now(), &last_run) {
            match crate::services::PaymentTrackingService::new(state.clone())
                .snapshot_debt_aging(Some(&site))
                .await
            {
                Ok(rows) => {
                    last_run.insert(site.clone(), day);
                    tracing::info!(
                        "[Scheduler] Debt aging snapshot for site {} on {}: {} rows",
                        site,
                        day,
                        rows
                    );
                }
                Err(e) => tracing::error!(
                    "[Scheduler] Debt aging snapshot failed for site {}: {}",
                    site,
                    e
                ),
            }
        }
    }
}

/// SPEC-009 daily collections worker: once per site-local calendar day it closes
/// or breaks payment plans, charges autopay mandates, runs each site's dunning
/// schedule and reminds managers of interim budget deadlines. Each step is
/// idempotent, so a pass triggered by one site's new day repeats nothing for the
/// others. Requires `auto_scheduler_enabled`.
pub async fn start_collections_worker(state: AppState) {
    let mut ticker = tokio::time::interval(Duration::from_secs(3600));
    let mut last_run: std::collections::HashMap<String, NaiveDate> = Default::default();
    loop {
        ticker.tick().await;
        let enabled = state.inner.read().await.auto_scheduler_enabled;
        if !enabled {
            continue;
        }
        let sites = site_timezones(&state).await;
        let due = sites_due_today(&sites, Utc::now(), &last_run);
        if due.is_empty() {
            continue;
        }
        let (plans, autopay, dunning, reminders) = run_daily_collections(&state).await;
        last_run.extend(due);
        tracing::info!(
            "[Scheduler] Daily collections: {} plans closed, {} autopay charges, {} dunning steps, {} budget reminders",
            plans,
            autopay,
            dunning,
            reminders
        );
    }
}

/// One pass of the daily collections jobs over every site (also used by tests).
pub async fn run_daily_collections(state: &AppState) -> (usize, usize, usize, usize) {
    use crate::services::{
        autopay_service::AutopayService, budget_compliance_service::BudgetComplianceService,
        dunning_service::DunningService, plan_service::PlanService,
    };
    let sites: Vec<String> = state
        .inner
        .read()
        .await
        .sites
        .iter()
        .map(|s| s.id.clone())
        .collect();
    let (mut plans, mut charges) = (0, 0);
    for site in &sites {
        match PlanService::new(state).run(site, None).await {
            Ok(r) => plans += r.completed.len() + r.broken.len(),
            Err(e) => tracing::error!("[Scheduler] Plans for site {}: {}", site, e),
        }
        match AutopayService::new(state).run(site, None).await {
            Ok(r) => charges += r.charged,
            Err(e) => tracing::warn!("[Scheduler] Autopay for site {}: {}", site, e),
        }
    }
    // STORY-07-13: persist the day's late fee first, so dunning and the ledger see it.
    let late_fees = crate::services::late_fee_service::LateFeeService::new(state)
        .run_all()
        .await;
    if late_fees > 0 {
        tracing::info!("[Scheduler] Late fees accrued on {} liabilities", late_fees);
    }
    let dunning = DunningService::new(state).run_all().await;
    let reminders = match BudgetComplianceService::new(state)
        .remind_interim_deadlines()
        .await
    {
        Ok(n) => n,
        Err(e) => {
            tracing::error!("[Scheduler] Interim budget reminders: {}", e);
            0
        }
    };
    (plans, charges, dunning, reminders)
}
