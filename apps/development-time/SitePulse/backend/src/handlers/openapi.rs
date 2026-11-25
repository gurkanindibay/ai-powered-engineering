use axum::{
    extract::State,
    http::{header, StatusCode},
    response::{Html, IntoResponse, Response},
};

use crate::state::AppState;

fn docs_disabled() -> Response {
    StatusCode::NOT_FOUND.into_response()
}

pub async fn openapi_spec(State(state): State<AppState>) -> Response {
    if !state.settings.public_api_docs_enabled {
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

pub async fn swagger_ui(State(state): State<AppState>) -> Response {
    if !state.settings.public_api_docs_enabled {
        return docs_disabled();
    }
    Html(crate::openapi::swagger_ui_html()).into_response()
}

pub async fn scalar_ui(State(state): State<AppState>) -> Response {
    if !state.settings.public_api_docs_enabled {
        return docs_disabled();
    }
    Html(crate::openapi::scalar_ui_html()).into_response()
}
