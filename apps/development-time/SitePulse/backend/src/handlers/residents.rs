//! Unit co-resident invitation and household members route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};

use super::site_admin::SiteIdParam;
use crate::models::{
    HomeResidentResponse, RegisterHomeResidentRequest, UnitInviteLinkResponse, UnitMemberDto,
};
use crate::services::{HomeResidentInvitationService, SiteAdminService};
use crate::state::AppState;

#[derive(Debug, serde::Deserialize)]
pub struct UpdateUnitMemberRequest {
    pub full_name: String,
    pub phone: String,
    pub email: String,
    #[serde(default)]
    pub relationship: Option<String>,
}

pub async fn generate_unit_invite_link(
    Path(unit_id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<UnitInviteLinkResponse>, crate::authorization::SecurityError> {
    HomeResidentInvitationService::new(state)
        .generate_unit_invite_link(&unit_id, None)
        .await
        .map(Json)
        .map_err(|_| crate::authorization::SecurityError::Unavailable)
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

pub async fn add_unit_member(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(unit_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::AddUnitMemberRequest>,
) -> Result<(StatusCode, Json<UnitMemberDto>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    let relationship = payload
        .relationship
        .unwrap_or_else(|| "Ev Sakini".to_string());
    service
        .add_unit_member(
            &site_id,
            &unit_id,
            &payload.full_name,
            &payload.phone,
            &payload.email,
            &relationship,
        )
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| {
            (
                if e == "Household storage unavailable" {
                    StatusCode::SERVICE_UNAVAILABLE
                } else {
                    StatusCode::BAD_REQUEST
                },
                e,
            )
        })
}

pub async fn delete_unit_member(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .delete_unit_member(&site_id, &unit_id, &resident_id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn update_unit_member(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateUnitMemberRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    let relationship = payload
        .relationship
        .unwrap_or_else(|| "Ev Sakini".to_string());
    service
        .update_unit_member(
            &site_id,
            &unit_id,
            &resident_id,
            &payload.full_name,
            &payload.phone,
            &payload.email,
            &relationship,
        )
        .await
        .map(|_| StatusCode::OK)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
