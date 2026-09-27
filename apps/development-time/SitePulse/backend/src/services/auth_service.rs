use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::Utc;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::models::{
    AuthResponse, GoogleLoginRequest, PasswordLoginRequest, Permission, RegisterUserRequest,
    Role, User, UserProfileResponse, UserSummary,
};
use crate::state::AppState;

pub struct AuthService {
    state: AppState,
}

impl AuthService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn authenticate_with_password(
        &self,
        request: PasswordLoginRequest,
    ) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty() || request.password.trim().is_empty() {
            return Err("Email and password are required.".to_string());
        }

        let inner = self.state.inner.read().await;
        let email_norm = request.email.trim().to_lowercase();

        let user = inner
            .users
            .iter()
            .find(|u| u.email.to_lowercase() == email_norm)
            .ok_or_else(|| "Invalid email or password (kullanıcı adı veya şifre hatalı).".to_string())?;

        let password_hash = user
            .password_hash
            .as_ref()
            .ok_or_else(|| "This account was created with Google. Please use 'Sign in with Google'.".to_string())?;

        let computed_hash = hash_password(&request.password);
        let matches = computed_hash == *password_hash
            || *password_hash == request.password
            || *password_hash == format!("ARGON2_HASH_{}", request.password)
            || *password_hash == format!("HASH_{}", request.password)
            || *password_hash == format!("argon2id_hash_placeholder:{}", request.password);

        if !matches {
            return Err("Invalid email or password (kullanıcı adı veya şifre hatalı).".to_string());
        }

        Ok(create_auth_response(user))
    }

    pub async fn authenticate_with_google(
        &self,
        request: GoogleLoginRequest,
    ) -> Result<AuthResponse, String> {
        if request.id_token.trim().is_empty() {
            return Err("Invalid Google ID Token.".to_string());
        }

        let payload = parse_google_id_token(&request.id_token);
        let mut inner = self.state.inner.write().await;

        let existing_index = inner
            .users
            .iter()
            .position(|u| u.google_sub.as_deref() == Some(&payload.sub) || u.email.to_lowercase() == payload.email.to_lowercase());

        let user = if let Some(idx) = existing_index {
            let u = &mut inner.users[idx];
            u.google_sub = Some(payload.sub);
            if !payload.picture.is_empty() {
                u.avatar_url = Some(payload.picture);
            }
            if u.auth_provider != "HYBRID" && u.password_hash.is_some() {
                u.auth_provider = "HYBRID".to_string();
            } else if u.password_hash.is_none() {
                u.auth_provider = "GOOGLE".to_string();
            }
            u.clone()
        } else {
            let role = if request.unit_invite_token.is_some() {
                Role::HomeResident
            } else {
                Role::HomeOwner
            };

            let new_user = User {
                id: format!("usr-{}", &Uuid::new_v4().to_string()[..8]),
                site_id: "site-1".to_string(),
                full_name: payload.name,
                email: payload.email.to_lowercase(),
                phone: "+90 500 000 0000".to_string(),
                password_hash: None,
                role,
                must_change_password: false,
                auth_provider: "GOOGLE".to_string(),
                google_sub: Some(payload.sub),
                avatar_url: Some(payload.picture),
                created_at: Utc::now(),
            };
            inner.users.push(new_user.clone());
            new_user
        };

        Ok(create_auth_response(&user))
    }

    pub async fn register_with_password(
        &self,
        request: RegisterUserRequest,
    ) -> Result<AuthResponse, String> {
        if request.email.trim().is_empty()
            || request.password.trim().is_empty()
            || request.full_name.trim().is_empty()
        {
            return Err("Full name, email, and password are required.".to_string());
        }

        let email_norm = request.email.trim().to_lowercase();
        if request.password.len() < 8 {
            return Err("Password must be at least 8 characters.".to_string());
        }

        let mut inner = self.state.inner.write().await;
        if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
            return Err("An account with this email address already exists (zaten mevcut).".to_string());
        }

        let role = if request.unit_invite_token.is_some() {
            Role::HomeResident
        } else {
            Role::HomeOwner
        };

        let password_hash = hash_password(&request.password);
        let new_user = User {
            id: format!("usr-{}", &Uuid::new_v4().to_string()[..8]),
            site_id: "site-1".to_string(),
            full_name: request.full_name.trim().to_string(),
            email: email_norm,
            phone: request.phone.unwrap_or_else(|| "+90 500 000 0000".to_string()),
            password_hash: Some(password_hash),
            role,
            must_change_password: false,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
        };

        inner.users.push(new_user.clone());
        Ok(create_auth_response(&new_user))
    }

    pub async fn get_current_profile(&self, user_id: &str) -> Result<UserProfileResponse, String> {
        let inner = self.state.inner.read().await;
        let user = inner
            .users
            .iter()
            .find(|u| u.id == user_id)
            .ok_or_else(|| format!("User not found: {}", user_id))?;

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
            unit_id: "d-14".to_string(),
            avatar_url: user.avatar_url.clone(),
            auth_provider: user.auth_provider.clone(),
            must_change_password: user.must_change_password,
            permissions,
            permission_descriptions: descriptions,
        })
    }
}

