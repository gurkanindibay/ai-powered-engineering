//! Authentication and authorization primitives.
//!
//! * Signed HS256 JWTs (`issue_token` / `verify_token`) built from typed claims.
//! * Argon2id password hashing (`hash_password` / `verify_password`).
//! * `require_auth`: an Axum middleware that authenticates every non-public route,
//!   enforces the role policy per route family, and pins every `site_id` / `unit_id`
//!   referenced by the request (path, query or JSON body) to the caller's tenant.

// Axum middleware helpers return `Response` as their error so it can be sent as-is.
#![allow(clippy::result_large_err)]

use std::sync::OnceLock;

use argon2::password_hash::{
    rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use argon2::Argon2;
use axum::{
    body::{to_bytes, Body},
    extract::{Request, State},
    http::{header, Method, StatusCode, Uri},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use chrono::Utc;
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::models::Role;
use crate::state::AppState;

/// Access tokens live for ten minutes; server-side sessions can revoke them immediately.
pub const TOKEN_TTL_SECONDS: i64 = 600;
/// Minimum password length, applied to registration, change and reset alike.
pub const MIN_PASSWORD_LENGTH: usize = 10;
const MAX_INSPECTED_BODY_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Claims {
    pub sid: String,
    pub ver: i64,
    pub iss: String,
    pub aud: String,
    pub jti: String,
    pub sub: String,
    pub email: String,
    pub role: Role,
    pub site_id: String,
    #[serde(default)]
    pub unit_id: Option<String>,
    pub iat: i64,
    pub exp: i64,
}

impl Claims {
    pub fn is_saas_admin(&self) -> bool {
        self.role == Role::SaasAdmin
    }
    pub fn is_site_staff(&self) -> bool {
        self.role == Role::SiteManager
    }
}

// ---------------------------------------------------------------------------
// Secrets
// ---------------------------------------------------------------------------

fn jwt_secret() -> Result<&'static [u8], String> {
    static SECRET: OnceLock<Result<Vec<u8>, String>> = OnceLock::new();
    SECRET
        .get_or_init(|| match std::env::var("SITEPULSE_JWT_SECRET") {
            Ok(s) if s.len() >= 32 => Ok(s.into_bytes()),
            Ok(_) => Err("SITEPULSE_JWT_SECRET must be at least 32 bytes".to_string()),
            Err(_) if crate::state::AppStateInner::is_production() => {
                Err("SITEPULSE_JWT_SECRET is required".to_string())
            }
            Err(_) => {
                use rand::RngExt;
                let mut bytes = vec![0u8; 48];
                rand::rng().fill(&mut bytes[..]);
                Ok(bytes)
            }
        })
        .as_deref()
        .map_err(Clone::clone)
}

/// Validate secrets before accepting requests.
///
/// # Errors
/// Rejects missing production secrets or invalid configuration.
pub fn validate_configuration() -> Result<(), String> {
    crate::state::AppStateInner::validate_mode()?;
    jwt_secret()?;
    if crate::state::AppStateInner::is_production()
        && std::env::var("SITEPULSE_BANK_WEBHOOK_SECRET")
            .map(|s| s.is_empty())
            .unwrap_or(true)
    {
        return Err("SITEPULSE_BANK_WEBHOOK_SECRET is required in production".to_string());
    }
    Ok(())
}
fn issuer() -> String {
    std::env::var("SITEPULSE_JWT_ISSUER").unwrap_or_else(|_| "sitepulse".to_string())
}
fn audience() -> String {
    std::env::var("SITEPULSE_JWT_AUDIENCE").unwrap_or_else(|_| "sitepulse-api".to_string())
}

/// Sign an access credential. A stored session is still required to authorize it.
///
/// # Errors
/// Returns a signing/configuration error.
pub fn issue_token(
    user_id: &str,
    email: &str,
    role: Role,
    site_id: &str,
    unit_id: Option<&str>,
) -> Result<String, String> {
    issue_token_for_session(
        user_id,
        email,
        role,
        site_id,
        unit_id,
        &uuid::Uuid::new_v4().to_string(),
        1,
    )
}
/// Sign credentials for an existing session.
///
/// # Errors
/// Returns a signing/configuration error.
pub fn issue_session_token(
    user: &crate::models::User,
    sid: &str,
    version: i64,
    unit_id: Option<&str>,
) -> Result<String, String> {
    issue_token_for_session(
        &user.id,
        &user.email,
        user.role,
        &user.site_id,
        unit_id,
        sid,
        version,
    )
}
#[derive(Serialize, Deserialize)]
struct AccessToken {
    sub: String,
    sid: String,
    ver: i64,
    iss: String,
    aud: String,
    iat: i64,
    exp: i64,
    jti: String,
}
/// Sign credentials containing identity/session references only.
///
/// # Errors
/// Returns a signing/configuration error.
pub fn issue_token_for_session(
    user_id: &str,
    _email: &str,
    _role: Role,
    _site_id: &str,
    _unit_id: Option<&str>,
    sid: &str,
    version: i64,
) -> Result<String, String> {
    let now = Utc::now().timestamp();
    let token = AccessToken {
        sub: user_id.to_string(),
        sid: sid.to_string(),
        ver: version,
        iss: issuer(),
        aud: audience(),
        iat: now,
        exp: now + TOKEN_TTL_SECONDS,
        jti: uuid::Uuid::new_v4().to_string(),
    };
    encode(
        &Header::new(Algorithm::HS256),
        &token,
        &EncodingKey::from_secret(jwt_secret()?),
    )
    .map_err(|_| "Token signing failed".to_string())
}
/// Validate the credential, then resolve authority from server-side storage.
///
/// # Errors
/// Returns a generic error for invalid or expired credentials.
pub fn verify_token(token: &str) -> Result<Claims, String> {
    let mut validation = Validation::new(Algorithm::HS256);
    validation.leeway = 30;
    validation.set_issuer(&[issuer()]);
    validation.set_audience(&[audience()]);
    validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
    let token = decode::<AccessToken>(token, &DecodingKey::from_secret(jwt_secret()?), &validation)
        .map_err(|_| "Invalid access token".to_string())?
        .claims;
    if token.sid.is_empty()
        || token.sub.is_empty()
        || token.jti.is_empty()
        || token.ver < 1
        || token.iat > Utc::now().timestamp() + 30
        || !matches!(token.exp.checked_sub(token.iat),Some(ttl) if (1..=TOKEN_TTL_SECONDS).contains(&ttl))
    {
        return Err("Invalid access token".to_string());
    }
    Ok(Claims {
        sub: token.sub,
        sid: token.sid,
        ver: token.ver,
        iss: token.iss,
        aud: token.aud,
        iat: token.iat,
        exp: token.exp,
        jti: token.jti,
        email: String::new(),
        site_id: String::new(),
        role: Role::HomeResident,
        unit_id: None,
    })
}

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------

pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| "Password hashing failed".to_string())
}

