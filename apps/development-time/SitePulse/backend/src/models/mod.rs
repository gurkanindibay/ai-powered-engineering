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
pub struct IndependentUnit {
    pub id: String,
    pub site_id: String,
    pub block_id: String,
    pub unit_number: i32,
    pub floor: i32,
    pub land_share: i32,
    pub owner_user_id: Option<String>,
    pub tenant_user_id: Option<String>,
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
pub struct ResidentDashboardDto {
    pub unit_id: String,
    pub site_title: String,
    pub total_debt: Decimal,
    pub is_overdue: bool,
    pub dues: Vec<DuesSummaryDto>,
    pub announcement_title: String,
    pub announcement_content: String,
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
