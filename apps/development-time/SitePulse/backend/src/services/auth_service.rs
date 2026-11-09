use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::Utc;
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use serde::Deserialize;

use crate::auth;
use crate::models::{
    AuthProvider, AuthResponse, ChangePasswordRequest, GoogleLoginRequest, PasswordLoginRequest,
    Permission, RegisterUserRequest, Role, User, UserProfileResponse, UserSummary,
};
use crate::state::AppState;

const INVALID_CREDENTIALS: &str = "Invalid email or password (kullanıcı adı veya şifre hatalı).";
const GOOGLE_JWKS_URL: &str = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_ISSUERS: [&str; 2] = ["accounts.google.com", "https://accounts.google.com"];

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct IdentityError(String);

type IdentityResult<T> = Result<T, IdentityError>;

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

    async fn find_user_by_email(&self, email_norm: &str) -> IdentityResult<Option<User>> {
        async {
            if let Some(ref pool) = self.state.pool {
                return crate::db::get_user_by_email(pool, email_norm)
                    .await
                    .map_err(|_| "Identity storage unavailable".to_string());
            }
            let inner = self.state.inner.read().await;
            Ok(inner
                .users
                .iter()
                .find(|u| crate::domain::email::same_email(&u.email, email_norm))
                .cloned())
        }
        .await
        .map_err(IdentityError)
    }

    /// Resolve a current unit from authoritative relationships.
    ///
    /// # Errors
    /// Propagates database failures instead of granting cached access.
    pub async fn resolve_unit_id(&self, user: &User) -> IdentityResult<Option<String>> {
        async {
        if !matches!(user.role, Role::HomeOwner | Role::HomeResident) {
            return Ok(None);
        }
        if let Some(client) = crate::db::security_connection(&self.state).await.map_err(|e| e.to_string())? {
            let site = crate::db::require_id("site", &user.site_id)?;
            let row=client.query_opt("SELECT u.id FROM units u WHERE u.site_id=$1 AND u.deleted_at IS NULL AND (u.owner_person_id=$2 OR u.tenant_person_id=$2 OR EXISTS(SELECT 1 FROM occupancy_members m JOIN unit_occupancies o ON o.id=m.occupancy_id WHERE o.unit_id=u.id AND o.is_active AND o.end_date IS NULL AND m.person_id=$2)) ORDER BY u.id LIMIT 1",&[&site,&user.person_id]).await.map_err(|_|"Identity storage unavailable".to_string())?;
            return Ok(row.map(|r| r.get::<_, i64>(0).to_string()));
        }
        let inner = self.state.inner.read().await;
        Ok(inner
            .units
            .iter()
            .find(|u| {
                crate::authorization::same_site(&u.site_id, &user.site_id)
                    && (u.owner_user_id.as_deref() == Some(&user.id)
                        || u.tenant_user_id.as_deref() == Some(&user.id)
                        || inner.unit_members.get(&u.id).is_some_and(|members| {
                            members
                                .iter()
                                .any(|m| m.email.eq_ignore_ascii_case(&user.email))
                        }))
            })
            .map(|u| u.id.clone()))
        }.await.map_err(IdentityError)
    }

    /// Users of a deleted or suspended site cannot sign in.
    async fn ensure_site_active(&self, user: &User) -> IdentityResult<()> {
        async {
            if user.role == Role::SaasAdmin || user.site_id.is_empty() {
                return Ok(());
            }
            if let Some(ref pool) = self.state.pool {
                if !crate::db::site_is_active(pool, &user.site_id)
                    .await
                    .map_err(|e| e.to_string())?
                {
                    return Err("This site is no longer active.".to_string());
                }
            }
            Ok(())
        }
        .await
        .map_err(IdentityError)
    }

    async fn auth_response(&self, user: &User) -> IdentityResult<AuthResponse> {
        async {
            let unit_id = match user.role {
                Role::HomeOwner | Role::HomeResident => self
                    .resolve_unit_id(user)
                    .await
                    .map_err(|e| e.to_string())?,
                _ => None,
            };
            let credentials = crate::security::create(&self.state, user, unit_id.as_deref())
                .await
                .map_err(|e| e.to_string())?;
            Ok(create_auth_response(user, unit_id.as_deref(), credentials))
        }
        .await
        .map_err(IdentityError)
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
            crate::db::delete_invitation_token(pool, token)
                .await
                .map_err(|e| e.to_string())?;
        }
        Ok(InviteScope {
            site_id,
            unit_id: invite.unit_id,
        })
    }

    pub async fn authenticate_with_password(
        &self,
        request: PasswordLoginRequest,
    ) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty() || request.password.is_empty() {
            return Err("Email and password are required.".to_string());
        }
        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);
        let user = self
            .find_user_by_email(&email_norm)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| INVALID_CREDENTIALS.to_string())?;

        let stored = user
            .password_hash
            .as_deref()
            .ok_or_else(|| INVALID_CREDENTIALS.to_string())?;
        if !auth::verify_password_async(request.password.clone(), stored.to_string()).await? {
            return Err(INVALID_CREDENTIALS.to_string());
        }
        self.ensure_site_active(&user)
            .await
            .map_err(|e| e.to_string())?;
        self.auth_response(&user).await.map_err(|e| e.to_string())
    }

    pub async fn authenticate_with_google(
        &self,
        request: GoogleLoginRequest,
    ) -> Result<AuthResponse, String> {
        if request.id_token.trim().is_empty() {
            return Err("Invalid Google ID Token.".to_string());
        }
        let payload = verify_google_id_token(&request.id_token).await?;
        if !payload.email_verified {
            return Err("Google account email is not verified.".to_string());
        }
        let email_norm = crate::domain::email::NormalizedEmail::normalize(&payload.email);

        if let Some(pool) = &self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|_| "Identity storage unavailable")?;
            let id = client
                .query_opt("SELECT id FROM users WHERE google_sub=$1", &[&payload.sub])
                .await
                .map_err(|_| "Identity storage unavailable")?
                .map(|r| r.get::<_, i64>(0).to_string());
            drop(client);
            if let Some(id) = id {
                let user = crate::security::user(&self.state, &id)
                    .await
                    .map_err(|e| e.to_string())?;
                self.ensure_site_active(&user)
                    .await
                    .map_err(|e| e.to_string())?;
                return self.auth_response(&user).await.map_err(|e| e.to_string());
            }
            if self
                .find_user_by_email(&email_norm)
                .await
                .map_err(|e| e.to_string())?
                .is_some()
            {
                return Err(
                    "Sign in with your existing method before linking a Google identity"
                        .to_string(),
                );
            }
            let token = request
                .unit_invite_token
                .as_deref()
                .filter(|t| !t.trim().is_empty())
                .ok_or("An invitation token is required")?;
            let draft = User {
                id: String::new(),
                site_id: String::new(),
                full_name: payload.name,
                email: email_norm,
                phone: String::new(),
                password_hash: None,
                role: Role::HomeResident,
                must_change_password: false,
                auth_provider: AuthProvider::Google,
                google_sub: Some(payload.sub),
                avatar_url: Some(payload.picture),
                created_at: Utc::now(),
                person_id: None,
            };
            let (user, _) = self.register_invited_db(draft, token).await?;
            return self.auth_response(&user).await.map_err(|e| e.to_string());
        }
        let existing = {
            let inner = self.state.inner.read().await;
            inner
                .users
                .iter()
                .position(|u| u.google_sub.as_deref() == Some(&payload.sub))
                .or_else(|| {
                    inner
                        .users
                        .iter()
                        .position(|u| crate::domain::email::same_email(&u.email, &email_norm))
                })
        };

        let user = if let Some(idx) = existing {
            let mut inner = self.state.inner.write().await;
            let u = &mut inner.users[idx];
            if let Some(ref linked) = u.google_sub {
                if linked != &payload.sub {
                    return Err("This email is linked to a different Google account.".to_string());
                }
            }
            if u.google_sub.is_none() {
                return Err(
                    "Sign in with your existing method before linking a Google identity."
                        .to_string(),
                );
            }
            u.google_sub = Some(payload.sub.clone());
            if !payload.picture.is_empty() {
                u.avatar_url = Some(payload.picture.clone());
            }
            u.auth_provider = if u.password_hash.is_some() {
                AuthProvider::Hybrid
            } else {
                AuthProvider::Google
            };
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
                let max_u = inner
                    .users
                    .iter()
                    .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                    .max()
                    .unwrap_or(0);
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
                auth_provider: AuthProvider::Google,
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
        self.ensure_site_active(&user)
            .await
            .map_err(|e| e.to_string())?;
        if let Some(ref pool) = self.state.pool {
            crate::db::save_user(pool, &user)
                .await
                .map_err(|e| format!("Failed to persist user: {}", e))?;
            if let Ok(client) = pool.get().await {
                if let Ok(Some(row)) = client
                    .query_opt(
                        "SELECT id FROM users WHERE LOWER(email) = $1",
                        &[&crate::domain::email::NormalizedEmail::normalize(
                            &user.email,
                        )],
                    )
                    .await
                {
                    let db_id: i64 = row.get("id");
                    user.id = db_id.to_string();
                }
            }
        }
        self.auth_response(&user).await.map_err(|e| e.to_string())
    }

    /// Self-service registration is only possible with a unit invitation token,
    /// which fixes the new account's site and unit.
    pub async fn register_with_password(
        &self,
        request: RegisterUserRequest,
    ) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty()
            || request.password.is_empty()
            || request.full_name.trim().is_empty()
        {
            return Err("Full name, email, and password are required.".to_string());
        }
        auth::validate_new_password(&request.password)?;
        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);
        if self
            .find_user_by_email(&email_norm)
            .await
            .map_err(|e| e.to_string())?
            .is_some()
        {
            return Err(
                "An account with this email address already exists (zaten mevcut).".to_string(),
            );
        }
        let token = request
            .unit_invite_token
            .as_deref()
            .filter(|t| !t.trim().is_empty())
            .ok_or_else(|| {
                "An invitation token from your site manager is required to register.".to_string()
            })?;
        if self.state.pool.is_some() {
            let draft = User {
                id: String::new(),
                site_id: String::new(),
                full_name: request.full_name.trim().to_string(),
                email: email_norm.clone(),
                phone: request.phone.clone().unwrap_or_default(),
                password_hash: Some(auth::hash_password_async(request.password.clone()).await?),
                role: Role::HomeResident,
                must_change_password: false,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: None,
            };
            let (user, _) = self.register_invited_db(draft, token).await?;
            return self.auth_response(&user).await.map_err(|e| e.to_string());
        }
        let scope = self.consume_invite_token(token.trim()).await?;

        let next_user_id = {
            let inner = self.state.inner.read().await;
            let max_u = inner
                .users
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
            (max_u + 1).to_string()
        };

        let mut new_user = User {
            id: next_user_id,
            site_id: scope.site_id,
            full_name: request.full_name.trim().to_string(),
            email: email_norm,
            phone: request.phone.unwrap_or_default(),
            password_hash: Some(auth::hash_password_async(request.password.clone()).await?),
            role: Role::HomeResident,
            must_change_password: false,
            auth_provider: AuthProvider::Local,
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
            crate::db::save_user(pool, &new_user)
                .await
                .map_err(|e| format!("Failed to persist user: {}", e))?;
            if let Ok(client) = pool.get().await {
                if let Ok(Some(row)) = client
                    .query_opt(
                        "SELECT id FROM users WHERE LOWER(email) = $1",
                        &[&crate::domain::email::NormalizedEmail::normalize(
                            &new_user.email,
                        )],
                    )
                    .await
                {
                    let db_id: i64 = row.get("id");
                    new_user.id = db_id.to_string();
                }
            }
        }
        self.auth_response(&new_user)
            .await
            .map_err(|e| e.to_string())
    }

    /// Link a verified Google identity after request-level step-up.
    ///
    /// # Errors
    /// Rejects conflicting identity links, invalid tokens and unavailable storage.
    pub async fn link_google(&self, user_id: &str, id_token: &str) -> Result<AuthResponse, String> {
        let payload = verify_google_id_token(id_token).await?;
        if !payload.email_verified {
            return Err("Google identity is unverified".to_string());
        }
        let mut user = crate::security::user(&self.state, user_id)
            .await
            .map_err(|e| e.to_string())?;
        if user
            .google_sub
            .as_ref()
            .is_some_and(|sub| sub != &payload.sub)
        {
            return Err("Account is already linked".to_string());
        }
        if let Some(client) = crate::db::security_connection(&self.state)
            .await
            .map_err(|e| e.to_string())?
        {
            let id = crate::db::require_id("user", &user.id)?;
            let n=client.execute("UPDATE users SET google_sub=$1,auth_provider='HYBRID' WHERE id=$2 AND (google_sub IS NULL OR google_sub=$1)",&[&payload.sub,&id]).await.map_err(|_|"Google identity cannot be linked".to_string())?;
            if n != 1 {
                return Err("Google identity cannot be linked".to_string());
            }
        } else {
            let mut inner = self.state.inner.write().await;
            if inner
                .users
                .iter()
                .any(|u| u.id != user.id && u.google_sub.as_deref() == Some(&payload.sub))
            {
                return Err("Google identity cannot be linked".to_string());
            }
            if let Some(u) = inner.users.iter_mut().find(|u| u.id == user.id) {
                u.google_sub = Some(payload.sub.clone());
                u.auth_provider = AuthProvider::Hybrid;
            }
        }
        user.google_sub = Some(payload.sub);
        user.auth_provider = AuthProvider::Hybrid;
        crate::security::revoke(&self.state, &user.id, None)
            .await
            .map_err(|e| e.to_string())?;
        self.auth_response(&user).await.map_err(|e| e.to_string())
    }

    /// Consume a unit invitation and create its account/membership atomically.
    ///
    /// # Errors
    /// Rejects consumed/expired invitations, duplicate identities and storage failures.
    pub(crate) async fn register_invited_db(
        &self,
        mut user: User,
        raw_token: &str,
    ) -> Result<(User, String), String> {
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or("Identity storage unavailable")?;
        let mut client = pool
            .get()
            .await
            .map_err(|_| "Identity storage unavailable")?;
        let tx = client
            .transaction()
            .await
            .map_err(|_| "Identity storage unavailable")?;
        let digest = auth::token_digest(raw_token.trim());
        let row=tx.query_opt("DELETE FROM invitation_tokens invite USING units unit,sites site WHERE invite.token=$1 AND invite.token_type='UNIT' AND invite.expires_at>now() AND invite.unit_id=unit.id AND unit.site_id=site.id AND unit.deleted_at IS NULL AND site.deleted_at IS NULL AND site.status IN ('ACTIVE','TRIAL') RETURNING invite.unit_id,unit.site_id,invite.relationship",&[&digest]).await.map_err(|_|"Invitation storage unavailable")?.ok_or("Invitation token is invalid or has already been used.")?;
        let unit: i64 = row.get(0);
        let site: i64 = row.get(1);
        let relationship: Option<String> = row.get(2);
        tx.query_one(
            "SELECT id FROM sites WHERE id=$1 AND status IN ('ACTIVE','TRIAL') FOR SHARE",
            &[&site],
        )
        .await
        .map_err(|_| "Site is unavailable")?;
        let person:i64=tx.query_one("INSERT INTO persons(full_name,email,phone,person_type,site_id) VALUES ($1,$2,$3,'HOME_RESIDENT',$4) RETURNING id",&[&user.full_name,&user.email,&user.phone,&site]).await.map_err(|_|"This identity cannot be registered; ask your site manager for assistance")?.get(0);
        let id:i64=tx.query_one("INSERT INTO users(site_id,person_id,email,password_hash,role,must_change_password,auth_provider,google_sub,avatar_url) VALUES ($1,$2,$3,$4,'HOME_RESIDENT',$5,$6,$7,$8) RETURNING id",&[&site,&person,&user.email,&user.password_hash,&user.must_change_password,&user.auth_provider,&user.google_sub,&user.avatar_url]).await.map_err(|_|"This identity cannot be registered")?.get(0);
        let occupancy=tx.query_opt("SELECT id FROM unit_occupancies WHERE unit_id=$1 AND is_active AND end_date IS NULL ORDER BY start_date DESC,id DESC LIMIT 1 FOR UPDATE",&[&unit]).await.map_err(|_|"Household storage unavailable")?;
        let occupancy: i64 = if let Some(row) = occupancy {
            row.get(0)
        } else {
            tx.query_opt("INSERT INTO unit_occupancies(unit_id,person_id,occupancy_type) SELECT id,COALESCE(tenant_person_id,owner_person_id),CASE WHEN tenant_person_id IS NOT NULL THEN 'TENANT' ELSE 'OWNER' END FROM units WHERE id=$1 AND COALESCE(tenant_person_id,owner_person_id) IS NOT NULL RETURNING id",&[&unit]).await.map_err(|_|"Household storage unavailable")?.ok_or("The unit has no active household; contact your site manager")?.get(0)
        };
        tx.execute("INSERT INTO occupancy_members(occupancy_id,person_id,resident_user_id,full_name,email,phone,relationship) VALUES ($1,$2,$3,$4,$5,$6,$7)",&[&occupancy,&person,&id,&user.full_name,&user.email,&user.phone,&crate::domain::household_relationship::HouseholdRelationship::from_input(relationship.as_deref().unwrap_or("")).unwrap_or(crate::domain::household_relationship::HouseholdRelationship::Other).as_str()]).await.map_err(|_|"Household storage unavailable")?;
        tx.execute(
            "INSERT INTO user_site_roles(user_id,site_id,role) VALUES ($1,$2,'HOME_RESIDENT')",
            &[&id, &site],
        )
        .await
        .map_err(|_| "Membership storage unavailable")?;
        tx.commit()
            .await
            .map_err(|_| "Identity storage unavailable")?;
        user.id = id.to_string();
        user.site_id = site.to_string();
        user.person_id = Some(person);
        user.role = Role::HomeResident;
        let unit_id = unit.to_string();
        let mut inner = self.state.inner.write().await;
        inner.unit_invite_tokens.remove(&digest);
        inner.users.push(user.clone());
        attach_member(&mut inner, &unit_id, &user);
        Ok((user, unit_id))
    }

    pub async fn get_current_profile(&self, user_id: &str) -> Result<UserProfileResponse, String> {
        let user = crate::security::user(&self.state, user_id)
            .await
            .map_err(|e| e.to_string())?;
        let unit_id = match user.role {
            Role::HomeOwner | Role::HomeResident => self
                .resolve_unit_id(&user)
                .await
                .map_err(|e| e.to_string())?
                .unwrap_or_default(),
            _ => String::new(),
        };
        let permissions = Permission::permissions_for_role(user.role);
        let descriptions = permissions
            .iter()
            .map(|p| format!("{:?}: {}", p, p.description()))
            .collect();
        Ok(UserProfileResponse {
            id: user.id.clone(),
            full_name: user.full_name.clone(),
            email: user.email.clone(),
            phone: user.phone.clone(),
            role: user.role,
            site_id: user.site_id.clone(),
            unit_id,
            avatar_url: user.avatar_url.clone(),
            auth_provider: user.auth_provider,
            must_change_password: user.must_change_password,
            permissions,
            permission_descriptions: descriptions,
        })
    }

    pub async fn change_password(
        &self,
        request: ChangePasswordRequest,
    ) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty()
            || request.current_password.is_empty()
            || request.new_password.is_empty()
        {
            return Err("Email, current password, and new password are required.".to_string());
        }
        auth::validate_new_password(&request.new_password)?;

        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);
        // The same message for "no such user" and "wrong password" avoids user enumeration.
        let user = self
            .find_user_by_email(&email_norm)
            .await
            .map_err(|e| e.to_string())?
            .ok_or_else(|| INVALID_CREDENTIALS.to_string())?;
        let stored = user
            .password_hash
            .as_deref()
            .ok_or_else(|| INVALID_CREDENTIALS.to_string())?;
        if !auth::verify_password_async(request.current_password.clone(), stored.to_string())
            .await?
        {
            return Err(INVALID_CREDENTIALS.to_string());
        }
        if request.new_password == request.current_password {
            return Err("The new password must differ from the current one.".to_string());
        }

        let new_hash = auth::hash_password_async(request.new_password.clone()).await?;
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
            if let Some(u) = inner
                .users
                .iter_mut()
                .find(|u| crate::domain::email::same_email(&u.email, &email_norm))
            {
                u.password_hash = Some(new_hash.clone());
                u.must_change_password = false;
            }
        }
        crate::security::revoke(&self.state, &user.id, None)
            .await
            .map_err(|e| e.to_string())?;
        let mut updated = user;
        updated.password_hash = Some(new_hash);
        updated.must_change_password = false;
        self.auth_response(&updated)
            .await
            .map_err(|e| e.to_string())
    }
}