/// Verifies a password against a stored PHC-format argon2 hash. Any other stored
/// format (plaintext, placeholder prefixes, unsalted digests) never verifies.
pub fn verify_password(password: &str, stored_hash: &str) -> bool {
    match PasswordHash::new(stored_hash) {
        Ok(parsed) => Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

pub fn is_argon2_hash(stored: &str) -> bool {
    stored.starts_with("$argon2")
}

/// Recovers the plaintext hidden in a legacy placeholder "hash" so the boot-time
/// upgrade can re-hash it with argon2id. Returns `None` for real hashes.
pub fn legacy_plaintext(stored: &str) -> Option<String> {
    if is_argon2_hash(stored) {
        return None;
    }
    for prefix in ["argon2id_hash_placeholder:", "ARGON2_HASH_", "HASH_"] {
        if let Some(rest) = stored.strip_prefix(prefix) {
            return Some(rest.to_string());
        }
    }
    // An unsalted SHA-256 digest cannot be reversed; the account must be reset.
    if stored.len() == 64 && stored.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(stored.to_string())
}

pub fn validate_new_password(password: &str) -> Result<(), String> {
    if password.len() > 1024 {
        return Err("Password is too long".to_string());
    }
    if password.chars().count() < MIN_PASSWORD_LENGTH {
        return Err(format!(
            "Password must be at least {} characters.",
            MIN_PASSWORD_LENGTH
        ));
    }
    Ok(())
}

/// Passwords that are long enough for the length rule but appear in every breach list.
const COMMON_PASSWORDS: &[&str] = &[
    "1234567890",
    "12345678910",
    "0123456789",
    "1q2w3e4r5t",
    "qwertyuiop",
    "qwerty1234",
    "qwerty12345",
    "password12",
    "password123",
    "password1234",
    "passw0rd123",
    "1234567891",
    "abcdefghij",
    "abcd123456",
    "iloveyou12",
    "iloveyou123",
    "welcome123",
    "welcome1234",
    "administrator",
    "letmein1234",
    "changeme123",
    "sitepulse123",
    "sitepulse1234",
    "1111111111",
    "0000000000",
    "9876543210",
    "asdfghjkl1",
    "zxcvbnm123",
];

/// Rejects passwords that repeat the account's own identity or a well-known weak value.
///
/// # Errors
/// Returns a user-facing message when the password is unacceptable.
pub fn validate_password_for_account(
    password: &str,
    email: &str,
    full_name: &str,
) -> Result<(), String> {
    validate_new_password(password)?;
    let lower = password.trim().to_lowercase();
    let email = crate::domain::email::NormalizedEmail::normalize(email);
    let local = email.split('@').next().unwrap_or_default();
    let name = full_name.trim().to_lowercase();
    if lower == email
        || (!local.is_empty() && lower == local)
        || (!name.is_empty() && lower == name)
    {
        return Err("Password must not match your email or name.".to_string());
    }
    if COMMON_PASSWORDS.contains(&lower.as_str()) {
        return Err("Password is too common. Choose a less predictable one.".to_string());
    }
    Ok(())
}

/// Generates a random one-time password with the given prefix (e.g. `SP-`).
pub fn generate_temporary_password(prefix: &str) -> String {
    use rand::RngExt;
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    let mut part = || -> String {
        (0..5)
            .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
            .collect()
    };
    format!("{}{}-{}", prefix, part(), part())
}

/// Hex SHA-256 digest used to store one-time tokens without keeping them in clear text.
pub fn token_digest(token: &str) -> String {
    use sha2::Digest;
    hex::encode(Sha256::digest(token.as_bytes()))
}

// ---------------------------------------------------------------------------
// Webhook signatures
// ---------------------------------------------------------------------------

/// Environment variable holding the shared bank webhook secret.
pub const BANK_WEBHOOK_SECRET_ENV: &str = "SITEPULSE_BANK_WEBHOOK_SECRET";

/// Verifies `hex(HMAC-SHA256(secret, raw_body))` in constant time against the
/// secret configured in [`BANK_WEBHOOK_SECRET_ENV`]. A missing or empty secret
/// rejects every request. The cryptography lives in
/// [`crate::domain::fingerprint::verify_hmac_sha256_hex`], which takes the
/// secret as a parameter; this wrapper only resolves configuration.
///
/// No timestamp or replay window is enforced: redeliveries are handled by the
/// payload-hash idempotency claim, not by the signature.
pub fn verify_webhook_signature(raw_body: &[u8], signature_hex: Option<&str>) -> bool {
    let Ok(secret) = std::env::var(BANK_WEBHOOK_SECRET_ENV) else {
        return false;
    };
    let Some(sig) = signature_hex else {
        return false;
    };
    crate::domain::fingerprint::verify_hmac_sha256_hex(secret.as_bytes(), raw_body, sig)
}

pub fn sign_webhook_body(secret: &str, raw_body: &[u8]) -> String {
    crate::domain::fingerprint::hmac_sha256_hex(secret.as_bytes(), raw_body)
}

// ---------------------------------------------------------------------------
// Route policy
// ---------------------------------------------------------------------------

/// Two ids refer to the same entity. In-memory ids carry prefixes (`site-1`) while
/// PostgreSQL ids are bare integers (`1`), so compare their numeric forms too.
pub fn same_id(a: &str, b: &str) -> bool {
    let kind = |id: &str| {
        if id.starts_with("site-") {
            1
        } else if id.starts_with("unit-") || id.starts_with("d-") {
            2
        } else {
            0
        }
    };
    if kind(a) != 0 && kind(b) != 0 && kind(a) != kind(b) {
        return false;
    }
    if a == b {
        return true;
    }
    match (crate::db::parse_id_to_i64(a), crate::db::parse_id_to_i64(b)) {
        (Some(x), Some(y)) => x == y,
        _ => false,
    }
}

fn error(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({ "status": "ERROR", "message": message })),
    )
        .into_response()
}

