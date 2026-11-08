//! Standardized API error handling and wire envelopes for SitePulse backend.
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};

/// Standardized JSON wire envelope for all API errors.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
}

/// Structured diagnostic payload conforming to SitePulse API error standards.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<serde_json::Value>,
    pub trace_id: String,
    pub timestamp: chrono::DateTime<chrono::Utc>,
}

/// Unified application error taxonomy.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("Validation error: {0}")]
    Validation(String, Option<serde_json::Value>),

    #[error("Resource not found: {0}")]
    NotFound(String),

    #[error("Conflict: {0}")]
    Conflict(String),

    #[error("Authentication required: {0}")]
    Unauthorized(String),

    #[error("Permission denied: {0}")]
    Forbidden(String),

    #[error("Business rule violation: {0}")]
    BusinessRule(String),

    #[error("Too many requests")]
    RateLimited,

    #[error("Service unavailable: {0}")]
    Unavailable(String),

    #[error("Internal server error: {0}")]
    Internal(String),

    #[error("Database error")]
    Database(#[from] tokio_postgres::Error),
}

pub type AppResult<T> = Result<T, AppError>;

impl AppError {
    pub fn validation(msg: impl Into<String>) -> Self {
        Self::Validation(msg.into(), None)
    }

    pub fn validation_with_details(msg: impl Into<String>, details: serde_json::Value) -> Self {
        Self::Validation(msg.into(), Some(details))
    }

    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::NotFound(msg.into())
    }

    pub fn conflict(msg: impl Into<String>) -> Self {
        Self::Conflict(msg.into())
    }

    pub fn forbidden(msg: impl Into<String>) -> Self {
        Self::Forbidden(msg.into())
    }

    pub fn unauthorized(msg: impl Into<String>) -> Self {
        Self::Unauthorized(msg.into())
    }

    pub fn business_rule(msg: impl Into<String>) -> Self {
        Self::BusinessRule(msg.into())
    }

    pub fn unavailable(msg: impl Into<String>) -> Self {
        Self::Unavailable(msg.into())
    }

    pub fn internal(msg: impl Into<String>) -> Self {
        Self::Internal(msg.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let trace_id = crate::audit::current_request_id()
            .unwrap_or_else(|| format!("req-{}", uuid::Uuid::new_v4()));
        let timestamp = chrono::Utc::now();

        let (status, code, client_message, details) = match self {
            AppError::Validation(msg, details) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Validation rejection");
                (
                    StatusCode::BAD_REQUEST,
                    "VALIDATION_FAILED".to_string(),
                    msg,
                    details,
                )
            }
            AppError::NotFound(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Resource not found");
                (
                    StatusCode::NOT_FOUND,
                    "RESOURCE_NOT_FOUND".to_string(),
                    msg,
                    None,
                )
            }
            AppError::Conflict(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Conflict rejection");
                (StatusCode::CONFLICT, "CONFLICT".to_string(), msg, None)
            }
            AppError::Unauthorized(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Authentication required");
                (
                    StatusCode::UNAUTHORIZED,
                    "AUTHENTICATION_REQUIRED".to_string(),
                    msg,
                    None,
                )
            }
            AppError::Forbidden(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Permission denied");
                (
                    StatusCode::FORBIDDEN,
                    "PERMISSION_DENIED".to_string(),
                    msg,
                    None,
                )
            }
            AppError::BusinessRule(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Business rule violation");
                (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "BUSINESS_RULE_VIOLATION".to_string(),
                    msg,
                    None,
                )
            }
            AppError::RateLimited => {
                tracing::warn!(trace_id = %trace_id, "Rate limit exceeded");
                (
                    StatusCode::TOO_MANY_REQUESTS,
                    "RATE_LIMITED".to_string(),
                    "Too many authentication attempts. Please wait before retrying.".to_string(),
                    None,
                )
            }
            AppError::Unavailable(msg) => {
                tracing::warn!(trace_id = %trace_id, error = %msg, "Service unavailable");
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "SERVICE_UNAVAILABLE".to_string(),
                    msg,
                    None,
                )
            }
            AppError::Internal(msg) => {
                tracing::error!(trace_id = %trace_id, error = %msg, "Internal server error occurred");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "INTERNAL_SERVER_ERROR".to_string(),
                    "An internal server error occurred.".to_string(),
                    None,
                )
            }
            AppError::Database(err) => {
                tracing::error!(trace_id = %trace_id, error = ?err, "Database persistence error occurred");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "DATABASE_ERROR".to_string(),
                    "A data persistence error occurred.".to_string(),
                    None,
                )
            }
        };

        let body = ErrorEnvelope {
            error: ErrorBody {
                code,
                message: client_message,
                details,
                trace_id: trace_id.clone(),
                timestamp,
            },
        };

        let mut res = (status, Json(body)).into_response();
        if let Ok(value) = axum::http::HeaderValue::from_str(&trace_id) {
            res.headers_mut()
                .insert(axum::http::HeaderName::from_static("x-request-id"), value);
        }
        if status == StatusCode::UNAUTHORIZED {
            res.headers_mut().insert(
                axum::http::header::WWW_AUTHENTICATE,
                axum::http::HeaderValue::from_static("Bearer"),
            );
        }
        if status == StatusCode::TOO_MANY_REQUESTS {
            res.headers_mut().insert(
                axum::http::header::RETRY_AFTER,
                axum::http::HeaderValue::from_static("60"),
            );
        }
        res
    }
}

