//! SPEC-007 handlers: operating budgets, card payment intents, the resident
//! statement, receipt PDFs and public receipt verification.

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{Html, IntoResponse, Response},
    Form, Json,
};
use chrono::Utc;
use serde::Deserialize;

use crate::auth::Claims;
use crate::models::*;
use crate::services::card_payment_service::{self, CardPaymentError, CardPaymentService};
use crate::services::operating_budget_service::{BudgetError, OperatingBudgetService};
use crate::services::{receipt_document, resident_statement};
use crate::state::AppState;

type ApiError = (StatusCode, String);

fn budget_status(e: BudgetError) -> ApiError {
    match e {
        BudgetError::NotFound(m) => (StatusCode::NOT_FOUND, m),
        BudgetError::Invalid(m) => (StatusCode::BAD_REQUEST, m),
        BudgetError::Conflict(m) => (StatusCode::CONFLICT, m),
        BudgetError::Storage(m) => (StatusCode::SERVICE_UNAVAILABLE, m),
    }
}

fn card_status(e: CardPaymentError) -> ApiError {
    match e {
        CardPaymentError::NotFound(m) => (StatusCode::NOT_FOUND, m),
        CardPaymentError::Invalid(m) => (StatusCode::BAD_REQUEST, m),
        CardPaymentError::Conflict(m) => (StatusCode::CONFLICT, m),
        CardPaymentError::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m),
    }
}

#[derive(Debug, Deserialize, Default)]
pub struct SiteQuery {
    pub site_id: Option<String>,
}

fn site_of(q: &SiteQuery, claims: &Claims) -> String {
    q.site_id
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| claims.site_id.clone())
}

fn actor(claims: &Claims) -> String {
    format!("user:{} <{}>", claims.sub, claims.email)
}

// ---------------------------------------------------------------------------
// Operating budgets (site staff)
// ---------------------------------------------------------------------------

pub async fn list_operating_budgets(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Query(q): Query<SiteQuery>,
) -> Json<Vec<OperatingBudget>> {
    Json(
        OperatingBudgetService::new(state)
            .list(&site_of(&q, &claims))
            .await,
    )
}

pub async fn create_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<CreateOperatingBudgetRequest>,
) -> Result<(StatusCode, Json<OperatingBudget>), ApiError> {
    let site = req
        .site_id
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| site_of(&q, &claims));
    OperatingBudgetService::new(state)
        .create_draft(&site, req, &actor(&claims))
        .await
        .map(|b| (StatusCode::CREATED, Json(b)))
        .map_err(budget_status)
}

pub async fn get_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .get(&site_of(&q, &claims), &id)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn delete_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
) -> Result<StatusCode, ApiError> {
    OperatingBudgetService::new(state)
        .delete_draft(&site_of(&q, &claims), &id)
        .await
        .map(|_| StatusCode::NO_CONTENT)
        .map_err(budget_status)
}

