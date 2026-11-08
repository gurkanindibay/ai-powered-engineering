//! SaaS multi-tenancy route handlers.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;

use crate::models::{
    RegisterSiteRequest, SaasGlobalStatsDto, SaasSiteSummaryDto, SiteAdminPasswordResetResponse,
    SiteRegistrationResponse, UpdateSiteRequest,
};
use crate::services::SaasTenantService;
use crate::state::AppState;

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

pub async fn update_site(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
    Json(payload): Json<UpdateSiteRequest>,
) -> Result<(StatusCode, Json<SaasSiteSummaryDto>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .update_site(&site_id, payload)
        .await
        .map(|res| (StatusCode::OK, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn reset_site_admin_password(
    Path(site_id): Path<String>,
    State(state): State<AppState>,
) -> Result<(StatusCode, Json<SiteAdminPasswordResetResponse>), (StatusCode, String)> {
    let service = SaasTenantService::new(state);
    service
        .reset_site_admin_password(&site_id)
        .await
        .map(|res| (StatusCode::OK, Json(res)))
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}
