//! Unit co-resident invitation and household members route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};

use super::site_admin::{person_error, SiteIdParam};
use crate::error::AppError;
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
) -> Result<(StatusCode, Json<UnitMemberDto>), AppError> {
    scope.pinned(q.site_id)?;
    let relationship = payload
        .relationship
        .clone()
        .unwrap_or_else(|| "OTHER".to_string());
    add_unit_member_by_ref(&state, &unit_id, &payload.person, &relationship).await
}

pub async fn delete_unit_member(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .delete_unit_member(&site_id, &unit_id, &resident_id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(person_error)
}

pub async fn update_unit_member(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path((unit_id, resident_id)): Path<(String, String)>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateUnitMemberRequest>,
) -> Result<StatusCode, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    let relationship = payload.relationship.unwrap_or_else(|| "OTHER".to_string());
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
        .map_err(person_error)
}

/// Adds a household member by person reference; the card is resolved in the same
/// transaction as the membership.
async fn add_unit_member_by_ref(
    state: &AppState,
    unit_id: &str,
    person: &crate::models::PersonRef,
    relationship: &str,
) -> Result<(StatusCode, Json<UnitMemberDto>), AppError> {
    use crate::services::person_service::PersonApiError;
    let pool = state
        .pool
        .as_ref()
        .ok_or_else(|| AppError::unavailable("Person records need the database"))?;
    let code =
        crate::domain::household_relationship::HouseholdRelationship::from_input(relationship)
            .ok_or_else(|| {
                AppError::validation(crate::domain::household_relationship::UNKNOWN_RELATIONSHIP)
            })?
            .as_str();
    let saved = crate::db::save_unit_member_ref(pool, unit_id, person, code)
        .await
        .map_err(|error| match error.downcast::<PersonApiError>() {
            Ok(person_error) => super::site_admin::person_api_error(*person_error),
            Err(other) if other.to_string() == crate::db::NO_CURRENT_OCCUPANT => {
                AppError::conflict("The unit has no current household to join")
            }
            Err(other) => {
                tracing::error!(error = %other, "Household member storage failure");
                AppError::unavailable("Household storage unavailable")
            }
        })?;
    let member = UnitMemberDto {
        resident_id: saved.member_id.to_string(),
        full_name: saved.full_name,
        relationship: code.to_string(),
        phone: saved.phone,
        email: saved.email,
        is_owner: false,
        occupancy_id: None,
        person_id: Some(saved.person_id),
        resident_user_id: None,
    };
    Ok((StatusCode::CREATED, Json(member)))
}
