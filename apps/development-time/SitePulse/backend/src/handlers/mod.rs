use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::json;

use crate::models::*;
use crate::services::{
    AuthService, DuesCalculationService, HomeResidentInvitationService,
    RegistrationApprovalService, SaasTenantService, SiteAdminService,
};
use crate::state::AppState;

// 1. Resident Dashboard Handler
pub async fn get_resident_dashboard(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let calc_service = DuesCalculationService::new();
    let inner = state.inner.read().await;

    let unit = inner
        .units
        .iter()
        .find(|u| u.id == unit_id)
        .cloned()
        .unwrap_or(IndependentUnit {
            id: unit_id.clone(),
            site_id: "site-1".to_string(),
            block_id: "A".to_string(),
            unit_number: 14,
            floor: 4,
            land_share: 24,
            owner_user_id: None,
            tenant_user_id: None,
        });

    let today = Utc::now().date_naive();
    let evaluated_dues: Vec<DuesLiability> = inner
        .dues
        .iter()
        .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
        .map(|d| calc_service.calculate_delay_penalty(d.clone(), today))
        .collect();

    let total_debt: Decimal = evaluated_dues.iter().map(|d| d.total_amount).sum();
    let is_overdue = evaluated_dues.iter().any(|d| d.status == DebtStatus::Overdue);

    let dues_dtos: Vec<DuesSummaryDto> = evaluated_dues
        .into_iter()
        .map(|d| DuesSummaryDto {
            id: d.id,
            period: d.period,
            principal_amount: d.principal_amount,
            delay_penalty: d.delay_penalty,
            total_amount: d.total_amount,
            due_date: d.due_date.to_string(),
            status: format!("{:?}", d.status).to_uppercase(),
        })
        .collect();

    let site_title = format!("Begonya Sitesi • {} Blok D:{}", unit.block_id, unit.unit_number);

    let response = ResidentDashboardDto {
        unit_id: unit.id,
        site_title,
        total_debt,
        is_overdue,
        dues: dues_dtos,
        announcement_title: "Planlı Su Kesintisi Hakkında".to_string(),
        announcement_content:
            "İSKİ ana hat yenilemesi sebebiyle 18 Eylül 10:00 - 14:00 arası su kesilecektir."
                .to_string(),
    };

    (StatusCode::OK, Json(response))
}

// 2. Auth Handlers
pub async fn login_password(
    State(state): State<AppState>,
    Json(payload): Json<PasswordLoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .authenticate_with_password(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::UNAUTHORIZED, e))
}

pub async fn login_google(
    State(state): State<AppState>,
    Json(payload): Json<GoogleLoginRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .authenticate_with_google(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn register_password(
    State(state): State<AppState>,
    Json(payload): Json<RegisterUserRequest>,
) -> Result<(StatusCode, Json<AuthResponse>), (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .register_with_password(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

#[derive(Deserialize)]
pub struct ProfileQuery {
    pub user_id: Option<String>,
}

pub async fn get_profile(
    State(state): State<AppState>,
    Query(query): Query<ProfileQuery>,
) -> Result<Json<UserProfileResponse>, (StatusCode, String)> {
    let user_id = query
        .user_id
        .unwrap_or_else(|| "usr-site-manager-1".to_string());
    let service = AuthService::new(state);
    service
        .get_current_profile(&user_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}

// 3. SaaS Tenant Handlers
pub async fn register_site(
    State(state): State<AppState>,
    Json(payload): Json<RegisterSiteRequest>,
) -> Result<(StatusCode, Json<SiteRegistrationResponse>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .register_site(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_all_sites(State(state): State<AppState>) -> Json<Vec<SaasSiteSummaryDto>> {
    let service = SaasTenantService::new(state);
    Json(service.get_all_sites().await)
}

pub async fn get_saas_stats(State(state): State<AppState>) -> Json<SaasGlobalStatsDto> {
    let service = SaasTenantService::new(state);
    Json(service.get_global_stats().await)
}

pub async fn delete_site(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .delete_site(&site_id)
        .await
        .map(|_| {
            (
                StatusCode::OK,
                Json(json!({
                    "success": true,
                    "message": format!("Site '{}' successfully deleted", site_id)
                })),
            )
        })
        .map_err(|e| (StatusCode::CONFLICT, e))
}

// 4. Site Admin Handlers
#[derive(Deserialize)]
pub struct SiteIdParam {
    pub site_id: Option<String>,
}

pub async fn register_home_owner(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HomeOwnerResponse>> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = SiteAdminService::new(state);
    Json(service.get_home_owners_for_site(&site_id).await)
}

// 5. Registration Approval Handlers
pub async fn generate_registration_link(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<SiteInvitationLinkResponse> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = RegistrationApprovalService::new(state);
    Json(service.generate_invitation_link(&site_id).await)
}

pub async fn submit_self_registration(
    Path(slug): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<SubmitSelfRegistrationRequest>,
) -> Result<(StatusCode, Json<PendingRegistrationResponse>), (StatusCode, String)> {
    let service = RegistrationApprovalService::new(state);
    service
        .submit_self_registration(&slug, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_pending_registrations(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<PendingRegistrationResponse>> {
    let site_id = q.site_id.unwrap_or_else(|| "site-1".to_string());
    let service = RegistrationApprovalService::new(state);
    Json(service.get_pending_registrations(&site_id).await)
}

pub async fn approve_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<ApprovalResultResponse>, (StatusCode, String)> {
    let service = RegistrationApprovalService::new(state);
    service
        .approve_registration(&request_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn reject_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<PendingRegistrationResponse>, (StatusCode, String)> {
    let service = RegistrationApprovalService::new(state);
    service
        .reject_registration(&request_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

// 6. Unit Co-Resident Invitation Handlers
pub async fn generate_unit_invite_link(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Json<UnitInviteLinkResponse> {
    let service = HomeResidentInvitationService::new(state);
    Json(service.generate_unit_invite_link(&unit_id, None).await)
}

pub async fn register_home_resident(
    State(state): State<AppState>,
    Json(payload): Json<RegisterHomeResidentRequest>,
) -> Result<(StatusCode, Json<HomeResidentResponse>), (StatusCode, String)> {
    let service = HomeResidentInvitationService::new(state);
    service
        .register_home_resident(payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_unit_members(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Json<Vec<UnitMemberDto>> {
    let service = HomeResidentInvitationService::new(state);
    Json(service.get_unit_members(&unit_id).await)
}

// 7. Health Check
pub async fn health_check() -> impl IntoResponse {
    (
        StatusCode::OK,
        Json(json!({
            "status": "UP",
            "service": "SitePulse Rust Backend",
            "version": "1.0.0",
            "engine": "Axum / Tokio",
        })),
    )
}
