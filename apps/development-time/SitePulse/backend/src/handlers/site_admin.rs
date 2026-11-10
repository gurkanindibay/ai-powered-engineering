//! Site administration and unit management route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::authorization::{AuthzContext, SecurityError};
use crate::error::AppError;
use crate::models::Permission;
use crate::models::{
    BlockDto, CreateBlockRequest, CreateHouseTypeRequest, HomeOwnerResponse, HouseTypeTariff,
    MoveInResidentRequest, MoveOutResidentRequest, OccupancyHistoryItem, RegisterHomeOwnerRequest,
    UpdateHomeOwnerRequest,
};
use crate::services::account_activation_service::{ActivationDelivery, ActivationError};
use crate::services::person_directory_service::{
    DirectoryPage, DirectoryQuery, PersonDirectoryError, PersonDirectoryService, PersonProfile,
};
use crate::services::person_import_service::{
    ImportReport, ImportRequest, PersonImportError, PersonImportService,
};
use crate::services::person_record_service::{
    ContactPreferences, DuplicateCandidate, DuplicateQuery, PersonRecordError, PersonRecordService,
    SetNationalIdRequest,
};
use crate::services::site_admin_service as service;
use crate::services::AccountActivationService;
use crate::services::SiteAdminService;
use crate::state::AppState;
use axum::response::{IntoResponse, Response};

#[derive(Deserialize, Default)]
pub struct SiteIdParam {
    pub site_id: Option<String>,
}

/// Map a person-module service failure to the standard error envelope (S10):
/// storage and driver failures become a generic 500 with a trace id, never raw text.
pub(crate) fn person_error(e: String) -> AppError {
    const INTERNAL_MARKERS: [&str; 8] = [
        "db error",
        "DB ",
        "Database",
        "Failed to",
        "Transaction",
        "Activation storage",
        "connection",
        "error communicating",
    ];
    if e == service::UNIT_NOT_FOUND || e == service::PERSON_NOT_FOUND {
        AppError::not_found(e)
    } else if e == service::EMAIL_NOT_AVAILABLE || e == service::UNIT_HAS_FINANCIAL_HISTORY {
        AppError::conflict(e)
    } else if e == "Household storage unavailable" {
        AppError::unavailable(e)
    } else if INTERNAL_MARKERS.iter().any(|m| e.contains(m)) {
        AppError::internal(e)
    } else {
        AppError::validation(e)
    }
}

/// Map an activation failure to the standard error envelope.
pub(crate) fn activation_error(e: ActivationError) -> AppError {
    match e {
        ActivationError::InvalidToken | ActivationError::Password(_) => {
            AppError::validation(e.to_string())
        }
        ActivationError::UnitNotFound | ActivationError::NoLoginAccount => {
            AppError::not_found(e.to_string())
        }
        ActivationError::AlreadyActive => AppError::conflict(e.to_string()),
        ActivationError::Storage(_) => AppError::internal(e.to_string()),
    }
}

pub async fn register_home_owner(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(person_error)
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HomeOwnerResponse>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_home_owners_for_site(&site_id).await)
}

pub async fn update_home_owner(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateHomeOwnerRequest>,
) -> Response {
    let site_id = q.site_id.unwrap_or_default();
    // Contact edits need PersonManage (the route); a login email change is an identity
    // change and also needs PersonIdentityManage and a recent step-up.
    let may_change_identity = ctx.permissions.contains(&Permission::PersonIdentityManage);
    let result = SiteAdminService::new(state)
        .update_home_owner(
            &site_id,
            &id,
            payload,
            may_change_identity && ctx.stepped_up,
        )
        .await;
    match result {
        Ok(updated) => Json(updated).into_response(),
        Err(e) if e == service::LOGIN_CHANGE_NEEDS_STEP_UP && may_change_identity => {
            SecurityError::StepUp.into_response()
        }
        Err(e) if e == service::LOGIN_CHANGE_NEEDS_STEP_UP => {
            SecurityError::Forbidden.into_response()
        }
        Err(e) => person_error(e).into_response(),
    }
}

