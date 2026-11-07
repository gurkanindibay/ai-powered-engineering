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

use argon2::password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
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
use hmac::{Hmac, Mac};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::models::Role;
use crate::state::AppState;

/// Access tokens live for 12 hours.
pub const TOKEN_TTL_SECONDS: i64 = 12 * 3600;
/// Minimum password length, applied to registration, change and reset alike.
pub const MIN_PASSWORD_LENGTH: usize = 10;
const MAX_INSPECTED_BODY_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Claims {
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
        matches!(self.role, Role::SiteManager | Role::SaasAdmin)
    }
}

// ---------------------------------------------------------------------------
// Secrets
// ---------------------------------------------------------------------------

fn jwt_secret() -> &'static [u8] {
    static SECRET: OnceLock<Vec<u8>> = OnceLock::new();
    SECRET.get_or_init(|| match std::env::var("SITEPULSE_JWT_SECRET") {
        Ok(s) if s.len() >= 32 => s.into_bytes(),
        Ok(_) => panic!("SITEPULSE_JWT_SECRET must be at least 32 characters long"),
        Err(_) => {
            if crate::state::AppStateInner::is_production() {
                panic!("SITEPULSE_JWT_SECRET is required in production");
            }
            tracing::warn!(
                "SITEPULSE_JWT_SECRET is not set; using a random per-process secret (tokens will not survive a restart)"
            );
            use rand::RngCore;
            let mut buf = vec![0u8; 48];
            rand::thread_rng().fill_bytes(&mut buf);
            buf
        }
    })
}

/// Fails fast at startup when required secrets are missing in production.
pub fn validate_configuration() {
    let _ = jwt_secret();
    if crate::state::AppStateInner::is_production() && std::env::var("SITEPULSE_BANK_WEBHOOK_SECRET").is_err() {
        panic!("SITEPULSE_BANK_WEBHOOK_SECRET is required in production");
    }
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

pub fn issue_token(user_id: &str, email: &str, role: Role, site_id: &str, unit_id: Option<&str>) -> String {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: user_id.to_string(),
        email: email.to_string(),
        role,
        site_id: site_id.to_string(),
        unit_id: unit_id.filter(|u| !u.is_empty()).map(str::to_string),
        iat: now,
        exp: now + TOKEN_TTL_SECONDS,
    };
    encode(&Header::new(Algorithm::HS256), &claims, &EncodingKey::from_secret(jwt_secret()))
        .expect("HS256 encoding of typed claims cannot fail")
}

pub fn verify_token(token: &str) -> Result<Claims, String> {
    let mut validation = Validation::new(Algorithm::HS256);
    validation.leeway = 30;
    decode::<Claims>(token, &DecodingKey::from_secret(jwt_secret()), &validation)
        .map(|d| d.claims)
        .map_err(|e| format!("Invalid access token: {}", e))
}

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------

pub fn hash_password(password: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .expect("argon2id hashing with a generated salt cannot fail")
        .to_string()
}

