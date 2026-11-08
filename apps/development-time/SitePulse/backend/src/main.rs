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
        let mut inner = state.inner.write().await;
        db::load_all_from_db(p, &mut inner).await?;
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

    // Spawn automated monthly dues accrual background scheduler (batch job)
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
