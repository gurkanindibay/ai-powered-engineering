use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

mod person_api;
pub use person_api::*;

mod payments_phase2;
pub use payments_phase2::*;
mod payments_phase3;
pub use payments_phase3::*;

macro_rules! impl_sql_for_enum {
    ($t:ty) => {
        impl<'a> tokio_postgres::types::FromSql<'a> for $t {
            fn from_sql(
                ty: &tokio_postgres::types::Type,
                raw: &'a [u8],
            ) -> Result<Self, Box<dyn std::error::Error + Sync + Send>> {
                let s = <&str as tokio_postgres::types::FromSql>::from_sql(ty, raw)?;
                Ok(Self::from_str_loose(s))
            }

            fn accepts(ty: &tokio_postgres::types::Type) -> bool {
                <&str as tokio_postgres::types::FromSql>::accepts(ty)
            }
        }

        impl tokio_postgres::types::ToSql for $t {
            fn to_sql(
                &self,
                ty: &tokio_postgres::types::Type,
                out: &mut tokio_postgres::types::private::BytesMut,
            ) -> Result<tokio_postgres::types::IsNull, Box<dyn std::error::Error + Sync + Send>>
            {
                self.as_str().to_sql(ty, out)
            }

            fn accepts(ty: &tokio_postgres::types::Type) -> bool {
                <&str as tokio_postgres::types::ToSql>::accepts(ty)
            }

            tokio_postgres::types::to_sql_checked!();
        }
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Role {
    HomeOwner,
    HomeResident,
    SiteManager,
    SaasAdmin,
    /// Denetçi (KMK 41): read-only access to the books; approves large expenses.
    Auditor,
}

impl Role {
    pub fn as_str(&self) -> &'static str {
        match self {
            Role::HomeOwner => "HOME_OWNER",
            Role::HomeResident => "HOME_RESIDENT",
            Role::SiteManager => "SITE_MANAGER",
            Role::SaasAdmin => "SAAS_ADMIN",
            Role::Auditor => "AUDITOR",
        }
    }

    /// Parse a role without granting authority to unknown values.
    ///
    /// # Errors
    /// Returns an error for unrecognized or legacy role strings.
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "HOME_OWNER" => Ok(Self::HomeOwner),
            "HOME_RESIDENT" => Ok(Self::HomeResident),
            "SITE_MANAGER" => Ok(Self::SiteManager),
            "SAAS_ADMIN" => Ok(Self::SaasAdmin),
            "AUDITOR" => Ok(Self::Auditor),
            _ => Err("Unknown role".to_string()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Permission {
    UnitRead,
    UnitPay,
    UnitInviteCoResident,
    UnitManageHousehold,
    SiteManage,
    ResidentInviteSite,
    ResidentApprove,
    LedgerManageAll,
    AnnouncementBroadcast,
    TenantManage,
    PaymentRecordManual,
    PaymentReverse,
    BankAccountManage,
    ReconciliationConfirm,
    RoleGrant,
    AuditLogRead,
    AuditLogExport,
    SupportAccess,
    PlatformIntegrationConfigure,
    /// SPEC-009: read the books, reports, collections and analytics.
    FinanceRead,
    /// SPEC-009: expenses, journal, dunning, plans, cases, leases, heat-share, KVKK settings.
    FinanceManage,
    /// SPEC-009: approve an expense invoice (four-eyes; the auditor above the limit).
    ExpenseApprove,
    /// SPEC-009: approve a waiver or write-off requested by someone else.
    AdjustmentApprove,
    /// SPEC-009: assembly meetings, votes and the decisions book.
    GovernanceManage,
    /// SPEC-009: a management company's portfolio of sites.
    PortfolioRead,
    /// Person module: read the site's owners and residents directory and unit history.
    PersonRead,
    /// Person module: register and edit people, households and contact details.
    PersonManage,
    /// Person module: change a login email (with step-up); identity, not contact data.
    PersonIdentityManage,
    /// Person module: move-in, move-out and ownership transfer.
    OccupancyManage,
    /// Person module: a unit's payer IBANs and payer names used for bank matching.
    UnitPaymentProfileManage,
    /// Person module: export the people directory (step-up, audited).
    PersonExport,
}

impl Permission {
    pub fn description(&self) -> &'static str {
        match self {
            Permission::UnitRead => "View unit dues and payment receipts",
            Permission::UnitPay => "Pay unit dues online (Credit Card / FAST)",
            Permission::UnitInviteCoResident => "Generate co-resident/family member invite link",
            Permission::UnitManageHousehold => "List and manage household members",
            Permission::SiteManage => "Manage site, blocks, units, and staff infrastructure",
            Permission::ResidentInviteSite => "Generate site-wide resident registration link",
            Permission::ResidentApprove => "Review and approve resident registration applications",
            Permission::LedgerManageAll => {
                "Manage dues liabilities and statutory delay penalties for all units"
            }
            Permission::AnnouncementBroadcast => {
                "Broadcast announcements and notifications to residents"
            }
            Permission::TenantManage => "Manage SaaS platform sites and subscriptions",
            Permission::PaymentRecordManual => "Record manual payments",
            Permission::PaymentReverse => "Reverse payments after step-up",
            Permission::BankAccountManage => "Manage site banking configuration",
            Permission::ReconciliationConfirm => "Confirm bank reconciliation",
            Permission::RoleGrant => "Manage role assignments",
            Permission::AuditLogRead => "Read scoped audit events",
            Permission::AuditLogExport => "Export scoped audit events",
            Permission::SupportAccess => "Request and approve support access",
            Permission::PlatformIntegrationConfigure => "Configure platform bank integration",
            Permission::FinanceRead => "Read the general ledger, reports, collections and analytics",
            Permission::FinanceManage => {
                "Manage expenses, journal entries, dunning, payment plans, collection cases and leases"
            }
            Permission::ExpenseApprove => "Approve expense invoices",
            Permission::AdjustmentApprove => "Approve penalty waivers and write-offs",
            Permission::GovernanceManage => "Manage assembly meetings and the decisions book",
            Permission::PortfolioRead => "View a management company's site portfolio",
            Permission::PersonRead => "View the owners and residents directory",
            Permission::PersonManage => "Register and edit people, households and contact details",
            Permission::PersonIdentityManage => "Change a resident's login email (step-up)",
            Permission::OccupancyManage => "Record move-in, move-out and ownership transfer",
            Permission::UnitPaymentProfileManage => "Manage a unit's payer IBANs and payer names",
            Permission::PersonExport => "Export the people directory (step-up, audited)",
        }
    }

    pub fn permissions_for_role(role: Role) -> Vec<Permission> {
        match role {
            Role::SaasAdmin => vec![
                Permission::TenantManage,
                Permission::AnnouncementBroadcast,
                Permission::RoleGrant,
                Permission::AuditLogRead,
                Permission::SupportAccess,
                Permission::PlatformIntegrationConfigure,
            ],
            Role::SiteManager => vec![
                Permission::UnitRead,
                Permission::PaymentRecordManual,
                Permission::PaymentReverse,
                Permission::BankAccountManage,
                Permission::ReconciliationConfirm,
                Permission::RoleGrant,
                Permission::AuditLogRead,
                Permission::AuditLogExport,
                Permission::SiteManage,
                Permission::ResidentInviteSite,
                Permission::ResidentApprove,
                Permission::LedgerManageAll,
                Permission::AnnouncementBroadcast,
                Permission::FinanceRead,
                Permission::FinanceManage,
                Permission::ExpenseApprove,
                Permission::AdjustmentApprove,
                Permission::GovernanceManage,
                Permission::PortfolioRead,
                Permission::PersonRead,
                Permission::PersonManage,
                Permission::PersonIdentityManage,
                Permission::OccupancyManage,
                Permission::UnitPaymentProfileManage,
                Permission::PersonExport,
            ],
            Role::HomeOwner => vec![
                Permission::UnitRead,
                Permission::UnitPay,
                Permission::UnitInviteCoResident,
                Permission::UnitManageHousehold,
                Permission::UnitPaymentProfileManage,
            ],
            Role::HomeResident => vec![Permission::UnitRead, Permission::UnitPay],
            Role::Auditor => vec![
                Permission::FinanceRead,
                Permission::ExpenseApprove,
                Permission::AuditLogRead,
            ],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DebtStatus {
    Pending,
    Overdue,
    Paid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DebtorType {
    #[default]
    Tenant,
    Owner,
}

impl DebtorType {
    pub fn as_str(&self) -> &'static str {
        match self {
            DebtorType::Tenant => "TENANT",
            DebtorType::Owner => "OWNER",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "OWNER" | "KAT_MALIKI" => DebtorType::Owner,
            _ => DebtorType::Tenant,
        }
    }
}

impl std::fmt::Display for DebtorType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(DebtorType);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ExpenseType {
    #[default]
    OperationalDues,
    CapitalDues,
}

impl ExpenseType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ExpenseType::OperationalDues => "OPERATIONAL_DUES",
            ExpenseType::CapitalDues => "CAPITAL_DUES",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "CAPITAL_DUES" | "CAPITAL" | "DEMIRBAS" => ExpenseType::CapitalDues,
            _ => ExpenseType::OperationalDues,
        }
    }
}

impl std::fmt::Display for ExpenseType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(ExpenseType);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum OccupancyStatus {
    #[default]
    OwnerOccupied,
    TenantOccupied,
    Vacant,
}

impl OccupancyStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            OccupancyStatus::OwnerOccupied => "OWNER_OCCUPIED",
            OccupancyStatus::TenantOccupied => "TENANT_OCCUPIED",
            OccupancyStatus::Vacant => "VACANT",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "TENANT_OCCUPIED" | "TENANT" => OccupancyStatus::TenantOccupied,
            "VACANT" => OccupancyStatus::Vacant,
            _ => OccupancyStatus::OwnerOccupied,
        }
    }
}

