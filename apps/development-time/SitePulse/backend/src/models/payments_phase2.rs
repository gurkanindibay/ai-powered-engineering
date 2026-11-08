//! SPEC-007 models: işletme projesi (operating budget), card payment intents,
//! the resident account statement and public receipt verification.

use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// İşletme projesi (KMK 35/37 as amended by Law 7579)
// ---------------------------------------------------------------------------

pub const BUDGET_DRAFT: &str = "DRAFT";
pub const BUDGET_INTERIM: &str = "INTERIM";
pub const BUDGET_APPROVED: &str = "APPROVED";
pub const BUDGET_FINAL: &str = "FINAL";
pub const BUDGET_REJECTED: &str = "REJECTED";
pub const BUDGET_SUPERSEDED: &str = "SUPERSEDED";

/// Budget lines' expense categories (they match the future expense module).
pub const BUDGET_CATEGORIES: [&str; 11] = [
    "PERSONNEL",
    "CLEANING",
    "ENERGY",
    "WATER",
    "MAINTENANCE",
    "INSURANCE",
    "MANAGEMENT_FEE",
    "SECURITY",
    "GARDENING",
    "RESERVE",
    "OTHER",
];
/// `LAND_SHARE` (arsa payı, the KMK 20 default), `EQUAL` (costs the yönetim planı
/// shares equally), and SPEC-009 R1: `HOUSE_TYPE` (weighted by the unit's house-type
/// tariff), `METER` and `CUSTOM` (explicit per-unit weights on the line).
pub const ALLOCATION_KEYS: [&str; 5] = ["LAND_SHARE", "EQUAL", "HOUSE_TYPE", "METER", "CUSTOM"];
pub const SERVICE_METHODS: [&str; 4] = [
    "IN_ASSEMBLY",
    "SIGNATURE",
    "REGISTERED_MAIL",
    "E_NOTIFICATION",
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OperatingBudgetLine {
    pub id: String,
    pub category: String,
    pub description: Option<String>,
    pub annual_amount: Decimal,
    pub allocation_key: String,
    /// Per-unit weights of a `METER` or `CUSTOM` line (SPEC-009 R1).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unit_weights: Vec<crate::models::UnitWeight>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OperatingBudgetUnitShare {
    pub unit_id: String,
    pub unit_label: String,
    pub land_share: i32,
    pub annual_amount: Decimal,
    /// The monthly avans the unit owes under this budget (annual / 12, rounded to kuruş).
    pub monthly_amount: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BudgetServiceRecord {
    pub id: String,
    pub unit_id: String,
    pub recipient_name: String,
    pub method: String,
    pub served_on: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BudgetObjection {
    pub id: String,
    pub unit_id: String,
    pub objector_name: String,
    pub filed_on: NaiveDate,
    pub reason: String,
    /// `OPEN`, `UPHELD` or `DISMISSED`.
    pub status: String,
    pub resolved_on: Option<NaiveDate>,
    pub resolution_note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OperatingBudget {
    pub id: String,
    pub site_id: String,
    pub fiscal_year: i32,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    /// `DRAFT -> INTERIM` (manager, capped) or `DRAFT/INTERIM -> APPROVED` (assembly),
    /// `APPROVED -> FINAL` once served and the objection window closed; `REJECTED`,
    /// `SUPERSEDED` when a later budget of the same year came into force.
    pub status: String,
    pub previous_budget_id: Option<String>,
    /// Yearly amount the increase is measured against: the previous budget's total,
    /// or, for a site's first budget, the yearly run-rate of its current tariffs.
    pub baseline_annual_amount: Decimal,
    pub total_annual_amount: Decimal,
    /// Increase over the baseline, in percent (None when the baseline is zero).
    pub increase_rate: Option<Decimal>,
    /// The revaluation rate the interim increase was checked against, in percent.
    pub cap_rate: Option<Decimal>,
    pub assembly_decision_ref: Option<String>,
    pub assembly_decision_date: Option<NaiveDate>,
    pub interim_issued_on: Option<NaiveDate>,
    /// An interim budget must reach the assembly within 3 months (KMK 37/2).
    pub interim_deadline: Option<NaiveDate>,
    /// Last service date + 7 days (KMK 37/3 objection window).
    pub objection_deadline: Option<NaiveDate>,
    pub notes: Option<String>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub lines: Vec<OperatingBudgetLine>,
    pub unit_shares: Vec<OperatingBudgetUnitShare>,
    pub service_records: Vec<BudgetServiceRecord>,
    pub objections: Vec<BudgetObjection>,
}

impl OperatingBudget {
    /// A budget dues may be accrued from.
    pub fn is_in_force(&self) -> bool {
        matches!(
            self.status.as_str(),
            BUDGET_INTERIM | BUDGET_APPROVED | BUDGET_FINAL
        )
    }

    pub fn covers(&self, date: NaiveDate) -> bool {
        self.period_start <= date && date <= self.period_end
    }

    pub fn share_of(&self, unit_id: &str) -> Option<&OperatingBudgetUnitShare> {
        self.unit_shares
            .iter()
            .find(|s| crate::auth::same_id(&s.unit_id, unit_id))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BudgetLineInput {
    pub category: String,
    #[serde(default)]
    pub description: Option<String>,
    pub annual_amount: Decimal,
    #[serde(default)]
    pub allocation_key: Option<String>,
    /// Required for `METER` and `CUSTOM` lines: a non-negative weight per unit.
    #[serde(default)]
    pub unit_weights: Vec<crate::models::UnitWeight>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CreateOperatingBudgetRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub fiscal_year: i32,
    /// Defaults to 1 January / 31 December of `fiscal_year`.
    #[serde(default)]
    pub period_start: Option<NaiveDate>,
    #[serde(default)]
    pub period_end: Option<NaiveDate>,
    #[serde(default)]
    pub notes: Option<String>,
    pub lines: Vec<BudgetLineInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct IssueInterimBudgetRequest {
    #[serde(default)]
    pub issued_on: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ApproveBudgetRequest {
    pub assembly_decision_ref: String,
    pub assembly_decision_date: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RejectBudgetRequest {
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RecordBudgetServiceRequest {
    pub unit_id: String,
    pub recipient_name: String,
    pub method: String,
    pub served_on: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileBudgetObjectionRequest {
    pub unit_id: String,
    pub objector_name: String,
    #[serde(default)]
    pub filed_on: Option<NaiveDate>,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ResolveBudgetObjectionRequest {
    /// `UPHELD` or `DISMISSED`.
    pub status: String,
    #[serde(default)]
    pub resolution_note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RevaluationRate {
    pub year: i32,
    /// Percent, e.g. 25.49.
    pub rate: Decimal,
    pub source: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct BudgetPolicyRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub require_operating_budget: bool,
}

/// A site's işletme projesi compliance at a glance.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetComplianceStatus {
    pub site_id: String,
    pub as_of: NaiveDate,
    pub require_operating_budget: bool,
    pub budget_in_force: Option<OperatingBudget>,
    /// Human-readable findings (missing budget, interim deadline passed, open objections, ...).
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Card payments through a licensed provider (6493)
// ---------------------------------------------------------------------------

pub const INTENT_CREATED: &str = "CREATED";
pub const INTENT_AUTHORIZED: &str = "AUTHORIZED";
pub const INTENT_CAPTURED: &str = "CAPTURED";
pub const INTENT_FAILED: &str = "FAILED";
pub const INTENT_REFUNDED: &str = "REFUNDED";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PaymentIntent {
    pub id: String,
    pub site_id: String,
    pub unit_id: String,
    pub debtor_type: String,
    pub payer_name: String,
    pub amount: Decimal,
    pub currency: String,
    pub provider: String,
    pub provider_ref: String,
    pub status: String,
    /// The provider-hosted payment page; card data is entered there, never in SitePulse.
    pub checkout_url: Option<String>,
    pub three_ds_status: Option<String>,
    pub fee_amount: Option<Decimal>,
    pub failure_reason: Option<String>,
    pub receipt_number: Option<String>,
    pub designation: Option<crate::models::PaymentDesignation>,
    pub created_by: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub captured_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CreatePaymentIntentRequest {
    pub amount: Decimal,
    /// `OWNER` or `TENANT`; defaults to the caller's own role on the unit.
    #[serde(default)]
    pub debtor_type: Option<String>,
    #[serde(default)]
    pub payer_name: Option<String>,
    #[serde(default)]
    pub designation: Option<crate::models::PaymentDesignation>,
}

/// The provider's signed notification (the sandbox provider sends the same shape).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderWebhookEvent {
    pub provider: String,
    pub provider_ref: String,
    /// `AUTHORIZED`, `CAPTURED`, `FAILED` or `REFUNDED`.
    pub status: String,
    pub amount: Decimal,
    #[serde(default)]
    pub fee_amount: Option<Decimal>,
    #[serde(default)]
    pub three_ds_status: Option<String>,
    #[serde(default)]
    pub failure_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SandboxCheckoutCompletion {
    /// `APPROVE` or `DECLINE`.
    pub outcome: String,
}

// ---------------------------------------------------------------------------
// Resident account statement (hesap ekstresi) and receipt verification
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementOpenItem {
    pub due_id: String,
    pub period: String,
    pub expense_type: String,
    pub due_date: NaiveDate,
    pub days_overdue: i64,
    pub principal_outstanding: Decimal,
    pub penalty_outstanding: Decimal,
    pub total_outstanding: Decimal,
    /// The operating budget the liability was accrued from (its legal basis).
    pub operating_budget_id: Option<String>,
    /// Older than five years: the claim may be time-barred (TBK 147/1).
    pub limitation_warning: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementDebtor {
    pub debtor_type: String,
    pub name: String,
    pub current_due: Decimal,
    pub overdue_1_30_days: Decimal,
    pub overdue_31_60_days: Decimal,
    pub overdue_61_90_days: Decimal,
    pub overdue_90_plus_days: Decimal,
    pub principal_outstanding: Decimal,
    pub penalty_outstanding: Decimal,
    pub total_outstanding: Decimal,
    pub advance_balance: Decimal,
    pub open_items: Vec<StatementOpenItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatementReceipt {
    pub receipt_number: String,
    pub receipt_type: String,
    pub issued_at: DateTime<Utc>,
    pub payer_role: String,
    pub payment_channel: String,
    pub total_amount: Decimal,
    pub reversed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResidentStatement {
    pub unit_id: String,
    pub unit_label: String,
    pub as_of: NaiveDate,
    pub debtors: Vec<StatementDebtor>,
    pub receipts: Vec<StatementReceipt>,
}

/// What anyone holding a receipt can confirm (KVKK: no payer name, no unit).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReceiptVerification {
    pub valid: bool,
    pub receipt_number: String,
    pub receipt_type: Option<String>,
    pub issued_at: Option<DateTime<Utc>>,
    pub total_amount: Option<Decimal>,
    pub issuer_name: Option<String>,
    pub reversed: bool,
}