pub async fn issue_interim_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<IssueInterimBudgetRequest>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .issue_interim(&site_of(&q, &claims), &id, req)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn approve_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<ApproveBudgetRequest>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .approve(&site_of(&q, &claims), &id, req)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn reject_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<RejectBudgetRequest>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .reject(&site_of(&q, &claims), &id, req)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn finalize_operating_budget(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .finalize(&site_of(&q, &claims), &id, Utc::now().date_naive())
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn record_budget_service(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<RecordBudgetServiceRequest>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .record_service(&site_of(&q, &claims), &id, req)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn file_budget_objection(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<FileBudgetObjectionRequest>,
) -> Result<(StatusCode, Json<OperatingBudget>), ApiError> {
    OperatingBudgetService::new(state)
        .file_objection(&site_of(&q, &claims), &id, req)
        .await
        .map(|b| (StatusCode::CREATED, Json(b)))
        .map_err(budget_status)
}

pub async fn resolve_budget_objection(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path((id, objection_id)): Path<(String, String)>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<ResolveBudgetObjectionRequest>,
) -> Result<Json<OperatingBudget>, ApiError> {
    OperatingBudgetService::new(state)
        .resolve_objection(&site_of(&q, &claims), &id, &objection_id, req)
        .await
        .map(Json)
        .map_err(budget_status)
}

pub async fn get_budget_compliance(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Query(q): Query<SiteQuery>,
) -> Json<BudgetComplianceStatus> {
    Json(
        OperatingBudgetService::new(state)
            .compliance(&site_of(&q, &claims), Utc::now().date_naive())
            .await,
    )
}

pub async fn set_budget_policy(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Query(q): Query<SiteQuery>,
    Json(req): Json<BudgetPolicyRequest>,
) -> Result<Json<BudgetComplianceStatus>, ApiError> {
    let site = req
        .site_id
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| site_of(&q, &claims));
    let service = OperatingBudgetService::new(state);
    service
        .set_policy(&site, req.require_operating_budget)
        .await
        .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    Ok(Json(
        service.compliance(&site, Utc::now().date_naive()).await,
    ))
}

pub async fn list_revaluation_rates(State(state): State<AppState>) -> Json<Vec<RevaluationRate>> {
    Json(OperatingBudgetService::new(state).revaluation_rates().await)
}

/// SaaS admin only (route policy): the yearly revaluation rate.
pub async fn set_revaluation_rate(
    State(state): State<AppState>,
    Json(req): Json<RevaluationRate>,
) -> Result<Json<RevaluationRate>, ApiError> {
    OperatingBudgetService::new(state)
        .set_revaluation_rate(req)
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

/// The budget in force for a resident's unit, with only that unit's share.
pub async fn get_resident_operating_budget(
    State(state): State<AppState>,
    Path(unit_id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let inner = state.inner.read().await;
    let unit = inner
        .units
        .iter()
        .find(|u| crate::auth::same_id(&u.id, &unit_id))
        .ok_or((StatusCode::NOT_FOUND, "Unit not found".to_string()))?;
    let today = Utc::now().date_naive();
    let Some(budget) =
        crate::services::operating_budget_service::budget_in_force(&inner, &unit.site_id, today)
    else {
        return Ok(Json(
            serde_json::json!({ "budget": null, "unit_share": null }),
        ));
    };
    let mut public = budget.clone();
    let share = budget.share_of(&unit.id).cloned();
    public.unit_shares.clear();
    public
        .service_records
        .retain(|r| crate::auth::same_id(&r.unit_id, &unit.id));
    public
        .objections
        .retain(|o| crate::auth::same_id(&o.unit_id, &unit.id));
    Ok(Json(
        serde_json::json!({ "budget": public, "unit_share": share }),
    ))
}

// ---------------------------------------------------------------------------
// Resident statement
// ---------------------------------------------------------------------------

pub async fn get_resident_statement(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(unit_id): Path<String>,
) -> Result<Json<ResidentStatement>, ApiError> {
    let inner = state.inner.read().await;
    let unit = inner
        .units
        .iter()
        .find(|u| crate::auth::same_id(&u.id, &unit_id))
        .ok_or((StatusCode::NOT_FOUND, "Unit not found".to_string()))?;
    let viewer = resident_statement::caller_debtor_role(&claims, unit);
    Ok(Json(resident_statement::build_statement(
        &inner,
        unit,
        viewer,
        Utc::now().date_naive(),
    )))
}

// ---------------------------------------------------------------------------
// Card payments
// ---------------------------------------------------------------------------

pub async fn create_payment_intent(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(unit_id): Path<String>,
    Json(req): Json<CreatePaymentIntentRequest>,
) -> Result<(StatusCode, Json<PaymentIntent>), ApiError> {
    let role = {
        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| crate::auth::same_id(&u.id, &unit_id))
            .ok_or((StatusCode::NOT_FOUND, "Unit not found".to_string()))?;
        resident_statement::caller_debtor_role(&claims, unit)
    };
    CardPaymentService::new(state)
        .create_intent(&unit_id, req, role, &actor(&claims))
        .await
        .map(|i| (StatusCode::CREATED, Json(i)))
        .map_err(card_status)
}

pub async fn get_payment_intent(
    State(state): State<AppState>,
    Path((unit_id, intent_id)): Path<(String, String)>,
) -> Result<Json<PaymentIntent>, ApiError> {
    CardPaymentService::new(state)
        .get_intent(&unit_id, &intent_id)
        .await
        .map(Json)
        .map_err(card_status)
}

/// The licensed provider's signed notification (`X-Provider-Signature`:
/// hex HMAC-SHA256 of the raw body). Public route; the signature is the auth.
pub async fn provider_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<PaymentIntent>, ApiError> {
    let signature = headers
        .get(card_payment_service::SIGNATURE_HEADER)
        .and_then(|v| v.to_str().ok());
    if !card_payment_service::verify_provider_signature(&body, signature) {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Invalid provider signature".to_string(),
        ));
    }
    let event: ProviderWebhookEvent = serde_json::from_slice(&body).map_err(|e| {
        (
            StatusCode::BAD_REQUEST,
            format!("Invalid notification: {}", e),
        )
    })?;
    crate::audit::CONTEXT
        .scope(
            crate::audit::AuditContext::service("payment-provider"),
            CardPaymentService::new(state).apply_provider_event(event),
        )
        .await
        .map(Json)
        .map_err(card_status)
}

fn sandbox_guard() -> Result<(), ApiError> {
    if card_payment_service::sandbox_enabled() {
        Ok(())
    } else {
        Err((StatusCode::NOT_FOUND, "Not found".to_string()))
    }
}

/// The sandbox provider's hosted payment page (outside production only).
pub async fn sandbox_checkout_page(
    State(state): State<AppState>,
    Path(reference): Path<String>,
) -> Result<Html<String>, ApiError> {
    sandbox_guard()?;
    let intent = CardPaymentService::new(state)
        .intent_by_ref(card_payment_service::SANDBOX_PROVIDER, &reference)
        .await
        .ok_or((StatusCode::NOT_FOUND, "Unknown payment".to_string()))?;
    Ok(Html(card_payment_service::sandbox_checkout_page(&intent)))
}

