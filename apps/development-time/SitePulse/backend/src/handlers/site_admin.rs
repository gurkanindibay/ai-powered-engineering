//! Site administration and unit management route handlers.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use serde::Deserialize;

use crate::authorization::{AuthzContext, SecurityError};
use crate::db::occupancy_repository::OccupancyError;
use crate::domain::unit_state::CommandKind;
use crate::error::AppError;
use crate::models::Permission;
use crate::models::{
    BlockDto, CreateBlockRequest, CreateHouseTypeRequest, CreateUnitsRequest, HomeOwnerResponse,
    HouseTypeTariff, MoveInResidentRequest, MoveOutResidentRequest, OccupancyHistoryItem,
    OccupancyTransitionRequest, OccupancyTransitionResponse, ProrationPolicyRequest,
    ProrationPolicyResponse, RegisterHomeOwnerRequest, UnitDto, UnitOccupancyStateResponse,
    UpdateHomeOwnerRequest,
};
use crate::services::account_activation_service::{ActivationDelivery, ActivationError};
use crate::services::finance_common::{Caller, FinanceError};
use crate::services::occupancy_service::OccupancyService;
use crate::services::person_directory_service::{
    DirectoryPage, DirectoryQuery, PersonDirectoryError, PersonDirectoryService, PersonProfile,
};
use crate::services::person_import_service::{
    ImportReport, ImportRequest, PersonImportError, PersonImportService,
};
use crate::services::person_merge_service::{
    MergePersonRequest, PersonMergeError, PersonMergeService,
};
use crate::services::person_record_service::{
    ContactPreferences, DuplicateCandidate, DuplicateQuery, PersonRecordError, PersonRecordService,
    SetNationalIdRequest,
};
use crate::services::site_admin_service as service;
use crate::services::supplementary_charge_service::SupplementaryChargeService;
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
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<RegisterHomeOwnerRequest>,
) -> Result<(StatusCode, Json<HomeOwnerResponse>), AppError> {
    let site_id = scope.pinned(q.site_id)?;
    preflight_person_refs(&state, &site_id, &payload).await?;
    let service = SiteAdminService::new(state);
    service
        .register_home_owner(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(person_error)
}

/// Rejects unusable person references with their coded errors (duplicates, taken
/// identity) before the registration transaction resolves them for real.
async fn preflight_person_refs(
    state: &AppState,
    site_id: &str,
    payload: &RegisterHomeOwnerRequest,
) -> Result<(), AppError> {
    let references: Vec<&crate::models::PersonRef> = payload
        .owner
        .iter()
        .chain(payload.tenant.iter())
        .chain(payload.members.iter().map(|m| &m.person))
        .collect();
    if references.is_empty() || state.pool.is_none() {
        return Ok(());
    }
    let site = site_number(site_id)?;
    let people = crate::services::person_service::PersonService::new(state);
    for reference in references {
        people
            .preflight(site, reference)
            .await
            .map_err(person_api_error)?;
    }
    Ok(())
}

pub async fn get_home_owners(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<HomeOwnerResponse>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_home_owners_for_site(&site_id).await))
}

