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
            "HOME_RESIDENT" | "EV_SAKINI" | "RESIDENT" => Role::HomeResident,
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
pub struct RegisterHomeOwnerRequest {
    pub block: String,
    pub unit_no: i32,
    pub floor: i32,
    pub owner_full_name: String,
    pub email: String,
    pub phone: String,
    pub land_share: Option<String>,
    pub monthly_dues: Option<Decimal>,
    pub is_resident: bool,
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
    pub is_resident: bool,
    pub temporary_password: Option<String>,
    pub must_change_password: bool,
    pub created_at: DateTime<Utc>,
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
