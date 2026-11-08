//! Request correlation and transaction-bound database audit attribution.
use axum::{
    extract::Request,
    http::{HeaderName, HeaderValue},
    middleware::Next,
    response::Response,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuditContext {
    pub permissions: Vec<crate::models::Permission>,
    pub support_grant_id: Option<String>,
    pub source_ip: Option<String>,
    pub user_agent: Option<String>,
    pub site_id: Option<String>,
    pub platform: bool,
    pub development: bool,
    pub request_id: String,
    pub actor_kind: String,
    pub actor_id: Option<String>,
    pub actor_role: Option<String>,
    pub session_id: Option<String>,
}

tokio::task_local! {
    pub static CONTEXT: AuditContext;
    static TRACE: std::sync::Arc<std::sync::Mutex<AuditContext>>;
}

/// Record verified identity for security outcomes, including early authorization denials.
pub fn identify(id: &str, role: &str, sid: &str, site: &str) {
    let _trace_result = TRACE.try_with(|trace| {
        if let Ok(mut context) = trace.lock() {
            context.actor_kind = "USER".to_string();
            context.actor_id = Some(id.to_string());
            context.actor_role = Some(role.to_string());
            context.session_id = Some(sid.to_string());
            context.permissions = crate::models::Role::parse(role)
                .map(crate::models::Permission::permissions_for_role)
                .unwrap_or_default();
            context.site_id = crate::db::parse_id_to_i64(site).map(|id| id.to_string());
        }
    });
}
pub(crate) fn record_context(context: &AuditContext) {
    let _trace_result = TRACE.try_with(|trace| {
        if let Ok(mut target) = trace.lock() {
            *target = context.clone();
        }
    });
}
fn current_context() -> Option<AuditContext> {
    let explicit = CONTEXT.try_with(Clone::clone).ok();
    if explicit
        .as_ref()
        .is_some_and(|c| c.actor_kind != "ANONYMOUS")
    {
        return explicit;
    }
    TRACE
        .try_with(|trace| trace.lock().ok().map(|c| c.clone()))
        .ok()
        .flatten()
        .or(explicit)
}

/// Replace connection-local context on every checkout, including background tasks.
/// A failed attribution write fails the checkout rather than reusing stale identity.
pub fn checkout_hook() -> deadpool_postgres::Hook {
    deadpool_postgres::Hook::async_fn(|client, _| {
        Box::pin(async move {
            let context = current_context()
                .map(|value| serde_json::to_string(&value))
                .transpose()
                .map_err(|_| deadpool_postgres::HookError::message("Invalid audit context"))?
                .unwrap_or_else(|| "{}".to_string());
            client
                .execute(
                    "SELECT set_config('sitepulse.audit_context', $1, false)",
                    &[&context],
                )
                .await
                .map_err(deadpool_postgres::HookError::Backend)?;
            Ok(())
        })
    })
}

/// Generate server-owned correlation IDs, propagate them on success and rejection.
pub async fn correlate(mut req: Request, next: Next) -> Response {
    let request_id = Uuid::new_v4().to_string();
    let authentication_response = req.uri().path().starts_with("/api/v1/auth/");
    let context = AuditContext {
        source_ip: req
            .extensions()
            .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
            .map(|peer| peer.0.ip().to_string()),
        user_agent: req
            .headers()
            .get("user-agent")
            .and_then(|v| v.to_str().ok())
            .map(|v| v.chars().take(256).collect()),
        permissions: Vec::new(),
        support_grant_id: None,
        site_id: None,
        platform: false,
        development: false,
        request_id: request_id.clone(),
        actor_kind: "ANONYMOUS".to_string(),
        actor_id: None,
        actor_role: None,
        session_id: None,
    };
    req.extensions_mut().insert(context.clone());
    let trace = std::sync::Arc::new(std::sync::Mutex::new(context));
    let mut response = TRACE.scope(trace, next.run(req)).await;
    if authentication_response {
        response
            .headers_mut()
            .insert("cache-control", HeaderValue::from_static("no-store"));
        response
            .headers_mut()
            .insert("pragma", HeaderValue::from_static("no-cache"));
    }
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response
            .headers_mut()
            .insert(HeaderName::from_static("x-request-id"), value);
    }
    response
}

