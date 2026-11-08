use sitepulse_backend::{app, auth, db, scheduler, state};

use std::net::SocketAddr;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use state::AppState;

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    auth::validate_configuration();
    let pool = db::create_pool();
    let state = AppState::with_pool(pool.clone());

    if let Some(ref p) = pool {
        // A schema that cannot be verified is fatal: never serve on top of it.
        db::init_db(p).await.expect("PostgreSQL schema initialization failed");
        db::upgrade_legacy_password_hashes(p)
            .await
            .expect("Failed to upgrade legacy password hashes");
        db::ensure_bootstrap_admin(p).await.expect("Failed to create bootstrap administrator");
        let mut inner = state.inner.write().await;
        db::load_all_from_db(p, &mut inner)
            .await
            .expect("Failed to load state from PostgreSQL");
    }

    let app = app::build_router(state.clone());

    // Spawn automated monthly dues accrual background scheduler (batch job)
    tokio::spawn(scheduler::start_automated_dues_accrual_scheduler(state.clone()));
    tokio::spawn(scheduler::start_debt_aging_snapshot_worker(state));

    let addr: SocketAddr = std::env::var("SITEPULSE_BIND_ADDR")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
        .parse()
        .expect("SITEPULSE_BIND_ADDR must be host:port");
    tracing::info!("🦀 SitePulse Rust Backend listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind listen address");

    axum::serve(listener, app)
        .await
        .expect("Failed to run Axum server");
}