pub async fn update_home_owner(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<UpdateHomeOwnerRequest>,
) -> Response {
    // The site comes from the token: a foreign site_id is refused.
    let site_id = match crate::tenancy::TenantScope::from_claims(&ctx.claims).pinned(q.site_id) {
        Ok(site) => site,
        Err(denied) => return denied.into_response(),
    };
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
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, AppError> {
    let site_id = scope.pinned(q.site_id)?;
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
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ResendActivationRequest>,
) -> Result<Json<ActivationDelivery>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
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

/// Maps a refused or failed transition to the error envelope: an illegal
/// command for the unit's state is a 409, invalid input a 400.
pub(crate) fn occupancy_error(e: OccupancyError) -> AppError {
    use crate::domain::unit_state::TransitionError;
    match e {
        OccupancyError::UnitNotFound => AppError::not_found(service::UNIT_NOT_FOUND),
        OccupancyError::PersonNotFound => AppError::not_found(service::PERSON_NOT_FOUND),
        OccupancyError::Rule(
            rule @ (TransitionError::IllegalCommand { .. }
            | TransitionError::OwnerRequired
            | TransitionError::MoveInAtTransferNotAllowed),
        ) => AppError::conflict(rule.to_string()),
        OccupancyError::Person(error) => person_api_error(error),
        OccupancyError::Storage(detail) => {
            tracing::error!(error = %detail, "Occupancy transition storage failure");
            AppError::internal("Occupancy storage failure")
        }
        other => AppError::validation(other.to_string()),
    }
}

pub async fn move_out_resident(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveOutResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    if state.pool.is_none() {
        return SiteAdminService::new(state)
            .move_out_resident(&site_id, &id, payload)
            .await
            .map(Json)
            .map_err(person_error);
    }
    let request = OccupancyTransitionRequest {
        person: None,
        command: CommandKind::MoveOut,
        effective_date: service::parse_effective_date(payload.end_date.as_deref())
            .map_err(occupancy_error)?,
        person_id: None,
        full_name: None,
        phone: None,
        email: None,
        owner_person_id: None,
        notes: payload.notes,
    };
    OccupancyService::new(state)
        .transition(&site_id, &id, request)
        .await
        .map_err(occupancy_error)?
        .closed
        .map(Json)
        .ok_or_else(|| AppError::internal("Move-out closed no occupancy"))
}

pub async fn move_in_resident(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MoveInResidentRequest>,
) -> Result<Json<OccupancyHistoryItem>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let request = service::move_in_request(payload).map_err(occupancy_error)?;
    OccupancyService::new(state)
        .transition(&site_id, &id, request)
        .await
        .map_err(occupancy_error)?
        .opened
        .map(Json)
        .ok_or_else(|| AppError::internal("Move-in opened no occupancy"))
}

/// Any guarded occupancy command, including the compound moves C1-C3.
pub async fn apply_occupancy_transition(
    State(state): State<AppState>,
    ctx: AuthzContext,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(mut payload): Json<OccupancyTransitionRequest>,
) -> Result<Json<OccupancyTransitionResponse>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let accrued_on = {
        let inner = state.inner.read().await;
        let timezone = inner
            .sites
            .iter()
            .find(|site| crate::auth::same_id(&site.id, &site_id))
            .map(|site| site.timezone.as_str())
            .unwrap_or("Europe/Istanbul");
        payload
            .effective_date
            .unwrap_or_else(|| crate::scheduler::site_local_date(timezone, chrono::Utc::now()))
    };
    payload.effective_date = Some(accrued_on);
    let service = OccupancyService::new(state.clone());
    if matches!(
        payload.command,
        CommandKind::TenantMoveIn
            | CommandKind::OwnerMoveIn
            | CommandKind::ReplaceTenant
            | CommandKind::OwnerRentsOut
            | CommandKind::OwnerTakesBack
    ) {
        // Refuse before the transition commits: a failure after it would report an error for
        // a move that happened and lose the charges (a retry finds the session already open).
        let today = service.site_today(&site_id).await;
        SupplementaryChargeService::new(state.clone())
            .check_postable(&site_id, &id, accrued_on, today)
            .await
            .map_err(correction_error)?;
    }
    let mut response = service
        .transition(&site_id, &id, payload)
        .await
        .map_err(occupancy_error)?;
    if let Some(opened) = response.opened.clone() {
        let today = service.site_today(&site_id).await;
        response.supplementary_charges = SupplementaryChargeService::new(state.clone())
            .post_for_opened_session(&site_id, &opened, today)
            .await
            .map_err(correction_error)?;
    }
    if let Some(correction) = service
        .request_open_period_split(&Caller::from_claims(&ctx.claims), &id, accrued_on)
        .await
        .map_err(correction_error)?
    {
        response.correction_requests.push(correction);
    }
    Ok(Json(response))
}

/// Sets the per-site opt-in for occupancy-aware dues proration.
pub async fn get_proration_policy(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<ProrationPolicyResponse>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let inner = state.inner.read().await;
    let site = inner
        .sites
        .iter()
        .find(|site| crate::auth::same_id(&site.id, &site_id))
        .ok_or_else(|| AppError::not_found(format!("Site {} not found", site_id)))?;
    Ok(Json(ProrationPolicyResponse {
        site_id,
        proration_enabled: site.proration_enabled,
    }))
}