impl From<crate::authorization::SecurityError> for AppError {
    fn from(err: crate::authorization::SecurityError) -> Self {
        use crate::authorization::SecurityError;
        match err {
            SecurityError::Misconfigured => AppError::Internal(err.to_string()),
            SecurityError::Unauthenticated => AppError::Unauthorized(err.to_string()),
            SecurityError::Forbidden | SecurityError::PasswordChange | SecurityError::StepUp => {
                AppError::Forbidden(err.to_string())
            }
            SecurityError::NotFound => AppError::NotFound(err.to_string()),
            SecurityError::BadRequest => AppError::Validation(err.to_string(), None),
            SecurityError::Unavailable => AppError::Unavailable(err.to_string()),
            SecurityError::Conflict => AppError::Conflict(err.to_string()),
            SecurityError::RateLimited => AppError::RateLimited,
        }
    }
}

impl From<crate::services::finance_common::FinanceError> for AppError {
    fn from(err: crate::services::finance_common::FinanceError) -> Self {
        use crate::services::finance_common::FinanceError;
        match err {
            FinanceError::NotFound(msg) => AppError::NotFound(msg),
            FinanceError::Invalid(msg) => AppError::Validation(msg, None),
            FinanceError::Conflict(msg) => AppError::Conflict(msg),
            FinanceError::Forbidden(msg) => AppError::Forbidden(msg),
            FinanceError::Unavailable(msg) => AppError::Unavailable(msg),
        }
    }
}

impl From<(StatusCode, String)> for AppError {
    fn from((status, msg): (StatusCode, String)) -> Self {
        match status {
            StatusCode::BAD_REQUEST => AppError::Validation(msg, None),
            StatusCode::NOT_FOUND => AppError::NotFound(msg),
            StatusCode::CONFLICT => AppError::Conflict(msg),
            StatusCode::UNAUTHORIZED => AppError::Unauthorized(msg),
            StatusCode::FORBIDDEN => AppError::Forbidden(msg),
            StatusCode::UNPROCESSABLE_ENTITY => AppError::BusinessRule(msg),
            StatusCode::TOO_MANY_REQUESTS => AppError::RateLimited,
            StatusCode::SERVICE_UNAVAILABLE => AppError::Unavailable(msg),
            _ => AppError::Internal(msg),
        }
    }
}

impl From<(StatusCode, &'static str)> for AppError {
    fn from((status, msg): (StatusCode, &'static str)) -> Self {
        AppError::from((status, msg.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_envelope_serializes_cleanly() {
        let err = ErrorEnvelope {
            error: ErrorBody {
                code: "RESOURCE_NOT_FOUND".into(),
                message: "Unit not found".into(),
                details: None,
                trace_id: "req-123".into(),
                timestamp: chrono::Utc::now(),
            },
        };
        let serialized = serde_json::to_string(&err).expect("serialization failed");
        assert!(serialized.contains("RESOURCE_NOT_FOUND"));
        assert!(serialized.contains("Unit not found"));
    }

    #[test]
    fn app_error_from_finance_error() {
        let f_err = crate::services::finance_common::FinanceError::NotFound("Missing unit".into());
        let app_err: AppError = f_err.into();
        match app_err {
            AppError::NotFound(msg) => assert_eq!(msg, "Missing unit"),
            _ => panic!("Expected NotFound variant"),
        }
    }
}
