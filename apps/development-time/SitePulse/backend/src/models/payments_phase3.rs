//! SPEC-009 models: KVKK controls, KMK 22 leases, notifications and dunning,
//! resident requests, autopay, expenses and the general ledger, collections,
//! bank matching, payment plans and adjustments, heat-share billing, the
//! assembly and decisions book, management companies and analytics.
//!
//! Persisted records carry an `i64` id assigned by the store; site, unit and
//! liability references are the string ids used everywhere else.

use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Vocabularies
// ---------------------------------------------------------------------------

pub const ACCESS_VIEW: &str = "VIEW";
pub const ACCESS_EXPORT: &str = "EXPORT";
pub const ACCESS_BLOCKED: &str = "BLOCKED";

pub const RETENTION_CATEGORIES: [&str; 5] = [
    "FINANCIAL_RECORDS",
    "ACCESS_LOG",
    "NOTIFICATIONS",
    "SENDER_IBANS",
    "STATEMENTS",
];

pub const NOTIFY_SENT: &str = "SENT";
pub const NOTIFY_BLOCKED: &str = "BLOCKED";
pub const NOTIFY_FAILED: &str = "FAILED";

pub const NOTIFICATION_CATEGORIES: [&str; 9] = [
    "DEBT_REMINDER",
    "DEBT_NOTICE",
    "PAYMENT",
    "AUTOPAY",
    "PLAN",
    "BUDGET",
    "COLLECTION",
    "SYSTEM",
    "ANNOUNCEMENT",
];

pub const REQUEST_PENDING: &str = "PENDING";
pub const REQUEST_APPROVED: &str = "APPROVED";
pub const REQUEST_REJECTED: &str = "REJECTED";

pub const DISPUTE_OPEN: &str = "OPEN";
pub const DISPUTE_ACCEPTED: &str = "ACCEPTED";
pub const DISPUTE_REJECTED: &str = "REJECTED";

pub const MANDATE_ACTIVE: &str = "ACTIVE";
pub const MANDATE_SUSPENDED: &str = "SUSPENDED";
pub const MANDATE_CANCELLED: &str = "CANCELLED";

pub const EXPENSE_PENDING: &str = "PENDING_APPROVAL";
pub const EXPENSE_APPROVED: &str = "APPROVED";
pub const EXPENSE_PARTIALLY_PAID: &str = "PARTIALLY_PAID";
pub const EXPENSE_PAID: &str = "PAID";
pub const EXPENSE_REJECTED: &str = "REJECTED";
pub const EXPENSE_CANCELLED: &str = "CANCELLED";

pub const CASE_STATUSES: [&str; 7] = [
    "REMINDED",
    "NOTICE_SENT",
    "MEDIATION",
    "LAWYER_ASSIGNED",
    "ICRA_FILED",
    "COLLECTED",
    "WRITTEN_OFF",
];

pub const PLAN_ACTIVE: &str = "ACTIVE";
pub const PLAN_COMPLETED: &str = "COMPLETED";
pub const PLAN_BROKEN: &str = "BROKEN";
pub const PLAN_CANCELLED: &str = "CANCELLED";

pub const ADJUSTMENT_PENALTY_WAIVER: &str = "PENALTY_WAIVER";
pub const ADJUSTMENT_WRITE_OFF: &str = "PRINCIPAL_WRITE_OFF";
/// System-generated reversal of late fee that a backdated payment makes
/// unwarranted (#187). Never requested by a user.
pub const ADJUSTMENT_PENALTY_REEVALUATION: &str = "PENALTY_REEVALUATION";
/// `LedgerAdjustment::source` of a re-evaluation caused by a payment's value date.
pub const ADJUSTMENT_SOURCE_PAYMENT_DATE: &str = "PAYMENT_DATE";

