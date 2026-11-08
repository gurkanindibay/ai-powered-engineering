use axum::http::StatusCode;
use axum::response::IntoResponse;
use sitepulse_backend::error::{AppError, ErrorEnvelope};
use sitepulse_backend::services::finance_common::FinanceError;

#[tokio::test]
async fn app_error_produces_standardized_json_envelope() {
    let err = AppError::validation_with_details(
        "Invalid transfer input",
        serde_json::json!({
            "field_errors": [
                {"field": "amount", "message": "Amount must be greater than zero"}
            ]
        }),
    );

    let response = err.into_response();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let body_bytes = axum::body::to_bytes(response.into_body(), 1024 * 16)
        .await
        .expect("body read failed");
    let envelope: ErrorEnvelope =
        serde_json::from_slice(&body_bytes).expect("deserialization to ErrorEnvelope failed");

    assert_eq!(envelope.error.code, "VALIDATION_FAILED");
    assert_eq!(envelope.error.message, "Invalid transfer input");
    assert!(envelope.error.trace_id.starts_with("req-"));
    assert!(envelope.error.details.is_some());
    let details = envelope.error.details.unwrap();
    assert_eq!(details["field_errors"][0]["field"], "amount");
}

#[tokio::test]
async fn finance_error_maps_cleanly_to_app_error_response() {
    let finance_conflict = FinanceError::Conflict("Period already closed".to_string());
    let app_err: AppError = finance_conflict.into();
    let response = app_err.into_response();

    assert_eq!(response.status(), StatusCode::CONFLICT);

    let body_bytes = axum::body::to_bytes(response.into_body(), 1024 * 16)
        .await
        .expect("body read failed");
    let envelope: ErrorEnvelope =
        serde_json::from_slice(&body_bytes).expect("deserialization to ErrorEnvelope failed");

    assert_eq!(envelope.error.code, "CONFLICT");
    assert_eq!(envelope.error.message, "Period already closed");
    assert!(envelope.error.trace_id.starts_with("req-"));
}

#[tokio::test]
async fn security_error_maps_cleanly_with_trace_id() {
    let sec_err = sitepulse_backend::authorization::SecurityError::Unauthenticated;
    let response = sec_err.into_response();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    assert!(response.headers().contains_key("www-authenticate"));

    let body_bytes = axum::body::to_bytes(response.into_body(), 1024 * 16)
        .await
        .expect("body read failed");
    let envelope: ErrorEnvelope =
        serde_json::from_slice(&body_bytes).expect("deserialization to ErrorEnvelope failed");

    assert_eq!(envelope.error.code, "AUTHENTICATION_REQUIRED");
    assert!(envelope.error.trace_id.starts_with("req-"));
}

#[tokio::test]
async fn response_includes_matching_x_request_id_header() {
    let err = AppError::not_found("Resource missing");
    let response = err.into_response();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    let header_val = response
        .headers()
        .get("x-request-id")
        .expect("x-request-id header must be present")
        .to_str()
        .expect("valid str")
        .to_string();

    let body_bytes = axum::body::to_bytes(response.into_body(), 1024 * 16)
        .await
        .expect("body read failed");
    let envelope: ErrorEnvelope =
        serde_json::from_slice(&body_bytes).expect("deserialization to ErrorEnvelope failed");

    assert_eq!(header_val, envelope.error.trace_id);
}

#[tokio::test]
async fn correlate_middleware_propagates_client_request_id() {
    use axum::http::Request;
    use tower::ServiceExt;

    let app = axum::Router::new()
        .route(
            "/test-error",
            axum::routing::get(|| async { AppError::validation("Client input invalid") }),
        )
        .layer(axum::middleware::from_fn(
            sitepulse_backend::audit::correlate,
        ));

    let req = Request::builder()
        .uri("/test-error")
        .header("x-request-id", "client-trace-12345")
        .body(axum::body::Body::empty())
        .unwrap();

    let response = app.oneshot(req).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let header_val = response
        .headers()
        .get("x-request-id")
        .expect("x-request-id header must be present")
        .to_str()
        .unwrap()
        .to_string();
    assert_eq!(header_val, "client-trace-12345");

    let body_bytes = axum::body::to_bytes(response.into_body(), 1024 * 16)
        .await
        .unwrap();
    let envelope: ErrorEnvelope = serde_json::from_slice(&body_bytes).unwrap();
    assert_eq!(envelope.error.trace_id, "client-trace-12345");
}