async fn check_unit_access(state: &AppState, claims: &Claims, id: &str) -> Result<(), Response> {
    crate::authorization::unit(state, claims, id)
        .await
        .map_err(IntoResponse::into_response)
}
fn check_site_access(claims: &Claims, site: &str) -> Result<(), Response> {
    crate::authorization::SiteId::parse(site).map_err(IntoResponse::into_response)?;
    if crate::authorization::same_site(&claims.site_id, site) {
        Ok(())
    } else {
        Err(crate::authorization::SecurityError::NotFound.into_response())
    }
}

/// Returns the URI with `site_id` pinned to the caller's site: an explicit
/// value for another site is rejected, a missing value is filled in.
fn pin_query_site(uri: &Uri, claims: &Claims) -> Result<Uri, Response> {
    let query = uri.query().unwrap_or("");
    let mut pairs: Vec<(String, String)> = url_pairs(query);
    let is_site_key = |k: &str| k == "site_id" || k == "siteId";
    let mut has_site = false;
    for (k, v) in &pairs {
        if is_site_key(k) && !v.is_empty() {
            has_site = true;
            check_site_access(claims, v)?;
        }
    }
    if has_site || claims.site_id.is_empty() {
        return Ok(uri.clone());
    }
    // An empty `site_id=` counts as missing and is replaced by the caller's site.
    pairs.retain(|(k, _)| !is_site_key(k));
    pairs.push(("site_id".to_string(), claims.site_id.clone()));
    let new_query: Vec<String> = pairs
        .iter()
        .map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v)))
        .collect();
    let pq = format!("{}?{}", uri.path(), new_query.join("&"));
    let mut parts = uri.clone().into_parts();
    parts.path_and_query = Some(
        pq.parse()
            .map_err(|_| error(StatusCode::BAD_REQUEST, "Malformed query"))?,
    );
    Uri::from_parts(parts).map_err(|_| error(StatusCode::BAD_REQUEST, "Malformed query"))
}

