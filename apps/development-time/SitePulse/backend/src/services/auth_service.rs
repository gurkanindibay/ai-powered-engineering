use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Utc;
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use serde::Deserialize;

use crate::auth;
use crate::models::{
    AuthResponse, ChangePasswordRequest, GoogleLoginRequest, PasswordLoginRequest, Permission, RegisterUserRequest,
    Role, User, UserProfileResponse, UserSummary,
};
use crate::state::AppState;

const INVALID_CREDENTIALS: &str = "Invalid email or password (kullanıcı adı veya şifre hatalı).";
const GOOGLE_JWKS_URL: &str = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_ISSUERS: [&str; 2] = ["accounts.google.com", "https://accounts.google.com"];

pub struct AuthService {
    state: AppState,
}

/// Site and unit a unit-invite token grants.
struct InviteScope {
    site_id: String,
    unit_id: String,
}

impl AuthService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    async fn find_user_by_email(&self, email_norm: &str) -> Result<Option<User>, String> {
        if let Some(ref pool) = self.state.pool {
            if let Some(u) = crate::db::get_user_by_email(pool, email_norm).await.map_err(|e| e.to_string())? {
                return Ok(Some(u));
            }
        }
        let inner = self.state.inner.read().await;
        Ok(inner.users.iter().find(|u| u.email.to_lowercase() == email_norm).cloned())
    }

    /// Resolves the unit a resident belongs to. Returns `None` rather than guessing.
    async fn resolve_unit_id(&self, user: &User) -> Option<String> {
        {
            let inner = self.state.inner.read().await;
            if let Some(u) = inner.units.iter().find(|un| {
                (un.site_id == user.site_id || crate::auth::same_id(&un.site_id, &user.site_id))
                    && (un.owner_user_id.as_deref() == Some(&user.id) || un.tenant_user_id.as_deref() == Some(&user.id))
            }) {
                return Some(u.id.clone());
            }
            for (unit_id, members) in inner.unit_members.iter() {
                if members.iter().any(|m| {
                    m.email.eq_ignore_ascii_case(&user.email)
                }) {
                    if let Some(u) = inner.units.iter().find(|u| &u.id == unit_id || crate::auth::same_id(&u.id, unit_id)) {
                        if !crate::auth::same_id(&u.site_id, &user.site_id) {
                            continue;
                        }
                    }
                    return Some(unit_id.clone());
                }
            }
        }
        let pool = self.state.pool.as_ref()?;
        let client = pool.get().await.ok()?;
        let email = user.email.to_lowercase();
        let site_id_num = crate::db::parse_id_to_i64(&user.site_id);

        let row = if let Some(sid) = site_id_num {
            client
                .query_opt(
                    r#"
                    SELECT u.id FROM units u
                    LEFT JOIN persons op ON u.owner_person_id = op.id
                    LEFT JOIN persons tp ON u.tenant_person_id = tp.id
                    WHERE (LOWER(op.email) = $1 OR LOWER(tp.email) = $1)
                      AND u.site_id = $2
                    ORDER BY u.id
                    LIMIT 1
                    "#,
                    &[&email, &sid],
                )
                .await
                .ok()??
        } else {
            client
                .query_opt(
                    r#"
                    SELECT u.id FROM units u
                    LEFT JOIN persons op ON u.owner_person_id = op.id
                    LEFT JOIN persons tp ON u.tenant_person_id = tp.id
                    WHERE LOWER(op.email) = $1 OR LOWER(tp.email) = $1
                    ORDER BY u.id
                    LIMIT 1
                    "#,
                    &[&email],
                )
                .await
                .ok()??
        };
        Some(row.get::<_, i64>(0).to_string())
    }

    /// Users of a deleted or suspended site cannot sign in.
    async fn ensure_site_active(&self, user: &User) -> Result<(), String> {
        if user.role == Role::SaasAdmin || user.site_id.is_empty() {
            return Ok(());
        }
        if let Some(ref pool) = self.state.pool {
            if !crate::db::site_is_active(pool, &user.site_id).await.map_err(|e| e.to_string())? {
                return Err("This site is no longer active.".to_string());
            }
        }
        Ok(())
    }

    async fn auth_response(&self, user: &User) -> AuthResponse {
        let unit_id = match user.role {
            Role::HomeOwner | Role::HomeResident => self.resolve_unit_id(user).await,
            _ => None,
        };
        create_auth_response(user, unit_id.as_deref())
    }

    /// Consumes a unit invite token: it must exist and be unexpired, and it is
    /// removed so that it cannot be replayed.
    async fn consume_invite_token(&self, raw_token: &str) -> Result<InviteScope, String> {
        let digest = auth::token_digest(raw_token);
        let token = digest.as_str();
        let mut inner = self.state.inner.write().await;
        let invite = inner
            .unit_invite_tokens
            .get(token)
            .cloned()
            .ok_or_else(|| "Invitation token is invalid or has already been used.".to_string())?;
        if invite.expires_at < Utc::now() {
            inner.unit_invite_tokens.remove(token);
            return Err("Invitation token has expired.".to_string());
        }
        let site_id = inner
            .units
            .iter()
            .find(|u| auth::same_id(&u.id, &invite.unit_id))
            .map(|u| u.site_id.clone())
            .ok_or_else(|| "The invited unit no longer exists.".to_string())?;
        inner.unit_invite_tokens.remove(token);
        drop(inner);
        if let Some(ref pool) = self.state.pool {
            crate::db::delete_invitation_token(pool, token).await.map_err(|e| e.to_string())?;
        }
        Ok(InviteScope { site_id, unit_id: invite.unit_id })
    }

    pub async fn authenticate_with_password(&self, request: PasswordLoginRequest) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty() || request.password.is_empty() {
            return Err("Email and password are required.".to_string());
        }
        let email_norm = request.email.trim().to_lowercase();
        let user = self.find_user_by_email(&email_norm).await?.ok_or_else(|| INVALID_CREDENTIALS.to_string())?;

        let stored = user
            .password_hash
            .as_deref()
            .ok_or_else(|| "This account was created with Google. Please use 'Sign in with Google'.".to_string())?;
        if !auth::verify_password(&request.password, stored) {
            return Err(INVALID_CREDENTIALS.to_string());
        }
        self.ensure_site_active(&user).await?;
        Ok(self.auth_response(&user).await)
    }

    pub async fn authenticate_with_google(&self, request: GoogleLoginRequest) -> Result<AuthResponse, String> {
        if request.id_token.trim().is_empty() {
            return Err("Invalid Google ID Token.".to_string());
        }
        let payload = verify_google_id_token(&request.id_token).await?;
        if !payload.email_verified {
            return Err("Google account email is not verified.".to_string());
        }
        let email_norm = payload.email.to_lowercase();

        let existing = {
            let inner = self.state.inner.read().await;
            inner
                .users
                .iter()
                .position(|u| u.google_sub.as_deref() == Some(&payload.sub))
                .or_else(|| inner.users.iter().position(|u| u.email.to_lowercase() == email_norm))
        };

        let user = if let Some(idx) = existing {
            let mut inner = self.state.inner.write().await;
            let u = &mut inner.users[idx];
            if let Some(ref linked) = u.google_sub {
                if linked != &payload.sub {
                    return Err("This email is linked to a different Google account.".to_string());
                }
            }
            if u.google_sub.is_none() && u.role == Role::SaasAdmin {
                return Err("Platform administrator accounts cannot be linked to Google sign-in.".to_string());
            }
            u.google_sub = Some(payload.sub.clone());
            if !payload.picture.is_empty() {
                u.avatar_url = Some(payload.picture.clone());
            }
            u.auth_provider = if u.password_hash.is_some() { "HYBRID" } else { "GOOGLE" }.to_string();
            u.clone()
        } else {
            // A brand-new account must come through a unit invitation; otherwise
            // there is no tenant to place it in.
            let token = request
                .unit_invite_token
                .as_deref()
                .filter(|t| !t.trim().is_empty())
                .ok_or_else(|| "No account exists for this Google identity. Ask your site manager for an invitation link.".to_string())?;
            let scope = self.consume_invite_token(token.trim()).await?;
            let next_user_id = {
                let inner = self.state.inner.read().await;
                let max_u = inner.users.iter().filter_map(|u| crate::db::parse_id_to_i64(&u.id)).max().unwrap_or(0);
                (max_u + 1).to_string()
            };
            let new_user = User {
                id: next_user_id,
                site_id: scope.site_id,
                full_name: payload.name.clone(),
                email: email_norm.clone(),
                phone: String::new(),
                password_hash: None,
                role: Role::HomeResident,
                must_change_password: false,
                auth_provider: "GOOGLE".to_string(),
                google_sub: Some(payload.sub.clone()),
                avatar_url: Some(payload.picture.clone()),
                created_at: Utc::now(),
                person_id: None,
            };
            let mut inner = self.state.inner.write().await;
            inner.users.push(new_user.clone());
            attach_member(&mut inner, &scope.unit_id, &new_user);
            new_user
        };

        let mut user = user;
        self.ensure_site_active(&user).await?;
        if let Some(ref pool) = self.state.pool {
            crate::db::save_user(pool, &user).await.map_err(|e| format!("Failed to persist user: {}", e))?;
            if let Ok(client) = pool.get().await {
                if let Ok(Some(row)) = client.query_opt("SELECT id FROM users WHERE LOWER(email) = $1", &[&user.email.to_lowercase()]).await {
                    let db_id: i64 = row.get("id");
                    user.id = db_id.to_string();
                }
            }
        }
        Ok(self.auth_response(&user).await)
    }

    /// Self-service registration is only possible with a unit invitation token,
    /// which fixes the new account's site and unit.
    pub async fn register_with_password(&self, request: RegisterUserRequest) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty() || request.password.is_empty() || request.full_name.trim().is_empty() {
            return Err("Full name, email, and password are required.".to_string());
        }
        auth::validate_new_password(&request.password)?;
        let email_norm = request.email.trim().to_lowercase();
        if self.find_user_by_email(&email_norm).await?.is_some() {
            return Err("An account with this email address already exists (zaten mevcut).".to_string());
        }
        let token = request
            .unit_invite_token
            .as_deref()
            .filter(|t| !t.trim().is_empty())
            .ok_or_else(|| "An invitation token from your site manager is required to register.".to_string())?;
        let scope = self.consume_invite_token(token.trim()).await?;

        let next_user_id = {
            let inner = self.state.inner.read().await;
            let max_u = inner.users.iter().filter_map(|u| crate::db::parse_id_to_i64(&u.id)).max().unwrap_or(0);
            (max_u + 1).to_string()
        };

        let mut new_user = User {
            id: next_user_id,
            site_id: scope.site_id,
            full_name: request.full_name.trim().to_string(),
            email: email_norm,
            phone: request.phone.unwrap_or_default(),
            password_hash: Some(auth::hash_password(&request.password)),
            role: Role::HomeResident,
            must_change_password: false,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: None,
        };
        {
            let mut inner = self.state.inner.write().await;
            inner.users.push(new_user.clone());
            attach_member(&mut inner, &scope.unit_id, &new_user);
        }
        if let Some(ref pool) = self.state.pool {
            crate::db::save_user(pool, &new_user).await.map_err(|e| format!("Failed to persist user: {}", e))?;
            if let Ok(client) = pool.get().await {
                if let Ok(Some(row)) = client.query_opt("SELECT id FROM users WHERE LOWER(email) = $1", &[&new_user.email.to_lowercase()]).await {
                    let db_id: i64 = row.get("id");
                    new_user.id = db_id.to_string();
                }
            }
        }
        Ok(self.auth_response(&new_user).await)
    }

    pub async fn get_current_profile(&self, user_id: &str) -> Result<UserProfileResponse, String> {
        let in_memory = {
            let inner = self.state.inner.read().await;
            inner.users.iter().find(|u| u.id == user_id).cloned()
        };
        let user = match in_memory {
            Some(u) => u,
            None => match self.state.pool {
                Some(ref pool) => crate::db::get_user_by_id(pool, user_id)
                    .await
                    .map_err(|e| e.to_string())?
                    .ok_or_else(|| "User not found".to_string())?,
                None => return Err("User not found".to_string()),
            },
        };
        let unit_id = match user.role {
            Role::HomeOwner | Role::HomeResident => self.resolve_unit_id(&user).await.unwrap_or_default(),
            _ => String::new(),
        };
        let permissions = Permission::permissions_for_role(user.role);
        let descriptions = permissions.iter().map(|p| format!("{:?}: {}", p, p.description())).collect();
        Ok(UserProfileResponse {
            id: user.id.clone(),
            full_name: user.full_name.clone(),
            email: user.email.clone(),
            phone: user.phone.clone(),
            role: user.role,
            site_id: user.site_id.clone(),
            unit_id,
            avatar_url: user.avatar_url.clone(),
            auth_provider: user.auth_provider.clone(),
            must_change_password: user.must_change_password,
            permissions,
            permission_descriptions: descriptions,
        })
    }

    pub async fn change_password(&self, request: ChangePasswordRequest) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty() || request.current_password.is_empty() || request.new_password.is_empty() {
            return Err("Email, current password, and new password are required.".to_string());
        }
        auth::validate_new_password(&request.new_password)?;

        let email_norm = request.email.trim().to_lowercase();
        // The same message for "no such user" and "wrong password" avoids user enumeration.
        let user = self.find_user_by_email(&email_norm).await?.ok_or_else(|| INVALID_CREDENTIALS.to_string())?;
        let stored = user.password_hash.as_deref().ok_or_else(|| INVALID_CREDENTIALS.to_string())?;
        if !auth::verify_password(&request.current_password, stored) {
            return Err(INVALID_CREDENTIALS.to_string());
        }
        if request.new_password == request.current_password {
            return Err("The new password must differ from the current one.".to_string());
        }

        let new_hash = auth::hash_password(&request.new_password);
        if let Some(ref pool) = self.state.pool {
            let client = pool.get().await.map_err(|e| e.to_string())?;
            client
                .execute(
                    "UPDATE users SET password_hash = $1, must_change_password = false WHERE LOWER(email) = $2",
                    &[&new_hash, &email_norm],
                )
                .await
                .map_err(|e| format!("Failed to persist new password: {}", e))?;
        }
        {
            let mut inner = self.state.inner.write().await;
            if let Some(u) = inner.users.iter_mut().find(|u| u.email.to_lowercase() == email_norm) {
                u.password_hash = Some(new_hash.clone());
                u.must_change_password = false;
            }
        }
        let mut updated = user;
        updated.password_hash = Some(new_hash);
        updated.must_change_password = false;
        Ok(self.auth_response(&updated).await)
    }
}

