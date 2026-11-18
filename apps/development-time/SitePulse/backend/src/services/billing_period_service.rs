//! Lifecycle operations for closing and reopening a billing period.

use chrono::Utc;

use crate::{
    db::billing_period_repository::BillingPeriodRepository,
    domain::billing_period::BillingPeriod,
    models::{
        DecidePeriodReopen, DuesPeriod, DuesPeriodReopenRequest, DuesPeriodSnapshot,
        DuesPeriodStatus, DuesPeriodSummary, DuesPeriodUnitSnapshot, RequestPeriodReopen,
    },
    services::{accounting_service::AccountingService, finance_common::*},
    state::{AppState, AppStateInner},
};

#[derive(Clone)]
pub struct BillingPeriodService<'a> {
    state: &'a AppState,
    repository: BillingPeriodRepository,
}

impl<'a> BillingPeriodService<'a> {
    pub fn new(state: &'a AppState) -> Self {
        Self {
            state,
            repository: BillingPeriodRepository::for_app(state),
        }
    }

    pub async fn summary(
        &self,
        site_id: &str,
        period_id: &str,
    ) -> FinanceResult<DuesPeriodSummary> {
        let inner = self.state.inner.read().await;
        summary_for(&inner, site_id, period_id)
    }

    pub async fn close(
        &self,
        caller: &Caller,
        period_id: &str,
        request_id: &str,
    ) -> FinanceResult<DuesPeriodSnapshot> {
        require_manager(caller)?;
        let summary = self.summary(&caller.site_id, period_id).await?;
        if summary.status != DuesPeriodStatus::Active {
            return Err(conflict("Only an open period can be closed"));
        }
        let period = {
            let inner = self.state.inner.read().await;
            find_period(&inner, &caller.site_id, period_id)
                .cloned()
                .ok_or_else(|| not_found("Billing period was not found"))?
        };
        let billing_period = BillingPeriod::parse(&period.period_name)
            .map_err(|_| invalid("The billing period does not have a valid month key"))?;
        let start = billing_period.first_day();
        let end = billing_period.last_day();
        let trial_balance = AccountingService::new(self.state)
            .trial_balance(&caller.site_id, Some(start), Some(end))
            .await;
        let journal_entries = AccountingService::new(self.state)
            .journal(&caller.site_id, Some(start), Some(end))
            .await;
        let mut report_snapshot = summary.clone();
        report_snapshot.status = DuesPeriodStatus::Closed;
        let snapshot = {
            let inner = self.state.inner.read().await;
            let version = inner
                .dues_period_snapshots
                .iter()
                .filter(|snapshot| {
                    crate::auth::same_id(&snapshot.site_id, &caller.site_id)
                        && crate::auth::same_id(&snapshot.period_id, period_id)
                })
                .map(|snapshot| snapshot.snapshot_version)
                .max()
                .unwrap_or(0)
                + 1;
            DuesPeriodSnapshot {
                site_id: caller.site_id.clone(),
                period_id: period_id.to_string(),
                period_key: billing_period.key(),
                accrued: summary.accrued,
                collected: summary.collected,
                outstanding: summary.outstanding,
                corrections: summary.corrections,
                per_unit: summary.per_unit.clone(),
                trial_balance,
                account_report: report_snapshot,
                journal_entries,
                snapshot_version: version,
                closed_by: caller.actor(),
                closed_at: Utc::now(),
            }
        };

        self.repository.close(caller, &snapshot, request_id).await?;

        let mut inner = self.state.inner.write().await;
        if let Some(period) = inner.dues_periods.iter_mut().find(|p| {
            crate::auth::same_id(&p.site_id, &caller.site_id)
                && crate::auth::same_id(&p.id, period_id)
        }) {
            if period.status != DuesPeriodStatus::Active {
                return Err(conflict("The period is no longer open"));
            }
            period.status = DuesPeriodStatus::Closed;
        } else {
            return Err(not_found("Billing period was not found"));
        }
        inner.dues_period_snapshots.push(snapshot.clone());
        Ok(snapshot)
    }

