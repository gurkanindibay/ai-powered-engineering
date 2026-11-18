//! Row mapping of the SPEC-009 records (`V20__payments_phase3.sql`).
//!
//! Each record names its table and columns once, in `finance_record!`; the
//! generic `insert`, `update`, `delete` and `load_all` below build their SQL from
//! that list. Column kinds:
//!
//! * `plain`: the field's own SQL type (text, int, bool, numeric, date, timestamptz)
//! * `id` / `opt_id`: a string reference to a BIGINT column (`site-1` -> 1)
//! * `json`: a serde value stored as JSONB

use rust_decimal::Decimal;
use tokio_postgres::types::ToSql;
use tokio_postgres::Row;

use super::{parse_id_to_i64, DbResult};
use crate::models::*;

pub type SqlParam = Box<dyn ToSql + Sync + Send>;

/// A table-backed SPEC-009 record with a store-assigned `BIGSERIAL` id.
pub trait Record: Sized + Clone + Send + Sync + 'static {
    const TABLE: &'static str;
    /// Every column except `id`, in `params` order.
    const COLUMNS: &'static [&'static str];
    fn id(&self) -> i64;
    fn set_id(&mut self, id: i64);
    fn params(&self) -> DbResult<Vec<SqlParam>>;
    fn from_row(row: &Row) -> DbResult<Self>;
}

pub(crate) fn id_param(column: &str, value: &str) -> DbResult<SqlParam> {
    let id = parse_id_to_i64(value)
        .ok_or_else(|| format!("{}: '{}' is not a database id", column, value))?;
    Ok(Box::new(id))
}

pub(crate) fn opt_id_param(column: &str, value: &Option<String>) -> DbResult<SqlParam> {
    match value {
        None => Ok(Box::new(Option::<i64>::None)),
        Some(v) => {
            let id = parse_id_to_i64(v)
                .ok_or_else(|| format!("{}: '{}' is not a database id", column, v))?;
            Ok(Box::new(Some(id)))
        }
    }
}

macro_rules! finance_record {
    ($ty:ident, $table:literal, { $($field:ident : $kind:ident),* $(,)? }) => {
        impl Record for $ty {
            const TABLE: &'static str = $table;
            const COLUMNS: &'static [&'static str] = &[$(stringify!($field)),*];
            fn id(&self) -> i64 {
                self.id
            }
            fn set_id(&mut self, id: i64) {
                self.id = id;
            }
            fn params(&self) -> DbResult<Vec<SqlParam>> {
                Ok(vec![$(finance_record!(@to $kind, self.$field, stringify!($field))),*])
            }
            fn from_row(row: &Row) -> DbResult<Self> {
                Ok(Self {
                    id: row.try_get("id")?,
                    $($field: finance_record!(@from $kind, row, stringify!($field)),)*
                })
            }
        }
    };
    (@to plain, $v:expr, $n:expr) => { Box::new($v.clone()) as SqlParam };
    (@to id, $v:expr, $n:expr) => { id_param($n, &$v)? };
    (@to opt_id, $v:expr, $n:expr) => { opt_id_param($n, &$v)? };
    (@to json, $v:expr, $n:expr) => { Box::new(serde_json::to_value(&$v)?) as SqlParam };
    (@from plain, $r:expr, $n:expr) => { $r.try_get($n)? };
    (@from id, $r:expr, $n:expr) => { $r.try_get::<_, i64>($n)?.to_string() };
    (@from opt_id, $r:expr, $n:expr) => { $r.try_get::<_, Option<i64>>($n)?.map(|v| v.to_string()) };
    (@from json, $r:expr, $n:expr) => { serde_json::from_value($r.try_get::<_, serde_json::Value>($n)?)? };
}