/// Re-exported for callers that previously used the service-level helper.
pub fn hash_password(password: &str) -> String {
    auth::hash_password(password)
}

fn attach_member(inner: &mut crate::state::AppStateInner, unit_id: &str, user: &User) {
    inner.unit_members.entry(unit_id.to_string()).or_default().push(crate::models::UnitMemberDto {
        resident_id: user.id.clone(),
        full_name: user.full_name.clone(),
        relationship: "Ev Sakini".to_string(),
        phone: user.phone.clone(),
        email: user.email.clone(),
        is_owner: false,
        occupancy_id: None,
        person_id: user.person_id,
        resident_user_id: None,
    });
}

fn create_auth_response(user: &User, unit_id: Option<&str>) -> AuthResponse {
    let permissions = Permission::permissions_for_role(user.role);
    let summary = UserSummary {
        id: user.id.clone(),
        // Accounts without a linked person (e.g. a seeded admin) have no name yet.
        full_name: if user.full_name.trim().is_empty() { user.email.clone() } else { user.full_name.clone() },
        email: user.email.clone(),
        phone: user.phone.clone(),
        role: user.role,
        site_id: user.site_id.clone(),
        unit_id: unit_id.unwrap_or_default().to_string(),
        avatar_url: user.avatar_url.clone(),
        auth_provider: user.auth_provider.clone(),
        must_change_password: user.must_change_password,
        permissions,
    };
    let token = auth::issue_token(&user.id, &user.email, user.role, &user.site_id, unit_id);
    AuthResponse {
        access_token: token,
        token_type: "Bearer".to_string(),
        expires_in: auth::TOKEN_TTL_SECONDS,
        user: summary,
    }
}

