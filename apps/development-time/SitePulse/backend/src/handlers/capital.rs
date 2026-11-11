//! Capital projects (demirbaş): projects, installments, disbursements, unit shares.

use super::*;

pub async fn list_capital_projects(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Query(q): Query<SiteIdParam>,
) -> Result<Json<Vec<CapitalProject>>, crate::tenancy::TenantDenied> {
    let site_id = scope.pinned(q.site_id)?;
    let service = CapitalProjectService::new(state);
    Ok(Json(service.list_projects(&site_id).await))
}

pub async fn create_capital_project(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Json(mut payload): Json<CreateCapitalProjectRequest>,
) -> Result<(StatusCode, Json<CapitalProject>), (StatusCode, String)> {
    scope.pin_opt(&mut payload.site_id)?;
    let service = CapitalProjectService::new(state);
    service
        .create_project(payload)
        .await
        .map(|p| (StatusCode::CREATED, Json(p)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// Loads a capital project and checks it belongs to the caller's tenant. A
/// foreign project is reported as not found (no cross-tenant existence oracle).
/// The middleware cannot check these routes: their path id is a project id.
pub(crate) async fn scoped_capital_project(
    state: &AppState,
    scope: &crate::tenancy::TenantScope,
    id: &str,
) -> Result<CapitalProject, (StatusCode, String)> {
    let not_found = || {
        (
            StatusCode::NOT_FOUND,
            "Demirbaş projesi bulunamadı.".to_string(),
        )
    };
    let project = CapitalProjectService::new(state.clone())
        .get_project(id)
        .await
        .ok_or_else(not_found)?;
    if !scope.allows(&project.site_id) {
        return Err(not_found());
    }
    Ok(project)
}

pub async fn get_capital_project(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
) -> Result<Json<CapitalProject>, (StatusCode, String)> {
    scoped_capital_project(&state, &scope, &id).await.map(Json)
}

pub async fn list_capital_installments(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
) -> Result<Json<Vec<CapitalProjectInstallment>>, (StatusCode, String)> {
    scoped_capital_project(&state, &scope, &id).await?;
    let service = CapitalProjectService::new(state);
    Ok(Json(service.list_installments(&id).await))
}

pub async fn accrue_capital_installment(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Json(payload): Json<AccrueInstallmentRequest>,
) -> Result<Json<AccrueInstallmentResponse>, (StatusCode, String)> {
    scoped_capital_project(&state, &scope, &id).await?;
    let service = CapitalProjectService::new(state);
    service
        .accrue_installment(&id, payload.installment_number)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn record_capital_disbursement(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
    Json(payload): Json<RecordDisbursementRequest>,
) -> Result<(StatusCode, Json<CapitalContractorDisbursement>), (StatusCode, String)> {
    let project = scoped_capital_project(&state, &scope, &id).await?;
    let service = CapitalProjectService::new(state);
    service
        .record_disbursement(&id, &project.site_id, payload)
        .await
        .map(|d| (StatusCode::CREATED, Json(d)))
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

pub async fn list_capital_disbursements(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
) -> Result<Json<Vec<CapitalContractorDisbursement>>, (StatusCode, String)> {
    scoped_capital_project(&state, &scope, &id).await?;
    let service = CapitalProjectService::new(state);
    Ok(Json(service.list_disbursements(&id).await))
}

pub async fn get_unit_capital_shares(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<String>,
) -> Result<Json<Vec<UnitCapitalShareSummary>>, (StatusCode, String)> {
    scoped_capital_project(&state, &scope, &id).await?;
    let service = CapitalProjectService::new(state);
    service
        .get_unit_capital_shares(&id)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}
