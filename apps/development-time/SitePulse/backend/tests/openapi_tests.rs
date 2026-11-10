use axum::body::Body;
use axum::http::{Request, StatusCode};
use sitepulse_backend::app::build_router;
use sitepulse_backend::state::AppState;
use tower::ServiceExt;

#[tokio::test]
async fn when_openapi_json_is_requested_then_valid_spec_is_returned() {
    let state = AppState::new();
    let app = build_router(state);

    let response = app
        .oneshot(
            Request::builder()
                .uri("/api-docs/openapi.json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok()),
        Some("application/json")
    );

    let body = axum::body::to_bytes(response.into_body(), 10 * 1024 * 1024)
        .await
        .unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["openapi"], "3.1.0");
    assert_eq!(
        json["info"]["title"],
        "SitePulse Residential Management Platform API"
    );
    assert!(json["paths"].as_object().unwrap().len() > 50);
    assert!(json["components"]["securitySchemes"]["bearerAuth"].is_object());
    assert!(json["components"]["schemas"]["ErrorEnvelope"].is_object());
}

#[tokio::test]
async fn when_openapi_aliases_are_requested_then_same_spec_is_returned() {
    let state = AppState::new();
    let app = build_router(state.clone());

    let res_v1 = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/v1/openapi.json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res_v1.status(), StatusCode::OK);

    let res_root = build_router(state)
        .oneshot(
            Request::builder()
                .uri("/openapi.json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res_root.status(), StatusCode::OK);
}

#[tokio::test]
async fn when_swagger_ui_is_requested_then_interactive_html_page_is_returned() {
    let state = AppState::new();
    let app = build_router(state);

    let response = app
        .oneshot(
            Request::builder()
                .uri("/swagger-ui")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert!(response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap()
        .contains("text/html"));

    let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    let html = String::from_utf8(body.to_vec()).unwrap();
    assert!(html.contains("SwaggerUIBundle"));
    assert!(html.contains("/api-docs/openapi.json"));
}

#[tokio::test]
async fn when_scalar_is_requested_then_scalar_html_page_is_returned() {
    let state = AppState::new();
    let app = build_router(state);

    let response = app
        .oneshot(
            Request::builder()
                .uri("/scalar")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = axum::body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .unwrap();
    let html = String::from_utf8(body.to_vec()).unwrap();
    assert!(html.contains("@scalar/api-reference"));
    assert!(html.contains("/api-docs/openapi.json"));
}

#[test]
fn when_spec_is_generated_then_all_registered_routes_are_covered() {
    let spec = sitepulse_backend::openapi::build_openapi_spec();
    let paths = spec["paths"].as_object().unwrap();

    for route in sitepulse_backend::app::ROUTES {
        let openapi_path = route
            .path
            .split('/')
            .map(|s| {
                if let Some(param) = s.strip_prefix(':') {
                    format!("{{{}}}", param)
                } else {
                    s.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("/");

        assert!(
            paths.contains_key(&openapi_path),
            "OpenAPI paths missing registered route: {} (converted: {})",
            route.path,
            openapi_path
        );

        let path_obj = paths.get(&openapi_path).unwrap();
        let method = route.method.to_ascii_lowercase();
        assert!(
            path_obj.get(&method).is_some(),
            "Path {} missing HTTP method {}",
            openapi_path,
            method
        );
    }
}
