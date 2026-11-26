//! Persistent sessions, refresh rotation and current identity resolution.
use crate::{
    auth::{self, Claims},
    authorization::SecurityError,
    models::{Role, User},
    state::AppState,
};
use axum::{extract::State, Extension, Json};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

const REFRESH_SECONDS: i64 = 7 * 24 * 3600;

#[derive(Clone)]
pub struct Session {
    pub id: String,
    pub user_id: String,
    pub version: i64,
    pub fingerprint: String,
    pub expires_at: DateTime<Utc>,
    pub revoked: bool,
    pub stepped_up_at: Option<DateTime<Utc>>,
}
#[derive(Default)]
pub struct MemorySecurity {
    pub sessions: HashMap<String, Session>,
    pub refresh: HashMap<String, (String, bool)>,
    pub login_attempts: HashMap<String, (std::time::Instant, u32)>,
}
#[derive(Serialize)]
pub struct Credentials {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: i64,
    pub token_type: &'static str,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RefreshRequest {
    pub refresh_token: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StepUpRequest {
    pub password: String,
}

fn fingerprint(user: &User) -> String {
    auth::token_digest(&format!(
        "{:?}|{}|{}|{:?}",
        user.role, user.site_id, user.id, user.password_hash
    ))
}

/// Load the identity from authoritative storage, never from a cache after a DB miss.
///
/// # Errors
/// Fails closed on an unavailable dependency or unknown user.
pub async fn user(state: &AppState, id: &str) -> Result<User, SecurityError> {
    if let Some(client) = crate::db::security_connection(state).await? {
        return crate::db::get_user_by_id_from_client(&client, id)
            .await
            .map_err(|_| SecurityError::Unavailable)?
            .ok_or(SecurityError::Unauthenticated);
    }
    state
        .inner
        .read()
        .await
        .users
        .iter()
        .find(|u| u.id == id)
        .cloned()
        .ok_or(SecurityError::Unauthenticated)
}

async fn version(state: &AppState, user: &User) -> Result<i64, SecurityError> {
    if let Some(client) = crate::db::security_connection(state).await? {
        let id =
            crate::db::require_id("user", &user.id).map_err(|_| SecurityError::Unauthenticated)?;
        let row = client
            .query_opt(
                "SELECT auth_version FROM users WHERE id=$1 AND is_active",
                &[&id],
            )
            .await
            .map_err(|_| SecurityError::Unavailable)?
            .ok_or(SecurityError::Unauthenticated)?;
        return Ok(row.get(0));
    }
    Ok(1)
}

async fn site_active(state: &AppState, user: &User) -> Result<(), SecurityError> {
    if user.role == Role::SaasAdmin {
        return Ok(());
    }
    if let Some(mut conn) = crate::db::security_connection(state).await? {
        let site = crate::db::require_id("site", &user.site_id)
            .map_err(|_| SecurityError::Unauthenticated)?;
        let client = crate::db::begin_tenant_read(&mut conn, site)
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        let active = crate::db::site_is_active_from_client(&*client, &user.site_id)
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        if !active {
            return Err(SecurityError::Unauthenticated);
        }
    } else if !state.inner.read().await.sites.iter().any(|s| {
        auth::same_id(&s.id, &user.site_id) && matches!(s.status, crate::models::SiteStatus::Active)
    }) {
        return Err(SecurityError::Unauthenticated);
    }
    Ok(())
}

fn mint(
    user: &User,
    session: &Session,
    unit_id: Option<&str>,
) -> Result<Credentials, SecurityError> {
    let refresh_token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    let access_token = auth::issue_session_token(user, &session.id, session.version, unit_id)
        .map_err(|_| SecurityError::Unavailable)?;
    Ok(Credentials {
        access_token,
        refresh_token,
        expires_in: auth::TOKEN_TTL_SECONDS,
        token_type: "Bearer",
    })
}

/// Create a durable session and hashed renewal credential.
///
/// # Errors
/// Returns unavailable if persistence or signing fails.
pub async fn create(
    state: &AppState,
    user: &User,
    unit_id: Option<&str>,
) -> Result<Credentials, SecurityError> {
    site_active(state, user).await?;
    let session = Session {
        id: Uuid::new_v4().to_string(),
        user_id: user.id.clone(),
        version: version(state, user).await?,
        fingerprint: fingerprint(user),
        expires_at: Utc::now() + Duration::seconds(REFRESH_SECONDS),
        revoked: false,
        stepped_up_at: None,
    };
    let result = mint(user, &session, unit_id)?;
    crate::audit::identify(&user.id, user.role.as_str(), &session.id, &user.site_id);
    let digest = auth::token_digest(&result.refresh_token);
    if let Some(mut client) = crate::db::security_connection(state).await? {
        let user_id =
            crate::db::require_id("user", &user.id).map_err(|_| SecurityError::Unauthenticated)?;
        let site = if user.role == Role::SaasAdmin {
            None
        } else {
            Some(
                crate::db::require_id("site", &user.site_id)
                    .map_err(|_| SecurityError::Unauthenticated)?,
            )
        };
        let tx = client
            .transaction()
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        if let Some(site_id) = site {
            crate::db::tx_bind_tenant(&tx, site_id)
                .await
                .map_err(|_| SecurityError::Unavailable)?;
        } else {
            // tenant-guard: platform — SaaS admin session has no site_id.
            crate::db::tx_bind_platform(&tx)
                .await
                .map_err(|_| SecurityError::Unavailable)?;
        }
        let inserted=tx.execute("INSERT INTO auth_sessions(id,user_id,auth_version,site_id,expires_at) SELECT $1,id,$3,$4,$5 FROM users WHERE id=$2 AND auth_version=$3 AND password_hash IS NOT DISTINCT FROM $6 AND role=$7 AND is_active AND site_id IS NOT DISTINCT FROM $4 AND google_sub IS NOT DISTINCT FROM $8",
            &[&session.id,&user_id,&session.version,&site,&session.expires_at,&user.password_hash,&user.role.as_str(),&user.google_sub]).await.map_err(|_|SecurityError::Unavailable)?;
        if inserted != 1 {
            return Err(SecurityError::Unauthenticated);
        }
        tx.execute(
            "INSERT INTO auth_refresh_tokens(digest,session_id,expires_at) VALUES ($1,$2,$3)",
            &[&digest, &session.id, &session.expires_at],
        )
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
    } else {
        let mut store = state.security.lock().await;
        store.refresh.insert(digest, (session.id.clone(), false));
        store.sessions.insert(session.id.clone(), session);
    }
    Ok(result)
}

/// Check a session and refresh the request's identity from current storage.
///
/// # Errors
/// Rejects stale, revoked or expired credentials and unavailable dependencies.
pub async fn validate(
    state: &AppState,
    mut claims: Claims,
) -> Result<(Claims, bool, bool), SecurityError> {
    let user = user(state, &claims.sub).await?;
    let current_version = version(state, &user).await?;
    site_active(state, &user).await?;
    let step_up = if let Some(client) = crate::db::security_connection(state).await? {
        let id =
            crate::db::require_id("user", &user.id).map_err(|_| SecurityError::Unauthenticated)?;
        let row=client.query_opt("SELECT stepped_up_at FROM auth_sessions WHERE id=$1 AND user_id=$2 AND auth_version=$3 AND revoked_at IS NULL AND expires_at>now()",&[&claims.sid,&id,&current_version]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::Unauthenticated)?;
        row.get::<_, Option<DateTime<Utc>>>(0)
    } else {
        let store = state.security.lock().await;
        let s = store
            .sessions
            .get(&claims.sid)
            .filter(|s| {
                s.user_id == user.id
                    && !s.revoked
                    && s.expires_at > Utc::now()
                    && s.fingerprint == fingerprint(&user)
            })
            .ok_or(SecurityError::Unauthenticated)?;
        s.stepped_up_at
    };
    if current_version != claims.ver {
        return Err(SecurityError::Unauthenticated);
    }
    claims.sub = user.id.clone();
    claims.email = user.email.clone();
    claims.role = user.role;
    claims.site_id = if user.role == Role::SaasAdmin {
        String::new()
    } else {
        user.site_id.clone()
    };
    claims.unit_id = crate::services::AuthService::new(state.clone())
        .resolve_unit_id(&user)
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    Ok((
        claims,
        user.must_change_password,
        step_up.is_some_and(|at| at > Utc::now() - Duration::minutes(5)),
    ))
}

/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn refresh(
    State(state): State<AppState>,
    Json(input): Json<RefreshRequest>,
) -> Result<Json<Credentials>, SecurityError> {
    if input.refresh_token.len() > 256 {
        return Err(SecurityError::Unauthenticated);
    }
    let digest = auth::token_digest(&input.refresh_token);
    if let Some(mut client) = crate::db::security_connection(&state).await? {
        // tenant-guard: platform — refresh token lookup before user/site is known.
        let tx = client
            .transaction()
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        crate::db::tx_bind_platform(&tx)
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        let row=tx.query_opt("SELECT s.id,s.user_id,s.auth_version,s.expires_at,s.revoked_at,t.consumed_at,u.auth_version,u.is_active FROM auth_refresh_tokens t JOIN auth_sessions s ON s.id=t.session_id JOIN users u ON u.id=s.user_id WHERE t.digest=$1 AND t.expires_at>now() FOR UPDATE OF s,t",&[&digest]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::Unauthenticated)?;
        let sid: String = row.get(0);
        if row.get::<_, Option<DateTime<Utc>>>(5).is_some() {
            tx.execute(
                "UPDATE auth_sessions SET revoked_at=now() WHERE id=$1",
                &[&sid],
            )
            .await
            .map_err(|_| SecurityError::Unavailable)?;
            tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
            return Err(SecurityError::Unauthenticated);
        }
        if row.get::<_, Option<DateTime<Utc>>>(4).is_some()
            || row.get::<_, i64>(2) != row.get::<_, i64>(6)
            || !row.get::<_, bool>(7)
            || row.get::<_, DateTime<Utc>>(3) <= Utc::now()
        {
            return Err(SecurityError::Unauthenticated);
        }
        let id = row.get::<_, i64>(1).to_string();
        // Use the same connection while holding the session lock; no second pool checkout.
        let user_row = tx
            .query_one(
                "SELECT email,role,site_id FROM users WHERE id=$1",
                &[&row.get::<_, i64>(1)],
            )
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        let role = Role::parse(&user_row.get::<_, String>(1))
            .map_err(|_| SecurityError::Unauthenticated)?;
        let site = user_row.get::<_, Option<i64>>(2);
        if role != Role::SaasAdmin {
            let active=tx.query_opt("SELECT 1 FROM sites WHERE id=$1 AND status IN ('ACTIVE','TRIAL') AND deleted_at IS NULL",&[&site]).await.map_err(|_|SecurityError::Unavailable)?.is_some();
            if !active {
                return Err(SecurityError::Unauthenticated);
            }
        }
        let refresh_token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
        let token = auth::issue_token_for_session(
            &id,
            &user_row.get::<_, String>(0),
            role,
            &site.map(|s| s.to_string()).unwrap_or_default(),
            None,
            &sid,
            row.get(2),
        )
        .map_err(|_| SecurityError::Unavailable)?;
        tx.execute(
            "UPDATE auth_refresh_tokens SET consumed_at=now() WHERE digest=$1",
            &[&digest],
        )
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        tx.execute(
            "INSERT INTO auth_refresh_tokens(digest,session_id,expires_at) VALUES ($1,$2,$3)",
            &[
                &auth::token_digest(&refresh_token),
                &sid,
                &row.get::<_, DateTime<Utc>>(3),
            ],
        )
        .await
        .map_err(|_| SecurityError::Unavailable)?;
        tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
        return Ok(Json(Credentials {
            access_token: token,
            refresh_token,
            expires_in: auth::TOKEN_TTL_SECONDS,
            token_type: "Bearer",
        }));
    }
    let mut store = state.security.lock().await;
    let (sid, consumed) = store
        .refresh
        .get(&digest)
        .cloned()
        .ok_or(SecurityError::Unauthenticated)?;
    if consumed {
        if let Some(s) = store.sessions.get_mut(&sid) {
            s.revoked = true;
        }
        return Err(SecurityError::Unauthenticated);
    }
    let session = store
        .sessions
        .get(&sid)
        .cloned()
        .filter(|s| !s.revoked && s.expires_at > Utc::now())
        .ok_or(SecurityError::Unauthenticated)?;
    let user = user(&state, &session.user_id).await?;
    site_active(&state, &user).await?;
    if session.fingerprint != fingerprint(&user) {
        return Err(SecurityError::Unauthenticated);
    }
    let result = mint(&user, &session, None)?;
    store.refresh.insert(digest, (sid.clone(), true));
    store
        .refresh
        .insert(auth::token_digest(&result.refresh_token), (sid, false));
    Ok(Json(result))
}

/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn logout(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    revoke(&state, &claims.sub, Some(&claims.sid)).await?;
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn logout_all(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    revoke(&state, &claims.sub, None).await?;
    Ok(Json(serde_json::json!({"status":"SUCCESS"})))
}
/// Revoke one or all sessions belonging to a user.
///
/// # Errors
/// Returns unavailable on persistence failure.
pub async fn revoke(state: &AppState, user: &str, sid: Option<&str>) -> Result<(), SecurityError> {
    if let Some(client) = crate::db::security_connection(state).await? {
        let id = crate::db::require_id("user", user).map_err(|_| SecurityError::Unauthenticated)?;
        client.execute("UPDATE auth_sessions SET revoked_at=now() WHERE user_id=$1 AND ($2::text IS NULL OR id=$2) AND revoked_at IS NULL",&[&id,&sid]).await.map_err(|_|SecurityError::Unavailable)?;
    } else {
        for s in state
            .security
            .lock()
            .await
            .sessions
            .values_mut()
            .filter(|s| s.user_id == user && sid.is_none_or(|id| s.id == id))
        {
            s.revoked = true;
        }
    }
    Ok(())
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn step_up(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Json(input): Json<StepUpRequest>,
) -> Result<Json<serde_json::Value>, SecurityError> {
    {
        let mut store = state.security.lock().await;
        store
            .login_attempts
            .retain(|_, (at, _)| at.elapsed().as_secs() < 60);
        let attempt = store
            .login_attempts
            .entry(format!("step-up:{}", claims.sid))
            .or_insert((std::time::Instant::now(), 0));
        attempt.1 += 1;
        if attempt.1 > 10 {
            return Err(SecurityError::RateLimited);
        }
    }
    let user = user(&state, &claims.sub).await?;
    let hash = user.password_hash.ok_or(SecurityError::Unauthenticated)?;
    if input.password.len() > 1024 {
        return Err(SecurityError::Unauthenticated);
    }
    let permit = auth::password_permit()
        .await
        .map_err(|_| SecurityError::Unavailable)?;
    let valid = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        auth::verify_password(&input.password, &hash)
    })
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    if !valid {
        return Err(SecurityError::Unauthenticated);
    }
    if let Some(client) = crate::db::security_connection(&state).await? {
        client
            .execute(
                "UPDATE auth_sessions SET stepped_up_at=now() WHERE id=$1 AND revoked_at IS NULL",
                &[&claims.sid],
            )
            .await
            .map_err(|_| SecurityError::Unavailable)?;
    } else if let Some(s) = state.security.lock().await.sessions.get_mut(&claims.sid) {
        s.stepped_up_at = Some(Utc::now());
    }
    Ok(Json(
        serde_json::json!({"status":"SUCCESS","expires_in":300}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinkGoogleRequest {
    pub id_token: String,
}
/// Apply the authenticated security operation.
///
/// # Errors
/// Rejects unauthorized requests, invalid state and unavailable persistence.
pub async fn link_google(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Json(input): Json<LinkGoogleRequest>,
) -> Result<Json<crate::models::AuthResponse>, SecurityError> {
    if input.id_token.len() > 16384 {
        return Err(SecurityError::BadRequest);
    }
    crate::services::AuthService::new(state)
        .link_google(&claims.sub, &input.id_token)
        .await
        .map(Json)
        .map_err(|_| SecurityError::BadRequest)
}
