//! Explicit permissions and resource authorization, independent of path prefixes.
use crate::{
    auth::Claims,
    models::{Permission, Role},
    state::AppState,
};
use axum::{
    extract::{FromRequestParts, Query, State},
    http::{request::Parts, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, thiserror::Error)]
pub enum SecurityError {
    #[error("Security context missing")]
    Misconfigured,
    #[error("Authentication required")]
    Unauthenticated,
    #[error("Permission denied")]
    Forbidden,
    #[error("Resource not found")]
    NotFound,
    #[error("Invalid identifier or request")]
    BadRequest,
    #[error("Password change required")]
    PasswordChange,
    #[error("Recent password verification required")]
    StepUp,
    #[error("Security dependency unavailable")]
    Unavailable,
    #[error("Request conflicts with current state")]
    Conflict,
    #[error("Too many authentication attempts")]
    RateLimited,
}
impl IntoResponse for SecurityError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Misconfigured => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "SECURITY_CONTEXT_MISSING",
            ),
            Self::Unauthenticated => (StatusCode::UNAUTHORIZED, "AUTHENTICATION_REQUIRED"),
            Self::Forbidden => (StatusCode::FORBIDDEN, "PERMISSION_DENIED"),
            Self::NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND"),
            Self::BadRequest => (StatusCode::BAD_REQUEST, "INVALID_REQUEST"),
            Self::PasswordChange => (StatusCode::FORBIDDEN, "PASSWORD_CHANGE_REQUIRED"),
            Self::StepUp => (StatusCode::FORBIDDEN, "STEP_UP_REQUIRED"),
            Self::Unavailable => (StatusCode::SERVICE_UNAVAILABLE, "SECURITY_UNAVAILABLE"),
            Self::Conflict => (StatusCode::CONFLICT, "CONFLICT"),
            Self::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED"),
        };
        let trace_id = format!("req-{}", uuid::Uuid::new_v4());
        let timestamp = chrono::Utc::now();
        let envelope = crate::error::ErrorEnvelope {
            error: crate::error::ErrorBody {
                code: code.to_string(),
                message: self.to_string(),
                details: None,
                trace_id,
                timestamp,
            },
        };
        let mut response = (status, Json(envelope)).into_response();
        if status == StatusCode::UNAUTHORIZED {
            response.headers_mut().insert(
                "www-authenticate",
                axum::http::HeaderValue::from_static("Bearer"),
            );
        }
        if status == StatusCode::TOO_MANY_REQUESTS {
            response
                .headers_mut()
                .insert("retry-after", axum::http::HeaderValue::from_static("60"));
        }
        response
    }
}
#[derive(Clone, Copy, Debug)]
pub enum RoutePolicy {
    Public,
    SelfOnly,
    Require(Permission),
    RequireAny(&'static [Permission]),
    Development,
}
#[derive(Clone, Debug)]
pub struct AuthzContext {
    pub claims: Claims,
    pub permissions: Vec<Permission>,
    pub request_id: String,
    /// The caller re-entered their password recently (sensitive actions).
    pub stepped_up: bool,
}
impl AuthzContext {
    /// Require a permission for the currently authorized tenant context.
    ///
    /// # Errors
    /// Rejects missing permission or another tenant's resource.
    pub fn require(&self, permission: Permission, site: &str) -> Result<(), SecurityError> {
        if !self.permissions.contains(&permission) {
            return Err(SecurityError::Forbidden);
        }
        if !same_site(&self.claims.site_id, site) {
            return Err(SecurityError::NotFound);
        }
        Ok(())
    }
}
impl<S: Send + Sync> FromRequestParts<S> for AuthzContext {
    type Rejection = SecurityError;
    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        parts
            .extensions
            .get::<Self>()
            .cloned()
            .ok_or(SecurityError::Misconfigured)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SiteId(i64);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnitId(i64);
fn parse(value: &str, prefixes: &[&str]) -> Result<i64, SecurityError> {
    let raw = prefixes
        .iter()
        .find_map(|p| value.strip_prefix(p))
        .unwrap_or(value);
    raw.parse::<i64>()
        .ok()
        .filter(|id| *id > 0)
        .ok_or(SecurityError::BadRequest)
}
impl SiteId {
    /// Parse a site identifier, rejecting identifiers belonging to another entity.
    ///
    /// # Errors
    /// Rejects malformed, nonpositive and wrong-kind IDs.
    pub fn parse(value: &str) -> Result<Self, SecurityError> {
        parse(value, &["site-"]).map(Self)
    }
}
impl UnitId {
    /// Parse a unit identifier.
    ///
    /// # Errors
    /// Rejects malformed, nonpositive and wrong-kind IDs.
    pub fn parse(value: &str) -> Result<Self, SecurityError> {
        parse(value, &["unit-", "d-"]).map(Self)
    }
}
pub fn same_site(a: &str, b: &str) -> bool {
    matches!((SiteId::parse(a),SiteId::parse(b)),(Ok(x),Ok(y)) if x==y)
}
pub fn same_unit(a: &str, b: &str) -> bool {
    matches!((UnitId::parse(a),UnitId::parse(b)),(Ok(x),Ok(y)) if x==y)
}

/// Authorize a unit using its current parent tenant and caller relationship.
///
/// # Errors
/// Returns a scoped 404 or dependency failure. Never falls back from DB to memory.
pub async fn unit(state: &AppState, claims: &Claims, id: &str) -> Result<(), SecurityError> {
    unit_relationship(state, claims, id, false).await
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn owned_unit(state: &AppState, claims: &Claims, id: &str) -> Result<(), SecurityError> {
    unit_relationship(state, claims, id, true).await
}
async fn unit_relationship(
    state: &AppState,
    claims: &Claims,
    id: &str,
    owner_only: bool,
) -> Result<(), SecurityError> {
    let unit = UnitId::parse(id)?;
    if let Some(client) = crate::db::security_connection(state).await? {
        let site = SiteId::parse(&claims.site_id)?;
        let user = crate::db::require_id("user", &claims.sub)
            .map_err(|_| SecurityError::Unauthenticated)?;
        let row=client.query_opt("SELECT u.site_id FROM units u JOIN users actor ON actor.id=$3 WHERE u.id=$1 AND u.site_id=$2 AND u.deleted_at IS NULL AND (NOT $5 OR u.owner_person_id=actor.person_id) AND (actor.role='SITE_MANAGER' OR $4 OR u.owner_person_id=actor.person_id OR u.tenant_person_id=actor.person_id OR EXISTS (SELECT 1 FROM occupancy_members m JOIN unit_occupancies o ON o.id=m.occupancy_id WHERE o.unit_id=u.id AND o.end_date IS NULL AND m.person_id=actor.person_id))",&[&unit.0,&site.0,&user,&claims.is_saas_admin(),&owner_only]).await.map_err(|_|SecurityError::Unavailable)?;
        return row.map(|_| ()).ok_or(SecurityError::NotFound);
    }
    let inner = state.inner.read().await;
    let target = inner
        .units
        .iter()
        .find(|u| same_unit(&u.id, id) && same_site(&u.site_id, &claims.site_id))
        .ok_or(SecurityError::NotFound)?;
    if owner_only && target.owner_user_id.as_deref() != Some(&claims.sub) {
        return Err(SecurityError::NotFound);
    }
    let related = target.owner_user_id.as_deref() == Some(&claims.sub)
        || target.tenant_user_id.as_deref() == Some(&claims.sub)
        || inner.unit_members.get(&target.id).is_some_and(|members| {
            members
                .iter()
                .any(|m| m.email.eq_ignore_ascii_case(&claims.email))
        });
    if claims.role == Role::SiteManager || claims.is_saas_admin() || related {
        Ok(())
    } else {
        Err(SecurityError::NotFound)
    }
}

/// Resolve indirect resources before a handler can observe or change them.
///
/// # Errors
/// Fails closed for a missing resource, wrong site or database error.
pub async fn resource(
    state: &AppState,
    claims: &Claims,
    kind: &str,
    id: &str,
) -> Result<(), SecurityError> {
    if let Some(client) = crate::db::security_connection(state).await? {
        let site = SiteId::parse(&claims.site_id)?;
        let row=match kind {
            "registration"=>client.query_opt("SELECT site_id FROM pending_registrations WHERE request_id=$1 AND site_id=$2",&[&id,&site.0]).await,
            "project"=>{let id=parse(id,&["cproj-"])?;client.query_opt("SELECT site_id FROM capital_projects WHERE id=$1 AND site_id=$2",&[&id,&site.0]).await},
            "receipt"=>{let row=client.query_opt("SELECT site_id,unit_id FROM payment_receipts WHERE (id::text=$1 OR receipt_number=$1) AND site_id=$2",&[&id,&site.0]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::NotFound)?;let unit_id:i64=row.get(1);drop(client);return unit(state,claims,&unit_id.to_string()).await;},
            "house_type"=>{let id=parse(id,&["ht-"])?;client.query_opt("SELECT site_id FROM house_types WHERE id=$1 AND site_id=$2",&[&id,&site.0]).await},
            _=>return Err(SecurityError::BadRequest),
        }.map_err(|_|SecurityError::Unavailable)?;
        return row.map(|_| ()).ok_or(SecurityError::NotFound);
    }
    let inner = state.inner.read().await;
    let site = match kind {
        "registration" => inner
            .pending_registrations
            .iter()
            .find(|r| r.request_id == id)
            .map(|r| r.site_id.clone()),
        "project" => inner
            .capital_projects
            .iter()
            .find(|r| r.id == id)
            .map(|r| r.site_id.clone()),
        "receipt" => inner
            .payment_receipts
            .iter()
            .find(|r| r.id.to_string() == id || r.receipt_number == id)
            .map(|r| r.site_id.clone()),
        "house_type" => inner
            .house_types
            .iter()
            .find(|r| r.id == id)
            .map(|r| r.site_id.clone()),
        _ => None,
    }
    .ok_or(SecurityError::NotFound)?;
    if !same_site(&site, &claims.site_id) {
        return Err(SecurityError::NotFound);
    }
    if kind == "receipt" {
        let id = inner
            .payment_receipts
            .iter()
            .find(|r| r.id.to_string() == id || r.receipt_number == id)
            .map(|r| r.unit_id.clone())
            .ok_or(SecurityError::NotFound)?;
        drop(inner);
        return unit(state, claims, &id).await;
    }
    Ok(())
}

#[derive(Deserialize)]
pub struct AuditQuery {
    pub before: Option<i64>,
    pub limit: Option<i64>,
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn audit_events(
    State(state): State<AppState>,
    ctx: AuthzContext,
    path: axum::extract::MatchedPath,
    Query(query): Query<AuditQuery>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    let pool = state.pool.as_ref().ok_or(SecurityError::Unavailable)?;
    let client = pool.get().await.map_err(|_| SecurityError::Unavailable)?;
    let site = if ctx.claims.site_id.is_empty() {
        None
    } else {
        Some(SiteId::parse(&ctx.claims.site_id)?.0)
    };
    let limit = query.limit.unwrap_or(100).clamp(1, 1000);
    let before = query.before.unwrap_or(i64::MAX);
    let rows=client.query("SELECT row_to_json(e)::text FROM audit_events e WHERE site_id IS NOT DISTINCT FROM $1 AND event_id<$2 ORDER BY event_id DESC LIMIT $3",&[&site,&before,&limit]).await.map_err(|_|SecurityError::Unavailable)?;
    let events = rows
        .into_iter()
        .map(|row| serde_json::from_str::<serde_json::Value>(&row.get::<_, String>(0)))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| SecurityError::Unavailable)?;
    let action = if path.as_str().ends_with("/export") {
        "AUDIT_LOG_EXPORTED"
    } else {
        "AUDIT_LOG_READ"
    };
    client.execute("INSERT INTO audit_events(request_id,actor_kind,actor_id,site_id,action,resource_type,outcome) VALUES ($1,'USER',$2,$3,$4,'audit_events','SUCCESS')",&[&ctx.request_id,&ctx.claims.sub,&site,&action]).await.map_err(|_|SecurityError::Unavailable)?;
    Ok(Json(serde_json::json!({"events":events})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantRequest {
    pub site_id: String,
    pub operator_user_id: String,
    pub permissions: Vec<Permission>,
    pub reason: String,
    pub minutes: i64,
}
#[derive(Deserialize)]
pub struct GrantAction {
    pub id: String,
}
#[derive(Serialize)]
pub struct GrantResult {
    pub id: String,
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn request_grant(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(input): Json<GrantRequest>,
) -> Result<Json<GrantResult>, SecurityError> {
    if !ctx.claims.is_saas_admin() || !ctx.permissions.contains(&Permission::SupportAccess) {
        return Err(SecurityError::Forbidden);
    }

    if input.reason.len() < 10
        || input.reason.len() > 500
        || input.permissions.is_empty()
        || input.permissions.len() > 20
        || !(1..=60).contains(&input.minutes)
    {
        return Err(SecurityError::BadRequest);
    }
    let allowed = [
        Permission::UnitRead,
        Permission::SiteManage,
        Permission::PersonRead,
        Permission::ResidentInviteSite,
        Permission::ResidentApprove,
        Permission::LedgerManageAll,
        Permission::PaymentRecordManual,
        Permission::BankAccountManage,
        Permission::ReconciliationConfirm,
        Permission::AuditLogRead,
        Permission::AuditLogExport,
    ];
    if input.permissions.iter().any(|p| !allowed.contains(p)) {
        return Err(SecurityError::Forbidden);
    }
    let operator = crate::db::require_id("user", &input.operator_user_id)
        .map_err(|_| SecurityError::BadRequest)?;
    if operator
        != crate::db::require_id("user", &ctx.claims.sub).map_err(|_| SecurityError::BadRequest)?
    {
        return Err(SecurityError::Forbidden);
    }
    let site = SiteId::parse(&input.site_id)?;
    let permissions = input
        .permissions
        .iter()
        .map(|p| serde_json::to_value(p).and_then(serde_json::from_value::<String>))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| SecurityError::BadRequest)?;
    let client = state
        .pool
        .as_ref()
        .ok_or(SecurityError::Unavailable)?
        .get()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let id = uuid::Uuid::new_v4().to_string();
    let expiry = chrono::Utc::now() + chrono::Duration::minutes(input.minutes);
    client.execute("INSERT INTO support_grants(id,operator_user_id,site_id,permissions,reason,expires_at) VALUES ($1,$2,$3,$4,$5,$6)",&[&id,&operator,&site.0,&permissions,&input.reason,&expiry]).await.map_err(|_|SecurityError::Unavailable)?;
    Ok(Json(GrantResult { id }))
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn approve_grant(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(input): Json<GrantAction>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    if !ctx.claims.is_saas_admin() || !ctx.permissions.contains(&Permission::SupportAccess) {
        return Err(SecurityError::Forbidden);
    }

    let client = state
        .pool
        .as_ref()
        .ok_or(SecurityError::Unavailable)?
        .get()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let id = crate::db::require_id("user", &ctx.claims.sub)
        .map_err(|_| SecurityError::Unauthenticated)?;
    let n=client.execute("UPDATE support_grants SET approved_by=$1 WHERE id=$2 AND operator_user_id<>$1 AND approved_by IS NULL AND revoked_at IS NULL AND expires_at>now()",&[&id,&input.id]).await.map_err(|_|SecurityError::Unavailable)?;
    if n != 1 {
        return Err(SecurityError::NotFound);
    }
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn revoke_grant(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(input): Json<GrantAction>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    if !ctx.claims.is_saas_admin() || !ctx.permissions.contains(&Permission::SupportAccess) {
        return Err(SecurityError::Forbidden);
    }

    let client = state
        .pool
        .as_ref()
        .ok_or(SecurityError::Unavailable)?
        .get()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    client
        .execute(
            "UPDATE support_grants SET revoked_at=now() WHERE id=$1 AND revoked_at IS NULL",
            &[&input.id],
        )
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    tracing::info!(actor_id=%ctx.claims.sub,"Support grant revoked");
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoleAssignment {
    pub user_id: String,
    pub role: Role,
}

/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn assign_role(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(input): Json<RoleAssignment>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    ctx.require(Permission::RoleGrant, &ctx.claims.site_id)?;
    if crate::db::parse_id_to_i64(&input.user_id) == crate::db::parse_id_to_i64(&ctx.claims.sub)
        || !matches!(input.role, Role::HomeOwner | Role::HomeResident)
    {
        return Err(SecurityError::Forbidden);
    }
    let pool = state.pool.as_ref().ok_or(SecurityError::Unavailable)?;
    let mut client = pool.get().await.map_err(|_| SecurityError::Unavailable)?;
    let tx = client
        .transaction()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let site = SiteId::parse(&ctx.claims.site_id)?.0;
    let user =
        crate::db::require_id("user", &input.user_id).map_err(|_| SecurityError::BadRequest)?;
    let row=tx.query_opt("SELECT role FROM users WHERE id=$1 AND site_id=$2 AND is_active AND role IN ('HOME_OWNER','HOME_RESIDENT') FOR UPDATE",&[&user,&site]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::NotFound)?;
    let old: String = row.get(0);
    tx.execute(
        "DELETE FROM user_site_roles WHERE user_id=$1 AND site_id=$2 AND role=$3",
        &[&user, &site, &old],
    )
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    tx.execute(
        "UPDATE users SET role=$1 WHERE id=$2 AND site_id=$3",
        &[&input.role.as_str(), &user, &site],
    )
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    tx.execute("INSERT INTO user_site_roles(user_id,site_id,role) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING",&[&user,&site,&input.role.as_str()]).await.map_err(|_|SecurityError::Unavailable)?;
    tx.execute(
        "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL",
        &[&user],
    )
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
    if let Some(u) = state
        .inner
        .write()
        .await
        .users
        .iter_mut()
        .find(|u| crate::db::parse_id_to_i64(&u.id) == Some(user))
    {
        u.role = input.role;
    }
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlatformRoleAssignment {
    pub user_id: String,
    pub enabled: bool,
}

/// Platform role changes are isolated from tenant role grants and revoke sessions.
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn assign_platform_role(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(input): Json<PlatformRoleAssignment>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    if !ctx.claims.is_saas_admin()
        || !ctx.permissions.contains(&Permission::RoleGrant)
        || crate::db::parse_id_to_i64(&ctx.claims.sub) == crate::db::parse_id_to_i64(&input.user_id)
    {
        return Err(SecurityError::Forbidden);
    }
    let id =
        crate::db::require_id("user", &input.user_id).map_err(|_| SecurityError::BadRequest)?;
    let mut client = state
        .pool
        .as_ref()
        .ok_or(SecurityError::Unavailable)?
        .get()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let tx = client
        .transaction()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let n = if input.enabled {
        tx.execute(
            "UPDATE users SET role='SAAS_ADMIN',site_id=NULL,is_active=true WHERE id=$1",
            &[&id],
        )
        .await
    } else {
        tx.execute(
            "UPDATE users SET is_active=false WHERE id=$1 AND role='SAAS_ADMIN'",
            &[&id],
        )
        .await
    }
    .map_err(|_| SecurityError::Unavailable)?;
    if n != 1 {
        return Err(SecurityError::NotFound);
    }
    tx.execute("DELETE FROM user_site_roles WHERE user_id=$1", &[&id])
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    tx.execute(
        "UPDATE auth_sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL",
        &[&id],
    )
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}
