//! Registration approval and invitation link route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};

use crate::models::{
    ApprovalResultResponse, PendingRegistrationResponse, SiteInvitationLinkResponse,
    SubmitSelfRegistrationRequest,
};
use crate::services::RegistrationApprovalService;
use crate::state::AppState;
use super::site_admin::SiteIdParam;

pub async fn generate_registration_link(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<SiteInvitationLinkResponse> {
    let site_id = q.site_id.unwrap_or_default();
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
    let site_id = q.site_id.unwrap_or_default();
    let service = RegistrationApprovalService::new(state);
    Json(service.get_pending_registrations(&site_id).await)
}

pub async fn approve_registration(
    Path(request_id): Path<String>,
    State(state): State<AppState>,
    claims: Option<axum::Extension<crate::auth::Claims>>,
) -> Result<Json<ApprovalResultResponse>, (StatusCode, String)> {
    if let Some(axum::Extension(ref c)) = claims {
        if !c.is_saas_admin() {
            let inner = state.inner.read().await;
            if let Some(r) = inner.pending_registrations.iter().find(|r| r.request_id == request_id) {
                if !crate::auth::same_id(&r.site_id, &c.site_id) {
                    return Err((StatusCode::FORBIDDEN, "Registration application belongs to another site".to_string()));
                }
            }
        }
    }
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
    claims: Option<axum::Extension<crate::auth::Claims>>,
) -> Result<Json<PendingRegistrationResponse>, (StatusCode, String)> {
    if let Some(axum::Extension(ref c)) = claims {
        if !c.is_saas_admin() {
            let inner = state.inner.read().await;
            if let Some(r) = inner.pending_registrations.iter().find(|r| r.request_id == request_id) {
                if !crate::auth::same_id(&r.site_id, &c.site_id) {
                    return Err((StatusCode::FORBIDDEN, "Registration application belongs to another site".to_string()));
                }
            }
        }
    }
    let service = RegistrationApprovalService::new(state);
    service
        .reject_registration(&request_id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