// ---------------------------------------------------------------------------
// R2: KVKK
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivacyNotice {
    pub id: i64,
    pub site_id: String,
    pub version: i32,
    pub title: String,
    pub body: String,
    pub published_at: DateTime<Utc>,
    pub published_by: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrivacyAcknowledgement {
    pub id: i64,
    pub notice_id: i64,
    pub site_id: String,
    pub user_ref: String,
    pub acknowledged_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CommunicationConsent {
    pub id: i64,
    pub site_id: String,
    pub user_ref: String,
    pub channel: String,
    pub granted: bool,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FinancialAccessLogEntry {
    pub id: i64,
    pub site_id: Option<String>,
    pub actor: String,
    pub actor_role: String,
    pub action: String,
    pub resource: String,
    pub subject_unit_id: Option<String>,
    pub detail: Option<String>,
    pub occurred_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RetentionPolicy {
    pub id: i64,
    pub site_id: String,
    pub category: String,
    pub retention_months: i32,
    pub updated_by: String,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishPrivacyNoticeRequest {
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConsentUpdate {
    pub channel: String,
    pub granted: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateConsentsRequest {
    pub consents: Vec<ConsentUpdate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrivacyStatus {
    pub current_notice: Option<PrivacyNotice>,
    pub acknowledged: bool,
    pub acknowledged_at: Option<DateTime<Utc>>,
    /// One row per consentable channel; a channel without a record is granted.
    pub consents: Vec<ConsentUpdate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebtorExportRow {
    pub unit_label: String,
    pub debtor_type: String,
    /// The debtor's name, masked for callers who are not site staff.
    pub debtor_name: String,
    pub open_amount: Decimal,
    pub overdue_amount: Decimal,
    pub oldest_due_date: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebtorExport {
    pub site_id: String,
    pub masked: bool,
    pub generated_at: DateTime<Utc>,
    pub rows: Vec<DebtorExportRow>,
    pub total_open: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetRetentionPolicyRequest {
    pub category: String,
    pub retention_months: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetentionReviewRow {
    pub category: String,
    pub retention_months: i32,
    pub records_past_retention: usize,
    /// Whether SitePulse purges these automatically (logs) or a person must decide (ledger data).
    pub purgeable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetentionReview {
    pub site_id: String,
    pub rows: Vec<RetentionReviewRow>,
    pub purged: usize,
}

// ---------------------------------------------------------------------------
// R3: KMK 22 leases
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TenancyLease {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub tenant_name: String,
    pub tenant_user_ref: Option<String>,
    pub monthly_rent: Decimal,
    pub lease_start: NaiveDate,
    pub lease_end: Option<NaiveDate>,
    pub rent_paid_through: Option<NaiveDate>,
    pub active: bool,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpsertLeaseRequest {
    pub unit_id: String,
    pub tenant_name: String,
    #[serde(default)]
    pub tenant_user_ref: Option<String>,
    pub monthly_rent: Decimal,
    pub lease_start: NaiveDate,
    #[serde(default)]
    pub lease_end: Option<NaiveDate>,
    #[serde(default)]
    pub rent_paid_through: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JointExposureRow {
    pub unit_id: String,
    pub unit_label: String,
    pub tenant_name: String,
    pub monthly_rent: Decimal,
    pub claimable_rent_months: u32,
    pub rent_cap: Decimal,
    pub owner_open_operational: Decimal,
    /// What may be claimed from the tenant for the owner's items (KMK 22, verify).
    pub claimable_from_tenant: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JointExposureReport {
    pub site_id: String,
    pub as_of: NaiveDate,
    pub rows: Vec<JointExposureRow>,
    pub total_claimable: Decimal,
    pub legal_note: String,
}

// ---------------------------------------------------------------------------
// R4: notifications and dunning
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Notification {
    pub id: i64,
    pub site_id: String,
    pub unit_id: Option<String>,
    pub recipient_ref: String,
    pub recipient_name: String,
    pub channel: String,
    pub category: String,
    pub subject: String,
    pub body: String,
    pub status: String,
    pub block_reason: Option<String>,
    pub provider_ref: Option<String>,
    pub dedupe_key: String,
    pub created_at: DateTime<Utc>,
    pub sent_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DunningStepDto {
    pub day_offset: u32,
    pub channel: String,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DunningPolicy {
    pub id: i64,
    pub site_id: String,
    pub enabled: bool,
    pub steps: Vec<DunningStepDto>,
    pub updated_by: String,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetDunningPolicyRequest {
    pub enabled: bool,
    pub steps: Vec<DunningStepDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DunningAction {
    pub id: i64,
    pub site_id: String,
    pub due_id: String,
    pub step_index: i32,
    pub kind: String,
    pub channel: String,
    pub notification_id: Option<i64>,
    pub executed_on: NaiveDate,
    pub outcome: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DunningRunRequest {
    #[serde(default)]
    pub as_of: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DunningRunReport {
    pub site_id: String,
    pub as_of: Option<NaiveDate>,
    pub examined: usize,
    pub sent: usize,
    pub blocked: usize,
    pub failed: usize,
    /// Liabilities skipped because they are disputed, in a plan or with a lawyer.
    pub paused: usize,
    pub actions: Vec<DunningAction>,
}

// ---------------------------------------------------------------------------
// R5: resident requests
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct VirmanRequest {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub source_debtor: String,
    pub target_debtor: String,
    pub amount: Decimal,
    pub note: Option<String>,
    pub requested_by: String,
    pub status: String,
    pub decided_by: Option<String>,
    pub decided_at: Option<DateTime<Utc>>,
    pub decision_note: Option<String>,
    pub receipt_number: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateVirmanRequest {
    pub amount: Decimal,
    /// The debtor whose advance is moved; residents may only name their own.
    #[serde(default)]
    pub source_debtor: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DecideRequest {
    pub approve: bool,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LedgerDispute {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub due_id: String,
    pub debtor_type: String,
    pub reason: String,
    pub raised_by: String,
    pub status: String,
    pub resolution_note: Option<String>,
    pub resolved_by: Option<String>,
    pub resolved_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDisputeRequest {
    pub due_id: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolveDisputeRequest {
    pub accept: bool,
    pub note: String,
}

// ---------------------------------------------------------------------------
// R6: autopay
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SavedPaymentMethod {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub debtor_type: String,
    pub owner_ref: String,
    pub provider: String,
    /// The provider's token; never sent to clients.
    #[serde(skip_serializing, default)]
    pub token_ref: String,
    pub brand: String,
    pub last4: String,
    pub exp_month: i32,
    pub exp_year: i32,
    pub status: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AutopayMandate {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub debtor_type: String,
    pub payment_method_id: i64,
    pub max_amount: Option<Decimal>,
    pub status: String,
    pub consented_by: String,
    pub consented_at: DateTime<Utc>,
    pub suspended_reason: Option<String>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AutopayAttempt {
    pub id: i64,
    pub mandate_id: i64,
    pub due_id: String,
    pub attempt_no: i32,
    pub amount: Decimal,
    pub status: String,
    pub provider_ref: Option<String>,
    pub receipt_number: Option<String>,
    pub failure_reason: Option<String>,
    pub attempted_on: NaiveDate,
    pub next_retry_on: Option<NaiveDate>,
    pub created_at: DateTime<Utc>,
}

/// The card token a provider returns when a hosted payment saved the card.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderCardToken {
    pub token: String,
    pub brand: String,
    pub last4: String,
    pub exp_month: i32,
    pub exp_year: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateMandateRequest {
    pub payment_method_id: i64,
    #[serde(default)]
    pub debtor_type: Option<String>,
    #[serde(default)]
    pub max_amount: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AutopayOverview {
    pub payment_methods: Vec<SavedPaymentMethod>,
    pub mandates: Vec<AutopayMandate>,
    pub attempts: Vec<AutopayAttempt>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AutopayRunReport {
    pub as_of: Option<NaiveDate>,
    pub charged: usize,
    pub declined: usize,
    pub suspended: usize,
    pub attempts: Vec<AutopayAttempt>,
}

// ---------------------------------------------------------------------------
// R7: expenses and the general ledger
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Vendor {
    pub id: i64,
    pub site_id: String,
    pub name: String,
    pub tax_id: String,
    pub iban: Option<String>,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub active: bool,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateVendorRequest {
    pub name: String,
    pub tax_id: String,
    #[serde(default)]
    pub iban: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub phone: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExpenseApprovalPolicy {
    pub id: i64,
    pub site_id: String,
    pub manager_limit: Decimal,
    pub updated_by: String,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExpenseApproval {
    pub approver: String,
    pub role: String,
    pub approved_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExpenseInvoice {
    pub id: i64,
    pub site_id: String,
    pub vendor_id: i64,
    pub invoice_number: String,
    pub invoice_date: NaiveDate,
    pub due_date: Option<NaiveDate>,
    pub category: String,
    pub description: Option<String>,
    pub net_amount: Decimal,
    pub vat_amount: Decimal,
    pub total_amount: Decimal,
    pub document_ref: Option<String>,
    pub status: String,
    pub budget_id: Option<String>,
    pub approvals: Vec<ExpenseApproval>,
    pub rejection_reason: Option<String>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateExpenseRequest {
    pub vendor_id: i64,
    pub invoice_number: String,
    pub invoice_date: NaiveDate,
    #[serde(default)]
    pub due_date: Option<NaiveDate>,
    pub category: String,
    #[serde(default)]
    pub description: Option<String>,
    pub net_amount: Decimal,
    #[serde(default)]
    pub vat_amount: Decimal,
    #[serde(default)]
    pub document_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RejectExpenseRequest {
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ExpensePayment {
    pub id: i64,
    pub site_id: String,
    pub invoice_id: i64,
    pub amount: Decimal,
    pub paid_on: NaiveDate,
    pub method: String,
    pub reference: Option<String>,
    pub recorded_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PayExpenseRequest {
    pub amount: Decimal,
    #[serde(default)]
    pub paid_on: Option<NaiveDate>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub reference: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExpenseView {
    #[serde(flatten)]
    pub invoice: ExpenseInvoice,
    pub vendor_name: String,
    pub paid_amount: Decimal,
    pub open_amount: Decimal,
    /// Whether the auditor's approval is still needed (total above the manager limit).
    pub needs_auditor: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetApprovalPolicyRequest {
    pub manager_limit: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManualJournalEntry {
    pub id: i64,
    pub site_id: String,
    pub entry_date: NaiveDate,
    pub kind: String,
    pub description: String,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManualJournalLine {
    pub id: i64,
    pub entry_id: i64,
    pub account_code: String,
    pub debit: Decimal,
    pub credit: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalLineInput {
    pub account_code: String,
    #[serde(default)]
    pub debit: Decimal,
    #[serde(default)]
    pub credit: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateJournalEntryRequest {
    #[serde(default)]
    pub entry_date: Option<NaiveDate>,
    #[serde(default)]
    pub kind: Option<String>,
    pub description: String,
    pub lines: Vec<JournalLineInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalLineView {
    pub account_code: String,
    pub account_name: String,
    pub debit: Decimal,
    pub credit: Decimal,
}

/// A generated or manual journal entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalEntryView {
    pub date: NaiveDate,
    /// `ACCRUAL`, `PENALTY`, `RECEIPT`, `REVERSAL`, `ADVANCE_USE`, `WAIVER`,
    /// `WRITE_OFF`, `EXPENSE`, `EXPENSE_PAYMENT`, `CAPITAL_DISBURSEMENT` or a manual kind.
    pub source: String,
    pub reference: String,
    pub description: String,
    pub lines: Vec<JournalLineView>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrialBalanceRowView {
    pub account_code: String,
    pub account_name: String,
    pub debit: Decimal,
    pub credit: Decimal,
    pub balance: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrialBalance {
    pub site_id: String,
    pub from: Option<NaiveDate>,
    pub to: Option<NaiveDate>,
    pub rows: Vec<TrialBalanceRowView>,
    pub total_debit: Decimal,
    pub total_credit: Decimal,
    pub balanced: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetVsActualRow {
    pub category: String,
    pub budgeted: Decimal,
    pub actual: Decimal,
    pub variance: Decimal,
    /// actual / budgeted × 100; `None` without a budget for the category.
    pub used_percent: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetVsActual {
    pub site_id: String,
    pub budget_id: Option<String>,
    pub fiscal_year: i32,
    pub rows: Vec<BudgetVsActualRow>,
    pub total_budgeted: Decimal,
    pub total_actual: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReserveFundStatus {
    pub site_id: String,
    pub fiscal_year: i32,
    /// The yearly RESERVE lines of the budget in force.
    pub target: Decimal,
    pub allocated: Decimal,
    pub used: Decimal,
    pub balance: Decimal,
    pub target_reached_percent: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountReport {
    pub site_id: String,
    pub site_name: String,
    pub fiscal_year: i32,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub opening_cash: Decimal,
    pub closing_cash: Decimal,
    pub dues_accrued: Decimal,
    pub penalties_accrued: Decimal,
    pub collected: Decimal,
    pub expenses_by_category: Vec<BudgetVsActualRow>,
    pub total_expenses: Decimal,
    pub expenses_paid: Decimal,
    pub receivables_outstanding: Decimal,
    pub payables_outstanding: Decimal,
    pub advances_held: Decimal,
    pub reserve_balance: Decimal,
    pub waivers_and_write_offs: Decimal,
    pub trial_balance_balanced: bool,
    pub generated_at: DateTime<Utc>,
}

// ---------------------------------------------------------------------------
// R8: collections
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CollectionCase {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub debtor_type: String,
    pub due_ids: Vec<String>,
    pub opened_amount: Decimal,
    pub status: String,
    pub lawyer_name: Option<String>,
    pub lawyer_contact: Option<String>,
    #[serde(skip_serializing, default)]
    pub lawyer_token_digest: Option<String>,
    pub lawyer_token_expires_at: Option<DateTime<Utc>>,
    pub opened_by: String,
    pub opened_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CollectionCaseEvent {
    pub id: i64,
    pub case_id: i64,
    pub from_status: Option<String>,
    pub to_status: String,
    pub note: Option<String>,
    pub actor: String,
    pub occurred_on: NaiveDate,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenCaseRequest {
    pub unit_id: String,
    #[serde(default)]
    pub debtor_type: Option<String>,
    /// Defaults to every overdue item of the debtor.
    #[serde(default)]
    pub due_ids: Vec<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AdvanceCaseRequest {
    pub to_status: String,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub occurred_on: Option<NaiveDate>,
    #[serde(default)]
    pub lawyer_name: Option<String>,
    #[serde(default)]
    pub lawyer_contact: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LimitationWarning {
    pub due_id: String,
    pub period: String,
    pub due_date: NaiveDate,
    pub limitation_date: NaiveDate,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaseView {
    #[serde(flatten)]
    pub case: CollectionCase,
    pub unit_label: String,
    pub outstanding: Decimal,
    pub events: Vec<CollectionCaseEvent>,
    /// ICRA_FILED events against this owner in the last 2 years (KMK 25).
    pub kmk25_enforcements_in_two_years: usize,
    pub kmk25_threshold_reached: bool,
    pub limitation_warnings: Vec<LimitationWarning>,
    /// Whether every item has a legal basis, so the evidence pack can be built.
    pub evidence_ready: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PenaltyDay {
    pub from: NaiveDate,
    pub to: NaiveDate,
    pub days: i64,
    pub principal_base: Decimal,
    pub penalty: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceItem {
    pub due_id: String,
    pub period: String,
    pub expense_type: String,
    pub due_date: NaiveDate,
    pub principal: Decimal,
    pub paid: Decimal,
    pub penalty_accrued: Decimal,
    pub outstanding: Decimal,
    /// "Operating budget 2027 #4 (KMK 37)" or "Capital project #2 (assembly decision ...)".
    pub legal_basis: String,
    pub penalty_breakdown: Vec<PenaltyDay>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidencePack {
    pub case_id: i64,
    pub site_name: String,
    pub unit_label: String,
    pub debtor_type: String,
    pub debtor_name: String,
    pub budget: Option<crate::models::OperatingBudget>,
    pub service_record: Option<crate::models::BudgetServiceRecord>,
    pub items: Vec<EvidenceItem>,
    pub receipts: Vec<crate::models::StatementReceipt>,
    pub total_outstanding: Decimal,
    pub generated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LawyerAccessGrant {
    pub case_id: i64,
    /// Shown once; only its digest is stored.
    pub token: String,
    pub expires_at: DateTime<Utc>,
    pub pack_url: String,
}

// ---------------------------------------------------------------------------
// R9: bank matching and feeds
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BankFeedConnection {
    pub id: i64,
    pub site_id: String,
    pub provider: String,
    pub account_iban: String,
    pub credential_ref: Option<String>,
    pub status: String,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateBankFeedRequest {
    pub provider: String,
    pub account_iban: String,
    #[serde(default)]
    pub credential_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BankReconciliationRun {
    pub id: i64,
    pub site_id: String,
    pub business_date: NaiveDate,
    pub bank_movement: Decimal,
    pub ledger_movement: Decimal,
    pub difference: Decimal,
    pub bank_closing_balance: Option<Decimal>,
    pub details: serde_json::Value,
    pub run_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferToMatch {
    #[serde(default)]
    pub reference: Option<String>,
    pub amount: Decimal,
    pub description: String,
    #[serde(default)]
    pub sender_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchCandidate {
    pub unit_id: String,
    pub unit_label: String,
    /// 0–100.
    pub confidence: u32,
    pub reasons: Vec<String>,
    pub open_amount: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchSuggestion {
    pub reference: Option<String>,
    pub amount: Decimal,
    pub description: String,
    pub candidates: Vec<MatchCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchRequest {
    pub transfers: Vec<TransferToMatch>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankLine {
    #[serde(default)]
    pub reference: Option<String>,
    /// Positive for money in, negative for money out.
    pub amount: Decimal,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DailyReconciliationRequest {
    pub business_date: NaiveDate,
    #[serde(default)]
    pub bank_closing_balance: Option<Decimal>,
    pub lines: Vec<BankLine>,
}

// ---------------------------------------------------------------------------
// R10: payment plans and adjustments
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PaymentPlan {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub debtor_type: String,
    pub due_ids: Vec<String>,
    pub total_amount: Decimal,
    pub installment_count: i32,
    pub first_due_date: NaiveDate,
    pub grace_days: i32,
    pub waive_penalty_on_completion: bool,
    pub status: String,
    pub opened_on: NaiveDate,
    pub created_by: String,
    pub approved_by: String,
    pub closed_on: Option<NaiveDate>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PaymentPlanInstallment {
    pub id: i64,
    pub plan_id: i64,
    pub seq: i32,
    pub due_date: NaiveDate,
    pub amount: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreatePaymentPlanRequest {
    pub unit_id: String,
    #[serde(default)]
    pub debtor_type: Option<String>,
    /// Defaults to every open item of the debtor.
    #[serde(default)]
    pub due_ids: Vec<String>,
    pub installment_count: i32,
    pub first_due_date: NaiveDate,
    #[serde(default)]
    pub grace_days: Option<i32>,
    #[serde(default)]
    pub waive_penalty_on_completion: bool,
    /// The second person who approves the plan (four-eyes).
    pub approved_by: String,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanInstallmentView {
    pub seq: u32,
    pub due_date: NaiveDate,
    pub amount: Decimal,
    pub covered: Decimal,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentPlanView {
    #[serde(flatten)]
    pub plan: PaymentPlan,
    pub unit_label: String,
    pub paid: Decimal,
    pub required_to_date: Decimal,
    pub installments: Vec<PlanInstallmentView>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LedgerAdjustment {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub due_id: String,
    pub kind: String,
    pub amount: Decimal,
    pub reason: String,
    pub source: String,
    pub requested_by: String,
    pub requested_at: DateTime<Utc>,
    pub status: String,
    pub decided_by: Option<String>,
    pub decided_at: Option<DateTime<Utc>>,
    pub decision_note: Option<String>,
    pub principal_before: Option<Decimal>,
    pub penalty_before: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestAdjustmentRequest {
    pub due_id: String,
    pub kind: String,
    /// Defaults to the whole outstanding penalty (waiver) or principal (write-off).
    #[serde(default)]
    pub amount: Option<Decimal>,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanRunReport {
    pub completed: Vec<i64>,
    pub broken: Vec<i64>,
}

// ---------------------------------------------------------------------------
// R11: heat-share
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeatCostPeriod {
    pub id: i64,
    pub site_id: String,
    pub label: String,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub total_cost: Decimal,
    pub consumption_share_percent: Decimal,
    pub due_date: NaiveDate,
    pub status: String,
    pub approved_by: Option<String>,
    pub approved_at: Option<DateTime<Utc>>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeatMeterReading {
    pub id: i64,
    pub period_id: i64,
    pub unit_id: String,
    pub area_weight: i32,
    pub previous_reading: Decimal,
    pub current_reading: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HeatCostShare {
    pub id: i64,
    pub period_id: i64,
    pub unit_id: String,
    pub fixed_amount: Decimal,
    pub consumption_amount: Decimal,
    pub total_amount: Decimal,
    pub due_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateHeatPeriodRequest {
    pub label: String,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub total_cost: Decimal,
    #[serde(default)]
    pub consumption_share_percent: Option<Decimal>,
    pub due_date: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeterReadingInput {
    pub unit_id: String,
    /// Defaults to the unit's land share.
    #[serde(default)]
    pub area_weight: Option<i32>,
    pub previous_reading: Decimal,
    pub current_reading: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordReadingsRequest {
    pub readings: Vec<MeterReadingInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeatShareView {
    pub unit_id: String,
    pub unit_label: String,
    pub consumption: Decimal,
    pub fixed_amount: Decimal,
    pub consumption_amount: Decimal,
    pub total_amount: Decimal,
    pub due_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeatPeriodView {
    #[serde(flatten)]
    pub period: HeatCostPeriod,
    pub readings: Vec<HeatMeterReading>,
    /// Stored shares once approved; a preview while the period is a draft.
    pub shares: Vec<HeatShareView>,
    pub legal_note: String,
}

// ---------------------------------------------------------------------------
// R12: assembly and decisions book
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssemblyMeeting {
    pub id: i64,
    pub site_id: String,
    pub kind: String,
    pub call_number: i32,
    pub scheduled_at: DateTime<Utc>,
    pub location: String,
    pub status: String,
    pub held_on: Option<NaiveDate>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssemblyAgendaItem {
    pub id: i64,
    pub meeting_id: i64,
    pub seq: i32,
    pub title: String,
    pub description: Option<String>,
    pub rule: String,
    pub linked_budget_id: Option<String>,
    pub status: String,
    pub decision_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssemblyAttendance {
    pub id: i64,
    pub meeting_id: i64,
    pub unit_id: String,
    pub attendee_name: String,
    pub is_proxy: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssemblyVote {
    pub id: i64,
    pub agenda_item_id: i64,
    pub unit_id: String,
    pub vote: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AssemblyDecision {
    pub id: i64,
    pub site_id: String,
    pub meeting_id: Option<i64>,
    pub decision_number: i32,
    pub decided_on: NaiveDate,
    pub title: String,
    pub text: String,
    pub outcome: String,
    pub rule: String,
    pub yes_count: i32,
    pub no_count: i32,
    pub abstain_count: i32,
    pub yes_land_share: i64,
    pub total_land_share: i64,
    pub linked_budget_id: Option<String>,
    pub attachment_ref: Option<String>,
    pub recorded_by: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgendaItemInput {
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub rule: Option<String>,
    #[serde(default)]
    pub linked_budget_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateMeetingRequest {
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub call_number: Option<i32>,
    pub scheduled_at: DateTime<Utc>,
    pub location: String,
    pub agenda: Vec<AgendaItemInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttendanceInput {
    pub unit_id: String,
    pub attendee_name: String,
    #[serde(default)]
    pub is_proxy: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordAttendanceRequest {
    pub attendance: Vec<AttendanceInput>,
    #[serde(default)]
    pub held_on: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoteInput {
    pub unit_id: String,
    pub vote: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CastVotesRequest {
    pub votes: Vec<VoteInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloseAgendaItemRequest {
    pub decision_text: String,
    #[serde(default)]
    pub attachment_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordDecisionRequest {
    pub decided_on: NaiveDate,
    pub title: String,
    pub text: String,
    #[serde(default)]
    pub outcome: Option<String>,
    #[serde(default)]
    pub linked_budget_id: Option<String>,
    #[serde(default)]
    pub attachment_ref: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuorumStatus {
    pub units_total: u64,
    pub land_share_total: u64,
    pub units_present: u64,
    pub land_share_present: u64,
    pub has_quorum: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeetingView {
    #[serde(flatten)]
    pub meeting: AssemblyMeeting,
    pub agenda: Vec<AssemblyAgendaItem>,
    pub attendance: Vec<AssemblyAttendance>,
    pub quorum: QuorumStatus,
}

// ---------------------------------------------------------------------------
// R13: management companies
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManagementCompany {
    pub id: i64,
    pub name: String,
    pub tax_id: String,
    pub tax_office: String,
    pub address: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManagementCompanySite {
    pub id: i64,
    pub company_id: i64,
    pub site_id: String,
    pub monthly_fee: Decimal,
    pub vat_rate: Decimal,
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManagementCompanyMember {
    pub id: i64,
    pub company_id: i64,
    pub user_ref: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FeeInvoice {
    pub id: i64,
    pub company_id: i64,
    pub site_id: String,
    pub period: String,
    pub net_amount: Decimal,
    pub vat_amount: Decimal,
    pub total_amount: Decimal,
    pub document_type: String,
    pub status: String,
    pub integrator: String,
    pub integrator_uuid: String,
    pub issued_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateCompanyRequest {
    pub name: String,
    pub tax_id: String,
    pub tax_office: String,
    #[serde(default)]
    pub address: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AttachSiteRequest {
    pub site_id: String,
    pub monthly_fee: Decimal,
    #[serde(default)]
    pub vat_rate: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddMemberRequest {
    pub user_ref: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IssueFeeInvoicesRequest {
    /// `YYYY-MM`.
    pub period: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortfolioSiteRow {
    pub site_id: String,
    pub site_name: String,
    pub units: usize,
    pub open_receivables: Decimal,
    pub overdue_items: usize,
    pub collection_rate_this_month: Option<Decimal>,
    pub open_cases: usize,
    pub pending_expense_approvals: usize,
    pub monthly_fee: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortfolioSummary {
    pub company: ManagementCompany,
    pub sites: Vec<PortfolioSiteRow>,
    pub total_receivables: Decimal,
    pub total_monthly_fees: Decimal,
}

// ---------------------------------------------------------------------------
// R14: analytics
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MonthlyCollectionKpi {
    /// `YYYY-MM` of the due dates.
    pub month: String,
    pub principal_due: Decimal,
    pub settled: Decimal,
    pub collection_rate: Option<Decimal>,
    pub on_time_rate: Option<Decimal>,
    pub dso_days: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChannelShare {
    pub channel: String,
    pub amount: Decimal,
    pub share_percent: Option<Decimal>,
    /// Settled without a person matching it (virtual IBAN, card, autopay).
    pub zero_touch: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CashFlowMonth {
    pub month: String,
    pub expected_inflow: Decimal,
    pub expected_outflow: Decimal,
    pub net: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AtRiskUnit {
    pub unit_id: String,
    pub unit_label: String,
    pub score: u32,
    pub tier: String,
    pub overdue_amount: Decimal,
    pub oldest_days_overdue: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionAnalytics {
    pub site_id: String,
    pub as_of: NaiveDate,
    pub months: Vec<MonthlyCollectionKpi>,
    pub channels: Vec<ChannelShare>,
    pub digital_share_percent: Option<Decimal>,
    pub zero_touch_share_percent: Option<Decimal>,
    pub trailing_collection_rate: Option<Decimal>,
    pub cash_flow_forecast: Vec<CashFlowMonth>,
    pub at_risk_units: Vec<AtRiskUnit>,
}

// ---------------------------------------------------------------------------
// R1: budget compliance extension
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct UnitWeight {
    pub unit_id: String,
    pub weight: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LiabilityWithoutBasis {
    pub due_id: String,
    pub unit_label: String,
    pub period: String,
    pub due_date: NaiveDate,
    pub principal: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LegalBasisReport {
    pub site_id: String,
    pub transition_until: Option<NaiveDate>,
    pub in_transition: bool,
    pub operational_liabilities: usize,
    pub with_legal_basis: usize,
    pub coverage_percent: Option<Decimal>,
    pub without_basis: Vec<LiabilityWithoutBasis>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetTransitionRequest {
    /// Days from today (1–90); 0 ends the transition.
    pub transition_days: i64,
}