/// Persist authentication outcomes and denials separately from domain transactions.
pub async fn security_boundary(
    axum::extract::State(state): axum::extract::State<crate::state::AppState>,
    req: Request,
    next: Next,
) -> Response {
    let path = req.uri().path().to_string();
    let template = req
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(|p| p.as_str().to_string());
    let login = matches!(path.as_str(), "/api/v1/auth/login" | "/api/v1/auth/google");
    let response = next.run(req).await;
    let status = response.status();
    let context = current_context();
    let action = if login {
        if status.is_success() {
            Some("AUTH_LOGIN_SUCCEEDED")
        } else {
            Some("AUTH_LOGIN_FAILED")
        }
    } else if status.is_success()
        && context
            .as_ref()
            .is_some_and(|c| c.support_grant_id.is_some())
    {
        Some("SUPPORT_GRANT_USED")
    } else if status == axum::http::StatusCode::UNAUTHORIZED {
        Some("AUTHENTICATION_FAILED")
    } else if status == axum::http::StatusCode::FORBIDDEN
        || status == axum::http::StatusCode::NOT_FOUND
            && context.as_ref().is_some_and(|c| c.actor_kind == "USER")
    {
        Some("AUTHZ_DENIED")
    } else {
        None
    };
    if let (Some(action), Some(context), Some(pool)) = (action, context, &state.pool) {
        if !status.is_success() {
            let mut store = state.security.lock().await;
            let counter = store
                .login_attempts
                .entry("security-event-limit".to_string())
                .or_insert((std::time::Instant::now(), 0));
            if counter.0.elapsed().as_secs() >= 60 {
                *counter = (std::time::Instant::now(), 0);
            }
            counter.1 = counter.1.saturating_add(1);
            if counter.1 > 1000 {
                if counter.1 == 1001 {
                    tracing::warn!("Security event rate limit reached; excess failures are aggregated for this minute");
                }
                return response;
            }
        }
        let outcome = if status.is_success() {
            "SUCCESS"
        } else {
            "DENIED"
        };
        let result=async{
            let site=match context.site_id.as_deref(){Some(site)=>Some(site.parse::<i64>().map_err(|_|())?),None=>None};
            let client=pool.get().await.map_err(|_|())?;
            client.execute("INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,session_reference,site_id,action,resource_type,outcome,support_grant_id,resource_id,source_ip,user_agent) VALUES ($1,$2,$3,$4,$5,$6,$7,'http_request',$8,$9,$10,$11::text::inet,$12)",
                &[&context.request_id,&context.actor_kind,&context.actor_id,&context.actor_role,&context.session_id,&site,&action,&outcome,&context.support_grant_id,&template,&context.source_ip,&context.user_agent]).await.map_err(|_|())?;
            Ok::<(),()>(())
        }.await;
        if result.is_err() {
            tracing::error!(request_id=%context.request_id,"Security event persistence unavailable");
            if action == "SUPPORT_GRANT_USED" {
                return axum::response::IntoResponse::into_response(
                    crate::authorization::SecurityError::Unavailable,
                );
            }
        }
    }
    response
}

impl AuditContext {
    /// Explicit identity for an internal worker or a separately authenticated webhook.
    pub fn service(name: &str) -> Self {
        let parent = current_context();
        Self {
            source_ip: parent.as_ref().and_then(|c| c.source_ip.clone()),
            user_agent: parent.as_ref().and_then(|c| c.user_agent.clone()),
            permissions: Vec::new(),
            support_grant_id: None,
            site_id: None,
            platform: false,
            development: false,
            request_id: current_context()
                .map(|c| c.request_id)
                .unwrap_or_else(|| Uuid::new_v4().to_string()),
            actor_kind: "SERVICE".to_string(),
            actor_id: Some(name.to_string()),
            actor_role: None,
            session_id: None,
        }
    }
}