/// Verifies a password against a stored PHC-format argon2 hash. Any other stored
/// format (plaintext, placeholder prefixes, unsalted digests) never verifies.
pub fn verify_password(password: &str, stored_hash: &str) -> bool {
    match PasswordHash::new(stored_hash) {
        Ok(parsed) => Argon2::default().verify_password(password.as_bytes(), &parsed).is_ok(),
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
    if password.chars().count() < MIN_PASSWORD_LENGTH {
        return Err(format!("Password must be at least {} characters.", MIN_PASSWORD_LENGTH));
    }
    Ok(())
}

/// Generates a random one-time password with the given prefix (e.g. `SP-`).
pub fn generate_temporary_password(prefix: &str) -> String {
    use rand::Rng;
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    let mut part = || -> String {
        (0..5).map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char).collect()
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

/// Verifies `hex(HMAC-SHA256(secret, raw_body))` in constant time.
pub fn verify_webhook_signature(raw_body: &[u8], signature_hex: Option<&str>) -> bool {
    let secret = match std::env::var("SITEPULSE_BANK_WEBHOOK_SECRET") {
        Ok(s) if !s.is_empty() => s,
        _ => return false,
    };
    let Some(sig) = signature_hex else { return false };
    let Ok(sig_bytes) = hex::decode(sig.trim().trim_start_matches("sha256=")) else { return false };
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(raw_body);
    mac.verify_slice(&sig_bytes).is_ok()
}

pub fn sign_webhook_body(secret: &str, raw_body: &[u8]) -> String {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(raw_body);
    hex::encode(mac.finalize().into_bytes())
}

// ---------------------------------------------------------------------------
// Route policy
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Access {
    Public,
    Authenticated,
    SiteStaff,
    SaasAdmin,
}

fn route_access(method: &Method, path: &str) -> Access {
    let p = path.trim_end_matches('/');
    match p {
        "/health" | "/api/v1/health" => return Access::Public,
        "/api/v1/auth/login" | "/api/v1/auth/google" | "/api/v1/auth/register" => return Access::Public,
        "/api/v1/home-residents/register" => return Access::Public,
        // Authenticated by HMAC signature inside the handler, not by a user token.
        "/api/v1/bank/webhook/incoming-transfer" => return Access::Public,
        "/api/v1/site-admin/banks" => return Access::Public,
        _ => {}
    }
    if p.starts_with("/api/v1/registration/submit/") {
        return Access::Public;
    }
    if p.starts_with("/api/v1/saas/") || p == "/api/v1/saas" || p.starts_with("/api/v1/system/") {
        return Access::SaasAdmin;
    }
    if p == "/api/v1/bank/kuveyt-turk/configure" {
        return Access::SaasAdmin;
    }
    if p.starts_with("/api/v1/auth/") {
        return Access::Authenticated;
    }
    // Unit-scoped resident routes: residents reach only their own unit (checked below).
    if p.starts_with("/api/v1/residents/") || p.starts_with("/api/v1/units/") || p.starts_with("/api/v1/payments/receipts/") {
        return Access::Authenticated;
    }
    if p.starts_with("/api/v1/home-residents/") {
        return Access::Authenticated;
    }
    if p.starts_with("/api/v1/capital-projects") && *method == Method::GET {
        return Access::Authenticated;
    }
    Access::SiteStaff
}

/// Extracts the unit id a path refers to, for the unit-scoped route families.
fn path_unit_id(path: &str) -> Option<String> {
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    // ["api","v1",family,...]
    if segs.len() < 4 {
        return None;
    }
    match (segs[2], segs.get(3).copied()) {
        ("residents", Some(u)) => Some(u.to_string()),
        ("units", Some(u)) => Some(u.to_string()),
        ("home-residents", Some("invite-link")) | ("home-residents", Some("members")) => segs.get(4).map(|s| s.to_string()),
        ("site-admin", Some("units")) | ("site-admin", Some("home-owners")) => segs.get(4).map(|s| s.to_string()),
        _ => None,
    }
}

fn path_site_id(path: &str) -> Option<String> {
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    if segs.len() >= 5 && segs[2] == "site-admin" && segs[3] == "bank-account" {
        return Some(segs[4].to_string());
    }
    None
}

/// Two ids refer to the same entity. In-memory ids carry prefixes (`site-1`) while
/// PostgreSQL ids are bare integers (`1`), so compare their numeric forms too.
pub fn same_id(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let num = |s: &str| -> Option<i64> {
        let stripped = s.trim_start_matches("site-").trim_start_matches("d-").trim_start_matches("unit-");
        stripped.parse::<i64>().ok()
    };
    matches!((num(a), num(b)), (Some(x), Some(y)) if x == y)
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(serde_json::json!({ "status": "ERROR", "message": message }))).into_response()
}

async fn unit_site_id(state: &AppState, unit_id: &str) -> Option<String> {
    {
        let inner = state.inner.read().await;
        if let Some(u) = inner.units.iter().find(|u| same_id(&u.id, unit_id)) {
            return Some(u.site_id.clone());
        }
    }
    let pool = state.pool.as_ref()?;
    let id: i64 = unit_id.trim_start_matches("d-").parse().ok()?;
    let client = pool.get().await.ok()?;
    let row = client.query_opt("SELECT site_id FROM units WHERE id = $1", &[&id]).await.ok()??;
    row.get::<_, Option<i64>>(0).map(|s| s.to_string())
}

async fn check_unit_access(state: &AppState, claims: &Claims, unit_id: &str) -> Result<(), Response> {
    if claims.is_saas_admin() {
        return Ok(());
    }
    if claims.role == Role::SiteManager {
        return match unit_site_id(state, unit_id).await {
            Some(site) if same_id(&site, &claims.site_id) => Ok(()),
            Some(_) => Err(error(StatusCode::FORBIDDEN, "Unit belongs to another site")),
            None => Err(error(StatusCode::NOT_FOUND, "Unit not found")),
        };
    }
    match &claims.unit_id {
        Some(own) if same_id(own, unit_id) => Ok(()),
        _ => Err(error(StatusCode::FORBIDDEN, "You may only access your own unit")),
    }
}

fn check_site_access(claims: &Claims, site_id: &str) -> Result<(), Response> {
    if claims.is_saas_admin() || same_id(site_id, &claims.site_id) {
        Ok(())
    } else {
        Err(error(StatusCode::FORBIDDEN, "Site belongs to another tenant"))
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
    if has_site || claims.is_saas_admin() || claims.site_id.is_empty() {
        return Ok(uri.clone());
    }
    // An empty `site_id=` counts as missing and is replaced by the caller's site.
    pairs.retain(|(k, _)| !is_site_key(k));
    pairs.push(("site_id".to_string(), claims.site_id.clone()));
    let new_query: Vec<String> = pairs.iter().map(|(k, v)| format!("{}={}", encode_component(k), encode_component(v))).collect();
    let pq = format!("{}?{}", uri.path(), new_query.join("&"));
    let mut parts = uri.clone().into_parts();
    parts.path_and_query = Some(pq.parse().map_err(|_| error(StatusCode::BAD_REQUEST, "Malformed query"))?);
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
                if let Some(b) = s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok()) {
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

/// Checks tenant-identifying fields in a JSON body (top level only).
async fn check_body_scope(state: &AppState, claims: &Claims, body: &serde_json::Value) -> Result<(), Response> {
    let Some(obj) = body.as_object() else { return Ok(()) };
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
    Ok(())
}

fn json_id(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

pub fn bearer_token(req: &Request) -> Option<String> {
    let value = req.headers().get(header::AUTHORIZATION)?.to_str().ok()?;
    let token = value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer "))?;
    Some(token.trim().to_string())
}

/// Axum middleware applied to the whole router.
pub async fn require_auth(State(state): State<AppState>, req: Request, next: Next) -> Response {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let access = route_access(&method, &path);
    if access == Access::Public || method == Method::OPTIONS {
        return next.run(req).await;
    }

    let Some(token) = bearer_token(&req) else {
        return error(StatusCode::UNAUTHORIZED, "Missing bearer token");
    };
    let claims = match verify_token(&token) {
        Ok(c) => c,
        Err(e) => return error(StatusCode::UNAUTHORIZED, &e),
    };

    let allowed = match access {
        Access::Public | Access::Authenticated => true,
        Access::SiteStaff => claims.is_site_staff(),
        Access::SaasAdmin => claims.is_saas_admin(),
    };
    if !allowed {
        return error(StatusCode::FORBIDDEN, "Your role is not allowed to use this endpoint");
    }

    if let Some(unit) = path_unit_id(&path) {
        if let Err(resp) = check_unit_access(&state, &claims, &unit).await {
            return resp;
        }
    }
    if let Some(site) = path_site_id(&path) {
        if let Err(resp) = check_site_access(&claims, &site) {
            return resp;
        }
    }

    let (mut parts, body) = req.into_parts();
    match pin_query_site(&parts.uri, &claims) {
        Ok(uri) => parts.uri = uri,
        Err(resp) => return resp,
    }

    let body = if matches!(method, Method::POST | Method::PUT | Method::PATCH) && !claims.is_saas_admin() {
        let bytes = match to_bytes(body, MAX_INSPECTED_BODY_BYTES).await {
            Ok(b) => b,
            Err(_) => return error(StatusCode::PAYLOAD_TOO_LARGE, "Request body too large"),
        };
        match serde_json::from_slice::<serde_json::Value>(&bytes) {
            Ok(mut value) => {
                if let Err(resp) = check_body_scope(&state, &claims, &value).await {
                    return resp;
                }
                // Pin a missing site to the caller's own site, as for the query string.
                if let Some(obj) = value.as_object_mut() {
                    let has_site = obj.get("site_id").map(|v| !json_id(v).is_empty()).unwrap_or(false)
                        || obj.get("siteId").map(|v| !json_id(v).is_empty()).unwrap_or(false);
                    if !has_site && !claims.site_id.is_empty() {
                        obj.insert("site_id".to_string(), serde_json::Value::String(claims.site_id.clone()));
                        match serde_json::to_vec(&value) {
                            Ok(v) => {
                                parts.headers.remove(header::CONTENT_LENGTH);
                                Body::from(v)
                            }
                            Err(_) => Body::from(bytes),
                        }
                    } else {
                        Body::from(bytes)
                    }
                } else {
                    Body::from(bytes)
                }
            }
            Err(_) => Body::from(bytes),
        }
    } else {
        body
    };

    parts.extensions.insert(claims);
    next.run(Request::from_parts(parts, body)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_round_trip_and_tamper_detection() {
        let t = issue_token("usr-1", "a\"b@x.io", Role::HomeOwner, "site-1", Some("d-14"));
        let c = verify_token(&t).expect("valid");
        assert_eq!(c.email, "a\"b@x.io");
        assert_eq!(c.role, Role::HomeOwner);
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
        let h = hash_password("correct horse battery");
        assert!(verify_password("correct horse battery", &h));
        assert!(!verify_password("wrong", &h));
        assert!(!verify_password("admin123", "ARGON2_HASH_admin123"));
        assert!(!verify_password("admin123", "admin123"));
        assert_eq!(legacy_plaintext("ARGON2_HASH_admin123").as_deref(), Some("admin123"));
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