fn url_pairs(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|s| !s.is_empty())
        .map(|kv| {
            let mut it = kv.splitn(2, '=');
            let k = decode_component(it.next().unwrap_or(""));
            let v = decode_component(it.next().unwrap_or(""));
            (k, v)
        })
        .collect()
}

fn decode_component(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                if let Some(b) = s
                    .get(i + 1..i + 3)
                    .and_then(|h| u8::from_str_radix(h, 16).ok())
                {
                    out.push(b);
                    i += 3;
                    continue;
                }
                out.push(b'%');
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn encode_component(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

/// Recursively checks tenant-identifying fields in a JSON body (including nested objects and arrays).
fn check_body_scope<'a>(
    state: &'a AppState,
    claims: &'a Claims,
    body: &'a serde_json::Value,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), Response>> + Send + 'a>> {
    Box::pin(async move {
        match body {
            serde_json::Value::Object(obj) => {
                for key in ["site_id", "siteId"] {
                    if let Some(v) = obj.get(key) {
                        let s = json_id(v);
                        if !s.is_empty() {
                            check_site_access(claims, &s)?;
                        }
                    }
                }
                for key in ["unit_id", "unitId", "matched_unit_id"] {
                    if let Some(v) = obj.get(key) {
                        let s = json_id(v);
                        if !s.is_empty() {
                            check_unit_access(state, claims, &s).await?;
                        }
                    }
                }
                for child in obj.values() {
                    check_body_scope(state, claims, child).await?;
                }
            }
            serde_json::Value::Array(arr) => {
                for item in arr {
                    check_body_scope(state, claims, item).await?;
                }
            }
            _ => {}
        }
        Ok(())
    })
}

fn json_id(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

pub fn bearer_token(req: &Request) -> Option<String> {
    let mut values = req.headers().get_all(header::AUTHORIZATION).iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    let mut words = value.split_ascii_whitespace();
    if !words.next()?.eq_ignore_ascii_case("Bearer") {
        return None;
    }
    let token = words.next()?;
    if words.next().is_some() || token.is_empty() {
        return None;
    }
    Some(token.to_string())
}

/// Limit expensive password operations independently of request concurrency.
///
/// # Errors
/// Returns an error if the worker semaphore is unavailable.
pub async fn password_permit() -> Result<tokio::sync::OwnedSemaphorePermit, String> {
    static LIMIT: OnceLock<std::sync::Arc<tokio::sync::Semaphore>> = OnceLock::new();
    LIMIT
        .get_or_init(|| std::sync::Arc::new(tokio::sync::Semaphore::new(4)))
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| "Password workers unavailable".to_string())
}
/// Hash a password outside asynchronous reactor threads.
///
/// # Errors
/// Propagates hashing and worker errors.
pub async fn hash_password_async(password: String) -> Result<String, String> {
    let permit = password_permit().await?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        hash_password(&password)
    })
    .await
    .map_err(|_| "Password worker unavailable".to_string())?
}
/// Verify a password outside asynchronous reactor threads.
///
/// # Errors
/// Propagates worker errors.
pub async fn verify_password_async(password: String, hash: String) -> Result<bool, String> {
    if password.len() > 1024 {
        return Ok(false);
    }
    let permit = password_permit().await?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        verify_password(&password, &hash)
    })
    .await
    .map_err(|_| "Password worker unavailable".to_string())
}