    pub async fn request_reopen(
        &self,
        caller: &Caller,
        period_id: &str,
        req: RequestPeriodReopen,
        request_id: &str,
    ) -> FinanceResult<DuesPeriodReopenRequest> {
        require_manager(caller)?;
        let reason = req.reason.trim();
        if reason.chars().count() < 5 {
            return Err(invalid("A reason of at least five characters is required"));
        }
        {
            let inner = self.state.inner.read().await;
            let period = find_period(&inner, &caller.site_id, period_id)
                .ok_or_else(|| not_found("Billing period was not found"))?;
            if period.status != DuesPeriodStatus::Closed {
                return Err(conflict("Only a closed period can be reopened"));
            }
            if inner.dues_period_reopen_requests.iter().any(|request| {
                crate::auth::same_id(&request.site_id, &caller.site_id)
                    && crate::auth::same_id(&request.period_id, period_id)
                    && request.status == "PENDING"
            }) {
                return Err(conflict("A reopen request is already pending"));
            }
        }
        let now = Utc::now();
        let normalized_request = RequestPeriodReopen {
            reason: reason.to_string(),
        };
        let db_id = self
            .repository
            .request_reopen(caller, period_id, &normalized_request, now, request_id)
            .await?;
        let memory_id = self
            .state
            .inner
            .read()
            .await
            .dues_period_reopen_requests
            .iter()
            .filter_map(|request| request.id.parse::<i64>().ok())
            .max()
            .unwrap_or(0)
            + 1;
        let request = DuesPeriodReopenRequest {
            id: db_id.unwrap_or_else(|| memory_id.to_string()),
            site_id: caller.site_id.clone(),
            period_id: period_id.to_string(),
            reason: reason.to_string(),
            requested_by: caller.actor(),
            requested_at: now,
            status: "PENDING".to_string(),
            decided_by: None,
            decided_at: None,
            decision_note: None,
        };
        let mut inner = self.state.inner.write().await;
        let period = find_period(&inner, &caller.site_id, period_id)
            .ok_or_else(|| not_found("Billing period was not found"))?;
        if period.status != DuesPeriodStatus::Closed {
            return Err(conflict("Only a closed period can be reopened"));
        }
        if inner.dues_period_reopen_requests.iter().any(|existing| {
            crate::auth::same_id(&existing.site_id, &caller.site_id)
                && crate::auth::same_id(&existing.period_id, period_id)
                && existing.status == "PENDING"
        }) {
            return Err(conflict("A reopen request is already pending"));
        }
        inner.dues_period_reopen_requests.push(request.clone());
        Ok(request)
    }

    pub async fn decide_reopen(
        &self,
        caller: &Caller,
        request_id: &str,
        req: DecidePeriodReopen,
        audit_request_id: &str,
    ) -> FinanceResult<DuesPeriodReopenRequest> {
        require_manager(caller)?;
        let current = {
            let inner = self.state.inner.read().await;
            inner
                .dues_period_reopen_requests
                .iter()
                .find(|request| {
                    crate::auth::same_id(&request.site_id, &caller.site_id)
                        && crate::auth::same_id(&request.id, request_id)
                })
                .cloned()
                .ok_or_else(|| not_found("Reopen request was not found"))?
        };
        if current.status != "PENDING" {
            return Err(conflict("The reopen request has already been decided"));
        }
        if current.requested_by == caller.actor() {
            return Err(FinanceError::Forbidden(
                "The requester cannot approve their own reopen request".to_string(),
            ));
        }
        let now = Utc::now();
        self.repository
            .decide_reopen(
                caller,
                &current,
                req.approve,
                now,
                req.decision_note.as_deref(),
                audit_request_id,
            )
            .await?;
        let mut inner = self.state.inner.write().await;
        let request = inner
            .dues_period_reopen_requests
            .iter_mut()
            .find(|request| {
                crate::auth::same_id(&request.site_id, &caller.site_id)
                    && crate::auth::same_id(&request.id, request_id)
            })
            .ok_or_else(|| not_found("Reopen request was not found"))?;
        request.status = if req.approve { "APPROVED" } else { "REJECTED" }.to_string();
        request.decided_by = Some(caller.actor());
        request.decided_at = Some(now);
        request.decision_note = req.decision_note;
        let response = request.clone();
        if req.approve {
            let period = inner
                .dues_periods
                .iter_mut()
                .find(|period| {
                    crate::auth::same_id(&period.site_id, &caller.site_id)
                        && crate::auth::same_id(&period.id, &current.period_id)
                })
                .ok_or_else(|| not_found("Billing period was not found"))?;
            period.status = DuesPeriodStatus::Active;
        }
        Ok(response)
    }
}

