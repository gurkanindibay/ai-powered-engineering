//! Registration approval and invitation link route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};

use super::site_admin::SiteIdParam;
use crate::models::{
    ApprovalResultResponse, PendingRegistrationResponse, SiteInvitationLinkResponse,
    SubmitSelfRegistrationRequest,
};
use crate::services::RegistrationApprovalService;
use crate::state::AppState;

pub async fn generate_registration_link(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<SiteInvitationLinkResponse>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = RegistrationApprovalService::new(state);
    Ok(Json(service.generate_invitation_link(&site_id).await))
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
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<PendingRegistrationResponse>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = RegistrationApprovalService::new(state);
    Ok(Json(service.get_pending_registrations(&site_id).await))
}

pub async fn approve_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
    ctx: crate::authorization::AuthzContext,
) -> Result<Json<ApprovalResultResponse>, crate::authorization::SecurityError> {
    RegistrationApprovalService::new(state)
        .approve_registration(&ctx, &request_id)
        .await
        .map(Json)
}

pub async fn reject_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
    ctx: crate::authorization::AuthzContext,
) -> Result<Json<PendingRegistrationResponse>, crate::authorization::SecurityError> {
    RegistrationApprovalService::new(state)
        .reject_registration(&ctx, &request_id)
        .await
        .map(Json)
}
