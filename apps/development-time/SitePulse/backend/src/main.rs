use sitepulse_backend::{app, auth, db, scheduler, state};

use std::net::SocketAddr;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use state::AppState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    auth::validate_configuration()?;
    let e2e_enabled = sitepulse_backend::e2e_clock::validate_e2e_configuration()?;
    let pool = db::create_pool()?;
    let state = AppState::with_pool(pool.clone());
    let migrations_only = std::env::var("SITEPULSE_MIGRATIONS_ONLY").is_ok_and(|v| v == "true");

    if let Some(ref p) = pool {
        // A schema that cannot be verified is fatal: never serve on top of it.
        if state::AppStateInner::is_production() && !migrations_only {
            db::validate_runtime_role(p).await?;
            sitepulse_backend::migrations::verify_current(p).await?;
        } else {
            db::init_db(p).await?;
            db::upgrade_legacy_password_hashes(p).await?;
            db::ensure_bootstrap_admin(p).await?;
        }
        if let Err(e) = db::warn_unresolved_period_labels(p).await {
            tracing::warn!("Could not read dues_period_migration_issues: {}", e);
        }
        // Loaded outside the global lock and swapped in (lock-lint).
        state.reload_from_db().await?;
        if !migrations_only {
            let policies_installed = db::rls_guard_installed(p).await?;
            let role = db::runtime_role_status(p).await?;
            if !policies_installed || !role.is_safe() {
                let reason = format!(
                    "Tenant RLS readiness failed (policies_installed={}, runtime_role_safe={})",
                    policies_installed,
                    role.is_safe()
                );
                tracing::error!(
                    policies_installed,
                    runtime_role_superuser = role.superuser,
                    runtime_role_bypassrls = role.bypass_rls,
                    runtime_role_createrole = role.create_role,
                    runtime_role_createdb = role.create_database,
                    runtime_role_owns_public_tables = role.owns_public_tables,
                    "{}",
                    reason
                );
                if state::AppStateInner::is_production() {
                    return Err(reason.into());
                }
            }
        }
    }

    if migrations_only {
        tracing::info!("Schema initialization complete; migrations-only mode");
        return Ok(());
    }
    if state::AppStateInner::is_production() {
        let pool = pool.as_ref().ok_or("Production requires PostgreSQL")?;
        db::validate_runtime_role(pool).await?;
    }
    let app = app::build_router(state.clone());

    if !e2e_enabled {
        tokio::spawn(sitepulse_backend::audit::CONTEXT.scope(
            sitepulse_backend::audit::AuditContext::service("dues-scheduler"),
            scheduler::start_automated_dues_accrual_scheduler(state.clone()),
        ));
        tokio::spawn(sitepulse_backend::audit::CONTEXT.scope(
            sitepulse_backend::audit::AuditContext::service("debt-aging-worker"),
            scheduler::start_debt_aging_snapshot_worker(state.clone()),
        ));
        tokio::spawn(sitepulse_backend::audit::CONTEXT.scope(
            sitepulse_backend::audit::AuditContext::service("collections-worker"),
            scheduler::start_collections_worker(state),
        ));
    } else {
        tracing::info!("E2E scheduler clock enabled; background timers are disabled");
    }

    let addr: SocketAddr = std::env::var("SITEPULSE_BIND_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
        .parse()?;
    tracing::info!("🦀 SitePulse Rust Backend listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}