/// The sandbox's 3-D Secure result: it sends the provider's signed notifications
/// to the public webhook path, exactly as a real provider would.
pub async fn sandbox_checkout_complete(
    State(state): State<AppState>,
    Path(reference): Path<String>,
    Form(form): Form<SandboxCheckoutCompletion>,
) -> Result<Html<String>, ApiError> {
    sandbox_guard()?;
    let service = CardPaymentService::new(state);
    let intent = service
        .intent_by_ref(card_payment_service::SANDBOX_PROVIDER, &reference)
        .await
        .ok_or((StatusCode::NOT_FOUND, "Unknown payment".to_string()))?;
    let approve = form.outcome.trim().eq_ignore_ascii_case("APPROVE");
    let events = if approve {
        vec![(INTENT_AUTHORIZED, None), (INTENT_CAPTURED, None)]
    } else {
        vec![(
            INTENT_FAILED,
            Some("3-D Secure doğrulaması reddedildi".to_string()),
        )]
    };
    let mut current = intent;
    for (status, failure) in events {
        let event = ProviderWebhookEvent {
            provider: card_payment_service::SANDBOX_PROVIDER.to_string(),
            provider_ref: reference.clone(),
            status: status.to_string(),
            amount: current.amount,
            fee_amount: approve.then(|| {
                (current.amount * rust_decimal::Decimal::new(19, 3))
                    .round_dp_with_strategy(2, rust_decimal::RoundingStrategy::MidpointNearestEven)
            }),
            three_ds_status: Some(if approve { "Y" } else { "N" }.to_string()),
            failure_reason: failure,
        };
        let body = serde_json::to_vec(&event)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        let signature = card_payment_service::sign_provider_body(&body);
        if !card_payment_service::verify_provider_signature(&body, Some(&signature)) {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                "Sandbox signature mismatch".to_string(),
            ));
        }
        current = crate::audit::CONTEXT
            .scope(
                crate::audit::AuditContext::service("payment-provider"),
                service.apply_provider_event(event),
            )
            .await
            .map_err(card_status)?;
    }
    Ok(Html(card_payment_service::sandbox_checkout_page(&current)))
}

// ---------------------------------------------------------------------------
// Receipt PDF and public verification
// ---------------------------------------------------------------------------

pub async fn get_payment_receipt_pdf(
    State(state): State<AppState>,
    axum::Extension(claims): axum::Extension<Claims>,
    Path(id): Path<String>,
    Query(q): Query<SiteQuery>,
) -> Result<Response, ApiError> {
    let site_id = site_of(&q, &claims);
    let receipt = crate::services::PaymentTrackingService::new(state.clone())
        .get_receipt(&site_id, &id)
        .await
        .map_err(|e| (StatusCode::NOT_FOUND, e))?;
    crate::authorization::unit(&state, &claims, &receipt.unit_id)
        .await
        .map_err(|_| (StatusCode::NOT_FOUND, "Receipt not found".to_string()))?;
    let unit_label = {
        let inner = state.inner.read().await;
        inner
            .units
            .iter()
            .find(|u| crate::auth::same_id(&u.id, &receipt.unit_id))
            .map(|u| inner.unit_label(&u.block_id, u.unit_number))
            .unwrap_or_else(|| receipt.unit_id.clone())
    };
    let pdf = receipt_document::render_receipt_pdf(&receipt, &unit_label)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;
    Ok((
        [
            (header::CONTENT_TYPE, "application/pdf".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{}.pdf\"", receipt.receipt_number),
            ),
        ],
        pdf,
    )
        .into_response())
}

#[derive(Debug, Deserialize)]
pub struct VerifyReceiptQuery {
    pub no: String,
    pub h: String,
}

/// Public: confirms a receipt by number and verification code. Discloses no payer data.
pub async fn verify_receipt(
    State(state): State<AppState>,
    Query(q): Query<VerifyReceiptQuery>,
) -> Json<ReceiptVerification> {
    let number = q.no.trim().to_string();
    let code = q.h.trim().to_lowercase();
    let mut found = {
        let inner = state.inner.read().await;
        inner
            .payment_receipts
            .iter()
            .find(|r| r.receipt_number == number && r.verification_hash == code)
            .cloned()
            .map(|r| {
                let reversed = inner
                    .payment_receipts
                    .iter()
                    .any(|x| x.reverses_receipt_id == Some(r.id));
                (r, reversed)
            })
    };
    if found.is_none() && code.len() == 64 {
        if let Some(ref pool) = state.pool {
            if let Ok(Some(r)) = crate::db::find_payment_receipt(pool, 0, &number).await {
                if r.verification_hash == code {
                    found = Some((r, false));
                }
            }
        }
    }
    Json(match found {
        Some((r, reversed)) => ReceiptVerification {
            valid: true,
            receipt_number: r.receipt_number,
            receipt_type: Some(r.receipt_type),
            issued_at: Some(r.issued_at),
            total_amount: Some(r.total_amount),
            issuer_name: r.issuer_name,
            reversed,
        },
        None => ReceiptVerification {
            valid: false,
            receipt_number: number,
            receipt_type: None,
            issued_at: None,
            total_amount: None,
            issuer_name: None,
            reversed: false,
        },
    })
}