/// Sets the per-site opt-in for occupancy-aware dues proration.
pub async fn set_proration_policy(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ProrationPolicyRequest>,
) -> Result<Json<ProrationPolicyResponse>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    OccupancyService::new(state)
        .set_proration_policy(&site_id, payload.proration_enabled)
        .await
        .map_err(occupancy_error)?;
    Ok(Json(ProrationPolicyResponse {
        site_id,
        proration_enabled: payload.proration_enabled,
    }))
}

fn correction_error(error: FinanceError) -> AppError {
    match error {
        FinanceError::NotFound(message) => AppError::not_found(message),
        FinanceError::Invalid(message) => AppError::validation(message),
        FinanceError::Conflict(message) => AppError::conflict(message),
        FinanceError::Forbidden(message) => AppError::forbidden(message),
        FinanceError::Unavailable(message) => AppError::unavailable(message),
    }
}

/// The unit's ownership, occupancy, owners on record and legal commands.
pub async fn get_unit_occupancy_state(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<UnitOccupancyStateResponse>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    OccupancyService::new(state)
        .unit_state(&site_id, &id)
        .await
        .map(Json)
        .map_err(occupancy_error)
}

pub async fn get_unit_occupancy_history(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<OccupancyHistoryItem>>, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .get_unit_occupancy_history(&site_id, &id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_house_types(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<HouseTypeTariff>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_house_types_for_site(&site_id).await))
}