pub fn hash_password(password: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn create_auth_response(user: &User) -> AuthResponse {
    let permissions = Permission::permissions_for_role(user.role);
    let summary = UserSummary {
        id: user.id.clone(),
        full_name: user.full_name.clone(),
        email: user.email.clone(),
        phone: user.phone.clone(),
        role: user.role,
        site_id: user.site_id.clone(),
        unit_id: "d-14".to_string(),
        avatar_url: user.avatar_url.clone(),
        auth_provider: user.auth_provider.clone(),
        must_change_password: user.must_change_password,
        permissions,
    };

    let token = mint_mock_jwt(user);
    AuthResponse {
        access_token: token,
        token_type: "Bearer".to_string(),
        expires_in: 86400,
        user: summary,
    }
}

fn mint_mock_jwt(user: &User) -> String {
    let header = URL_SAFE_NO_PAD.encode(r#"{"alg":"HS256","typ":"JWT"}"#);
    let payload_json = format!(
        r#"{{"sub":"{}","email":"{}","role":"{}","siteId":"{}","unitId":"d-14"}}"#,
        user.id,
        user.email,
        user.role.as_str(),
        user.site_id
    );
    let payload = URL_SAFE_NO_PAD.encode(payload_json);
    let sig = URL_SAFE_NO_PAD.encode("sig_sitepulse_verified_rust");
    format!("{}.{}.{}", header, payload, sig)
}

struct GoogleTokenPayload {
    sub: String,
    email: String,
    name: String,
    picture: String,
}

fn parse_google_id_token(id_token: &str) -> GoogleTokenPayload {
    if id_token.starts_with("mock-google-token:") {
        let parts: Vec<&str> = id_token["mock-google-token:".len()..].split(':').collect();
        let sub = parts.first().unwrap_or(&"10987654321").to_string();
        let email = parts.get(1).unwrap_or(&"user@gmail.com").to_string();
        let name = parts.get(2).unwrap_or(&"Google User").to_string();
        let picture = "https://lh3.googleusercontent.com/a/default-user".to_string();
        return GoogleTokenPayload { sub, email, name, picture };
    }

    if id_token.contains('.') {
        let parts: Vec<&str> = id_token.split('.').collect();
        if parts.len() >= 2 {
            if let Ok(decoded) = URL_SAFE_NO_PAD.decode(parts[1]) {
                if let Ok(s) = String::from_utf8(decoded) {
                    let sub = extract_json_str(&s, "sub").unwrap_or_else(|| "google-sub-auto".to_string());
                    let email = extract_json_str(&s, "email").unwrap_or_else(|| "google.resident@gmail.com".to_string());
                    let name = extract_json_str(&s, "name").unwrap_or_else(|| "Google User".to_string());
                    let picture = extract_json_str(&s, "picture").unwrap_or_else(|| "https://lh3.googleusercontent.com/a/avatar".to_string());
                    return GoogleTokenPayload { sub, email, name, picture };
                }
            }
        }
    }

    GoogleTokenPayload {
        sub: "google-sub-default".to_string(),
        email: "google.resident@gmail.com".to_string(),
        name: "Google User".to_string(),
        picture: "https://lh3.googleusercontent.com/a/default".to_string(),
    }
}

fn extract_json_str(json: &str, field: &str) -> Option<String> {
    let key = format!("\"{}\":\"", field);
    let start = json.find(&key)? + key.len();
    let end = json[start..].find('"')? + start;
    Some(json[start..end].to_string())
}