finance_record!(PrivacyNotice, "privacy_notices", {
    site_id: id, version: plain, title: plain, body: plain, published_at: plain, published_by: plain,
});
finance_record!(PrivacyAcknowledgement, "privacy_acknowledgements", {
    notice_id: plain, site_id: id, user_ref: plain, acknowledged_at: plain,
});
finance_record!(CommunicationConsent, "communication_consents", {
    site_id: id, user_ref: plain, channel: plain, granted: plain, updated_at: plain,
});
finance_record!(FinancialAccessLogEntry, "financial_access_log", {
    site_id: opt_id, actor: plain, actor_role: plain, action: plain, resource: plain,
    subject_unit_id: opt_id, detail: plain, occurred_at: plain,
});
finance_record!(RetentionPolicy, "data_retention_policies", {
    site_id: id, category: plain, retention_months: plain, updated_by: plain, updated_at: plain,
});
finance_record!(TenancyLease, "tenancy_leases", {
    site_id: id, unit_id: id, tenant_name: plain, tenant_user_ref: plain, monthly_rent: plain,
    lease_start: plain, lease_end: plain, rent_paid_through: plain, active: plain,
    created_by: plain, created_at: plain,
});
finance_record!(Notification, "notifications", {
    site_id: id, unit_id: opt_id, recipient_ref: plain, recipient_name: plain, channel: plain,
    category: plain, subject: plain, body: plain, status: plain, block_reason: plain,
    provider_ref: plain, dedupe_key: plain, created_at: plain, sent_at: plain,
});
finance_record!(DunningPolicy, "dunning_policies", {
    site_id: id, enabled: plain, steps: json, updated_by: plain, updated_at: plain,
});
finance_record!(DunningAction, "dunning_actions", {
    site_id: id, due_id: id, step_index: plain, kind: plain, channel: plain,
    notification_id: plain, executed_on: plain, outcome: plain,
});
finance_record!(VirmanRequest, "virman_requests", {
    site_id: id, unit_id: id, source_debtor: plain, target_debtor: plain, amount: plain,
    note: plain, requested_by: plain, status: plain, decided_by: plain, decided_at: plain,
    decision_note: plain, receipt_number: plain, created_at: plain,
});
finance_record!(LedgerDispute, "ledger_disputes", {
    site_id: id, unit_id: id, due_id: id, debtor_type: plain, reason: plain, raised_by: plain,
    status: plain, resolution_note: plain, resolved_by: plain, resolved_at: plain, created_at: plain,
});
finance_record!(SavedPaymentMethod, "saved_payment_methods", {
    site_id: id, unit_id: id, debtor_type: plain, owner_ref: plain, provider: plain,
    token_ref: plain, brand: plain, last4: plain, exp_month: plain, exp_year: plain,
    status: plain, created_at: plain,
});
finance_record!(AutopayMandate, "autopay_mandates", {
    site_id: id, unit_id: id, debtor_type: plain, payment_method_id: plain, max_amount: plain,
    status: plain, consented_by: plain, consented_at: plain, suspended_reason: plain,
    updated_at: plain,
});
finance_record!(AutopayAttempt, "autopay_attempts", {
    mandate_id: plain, due_id: id, attempt_no: plain, amount: plain, status: plain,
    provider_ref: plain, receipt_number: plain, failure_reason: plain, attempted_on: plain,
    next_retry_on: plain, created_at: plain,
});
finance_record!(Vendor, "vendors", {
    site_id: id, name: plain, tax_id: plain, iban: plain, email: plain, phone: plain,
    active: plain, created_at: plain,
});
finance_record!(ExpenseApprovalPolicy, "expense_approval_policies", {
    site_id: id, manager_limit: plain, updated_by: plain, updated_at: plain,
});
finance_record!(ExpenseInvoice, "expense_invoices", {
    site_id: id, vendor_id: plain, invoice_number: plain, invoice_date: plain, due_date: plain,
    category: plain, description: plain, net_amount: plain, vat_amount: plain,
    total_amount: plain, document_ref: plain, status: plain, budget_id: opt_id,
    approvals: json, rejection_reason: plain, created_by: plain, created_at: plain,
});
finance_record!(ExpensePayment, "expense_payments", {
    site_id: id, invoice_id: plain, amount: plain, paid_on: plain, method: plain,
    reference: plain, recorded_by: plain, created_at: plain,
});
finance_record!(ManualJournalEntry, "manual_journal_entries", {
    site_id: id, entry_date: plain, kind: plain, description: plain, created_by: plain,
    created_at: plain,
});
finance_record!(ManualJournalLine, "manual_journal_lines", {
    entry_id: plain, account_code: plain, debit: plain, credit: plain,
});
finance_record!(CollectionCase, "collection_cases", {
    site_id: id, unit_id: id, debtor_type: plain, due_ids: json, opened_amount: plain,
    status: plain, lawyer_name: plain, lawyer_contact: plain, lawyer_token_digest: plain,
    lawyer_token_expires_at: plain, opened_by: plain, opened_at: plain, closed_at: plain,
    note: plain,
});
finance_record!(CollectionCaseEvent, "collection_case_events", {
    case_id: plain, from_status: plain, to_status: plain, note: plain, actor: plain,
    occurred_on: plain, created_at: plain,
});
finance_record!(BankFeedConnection, "bank_feed_connections", {
    site_id: id, provider: plain, account_iban: plain, credential_ref: plain, status: plain,
    last_synced_at: plain, last_error: plain, created_at: plain,
});
finance_record!(BankReconciliationRun, "bank_reconciliation_runs", {
    site_id: id, business_date: plain, bank_movement: plain, ledger_movement: plain,
    difference: plain, bank_closing_balance: plain, details: plain, run_by: plain,
    created_at: plain,
});
finance_record!(PaymentPlan, "payment_plans", {
    site_id: id, unit_id: id, debtor_type: plain, due_ids: json, total_amount: plain,
    installment_count: plain, first_due_date: plain, grace_days: plain,
    waive_penalty_on_completion: plain, status: plain, opened_on: plain, created_by: plain,
    approved_by: plain, closed_on: plain, note: plain,
});
finance_record!(PaymentPlanInstallment, "payment_plan_installments", {
    plan_id: plain, seq: plain, due_date: plain, amount: plain,
});
finance_record!(LedgerAdjustment, "ledger_adjustments", {
    site_id: id, unit_id: id, due_id: id, kind: plain, amount: plain, reason: plain,
    source: plain, requested_by: plain, requested_at: plain, status: plain,
    decided_by: plain, decided_at: plain, decision_note: plain, principal_before: plain,
    penalty_before: plain, booked_on: plain,
});
finance_record!(AccrualCorrection, "accrual_corrections", {
    site_id: id, unit_id: id, due_id: id, period: plain, debtor_type: plain, kind: plain,
    amount: plain, new_due_date: plain, new_debtor_type: plain, reason: plain,
    requested_by: plain, requested_at: plain, status: plain, decided_by: plain,
    decided_at: plain, decision_note: plain, principal_before: plain, penalty_before: plain,
    paid_before: plain, penalty_reversed: plain, advance_credited: plain,
    replacement_due_id: opt_id,
});
finance_record!(LateFeeAccrual, "late_fee_accruals", {
    site_id: id, due_id: id, accrual_date: plain, booked_on: plain, outstanding_principal: plain,
    segment_start: plain, segment_base: plain, cumulative_fee: plain, daily_amount: plain,
});
finance_record!(HeatCostPeriod, "heat_cost_periods", {
    site_id: id, label: plain, period_start: plain, period_end: plain, total_cost: plain,
    consumption_share_percent: plain, due_date: plain, status: plain, approved_by: plain,
    approved_at: plain, created_by: plain, created_at: plain,
});
finance_record!(HeatMeterReading, "heat_meter_readings", {
    period_id: plain, unit_id: id, area_weight: plain, previous_reading: plain,
    current_reading: plain,
});
finance_record!(HeatCostShare, "heat_cost_shares", {
    period_id: plain, unit_id: id, fixed_amount: plain, consumption_amount: plain,
    total_amount: plain, due_id: opt_id,
});
finance_record!(AssemblyMeeting, "assembly_meetings", {
    site_id: id, kind: plain, call_number: plain, scheduled_at: plain, location: plain,
    status: plain, held_on: plain, created_by: plain, created_at: plain,
});
finance_record!(AssemblyAgendaItem, "assembly_agenda_items", {
    meeting_id: plain, seq: plain, title: plain, description: plain, rule: plain,
    linked_budget_id: opt_id, status: plain, decision_id: plain,
});
finance_record!(AssemblyAttendance, "assembly_attendance", {
    meeting_id: plain, unit_id: id, attendee_name: plain, is_proxy: plain,
});
finance_record!(AssemblyVote, "assembly_votes", {
    agenda_item_id: plain, unit_id: id, vote: plain,
});
finance_record!(AssemblyDecision, "assembly_decisions", {
    site_id: id, meeting_id: plain, decision_number: plain, decided_on: plain, title: plain,
    text: plain, outcome: plain, rule: plain, yes_count: plain, no_count: plain,
    abstain_count: plain, yes_land_share: plain, total_land_share: plain,
    linked_budget_id: opt_id, attachment_ref: plain, recorded_by: plain, created_at: plain,
});
finance_record!(ManagementCompany, "management_companies", {
    name: plain, tax_id: plain, tax_office: plain, address: plain, created_at: plain,
});
finance_record!(ManagementCompanySite, "management_company_sites", {
    company_id: plain, site_id: id, monthly_fee: plain, vat_rate: plain, active: plain,
});
finance_record!(ManagementCompanyMember, "management_company_members", {
    company_id: plain, user_ref: plain,
});
finance_record!(FeeInvoice, "fee_invoices", {
    company_id: plain, site_id: id, period: plain, net_amount: plain, vat_amount: plain,
    total_amount: plain, document_type: plain, status: plain, integrator: plain,
    integrator_uuid: plain, issued_at: plain,
});

