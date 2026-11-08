//! Database-level tenant guardrail (defense in depth, migration V19).
//!
//! Tenant-bound transactions call [`tx_bind_tenant`] first. It
//!
//! 1. sets `app.tenant_site_id` for the transaction only (`set_config(.., true)`),
//!    so a pooled connection never carries a tenant into the next checkout, and
//! 2. drops to the `sitepulse_tenant` role (`SET LOCAL ROLE`) when it exists.
//!    That role has no `BYPASSRLS`, so the row-level security policies of V19
//!    apply even when the service connects as a superuser or as the table owner.
//!
//! Inside such a transaction a query that forgets its `site_id` predicate still
//! cannot read or write another tenant's rows: PostgreSQL filters them out.
//! Connections that never bind a tenant (start-up load, platform scheduler,
//! SaaS administration) are unaffected.

use std::sync::atomic::{AtomicU8, Ordering};

use deadpool_postgres::Pool;

use super::base::DbResult;

/// The non-bypass role tenant-bound transactions switch to (V19).
pub const TENANT_ROLE: &str = "sitepulse_tenant";

/// 0 = not probed yet, 1 = role usable, 2 = role missing or not granted.
static ROLE_STATE: AtomicU8 = AtomicU8::new(0);

async fn tenant_role_usable(tx: &deadpool_postgres::Transaction<'_>) -> DbResult<bool> {
    match ROLE_STATE.load(Ordering::Relaxed) {
        1 => return Ok(true),
        2 => return Ok(false),
        _ => {}
    }
    let row = tx
        .query_one(
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)
                         THEN pg_has_role(current_user, $1, 'USAGE')
                         ELSE FALSE END",
            &[&TENANT_ROLE],
        )
        .await?;
    let usable: bool = row.get(0);
    ROLE_STATE.store(if usable { 1 } else { 2 }, Ordering::Relaxed);
    if !usable {
        tracing::warn!(
            "Role '{}' is not available: row-level tenant isolation relies on FORCE ROW LEVEL SECURITY only",
            TENANT_ROLE
        );
    }
    Ok(usable)
}

/// Binds the transaction to one tenant. Must be the first statement of a
/// tenant-scoped transaction; everything after it is filtered by RLS.
pub async fn tx_bind_tenant(tx: &deadpool_postgres::Transaction<'_>, site_id: i64) -> DbResult<()> {
    if site_id <= 0 {
        return Err(format!("refusing to bind an invalid tenant id {}", site_id).into());
    }
    let use_role = tenant_role_usable(tx).await?;
    tx.execute(
        "SELECT set_config('app.tenant_site_id', $1, true)",
        &[&site_id.to_string()],
    )
    .await?;
    if use_role {
        tx.batch_execute(&format!("SET LOCAL ROLE {}", TENANT_ROLE))
            .await?;
    }
    Ok(())
}

/// The tenant the current transaction is bound to, if any (diagnostics/tests).
pub async fn tx_bound_tenant(tx: &deadpool_postgres::Transaction<'_>) -> DbResult<Option<i64>> {
    let row = tx
        .query_one(
            "SELECT NULLIF(current_setting('app.tenant_site_id', true), '')::BIGINT",
            &[],
        )
        .await?;
    Ok(row.get(0))
}

/// Runs a read-only, tenant-bound transaction and returns its client so the
/// caller can issue queries through `tx`. Usage:
///
/// ```ignore
/// let mut client = pool.get().await?;
/// let tx = begin_tenant_read(&mut client, site_id).await?;
/// let rows = tx.query("SELECT ... FROM payment_entries", &[]).await?;
/// tx.commit().await?;
/// ```
pub async fn begin_tenant_read(
    client: &mut deadpool_postgres::Object,
    site_id: i64,
) -> DbResult<deadpool_postgres::Transaction<'_>> {
    let tx = client.build_transaction().read_only(true).start().await?;
    tx_bind_tenant(&tx, site_id).await?;
    Ok(tx)
}

/// Probes whether the RLS guardrail is installed (used by health/diagnostics).
pub async fn rls_guard_installed(pool: &Pool) -> DbResult<bool> {
    let client = pool.get().await?;
    let row = client
        .query_one(
            "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relname = 'payment_entries'
                AND c.relrowsecurity AND c.relforcerowsecurity",
            &[],
        )
        .await?;
    Ok(row.get::<_, i64>(0) == 1)
}
