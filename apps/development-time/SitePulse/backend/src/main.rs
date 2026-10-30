mod db;
mod handlers;
mod models;
mod scheduler;
mod services;
mod state;

use std::net::SocketAddr;
use axum::{
    routing::{delete, get, post, put},
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

    let pool = db::create_pool();
    let state = AppState::with_pool(pool.clone());

    if let Some(ref p) = pool {
        if let Err(e) = db::init_db(p).await {
            tracing::warn!("PostgreSQL initialization notice: {}", e);
        }
        let mut inner = state.inner.write().await;
        db::load_all_from_db(p, &mut inner).await;
    }

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
        .route(
            "/api/v1/site-admin/home-owners/:id",
            put(handlers::update_home_owner).delete(handlers::delete_home_owner),
        )
        .route(
            "/api/v1/site-admin/units/:id/move-out",
            post(handlers::move_out_resident),
        )
        .route(
            "/api/v1/site-admin/units/:id/move-in",
            post(handlers::move_in_resident),
        )
        .route(
            "/api/v1/site-admin/units/:id/occupancy-history",
            get(handlers::get_unit_occupancy_history),
        )
        .route(
            "/api/v1/site-admin/house-types",
            get(handlers::get_house_types).post(handlers::create_house_type),
        )
        .route(
            "/api/v1/site-admin/house-types/:id",
            delete(handlers::delete_house_type),
        )
        .route(
            "/api/v1/site-admin/blocks",
            get(handlers::get_blocks).post(handlers::create_block),
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
        .route(
            "/api/v1/home-residents/members/:unit_id/:resident_id",
            delete(handlers::delete_unit_member).put(handlers::update_unit_member),
        )
        // Bank Statement Ingestion & Automated Reconciliation (STORY-07-02)
        .route("/api/v1/bank/statements/parse", post(handlers::parse_bank_statement))
        .route("/api/v1/bank/statements/reconciliation-queue", get(handlers::get_reconciliation_queue))
        .route("/api/v1/bank/statements/confirm-reconciliation", post(handlers::confirm_reconciliation))
        // Site Bank Account Configuration (STORY-08-01)
        .route("/api/v1/site-admin/banks", get(handlers::list_supported_banks))
        .route(
            "/api/v1/site-admin/bank-account/:site_id",
            get(handlers::get_site_bank_account).post(handlers::configure_site_bank_account),
        )
        // Kuveyt Türk Sandbox & Flat Virtual IBAN Allocation (STORY-07-01 & STORY-07-06)
        .route(
            "/api/v1/units/:id/virtual-iban",
            get(handlers::get_or_allocate_virtual_iban).post(handlers::get_or_allocate_virtual_iban),
        )
        .route("/api/v1/bank/kuveyt-turk/status", get(handlers::get_kuveyt_turk_status))
        .route("/api/v1/bank/kuveyt-turk/configure", post(handlers::configure_kuveyt_turk))
        .route("/api/v1/bank/kuveyt-turk/test-connection", post(handlers::test_kuveyt_turk_connection))
        // Real-Time Bank Webhook & Virtual IBAN Settlement (STORY-07-03)
        .route(
            "/api/v1/bank/webhook/incoming-transfer",
            post(handlers::handle_bank_incoming_webhook),
        )
        .route(
            "/api/v1/bank/remembered-ibans",
            post(handlers::remember_sender_iban),
        )
        // Homeowner Payment Matching Criteria
        .route(
            "/api/v1/residents/:unit_id/matching-criteria",
            get(handlers::get_unit_matching_criteria),
        )
        .route(
            "/api/v1/residents/:unit_id/matching-criteria/ibans",
            post(handlers::add_unit_sender_iban),
        )
        .route(
            "/api/v1/residents/:unit_id/matching-criteria/ibans/:sender_iban",
            delete(handlers::delete_unit_sender_iban),
        )
        .route(
            "/api/v1/residents/:unit_id/matching-criteria/payer-names",
            put(handlers::update_unit_payer_names),
        )
        // Periodic Dues Accrual & Automatic Advance Balance Offsetting
        .route(
            "/api/v1/dues/periods",
            get(handlers::list_dues_periods).post(handlers::create_dues_period),
        )
        .route(
            "/api/v1/dues/accrue-period",
            post(handlers::accrue_monthly_dues),
        )
        // Homeowner Payments Collection & Matching
        .route("/api/v1/payments/record", post(handlers::record_homeowner_payment))
        .route("/api/v1/payments/match-all", post(handlers::match_all_homeowner_payments))
        .route("/api/v1/payments/homeowner-records", get(handlers::get_homeowner_payments))
        // Payment Tracking & Unified Treasury Streams (STORY-09-01 .. STORY-09-07)
        .route("/api/v1/payments/stream", get(handlers::get_payment_stream))
        .route("/api/v1/payments/debt-aging", get(handlers::get_debt_aging_report))
        .route("/api/v1/payments/record-manual", post(handlers::record_manual_payment))
        .route("/api/v1/payments/inter-ledger-transfer", post(handlers::inter_ledger_transfer))
        .route("/api/v1/payments/receipts/:id", get(handlers::get_payment_receipt))
        .route("/api/v1/site-admin/units/:id/transfer-ownership", post(handlers::transfer_unit_ownership))
        // Capital Projects & Fixtures Management (Demirbaş Yönetimi - EPIC-10)
        .route(
            "/api/v1/capital-projects",
            get(handlers::list_capital_projects).post(handlers::create_capital_project),
        )
        .route(
            "/api/v1/capital-projects/:id",
            get(handlers::get_capital_project),
        )
        .route(
            "/api/v1/capital-projects/:id/installments",
            get(handlers::list_capital_installments),
        )
        .route(
            "/api/v1/capital-projects/:id/accrue-installment",
            post(handlers::accrue_capital_installment),
        )
        .route(
            "/api/v1/capital-projects/:id/disbursements",
            get(handlers::list_capital_disbursements).post(handlers::record_capital_disbursement),
        )
        .route(
            "/api/v1/capital-projects/:id/unit-shares",
            get(handlers::get_unit_capital_shares),
        )
        // System Reset & Test Data Fixtures
        .route("/api/v1/system/reset-demo-data", post(handlers::reset_demo_data))
        .route("/api/v1/system/reset-to-initial-state", post(handlers::reset_to_initial_state))
        .route("/api/v1/system/recreate-db", post(handlers::recreate_db))
        .route("/api/v1/system/accrue-test-due", post(handlers::accrue_test_due))
        .route("/api/v1/system/seed-test-fixtures", post(handlers::seed_test_fixtures))
        .route("/api/v1/system/seed-test-data", post(handlers::seed_test_fixtures))
        .route("/api/v1/system/clear-all-data", post(handlers::clear_all_data))
        .route("/api/v1/system/provision-site-units", post(handlers::provision_site_units))
        .route("/api/v1/system/units-summary", get(handlers::get_units_summary))
        .route("/api/v1/system/site-payments", get(handlers::get_site_payments))
        .route("/api/v1/site-admin/overview", get(handlers::get_site_overview))
        .layer(cors)
        .with_state(state.clone());

    // Spawn automated monthly dues accrual background scheduler (batch job)
    tokio::spawn(scheduler::start_automated_dues_accrual_scheduler(state));

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    tracing::info!("🦀 SitePulse Rust Backend listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("Failed to bind port 8080");

    axum::serve(listener, app)
        .await
        .expect("Failed to run Axum server");
}
