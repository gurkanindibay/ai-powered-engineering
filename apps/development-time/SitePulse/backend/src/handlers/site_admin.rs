//! Site administration and unit management route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::models::{
    BlockDto, CreateBlockRequest, CreateHouseTypeRequest, HomeOwnerResponse, HouseTypeTariff,
    MoveInResidentRequest, MoveOutResidentRequest, OccupancyHistoryItem, RegisterHomeOwnerRequest,
    UpdateHomeOwnerRequest,
};
use crate::services::SiteAdminService;
use crate::state::AppState;

#[derive(Deserialize, Default)]
pub struct SiteIdParam {
    pub site_id: Option<String>,
}

pub async fn register_home_owner(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<HomeOwnerResponse>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_home_owners_for_site(&site_id).await))
}

pub async fn update_home_owner(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateHomeOwnerRequest>,
) -> Result<Json<HomeOwnerResponse>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .update_home_owner(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_home_owner(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .delete_home_owner(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| {
            let code = if e == crate::services::site_admin_service::UNIT_HAS_FINANCIAL_HISTORY {
                StatusCode::CONFLICT
            } else {
                StatusCode::BAD_REQUEST
            };
            (code, e)
        })
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveOutResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .move_out_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn move_in_resident(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveInResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .move_in_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_unit_occupancy_history(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<OccupancyHistoryItem>>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .get_unit_occupancy_history(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_house_types(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<HouseTypeTariff>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_house_types_for_site(&site_id).await))
}

pub async fn create_house_type(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<HouseTypeTariff>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .create_or_update_house_type(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_house_type(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .delete_house_type(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_blocks(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<BlockDto>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_blocks_for_site(&site_id).await))
}

pub async fn create_block(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateBlockRequest>,
) -> Result<(StatusCode, Json<BlockDto>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .create_or_update_block(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