pub async fn create_house_type(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateHouseTypeRequest>,
) -> Result<(StatusCode, Json<HouseTypeTariff>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .create_or_update_house_type(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn delete_house_type(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .delete_house_type(&site_id, &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_blocks(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<BlockDto>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_blocks_for_site(&site_id).await))
}

pub async fn create_block(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateBlockRequest>,
) -> Result<(StatusCode, Json<BlockDto>), (StatusCode, String)> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    service
        .create_or_update_block(&site_id, payload)
        .await
        .map(|res| (StatusCode::CREATED, Json(res)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn get_units(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<UnitDto>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    Ok(Json(service.get_units_for_site(&site_id, None).await))
}

pub async fn create_units(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<CreateUnitsRequest>,
) -> Result<(StatusCode, Json<Vec<UnitDto>>), AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let service = SiteAdminService::new(state);
    let res = service.create_units(&site_id, payload).await?;
    Ok((StatusCode::CREATED, Json(res)))
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
    scope: crate::tenancy::TenantScope,
    Query(q): Query<DirectoryQuery>,
) -> Result<Json<DirectoryPage>, AppError> {
    let site_id = scope.pinned(q.site_id.clone())?;
    PersonDirectoryService::new(state)
        .directory(&site_id, &q)
        .await
        .map(Json)
        .map_err(directory_error)
}

/// One person with every unit they own, rent or live in, over time (person U3).
pub async fn get_person_profile(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<PersonProfile>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
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
    let scope = crate::tenancy::TenantScope::from_claims(&ctx.claims);
    let site_id = scope.pinned(q.site_id.clone())?;
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
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<ContactPreferences>,
) -> Result<Json<ContactPreferences>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
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
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<DuplicateQuery>,
) -> Result<Json<Vec<DuplicateCandidate>>, AppError> {
    let site_id = scope.pinned(q.site_id)?;
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

/// Change only the selected unit communication contact.
pub async fn select_responsible_contact(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(request): Json<crate::models::SelectResponsibleContactRequest>,
) -> Response {
    let site = match scope.pinned(q.site_id) {
        Ok(site) => site,
        Err(error) => return error.into_response(),
    };
    match crate::services::responsible_contact_service::select(state, &site, &id, request).await {
        Ok(contact) => Json(contact).into_response(),
        Err(error) => {
            use crate::services::responsible_contact_service::ResponsibleContactError;
            match error {
                ResponsibleContactError::NotFound => AppError::not_found(error.to_string()),
                ResponsibleContactError::InvalidSelection => {
                    AppError::validation(error.to_string())
                }
                ResponsibleContactError::Storage => AppError::unavailable(error.to_string()),
            }
            .into_response()
        }
    }
}

// ---------------------------------------------------------------------------
// Unified person API (task-33): scoped search, role-free create, card, edit.
// ---------------------------------------------------------------------------

/// Query for person routes: the unified-API search fields plus the pinned site.
///
/// The fields are declared inline rather than through `#[serde(flatten)]`:
/// flattening makes `serde_urlencoded` buffer every value as a string, so
/// numeric fields such as `page=1` fail with "expected i64".
#[derive(Debug, Deserialize)]
pub struct PersonSearchParams {
    #[serde(default)]
    pub q: Option<String>,
    #[serde(default)]
    pub context: Option<crate::models::PersonSearchContext>,
    #[serde(default)]
    pub unit_id: Option<String>,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub page: Option<i64>,
    #[serde(default)]
    pub site_id: Option<String>,
}

impl PersonSearchParams {
    /// Splits the query into the pinned site and the service search query.
    pub fn into_parts(self) -> (Option<String>, crate::models::PersonSearchQuery) {
        let search = crate::models::PersonSearchQuery {
            q: self.q,
            context: self.context,
            unit_id: self.unit_id,
            limit: self.limit,
            page: self.page,
        };
        (self.site_id, search)
    }
}

pub(crate) fn person_api_error(e: crate::services::person_service::PersonApiError) -> AppError {
    use crate::services::person_service::PersonApiError as E;
    match e {
        E::NotFound => AppError::not_found("Person not found"),
        E::Validation(msg) => AppError::validation(msg),
        E::StaleVersion => AppError::coded_conflict(
            "PERSON_VERSION_CONFLICT",
            "The person card changed since it was loaded. Reload and retry.",
            serde_json::json!({ "overridable": false }),
        ),
        E::LoginAlreadyActive => AppError::coded_conflict(
            "PERSON_LOGIN_ALREADY_ACTIVE",
            "The person already has an active login.",
            serde_json::json!({ "overridable": false }),
        ),
        E::NoLogin => AppError::not_found("The person has no login to remove"),
        E::IdentityTaken(person_id) => AppError::coded_conflict(
            "PERSON_IDENTITY_TAKEN",
            "This person is already recorded in the site.",
            serde_json::json!({ "overridable": false, "person_id": person_id }),
        ),
        E::PossibleDuplicate(found) => AppError::coded_conflict(
            "PERSON_POSSIBLE_DUPLICATE",
            "A similar person already exists in the site.",
            serde_json::json!({
                "overridable": true,
                "candidates": found.iter().map(|m| serde_json::json!({
                    "person_id": m.person_id,
                    "reasons": m.reasons,
                })).collect::<Vec<_>>(),
            }),
        ),
        E::Unavailable => AppError::unavailable(e.to_string()),
        E::Storage(_) => AppError::internal(e.to_string()),
    }
}

fn site_number(site_id: &str) -> Result<i64, AppError> {
    crate::db::parse_id_to_i64(site_id).ok_or_else(|| AppError::validation("Site is not valid"))
}

/// Type-ahead person search with role eligibility for the picker.
pub async fn search_people(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<PersonSearchParams>,
) -> Result<Json<crate::models::PersonSearchResponse>, AppError> {
    let (site_id, search) = q.into_parts();
    let site = site_number(&scope.pinned(site_id)?)?;
    crate::services::person_service::PersonService::new(&state)
        .search(site, &search)
        .await
        .map(Json)
        .map_err(person_api_error)
}

/// Creates a card that holds no role yet.
pub async fn create_person(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::CreatePersonRequest>,
) -> Result<(StatusCode, Json<crate::models::PersonMutationResponse>), AppError> {
    let site = site_number(&scope.pinned(q.site_id)?)?;
    crate::services::person_service::PersonService::new(&state)
        .create(site, &payload)
        .await
        .map(|body| (StatusCode::CREATED, Json(body)))
        .map_err(person_api_error)
}

/// One card with role flags, version and unit history.
pub async fn get_person_card(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<crate::models::PersonCardResponse>, AppError> {
    let site = site_number(&scope.pinned(q.site_id)?)?;
    let id = person_id_of(&person_id)?;
    crate::services::person_service::PersonService::new(&state)
        .card(site, id)
        .await
        .map(Json)
        .map_err(person_api_error)
}

/// Edits name, phone and email; the request must carry the card `version`.
pub async fn update_person(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<crate::models::UpdatePersonRequest>,
) -> Result<Json<crate::models::PersonMutationResponse>, AppError> {
    let site = site_number(&scope.pinned(q.site_id)?)?;
    let id = person_id_of(&person_id)?;
    crate::services::person_service::PersonService::new(&state)
        .update(site, id, &payload)
        .await
        .map(Json)
        .map_err(person_api_error)
}

/// Opens a login for the person, or re-sends a pending activation link.
pub async fn open_person_login(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<ActivationDelivery>, AppError> {
    let site = site_number(&scope.pinned(q.site_id)?)?;
    let id = person_id_of(&person_id)?;
    crate::services::person_service::PersonService::new(&state)
        .open_login(site, id)
        .await
        .map(Json)
        .map_err(person_api_error)
}

/// Removes the person's login. Needs a recent step-up.
pub async fn remove_person_login(
    State(state): State<AppState>,
    ctx: AuthzContext,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
) -> Result<StatusCode, AppError> {
    if !ctx.stepped_up {
        return Err(AppError::forbidden("Step-up authentication is required."));
    }
    let site = site_number(&scope.pinned(q.site_id)?)?;
    let id = person_id_of(&person_id)?;
    crate::services::person_service::PersonService::new(&state)
        .remove_login(site, id)
        .await
        .map(|()| StatusCode::NO_CONTENT)
        .map_err(person_api_error)
}

/// Merges this card into another one; needs `PersonManage` and a recent step-up.
/// Ledger rows keep their person IDs; readers resolve the tombstone.
pub async fn merge_person(
    State(state): State<AppState>,
    ctx: AuthzContext,
    scope: crate::tenancy::TenantScope,
    Path(person_id): Path<String>,
    Query(q): Query<SiteIdParam>,
    Json(payload): Json<MergePersonRequest>,
) -> Result<Response, AppError> {
    let site_id = scope.pinned(q.site_id)?;
    let id = person_id_of(&person_id)?;
    match PersonMergeService::new(&state)
        .merge(&ctx, &site_id, id, &payload)
        .await
    {
        Ok(outcome) => Ok(Json(outcome).into_response()),
        Err(PersonMergeError::StepUpRequired) => Ok(SecurityError::StepUp.into_response()),
        Err(e) => Err(merge_error(e)),
    }
}

fn merge_error(e: PersonMergeError) -> AppError {
    match e {
        PersonMergeError::NotFound => AppError::not_found("Kişi bulunamadı."),
        PersonMergeError::SamePerson => {
            AppError::validation("Bir kişi kendisiyle birleştirilemez.")
        }
        PersonMergeError::NotMergeable
        | PersonMergeError::VersionMismatch
        | PersonMergeError::RoleConflict { .. } => AppError::conflict(e.to_string()),
        PersonMergeError::StepUpRequired => AppError::validation(e.to_string()),
        PersonMergeError::Unavailable => AppError::unavailable(e.to_string()),
        PersonMergeError::Storage(_) => AppError::internal(e.to_string()),
    }
}

#[cfg(test)]
mod person_search_params_tests {
    use super::PersonSearchParams;
    use crate::models::PersonSearchContext;

    // covers: SC-12-05-06
    #[test]
    fn numeric_paging_fields_parse_from_query_string() {
        let uri: axum::http::Uri = "/x?context=owner&page=1&limit=50&site_id=7&q=ay"
            .parse()
            .expect("valid uri");
        let axum::extract::Query(parsed) =
            axum::extract::Query::<PersonSearchParams>::try_from_uri(&uri)
                .expect("query string should deserialize");
        let (site_id, search) = parsed.into_parts();
        assert_eq!(site_id.as_deref(), Some("7"));
        assert_eq!(search.page, Some(1));
        assert_eq!(search.limit, Some(50));
        assert_eq!(search.q.as_deref(), Some("ay"));
        assert_eq!(search.context, Some(PersonSearchContext::Owner));
    }

    #[test]
    fn empty_query_string_uses_defaults() {
        let uri: axum::http::Uri = "/x".parse().expect("valid uri");
        let axum::extract::Query(parsed) =
            axum::extract::Query::<PersonSearchParams>::try_from_uri(&uri)
                .expect("empty query should deserialize");
        let (site_id, search) = parsed.into_parts();
        assert!(site_id.is_none());
        assert_eq!(search, crate::models::PersonSearchQuery::default());
    }
}
