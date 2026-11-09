//! Site administration and unit management route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::authorization::{AuthzContext, SecurityError};
use crate::error::AppError;
use crate::models::Permission;
use crate::models::{
    BlockDto, CreateBlockRequest, CreateHouseTypeRequest, HomeOwnerResponse, HouseTypeTariff,
    MoveInResidentRequest, MoveOutResidentRequest, OccupancyHistoryItem, RegisterHomeOwnerRequest,
    UpdateHomeOwnerRequest,
};
use crate::services::account_activation_service::{ActivationDelivery, ActivationError};
use crate::services::site_admin_service as service;
use crate::services::AccountActivationService;
use crate::services::SiteAdminService;
use crate::state::AppState;
use axum::response::{IntoResponse, Response};

#[derive(Deserialize, Default)]
pub struct SiteIdParam {
    pub site_id: Option<String>,
}

/// Map a person-module service failure to the standard error envelope (S10):
/// storage and driver failures become a generic 500 with a trace id, never raw text.
pub(crate) fn person_error(e: String) -> AppError {
    const INTERNAL_MARKERS: [&str; 8] = [
        "db error",
        "DB ",
        "Database",
        "Failed to",
        "Transaction",
        "Activation storage",
        "connection",
        "error communicating",
    ];
    if e == service::UNIT_NOT_FOUND {
        AppError::not_found(e)
    } else if e == service::EMAIL_NOT_AVAILABLE || e == service::UNIT_HAS_FINANCIAL_HISTORY {
        AppError::conflict(e)
    } else if e == "Household storage unavailable" {
        AppError::unavailable(e)
    } else if INTERNAL_MARKERS.iter().any(|m| e.contains(m)) {
        AppError::internal(e)
    } else {
        AppError::validation(e)
    }
}

/// Map an activation failure to the standard error envelope.
pub(crate) fn activation_error(e: ActivationError) -> AppError {
    match e {
        ActivationError::InvalidToken | ActivationError::Password(_) => {
            AppError::validation(e.to_string())
        }
        ActivationError::UnitNotFound | ActivationError::NoLoginAccount => {
            AppError::not_found(e.to_string())
        }
        ActivationError::AlreadyActive => AppError::conflict(e.to_string()),
        ActivationError::Storage(_) => AppError::internal(e.to_string()),
    }
}

pub async fn register_home_owner(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(person_error)
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HomeOwnerResponse>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_home_owners_for_site(&site_id).await)
}

pub async fn update_home_owner(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateHomeOwnerRequest>,
) -> Response {
    let site_id = q.site_id.unwrap_or_default();
    // Contact edits need PersonManage (the route); a login email change is an identity
    // change and also needs PersonIdentityManage and a recent step-up.
    let may_change_identity = ctx.permissions.contains(&Permission::PersonIdentityManage);
    let result = SiteAdminService::new(state)
        .update_home_owner(
            &site_id,
            &id,
            payload,
            may_change_identity && ctx.stepped_up,
        )
        .await;
    match result {
        Ok(updated) => Json(updated).into_response(),
        Err(e) if e == service::LOGIN_CHANGE_NEEDS_STEP_UP && may_change_identity => {
            SecurityError::StepUp.into_response()
        }
        Err(e) if e == service::LOGIN_CHANGE_NEEDS_STEP_UP => {
            SecurityError::Forbidden.into_response()
        }
        Err(e) => person_error(e).into_response(),
    }
}

pub async fn delete_home_owner(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_home_owner(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(person_error)
}

/// The security boundary adds the caller's `site_id` to JSON bodies, so unknown
/// fields are tolerated here; only `role` is read.
#[derive(Deserialize)]
pub struct ResendActivationRequest {
    /// `OWNER` (default) or `TENANT`.
    #[serde(default)]
    pub role: Option<String>,
}

/// Send a fresh activation link to a unit's owner or tenant; older links stop working.
pub async fn resend_activation(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ResendActivationRequest>,
) -> Result<Json<ActivationDelivery>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let tenant = payload
        .role
        .as_deref()
        .is_some_and(|r| r.eq_ignore_ascii_case("TENANT"));
    AccountActivationService::new(state)
        .resend_for_unit(&site_id, &id, tenant)
        .await
        .map(Json)
        .map_err(activation_error)
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveOutResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_out_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn move_in_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveInResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_in_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_unit_occupancy_history(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<OccupancyHistoryItem>>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .get_unit_occupancy_history(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_house_types(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HouseTypeTariff>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_house_types_for_site(&site_id).await)
}

pub async fn create_house_type(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<HouseTypeTariff>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_house_type(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_house_type(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_house_type(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_blocks(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<BlockDto>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_blocks_for_site(&site_id).await)
}

pub async fn create_block(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateBlockRequest>,
) -> Result<(StatusCode, Json<BlockDto>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_block(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