impl std::fmt::Display for OccupancyStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(OccupancyStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DuesPeriodStatus {
    #[default]
    Active,
    Closed,
    Draft,
}

impl DuesPeriodStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            DuesPeriodStatus::Active => "ACTIVE",
            DuesPeriodStatus::Closed => "CLOSED",
            DuesPeriodStatus::Draft => "DRAFT",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "CLOSED" => DuesPeriodStatus::Closed,
            "DRAFT" => DuesPeriodStatus::Draft,
            _ => DuesPeriodStatus::Active,
        }
    }
}

impl std::fmt::Display for DuesPeriodStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(DuesPeriodStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SiteStatus {
    #[default]
    Active,
    Suspended,
    Deleted,
}

impl SiteStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            SiteStatus::Active => "ACTIVE",
            SiteStatus::Suspended => "SUSPENDED",
            SiteStatus::Deleted => "DELETED",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "SUSPENDED" => SiteStatus::Suspended,
            "DELETED" => SiteStatus::Deleted,
            _ => SiteStatus::Active,
        }
    }
}

impl std::fmt::Display for SiteStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(SiteStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PlanType {
    #[default]
    Standard,
    Premium,
    Enterprise,
    Community,
}

impl PlanType {
    pub fn as_str(&self) -> &'static str {
        match self {
            PlanType::Standard => "STANDARD",
            PlanType::Premium => "PREMIUM",
            PlanType::Enterprise => "ENTERPRISE",
            PlanType::Community => "COMMUNITY",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "PREMIUM" => PlanType::Premium,
            "ENTERPRISE" | "PRO" => PlanType::Enterprise,
            "COMMUNITY" => PlanType::Community,
            _ => PlanType::Standard,
        }
    }
}

impl std::fmt::Display for PlanType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(PlanType);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum AuthProvider {
    #[default]
    Local,
    Google,
    Hybrid,
}

impl AuthProvider {
    pub fn as_str(&self) -> &'static str {
        match self {
            AuthProvider::Local => "LOCAL",
            AuthProvider::Google => "GOOGLE",
            AuthProvider::Hybrid => "HYBRID",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "GOOGLE" => AuthProvider::Google,
            "HYBRID" => AuthProvider::Hybrid,
            _ => AuthProvider::Local,
        }
    }
}

impl std::fmt::Display for AuthProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(AuthProvider);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaymentChannel {
    CreditCard,
    BankTransfer,
    BankStatement,
    Fast,
    Cash,
    #[default]
    ManualCash,
    VirtualIban,
    InterLedger,
    OnlinePayment,
    Other,
}

impl PaymentChannel {
    pub fn as_str(&self) -> &'static str {
        match self {
            PaymentChannel::CreditCard => "CREDIT_CARD",
            PaymentChannel::BankTransfer => "BANK_TRANSFER",
            PaymentChannel::BankStatement => "BANK_STATEMENT",
            PaymentChannel::Fast => "FAST",
            PaymentChannel::Cash => "CASH",
            PaymentChannel::ManualCash => "MANUAL_CASH",
            PaymentChannel::VirtualIban => "VIRTUAL_IBAN",
            PaymentChannel::InterLedger => "INTER_LEDGER",
            PaymentChannel::OnlinePayment => "ONLINE_PAYMENT",
            PaymentChannel::Other => "OTHER",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        let u = s.to_uppercase();
        if u.contains("CARD") || u.contains("KART") || u.contains("POS") {
            PaymentChannel::CreditCard
        } else if u.contains("VIBAN") || u.contains("VIRTUAL") {
            PaymentChannel::VirtualIban
        } else if u.contains("FAST") {
            PaymentChannel::Fast
        } else if u.contains("INTER_LEDGER") {
            PaymentChannel::InterLedger
        } else if u.contains("STATEMENT") || u.contains("EKSTRE") {
            PaymentChannel::BankStatement
        } else if u.contains("ONLINE") {
            PaymentChannel::OnlinePayment
        } else if u.contains("BANK")
            || u.contains("HAVALE")
            || u.contains("EFT")
            || u.contains("TRANSFER")
        {
            PaymentChannel::BankTransfer
        } else if u.contains("MANUAL") {
            PaymentChannel::ManualCash
        } else if u.contains("CASH") || u.contains("NAKIT") {
            PaymentChannel::Cash
        } else {
            PaymentChannel::Other
        }
    }
}

impl std::fmt::Display for PaymentChannel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(PaymentChannel);

pub type PaymentMethod = PaymentChannel;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SettlementStatus {
    #[default]
    Settled,
    Pending,
    Unmatched,
    Reversed,
}

impl SettlementStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            SettlementStatus::Settled => "SETTLED",
            SettlementStatus::Pending => "PENDING",
            SettlementStatus::Unmatched => "UNMATCHED",
            SettlementStatus::Reversed => "REVERSED",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "PENDING" => SettlementStatus::Pending,
            "UNMATCHED" => SettlementStatus::Unmatched,
            "REVERSED" => SettlementStatus::Reversed,
            _ => SettlementStatus::Settled,
        }
    }
}

impl std::fmt::Display for SettlementStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(SettlementStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum RegistrationStatus {
    #[default]
    Pending,
    Approved,
    Rejected,
}

impl RegistrationStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            RegistrationStatus::Pending => "PENDING",
            RegistrationStatus::Approved => "APPROVED",
            RegistrationStatus::Rejected => "REJECTED",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "APPROVED" => RegistrationStatus::Approved,
            "REJECTED" => RegistrationStatus::Rejected,
            _ => RegistrationStatus::Pending,
        }
    }
}

impl std::fmt::Display for RegistrationStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(RegistrationStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CapitalProjectStatus {
    #[default]
    Active,
    Completed,
    Cancelled,
    Draft,
}

impl CapitalProjectStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            CapitalProjectStatus::Active => "ACTIVE",
            CapitalProjectStatus::Completed => "COMPLETED",
            CapitalProjectStatus::Cancelled => "CANCELLED",
            CapitalProjectStatus::Draft => "DRAFT",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "COMPLETED" => CapitalProjectStatus::Completed,
            "CANCELLED" => CapitalProjectStatus::Cancelled,
            "DRAFT" => CapitalProjectStatus::Draft,
            _ => CapitalProjectStatus::Active,
        }
    }
}

impl std::fmt::Display for CapitalProjectStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(CapitalProjectStatus);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DisbursementMethod {
    #[default]
    BankTransfer,
    Fast,
    Cash,
    Check,
}