/// Requests per minute from one client address to the public routes.
const PUBLIC_PER_ADDRESS_LIMIT: u32 = 120;
/// Attempts per minute from one client against one account.
const ACCOUNT_ATTEMPTS_PER_CLIENT: u32 = 10;
/// Attempts per minute against one account from all clients together.
const ACCOUNT_ATTEMPTS_TOTAL: u32 = 60;
/// Circuit breaker for all public traffic; far above legitimate use.
const PUBLIC_GLOBAL_LIMIT: u32 = 6000;

/// Counts one request against every key; false when any limit is exceeded.
/// Counters live in process memory and reset with the process.
async fn throttle_allows(state: &AppState, mut keys: Vec<(String, u32)>) -> bool {
    keys.push(("global".to_string(), PUBLIC_GLOBAL_LIMIT));
    let mut store = state.security.lock().await;
    store
        .login_attempts
        .retain(|_, (at, _)| at.elapsed().as_secs() < 60);
    if store.login_attempts.len() > 50_000 {
        return false;
    }
    let mut allowed = true;
    for (key, max) in keys {
        let attempt = store
            .login_attempts
            .entry(key)
            .or_insert((std::time::Instant::now(), 0));
        attempt.1 += 1;
        if attempt.1 > max {
            allowed = false;
        }
    }
    allowed
}