#[derive(Debug, Deserialize)]
struct GoogleTokenPayload {
    sub: String,
    email: String,
    #[serde(default)]
    email_verified: bool,
    #[serde(default)]
    name: String,
    #[serde(default)]
    picture: String,
}

fn mock_google_tokens_allowed() -> bool {
    !crate::state::AppStateInner::is_production()
        && std::env::var("SITEPULSE_ALLOW_MOCK_GOOGLE_TOKENS").map(|v| v == "true").unwrap_or(false)
}

async fn google_jwks() -> Result<JwkSet, String> {
    static CACHE: Mutex<Option<(Instant, JwkSet)>> = Mutex::new(None);
    if let Some((at, set)) = CACHE.lock().unwrap().as_ref() {
        if at.elapsed() < Duration::from_secs(3600) {
            return Ok(set.clone());
        }
    }
    let set: JwkSet = reqwest::get(GOOGLE_JWKS_URL)
        .await
        .map_err(|e| format!("Could not fetch Google signing keys: {}", e))?
        .json()
        .await
        .map_err(|e| format!("Invalid Google signing keys: {}", e))?;
    *CACHE.lock().unwrap() = Some((Instant::now(), set.clone()));
    Ok(set)
}

/// Verifies a Google ID token's RS256 signature against Google's published keys
/// and checks issuer, audience (`GOOGLE_CLIENT_ID`) and expiry.
async fn verify_google_id_token(id_token: &str) -> Result<GoogleTokenPayload, String> {
    if let Some(rest) = id_token.strip_prefix("mock-google-token:") {
        if !mock_google_tokens_allowed() {
            return Err("Invalid Google ID Token.".to_string());
        }
        let parts: Vec<&str> = rest.split(':').collect();
        return match (parts.first(), parts.get(1)) {
            (Some(sub), Some(email)) if !sub.is_empty() && email.contains('@') => Ok(GoogleTokenPayload {
                sub: sub.to_string(),
                email: email.to_string(),
                email_verified: true,
                name: parts.get(2).unwrap_or(&"Google User").to_string(),
                picture: String::new(),
            }),
            _ => Err("Invalid Google ID Token.".to_string()),
        };
    }

    let client_id = std::env::var("GOOGLE_CLIENT_ID").map_err(|_| "Google sign-in is not configured on this server.".to_string())?;
    let header = decode_header(id_token).map_err(|_| "Invalid Google ID Token.".to_string())?;
    let kid = header.kid.ok_or_else(|| "Invalid Google ID Token.".to_string())?;
    let jwks = google_jwks().await?;
    let jwk = jwks.find(&kid).ok_or_else(|| "Google ID Token signed with an unknown key.".to_string())?;
    let key = DecodingKey::from_jwk(jwk).map_err(|_| "Invalid Google signing key.".to_string())?;
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&[client_id]);
    validation.set_issuer(&GOOGLE_ISSUERS);
    decode::<GoogleTokenPayload>(id_token, &key, &validation)
        .map(|d| d.claims)
        .map_err(|e| format!("Invalid Google ID Token: {}", e))
}
