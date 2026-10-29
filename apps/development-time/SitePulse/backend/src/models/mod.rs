use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Role {
    HomeOwner,
    HomeResident,
    SiteManager,
    SaasAdmin,
}

impl Role {
    pub fn as_str(&self) -> &'static str {
        match self {
            Role::HomeOwner => "HOME_OWNER",
            Role::HomeResident => "HOME_RESIDENT",
            Role::SiteManager => "SITE_MANAGER",
            Role::SaasAdmin => "SAAS_ADMIN",
        }
    }

    #[allow(dead_code)]
    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "HOME_OWNER" | "KAT_MALIKI" => Role::HomeOwner,
            "HOME_RESIDENT" | "EV_SAKINI" | "RESIDENT" | "KAT_SAKINI" | "TENANT" => Role::HomeResident,
            "SITE_MANAGER" | "YONETICI" => Role::SiteManager,
            "SAAS_ADMIN" | "ADMIN" => Role::SaasAdmin,
            _ => Role::HomeOwner,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
            Permission::LedgerManageAll => "Manage dues liabilities and statutory delay penalties for all units",
            Permission::AnnouncementBroadcast => "Broadcast announcements and notifications to residents",
            Permission::TenantManage => "Manage SaaS platform sites and subscriptions",
        }
    }

    pub fn permissions_for_role(role: Role) -> Vec<Permission> {
        match role {
            Role::SaasAdmin => vec![
                Permission::TenantManage,
                Permission::SiteManage,
                Permission::AnnouncementBroadcast,
            ],
            Role::SiteManager => vec![
                Permission::SiteManage,
                Permission::ResidentInviteSite,
                Permission::ResidentApprove,
                Permission::LedgerManageAll,
                Permission::AnnouncementBroadcast,
            ],
            Role::HomeOwner => vec![
                Permission::UnitRead,
                Permission::UnitPay,
                Permission::UnitInviteCoResident,
                Permission::UnitManageHousehold,
            ],
            Role::HomeResident => vec![
                Permission::UnitRead,
                Permission::UnitPay,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesLiability {
    pub id: String,
    pub unit_id: String,
    pub period: String,
    pub principal_amount: Decimal,
    pub delay_penalty: Decimal,
    pub total_amount: Decimal,
    pub due_date: NaiveDate,
    pub status: DebtStatus,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesPeriod {
    pub id: String,
    pub site_id: String,
    pub period_name: String,
    pub due_date: NaiveDate,
    pub status: String, // "ACTIVE", "CLOSED", "DRAFT"
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
pub struct User {
    pub id: String,
    pub site_id: String,
    pub full_name: String,
    pub email: String,
    pub phone: String,
    pub password_hash: Option<String>,
    pub role: Role,
    pub must_change_password: bool,
    pub auth_provider: String,
    pub google_sub: Option<String>,
    pub avatar_url: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Site {
    pub id: String,
    pub name: String,
    pub address: String,
    pub slug: String,
    pub status: String,
    pub plan_type: String,
    pub license_end_date: NaiveDate,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DuesSummaryDto {
    pub id: String,
    pub period: String,
    pub principal_amount: Decimal,
    pub delay_penalty: Decimal,
    pub total_amount: Decimal,
    pub due_date: String,
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
pub struct AuthResponse {
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
    pub auth_provider: String,
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
    pub auth_provider: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SiteRegistrationResponse {
    pub site_id: String,
    pub site_name: String,
    pub slug: String,
    pub status: String,
    pub plan_type: String,
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
    pub status: String,
    pub plan_type: String,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[allow(dead_code)]
pub enum OccupancyStatus {
    OwnerOccupied,
    TenantOccupied,
    Vacant,
}

impl Default for OccupancyStatus {
    fn default() -> Self {
        OccupancyStatus::OwnerOccupied
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[allow(dead_code)]
pub enum ExpenseType {
    OperationalDues,
    CapitalDues,
}

impl Default for ExpenseType {
    fn default() -> Self {
        ExpenseType::OperationalDues
    }
}

impl ExpenseType {
    #[allow(dead_code)]
    pub fn as_str(&self) -> &'static str {
        match self {
            ExpenseType::OperationalDues => "OPERATIONAL_DUES",
            ExpenseType::CapitalDues => "CAPITAL_DUES",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[allow(dead_code)]
pub enum DebtorType {
    Tenant,
    Owner,
}

impl Default for DebtorType {
    fn default() -> Self {
        DebtorType::Tenant
    }
}

impl DebtorType {
    #[allow(dead_code)]
    pub fn as_str(&self) -> &'static str {
        match self {
            DebtorType::Tenant => "TENANT",
            DebtorType::Owner => "OWNER",
        }
    }
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
    pub role: String, // "TENANT" or "OWNER"
    pub start_date: Option<String>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OccupancyHistoryItem {
    pub id: i64,
    pub unit_id: i64,
    pub person_id: i64,
    pub person_name: String,
    pub person_phone: Option<String>,
    pub person_email: Option<String>,
    pub role: String,
    pub start_date: String,
    pub end_date: Option<String>,
    pub is_active: bool,
    pub exit_balance: Decimal,
    pub notes: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeOwnerResponse {
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
    pub temporary_password: Option<String>,
    pub must_change_password: bool,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub occupancy_status: Option<String>,
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
    pub status: String,
    pub submitted_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApprovalResultResponse {
    pub request_id: String,
    pub site_id: String,
    pub status: String,
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
    pub resident_id: String,
    pub full_name: String,
    pub relationship: String,
    pub phone: String,
    pub email: String,
    pub is_owner: bool,
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
            SupportedBank::ZiraatBankasi
            | SupportedBank::Halkbank
            | SupportedBank::Vakifbank => BankStatementFormat::Mt940,
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
    pub statement_format: String,
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
    pub statement_format: String,
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
    pub statement_format: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum BankStatementFormat {
    Excel,
    Csv,
    Mt940,
    Auto,
}

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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfirmReconciliationRequest {
    pub site_id: String,
    pub match_ids: Vec<String>,
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
    pub payment_method: String, // 'CREDIT_CARD', 'BANK_TRANSFER', 'FAST', 'CASH'
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
    pub payment_method: String,
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
    pub expense_type: String,
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
    pub payer_role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on_behalf_of_role: Option<String>,
    pub total_amount: Decimal,
    pub payment_channel: String,
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentEntry {
    pub id: i64,
    pub site_id: String,
    pub unit_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_label: Option<String>,
    pub payer_name: String,
    pub payer_role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_id: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receipt_number: Option<String>,
    pub amount: Decimal,
    pub payment_channel: String,
    pub settlement_status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_reference: Option<String>,
    pub payment_date: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PaymentStreamFilter {
    #[serde(default)]
    pub site_id: Option<String>,
    #[serde(default)]
    pub channel: Option<String>,
    #[serde(default)]
    pub payer_role: Option<String>,
    #[serde(default)]
    pub settlement_status: Option<String>,
    #[serde(default)]
    pub unit_id: Option<String>,
    #[serde(default)]
    pub search: Option<String>,
    #[serde(default)]
    pub start_date: Option<NaiveDate>,
    #[serde(default)]
    pub end_date: Option<NaiveDate>,
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
    pub debtor_type: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InterLedgerTransferRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
    pub amount: Decimal,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub operator_user_id: Option<String>,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordManualPaymentRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
    pub amount: Decimal,
    pub payer_name: String,
    #[serde(default = "default_payer_role")]
    pub payer_role: String,
    #[serde(default = "default_payment_channel")]
    pub payment_channel: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub payment_date: Option<DateTime<Utc>>,
}

fn default_payer_role() -> String {
    "TENANT".to_string()
}

fn default_payment_channel() -> String {
    "MANUAL_CASH".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferOwnershipRequest {
    #[serde(default)]
    pub site_id: Option<String>,
    pub unit_id: String,
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CapitalProjectCategory {
    Elevator,
    FacadeInsulation,
    RoofWaterproofing,
    Generator,
    SecuritySystem,
    FireSafety,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum AllocationBasis {
    ByLandShare,
    EqualPerUnit,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CapitalProject {
    pub id: String,
    pub site_id: String,
    pub title: String,
    pub category: String,
    #[serde(default)]
    pub description: Option<String>,
    pub total_budget: Decimal,
    pub allocation_basis: String,
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
    pub status: String,
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
    pub disbursement_method: String,
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
    pub category: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    pub total_budget: Decimal,
    #[serde(default)]
    pub allocation_basis: Option<String>,
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
    pub disbursement_method: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}