fn placeholders(n: usize, start: usize) -> String {
    (start..start + n)
        .map(|i| format!("${}", i))
        .collect::<Vec<_>>()
        .join(", ")
}

fn as_refs(params: &[SqlParam]) -> Vec<&(dyn ToSql + Sync)> {
    params
        .iter()
        .map(|p| p.as_ref() as &(dyn ToSql + Sync))
        .collect()
}

/// Inserts `record` and returns its new id.
pub async fn insert<T: Record>(
    client: &impl tokio_postgres::GenericClient,
    record: &T,
) -> DbResult<i64> {
    let params = record.params()?;
    let sql = format!(
        "INSERT INTO {} ({}) VALUES ({}) RETURNING id",
        T::TABLE,
        T::COLUMNS.join(", "),
        placeholders(T::COLUMNS.len(), 1)
    );
    let row = client.query_one(&sql, &as_refs(&params)).await?;
    Ok(row.try_get(0)?)
}

/// Writes every column of an existing record.
pub async fn update<T: Record>(
    client: &impl tokio_postgres::GenericClient,
    record: &T,
) -> DbResult<()> {
    let mut params = record.params()?;
    let assignments: Vec<String> = T::COLUMNS
        .iter()
        .enumerate()
        .map(|(i, c)| format!("{} = ${}", c, i + 1))
        .collect();
    params.push(Box::new(record.id()));
    let sql = format!(
        "UPDATE {} SET {} WHERE id = ${}",
        T::TABLE,
        assignments.join(", "),
        params.len()
    );
    let changed = client.execute(&sql, &as_refs(&params)).await?;
    if changed != 1 {
        return Err(format!("{} {} was not found", T::TABLE, record.id()).into());
    }
    Ok(())
}

