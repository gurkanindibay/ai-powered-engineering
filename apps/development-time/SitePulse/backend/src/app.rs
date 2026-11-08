//! The single source of truth for registered method/template policies.
use crate::models::Permission::*;
use crate::{
    audit, auth, authorization, handlers, security,
    state::{self, AppState},
};
use authorization::RoutePolicy::{self, Development, Public, Require, RequireAny, SelfOnly};
use axum::{
    http::{header, HeaderName, HeaderValue, Method},
    middleware,
    routing::{delete, get, post, put},
    Router,
};
use tower_http::cors::{AllowOrigin, CorsLayer};

pub struct RouteSpec {
    pub method: &'static str,
    pub path: &'static str,
    pub policy: RoutePolicy,
}
macro_rules! routes {
    ($( $method:ident $path:literal => $handler:path, $policy:expr; )*) => {
        pub const ROUTES:&[RouteSpec]=&[$(RouteSpec{method:stringify!($method),path:$path,policy:$policy}),*];
        fn registered_routes()->Router<AppState>{
            let mut app=Router::new();
            $(if !matches!($policy,Development)||dev_routes_enabled(){app=app.route($path,$method($handler));})*
            app
        }
    }
}
routes! {
    post "/api/v1/saas/platform-roles" => authorization::assign_platform_role, Require(TenantManage);
    post "/api/v1/auth/link-google" => security::link_google, SelfOnly;
    post "/api/v1/site-admin/roles" => authorization::assign_role, Require(RoleGrant);
    get "/health" => handlers::health_check, Public;
    get "/api/v1/health" => handlers::health_check, Public;
    get "/api/v1/residents/:unit_id/dashboard" => handlers::get_resident_dashboard, Require(UnitRead);
    post "/api/v1/auth/login" => handlers::login_password, Public;
    post "/api/v1/auth/google" => handlers::login_google, Public;
    post "/api/v1/auth/register" => handlers::register_password, Public;
    post "/api/v1/auth/change-password" => handlers::change_password, SelfOnly;
    get "/api/v1/auth/me" => handlers::get_profile, SelfOnly;
    get "/api/v1/saas/sites" => handlers::get_all_sites, Require(TenantManage);
    post "/api/v1/saas/sites" => handlers::register_site, Require(TenantManage);
    put "/api/v1/saas/sites/:id" => handlers::update_site, Require(TenantManage);
    delete "/api/v1/saas/sites/:id" => handlers::delete_site, Require(TenantManage);
    post "/api/v1/saas/sites/:id/reset-admin-password" => handlers::reset_site_admin_password, Require(TenantManage);
    get "/api/v1/saas/stats" => handlers::get_saas_stats, Require(TenantManage);
    get "/api/v1/site-admin/home-owners" => handlers::get_home_owners, Require(SiteManage);
    post "/api/v1/site-admin/home-owners" => handlers::register_home_owner, Require(SiteManage);
    put "/api/v1/site-admin/home-owners/:id" => handlers::update_home_owner, Require(SiteManage);
    delete "/api/v1/site-admin/home-owners/:id" => handlers::delete_home_owner, Require(SiteManage);
    post "/api/v1/site-admin/units/:id/move-out" => handlers::move_out_resident, Require(SiteManage);
    post "/api/v1/site-admin/units/:id/move-in" => handlers::move_in_resident, Require(SiteManage);
    get "/api/v1/site-admin/units/:id/occupancy-history" => handlers::get_unit_occupancy_history, Require(SiteManage);
    get "/api/v1/site-admin/house-types" => handlers::get_house_types, Require(SiteManage);
    post "/api/v1/site-admin/house-types" => handlers::create_house_type, Require(SiteManage);
    delete "/api/v1/site-admin/house-types/:id" => handlers::delete_house_type, Require(SiteManage);
    get "/api/v1/site-admin/blocks" => handlers::get_blocks, Require(SiteManage);
    post "/api/v1/site-admin/blocks" => handlers::create_block, Require(SiteManage);
    get "/api/v1/registration/invite-link" => handlers::generate_registration_link, Require(ResidentInviteSite);
    post "/api/v1/registration/submit/:slug" => handlers::submit_self_registration, Public;
    get "/api/v1/registration/pending" => handlers::get_pending_registrations, Require(ResidentApprove);
    post "/api/v1/registration/approve/:id" => handlers::approve_registration, Require(ResidentApprove);
    post "/api/v1/registration/reject/:id" => handlers::reject_registration, Require(ResidentApprove);
    get "/api/v1/home-residents/invite-link/:unit_id" => handlers::generate_unit_invite_link, Require(UnitInviteCoResident);
    post "/api/v1/home-residents/register" => handlers::register_home_resident, Public;
    get "/api/v1/home-residents/members/:unit_id" => handlers::get_unit_members, RequireAny(&[UnitManageHousehold, SiteManage]);
    post "/api/v1/home-residents/members/:unit_id" => handlers::add_unit_member, RequireAny(&[UnitManageHousehold, SiteManage]);
    delete "/api/v1/home-residents/members/:unit_id/:resident_id" => handlers::delete_unit_member, RequireAny(&[UnitManageHousehold, SiteManage]);
    put "/api/v1/home-residents/members/:unit_id/:resident_id" => handlers::update_unit_member, RequireAny(&[UnitManageHousehold, SiteManage]);
    post "/api/v1/bank/statements/parse" => handlers::parse_bank_statement, Require(ReconciliationConfirm);
    get "/api/v1/bank/statements/reconciliation-queue" => handlers::get_reconciliation_queue, Require(ReconciliationConfirm);
    post "/api/v1/bank/statements/confirm-reconciliation" => handlers::confirm_reconciliation, Require(ReconciliationConfirm);
    get "/api/v1/site-admin/banks" => handlers::list_supported_banks, Public;
    get "/api/v1/site-admin/bank-account/:site_id" => handlers::get_site_bank_account, Require(BankAccountManage);
    post "/api/v1/site-admin/bank-account/:site_id" => handlers::configure_site_bank_account, Require(BankAccountManage);
    get "/api/v1/units/:id/virtual-iban" => handlers::get_or_allocate_virtual_iban, Require(UnitRead);
    post "/api/v1/units/:id/virtual-iban" => handlers::get_or_allocate_virtual_iban, Require(UnitRead);
    get "/api/v1/bank/kuveyt-turk/status" => handlers::get_kuveyt_turk_status, Require(BankAccountManage);
    post "/api/v1/bank/kuveyt-turk/configure" => handlers::configure_kuveyt_turk, Require(PlatformIntegrationConfigure);
    post "/api/v1/bank/kuveyt-turk/test-connection" => handlers::test_kuveyt_turk_connection, Require(PlatformIntegrationConfigure);
    post "/api/v1/bank/webhook/incoming-transfer" => handlers::handle_bank_incoming_webhook, Public;
    post "/api/v1/bank/remembered-ibans" => handlers::remember_sender_iban, Require(ReconciliationConfirm);
    get "/api/v1/residents/:unit_id/matching-criteria" => handlers::get_unit_matching_criteria, Require(UnitRead);
    post "/api/v1/residents/:unit_id/matching-criteria/ibans" => handlers::add_unit_sender_iban, Require(UnitPay);
    delete "/api/v1/residents/:unit_id/matching-criteria/ibans/:sender_iban" => handlers::delete_unit_sender_iban, Require(UnitPay);
    put "/api/v1/residents/:unit_id/matching-criteria/payer-names" => handlers::update_unit_payer_names, Require(UnitPay);
    get "/api/v1/dues/periods" => handlers::list_dues_periods, Require(LedgerManageAll);
    post "/api/v1/dues/periods" => handlers::create_dues_period, Require(LedgerManageAll);
    post "/api/v1/dues/accrue-period" => handlers::accrue_monthly_dues, Require(LedgerManageAll);
    post "/api/v1/payments/record" => handlers::record_homeowner_payment, Require(PaymentRecordManual);
    post "/api/v1/payments/match-all" => handlers::match_all_homeowner_payments, Require(PaymentRecordManual);
    get "/api/v1/payments/homeowner-records" => handlers::get_homeowner_payments, Require(LedgerManageAll);
    get "/api/v1/payments/stream" => handlers::get_payment_stream, Require(LedgerManageAll);
    get "/api/v1/payments/debt-aging" => handlers::get_debt_aging_report, Require(LedgerManageAll);
    post "/api/v1/payments/record-manual" => handlers::record_manual_payment, Require(PaymentRecordManual);
    post "/api/v1/payments/inter-ledger-transfer" => handlers::inter_ledger_transfer, Require(LedgerManageAll);
    post "/api/v1/payments/reverse" => handlers::reverse_payment, Require(PaymentReverse);
    post "/api/v1/payments/debt-aging/snapshot" => handlers::snapshot_debt_aging, Require(LedgerManageAll);
    get "/api/v1/payments/receipts/:id" => handlers::get_payment_receipt, Require(UnitRead);
    post "/api/v1/site-admin/units/:id/transfer-ownership" => handlers::transfer_unit_ownership, Require(SiteManage);
    get "/api/v1/capital-projects" => handlers::list_capital_projects, Require(UnitRead);
    post "/api/v1/capital-projects" => handlers::create_capital_project, Require(SiteManage);
    get "/api/v1/capital-projects/:id" => handlers::get_capital_project, Require(UnitRead);
    get "/api/v1/capital-projects/:id/installments" => handlers::list_capital_installments, Require(UnitRead);
    post "/api/v1/capital-projects/:id/accrue-installment" => handlers::accrue_capital_installment, Require(LedgerManageAll);
    get "/api/v1/capital-projects/:id/disbursements" => handlers::list_capital_disbursements, Require(SiteManage);
    post "/api/v1/capital-projects/:id/disbursements" => handlers::record_capital_disbursement, Require(SiteManage);
    get "/api/v1/capital-projects/:id/unit-shares" => handlers::get_unit_capital_shares, Require(UnitRead);
    get "/api/v1/site-admin/overview" => handlers::get_site_overview, Require(SiteManage);
    post "/api/v1/system/reset-demo-data" => handlers::reset_demo_data, Development;
    post "/api/v1/system/sync-db" => handlers::sync_db, Development;
    post "/api/v1/system/reset-to-initial-state" => handlers::reset_to_initial_state, Development;
    post "/api/v1/system/wipe-all-data" => handlers::wipe_all_data, Development;
    post "/api/v1/system/delete-all-data" => handlers::wipe_all_data, Development;
    post "/api/v1/system/fresh-start" => handlers::wipe_all_data, Development;
    post "/api/v1/system/purge-site/:site_id" => handlers::purge_site_cascade, Development;
    post "/api/v1/system/delete-site-cascade/:site_id" => handlers::purge_site_cascade, Development;
    post "/api/v1/system/recreate-db" => handlers::recreate_db, Development;
    post "/api/v1/system/accrue-test-due" => handlers::accrue_test_due, Development;
    post "/api/v1/system/seed-test-fixtures" => handlers::seed_test_fixtures, Development;
    post "/api/v1/system/seed-test-data" => handlers::seed_test_fixtures, Development;
    post "/api/v1/system/clear-all-data" => handlers::clear_all_data, Development;
    post "/api/v1/system/provision-site-units" => handlers::provision_site_units, Development;
    get "/api/v1/system/units-summary" => handlers::get_units_summary, Development;
    get "/api/v1/system/site-payments" => handlers::get_site_payments, Development;
    post "/api/v1/auth/refresh" => security::refresh, Public;
    post "/api/v1/auth/logout" => security::logout, SelfOnly;
    post "/api/v1/auth/logout-all" => security::logout_all, SelfOnly;
    post "/api/v1/auth/step-up" => security::step_up, SelfOnly;
    get "/api/v1/audit/events" => authorization::audit_events, Require(AuditLogRead);
    get "/api/v1/audit/export" => authorization::audit_events, Require(AuditLogExport);
    post "/api/v1/support/grants" => authorization::request_grant, Require(SupportAccess);
    post "/api/v1/support/grants/approve" => authorization::approve_grant, Require(SupportAccess);
    post "/api/v1/support/grants/revoke" => authorization::revoke_grant, Require(SupportAccess);
}
pub fn build_router(state: AppState) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(cors_origins())
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            HeaderName::from_static("idempotency-key"),
            HeaderName::from_static("x-sitepulse-support-grant"),
        ])
        .expose_headers([HeaderName::from_static("x-request-id")]);
    registered_routes()
        .layer(middleware::from_fn_with_state(
            state.clone(),
            auth::require_auth,
        ))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            audit::security_boundary,
        ))
        .layer(cors)
        .layer(middleware::from_fn(audit::correlate))
        .with_state(state)
}
pub fn dev_routes_enabled() -> bool {
    !state::AppStateInner::is_production()
        && std::env::var("SITEPULSE_ENABLE_DEV_ROUTES")
            .map(|v| v == "true")
            .unwrap_or(false)
}
/// Origins allowed by CORS: `SITEPULSE_CORS_ORIGINS` (comma separated), plus
/// localhost on any port outside production for local Flutter web development.
fn cors_origins() -> AllowOrigin {
    let configured: Vec<String> = std::env::var("SITEPULSE_CORS_ORIGINS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let allow_localhost = !state::AppStateInner::is_production();
    AllowOrigin::predicate(move |origin: &HeaderValue, _| {
        let Ok(o) = origin.to_str() else { return false };
        if configured.iter().any(|c| c == o) {
            return true;
        }
        allow_localhost
            && (o == "http://localhost"
                || o.starts_with("http://localhost:")
                || o == "http://127.0.0.1"
                || o.starts_with("http://127.0.0.1:"))
    })
}
