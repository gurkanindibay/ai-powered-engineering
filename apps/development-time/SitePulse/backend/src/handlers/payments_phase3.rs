//! SPEC-009 handlers. Thin: extract, build the `Caller`, delegate, map errors.
//! The middleware has already authenticated the caller, checked the route's
//! permission, scoped `:unit_id` paths and pinned `site_id` to the caller's site.

use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::NaiveDate;
use serde::Deserialize;

use crate::authorization::AuthzContext;
use crate::models::*;
use crate::services::accounting_service::AccountingService;
use crate::services::analytics_service::AnalyticsService;
use crate::services::assembly_service::AssemblyService;
use crate::services::autopay_service::AutopayService;
use crate::services::bank_matching_service::BankMatchingService;
use crate::services::budget_compliance_service::BudgetComplianceService;
use crate::services::collections_service::CollectionsService;
use crate::services::dunning_service::DunningService;
use crate::services::finance_common::{Caller, FinanceError};
use crate::services::heat_share_service::HeatShareService;
use crate::services::kvkk_service::KvkkService;
use crate::services::lease_service::LeaseService;
use crate::services::notification_service::NotificationService;
use crate::services::plan_service::PlanService;
use crate::services::portfolio_service::PortfolioService;
use crate::services::receipt_document::{render_text_document, TextDocument};
use crate::services::resident_request_service::ResidentRequestService;
use crate::state::AppState;

type ApiError = (StatusCode, Json<serde_json::Value>);
type ApiResult<T> = Result<Json<T>, ApiError>;

fn api_error(status: StatusCode, message: String) -> ApiError {
    (
        status,
        Json(serde_json::json!({ "status": "ERROR", "message": message })),
    )
}

fn fail(e: FinanceError) -> ApiError {
    let status = match e {
        FinanceError::NotFound(_) => StatusCode::NOT_FOUND,
        FinanceError::Invalid(_) => StatusCode::BAD_REQUEST,
        FinanceError::Conflict(_) => StatusCode::CONFLICT,
        FinanceError::Forbidden(_) => StatusCode::FORBIDDEN,
        FinanceError::Unavailable(_) => StatusCode::SERVICE_UNAVAILABLE,
    };
    api_error(status, e.to_string())
}

fn ok<T>(r: Result<T, FinanceError>) -> ApiResult<T> {
    r.map(Json).map_err(fail)
}

fn created<T>(r: Result<T, FinanceError>) -> Result<(StatusCode, Json<T>), ApiError> {
    r.map(|v| (StatusCode::CREATED, Json(v))).map_err(fail)
}

fn caller(ctx: &AuthzContext) -> Caller {
    Caller::from_claims(&ctx.claims)
}

