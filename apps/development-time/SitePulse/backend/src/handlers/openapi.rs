use axum::{
    http::{header, StatusCode},
    response::{Html, IntoResponse, Response},
};

/// API documentation is public in development; production needs an explicit opt-in.
fn docs_enabled() -> bool {
    !crate::state::AppStateInner::is_production()
        || std::env::var("SITEPULSE_ENABLE_API_DOCS").is_ok_and(|v| v == "true")
}

fn docs_disabled() -> Response {
    StatusCode::NOT_FOUND.into_response()
}

pub async fn openapi_spec() -> Response {
    if !docs_enabled() {
        return docs_disabled();
    }
    let spec = crate::openapi::get_openapi_spec_json();
    (
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "public, max-age=300"),
        ],
        spec,
    )
        .into_response()
}

pub async fn swagger_ui() -> Response {
    if !docs_enabled() {
        return docs_disabled();
    }
    Html(crate::openapi::swagger_ui_html()).into_response()
}

pub async fn scalar_ui() -> Response {
    if !docs_enabled() {
        return docs_disabled();
    }
    Html(crate::openapi::scalar_ui_html()).into_response()
}