fn summary_for(
    inner: &AppStateInner,
    site_id: &str,
    period_id: &str,
) -> FinanceResult<DuesPeriodSummary> {
    let period = find_period(inner, site_id, period_id)
        .ok_or_else(|| not_found("Billing period was not found"))?;
    if period.status == DuesPeriodStatus::Closed {
        if let Some(snapshot) = inner
            .dues_period_snapshots
            .iter()
            .filter(|snapshot| {
                crate::auth::same_id(&snapshot.site_id, site_id)
                    && crate::auth::same_id(&snapshot.period_id, period_id)
            })
            .max_by_key(|snapshot| snapshot.snapshot_version)
        {
            return Ok(snapshot.account_report.clone());
        }
    }
    let key = BillingPeriod::parse(&period.period_name)
        .map_err(|_| invalid("The billing period does not have a valid month key"))?;
    let mut by_unit = std::collections::BTreeMap::<String, DuesPeriodUnitSnapshot>::new();
    let mut corrections = rust_decimal::Decimal::ZERO;
    for due in inner.dues.iter().filter(|due| {
        inner.units.iter().any(|unit| {
            crate::auth::same_id(&unit.id, &due.unit_id)
                && crate::auth::same_id(&unit.site_id, site_id)
        }) && BillingPeriod::parse(&due.period).ok() == Some(key)
            && due.status != crate::models::DebtStatus::Cancelled
    }) {
        let row = by_unit
            .entry(due.unit_id.clone())
            .or_insert_with(|| DuesPeriodUnitSnapshot {
                unit_id: due.unit_id.clone(),
                accrued: rust_decimal::Decimal::ZERO,
                collected: rust_decimal::Decimal::ZERO,
                outstanding: rust_decimal::Decimal::ZERO,
            });
        row.accrued += due.principal_amount + due.delay_penalty;
        row.collected += due.paid_principal + due.paid_penalty;
        row.outstanding +=
            (due.principal_amount + due.delay_penalty - due.paid_principal - due.paid_penalty)
                .max(rust_decimal::Decimal::ZERO);
    }
    for correction in inner.finance.corrections.iter().filter(|correction| {
        correction.status == crate::models::REQUEST_APPROVED
            && BillingPeriod::parse(&correction.period).ok() == Some(key)
            && inner.dues.iter().any(|due| {
                crate::auth::same_id(&due.id, &correction.due_id)
                    && inner.units.iter().any(|unit| {
                        crate::auth::same_id(&unit.id, &due.unit_id)
                            && crate::auth::same_id(&unit.site_id, site_id)
                    })
            })
    }) {
        corrections += correction.amount;
    }
    let per_unit: Vec<DuesPeriodUnitSnapshot> = by_unit.into_values().collect();
    let accrued = per_unit.iter().map(|unit| unit.accrued).sum();
    let collected = per_unit.iter().map(|unit| unit.collected).sum();
    let outstanding = per_unit.iter().map(|unit| unit.outstanding).sum();
    Ok(DuesPeriodSummary {
        period_id: period.id.clone(),
        period_key: key.key(),
        status: period.status,
        accrued,
        collected,
        outstanding,
        corrections,
        per_unit,
    })
}

fn find_period<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
    period_id: &str,
) -> Option<&'a DuesPeriod> {
    inner.dues_periods.iter().find(|period| {
        crate::auth::same_id(&period.site_id, site_id)
            && crate::auth::same_id(&period.id, period_id)
    })
}

fn require_manager(caller: &Caller) -> FinanceResult<()> {
    if caller.is_staff() {
        Ok(())
    } else {
        Err(FinanceError::Forbidden(
            "Only a site manager can change the billing period lifecycle".to_string(),
        ))
    }
}

/// Refuses to create any new liability in a closed month.
pub fn ensure_open_for_accrual(
    inner: &AppStateInner,
    site_id: &str,
    period: BillingPeriod,
) -> FinanceResult<()> {
    if inner.dues_periods.iter().any(|existing| {
        crate::auth::same_id(&existing.site_id, site_id)
            && BillingPeriod::parse(&existing.period_name).ok() == Some(period)
            && existing.status == DuesPeriodStatus::Closed
    }) {
        return Err(conflict(format!(
            "Billing period {} is closed and cannot be accrued",
            period.key()
        )));
    }
    Ok(())
}
