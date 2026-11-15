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
pub fn current_context() -> Option<AuditContext> {
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

pub fn current_request_id() -> Option<String> {
    current_context().map(|c| c.request_id)
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
    let incoming_id = req
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim())
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 64
                && s.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        });
    let request_id = incoming_id
        .map(|s| s.to_string())
        .unwrap_or_else(|| Uuid::new_v4().to_string());
    let path = req.uri().path().to_string();
    let method = req.method().to_string();
    let authentication_response = path.starts_with("/api/v1/auth/");
    let start = std::time::Instant::now();
    let context = AuditContext {
        source_ip: client_ip(&req),
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

    tracing::debug!(
        request_id = %request_id,
        method = %method,
        path = %path,
        source_ip = ?context.source_ip,
        "--> HTTP request started"
    );

    let trace = std::sync::Arc::new(std::sync::Mutex::new(context));
    let mut response = TRACE.scope(trace, next.run(req)).await;
    let latency_ms = start.elapsed().as_millis();
    let status = response.status();

    if status.is_server_error() {
        tracing::error!(
            request_id = %request_id,
            method = %method,
            path = %path,
            status = %status.as_u16(),
            latency_ms = %latency_ms,
            "<-- HTTP request completed with server error"
        );
    } else if status.is_client_error() {
        tracing::warn!(
            request_id = %request_id,
            method = %method,
            path = %path,
            status = %status.as_u16(),
            latency_ms = %latency_ms,
            "<-- HTTP request completed with client rejection"
        );
    } else {
        tracing::info!(
            request_id = %request_id,
            method = %method,
            path = %path,
            status = %status.as_u16(),
            latency_ms = %latency_ms,
            "<-- HTTP request completed successfully"
        );
    }

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

/// Addresses of reverse proxies whose `X-Forwarded-For` header is believed
/// (`SITEPULSE_TRUSTED_PROXIES`, comma separated).
fn trusted_proxies() -> Vec<std::net::IpAddr> {
    std::env::var("SITEPULSE_TRUSTED_PROXIES")
        .unwrap_or_default()
        .split(',')
        .filter_map(|s| s.trim().parse().ok())
        .collect()
}

/// The real client address. The forwarded header is used only when the TCP peer
/// is a trusted proxy; the rightmost entry that is not itself a trusted proxy wins.
pub fn client_ip(req: &axum::extract::Request) -> Option<String> {
    let peer = req
        .extensions()
        .get::<axum::extract::ConnectInfo<std::net::SocketAddr>>()
        .map(|p| p.0.ip())?;
    let trusted = trusted_proxies();
    let forwarded = req
        .headers()
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok());
    Some(resolve_client_ip(peer, forwarded, &trusted).to_string())
}

fn resolve_client_ip(
    peer: std::net::IpAddr,
    forwarded: Option<&str>,
    trusted: &[std::net::IpAddr],
) -> std::net::IpAddr {
    if !trusted.contains(&peer) {
        return peer;
    }
    forwarded
        .into_iter()
        .flat_map(|h| h.split(',').rev())
        .filter_map(|s| s.trim().parse::<std::net::IpAddr>().ok())
        .find(|ip| !trusted.contains(ip))
        .unwrap_or(peer)
}

#[cfg(test)]
mod client_ip_tests {
    use super::resolve_client_ip;
    use std::net::IpAddr;

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn ignores_forwarded_header_from_untrusted_peer() {
        assert_eq!(
            resolve_client_ip(ip("203.0.113.9"), Some("1.2.3.4"), &[ip("10.0.0.1")]),
            ip("203.0.113.9")
        );
    }

    #[test]
    fn takes_rightmost_untrusted_entry_from_trusted_proxy() {
        let trusted = [ip("10.0.0.1"), ip("10.0.0.2")];
        assert_eq!(
            resolve_client_ip(
                ip("10.0.0.1"),
                Some("6.6.6.6, 198.51.100.7, 10.0.0.2"),
                &trusted
            ),
            ip("198.51.100.7")
        );
    }
}