pub async fn delete<T: Record>(
    client: &impl tokio_postgres::GenericClient,
    id: i64,
) -> DbResult<()> {
    let sql = format!("DELETE FROM {} WHERE id = $1", T::TABLE);
    client.execute(&sql, &[&id]).await?;
    Ok(())
}

pub async fn load_all<T: Record>(client: &impl tokio_postgres::GenericClient) -> DbResult<Vec<T>> {
    let sql = format!(
        "SELECT id, {} FROM {} ORDER BY id",
        T::COLUMNS.join(", "),
        T::TABLE
    );
    client
        .query(&sql, &[])
        .await?
        .iter()
        .map(T::from_row)
        .collect()
}

/// Lowers what a liability owes after an approved waiver or write-off, and sets
/// the status that matches its paid amounts (`chk_dues_paid_status_consistent`).
pub async fn apply_due_adjustment(
    client: &impl tokio_postgres::GenericClient,
    due_id: &str,
    principal: Decimal,
    penalty: Decimal,
) -> DbResult<()> {
    let id = parse_id_to_i64(due_id).ok_or_else(|| format!("Invalid due id '{}'", due_id))?;
    let changed = client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET principal_amount = $2,
                delay_penalty = $3,
                status = CASE
                    WHEN paid_principal >= $2 AND paid_penalty >= $3 THEN 'PAID'
                    WHEN paid_amount > 0 THEN 'PARTIALLY_PAID'
                    WHEN status = 'PAID' THEN 'PENDING'
                    ELSE status END,
                version = version + 1
            WHERE id = $1 AND paid_principal <= $2 AND paid_penalty <= $3
            "#,
            &[&id, &principal, &penalty],
        )
        .await?;
    if changed != 1 {
        return Err(format!(
            "Liability {} was not adjusted: it does not exist or is already paid beyond the new amount",
            due_id
        )
        .into());
    }
    Ok(())
}