/// Authentication, explicit route policy, current resource scope and audit identity.
pub async fn require_auth(State(state): State<AppState>, mut req: Request, next: Next) -> Response {
    use crate::authorization::{AuthzContext, RoutePolicy, SecurityError};
    let template = req
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(|p| p.as_str())
        .unwrap_or("")
        .to_string();
    let policy = crate::app::route_policy(req.method().as_str(), &template);
    let Some(policy) = policy else {
        return SecurityError::NotFound.into_response();
    };
    let mut audit = req
        .extensions()
        .get::<crate::audit::AuditContext>()
        .cloned()
        .unwrap_or(crate::audit::AuditContext {
            source_ip: None,
            user_agent: None,
            permissions: Vec::new(),
            support_grant_id: None,
            site_id: None,
            platform: false,
            development: false,
            request_id: uuid::Uuid::new_v4().to_string(),
            actor_kind: "ANONYMOUS".to_string(),
            actor_id: None,
            actor_role: None,
            session_id: None,
        });
    if matches!(policy, RoutePolicy::Public) {
        let client = audit
            .source_ip
            .clone()
            .unwrap_or_else(|| "unknown".to_string());
        let is_credential_route = template.starts_with("/api/v1/auth/")
            || template.contains("/register")
            || template.contains("/registration/submit/");
        let mut keys = vec![(format!("addr:{client}"), PUBLIC_PER_ADDRESS_LIMIT)];
        if is_credential_route {
            let (parts, body) = req.into_parts();
            let bytes = match to_bytes(body, 16384).await {
                Ok(b) => b,
                Err(_) => return SecurityError::BadRequest.into_response(),
            };
            let account = serde_json::from_slice::<serde_json::Value>(&bytes)
                .ok()
                .and_then(|v| {
                    v.get("email")
                        .and_then(|v| v.as_str())
                        .map(|s| s.trim().to_lowercase())
                        .or_else(|| {
                            v.get("refresh_token")
                                .and_then(|t| t.as_str())
                                .map(token_digest)
                        })
                })
                .unwrap_or_else(|| template.to_string());
            // The tight limit is per client and account, so one client cannot lock a
            // victim out; the loose per-account limit still bounds distributed guessing.
            keys.push((
                format!("client-account:{client}:{account}"),
                ACCOUNT_ATTEMPTS_PER_CLIENT,
            ));
            keys.push((format!("account:{account}"), ACCOUNT_ATTEMPTS_TOTAL));
            if !throttle_allows(&state, keys).await {
                return SecurityError::RateLimited.into_response();
            }
            req = Request::from_parts(parts, Body::from(bytes));
        } else if !throttle_allows(&state, keys).await {
            return SecurityError::RateLimited.into_response();
        }
        return crate::audit::CONTEXT.scope(audit, next.run(req)).await;
    }
    let Some(token) = bearer_token(&req) else {
        return SecurityError::Unauthenticated.into_response();
    };
    let claims = match verify_token(&token) {
        Ok(c) => c,
        Err(_) => return SecurityError::Unauthenticated.into_response(),
    };
    let (mut claims, must_change, stepped_up) =
        match crate::security::validate(&state, claims).await {
            Ok(c) => c,
            Err(e) => return e.into_response(),
        };
    crate::audit::identify(
        &claims.sub,
        claims.role.as_str(),
        &claims.sid,
        &claims.site_id,
    );
    if must_change
        && !matches!(
            template.as_str(),
            "/api/v1/auth/change-password"
                | "/api/v1/auth/me"
                | "/api/v1/auth/logout"
                | "/api/v1/auth/logout-all"
        )
    {
        return SecurityError::PasswordChange.into_response();
    }
    if template == "/api/v1/auth/link-google" && !stepped_up {
        return SecurityError::StepUp.into_response();
    }
    let mut permissions = crate::models::Permission::permissions_for_role(claims.role);
    if let Some(grant) = req.headers().get("x-sitepulse-support-grant") {
        if !claims.is_saas_admin() {
            return SecurityError::Forbidden.into_response();
        }
        let Ok(grant) = grant.to_str() else {
            return SecurityError::Forbidden.into_response();
        };
        let Some(pool) = &state.pool else {
            return SecurityError::Unavailable.into_response();
        };
        let client = match pool.get().await {
            Ok(c) => c,
            Err(_) => return SecurityError::Unavailable.into_response(),
        };
        let user = match crate::db::require_id("user", &claims.sub) {
            Ok(id) => id,
            Err(_) => return SecurityError::Unauthenticated.into_response(),
        };
        let row=match client.query_opt("SELECT g.site_id,g.permissions FROM support_grants g JOIN users approver ON approver.id=g.approved_by JOIN sites site ON site.id=g.site_id WHERE g.id=$1 AND g.operator_user_id=$2 AND g.approved_by<>g.operator_user_id AND approver.role='SAAS_ADMIN' AND approver.is_active AND g.revoked_at IS NULL AND g.expires_at>now() AND site.status IN ('ACTIVE','TRIAL') AND site.deleted_at IS NULL",&[&grant,&user]).await{Ok(Some(row))=>row,Ok(None)=>return SecurityError::Forbidden.into_response(),Err(_)=>return SecurityError::Unavailable.into_response()};
        claims.site_id = row.get::<_, i64>(0).to_string();
        audit.support_grant_id = Some(grant.to_string());
        permissions = row
            .get::<_, Vec<String>>(1)
            .into_iter()
            .filter_map(|s| {
                serde_json::from_value::<crate::models::Permission>(serde_json::Value::String(s))
                    .ok()
            })
            .collect();
    }
    let required = match policy {
        RoutePolicy::Require(permission) => Some(permission),
        RoutePolicy::RequireAny(options) => {
            let Some(permission) = options.iter().find(|p| permissions.contains(p)).copied() else {
                return SecurityError::Forbidden.into_response();
            };
            Some(permission)
        }
        _ => None,
    };
    if let Some(permission) = required {
        if !permissions.contains(&permission) {
            return SecurityError::Forbidden.into_response();
        }
        let sensitive = matches!(
            permission,
            crate::models::Permission::PaymentReverse
                | crate::models::Permission::SupportAccess
                | crate::models::Permission::RoleGrant
                | crate::models::Permission::PersonExport
                | crate::models::Permission::PersonIdentityManage
        ) || matches!(
            permission,
            crate::models::Permission::BankAccountManage
                | crate::models::Permission::PlatformIntegrationConfigure
        ) && req.method() != Method::GET
            || template.ends_with("/persons/:person_id/merge")
            || template.ends_with("/persons/{person_id}/merge")
            || template.ends_with("/transfer-ownership")
            || template.ends_with("/reset-admin-password")
            || template.ends_with("/platform-roles");
        if sensitive && !stepped_up {
            return SecurityError::StepUp.into_response();
        }
    }
    if matches!(policy, RoutePolicy::Development) && !claims.is_saas_admin() {
        return SecurityError::Forbidden.into_response();
    }
    audit.site_id = crate::authorization::SiteId::parse(&claims.site_id)
        .ok()
        .and_then(|_| crate::db::parse_id_to_i64(&claims.site_id).map(|s| s.to_string()));
    audit.permissions = permissions.clone();
    audit.platform = matches!(
        policy,
        RoutePolicy::Require(
            crate::models::Permission::TenantManage
                | crate::models::Permission::SupportAccess
                | crate::models::Permission::PlatformIntegrationConfigure
        )
    );
    audit.development = matches!(policy, RoutePolicy::Development);
    audit.actor_kind = "USER".to_string();
    audit.actor_id = Some(claims.sub.clone());
    audit.actor_role = Some(claims.role.as_str().to_string());
    audit.session_id = Some(claims.sid.clone());
    crate::audit::record_context(&audit);
    let context = AuthzContext {
        claims: claims.clone(),
        permissions,
        request_id: audit.request_id.clone(),
        stepped_up,
    };
    crate::audit::CONTEXT
        .scope(audit, async move {
            let result = scope_request(&state, &claims, &mut req, policy).await;
            if let Err(response) = result {
                return response;
            }
            req.extensions_mut().insert(claims);
            req.extensions_mut().insert(context);
            next.run(req).await
        })
        .await
}