/// Re-exported for callers that previously used the service-level helper.
pub fn hash_password(password: &str) -> Result<String, String> {
    auth::hash_password(password)
}

fn attach_member(inner: &mut crate::state::AppStateInner, unit_id: &str, user: &User) {
    inner
        .unit_members
        .entry(unit_id.to_string())
        .or_default()
        .push(crate::models::UnitMemberDto {
            resident_id: user.id.clone(),
            full_name: user.full_name.clone(),
            relationship: "OTHER".to_string(),
            phone: user.phone.clone(),
            email: user.email.clone(),
            is_owner: false,
            occupancy_id: None,
            person_id: user.person_id,
            resident_user_id: None,
        });
}

fn create_auth_response(
    user: &User,
    unit_id: Option<&str>,
    credentials: crate::security::Credentials,
) -> AuthResponse {
    let permissions = Permission::permissions_for_role(user.role);
    let summary = UserSummary {
        id: user.id.clone(),
        // Accounts without a linked person (e.g. a seeded admin) have no name yet.
        full_name: if user.full_name.trim().is_empty() {
            user.email.clone()
        } else {
            user.full_name.clone()
        },
        email: user.email.clone(),
        phone: user.phone.clone(),
        role: user.role,
        site_id: user.site_id.clone(),
        unit_id: unit_id.unwrap_or_default().to_string(),
        avatar_url: user.avatar_url.clone(),
        auth_provider: user.auth_provider,
        must_change_password: user.must_change_password,
        permissions,
    };
    AuthResponse {
        refresh_token: credentials.refresh_token,
        access_token: credentials.access_token,
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
        && std::env::var("SITEPULSE_ALLOW_MOCK_GOOGLE_TOKENS")
            .map(|v| v == "true")
            .unwrap_or(false)
}

async fn google_jwks(force: bool) -> Result<JwkSet, String> {
    static CACHE: Mutex<Option<(Instant, JwkSet)>> = Mutex::new(None);
    if let Some((at, set)) = CACHE
        .lock()
        .map_err(|_| "Google key cache unavailable".to_string())?
        .as_ref()
    {
        if !force && at.elapsed() < Duration::from_secs(3600) {
            return Ok(set.clone());
        }
    }
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|_| "Google identity provider unavailable".to_string())?;
    let set: JwkSet = client
        .get(GOOGLE_JWKS_URL)
        .send()
        .await
        .map_err(|e| format!("Could not fetch Google signing keys: {}", e))?
        .error_for_status()
        .map_err(|_| "Google identity provider unavailable".to_string())?
        .json()
        .await
        .map_err(|_| "Invalid Google signing keys".to_string())?;
    *CACHE
        .lock()
        .map_err(|_| "Google key cache unavailable".to_string())? =
        Some((Instant::now(), set.clone()));
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
            (Some(sub), Some(email)) if !sub.is_empty() && email.contains('@') => {
                Ok(GoogleTokenPayload {
                    sub: sub.to_string(),
                    email: email.to_string(),
                    email_verified: true,
                    name: parts.get(2).unwrap_or(&"Google User").to_string(),
                    picture: String::new(),
                })
            }
            _ => Err("Invalid Google ID Token.".to_string()),
        };
    }

    let client_id = std::env::var("GOOGLE_CLIENT_ID")
        .map_err(|_| "Google sign-in is not configured on this server.".to_string())?;
    let header = decode_header(id_token).map_err(|_| "Invalid Google ID Token.".to_string())?;
    let kid = header
        .kid
        .ok_or_else(|| "Invalid Google ID Token.".to_string())?;
    let mut jwks = google_jwks(false).await?;
    if jwks.find(&kid).is_none() {
        jwks = google_jwks(true).await?;
    }
    let jwk = jwks
        .find(&kid)
        .ok_or_else(|| "Invalid Google ID Token.".to_string())?;
    let key = DecodingKey::from_jwk(jwk).map_err(|_| "Invalid Google signing key.".to_string())?;
    let mut validation = Validation::new(Algorithm::RS256);
    validation.set_audience(&[client_id]);
    validation.set_issuer(&GOOGLE_ISSUERS);
    decode::<GoogleTokenPayload>(id_token, &key, &validation)
        .map(|d| d.claims)
        .map_err(|e| format!("Invalid Google ID Token: {}", e))
}
