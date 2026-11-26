//! Database-level tenant guardrail (defense in depth, migrations V25 and V54).
//!
//! Tenant-bound transactions call [`tx_bind_tenant`] first. It
//!
//! 1. sets `app.tenant_site_id` for the transaction only (`set_config(.., true)`),
//!    so a pooled connection never carries a tenant into the next checkout, and
//! 2. drops to the `sitepulse_tenant` role (`SET LOCAL ROLE`) when it exists.
//!    That role has no `BYPASSRLS`, so the row-level security policies apply
//!    even when the service connects as a superuser or as the table owner.
//!
//! Platform-wide transactions (start-up load, scheduler, SaaS administration)
//! must opt in explicitly via [`tx_bind_platform`] (setting `app.platform = 'on'`).
//! Unbound queries fail closed (V54).

use std::sync::atomic::{AtomicU8, Ordering};

use deadpool_postgres::Pool;

use super::base::DbResult;

/// The non-bypass role tenant-bound transactions switch to (V21).
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
        "SELECT set_config('app.tenant_site_id', $1, true), set_config('app.platform', '', true)",
        &[&site_id.to_string()],
    )
    .await?;
    if use_role {
        tx.batch_execute(&format!("SET LOCAL ROLE {}", TENANT_ROLE))
            .await?;
    }
    Ok(())
}

/// Marks the transaction as an explicit platform-wide operation (`app.platform = 'on'`).
/// Used by start-up loads, schedulers, and SaaS administration so unbound
/// tenant-table queries fail closed (V54).
pub async fn tx_bind_platform(tx: &deadpool_postgres::Transaction<'_>) -> DbResult<()> {
    tx.execute(
        "SELECT set_config('app.platform', 'on', true), set_config('app.tenant_site_id', '', true)",
        &[],
    )
    .await?;
    Ok(())
}

/// Grants the runtime identity membership in [`TENANT_ROLE`] (V25), as database
/// provisioning does in production.
///
/// Test fixtures run with split identities: the owner creates and migrates the
/// throwaway database, the runtime role serves the application. This call gives
/// that runtime role the tenant role it needs for `SET LOCAL ROLE` binding.
pub async fn provision_runtime_role(admin: &Pool, runtime_role: &str) -> DbResult<()> {
    if runtime_role.is_empty()
        || !runtime_role
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
    {
        return Err(format!("refusing to grant a role name '{}'", runtime_role).into());
    }
    let client = admin.get().await?;
    let statement = format!("GRANT {} TO {}", TENANT_ROLE, runtime_role);
    client.batch_execute(&statement).await?;
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

/// Runs a read-only, tenant-bound transaction and returns it so the caller can
/// issue queries through `tx`.
pub async fn begin_tenant_read(
    client: &mut deadpool_postgres::Object,
    site_id: i64,
) -> DbResult<deadpool_postgres::Transaction<'_>> {
    let tx = client.build_transaction().read_only(true).start().await?;
    tx_bind_tenant(&tx, site_id).await?;
    Ok(tx)
}

/// Starts a read-write, tenant-bound transaction.
pub async fn begin_tenant_tx(
    client: &mut deadpool_postgres::Object,
    site_id: i64,
) -> DbResult<deadpool_postgres::Transaction<'_>> {
    let tx = client.transaction().await?;
    tx_bind_tenant(&tx, site_id).await?;
    Ok(tx)
}

/// Starts a read-only, platform-wide transaction (`app.platform = 'on'`).
pub async fn begin_platform_read(
    client: &mut deadpool_postgres::Object,
) -> DbResult<deadpool_postgres::Transaction<'_>> {
    let tx = client.build_transaction().read_only(true).start().await?;
    tx_bind_platform(&tx).await?;
    Ok(tx)
}

/// Starts a read-write, platform-wide transaction (`app.platform = 'on'`).
pub async fn begin_platform_tx(
    client: &mut deadpool_postgres::Object,
) -> DbResult<deadpool_postgres::Transaction<'_>> {
    let tx = client.transaction().await?;
    tx_bind_platform(&tx).await?;
    Ok(tx)
}

/// Probes whether every tenant-keyed public table has forced tenant isolation.
pub async fn rls_guard_installed(pool: &Pool) -> DbResult<bool> {
    let client = pool.get().await?;
    #[derive(serde::Deserialize)]
    struct TenantRlsConfig {
        tenant_keys: Vec<String>,
        parent_tenant_keys: std::collections::HashMap<String, String>,
        root_tables: Vec<String>,
        exemptions: std::collections::HashMap<String, String>,
    }
    let config: TenantRlsConfig =
        serde_json::from_str(include_str!("../../../scripts/tenant_rls_config.json"))?;
    let mut tenant_keys = config.tenant_keys;
    tenant_keys.extend(config.parent_tenant_keys.into_keys());
    let exemptions: Vec<String> = config.exemptions.into_keys().collect();
    let row = client
        .query_one(
            "WITH expected AS (
                 SELECT c.oid, c.relrowsecurity, c.relforcerowsecurity
                 FROM pg_class c
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public'
                   AND c.relkind IN ('r', 'p')
                   AND c.relname <> ALL($1::text[])
                   AND (
                       c.relname = ANY($3::text[])
                       OR EXISTS (
                           SELECT 1 FROM pg_attribute a
                           WHERE a.attrelid = c.oid
                             AND a.attnum > 0
                             AND NOT a.attisdropped
                             AND a.attname = ANY($2::text[])
                       )
                   )
             )
             SELECT COUNT(*) > 0
                AND COUNT(*) FILTER (WHERE e.relrowsecurity AND e.relforcerowsecurity
                    AND EXISTS (SELECT 1 FROM pg_policy p
                                WHERE p.polrelid = e.oid AND p.polname = 'tenant_isolation')) = COUNT(*)
             FROM expected e",
            &[&exemptions, &tenant_keys, &config.root_tables],
        )
        .await?;
    Ok(row.get(0))
}