pub async fn delete_home_owner(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_home_owner(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(person_error)
}

/// The security boundary adds the caller's `site_id` to JSON bodies, so unknown
/// fields are tolerated here; only `role` is read.
#[derive(Deserialize)]
pub struct ResendActivationRequest {
    /// `OWNER` (default) or `TENANT`.
    #[serde(default)]
    pub role: Option<String>,
}

/// Send a fresh activation link to a unit's owner or tenant; older links stop working.
pub async fn resend_activation(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ResendActivationRequest>,
) -> Result<Json<ActivationDelivery>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let tenant = payload
        .role
        .as_deref()
        .is_some_and(|r| r.eq_ignore_ascii_case("TENANT"));
    AccountActivationService::new(state)
        .resend_for_unit(&site_id, &id, tenant)
        .await
        .map(Json)
        .map_err(activation_error)
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveOutResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_out_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(person_error)
}

pub async fn move_in_resident(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveInResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .move_in_resident(&site_id, &id, payload)
        .await
        .map(Json)
        .map_err(person_error)
}

pub async fn get_unit_occupancy_history(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<OccupancyHistoryItem>>, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .get_unit_occupancy_history(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_house_types(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<HouseTypeTariff>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_house_types_for_site(&site_id).await)
}

pub async fn create_house_type(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<HouseTypeTariff>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_house_type(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_house_type(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .delete_house_type(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_blocks(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
) -> Json<Vec<BlockDto>> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    Json(service.get_blocks_for_site(&site_id).await)
}

pub async fn create_block(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateBlockRequest>,
) -> Result<(StatusCode, Json<BlockDto>), (StatusCode, String)> {
    let site_id = q.site_id.unwrap_or_default();
    let service = SiteAdminService::new(state);
    service
        .create_or_update_block(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

fn directory_error(e: PersonDirectoryError) -> AppError {
    match e {
        PersonDirectoryError::NotFound => AppError::not_found(e.to_string()),
        PersonDirectoryError::InvalidFilter(_) => AppError::validation(e.to_string()),
        PersonDirectoryError::Storage(_) => AppError::internal(e.to_string()),
    }
}

/// The site's people with search, role and login filters and paging (person F1/U4).
pub async fn list_persons(
    State(state): State<AppState>,
    Query(q): Query<DirectoryQuery>,
) -> Result<Json<DirectoryPage>, AppError> {
    let site_id = q.site_id.clone().unwrap_or_default();
    PersonDirectoryService::new(state)
        .directory(&site_id, &q)
        .await
        .map(Json)
        .map_err(directory_error)
}

/// One person with every unit they own, rent or live in, over time (person U3).
pub async fn get_person_profile(
    State(state): State<AppState>,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<PersonProfile>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let id = crate::db::parse_id_to_i64(&person_id)
        .ok_or_else(|| AppError::not_found("Person not found"))?;
    PersonDirectoryService::new(state)
        .profile(&site_id, id)
        .await
        .map(Json)
        .map_err(directory_error)
}

/// The filtered directory as CSV; needs step-up and is written to the audit log (person F8).
pub async fn export_persons(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<DirectoryQuery>,
) -> Result<Response, AppError> {
    let site_id = q.site_id.clone().unwrap_or_default();
    let directory = PersonDirectoryService::new(state);
    let (csv, rows) = directory
        .export_csv(&site_id, &q)
        .await
        .map_err(directory_error)?;
    directory
        .record_export(&ctx, &site_id, rows)
        .await
        .map_err(directory_error)?;
    tracing::info!(actor_id = %ctx.claims.sub, rows, "Person directory exported");
    Ok((
        [
            (
                axum::http::header::CONTENT_TYPE,
                "text/csv; charset=utf-8".to_string(),
            ),
            (
                axum::http::header::CONTENT_DISPOSITION,
                "attachment; filename=\"sakinler.csv\"".to_string(),
            ),
        ],
        csv,
    )
        .into_response())
}

fn record_error(e: PersonRecordError) -> AppError {
    match e {
        PersonRecordError::NotFound => AppError::not_found("Kişi bulunamadı."),
        PersonRecordError::InvalidNationalId => {
            AppError::validation("Geçerli bir T.C. kimlik numarası giriniz (11 hane).")
        }
        PersonRecordError::NationalIdInUse => {
            AppError::conflict("Bu kimlik numarası sitede başka bir kişiye kayıtlı.")
        }
        PersonRecordError::InvalidPreference(field) => AppError::validation(match field {
            "preferred_channel" => "Geçersiz iletişim kanalı.",
            "preferred_language" => "Geçersiz dil.",
            "emergency_contact" => "Acil durum kişisinin adı ve telefonu birlikte girilmelidir.",
            "emergency_contact_phone" => "Acil durum telefonu geçerli değil.",
            _ => "Acil durum kişisinin adı çok uzun.",
        }),
        PersonRecordError::Unavailable => AppError::unavailable(e.to_string()),
        PersonRecordError::Storage(_) => AppError::internal(e.to_string()),
    }
}

fn person_id_of(raw: &str) -> Result<i64, AppError> {
    crate::db::parse_id_to_i64(raw).ok_or_else(|| AppError::not_found("Kişi bulunamadı."))
}

/// Records or clears a person's national ID (person F10). The route needs
/// `PersonIdentityManage` and a recent step-up; the action is audited.
pub async fn set_person_national_id(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<SetNationalIdRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let id = person_id_of(&person_id)?;
    let masked = PersonRecordService::new(state)
        .set_national_id(&ctx, &site_id, id, payload.national_id.as_deref())
        .await
        .map_err(record_error)?;
    Ok(Json(serde_json::json!({ "national_id_masked": masked })))
}

/// Saves a person's preferred channel, language and emergency contact (person F7).
pub async fn update_person_preferences(
    State(state): State<AppState>,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ContactPreferences>,
) -> Result<Json<ContactPreferences>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    let id = person_id_of(&person_id)?;
    PersonRecordService::new(state)
        .update_preferences(&site_id, id, payload)
        .await
        .map(Json)
        .map_err(record_error)
}

/// People of the site who may be the one being entered (person F9). A POST, so a
/// national ID never appears in a URL or an access log.
pub async fn check_person_duplicates(
    State(state): State<AppState>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<DuplicateQuery>,
) -> Result<Json<Vec<DuplicateCandidate>>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    PersonRecordService::new(state)
        .duplicates(&site_id, &payload)
        .await
        .map(Json)
        .map_err(record_error)
}

fn import_error(e: PersonImportError) -> AppError {
    match e {
        PersonImportError::Storage(_) => AppError::internal(e.to_string()),
        PersonImportError::Empty => {
            AppError::validation("Dosyada başlık satırından sonra kayıt yok.")
        }
        PersonImportError::TooManyRows => {
            AppError::validation("Bir dosyada en fazla 500 satır olabilir.")
        }
        PersonImportError::TooLarge => AppError::validation("Dosya 1 MB'tan büyük olamaz."),
        PersonImportError::MissingColumns(columns) => {
            AppError::validation(format!("Eksik sütunlar: {columns}. Şablonu kullanın."))
        }
        PersonImportError::UnterminatedQuote(line) => {
            AppError::validation(format!("{line}. satırda kapanmamış tırnak var."))
        }
    }
}

/// Checks a CSV of owners and, unless `dry_run`, registers them when no row has an
/// error (person F8).
pub async fn import_persons(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ImportRequest>,
) -> Result<Json<ImportReport>, AppError> {
    let site_id = q.site_id.unwrap_or_default();
    PersonImportService::new(state)
        .import(&ctx, &site_id, &payload.csv, payload.dry_run)
        .await
        .map(Json)
        .map_err(import_error)
}
