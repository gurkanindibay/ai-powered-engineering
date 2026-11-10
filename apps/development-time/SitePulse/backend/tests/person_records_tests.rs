//! Person module F7/F8/F9/F10: CSV import, duplicate detection and the routes that
//! guard national IDs and contact preferences.
mod support;
use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use sitepulse_backend::app::build_router;
use sitepulse_backend::models::*;
use sitepulse_backend::services::person_import_service::PersonImportService;
use sitepulse_backend::services::person_record_service::{
    DuplicateQuery, DuplicateReason, PersonRecordService,
};
use sitepulse_backend::state::AppState;
use tower::ServiceExt;

const SITE: &str = "site-1";
const HEADER: &str = "block,unit_no,floor,owner_full_name,owner_email,owner_phone,land_share,monthly_dues,is_resident,tenant_full_name,tenant_email,tenant_phone";

fn manager() -> sitepulse_backend::authorization::AuthzContext {
    let token =
        sitepulse_backend::auth::issue_token("usr-import", "", Role::SiteManager, SITE, None)
            .unwrap();
    let claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    sitepulse_backend::authorization::AuthzContext {
        claims,
        permissions: Permission::permissions_for_role(Role::SiteManager),
        request_id: "person-import".to_string(),
        stepped_up: false,
    }
}

fn file() -> String {
    format!(
        "{HEADER}\n\
         Z Blok,901,9,Deniz Arslan,deniz.import@example.com,0532 700 10 01,12,1500,evet,,,\n\
         Z Blok,902,9,Ece Kara,ece.import@example.com,0532 700 10 02,,,hayır,Can Kiracı,can.import@example.com,0532 700 10 03\n"
    )
}

#[tokio::test]
async fn a_dry_run_checks_every_row_and_changes_nothing() {
    let state = AppState::new_with_test_fixtures();
    let before = state.inner.read().await.users.len();
    let report = PersonImportService::new(state.clone())
        .import(&manager(), SITE, &file(), true)
        .await
        .unwrap();
    assert_eq!((report.total, report.invalid, report.created), (2, 0, 0));
    assert!(report.dry_run && !report.committed);
    assert_eq!(state.inner.read().await.users.len(), before);
}

#[tokio::test]
async fn a_commit_registers_the_rows_and_a_second_import_is_refused_row_by_row() {
    let state = AppState::new_with_test_fixtures();
    let service = PersonImportService::new(state.clone());
    let report = service
        .import(&manager(), SITE, &file(), false)
        .await
        .unwrap();
    assert!(report.committed, "{:?}", report.rows);
    assert_eq!(report.created, 2);
    assert!(report.rows.iter().all(|r| r.unit_id.is_some()));
    assert_eq!(report.rows[0].activation.as_deref(), Some("SENT"));

    let again = service
        .import(&manager(), SITE, &file(), false)
        .await
        .unwrap();
    assert!(!again.committed);
    assert_eq!((again.invalid, again.created), (2, 0));
    let errors = &again.rows[0].errors;
    assert!(
        errors.iter().any(|e| e.contains("zaten kayıtlı")),
        "{errors:?}"
    );
    assert!(
        errors.iter().any(|e| e.contains("başka bir hesapta")),
        "{errors:?}"
    );
}

#[tokio::test]
async fn one_bad_row_blocks_the_whole_commit() {
    let state = AppState::new_with_test_fixtures();
    let before = state.inner.read().await.users.len();
    let bad = format!("{}Z Blok,903,9,,x,1,,,evet,,,\n", file());
    let report = PersonImportService::new(state.clone())
        .import(&manager(), SITE, &bad, false)
        .await
        .unwrap();
    assert!(!report.committed);
    assert_eq!((report.invalid, report.created), (1, 0));
    assert_eq!(report.rows[2].line, 4);
    assert_eq!(state.inner.read().await.users.len(), before);
}

#[tokio::test]
async fn duplicates_are_found_by_phone_email_and_name() {
    let state = AppState::new_with_test_fixtures();
    PersonImportService::new(state.clone())
        .import(&manager(), SITE, &file(), false)
        .await
        .unwrap();
    let records = PersonRecordService::new(state);
    let found = records
        .duplicates(
            SITE,
            &DuplicateQuery {
                full_name: Some("ARSLAN deniz".into()),
                phone: Some("+905327001001".into()),
                ..DuplicateQuery::default()
            },
        )
        .await
        .unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].person.full_name, "Deniz Arslan");
    assert_eq!(
        found[0].reasons,
        vec![DuplicateReason::SamePhone, DuplicateReason::SimilarName]
    );
    let other_site = records
        .duplicates(
            "site-2",
            &DuplicateQuery {
                phone: Some("05327001001".into()),
                ..DuplicateQuery::default()
            },
        )
        .await
        .unwrap();
    assert!(other_site.is_empty(), "another site's people never match");
}

async fn send(
    state: &AppState,
    method: &str,
    path: &str,
    token: &str,
    body: serde_json::Value,
) -> (StatusCode, String) {
    let response = build_router(state.clone())
        .oneshot(
            Request::builder()
                .method(method)
                .uri(path)
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), 1 << 20)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&bytes).into_owned())
}

#[tokio::test]
async fn a_national_id_change_needs_identity_rights_and_a_step_up() {
    let state = AppState::new_with_test_fixtures();
    let path = "/api/v1/site-admin/persons/1/national-id";
    let body = serde_json::json!({"national_id": "10000000146"});

    let owner = support::token(&state, "owner-f10", Role::HomeOwner, SITE, Some("d-14")).await;
    assert_eq!(
        send(&state, "PUT", path, &owner, body.clone()).await.0,
        StatusCode::FORBIDDEN
    );

    let manager = support::token(&state, "manager-f10", Role::SiteManager, SITE, None).await;
    let (status, text) = send(&state, "PUT", path, &manager, body).await;
    assert!(text.contains("STEP_UP_REQUIRED"), "{status} {text}");
}

#[tokio::test]
async fn residents_cannot_import_people_or_edit_preferences() {
    let state = AppState::new_with_test_fixtures();
    let resident = support::token(
        &state,
        "resident-f8",
        Role::HomeResident,
        SITE,
        Some("d-14"),
    )
    .await;
    let (import, _) = send(
        &state,
        "POST",
        "/api/v1/site-admin/persons/import",
        &resident,
        serde_json::json!({"csv": file(), "dry_run": true}),
    )
    .await;
    assert_eq!(import, StatusCode::FORBIDDEN);
    let (prefs, _) = send(
        &state,
        "PUT",
        "/api/v1/site-admin/persons/1/preferences",
        &resident,
        serde_json::json!({"preferred_channel": "SMS", "preferred_language": "tr"}),
    )
    .await;
    assert_eq!(prefs, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_import_route_answers_a_manager_with_a_report() {
    let state = AppState::new_with_test_fixtures();
    let manager = support::token(&state, "manager-f8", Role::SiteManager, SITE, None).await;
    let (status, text) = send(
        &state,
        "POST",
        "/api/v1/site-admin/persons/import",
        &manager,
        serde_json::json!({"csv": "block,unit_no\nA,1\n", "dry_run": true}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{text}");
    assert!(text.contains("owner_full_name"), "{text}");
}
