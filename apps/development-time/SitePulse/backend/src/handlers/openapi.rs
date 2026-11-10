use axum::{
    http::header,
    response::{Html, IntoResponse, Response},
};

pub async fn openapi_spec() -> Response {
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

pub async fn swagger_ui() -> Html<&'static str> {
    Html(crate::openapi::swagger_ui_html())
}

pub async fn scalar_ui() -> Html<&'static str> {
    Html(crate::openapi::scalar_ui_html())
}
