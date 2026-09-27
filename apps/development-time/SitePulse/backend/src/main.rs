mod handlers;
mod models;
mod services;
mod state;

use std::net::SocketAddr;
use axum::{
    routing::{delete, get, post},
    Router,
};
use tower_http::cors::{Any, CorsLayer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use state::AppState;

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let state = AppState::new();

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/health", get(handlers::health_check))
        .route("/api/v1/health", get(handlers::health_check))
        // Resident Dashboard
        .route("/api/v1/residents/:unit_id/dashboard", get(handlers::get_resident_dashboard))
        // Auth
        .route("/api/v1/auth/login", post(handlers::login_password))
        .route("/api/v1/auth/google", post(handlers::login_google))
        .route("/api/v1/auth/register", post(handlers::register_password))
        .route("/api/v1/auth/me", get(handlers::get_profile))
        // SaaS Multi-Tenancy
        .route("/api/v1/saas/sites", get(handlers::get_all_sites).post(handlers::register_site))
        .route("/api/v1/saas/sites/:id", delete(handlers::delete_site))
        .route(
            "/api/v1/saas/sites/:id/reset-admin-password",
            post(handlers::reset_site_admin_password),
        )
        .route("/api/v1/saas/stats", get(handlers::get_saas_stats))
        // Site Admin & Flats
        .route(
            "/api/v1/site-admin/home-owners",
            get(handlers::get_home_owners).post(handlers::register_home_owner),
        )
        // Self-Registration & Approval Queue
        .route("/api/v1/registration/invite-link", get(handlers::generate_registration_link))
        .route("/api/v1/registration/submit/:slug", post(handlers::submit_self_registration))
        .route("/api/v1/registration/pending", get(handlers::get_pending_registrations))
        .route("/api/v1/registration/approve/:id", post(handlers::approve_registration))
        .route("/api/v1/registration/reject/:id", post(handlers::reject_registration))
        // Co-Resident & Household Members
        .route(
            "/api/v1/home-residents/invite-link/:unit_id",
            get(handlers::generate_unit_invite_link),
        )
        .route("/api/v1/home-residents/register", post(handlers::register_home_resident))
        .route("/api/v1/home-residents/members/:unit_id", get(handlers::get_unit_members))
        .layer(cors)
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    tracing::info!("🦀 SitePulse Rust Backend listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind port 8080");

    axum::serve(listener, app)
        .await
        .expect("Failed to run Axum server");
}
