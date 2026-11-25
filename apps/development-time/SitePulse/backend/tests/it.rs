//! Consolidated SitePulse backend integration-test crate.

#[path = "it/aaa_security_tests.rs"]
mod aaa_security_tests;

#[path = "it/accrual_corrections_tests.rs"]
mod accrual_corrections_tests;

#[path = "it/accrual_schedule_tests.rs"]
mod accrual_schedule_tests;

#[path = "it/api_security_tests.rs"]
mod api_security_tests;

#[path = "it/architecture_flaws_regression_tests.rs"]
mod architecture_flaws_regression_tests;

#[path = "it/bank_multi_debtor_tests.rs"]
mod bank_multi_debtor_tests;

#[path = "it/billing_period_lifecycle_tests.rs"]
mod billing_period_lifecycle_tests;

#[path = "it/billing_period_tests.rs"]
mod billing_period_tests;

#[path = "it/capital_apportionment_tests.rs"]
mod capital_apportionment_tests;

#[allow(dead_code)]
#[path = "it/db_accrual_atomic_tests.rs"]
mod db_accrual_atomic_tests;

#[path = "it/db_accrual_persistence_tests.rs"]
mod db_accrual_persistence_tests;

#[path = "it/db_advance_exit_settlements_tests.rs"]
mod db_advance_exit_settlements_tests;

#[path = "it/db_capital_accrual_archived_units_tests.rs"]
mod db_capital_accrual_archived_units_tests;

#[path = "it/db_occupancy_transitions_tests.rs"]
mod db_occupancy_transitions_tests;

#[allow(dead_code)]
#[path = "it/db_person_api_tests.rs"]
mod db_person_api_tests;

#[path = "it/db_person_merge_tests.rs"]
mod db_person_merge_tests;

#[path = "it/db_site_local_date_tests.rs"]
mod db_site_local_date_tests;

#[path = "it/db_tenant_isolation_tests.rs"]
mod db_tenant_isolation_tests;

#[allow(dead_code)]
#[path = "it/db_unit_person_action_cycles_tests.rs"]
mod db_unit_person_action_cycles_tests;

#[cfg(feature = "e2e")]
#[path = "it/e2e_clock_reset_tests.rs"]
mod e2e_clock_reset_tests;

#[cfg(feature = "e2e")]
#[path = "it/e2e_clock_tests.rs"]
mod e2e_clock_tests;

#[path = "it/error_management_tests.rs"]
mod error_management_tests;

#[path = "it/finance_store_pg_tests.rs"]
mod finance_store_pg_tests;

#[path = "it/financial_fixtures.rs"]
mod financial_fixtures;

#[path = "it/integration_tests.rs"]
mod integration_tests;

#[path = "it/late_fee_consistency_tests.rs"]
mod late_fee_consistency_tests;

#[path = "it/late_fee_day_rows_tests.rs"]
mod late_fee_day_rows_tests;

#[path = "it/late_fee_reevaluation_tests.rs"]
mod late_fee_reevaluation_tests;

#[path = "it/notification_sender_tests.rs"]
mod notification_sender_tests;

#[path = "it/occupancy_proration_tests.rs"]
mod occupancy_proration_tests;

#[path = "it/occupancy_state_machine_tests.rs"]
mod occupancy_state_machine_tests;

#[path = "it/openapi_tests.rs"]
mod openapi_tests;

#[path = "it/payment_compliance_tests.rs"]
mod payment_compliance_tests;

#[path = "it/payment_ledger_hardening_tests.rs"]
mod payment_ledger_hardening_tests;

#[path = "it/payments_phase2_tests.rs"]
mod payments_phase2_tests;

#[path = "it/payments_phase3_tests.rs"]
mod payments_phase3_tests;

#[path = "it/person_records_tests.rs"]
mod person_records_tests;

#[path = "it/person_security_tests.rs"]
mod person_security_tests;

#[path = "it/reconciliation_assignment_tests.rs"]
mod reconciliation_assignment_tests;

#[path = "it/sale_clearance_tests.rs"]
mod sale_clearance_tests;

#[path = "it/shared_rules_tests.rs"]
mod shared_rules_tests;

#[path = "it/statement_access_tests.rs"]
mod statement_access_tests;

#[path = "it/supplementary_charge_tests.rs"]
mod supplementary_charge_tests;

#[path = "it/test_db.rs"]
mod test_db;

#[path = "it/support/mod.rs"]
mod support;

#[path = "it/money_rules_proptest.rs"]
mod money_rules_proptest;
