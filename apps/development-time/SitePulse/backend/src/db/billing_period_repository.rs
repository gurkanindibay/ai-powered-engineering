//! Persistence operations for billing period snapshots and reopen approvals.

use deadpool_postgres::Pool;

use crate::{
    db::{base::require_id, tenant_guard::tx_bind_tenant},
    models::{DuesPeriodReopenRequest, DuesPeriodSnapshot, RequestPeriodReopen},
    services::finance_common::{conflict, Caller, FinanceError, FinanceResult},
    state::AppState,
};

#[derive(Clone)]
pub enum BillingPeriodRepository {
    Memory,
    Postgres(Pool),
}

impl BillingPeriodRepository {
    pub fn for_app(app: &AppState) -> Self {
        app.pool.clone().map_or(Self::Memory, Self::Postgres)
    }

    pub async fn close(
        &self,
        caller: &Caller,
        snapshot: &DuesPeriodSnapshot,
        request_id: &str,
    ) -> FinanceResult<()> {
        let Self::Postgres(pool) = self else {
            return Ok(());
        };
        let site = require_id("site", &caller.site_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let id = require_id("billing period", &snapshot.period_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let mut client = pool
            .get()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let tx = client
            .transaction()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx_bind_tenant(&tx, site)
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let row = tx
            .query_opt(
                "UPDATE dues_periods SET status='CLOSED' WHERE id=$1 AND site_id=$2 AND status IN ('OPEN','ACTIVE') RETURNING id",
                &[&id, &site],
            )
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        if row.is_none() {
            return Err(conflict("The period is no longer open"));
        }
        let per_unit = json(snapshot.per_unit.as_slice())?;
        let trial_balance = json(&snapshot.trial_balance)?;
        let account_report = json(&snapshot.account_report)?;
        let journal_entries = json(snapshot.journal_entries.as_slice())?;
        tx.execute(
            "INSERT INTO dues_period_snapshots (site_id,period_id,period_key,snapshot_version,accrued,collected,outstanding,corrections,per_unit,trial_balance,account_report,journal_entries,closed_by,closed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)",
            &[&site,&id,&snapshot.period_key,&snapshot.snapshot_version,&snapshot.accrued,&snapshot.collected,&snapshot.outstanding,&snapshot.corrections,&per_unit,&trial_balance,&account_report,&journal_entries,&snapshot.closed_by,&snapshot.closed_at],
        )
        .await
        .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx.execute(
            "INSERT INTO audit_events (request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,resource_id,outcome,changes) VALUES ($1,'USER',$2,$3,$4,'DUES_PERIOD_CLOSED','dues_period',$5,'SUCCESS',jsonb_build_object('period_key',$6,'snapshot_version',$7))",
            &[&request_id,&caller.user_id,&caller.role.as_str(),&site,&snapshot.period_id,&snapshot.period_key,&snapshot.snapshot_version],
        )
        .await
        .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx.commit()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        Ok(())
    }

    pub async fn request_reopen(
        &self,
        caller: &Caller,
        period_id: &str,
        request: &RequestPeriodReopen,
        requested_at: chrono::DateTime<chrono::Utc>,
        audit_request_id: &str,
    ) -> FinanceResult<Option<String>> {
        let Self::Postgres(pool) = self else {
            return Ok(None);
        };
        let site = require_id("site", &caller.site_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let period = require_id("billing period", period_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let mut client = pool
            .get()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let tx = client
            .transaction()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx_bind_tenant(&tx, site)
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let row = tx
            .query_opt(
                "SELECT status FROM dues_periods WHERE id=$1 AND site_id=$2 FOR UPDATE",
                &[&period, &site],
            )
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?
            .ok_or_else(|| FinanceError::NotFound("Billing period was not found".to_string()))?;
        let status: String = row.get(0);
        if status != "CLOSED" {
            return Err(conflict("Only a closed period can be reopened"));
        }
        let pending: bool = tx
            .query_one(
                "SELECT EXISTS (SELECT 1 FROM dues_period_reopen_requests WHERE site_id=$1 AND period_id=$2 AND status='PENDING')",
                &[&site, &period],
            )
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?
            .get(0);
        if pending {
            return Err(conflict("A reopen request is already pending"));
        }
        let row = tx
            .query_one(
                "INSERT INTO dues_period_reopen_requests (site_id,period_id,reason,requested_by,requested_at,status) VALUES ($1,$2,$3,$4,$5,'PENDING') RETURNING id",
                &[&site,&period,&request.reason,&caller.actor(),&requested_at],
            )
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let id: i64 = row.get(0);
        tx.execute(
            "INSERT INTO audit_events (request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,resource_id,outcome,changes) VALUES ($1,'USER',$2,$3,$4,'DUES_PERIOD_REOPEN_REQUESTED','dues_period',$5,'SUCCESS',jsonb_build_object('reason',$6))",
            &[&audit_request_id,&caller.user_id,&caller.role.as_str(),&site,&period_id,&request.reason],
        )
        .await
        .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx.commit()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        Ok(Some(id.to_string()))
    }

    pub async fn decide_reopen(
        &self,
        caller: &Caller,
        request: &DuesPeriodReopenRequest,
        approve: bool,
        decided_at: chrono::DateTime<chrono::Utc>,
        decision_note: Option<&str>,
        audit_request_id: &str,
    ) -> FinanceResult<()> {
        let Self::Postgres(pool) = self else {
            return Ok(());
        };
        let site = require_id("site", &caller.site_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let id = require_id("reopen request", &request.id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let period = require_id("billing period", &request.period_id)
            .map_err(|e| FinanceError::Invalid(e.to_string()))?;
        let mut client = pool
            .get()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let tx = client
            .transaction()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx_bind_tenant(&tx, site)
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        let status = if approve { "APPROVED" } else { "REJECTED" };
        let row = tx
            .query_opt(
                "UPDATE dues_period_reopen_requests SET status=$3,decided_by=$4,decided_at=$5,decision_note=$6 WHERE id=$1 AND site_id=$2 AND status='PENDING' AND requested_by<>$4 RETURNING id",
                &[&id,&site,&status,&caller.actor(),&decided_at,&decision_note],
            )
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        if row.is_none() {
            return Err(conflict("The reopen request is no longer pending"));
        }
        if approve {
            let changed = tx
                .execute(
                    "UPDATE dues_periods SET status='OPEN' WHERE id=$1 AND site_id=$2 AND status='CLOSED'",
                    &[&period, &site],
                )
                .await
                .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
            if changed != 1 {
                return Err(conflict("The period is no longer closed"));
            }
        }
        tx.execute(
            "INSERT INTO audit_events (request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,resource_id,outcome,changes) VALUES ($1,'USER',$2,$3,$4,'DUES_PERIOD_REOPEN_DECIDED','dues_period_reopen_request',$5,'SUCCESS',jsonb_build_object('approved',$6,'period_id',$7))",
            &[&audit_request_id,&caller.user_id,&caller.role.as_str(),&site,&request.id,&approve,&request.period_id],
        )
        .await
        .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        tx.commit()
            .await
            .map_err(|e| FinanceError::Unavailable(e.to_string()))?;
        Ok(())
    }
}

fn json<T: serde::Serialize + ?Sized>(
    value: &T,
) -> FinanceResult<tokio_postgres::types::Json<serde_json::Value>> {
    serde_json::to_value(value)
        .map(tokio_postgres::types::Json)
        .map_err(|e| FinanceError::Unavailable(e.to_string()))
}