/// Liabilities' budget legal basis, the budget line weights and the site
/// transition dates are columns of SPEC-007 tables.
pub async fn set_site_budget_transition(
    client: &impl tokio_postgres::GenericClient,
    site_id: &str,
    until: Option<chrono::NaiveDate>,
) -> DbResult<()> {
    let id = parse_id_to_i64(site_id).ok_or_else(|| format!("Invalid site id '{}'", site_id))?;
    client
        .execute(
            "UPDATE sites SET budget_transition_until = $2 WHERE id = $1",
            &[&id, &until],
        )
        .await?;
    Ok(())
}

pub async fn load_site_budget_transitions(
    client: &impl tokio_postgres::GenericClient,
) -> DbResult<Vec<(String, chrono::NaiveDate)>> {
    Ok(client
        .query(
            "SELECT id, budget_transition_until FROM sites WHERE budget_transition_until IS NOT NULL",
            &[],
        )
        .await?
        .iter()
        .filter_map(|r| {
            let id: i64 = r.get(0);
            r.get::<_, Option<chrono::NaiveDate>>(1)
                .map(|d| (id.to_string(), d))
        })
        .collect())
}

pub async fn set_budget_decision(
    client: &impl tokio_postgres::GenericClient,
    budget_id: &str,
    decision_id: i64,
) -> DbResult<()> {
    let id =
        parse_id_to_i64(budget_id).ok_or_else(|| format!("Invalid budget id '{}'", budget_id))?;
    client
        .execute(
            "UPDATE operating_budgets SET assembly_decision_id = $2 WHERE id = $1",
            &[&id, &decision_id],
        )
        .await?;
    Ok(())
}

/// Card instalments and the save-card flag of an intent.
pub async fn set_intent_options(
    client: &impl tokio_postgres::GenericClient,
    intent_id: &str,
    installments: i32,
    save_card: bool,
) -> DbResult<()> {
    let id =
        parse_id_to_i64(intent_id).ok_or_else(|| format!("Invalid intent id '{}'", intent_id))?;
    client
        .execute(
            "UPDATE payment_intents SET installment_count = $2, save_card = $3 WHERE id = $1",
            &[&id, &installments, &save_card],
        )
        .await?;
    Ok(())
}

pub async fn load_intent_options(
    client: &impl tokio_postgres::GenericClient,
) -> DbResult<Vec<(String, i32, bool)>> {
    Ok(client
        .query(
            "SELECT id, installment_count, save_card FROM payment_intents WHERE installment_count <> 1 OR save_card",
            &[],
        )
        .await?
        .iter()
        .map(|r| {
            let id: i64 = r.get(0);
            (id.to_string(), r.get(1), r.get(2))
        })
        .collect())
}

/// Units of a site whose owner or tenant has this national id. National ids
/// are stored only as an HMAC digest (V15), so the lookup compares digests.
pub async fn units_by_national_id(
    client: &impl tokio_postgres::GenericClient,
    site_id: &str,
    national_id: &str,
) -> DbResult<Vec<String>> {
    let site = parse_id_to_i64(site_id).ok_or_else(|| format!("Invalid site id '{}'", site_id))?;
    Ok(client
        .query(
            r#"
            SELECT u.id FROM units u
            JOIN persons p ON p.id IN (u.owner_person_id, u.tenant_person_id)
            WHERE u.site_id = $1
              AND p.national_id_hash = encode(hmac(convert_to($2, 'UTF8'),
                    (SELECT hmac_key FROM pii_settings LIMIT 1), 'sha256'), 'hex')
            "#,
            &[&site, &national_id],
        )
        .await?
        .iter()
        .map(|r| r.get::<_, i64>(0).to_string())
        .collect())
}