async fn scope_request(
    state: &AppState,
    claims: &Claims,
    req: &mut Request,
    policy: crate::authorization::RoutePolicy,
) -> Result<(), Response> {
    use crate::authorization::{self, RoutePolicy};
    use crate::models::Permission;
    if matches!(
        policy,
        RoutePolicy::SelfOnly
            | RoutePolicy::Development
            | RoutePolicy::Require(
                Permission::TenantManage
                    | Permission::SupportAccess
                    | Permission::PlatformIntegrationConfigure
            )
    ) {
        return Ok(());
    }
    // Platform audit access is deliberately restricted to NULL-site events.
    if claims.is_saas_admin() && claims.site_id.is_empty() {
        if matches!(policy, RoutePolicy::Require(Permission::AuditLogRead)) {
            return Ok(());
        }
        return Err(authorization::SecurityError::Forbidden.into_response());
    }
    let path = req.uri().path().to_string();
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let template = req
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(|p| p.as_str())
        .unwrap_or("");
    if template.contains(":unit_id")
        || template.contains("{unit_id}")
        || template.starts_with("/api/v1/units/:id")
        || template.starts_with("/api/v1/units/{id}")
        || template.starts_with("/api/v1/site-admin/units/:id")
        || template.starts_with("/api/v1/site-admin/units/{id}")
        || template.starts_with("/api/v1/site-admin/home-owners/:id")
        || template.starts_with("/api/v1/site-admin/home-owners/{id}")
    {
        let idx = if matches!(parts.get(2), Some(&"site-admin" | &"home-residents")) {
            4
        } else {
            3
        };
        if let Some(id) = parts.get(idx) {
            // Household and payment-profile changes by residents need the unit's owner;
            // managers are scoped to their site by `check_unit_access`.
            if matches!(
                policy,
                RoutePolicy::Require(
                    Permission::UnitInviteCoResident | Permission::UnitManageHousehold
                )
            ) || matches!(
                policy,
                RoutePolicy::RequireAny(_)
                    | RoutePolicy::Require(Permission::UnitPaymentProfileManage)
            ) && matches!(claims.role, Role::HomeOwner | Role::HomeResident)
            {
                authorization::owned_unit(state, claims, id)
                    .await
                    .map_err(IntoResponse::into_response)?;
            } else {
                check_unit_access(state, claims, id).await?;
            }
        }
    }
    for (prefix, kind) in [
        ("/api/v1/registration/approve/", "registration"),
        ("/api/v1/registration/reject/", "registration"),
        ("/api/v1/capital-projects/", "project"),
        ("/api/v1/payments/receipts/", "receipt"),
        ("/api/v1/site-admin/house-types/", "house_type"),
    ] {
        if let Some(id) = path.strip_prefix(prefix).and_then(|p| p.split('/').next()) {
            authorization::resource(state, claims, kind, id)
                .await
                .map_err(IntoResponse::into_response)?;
        }
    }
    if let Some(site) = path.strip_prefix("/api/v1/site-admin/bank-account/") {
        check_site_access(claims, site)?;
    }
    for (key, value) in url_pairs(req.uri().query().unwrap_or("")) {
        if matches!(key.as_str(), "unit_id" | "unitId") && !value.is_empty() {
            check_unit_access(state, claims, &value).await?;
        }
    }
    *req.uri_mut() = pin_query_site(req.uri(), claims)?;
    if matches!(
        *req.method(),
        Method::POST | Method::PUT | Method::PATCH | Method::DELETE
    ) {
        let body = std::mem::replace(req.body_mut(), Body::empty());
        let bytes = to_bytes(body, MAX_INSPECTED_BODY_BYTES)
            .await
            .map_err(|_| error(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large"))?;
        if !bytes.is_empty() {
            let mut value: serde_json::Value = serde_json::from_slice(&bytes)
                .map_err(|_| error(StatusCode::BAD_REQUEST, "Invalid JSON body"))?;
            check_body_scope(state, claims, &value).await?;
            if let Some(id) = value.get("receipt").and_then(|v| v.as_str()) {
                authorization::resource(state, claims, "receipt", id)
                    .await
                    .map_err(IntoResponse::into_response)?;
            }
            if !matches!(policy, RoutePolicy::Require(Permission::RoleGrant)) {
                if let Some(obj) = value.as_object_mut() {
                    obj.entry("site_id")
                        .or_insert_with(|| serde_json::Value::String(claims.site_id.clone()));
                }
            }
            let bytes = serde_json::to_vec(&value)
                .map_err(|_| error(StatusCode::BAD_REQUEST, "Invalid body"))?;
            req.headers_mut().remove(header::CONTENT_LENGTH);
            *req.body_mut() = Body::from(bytes);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_round_trip_and_tamper_detection() {
        let t = issue_token(
            "usr-1",
            "a\"b@x.io",
            Role::HomeOwner,
            "site-1",
            Some("d-14"),
        )
        .expect("signed");
        let c = verify_token(&t).expect("valid");
        assert_eq!(c.sub, "usr-1");
        assert!(!c.sid.is_empty());
        let mut parts: Vec<&str> = t.split('.').collect();
        let forged = base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            r#"{"sub":"x","email":"x","role":"SAAS_ADMIN","site_id":"1","iat":0,"exp":9999999999}"#,
        );
        parts[1] = &forged;
        assert!(verify_token(&parts.join(".")).is_err());
    }

    #[test]
    fn passwords_only_verify_against_argon2() {
        let h = hash_password("correct horse battery").expect("hashed");
        assert!(verify_password("correct horse battery", &h));
        assert!(!verify_password("wrong", &h));
        assert!(!verify_password("admin123", "ARGON2_HASH_admin123"));
        assert!(!verify_password("admin123", "admin123"));
        assert_eq!(
            legacy_plaintext("ARGON2_HASH_admin123").as_deref(),
            Some("admin123")
        );
        assert_eq!(legacy_plaintext(&h), None);
    }

    #[test]
    fn webhook_signature() {
        std::env::set_var("SITEPULSE_BANK_WEBHOOK_SECRET", "unit-test-secret");
        let body = br#"{"amount":"10.00"}"#;
        let sig = sign_webhook_body("unit-test-secret", body);
        assert!(verify_webhook_signature(body, Some(&sig)));
        assert!(!verify_webhook_signature(b"tampered", Some(&sig)));
        assert!(!verify_webhook_signature(body, None));
    }

    #[test]
    fn query_decoding() {
        assert_eq!(decode_component("a%20b+c"), "a b c");
        assert_eq!(decode_component("100%"), "100%");
    }
}

#[cfg(test)]
mod password_policy_tests {
    use super::validate_password_for_account;

    #[test]
    fn rejects_identity_and_common_passwords() {
        assert!(
            validate_password_for_account("ayse.demir@x.com", "ayse.demir@x.com", "A").is_err()
        );
        assert!(
            validate_password_for_account("Ayse Demir Kaya", "a@x.com", "ayse demir kaya").is_err()
        );
        assert!(validate_password_for_account("Password123", "a@x.com", "A").is_err());
        assert!(validate_password_for_account("short", "a@x.com", "A").is_err());
        assert!(validate_password_for_account("tr1cky-Horse-staple", "a@x.com", "A").is_ok());
    }
}

#[cfg(test)]
mod throttle_tests {
    use super::*;

    fn keys(client: &str, account: &str) -> Vec<(String, u32)> {
        vec![
            (format!("addr:{client}"), PUBLIC_PER_ADDRESS_LIMIT),
            (
                format!("client-account:{client}:{account}"),
                ACCOUNT_ATTEMPTS_PER_CLIENT,
            ),
            (format!("account:{account}"), ACCOUNT_ATTEMPTS_TOTAL),
        ]
    }

    #[tokio::test]
    async fn one_client_cannot_lock_out_another_clients_account() {
        let state = AppState::new_empty();
        for _ in 0..ACCOUNT_ATTEMPTS_PER_CLIENT {
            assert!(throttle_allows(&state, keys("203.0.113.1", "victim@x.com")).await);
        }
        assert!(!throttle_allows(&state, keys("203.0.113.1", "victim@x.com")).await);
        assert!(throttle_allows(&state, keys("198.51.100.2", "victim@x.com")).await);
    }

    #[tokio::test]
    async fn varying_the_account_does_not_evade_the_address_limit() {
        let state = AppState::new_empty();
        for i in 0..PUBLIC_PER_ADDRESS_LIMIT {
            assert!(throttle_allows(&state, keys("203.0.113.1", &format!("u{i}@x.com"))).await);
        }
        assert!(!throttle_allows(&state, keys("203.0.113.1", "another@x.com")).await);
    }
}