fn pdf(document: &TextDocument, filename: &str) -> Result<Response, ApiError> {
    let bytes = render_text_document(document)
        .map_err(|e| api_error(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok((
        [
            (header::CONTENT_TYPE, "application/pdf".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{}.pdf\"", filename),
            ),
        ],
        bytes,
    )
        .into_response())
}

async fn log(
    state: &AppState,
    c: &Caller,
    action: &str,
    resource: &str,
    unit: Option<&str>,
) -> Result<(), ApiError> {
    KvkkService::new(state)
        .log_access(c, action, resource, unit, None)
        .await
        .map(|_| ())
        .map_err(fail)
}

#[derive(Debug, Deserialize, Default)]
pub struct RangeQuery {
    pub from: Option<NaiveDate>,
    pub to: Option<NaiveDate>,
    pub year: Option<i32>,
    pub format: Option<String>,
    pub months: Option<u32>,
    pub as_of: Option<NaiveDate>,
    pub limit: Option<usize>,
}

impl RangeQuery {
    fn wants_pdf(&self) -> bool {
        self.format
            .as_deref()
            .is_some_and(|f| f.eq_ignore_ascii_case("pdf"))
    }
    fn year_or_now(&self) -> i32 {
        use chrono::Datelike;
        self.year.unwrap_or_else(|| chrono::Utc::now().year())
    }
}

// ---------------------------------------------------------------------------
// R2: KVKK
// ---------------------------------------------------------------------------

pub async fn kvkk_status(State(state): State<AppState>, ctx: AuthzContext) -> Json<PrivacyStatus> {
    Json(KvkkService::new(&state).status(&caller(&ctx)).await)
}

pub async fn kvkk_acknowledge(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> ApiResult<PrivacyStatus> {
    ok(KvkkService::new(&state).acknowledge(&caller(&ctx)).await)
}

pub async fn kvkk_update_consents(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<UpdateConsentsRequest>,
) -> ApiResult<PrivacyStatus> {
    ok(KvkkService::new(&state)
        .update_consents(&caller(&ctx), req)
        .await)
}

pub async fn publish_privacy_notice(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<PublishPrivacyNoticeRequest>,
) -> Result<(StatusCode, Json<PrivacyNotice>), ApiError> {
    created(
        KvkkService::new(&state)
            .publish_notice(&caller(&ctx), req)
            .await,
    )
}

pub async fn debtor_export(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> ApiResult<DebtorExport> {
    ok(KvkkService::new(&state).debtor_export(&caller(&ctx)).await)
}

pub async fn financial_access_log(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<Vec<FinancialAccessLogEntry>> {
    Json(
        KvkkService::new(&state)
            .access_log(&caller(&ctx), q.limit.unwrap_or(200))
            .await,
    )
}

pub async fn retention_review(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> ApiResult<RetentionReview> {
    ok(KvkkService::new(&state)
        .retention_review(&caller(&ctx), false)
        .await)
}

pub async fn retention_purge(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> ApiResult<RetentionReview> {
    ok(KvkkService::new(&state)
        .retention_review(&caller(&ctx), true)
        .await)
}

pub async fn set_retention_policy(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<SetRetentionPolicyRequest>,
) -> ApiResult<RetentionPolicy> {
    ok(KvkkService::new(&state)
        .set_retention(&caller(&ctx), req)
        .await)
}

/// The SPEC-007 statement, with a KVKK access-log row.
pub async fn get_resident_statement_logged(
    State(state): State<AppState>,
    ctx: AuthzContext,
    claims: axum::Extension<crate::auth::Claims>,
    path: Path<String>,
) -> Result<Json<ResidentStatement>, ApiError> {
    let unit = path.0.clone();
    let statement = super::get_resident_statement(State(state.clone()), claims, path)
        .await
        .map_err(|(s, m)| api_error(s, m))?;
    log(&state, &caller(&ctx), ACCESS_VIEW, "STATEMENT", Some(&unit)).await?;
    Ok(statement)
}

/// The SPEC-007 receipt PDF, with a KVKK access-log row.
pub async fn get_payment_receipt_pdf_logged(
    State(state): State<AppState>,
    ctx: AuthzContext,
    claims: axum::Extension<crate::auth::Claims>,
    path: Path<String>,
    query: Query<super::SiteQuery>,
) -> Result<Response, ApiError> {
    let id = path.0.clone();
    let response = super::get_payment_receipt_pdf(State(state.clone()), claims, path, query)
        .await
        .map_err(|(s, m)| api_error(s, m))?;
    KvkkService::new(&state)
        .log_access(&caller(&ctx), ACCESS_EXPORT, "RECEIPT_PDF", None, Some(id))
        .await
        .map_err(fail)?;
    Ok(response)
}

// ---------------------------------------------------------------------------
// R4: notifications and dunning
// ---------------------------------------------------------------------------

pub async fn list_notifications(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<Vec<Notification>> {
    Json(
        NotificationService::new(&state)
            .list(&caller(&ctx), q.limit.unwrap_or(100))
            .await,
    )
}

#[derive(Debug, Deserialize)]
pub struct BroadcastRequest {
    pub channel: String,
    pub category: String,
    pub subject: String,
    pub body: String,
}

pub async fn broadcast_notification(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<BroadcastRequest>,
) -> ApiResult<Notification> {
    ok(NotificationService::new(&state)
        .broadcast(
            &caller(&ctx),
            &req.channel,
            &req.category,
            &req.subject,
            &req.body,
        )
        .await)
}

#[derive(Debug, Deserialize)]
pub struct CreateAnnouncementRequest {
    pub site_id: String,
    pub title: String,
    pub body: String,
}

pub async fn create_announcement(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    ctx: AuthzContext,
    Json(req): Json<CreateAnnouncementRequest>,
) -> impl IntoResponse {
    let site_id = match scope.pinned(Some(req.site_id)) {
        Ok(site_id) => site_id,
        Err(denied) => return denied.json().into_response(),
    };
    if req.title.trim().is_empty()
        || req.body.trim().is_empty()
        || req.title.chars().count() > 120
        || req.body.chars().count() > 2_000
    {
        return api_error(
            StatusCode::BAD_REQUEST,
            "Title and body are required and must be within their length limits".to_string(),
        )
        .into_response();
    }
    let mut actor = caller(&ctx);
    actor.site_id = site_id;
    match NotificationService::new(&state)
        .broadcast(
            &actor,
            "NOTICE_BOARD",
            "ANNOUNCEMENT",
            &req.title,
            &req.body,
        )
        .await
    {
        Ok(notification) => (StatusCode::CREATED, Json(notification)).into_response(),
        Err(error) => fail(error).into_response(),
    }
}

pub async fn get_dunning_policy(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<DunningPolicy> {
    Json(
        DunningService::new(&state)
            .policy(&ctx.claims.site_id)
            .await,
    )
}

pub async fn set_dunning_policy(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<SetDunningPolicyRequest>,
) -> ApiResult<DunningPolicy> {
    ok(DunningService::new(&state)
        .set_policy(&caller(&ctx), req)
        .await)
}

pub async fn run_dunning(
    State(state): State<AppState>,
    ctx: AuthzContext,
    body: Option<Json<DunningRunRequest>>,
) -> ApiResult<DunningRunReport> {
    let as_of = body.and_then(|b| b.0.as_of);
    ok(DunningService::new(&state)
        .run(&ctx.claims.site_id, as_of)
        .await)
}

pub async fn dunning_actions(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<DunningAction>> {
    Json(
        DunningService::new(&state)
            .actions(&ctx.claims.site_id)
            .await,
    )
}

pub async fn dunning_notice_letter(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(due_id): Path<String>,
) -> Result<Response, ApiError> {
    let doc = DunningService::new(&state)
        .notice_letter(&ctx.claims.site_id, &due_id)
        .await
        .map_err(fail)?;
    log(&state, &caller(&ctx), ACCESS_EXPORT, "IHTARNAME", None).await?;
    pdf(&doc, &format!("ihtarname-{}", due_id))
}

// ---------------------------------------------------------------------------
// R3: leases (KMK 22)
// ---------------------------------------------------------------------------

pub async fn list_leases(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<TenancyLease>> {
    Json(LeaseService::new(&state).list(&ctx.claims.site_id).await)
}

pub async fn upsert_lease(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<UpsertLeaseRequest>,
) -> Result<(StatusCode, Json<TenancyLease>), ApiError> {
    created(LeaseService::new(&state).upsert(&caller(&ctx), req).await)
}

pub async fn joint_exposure(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<JointExposureReport> {
    Json(
        LeaseService::new(&state)
            .joint_exposure(&ctx.claims.site_id)
            .await,
    )
}

pub async fn rent_deduction_certificate(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<String>,
) -> Result<Response, ApiError> {
    let doc = LeaseService::new(&state)
        .rent_deduction_certificate(&ctx.claims.site_id, &id)
        .await
        .map_err(fail)?;
    log(
        &state,
        &caller(&ctx),
        ACCESS_EXPORT,
        "RENT_CERTIFICATE",
        None,
    )
    .await?;
    pdf(&doc, &format!("kira-mahsup-{}", id))
}

// ---------------------------------------------------------------------------
// R5: resident requests
// ---------------------------------------------------------------------------

pub async fn create_virman_request(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
    Json(req): Json<CreateVirmanRequest>,
) -> Result<(StatusCode, Json<VirmanRequest>), ApiError> {
    created(
        ResidentRequestService::new(&state)
            .create_virman_request(&caller(&ctx), &unit_id, req)
            .await,
    )
}

pub async fn unit_virman_requests(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
) -> Json<Vec<VirmanRequest>> {
    Json(
        ResidentRequestService::new(&state)
            .virman_requests(&caller(&ctx), Some(&unit_id))
            .await,
    )
}

pub async fn site_virman_requests(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<VirmanRequest>> {
    Json(
        ResidentRequestService::new(&state)
            .virman_requests(&caller(&ctx), None)
            .await,
    )
}

pub async fn decide_virman_request(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<DecideRequest>,
) -> ApiResult<VirmanRequest> {
    ok(ResidentRequestService::new(&state)
        .decide_virman(&caller(&ctx), id, req)
        .await)
}

pub async fn create_dispute(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
    Json(req): Json<CreateDisputeRequest>,
) -> Result<(StatusCode, Json<LedgerDispute>), ApiError> {
    created(
        ResidentRequestService::new(&state)
            .create_dispute(&caller(&ctx), &unit_id, req)
            .await,
    )
}

pub async fn unit_disputes(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
) -> Json<Vec<LedgerDispute>> {
    Json(
        ResidentRequestService::new(&state)
            .disputes(&caller(&ctx), Some(&unit_id))
            .await,
    )
}

pub async fn site_disputes(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<LedgerDispute>> {
    Json(
        ResidentRequestService::new(&state)
            .disputes(&caller(&ctx), None)
            .await,
    )
}

pub async fn resolve_dispute(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<ResolveDisputeRequest>,
) -> ApiResult<LedgerDispute> {
    ok(ResidentRequestService::new(&state)
        .resolve_dispute(&caller(&ctx), id, req)
        .await)
}

// ---------------------------------------------------------------------------
// R6: autopay and card instalments
// ---------------------------------------------------------------------------

/// SPEC-007 request plus SPEC-009 R6 options.
#[derive(Debug, Deserialize)]
pub struct CreatePaymentIntentV2 {
    #[serde(flatten)]
    pub base: CreatePaymentIntentRequest,
    #[serde(default)]
    pub installments: Option<i32>,
    #[serde(default)]
    pub save_card: bool,
}

pub async fn create_payment_intent_v2(
    State(state): State<AppState>,
    claims: axum::Extension<crate::auth::Claims>,
    Path(unit_id): Path<String>,
    Json(req): Json<CreatePaymentIntentV2>,
) -> Result<(StatusCode, Json<PaymentIntent>), ApiError> {
    if req.installments.is_some_and(|n| n != 1) || req.save_card {
        // Validate the options before the provider page is opened.
        let charger = crate::services::autopay_service::configured_charger()
            .map_err(|e| api_error(StatusCode::SERVICE_UNAVAILABLE, e.0))?;
        let n = req.installments.unwrap_or(1);
        if !charger.installments().contains(&n) {
            return Err(api_error(
                StatusCode::BAD_REQUEST,
                format!("{} instalments are not offered", n),
            ));
        }
    }
    let (status, Json(intent)) =
        super::create_payment_intent(State(state.clone()), claims, Path(unit_id), Json(req.base))
            .await
            .map_err(|(s, m)| api_error(s, m))?;
    AutopayService::new(&state)
        .set_intent_options(&intent.id, req.installments, req.save_card)
        .await
        .map_err(fail)?;
    Ok((status, Json(intent)))
}

#[derive(Debug, Deserialize)]
struct TokenEnvelope {
    #[serde(default)]
    card_token: Option<ProviderCardToken>,
}

/// The provider webhook (SPEC-007) that also keeps a saved card's token (R6).
pub async fn provider_webhook_v2(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<PaymentIntent>, ApiError> {
    let token = serde_json::from_slice::<TokenEnvelope>(&body)
        .ok()
        .and_then(|t| t.card_token);
    let Json(intent) = super::provider_webhook(State(state.clone()), headers, body)
        .await
        .map_err(|(s, m)| api_error(s, m))?;
    if let Some(token) = token {
        crate::audit::CONTEXT
            .scope(
                crate::audit::AuditContext::service("payment-provider"),
                AutopayService::new(&state).after_capture(&intent, Some(token)),
            )
            .await
            .map_err(fail)?;
    }
    Ok(Json(intent))
}

pub async fn autopay_overview(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
) -> ApiResult<AutopayOverview> {
    ok(AutopayService::new(&state)
        .overview(&caller(&ctx), &unit_id)
        .await)
}

pub async fn create_mandate(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
    Json(req): Json<CreateMandateRequest>,
) -> Result<(StatusCode, Json<AutopayMandate>), ApiError> {
    created(
        AutopayService::new(&state)
            .create_mandate(&caller(&ctx), &unit_id, req)
            .await,
    )
}

pub async fn cancel_mandate(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path((unit_id, mandate_id)): Path<(String, i64)>,
) -> ApiResult<AutopayMandate> {
    ok(AutopayService::new(&state)
        .cancel_mandate(&caller(&ctx), &unit_id, mandate_id)
        .await)
}

pub async fn run_autopay(
    State(state): State<AppState>,
    ctx: AuthzContext,
    body: Option<Json<DunningRunRequest>>,
) -> ApiResult<AutopayRunReport> {
    let as_of = body.and_then(|b| b.0.as_of);
    ok(AutopayService::new(&state)
        .run(&ctx.claims.site_id, as_of)
        .await)
}

// ---------------------------------------------------------------------------
// R7: accounting
// ---------------------------------------------------------------------------

pub async fn list_vendors(State(state): State<AppState>, ctx: AuthzContext) -> Json<Vec<Vendor>> {
    Json(
        AccountingService::new(&state)
            .vendors(&ctx.claims.site_id)
            .await,
    )
}

pub async fn create_vendor(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateVendorRequest>,
) -> Result<(StatusCode, Json<Vendor>), ApiError> {
    created(
        AccountingService::new(&state)
            .create_vendor(&caller(&ctx), req)
            .await,
    )
}

pub async fn get_approval_policy(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<serde_json::Value> {
    let limit = AccountingService::new(&state)
        .policy(&ctx.claims.site_id)
        .await;
    Json(serde_json::json!({ "site_id": ctx.claims.site_id, "manager_limit": limit }))
}

pub async fn set_approval_policy(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<SetApprovalPolicyRequest>,
) -> ApiResult<ExpenseApprovalPolicy> {
    ok(AccountingService::new(&state)
        .set_policy(&caller(&ctx), req)
        .await)
}

pub async fn list_expenses(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<ExpenseView>> {
    Json(
        AccountingService::new(&state)
            .expenses(&ctx.claims.site_id)
            .await,
    )
}

pub async fn create_expense(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateExpenseRequest>,
) -> Result<(StatusCode, Json<ExpenseView>), ApiError> {
    created(
        AccountingService::new(&state)
            .create_expense(&caller(&ctx), req)
            .await,
    )
}

pub async fn approve_expense(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<ExpenseView> {
    ok(AccountingService::new(&state)
        .approve_expense(&caller(&ctx), id)
        .await)
}

pub async fn reject_expense(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<RejectExpenseRequest>,
) -> ApiResult<ExpenseView> {
    ok(AccountingService::new(&state)
        .reject_expense(&caller(&ctx), id, req)
        .await)
}

pub async fn pay_expense(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<PayExpenseRequest>,
) -> ApiResult<ExpenseView> {
    ok(AccountingService::new(&state)
        .pay_expense(&caller(&ctx), id, req)
        .await)
}

pub async fn journal(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Result<Json<Vec<JournalEntryView>>, ApiError> {
    let rows = AccountingService::new(&state)
        .journal(&ctx.claims.site_id, q.from, q.to)
        .await;
    log(&state, &caller(&ctx), ACCESS_VIEW, "GENERAL_LEDGER", None).await?;
    Ok(Json(rows))
}

pub async fn create_journal_entry(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateJournalEntryRequest>,
) -> Result<(StatusCode, Json<JournalEntryView>), ApiError> {
    created(
        AccountingService::new(&state)
            .create_journal_entry(&caller(&ctx), req)
            .await,
    )
}

pub async fn trial_balance(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<TrialBalance> {
    Json(
        AccountingService::new(&state)
            .trial_balance(&ctx.claims.site_id, q.from, q.to)
            .await,
    )
}

pub async fn chart_of_accounts() -> Json<Vec<serde_json::Value>> {
    Json(
        crate::domain::double_entry::CHART
            .iter()
            .map(|a| {
                serde_json::json!({
                    "code": a.code,
                    "name": a.name,
                    "normal_side": if a.side == crate::domain::double_entry::NormalSide::Debit { "DEBIT" } else { "CREDIT" },
                })
            })
            .collect(),
    )
}

pub async fn budget_vs_actual(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<BudgetVsActual> {
    Json(
        AccountingService::new(&state)
            .budget_vs_actual(&ctx.claims.site_id, q.year_or_now())
            .await,
    )
}

pub async fn reserve_fund(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<ReserveFundStatus> {
    Json(
        AccountingService::new(&state)
            .reserve_fund(&ctx.claims.site_id, q.year_or_now())
            .await,
    )
}

pub async fn account_report(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Result<Response, ApiError> {
    let report = AccountingService::new(&state)
        .account_report(&ctx.claims.site_id, q.year_or_now())
        .await
        .map_err(fail)?;
    log(&state, &caller(&ctx), ACCESS_EXPORT, "ACCOUNT_REPORT", None).await?;
    if q.wants_pdf() {
        return pdf(
            &AccountingService::account_report_document(&report),
            &format!("hesap-raporu-{}", report.fiscal_year),
        );
    }
    Ok(Json(report).into_response())
}

// ---------------------------------------------------------------------------
// R8: collections
// ---------------------------------------------------------------------------

pub async fn list_cases(State(state): State<AppState>, ctx: AuthzContext) -> Json<Vec<CaseView>> {
    Json(
        CollectionsService::new(&state)
            .cases(&ctx.claims.site_id)
            .await,
    )
}

pub async fn open_case(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<OpenCaseRequest>,
) -> Result<(StatusCode, Json<CaseView>), ApiError> {
    created(
        CollectionsService::new(&state)
            .open_case(&caller(&ctx), req)
            .await,
    )
}

pub async fn get_case(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<CaseView> {
    ok(CollectionsService::new(&state)
        .case(&ctx.claims.site_id, id)
        .await)
}

pub async fn advance_case(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<AdvanceCaseRequest>,
) -> ApiResult<CaseView> {
    ok(CollectionsService::new(&state)
        .advance(&caller(&ctx), id, req)
        .await)
}

pub async fn evidence_pack(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Query(q): Query<RangeQuery>,
) -> Result<Response, ApiError> {
    let pack = CollectionsService::new(&state)
        .evidence_pack(&ctx.claims.site_id, id)
        .await
        .map_err(fail)?;
    log(&state, &caller(&ctx), ACCESS_EXPORT, "EVIDENCE_PACK", None).await?;
    if q.wants_pdf() {
        return pdf(
            &CollectionsService::evidence_document(&pack),
            &format!("delil-dosyasi-{}", id),
        );
    }
    Ok(Json(pack).into_response())
}

pub async fn grant_lawyer_access(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<LawyerAccessGrant> {
    ok(CollectionsService::new(&state)
        .grant_lawyer_access(&caller(&ctx), id)
        .await)
}

#[derive(Debug, Deserialize)]
pub struct TokenQuery {
    pub token: String,
    #[serde(default)]
    pub format: Option<String>,
}

/// Public: the lawyer's read-only pack behind a one-time token.
pub async fn lawyer_pack(
    State(state): State<AppState>,
    Query(q): Query<TokenQuery>,
) -> Result<Response, ApiError> {
    let pack = CollectionsService::new(&state)
        .pack_by_token(&q.token)
        .await
        .map_err(fail)?;
    if q.format
        .as_deref()
        .is_some_and(|f| f.eq_ignore_ascii_case("pdf"))
    {
        return pdf(
            &CollectionsService::evidence_document(&pack),
            &format!("delil-dosyasi-{}", pack.case_id),
        );
    }
    Ok(Json(pack).into_response())
}

// ---------------------------------------------------------------------------
// R10: plans and adjustments
// ---------------------------------------------------------------------------

pub async fn list_plans(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<PaymentPlanView>> {
    Json(
        PlanService::new(&state)
            .plans(&ctx.claims.site_id, None)
            .await,
    )
}

pub async fn unit_plans(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(unit_id): Path<String>,
) -> Json<Vec<PaymentPlanView>> {
    Json(
        PlanService::new(&state)
            .plans(&ctx.claims.site_id, Some(&unit_id))
            .await,
    )
}

pub async fn create_plan(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreatePaymentPlanRequest>,
) -> Result<(StatusCode, Json<PaymentPlanView>), ApiError> {
    created(
        PlanService::new(&state)
            .create_plan(&caller(&ctx), req)
            .await,
    )
}

pub async fn cancel_plan(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<PaymentPlan> {
    ok(PlanService::new(&state)
        .cancel_plan(&caller(&ctx), id)
        .await)
}

pub async fn run_plans(
    State(state): State<AppState>,
    ctx: AuthzContext,
    body: Option<Json<DunningRunRequest>>,
) -> ApiResult<PlanRunReport> {
    let as_of = body.and_then(|b| b.0.as_of);
    ok(PlanService::new(&state)
        .run(&ctx.claims.site_id, as_of)
        .await)
}

pub async fn list_adjustments(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<LedgerAdjustment>> {
    Json(
        PlanService::new(&state)
            .adjustments(&ctx.claims.site_id)
            .await,
    )
}

pub async fn request_adjustment(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<RequestAdjustmentRequest>,
) -> Result<(StatusCode, Json<LedgerAdjustment>), ApiError> {
    created(
        PlanService::new(&state)
            .request_adjustment(&caller(&ctx), req, "MANUAL")
            .await,
    )
}

pub async fn decide_adjustment(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<DecideRequest>,
) -> ApiResult<LedgerAdjustment> {
    ok(PlanService::new(&state)
        .decide_adjustment(&caller(&ctx), id, req)
        .await)
}

// ---------------------------------------------------------------------------
// R9: bank matching
// ---------------------------------------------------------------------------

pub async fn suggest_matches(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<MatchRequest>,
) -> ApiResult<Vec<MatchSuggestion>> {
    ok(BankMatchingService::new(&state)
        .suggest(&ctx.claims.site_id, req)
        .await)
}

pub async fn list_bank_feeds(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<BankFeedConnection>> {
    Json(
        BankMatchingService::new(&state)
            .feeds(&ctx.claims.site_id)
            .await,
    )
}

pub async fn create_bank_feed(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateBankFeedRequest>,
) -> Result<(StatusCode, Json<BankFeedConnection>), ApiError> {
    created(
        BankMatchingService::new(&state)
            .create_feed(&caller(&ctx), req)
            .await,
    )
}

pub async fn sync_bank_feed(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<serde_json::Value> {
    ok(BankMatchingService::new(&state)
        .sync_feed(&caller(&ctx), id)
        .await
        .map(|(feed, fetched)| serde_json::json!({ "feed": feed, "fetched_lines": fetched })))
}

pub async fn daily_reconciliation(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<DailyReconciliationRequest>,
) -> Result<(StatusCode, Json<BankReconciliationRun>), ApiError> {
    created(
        BankMatchingService::new(&state)
            .daily_reconciliation(&caller(&ctx), req)
            .await,
    )
}

pub async fn reconciliation_runs(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<BankReconciliationRun>> {
    Json(
        BankMatchingService::new(&state)
            .reconciliation_runs(&ctx.claims.site_id)
            .await,
    )
}

// ---------------------------------------------------------------------------
// R11: heat-share
// ---------------------------------------------------------------------------

pub async fn list_heat_periods(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> ApiResult<Vec<HeatPeriodView>> {
    ok(HeatShareService::new(&state)
        .periods(&ctx.claims.site_id)
        .await)
}

pub async fn create_heat_period(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateHeatPeriodRequest>,
) -> Result<(StatusCode, Json<HeatPeriodView>), ApiError> {
    created(
        HeatShareService::new(&state)
            .create_period(&caller(&ctx), req)
            .await,
    )
}

pub async fn get_heat_period(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<HeatPeriodView> {
    ok(HeatShareService::new(&state)
        .period(&ctx.claims.site_id, id)
        .await)
}

pub async fn record_heat_readings(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<RecordReadingsRequest>,
) -> ApiResult<HeatPeriodView> {
    ok(HeatShareService::new(&state)
        .record_readings(&caller(&ctx), id, req)
        .await)
}

pub async fn approve_heat_period(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<HeatPeriodView> {
    ok(HeatShareService::new(&state)
        .approve(&caller(&ctx), id)
        .await)
}

// ---------------------------------------------------------------------------
// R12: assembly
// ---------------------------------------------------------------------------

pub async fn list_meetings(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<MeetingView>> {
    Json(
        AssemblyService::new(&state)
            .meetings(&ctx.claims.site_id)
            .await,
    )
}

pub async fn create_meeting(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<CreateMeetingRequest>,
) -> Result<(StatusCode, Json<MeetingView>), ApiError> {
    created(
        AssemblyService::new(&state)
            .create_meeting(&caller(&ctx), req)
            .await,
    )
}

pub async fn get_meeting(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<MeetingView> {
    ok(AssemblyService::new(&state)
        .meeting(&ctx.claims.site_id, id)
        .await)
}

pub async fn record_attendance(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<RecordAttendanceRequest>,
) -> ApiResult<MeetingView> {
    ok(AssemblyService::new(&state)
        .record_attendance(&caller(&ctx), id, req)
        .await)
}

pub async fn cast_votes(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<CastVotesRequest>,
) -> ApiResult<Vec<AssemblyVote>> {
    ok(AssemblyService::new(&state)
        .cast_votes(&caller(&ctx), id, req)
        .await)
}

pub async fn close_agenda_item(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
    Json(req): Json<CloseAgendaItemRequest>,
) -> ApiResult<AssemblyDecision> {
    ok(AssemblyService::new(&state)
        .close_item(&caller(&ctx), id, req)
        .await)
}

pub async fn list_decisions(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<Vec<AssemblyDecision>> {
    Json(
        AssemblyService::new(&state)
            .decisions(&ctx.claims.site_id)
            .await,
    )
}

pub async fn record_decision(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<RecordDecisionRequest>,
) -> Result<(StatusCode, Json<AssemblyDecision>), ApiError> {
    created(
        AssemblyService::new(&state)
            .record_decision(&caller(&ctx), req)
            .await,
    )
}

// ---------------------------------------------------------------------------
// R1: budget compliance
// ---------------------------------------------------------------------------

pub async fn budget_legal_basis(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<LegalBasisReport> {
    Json(
        BudgetComplianceService::new(&state)
            .legal_basis(&ctx.claims.site_id)
            .await,
    )
}

pub async fn set_budget_transition(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(req): Json<SetTransitionRequest>,
) -> ApiResult<LegalBasisReport> {
    ok(BudgetComplianceService::new(&state)
        .set_transition(&caller(&ctx), req)
        .await)
}

// ---------------------------------------------------------------------------
// R13: portfolio
// ---------------------------------------------------------------------------

pub async fn list_companies(State(state): State<AppState>) -> Json<Vec<ManagementCompany>> {
    Json(PortfolioService::new(&state).companies().await)
}

pub async fn create_company(
    State(state): State<AppState>,
    Json(req): Json<CreateCompanyRequest>,
) -> Result<(StatusCode, Json<ManagementCompany>), ApiError> {
    created(PortfolioService::new(&state).create_company(req).await)
}

pub async fn attach_company_site(
    State(state): State<AppState>,
    scope: crate::tenancy::TenantScope,
    Path(id): Path<i64>,
    Json(req): Json<AttachSiteRequest>,
) -> Result<(StatusCode, Json<ManagementCompanySite>), ApiError> {
    // A platform (TenantManage) route: only the platform scope may name any site.
    scope
        .ensure(&req.site_id)
        .map_err(crate::tenancy::TenantDenied::json)?;
    created(PortfolioService::new(&state).attach_site(id, req).await)
}

pub async fn add_company_member(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(req): Json<AddMemberRequest>,
) -> Result<(StatusCode, Json<ManagementCompanyMember>), ApiError> {
    created(PortfolioService::new(&state).add_member(id, req).await)
}

pub async fn portfolio_summary(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Path(id): Path<i64>,
) -> ApiResult<PortfolioSummary> {
    ok(PortfolioService::new(&state)
        .summary(&caller(&ctx), id)
        .await)
}

pub async fn issue_fee_invoices(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(req): Json<IssueFeeInvoicesRequest>,
) -> ApiResult<Vec<FeeInvoice>> {
    ok(PortfolioService::new(&state).issue_invoices(id, req).await)
}

pub async fn list_fee_invoices(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> Json<Vec<FeeInvoice>> {
    Json(PortfolioService::new(&state).invoices(id).await)
}

// ---------------------------------------------------------------------------
// R14: analytics
// ---------------------------------------------------------------------------

pub async fn collection_analytics(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Query(q): Query<RangeQuery>,
) -> Json<CollectionAnalytics> {
    Json(
        AnalyticsService::new(&state)
            .collections(&ctx.claims.site_id, q.months, q.as_of)
            .await,
    )
}
