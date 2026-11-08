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
    get "/api/v1/payments/receipts/:id/pdf" => handlers::get_payment_receipt_pdf_logged, Require(UnitRead);
    get "/api/v1/public/receipts/verify" => handlers::verify_receipt, Public;
    post "/api/v1/payments/provider/webhook" => handlers::provider_webhook_v2, Public;
    get "/api/v1/payment-provider/sandbox/checkout/:reference" => handlers::sandbox_checkout_page, Public;
    post "/api/v1/payment-provider/sandbox/checkout/:reference/complete" => handlers::sandbox_checkout_complete, Public;
    get "/api/v1/residents/:unit_id/statement" => handlers::get_resident_statement_logged, Require(UnitRead);
    get "/api/v1/residents/:unit_id/operating-budget" => handlers::get_resident_operating_budget, Require(UnitRead);
    post "/api/v1/residents/:unit_id/payment-intents" => handlers::create_payment_intent_v2, Require(UnitPay);
    get "/api/v1/residents/:unit_id/payment-intents/:intent_id" => handlers::get_payment_intent, Require(UnitPay);
    get "/api/v1/operating-budgets" => handlers::list_operating_budgets, Require(SiteManage);
    post "/api/v1/operating-budgets" => handlers::create_operating_budget, Require(SiteManage);
    get "/api/v1/operating-budgets/compliance" => handlers::get_budget_compliance, Require(SiteManage);
    put "/api/v1/operating-budgets/policy" => handlers::set_budget_policy, Require(SiteManage);
    get "/api/v1/operating-budgets/:id" => handlers::get_operating_budget, Require(SiteManage);
    delete "/api/v1/operating-budgets/:id" => handlers::delete_operating_budget, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/issue-interim" => handlers::issue_interim_budget, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/approve" => handlers::approve_operating_budget, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/reject" => handlers::reject_operating_budget, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/finalize" => handlers::finalize_operating_budget, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/service" => handlers::record_budget_service, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/objections" => handlers::file_budget_objection, Require(SiteManage);
    post "/api/v1/operating-budgets/:id/objections/:objection_id/resolve" => handlers::resolve_budget_objection, Require(SiteManage);
    get "/api/v1/revaluation-rates" => handlers::list_revaluation_rates, SelfOnly;
    put "/api/v1/revaluation-rates" => handlers::set_revaluation_rate, Require(TenantManage);
    // SPEC-009 R1: budget legal basis and transition mode
    get "/api/v1/operating-budgets/legal-basis" => handlers::budget_legal_basis, Require(SiteManage);
    put "/api/v1/operating-budgets/transition" => handlers::set_budget_transition, Require(SiteManage);
    // SPEC-009 R2: KVKK (the caller's own notice and consents are SelfOnly, so every role reaches them)
    get "/api/v1/kvkk/me" => handlers::kvkk_status, SelfOnly;
    post "/api/v1/kvkk/me/acknowledge" => handlers::kvkk_acknowledge, SelfOnly;
    put "/api/v1/kvkk/me/consents" => handlers::kvkk_update_consents, SelfOnly;
    post "/api/v1/kvkk/privacy-notices" => handlers::publish_privacy_notice, Require(FinanceManage);
    get "/api/v1/kvkk/debtor-export" => handlers::debtor_export, RequireAny(&[FinanceManage, FinanceRead, UnitRead]);
    get "/api/v1/kvkk/access-log" => handlers::financial_access_log, Require(AuditLogRead);
    get "/api/v1/kvkk/retention" => handlers::retention_review, Require(FinanceManage);
    put "/api/v1/kvkk/retention" => handlers::set_retention_policy, Require(FinanceManage);
    post "/api/v1/kvkk/retention/purge" => handlers::retention_purge, Require(FinanceManage);
    // SPEC-009 R3: KMK 22 leases. The certificate stays under /payments/receipts/ so the
    // middleware resolves the receipt and checks the caller's unit relationship.
    get "/api/v1/leases" => handlers::list_leases, Require(FinanceManage);
    post "/api/v1/leases" => handlers::upsert_lease, Require(FinanceManage);
    get "/api/v1/leases/joint-exposure" => handlers::joint_exposure, Require(FinanceRead);
    get "/api/v1/payments/receipts/:id/rent-deduction-certificate" => handlers::rent_deduction_certificate, Require(UnitRead);
    // SPEC-009 R4: notifications and dunning
    get "/api/v1/notifications" => handlers::list_notifications, RequireAny(&[FinanceManage, FinanceRead, UnitRead]);
    post "/api/v1/notifications/broadcast" => handlers::broadcast_notification, Require(AnnouncementBroadcast);
    get "/api/v1/dunning/policy" => handlers::get_dunning_policy, Require(FinanceManage);
    put "/api/v1/dunning/policy" => handlers::set_dunning_policy, Require(FinanceManage);
    post "/api/v1/dunning/run" => handlers::run_dunning, Require(FinanceManage);
    get "/api/v1/dunning/actions" => handlers::dunning_actions, Require(FinanceRead);
    get "/api/v1/dunning/notice-letter/:due_id" => handlers::dunning_notice_letter, Require(FinanceManage);
    // SPEC-009 R5: resident requests
    get "/api/v1/residents/:unit_id/virman-requests" => handlers::unit_virman_requests, Require(UnitRead);
    post "/api/v1/residents/:unit_id/virman-requests" => handlers::create_virman_request, Require(UnitRead);
    get "/api/v1/residents/:unit_id/disputes" => handlers::unit_disputes, Require(UnitRead);
    post "/api/v1/residents/:unit_id/disputes" => handlers::create_dispute, Require(UnitRead);
    get "/api/v1/residents/:unit_id/payment-plans" => handlers::unit_plans, Require(UnitRead);
    get "/api/v1/resident-requests/virman" => handlers::site_virman_requests, Require(FinanceManage);
    post "/api/v1/resident-requests/virman/:id/decide" => handlers::decide_virman_request, Require(FinanceManage);
    get "/api/v1/resident-requests/disputes" => handlers::site_disputes, Require(FinanceManage);
    post "/api/v1/resident-requests/disputes/:id/resolve" => handlers::resolve_dispute, Require(FinanceManage);
    // SPEC-009 R6: autopay
    get "/api/v1/residents/:unit_id/autopay" => handlers::autopay_overview, Require(UnitPay);
    post "/api/v1/residents/:unit_id/autopay/mandates" => handlers::create_mandate, Require(UnitPay);
    post "/api/v1/residents/:unit_id/autopay/mandates/:mandate_id/cancel" => handlers::cancel_mandate, Require(UnitPay);
    post "/api/v1/autopay/run" => handlers::run_autopay, Require(FinanceManage);
    // SPEC-009 R7: expenses, general ledger, account report, reserve fund
    get "/api/v1/accounting/chart" => handlers::chart_of_accounts, Require(FinanceRead);
    get "/api/v1/accounting/vendors" => handlers::list_vendors, Require(FinanceRead);
    post "/api/v1/accounting/vendors" => handlers::create_vendor, Require(FinanceManage);
    get "/api/v1/accounting/approval-policy" => handlers::get_approval_policy, Require(FinanceRead);
    put "/api/v1/accounting/approval-policy" => handlers::set_approval_policy, Require(FinanceManage);
    get "/api/v1/accounting/expenses" => handlers::list_expenses, Require(FinanceRead);
    post "/api/v1/accounting/expenses" => handlers::create_expense, Require(FinanceManage);
    post "/api/v1/accounting/expenses/:id/approve" => handlers::approve_expense, Require(ExpenseApprove);
    post "/api/v1/accounting/expenses/:id/reject" => handlers::reject_expense, Require(ExpenseApprove);
    post "/api/v1/accounting/expenses/:id/payments" => handlers::pay_expense, Require(FinanceManage);
    get "/api/v1/accounting/journal" => handlers::journal, Require(FinanceRead);
    post "/api/v1/accounting/journal" => handlers::create_journal_entry, Require(FinanceManage);
    get "/api/v1/accounting/trial-balance" => handlers::trial_balance, Require(FinanceRead);
    get "/api/v1/accounting/budget-vs-actual" => handlers::budget_vs_actual, Require(FinanceRead);
    get "/api/v1/accounting/reserve-fund" => handlers::reserve_fund, Require(FinanceRead);
    get "/api/v1/accounting/account-report" => handlers::account_report, Require(FinanceRead);
    // SPEC-009 R8: collections and legal handover
    get "/api/v1/collections/cases" => handlers::list_cases, Require(FinanceRead);
    post "/api/v1/collections/cases" => handlers::open_case, Require(FinanceManage);
    get "/api/v1/collections/cases/:id" => handlers::get_case, Require(FinanceRead);
    post "/api/v1/collections/cases/:id/advance" => handlers::advance_case, Require(FinanceManage);
    get "/api/v1/collections/cases/:id/evidence-pack" => handlers::evidence_pack, Require(FinanceRead);
    post "/api/v1/collections/cases/:id/lawyer-access" => handlers::grant_lawyer_access, Require(FinanceManage);
    get "/api/v1/public/collection-cases/pack" => handlers::lawyer_pack, Public;
    // SPEC-009 R9: bank feeds, payer matching, daily reconciliation
    post "/api/v1/bank-matching/suggest" => handlers::suggest_matches, Require(ReconciliationConfirm);
    get "/api/v1/bank-matching/feeds" => handlers::list_bank_feeds, Require(ReconciliationConfirm);
    post "/api/v1/bank-matching/feeds" => handlers::create_bank_feed, Require(ReconciliationConfirm);
    post "/api/v1/bank-matching/feeds/:id/sync" => handlers::sync_bank_feed, Require(ReconciliationConfirm);
    get "/api/v1/bank-matching/daily-reconciliation" => handlers::reconciliation_runs, Require(ReconciliationConfirm);
    post "/api/v1/bank-matching/daily-reconciliation" => handlers::daily_reconciliation, Require(ReconciliationConfirm);
    // SPEC-009 R10: payment plans, waivers and write-offs
    get "/api/v1/payment-plans" => handlers::list_plans, Require(FinanceRead);
    post "/api/v1/payment-plans" => handlers::create_plan, Require(FinanceManage);
    post "/api/v1/payment-plans/run" => handlers::run_plans, Require(FinanceManage);
    post "/api/v1/payment-plans/:id/cancel" => handlers::cancel_plan, Require(FinanceManage);
    get "/api/v1/adjustments" => handlers::list_adjustments, Require(FinanceRead);
    post "/api/v1/adjustments" => handlers::request_adjustment, Require(FinanceManage);
    post "/api/v1/adjustments/:id/decide" => handlers::decide_adjustment, Require(AdjustmentApprove);
    // SPEC-009 R11: heat-share billing
    get "/api/v1/heat-share/periods" => handlers::list_heat_periods, Require(FinanceRead);
    post "/api/v1/heat-share/periods" => handlers::create_heat_period, Require(FinanceManage);
    get "/api/v1/heat-share/periods/:id" => handlers::get_heat_period, Require(FinanceRead);
    put "/api/v1/heat-share/periods/:id/readings" => handlers::record_heat_readings, Require(FinanceManage);
    post "/api/v1/heat-share/periods/:id/approve" => handlers::approve_heat_period, Require(FinanceManage);
    // SPEC-009 R12: assembly and decisions book
    get "/api/v1/assembly/meetings" => handlers::list_meetings, Require(GovernanceManage);
    post "/api/v1/assembly/meetings" => handlers::create_meeting, Require(GovernanceManage);
    get "/api/v1/assembly/meetings/:id" => handlers::get_meeting, Require(GovernanceManage);
    post "/api/v1/assembly/meetings/:id/attendance" => handlers::record_attendance, Require(GovernanceManage);
    post "/api/v1/assembly/agenda-items/:id/votes" => handlers::cast_votes, Require(GovernanceManage);
    post "/api/v1/assembly/agenda-items/:id/close" => handlers::close_agenda_item, Require(GovernanceManage);
    get "/api/v1/assembly/decisions" => handlers::list_decisions, RequireAny(&[GovernanceManage, FinanceRead, UnitRead]);
    post "/api/v1/assembly/decisions" => handlers::record_decision, Require(GovernanceManage);
    // SPEC-009 R13: management companies
    get "/api/v1/saas/companies" => handlers::list_companies, Require(TenantManage);
    post "/api/v1/saas/companies" => handlers::create_company, Require(TenantManage);
    post "/api/v1/saas/companies/:id/sites" => handlers::attach_company_site, Require(TenantManage);
    post "/api/v1/saas/companies/:id/members" => handlers::add_company_member, Require(TenantManage);
    get "/api/v1/saas/companies/:id/summary" => handlers::portfolio_summary, Require(TenantManage);
    get "/api/v1/saas/companies/:id/fee-invoices" => handlers::list_fee_invoices, Require(TenantManage);
    post "/api/v1/saas/companies/:id/fee-invoices" => handlers::issue_fee_invoices, Require(TenantManage);
    get "/api/v1/portfolio/companies/:id/summary" => handlers::portfolio_summary, Require(PortfolioRead);
    // SPEC-009 R14: analytics
    get "/api/v1/analytics/collections" => handlers::collection_analytics, Require(FinanceRead);
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
