//! Authentication route handlers.

use axum::{extract::State, http::StatusCode, Json};

use crate::models::{
    AuthResponse, ChangePasswordRequest, GoogleLoginRequest, PasswordLoginRequest,
    RegisterUserRequest, UserProfileResponse,
};
use crate::services::AuthService;
use crate::state::AppState;

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

pub async fn change_password(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<AuthResponse>, (StatusCode, String)> {
    if !payload.email.trim().eq_ignore_ascii_case(&claims.email) {
        return Err((
            StatusCode::FORBIDDEN,
            "You can only change your own password".to_string(),
        ));
    }
    let service = AuthService::new(state);
    service
        .change_password(payload)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// Returns the profile of the authenticated caller (identity comes from the token).
pub async fn get_profile(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
) -> Result<Json<UserProfileResponse>, (StatusCode, String)> {
    let service = AuthService::new(state);
    service
        .get_current_profile(&claims.sub)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::NOT_FOUND, e))
}

/// Set the first password of an account with the single-use link the person received (S2/S3).
pub async fn activate_account(
    State(state): State<AppState>,
    Json(payload): Json<crate::services::account_activation_service::ActivateAccountRequest>,
) -> Result<StatusCode, crate::error::AppError> {
    crate::services::AccountActivationService::new(state)
        .activate(payload)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(super::site_admin::activation_error)
}

/// Apply a login email change once the new address confirms it (S5).
pub async fn confirm_email_change(
    State(state): State<AppState>,
    Json(payload): Json<crate::services::account_activation_service::ConfirmEmailRequest>,
) -> Result<StatusCode, crate::error::AppError> {
    crate::services::AccountActivationService::new(state)
        .confirm_email(payload)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(super::site_admin::activation_error)
}