impl DisbursementMethod {
    pub fn as_str(&self) -> &'static str {
        match self {
            DisbursementMethod::BankTransfer => "BANK_TRANSFER",
            DisbursementMethod::Fast => "FAST",
            DisbursementMethod::Cash => "CASH",
            DisbursementMethod::Check => "CHECK",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "FAST" => DisbursementMethod::Fast,
            "CASH" => DisbursementMethod::Cash,
            "CHECK" => DisbursementMethod::Check,
            _ => DisbursementMethod::BankTransfer,
        }
    }
}

impl std::fmt::Display for DisbursementMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(DisbursementMethod);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesLiability {
    pub id: String,
    pub unit_id: String,
    pub period: String,
    /// Principal owed. Never reduced by payments (see `paid_principal`).
    pub principal_amount: Decimal,
    /// Delay penalty accrued. Never reduced by payments (see `paid_penalty`).
    pub delay_penalty: Decimal,
    /// Outstanding balance: principal + penalty - paid_principal - paid_penalty.
    pub total_amount: Decimal,
    pub due_date: NaiveDate,
    pub status: DebtStatus,
    #[serde(default)]
    pub paid_principal: Decimal,
    #[serde(default)]
    pub paid_penalty: Decimal,
    /// `OWNER` or `TENANT`: who is liable.
    #[serde(default)]
    pub debtor_type: DebtorType,
    #[serde(default)]
    pub expense_type: ExpenseType,
    /// Date up to which `delay_penalty` has been accrued (KMK 20 segmented accrual).
    /// `None` for liabilities that never accrued a segment (legacy rule applies).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub penalty_accrued_through: Option<NaiveDate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccrueDuesPeriodRequest {
    pub site_id: String,
    pub period: String,
    pub amount: Decimal,
    pub due_date: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccrueDuesPeriodResponse {
    pub site_id: String,
    pub period: String,
    pub total_units_accrued: usize,
    pub newly_accrued_units_count: usize,
    pub auto_settled_units_count: usize,
    pub total_amount_accrued: Decimal,
    pub total_amount_offset_from_advance: Decimal,
    pub already_accrued: bool,
    pub message: String,
    /// The operating budget the amounts came from (their legal basis), if any.
    #[serde(default)]
    pub operating_budget_id: Option<String>,
    /// Set when dues were accrued without an operating budget in force (KMK 37).
    #[serde(default)]
    pub legal_basis_warning: Option<String>,
    /// Units that were not accrued, with the reason.
    #[serde(default)]
    pub skipped_units: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesPeriod {
    pub id: String,
    pub site_id: String,
    pub period_name: String,
    pub due_date: NaiveDate,
    pub status: DuesPeriodStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateDuesPeriodRequest {
    pub site_id: String,
    pub period_name: String,
    pub due_date: NaiveDate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IndependentUnit {
    pub id: String,
    pub site_id: String,
    pub block_id: String,
    pub unit_number: i32,
    pub floor: i32,
    pub land_share: i32,
    pub owner_user_id: Option<String>,
    pub tenant_user_id: Option<String>,
    #[serde(default)]
    pub virtual_iban: Option<String>,
    #[serde(default)]
    pub house_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Person {
    pub id: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub national_id: Option<String>,
    pub full_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phone: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    pub site_id: String,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub password_hash: Option<String>,
    pub role: Role,
    pub must_change_password: bool,
    pub auth_provider: AuthProvider,
    pub google_sub: Option<String>,
    pub avatar_url: Option<String>,
    pub created_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Site {
    pub id: String,
    pub name: String,
    pub address: String,
    pub slug: String,
    pub status: SiteStatus,
    pub plan_type: PlanType,
    pub license_end_date: NaiveDate,
    /// IANA time zone used for accrual dates (e.g. `Europe/Istanbul`).
    #[serde(default = "default_site_timezone")]
    pub timezone: String,
    /// Vergi Kimlik No (10 digits) or the manager's T.C. Kimlik No (11), printed on receipts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tax_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tax_office: Option<String>,
}

pub fn default_site_timezone() -> String {
    "Europe/Istanbul".to_string()
}

// DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountTransactionDto {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub amount: Decimal,
    pub date: String,
    pub is_credit: bool,
    /// The receipt issued for this payment (TAH-...), when one exists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_number: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResidentDashboardDto {
    pub unit_id: String,
    pub site_title: String,
    pub total_debt: Decimal,
    pub is_overdue: bool,
    pub dues: Vec<DuesSummaryDto>,
    pub announcement_title: String,
    pub announcement_content: String,
    #[serde(default)]
    pub virtual_iban: Option<String>,
    #[serde(default)]
    pub advance_payment: Decimal,
    #[serde(default)]
    pub transactions: Vec<AccountTransactionDto>,
    #[serde(default)]
    pub capital_dues: Vec<CapitalDuesSummaryDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapitalDuesSummaryDto {
    pub project_id: String,
    pub project_title: String,
    pub outstanding_balance: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesSummaryDto {
    pub id: String,
    pub period: String,
    pub principal_amount: Decimal,
    pub delay_penalty: Decimal,
    pub total_amount: Decimal,
    pub due_date: String,
    /// Uses the same calculation date as the returned delay penalty.
    #[serde(default)]
    pub days_overdue: i32,
    pub status: String,
}

// Auth DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PasswordLoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoogleLoginRequest {
    pub id_token: String,
    pub unit_invite_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterUserRequest {
    pub full_name: String,
    pub email: String,
    pub password: String,
    pub phone: Option<String>,
    pub unit_invite_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChangePasswordRequest {
    pub email: String,
    pub current_password: String,
    pub new_password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthResponse {
    pub refresh_token: String,
    pub access_token: String,
    pub token_type: String,
    pub expires_in: i64,
    pub user: UserSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserSummary {
    pub id: String,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub role: Role,
    pub site_id: String,
    pub unit_id: String,
    pub avatar_url: Option<String>,
    pub auth_provider: AuthProvider,
    pub must_change_password: bool,
    pub permissions: Vec<Permission>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserProfileResponse {
    pub id: String,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub role: Role,
    pub site_id: String,
    pub unit_id: String,
    pub avatar_url: Option<String>,
    pub auth_provider: AuthProvider,
    pub must_change_password: bool,
    pub permissions: Vec<Permission>,
    pub permission_descriptions: Vec<String>,
}

// SaaS DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterSiteRequest {
    pub site_name: String,
    pub address: String,
    pub site_admin_full_name: String,
    pub site_admin_email: String,
    pub site_admin_phone: String,
    pub plan_type: Option<String>,
    #[serde(default)]
    pub blocks: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct UpdateSiteRequest {
    pub site_name: Option<String>,
    pub address: Option<String>,
    pub status: Option<String>,
    pub plan_type: Option<String>,
    pub site_admin_full_name: Option<String>,
    pub site_admin_email: Option<String>,
    pub site_admin_phone: Option<String>,
    #[serde(default)]
    pub blocks: Option<Vec<String>>,
    /// Issuer tax id printed on receipts (10 or 11 digits); an empty string clears it.
    #[serde(default)]
    pub tax_id: Option<String>,
    #[serde(default)]
    pub tax_office: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteRegistrationResponse {
    pub site_id: String,
    pub site_name: String,
    pub slug: String,
    pub status: SiteStatus,
    pub plan_type: PlanType,
    pub admin_user_id: String,
    pub admin_full_name: String,
    pub admin_email: String,
    pub temporary_password: String,
    pub must_change_password: bool,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub blocks: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteAdminPasswordResetResponse {
    pub site_id: String,
    pub site_name: String,
    pub admin_user_id: String,
    pub admin_full_name: String,
    pub admin_email: String,
    pub temporary_password: String,
    pub must_change_password: bool,
    pub renewed_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaasSiteSummaryDto {
    pub site_id: String,
    pub site_name: String,
    pub slug: String,
    pub address: String,
    pub status: SiteStatus,
    pub plan_type: PlanType,
    pub license_end_date: NaiveDate,
    pub total_units: i32,
    pub monthly_dues_volume: Decimal,
    pub primary_manager_name: String,
    pub primary_manager_email: String,
    pub primary_manager_phone: String,
    #[serde(default)]
    pub blocks: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockDto {
    pub id: String,
    pub site_id: String,
    pub block_name: String,
    pub total_floors: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateBlockRequest {
    pub block_name: String,
    #[serde(default)]
    pub total_floors: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SaasGlobalStatsDto {
    pub total_sites: usize,
    pub active_sites: usize,
    pub total_units: usize,
    pub monthly_collection_volume: Decimal,
}

// Site Admin DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HouseTypeTariff {
    pub id: String,
    pub site_id: String,
    pub type_name: String,
    pub dues_amount: Decimal,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateHouseTypeRequest {
    pub type_name: String,
    pub dues_amount: Decimal,
    #[serde(default)]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterHomeOwnerRequest {
    pub block: String,
    pub unit_no: i32,
    pub floor: i32,
    pub owner_full_name: String,
    pub email: String,
    pub phone: String,
    #[serde(default)]
    pub tenant_full_name: Option<String>,
    #[serde(default)]
    pub tenant_email: Option<String>,
    #[serde(default)]
    pub tenant_phone: Option<String>,
    pub land_share: Option<String>,
    pub monthly_dues: Option<Decimal>,
    #[serde(default)]
    pub house_type: Option<String>,
    pub is_resident: bool,
    #[serde(default)]
    pub role: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateHomeOwnerRequest {
    pub owner_full_name: Option<String>,
    pub email: Option<String>,
    pub phone: Option<String>,
    pub tenant_full_name: Option<String>,
    pub tenant_email: Option<String>,
    pub tenant_phone: Option<String>,
    pub remove_tenant: Option<bool>,
    pub house_type: Option<String>,
    pub monthly_dues: Option<Decimal>,
    pub land_share: Option<String>,
    pub is_resident: Option<bool>,
}

/// A login email change the person has not confirmed yet.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingEmailChange {
    pub new_email: String,
    pub delivery: crate::services::account_activation_service::ActivationDelivery,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveOutResidentRequest {
    pub end_date: Option<String>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MoveInResidentRequest {
    pub person_id: Option<i64>,
    pub full_name: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub role: DebtorType,
    pub start_date: Option<String>,
    pub notes: Option<String>,
}

/// One guarded occupancy command on a unit (EPIC-08 §3.3).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OccupancyTransitionRequest {
    pub command: crate::domain::unit_state::CommandKind,
    /// The date the move takes effect; today when omitted. Never in the future.
    #[serde(default)]
    pub effective_date: Option<NaiveDate>,
    /// The incoming person as a reference: an existing card or a new one created
    /// atomically with the move. Takes precedence over the legacy fields below.
    #[serde(default)]
    pub person: Option<PersonRef>,
    /// The incoming tenant: an existing person of the site...
    #[serde(default)]
    pub person_id: Option<i64>,
    /// ...or a new person (tenant commands only).
    #[serde(default)]
    pub full_name: Option<String>,
    #[serde(default)]
    pub phone: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    /// Which owner moves in when the unit has several (decision A1).
    #[serde(default)]
    pub owner_person_id: Option<i64>,
    #[serde(default)]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OccupancyTransitionResponse {
    pub unit_id: i64,
    pub command: crate::domain::unit_state::CommandKind,
    pub from_state: crate::domain::unit_state::UnitState,
    pub to_state: crate::domain::unit_state::UnitState,
    /// The session the command closed, with its exit balance.
    pub closed: Option<OccupancyHistoryItem>,
    /// The session the command opened.
    pub opened: Option<OccupancyHistoryItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitOwnerDto {
    pub person_id: i64,
    pub full_name: String,
    pub share_percentage: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitOccupantDto {
    pub occupancy_id: i64,
    pub person_id: i64,
    pub full_name: String,
    pub role: DebtorType,
    pub start_date: NaiveDate,
}

/// A unit's ownership and occupancy and the commands legal from there.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitOccupancyStateResponse {
    pub unit_id: i64,
    pub ownership: crate::domain::unit_state::Ownership,
    pub occupancy: crate::domain::unit_state::Occupancy,
    pub owners: Vec<UnitOwnerDto>,
    pub occupant: Option<UnitOccupantDto>,
    pub allowed_commands: Vec<crate::domain::unit_state::CommandKind>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OccupancyHistoryItem {
    pub id: i64,
    pub unit_id: i64,
    pub person_id: i64,
    pub person_name: String,
    pub person_phone: Option<String>,
    pub person_email: Option<String>,
    pub role: DebtorType,
    pub start_date: String,
    pub end_date: Option<String>,
    pub is_active: bool,
    pub exit_balance: Decimal,
    pub notes: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// A unit's selected communication contact, independent of ownership and occupancy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrimaryResponsibleContact {
    pub primary_responsible_name: String,
    pub primary_responsible_role: String,
    pub primary_responsible_phone: String,
    pub primary_responsible_email: String,
    #[serde(default)]
    pub primary_responsible_member_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SelectResponsibleContactRequest {
    /// Preferred: the person card chosen as primary contact. Replaces `role` and name.
    #[serde(default)]
    pub person_id: Option<i64>,
    #[serde(default)]
    pub role: String,
    #[serde(default)]
    pub resident_name: String,
    #[serde(default)]
    pub member_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeOwnerResponse {
    #[serde(default, flatten)]
    pub primary_responsible: Option<PrimaryResponsibleContact>,
    pub unit_id: String,
    pub site_id: String,
    pub block: String,
    pub unit_no: i32,
    pub floor: i32,
    pub owner_full_name: String,
    pub email: String,
    pub phone: String,
    pub land_share: String,
    pub monthly_dues: Decimal,
    #[serde(default)]
    pub house_type: Option<String>,
    pub is_resident: bool,
    /// Whether the owner's activation link was sent. The link itself is never returned.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activation: Option<crate::services::account_activation_service::ActivationDelivery>,
    /// The same for a tenant account created together with the owner.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tenant_activation: Option<crate::services::account_activation_service::ActivationDelivery>,
    /// Login email changes waiting for the new address to confirm them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending_email_changes: Vec<PendingEmailChange>,
    /// Defaults the server applied that the manager should check (`DUES_DEFAULTED`, `LAND_SHARE_DEFAULTED`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<String>,
    pub must_change_password: bool,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub occupancy_status: Option<OccupancyStatus>,
    #[serde(default)]
    pub tenant_full_name: Option<String>,
    #[serde(default)]
    pub tenant_email: Option<String>,
    #[serde(default)]
    pub tenant_phone: Option<String>,
    #[serde(default)]
    pub operational_dues_balance: Option<Decimal>,
    #[serde(default)]
    pub capital_dues_balance: Option<Decimal>,
    /// The unit's advance (avans) balance, owner + tenant (used by the virman dialog).
    #[serde(default)]
    pub advance_balance: Option<Decimal>,
    #[serde(default)]
    pub household_residents: Vec<UnitMemberDto>,
}

// Registration Approval DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteInvitationLinkResponse {
    pub site_id: String,
    pub site_name: String,
    pub slug: String,
    pub token: String,
    pub join_url: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubmitSelfRegistrationRequest {
    pub block: String,
    pub unit_no: i32,
    pub floor: i32,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub is_resident: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingRegistrationResponse {
    pub request_id: String,
    pub site_id: String,
    pub block: String,
    pub unit_no: i32,
    pub floor: i32,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub is_resident: bool,
    pub status: RegistrationStatus,
    pub submitted_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalResultResponse {
    pub request_id: String,
    pub site_id: String,
    pub status: RegistrationStatus,
    pub unit_id: String,
    pub email: String,
    pub temporary_password: String,
    pub approved_at: DateTime<Utc>,
}

// Unit Invitation DTOs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitInviteLinkResponse {
    pub invite_url: String,
    pub token: String,
    pub unit_id: String,
    pub building: String,
    pub unit_number: String,
    pub relationship: String,
    pub expires_at: DateTime<Utc>,
    pub security_notice: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterHomeResidentRequest {
    pub token: String,
    pub full_name: String,
    pub email: String,
    pub phone: Option<String>,
    pub relationship: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeResidentResponse {
    pub resident_id: String,
    pub full_name: String,
    pub email: String,
    pub phone: Option<String>,
    pub unit_id: String,
    pub role: String,
    pub temporary_password: String,
    pub permission_scope: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitMemberDto {
    /// `occupancy_members.id` — the sole, real identifier for a household member.
    pub resident_id: String,
    pub full_name: String,
    pub relationship: String,
    pub phone: String,
    pub email: String,
    pub is_owner: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub occupancy_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resident_user_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddUnitMemberRequest {
    /// Preferred: an existing card or a new one created atomically with the member.
    #[serde(default)]
    pub person: Option<PersonRef>,
    #[serde(default)]
    pub full_name: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub relationship: Option<String>,
}

// ============================================================================
// Bank Statement Ingestion & Automated Reconciliation Models (STORY-07-02)
// ============================================================================

// ============================================================================
// Site Bank Account Configuration (STORY-08-01)
// Allows a site manager to define the bank and IBAN for the site.
// The statement file format is automatically derived from the bank.
// Only one active bank account is permitted per site at any time.
// ============================================================================

/// Supported Turkish banks and their associated statement file format.
/// Adding a new bank here automatically enables its format for upload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SupportedBank {
    KuveytTurk,
    IsBankasi,
    ZiraatBankasi,
    GarantiBbva,
    AkBank,
    YapiKredi,
    Halkbank,
    Vakifbank,
    DenizBank,
    QnbFinansbank,
}

impl SupportedBank {
    /// Returns the canonical bank code string stored in the database.
    pub fn as_code(&self) -> &'static str {
        match self {
            SupportedBank::KuveytTurk => "KUVEYT_TURK",
            SupportedBank::IsBankasi => "IS_BANKASI",
            SupportedBank::ZiraatBankasi => "ZIRAAT_BANKASI",
            SupportedBank::GarantiBbva => "GARANTI_BBVA",
            SupportedBank::AkBank => "AKBANK",
            SupportedBank::YapiKredi => "YAPI_KREDI",
            SupportedBank::Halkbank => "HALKBANK",
            SupportedBank::Vakifbank => "VAKIFBANK",
            SupportedBank::DenizBank => "DENIZBANK",
            SupportedBank::QnbFinansbank => "QNB_FINANSBANK",
        }
    }

    /// Five-digit EFT bank code carried in characters 5–9 of the bank's IBANs.
    pub fn eft_code(&self) -> &'static str {
        match self {
            SupportedBank::KuveytTurk => "00205",
            SupportedBank::IsBankasi => "00064",
            SupportedBank::ZiraatBankasi => "00010",
            SupportedBank::GarantiBbva => "00062",
            SupportedBank::AkBank => "00046",
            SupportedBank::YapiKredi => "00067",
            SupportedBank::Halkbank => "00012",
            SupportedBank::Vakifbank => "00015",
            SupportedBank::DenizBank => "00134",
            SupportedBank::QnbFinansbank => "00111",
        }
    }

    /// Human-readable display name for the bank.
    pub fn display_name(&self) -> &'static str {
        match self {
            SupportedBank::KuveytTurk => "Kuveyt Türk Katılım Bankası",
            SupportedBank::IsBankasi => "Türkiye İş Bankası",
            SupportedBank::ZiraatBankasi => "Ziraat Bankası",
            SupportedBank::GarantiBbva => "Garanti BBVA",
            SupportedBank::AkBank => "Akbank",
            SupportedBank::YapiKredi => "Yapı Kredi Bankası",
            SupportedBank::Halkbank => "Halkbank",
            SupportedBank::Vakifbank => "Vakıfbank",
            SupportedBank::DenizBank => "DenizBank",
            SupportedBank::QnbFinansbank => "QNB Finansbank",
        }
    }

    /// Derives the required statement file format from the bank.
    /// Banks that provide SWIFT MT940 exports use MT940;
    /// banks whose online-banking portal exports XLSX use Excel.
    /// All others default to CSV.
    pub fn statement_format(&self) -> BankStatementFormat {
        match self {
            // Kuveyt Türk and Yapı Kredi export XLSX from online banking
            SupportedBank::KuveytTurk | SupportedBank::YapiKredi => BankStatementFormat::Excel,
            // Ziraat, Halkbank, Vakıfbank support MT940 exports
            SupportedBank::ZiraatBankasi | SupportedBank::Halkbank | SupportedBank::Vakifbank => {
                BankStatementFormat::Mt940
            }
            // All others use CSV
            _ => BankStatementFormat::Csv,
        }
    }

    /// Resolves a bank from its code string (case-insensitive).
    pub fn from_code(code: &str) -> Option<Self> {
        match code.to_uppercase().as_str() {
            "KUVEYT_TURK" => Some(SupportedBank::KuveytTurk),
            "IS_BANKASI" => Some(SupportedBank::IsBankasi),
            "ZIRAAT_BANKASI" => Some(SupportedBank::ZiraatBankasi),
            "GARANTI_BBVA" => Some(SupportedBank::GarantiBbva),
            "AKBANK" => Some(SupportedBank::AkBank),
            "YAPI_KREDI" => Some(SupportedBank::YapiKredi),
            "HALKBANK" => Some(SupportedBank::Halkbank),
            "VAKIFBANK" => Some(SupportedBank::Vakifbank),
            "DENIZBANK" => Some(SupportedBank::DenizBank),
            "QNB_FINANSBANK" => Some(SupportedBank::QnbFinansbank),
            _ => None,
        }
    }
}

/// The single active bank account for a site, as persisted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteBankAccount {
    pub id: String,
    pub site_id: String,
    pub bank_code: String,
    pub bank_name: String,
    pub iban: String,
    pub account_holder: String,
    /// Automatically derived from bank_code; stored as canonical string.
    pub statement_format: BankStatementFormat,
    pub is_active: bool,
    pub configured_by: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

// --- Request / Response DTOs ---

/// Request body for configuring or replacing the site bank account.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigureBankAccountRequest {
    /// One of the supported bank codes, e.g. "KUVEYT_TURK".
    pub bank_code: String,
    /// IBAN in TR format (26 chars, e.g. TR620020500009863791600001).
    pub iban: String,
    /// Legal name of the account holder.
    pub account_holder: String,
    /// Optional: ID of the user performing the configuration.
    pub configured_by: Option<String>,
}

/// Full bank account info returned to the client, including the auto-set format.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankAccountConfigResponse {
    pub id: String,
    pub site_id: String,
    pub bank_code: String,
    pub bank_name: String,
    pub iban: String,
    pub account_holder: String,
    /// The statement file format required for this bank (EXCEL / CSV / MT940).
    pub statement_format: BankStatementFormat,
    pub is_active: bool,
    pub configured_by: Option<String>,
    pub updated_at: DateTime<Utc>,
}

/// Lightweight catalogue entry used to populate the bank selector dropdown.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SupportedBankEntry {
    pub code: String,
    pub display_name: String,
    /// Statement format automatically applied when this bank is selected.
    pub statement_format: BankStatementFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BankStatementFormat {
    #[default]
    Excel,
    Csv,
    Mt940,
    Auto,
}

impl BankStatementFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            BankStatementFormat::Excel => "EXCEL",
            BankStatementFormat::Csv => "CSV",
            BankStatementFormat::Mt940 => "MT940",
            BankStatementFormat::Auto => "AUTO",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "CSV" => BankStatementFormat::Csv,
            "MT940" => BankStatementFormat::Mt940,
            "AUTO" => BankStatementFormat::Auto,
            _ => BankStatementFormat::Excel,
        }
    }
}

impl std::fmt::Display for BankStatementFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(BankStatementFormat);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ReconciliationStatus {
    PendingApproval,  // "ONAY_BEKLIYOR"
    Approved,         // "ONAYLANDI"
    Unmatched,        // "ESLESTIRILEMEDI"
    Rejected,         // "REDDEDILDI"
    AlreadyProcessed, // "ZATEN_YUKLENDI"
}

impl ReconciliationStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            ReconciliationStatus::PendingApproval => "ONAY_BEKLIYOR",
            ReconciliationStatus::Approved => "ONAYLANDI",
            ReconciliationStatus::Unmatched => "ESLESTIRILEMEDI",
            ReconciliationStatus::Rejected => "REDDEDILDI",
            ReconciliationStatus::AlreadyProcessed => "ZATEN_YUKLENDI",
        }
    }

    /// The single stored vocabulary of `reconciliation_queue.status` (V17, O-7).
    pub fn db_code(&self) -> &'static str {
        match self {
            ReconciliationStatus::PendingApproval => "PENDING_APPROVAL",
            ReconciliationStatus::Approved => "APPROVED",
            ReconciliationStatus::Unmatched => "UNMATCHED",
            ReconciliationStatus::Rejected => "REJECTED",
            ReconciliationStatus::AlreadyProcessed => "ALREADY_PROCESSED",
        }
    }

    pub fn from_db_code(code: &str) -> Self {
        match code {
            "APPROVED" => ReconciliationStatus::Approved,
            "UNMATCHED" => ReconciliationStatus::Unmatched,
            "REJECTED" => ReconciliationStatus::Rejected,
            "ALREADY_PROCESSED" => ReconciliationStatus::AlreadyProcessed,
            _ => ReconciliationStatus::PendingApproval,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankTransactionItem {
    pub transaction_id: String,
    pub date: NaiveDate,
    pub amount: Decimal,
    pub currency: String,
    pub description: String,
    pub sender_name: Option<String>,
    pub sender_iban: Option<String>,
    pub reference_no: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReconciliationMatch {
    pub match_id: String,
    #[serde(default)]
    pub site_id: String,
    pub transaction: BankTransactionItem,
    pub matched_unit_id: Option<String>,
    pub matched_block: Option<String>,
    pub matched_unit_number: Option<i32>,
    pub matched_resident_name: Option<String>,
    pub confidence_score: u8,
    pub matched_due_id: Option<String>,
    pub outstanding_balance: Option<Decimal>,
    pub amount_matches_balance: bool,
    pub status: ReconciliationStatus,
    pub status_code: String,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParseBankStatementRequest {
    pub site_id: String,
    pub content: String,
    pub format: Option<BankStatementFormat>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParseBankStatementResponse {
    pub site_id: String,
    pub total_transactions: usize,
    pub matched_count: usize,
    pub unmatched_count: usize,
    #[serde(default)]
    pub already_processed_count: usize,
    pub matches: Vec<ReconciliationMatch>,
    /// Statement entries that were not imported, with the reason. Previously
    /// such rows were dropped silently.
    #[serde(default)]
    pub skipped_entries: Vec<SkippedStatementEntry>,
}

/// A statement line or MT940 entry that was not turned into a transaction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SkippedStatementEntry {
    /// 1-based line number in the uploaded content.
    pub line_number: usize,
    pub reason: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfirmReconciliationRequest {
    pub site_id: String,
    pub match_ids: Vec<String>,
    /// Client matched rows are accepted for uploads that were parsed locally.
    /// The handler revalidates the site and unit before recording any payment.
    #[serde(default)]
    pub matches: Vec<ReconciliationMatch>,
    #[serde(default)]
    pub optional_message: Option<String>,
    #[serde(default)]
    pub remember_sender_iban: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfirmReconciliationResponse {
    pub confirmed_count: usize,
    pub total_amount_cleared: Decimal,
    pub updated_unit_ids: Vec<String>,
    pub confirmed_matches: Vec<ReconciliationMatch>,
    #[serde(default)]
    pub message_sent: bool,
    #[serde(default)]
    pub notification_summary: Option<String>,
    #[serde(default)]
    pub remembered_ibans_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RememberSenderIbanRequest {
    pub site_id: String,
    pub unit_id: String,
    pub sender_iban: String,
    #[serde(default)]
    pub sender_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RememberSenderIbanResponse {
    pub success: bool,
    pub unit_id: String,
    pub sender_iban: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankIncomingWebhookRequest {
    pub transaction_id: String,
    pub virtual_iban: String,
    pub amount: Decimal,
    #[serde(default)]
    pub currency: Option<String>,
    #[serde(default)]
    pub sender_name: Option<String>,
    #[serde(default)]
    pub sender_iban: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub signature: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BankIncomingWebhookResponse {
    pub status: String,
    pub transaction_id: String,
    pub matched_unit_id: String,
    pub matched_block: String,
    pub matched_unit_number: i32,
    pub cleared_due_period: Option<String>,
    pub cleared_amount: Decimal,
    pub remaining_debt: Decimal,
    #[serde(default)]
    pub advance_payment: Decimal,
    pub receipt_id: String,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum PaymentMatchStatus {
    Pending,
    MatchedDebt,
    MatchedAdvance,
    PartiallyMatched,
}

impl PaymentMatchStatus {
    #[allow(dead_code)]
    pub fn as_str(&self) -> &'static str {
        match self {
            PaymentMatchStatus::Pending => "PENDING",
            PaymentMatchStatus::MatchedDebt => "MATCHED_DEBT",
            PaymentMatchStatus::MatchedAdvance => "MATCHED_ADVANCE",
            PaymentMatchStatus::PartiallyMatched => "PARTIALLY_MATCHED",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeownerPaymentRecord {
    pub id: String,
    pub unit_id: String,
    pub block_id: String,
    pub unit_number: i32,
    pub homeowner_name: Option<String>,
    pub amount: Decimal,
    pub payment_method: PaymentChannel,
    pub reference_code: Option<String>,
    pub note: Option<String>,
    pub status: PaymentMatchStatus,
    pub cleared_debt_amount: Decimal,
    pub advance_credit_amount: Decimal,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordHomeownerPaymentRequest {
    pub unit_id: String,
    pub amount: Decimal,
    pub payment_method: PaymentChannel,
    #[serde(default)]
    pub reference_code: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub homeowner_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordHomeownerPaymentResponse {
    pub payment_id: String,
    pub unit_id: String,
    pub amount: Decimal,
    pub cleared_debt_amount: Decimal,
    pub advance_payment_amount: Decimal,
    pub remaining_debt: Decimal,
    pub total_unit_advance_balance: Decimal,
    pub status: PaymentMatchStatus,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchAllPaymentsRequest {
    #[serde(default)]
    pub site_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchAllPaymentsResponse {
    pub total_payments_processed: usize,
    pub total_debt_cleared: Decimal,
    pub total_advance_credited: Decimal,
    pub matched_debts_count: usize,
    pub matched_advance_count: usize,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredSenderIbanDto {
    pub sender_iban: String,
    pub formatted_iban: String,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub bank_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitMatchingCriteriaDto {
    pub unit_id: String,
    pub block: String,
    pub unit_number: i32,
    pub resident_name: String,
    pub virtual_iban: Option<String>,
    pub remembered_ibans: Vec<RegisteredSenderIbanDto>,
    pub registered_payer_names: Vec<String>,
    pub recommended_description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AddSenderIbanRequest {
    pub sender_iban: String,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub bank_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdatePayerNamesRequest {
    pub payer_names: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvisionSiteUnitsRequest {
    pub site_id: Option<String>,
    pub site_name: Option<String>,
    pub block: Option<String>,
    pub units_count: Option<usize>,
    pub monthly_dues: Option<Decimal>,
    pub accrue_initial_dues: Option<bool>,
    pub period: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvisionedUnitDto {
    pub unit_id: String,
    pub unit_number: i32,
    pub block: String,
    pub floor: i32,
    pub resident_name: String,
    pub email: String,
    pub phone: String,
    pub virtual_iban: String,
    pub current_debt: Decimal,
    pub advance_balance: Decimal,
    pub sender_iban: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProvisionSiteUnitsResponse {
    pub status: String,
    pub message: String,
    pub site_id: String,
    pub site_name: String,
    pub units_count: usize,
    pub total_monthly_dues_volume: Decimal,
    pub units: Vec<ProvisionedUnitDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteOverviewQuery {
    pub site_id: Option<String>,
    pub period: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteSummaryBriefDto {
    pub id: String,
    pub name: String,
    pub address: String,
    pub total_units: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteCollectionSummaryDto {
    pub total_expected: Decimal,
    pub total_collected: Decimal,
    pub total_overdue_with_interest: Decimal,
    pub total_advance_balance: Decimal,
    pub paid_units_count: usize,
    pub overdue_units_count: usize,
    pub total_units_count: usize,
    pub collection_percentage: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteFlatStatusDto {
    pub id: String,
    pub block: String,
    pub unit_no: i32,
    pub resident_name: String,
    pub amount_due: Decimal,
    pub days_overdue: i32,
    pub is_paid: bool,
    pub paid_date_str: Option<String>,
    pub virtual_iban: Option<String>,
    pub advance_balance: Decimal,
    #[serde(default)]
    pub registered_payer_names: Vec<String>,
    #[serde(default)]
    pub house_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteOverviewResponse {
    pub site_id: String,
    pub site_name: String,
    pub address: String,
    pub manager_name: String,
    pub manager_email: String,
    pub selected_period: String,
    pub available_periods: Vec<String>,
    pub available_sites: Vec<SiteSummaryBriefDto>,
    pub summary: SiteCollectionSummaryDto,
    pub flats: Vec<SiteFlatStatusDto>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guidance: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AllocationBreakdownItem {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_id: Option<String>,
    pub period: String,
    pub expense_type: ExpenseType,
    pub principal_paid: Decimal,
    pub penalty_paid: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentReceipt {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    pub receipt_number: String,
    pub sequence_number: i64,
    pub payer_name: String,
    pub payer_role: DebtorType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of_role: Option<DebtorType>,
    pub total_amount: Decimal,
    pub payment_channel: PaymentChannel,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_reference: Option<String>,
    pub allocated_principal: Decimal,
    pub allocated_penalty: Decimal,
    pub allocated_advance: Decimal,
    #[serde(default)]
    pub allocation_breakdown: Vec<AllocationBreakdownItem>,
    pub is_rent_offset_eligible: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legal_statutory_note: Option<String>,
    pub verification_hash: String,
    pub issued_at: DateTime<Utc>,
    /// `COLLECTION` (TAH- series) or `REVERSAL` (IAD- series).
    #[serde(default = "default_ledger_kind")]
    pub receipt_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverses_receipt_id: Option<i64>,
    /// The debtor whose advance received `allocated_advance` (None when it is 0).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub advance_debtor_type: Option<String>,
    /// Issuer legal details as printed when the receipt was issued.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issuer_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issuer_address: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issuer_tax_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issuer_tax_office: Option<String>,
}

pub const LEDGER_KIND_COLLECTION: &str = "COLLECTION";
pub const LEDGER_KIND_REVERSAL: &str = "REVERSAL";

pub fn default_ledger_kind() -> String {
    LEDGER_KIND_COLLECTION.to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentEntry {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_label: Option<String>,
    pub payer_name: String,
    pub payer_role: DebtorType,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_number: Option<String>,
    pub amount: Decimal,
    pub payment_channel: PaymentChannel,
    pub settlement_status: SettlementStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_reference: Option<String>,
    pub payment_date: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    /// `COLLECTION`, or `REVERSAL` for the contra entry of a reversed payment.
    #[serde(default = "default_ledger_kind")]
    pub entry_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reverses_entry_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reversal_reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded_by: Option<String>,
}

/// A unit's advance (avans) balance, one bucket per debtor (V12 `advance_balances`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnitAdvance {
    pub owner: Decimal,
    pub tenant: Decimal,
}

impl UnitAdvance {
    pub fn total(&self) -> Decimal {
        self.owner + self.tenant
    }

    /// Balance of one debtor (`OWNER` or `TENANT`, case-insensitive).
    pub fn of(&self, debtor_type: &str) -> Decimal {
        if debtor_type.eq_ignore_ascii_case("OWNER") {
            self.owner
        } else {
            self.tenant
        }
    }

    pub fn bucket_mut(&mut self, debtor_type: &str) -> &mut Decimal {
        if debtor_type.eq_ignore_ascii_case("OWNER") {
            &mut self.owner
        } else {
            &mut self.tenant
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PaymentStreamFilter {
    #[serde(default)]
    pub site_id: Option<String>,
    #[serde(default)]
    pub channel: Option<PaymentChannel>,
    #[serde(default)]
    pub payer_role: Option<DebtorType>,
    #[serde(default)]
    pub settlement_status: Option<SettlementStatus>,
    #[serde(default)]
    pub unit_id: Option<String>,
    #[serde(default)]
    pub search: Option<String>,
    #[serde(default)]
    pub start_date: Option<NaiveDate>,
    #[serde(default)]
    pub end_date: Option<NaiveDate>,
    #[serde(default)]
    pub page: Option<usize>,
    #[serde(default)]
    pub page_size: Option<usize>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub offset: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentStreamResponse {
    pub entries: Vec<PaymentEntry>,
    pub total_volume: Decimal,
    pub settled_volume: Decimal,
    pub unmatched_volume: Decimal,
    pub total_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebtAgingBracket {
    pub unit_id: String,
    pub unit_label: String,
    pub resident_name: String,
    pub debtor_type: DebtorType,
    pub current_due: Decimal,
    pub overdue_1_30_days: Decimal,
    pub overdue_31_60_days: Decimal,
    pub overdue_60_plus_days: Decimal,
    pub accrued_delay_penalty: Decimal,
    pub total_outstanding: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DebtAgingReport {
    pub as_of_date: NaiveDate,
    pub total_current: Decimal,
    pub total_1_30_days: Decimal,
    pub total_31_60_days: Decimal,
    pub total_60_plus_days: Decimal,
    pub total_penalty: Decimal,
    pub grand_total: Decimal,
    pub brackets: Vec<DebtAgingBracket>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct InterLedgerTransferRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
    pub amount: Decimal,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub operator_user_id: Option<String>,
    /// Whose advance is debited: `OWNER` (default) or `TENANT`.
    #[serde(default)]
    pub source_debtor: Option<String>,
    /// Whose liabilities are settled: `OWNER` (default, e.g. Demirbaş) or `TENANT`.
    /// TENANT -> OWNER is the tenant surplus paying the owner's capital dues.
    #[serde(default)]
    pub target_debtor: Option<String>,
}

/// Staff request to reverse a settled payment (SPEC-006 R2).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ReversePaymentRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    /// The receipt of the payment to reverse (`TAH-...` number or numeric id).
    pub receipt: String,
    /// Why the payment is reversed (bounced transfer, refund to payer, wrong unit...).
    /// A receipt is reversed at most once, so a retry returns the first reversal.
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReversePaymentResponse {
    pub reversal_receipt: PaymentReceipt,
    pub reversed_receipt_number: String,
    /// Advance that was refunded (debited from the advance ledger as REFUND).
    pub refunded_advance: Decimal,
    /// Liabilities whose paid amounts were restored.
    pub reopened_due_ids: Vec<String>,
    /// Advance credited back to the source debtor when a virman is reversed
    /// (written to the advance ledger as VIRMAN_REVERSAL); zero otherwise.
    #[serde(default)]
    pub restored_advance: Decimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InterLedgerTransferResponse {
    pub success: bool,
    pub message: String,
    pub receipt_number: String,
    pub transferred_amount: Decimal,
    pub remaining_advance_balance: Decimal,
    pub cleared_capital_due_amount: Decimal,
    pub verification_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RecordManualPaymentRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
    pub amount: Decimal,
    pub payer_name: String,
    #[serde(default)]
    pub payer_role: DebtorType,
    #[serde(default)]
    pub payment_channel: PaymentChannel,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub payment_date: Option<DateTime<Utc>>,
    /// Client-generated key; retrying with the same key returns the first receipt.
    #[serde(default)]
    pub idempotency_key: Option<String>,
    /// TBK 101: which liabilities the payer is paying (settled first).
    #[serde(default)]
    pub designation: Option<PaymentDesignation>,
    /// Bank/channel transaction reference, stored on the ledger entry.
    #[serde(default)]
    pub external_reference: Option<String>,
    /// When set (bank channels), a period named in `description` designates
    /// the liability if no explicit `designation` is given.
    #[serde(default)]
    pub designate_from_description: bool,
    /// Settles this existing UNMATCHED ledger entry instead of inserting a new
    /// one (match-all, SPEC-005 R2). Its amount must equal `amount`.
    #[serde(default)]
    pub settles_unmatched_entry_id: Option<String>,
}

/// Payer's designation of the liabilities a payment settles (TBK 101).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct PaymentDesignation {
    #[serde(default)]
    pub due_ids: Vec<String>,
    #[serde(default)]
    pub periods: Vec<String>,
    #[serde(default)]
    pub expense_type: Option<String>,
}

impl PaymentDesignation {
    pub fn is_empty(&self) -> bool {
        self.due_ids.is_empty() && self.periods.is_empty() && self.expense_type.is_none()
    }

    /// Human-readable form recorded on the ledger entry.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if !self.periods.is_empty() {
            parts.push(format!("periods={}", self.periods.join(",")));
        }
        if !self.due_ids.is_empty() {
            parts.push(format!("dues={}", self.due_ids.join(",")));
        }
        if let Some(e) = &self.expense_type {
            parts.push(format!("expense={}", e));
        }
        parts.join("; ")
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferOwnershipRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
    /// Preferred: the buyer as an existing card or a new one. Overrides the
    /// `new_owner_*` fields, which remain for one release.
    #[serde(default)]
    pub new_owner: Option<PersonRef>,
    #[serde(default)]
    pub new_owner_name: String,
    #[serde(default)]
    pub new_owner_national_id: Option<String>,
    #[serde(default)]
    pub new_owner_phone: Option<String>,
    #[serde(default)]
    pub new_owner_email: Option<String>,
    #[serde(default)]
    pub transfer_date: Option<NaiveDate>,
    #[serde(default)]
    pub notes: Option<String>,
    /// The buyer as an existing person of the site (for example the tenant
    /// buying the unit); otherwise a new owner is created from the fields above.
    #[serde(default)]
    pub new_owner_person_id: Option<i64>,
    /// The new owner moves in at transfer (owner-occupied units only, A4).
    #[serde(default)]
    pub new_owner_moves_in: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferOwnershipResponse {
    pub success: bool,
    pub message: String,
    pub unit_id: String,
    pub old_owner_name: String,
    pub old_owner_exit_balance: Decimal,
    pub new_owner_name: String,
    pub transferred_at: DateTime<Utc>,
}

// ==========================================
// EPIC-10: Capital Projects & Fixture Dues Models
// ==========================================

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CapitalProjectCategory {
    Elevator,
    FacadeInsulation,
    RoofWaterproofing,
    Generator,
    SecuritySystem,
    FireSafety,
    #[default]
    Other,
}

impl CapitalProjectCategory {
    pub fn as_str(&self) -> &'static str {
        match self {
            CapitalProjectCategory::Elevator => "ELEVATOR",
            CapitalProjectCategory::FacadeInsulation => "FACADE_INSULATION",
            CapitalProjectCategory::RoofWaterproofing => "ROOF_WATERPROOFING",
            CapitalProjectCategory::Generator => "GENERATOR",
            CapitalProjectCategory::SecuritySystem => "SECURITY_SYSTEM",
            CapitalProjectCategory::FireSafety => "FIRE_SAFETY",
            CapitalProjectCategory::Other => "OTHER",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "ELEVATOR" | "ASANSOR" => CapitalProjectCategory::Elevator,
            "FACADE_INSULATION" | "MANTOLAMA" => CapitalProjectCategory::FacadeInsulation,
            "ROOF_WATERPROOFING" | "ROOF_FACADE" | "CATI" => {
                CapitalProjectCategory::RoofWaterproofing
            }
            "GENERATOR" | "JENERATOR" => CapitalProjectCategory::Generator,
            "SECURITY_SYSTEM" | "GUVENLIK" => CapitalProjectCategory::SecuritySystem,
            "FIRE_SAFETY" | "YANGIN" => CapitalProjectCategory::FireSafety,
            _ => CapitalProjectCategory::Other,
        }
    }
}

impl std::fmt::Display for CapitalProjectCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(CapitalProjectCategory);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum AllocationBasis {
    #[default]
    ByLandShare,
    EqualPerUnit,
}

impl AllocationBasis {
    pub fn as_str(&self) -> &'static str {
        match self {
            AllocationBasis::ByLandShare => "BY_LAND_SHARE",
            AllocationBasis::EqualPerUnit => "EQUAL_PER_UNIT",
        }
    }

    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "EQUAL_PER_UNIT" => AllocationBasis::EqualPerUnit,
            _ => AllocationBasis::ByLandShare,
        }
    }
}

impl std::fmt::Display for AllocationBasis {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.as_str())
    }
}

impl_sql_for_enum!(AllocationBasis);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapitalProject {
    pub id: String,
    pub site_id: String,
    pub title: String,
    pub category: CapitalProjectCategory,
    #[serde(default)]
    pub description: Option<String>,
    pub total_budget: Decimal,
    pub allocation_basis: AllocationBasis,
    pub target_start_date: NaiveDate,
    #[serde(default)]
    pub target_completion_date: Option<NaiveDate>,
    #[serde(default)]
    pub contractor_name: Option<String>,
    #[serde(default)]
    pub contractor_tax_no: Option<String>,
    #[serde(default)]
    pub contractor_iban: Option<String>,
    #[serde(default)]
    pub contract_amount: Option<Decimal>,
    pub status: CapitalProjectStatus,
    pub collected_amount: Decimal,
    pub disbursed_amount: Decimal,
    pub remaining_fund_balance: Decimal,
    pub total_units_count: i64,
    pub installments_count: i64,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapitalProjectInstallment {
    pub id: String,
    pub project_id: String,
    pub installment_number: i32,
    pub total_installments: i32,
    pub due_date: NaiveDate,
    pub installment_budget: Decimal,
    pub percentage: Decimal,
    pub is_accrued: bool,
    #[serde(default)]
    pub accrued_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapitalContractorDisbursement {
    pub id: String,
    pub project_id: String,
    pub milestone_name: String,
    #[serde(default)]
    pub invoice_number: Option<String>,
    pub amount: Decimal,
    pub disbursement_date: NaiveDate,
    pub recipient_name: String,
    pub recipient_iban: String,
    #[serde(default)]
    pub payment_reference: Option<String>,
    #[serde(default)]
    pub disbursement_method: DisbursementMethod,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnitCapitalShareSummary {
    pub unit_id: String,
    pub block: String,
    pub unit_number: i32,
    pub owner_name: String,
    #[serde(default)]
    pub owner_phone: Option<String>,
    pub land_share: i32,
    pub total_project_share: Decimal,
    pub total_accrued: Decimal,
    pub total_paid: Decimal,
    pub remaining_debt: Decimal,
    pub is_settled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateCapitalProjectRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub title: String,
    #[serde(default)]
    pub category: Option<CapitalProjectCategory>,
    #[serde(default)]
    pub description: Option<String>,
    pub total_budget: Decimal,
    #[serde(default)]
    pub allocation_basis: Option<AllocationBasis>,
    #[serde(default)]
    pub target_start_date: Option<NaiveDate>,
    #[serde(default)]
    pub target_completion_date: Option<NaiveDate>,
    #[serde(default)]
    pub contractor_name: Option<String>,
    #[serde(default)]
    pub contractor_tax_no: Option<String>,
    #[serde(default)]
    pub contractor_iban: Option<String>,
    #[serde(default)]
    pub contract_amount: Option<Decimal>,
    #[serde(default)]
    pub installments: Option<Vec<CreateInstallmentItem>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateInstallmentItem {
    pub installment_number: i32,
    pub total_installments: i32,
    pub due_date: NaiveDate,
    pub installment_budget: Decimal,
    #[serde(default)]
    pub percentage: Option<Decimal>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccrueInstallmentRequest {
    pub installment_number: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccrueInstallmentResponse {
    pub success: bool,
    pub message: String,
    pub project_id: String,
    pub installment_number: i32,
    pub total_accrued_amount: Decimal,
    pub charged_units_count: i64,
    pub accrued_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordDisbursementRequest {
    pub milestone_name: String,
    #[serde(default)]
    pub invoice_number: Option<String>,
    pub amount: Decimal,
    #[serde(default)]
    pub disbursement_date: Option<NaiveDate>,
    pub recipient_name: String,
    pub recipient_iban: String,
    #[serde(default)]
    pub payment_reference: Option<String>,
    #[serde(default)]
    pub disbursement_method: Option<DisbursementMethod>,
    #[serde(default)]
    pub notes: Option<String>,
}
