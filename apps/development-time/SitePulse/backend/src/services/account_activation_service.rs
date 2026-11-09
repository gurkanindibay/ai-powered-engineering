//! Single-use account activation and email-confirmation tokens.
//!
//! A site manager never sees or chooses a resident's password. Creating an
//! account issues a random 256-bit token that is delivered to the person's own
//! email address; the person sets a password with it (`ACTIVATE`). A login
//! email change is applied only after the new address confirms it
//! (`EMAIL_CHANGE`). Only the SHA-256 digest of a token is stored, a newer token
//! of the same purpose voids the older ones, and every token expires.

use chrono::{DateTime, Duration, Utc};
use deadpool_postgres::{GenericClient, Pool};
use serde::{Deserialize, Serialize};

use crate::domain::kvkk::DeliveryChannel;
use crate::services::notification_service::{configured_sender, Recipient};
use crate::state::AppState;

/// How long an activation or confirmation link stays valid.
pub const ACTIVATION_TTL_HOURS: i64 = 72;
/// The one message for every unusable token, so a caller learns nothing about why.
pub const INVALID_TOKEN: &str =
    "This link is invalid or has expired. Ask your site manager for a new one.";

/// Why an activation operation was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ActivationError {
    /// Unknown, used, expired or wrong-purpose token, or an address taken meanwhile.
    #[error("{INVALID_TOKEN}")]
    InvalidToken,
    /// The chosen password breaks the password policy.
    #[error("{0}")]
    Password(String),
    /// The unit is not in the caller's site.
    #[error("Unit not found")]
    UnitNotFound,
    /// The person has no login account.
    #[error("This person has no login account.")]
    NoLoginAccount,
    /// The account already has a password (or a linked Google sign-in).
    #[error("This account is already active.")]
    AlreadyActive,
    /// Persistence failed; the message is logged, never shown.
    #[error("Activation storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> ActivationError {
    ActivationError::Storage(e.to_string())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActivationPurpose {
    Activate,
    EmailChange,
}

impl ActivationPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Activate => "ACTIVATE",
            Self::EmailChange => "EMAIL_CHANGE",
        }
    }
    fn parse(value: &str) -> Option<Self> {
        match value {
            "ACTIVATE" => Some(Self::Activate),
            "EMAIL_CHANGE" => Some(Self::EmailChange),
            _ => None,
        }
    }
}

/// A token as handed to the delivery step. The plaintext never leaves the server
/// except inside the message sent to the person.
#[derive(Debug, Clone)]
pub struct IssuedToken {
    pub token: String,
    pub expires_at: DateTime<Utc>,
}

/// What a site manager may know about an activation: whether it was sent, never the link.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActivationDelivery {
    /// `SENT`, `DELIVERY_FAILED` or `NO_EMAIL`.
    pub status: String,
    pub expires_at: Option<DateTime<Utc>>,
}

impl ActivationDelivery {
    pub fn no_email() -> Self {
        Self {
            status: "NO_EMAIL".to_string(),
            expires_at: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivateAccountRequest {
    pub token: String,
    pub new_password: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfirmEmailRequest {
    pub token: String,
}

/// An in-memory token, used only when the service runs without PostgreSQL.
#[derive(Debug, Clone)]
pub struct MemoryActivation {
    pub user_id: String,
    pub purpose: ActivationPurpose,
    pub new_email: Option<String>,
    pub expires_at: DateTime<Utc>,
    pub used: bool,
}

fn new_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// Issue a token inside the caller's transaction, voiding older unused tokens of the same purpose.
///
/// # Errors
/// [`ActivationError::Storage`] when the token cannot be stored.
pub async fn issue_in<C: GenericClient>(
    client: &C,
    user_id: i64,
    site_id: Option<i64>,
    purpose: ActivationPurpose,
    new_email: Option<&str>,
) -> Result<IssuedToken, ActivationError> {
    let token = new_token();
    let expires_at = Utc::now() + Duration::hours(ACTIVATION_TTL_HOURS);
    client
        .execute(
            "UPDATE account_activations SET used_at = now() WHERE user_id = $1 AND purpose = $2 AND used_at IS NULL",
            &[&user_id, &purpose.as_str()],
        )
        .await
        .map_err(storage)?;
    client
        .execute(
            "INSERT INTO account_activations (token_hash, user_id, site_id, purpose, new_email, expires_at) VALUES ($1, $2, $3, $4, $5, $6)",
            &[
                &crate::auth::token_digest(&token),
                &user_id,
                &site_id,
                &purpose.as_str(),
                &new_email,
                &expires_at,
            ],
        )
        .await
        .map_err(storage)?;
    Ok(IssuedToken { token, expires_at })
}

/// Issue a token in the in-memory store.
pub fn issue_in_memory(
    inner: &mut crate::state::AppStateInner,
    user_id: &str,
    purpose: ActivationPurpose,
    new_email: Option<&str>,
) -> IssuedToken {
    let token = new_token();
    let expires_at = Utc::now() + Duration::hours(ACTIVATION_TTL_HOURS);
    for existing in inner.account_activations.values_mut() {
        if existing.user_id == user_id && existing.purpose == purpose {
            existing.used = true;
        }
    }
    inner.account_activations.insert(
        crate::auth::token_digest(&token),
        MemoryActivation {
            user_id: user_id.to_string(),
            purpose,
            new_email: new_email.map(str::to_string),
            expires_at,
            used: false,
        },
    );
    IssuedToken { token, expires_at }
}

fn public_link(path: &str, token: &str) -> String {
    let base = std::env::var("SITEPULSE_PUBLIC_APP_URL")
        .unwrap_or_else(|_| "http://localhost:8080".to_string());
    format!("{}/#/{}?token={}", base.trim_end_matches('/'), path, token)
}

/// Where tokens live: chosen once, so each operation has one storage path.
enum ActivationStore {
    Postgres(Pool),
    Memory,
}

/// A login account a token is issued for.
struct ActivationTarget {
    user_id: String,
    name: String,
    email: String,
    issued: IssuedToken,
}

pub struct AccountActivationService {
    state: AppState,
    store: ActivationStore,
}

impl AccountActivationService {
    pub fn new(state: AppState) -> Self {
        let store = match state.pool.clone() {
            Some(pool) => ActivationStore::Postgres(pool),
            None => ActivationStore::Memory,
        };
        Self { state, store }
    }

    /// Send the link to the person's own address. Delivery failure is reported,
    /// not hidden; the token stays valid so the manager can resend.
    pub fn deliver(
        &self,
        reference: &str,
        name: &str,
        email: &str,
        purpose: ActivationPurpose,
        issued: &IssuedToken,
    ) -> ActivationDelivery {
        if email.trim().is_empty() {
            return ActivationDelivery::no_email();
        }
        let (subject, path, intro) = match purpose {
            ActivationPurpose::Activate => (
                "SitePulse hesabınızı etkinleştirin",
                "activate",
                "SitePulse hesabınız oluşturuldu. Şifrenizi belirlemek için bağlantıyı açın:",
            ),
            ActivationPurpose::EmailChange => (
                "SitePulse e-posta değişikliğini onaylayın",
                "confirm-email",
                "Giriş e-posta adresinizin bu adresle değiştirilmesi istendi. Onaylamak için bağlantıyı açın:",
            ),
        };
        let body = format!(
            "{}\n{}\n\nBağlantı {} tarihine kadar geçerlidir ve bir kez kullanılabilir.",
            intro,
            public_link(path, &issued.token),
            issued.expires_at.format("%d.%m.%Y %H:%M UTC")
        );
        let recipient = Recipient {
            reference: reference.to_string(),
            name: name.to_string(),
            email: Some(email.to_string()),
            phone: None,
            has_app: false,
        };
        let status = match configured_sender()
            .and_then(|sender| sender.send(DeliveryChannel::Email, &recipient, subject, &body))
        {
            Ok(_) => "SENT",
            Err(e) => {
                tracing::warn!(recipient = %reference, error = %e, "Activation link could not be delivered");
                "DELIVERY_FAILED"
            }
        };
        ActivationDelivery {
            status: status.to_string(),
            expires_at: Some(issued.expires_at),
        }
    }

    /// Tell the previous address that the login email is being changed.
    pub fn notify_previous_email(&self, reference: &str, name: &str, previous_email: &str) {
        if previous_email.trim().is_empty() {
            return;
        }
        let recipient = Recipient {
            reference: reference.to_string(),
            name: name.to_string(),
            email: Some(previous_email.to_string()),
            phone: None,
            has_app: false,
        };
        let body = "Site yöneticiniz giriş e-posta adresinizin değiştirilmesini istedi. Değişiklik, yeni adres onaylandığında geçerli olur. Bu isteği siz yapmadıysanız site yönetiminize başvurun.";
        if let Err(e) = configured_sender().and_then(|sender| {
            sender.send(
                DeliveryChannel::Email,
                &recipient,
                "SitePulse e-posta değişikliği isteği",
                body,
            )
        }) {
            tracing::warn!(recipient = %reference, error = %e, "Email change notice could not be delivered");
        }
    }

    /// Issue and send a fresh activation link to a unit's owner (or tenant).
    /// Only an account that has never set a password can be activated this way.
    ///
    /// # Errors
    /// Unknown unit, no login account, an already active account, or storage failure.
    pub async fn resend_for_unit(
        &self,
        site_id: &str,
        unit_id: &str,
        tenant: bool,
    ) -> Result<ActivationDelivery, ActivationError> {
        let site = crate::db::parse_id_to_i64(site_id).ok_or(ActivationError::UnitNotFound)?;
        let unit = crate::db::parse_id_to_i64(unit_id).ok_or(ActivationError::UnitNotFound)?;
        let target = match &self.store {
            ActivationStore::Postgres(pool) => {
                Self::resend_target_in_db(pool, site, unit, tenant).await?
            }
            ActivationStore::Memory => self.resend_target_in_memory(site_id, unit, tenant).await?,
        };
        Ok(self.deliver(
            &format!("user-{}", target.user_id),
            &target.name,
            &target.email,
            ActivationPurpose::Activate,
            &target.issued,
        ))
    }

    async fn resend_target_in_db(
        pool: &Pool,
        site: i64,
        unit: i64,
        tenant: bool,
    ) -> Result<ActivationTarget, ActivationError> {
        let mut connection = pool.get().await.map_err(storage)?;
        let tx = connection.transaction().await.map_err(storage)?;
        let sql = if tenant {
            "SELECT usr.id, COALESCE(p.full_name, ''), usr.email, usr.password_hash IS NULL AND usr.google_sub IS NULL FROM units u \
             JOIN persons p ON p.id = u.tenant_person_id JOIN users usr ON usr.person_id = p.id AND usr.is_active \
             WHERE u.id = $1 AND u.site_id = $2 AND u.deleted_at IS NULL"
        } else {
            "SELECT usr.id, COALESCE(p.full_name, ''), usr.email, usr.password_hash IS NULL AND usr.google_sub IS NULL FROM units u \
             JOIN persons p ON p.id = u.owner_person_id JOIN users usr ON usr.person_id = p.id AND usr.is_active \
             WHERE u.id = $1 AND u.site_id = $2 AND u.deleted_at IS NULL"
        };
        let unit_exists = tx
            .query_opt(
                "SELECT 1 FROM units WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL",
                &[&unit, &site],
            )
            .await
            .map_err(storage)?
            .is_some();
        if !unit_exists {
            return Err(ActivationError::UnitNotFound);
        }
        let row = tx
            .query_opt(sql, &[&unit, &site])
            .await
            .map_err(storage)?
            .ok_or(ActivationError::NoLoginAccount)?;
        let user_id: i64 = row.get(0);
        let awaiting: bool = row.get(3);
        if !awaiting {
            return Err(ActivationError::AlreadyActive);
        }
        let issued = issue_in(&tx, user_id, Some(site), ActivationPurpose::Activate, None).await?;
        tx.commit().await.map_err(storage)?;
        Ok(ActivationTarget {
            user_id: user_id.to_string(),
            name: row.get(1),
            email: row.get(2),
            issued,
        })
    }

    async fn resend_target_in_memory(
        &self,
        site_id: &str,
        unit: i64,
        tenant: bool,
    ) -> Result<ActivationTarget, ActivationError> {
        let mut inner = self.state.inner.write().await;
        let target = inner
            .units
            .iter()
            .find(|u| {
                crate::db::parse_id_to_i64(&u.id) == Some(unit)
                    && crate::auth::same_id(&u.site_id, site_id)
            })
            .ok_or(ActivationError::UnitNotFound)?;
        let user_id = if tenant {
            target.tenant_user_id.clone()
        } else {
            target.owner_user_id.clone()
        }
        .ok_or(ActivationError::NoLoginAccount)?;
        let user = inner
            .users
            .iter()
            .find(|u| u.id == user_id)
            .cloned()
            .ok_or(ActivationError::NoLoginAccount)?;
        if user.password_hash.is_some() || user.google_sub.is_some() {
            return Err(ActivationError::AlreadyActive);
        }
        let issued = issue_in_memory(&mut inner, &user.id, ActivationPurpose::Activate, None);
        Ok(ActivationTarget {
            user_id: user.id,
            name: user.full_name,
            email: user.email,
            issued,
        })
    }

    /// Set the first password of an account with an activation token.
    ///
    /// # Errors
    /// [`ActivationError::InvalidToken`] for any unusable token, or a password policy refusal.
    pub async fn activate(&self, request: ActivateAccountRequest) -> Result<(), ActivationError> {
        crate::auth::validate_new_password(&request.new_password)
            .map_err(ActivationError::Password)?;
        let hash = crate::auth::hash_password_async(request.new_password.clone())
            .await
            .map_err(storage)?;
        let digest = crate::auth::token_digest(request.token.trim());
        let mut inner = match &self.store {
            ActivationStore::Postgres(pool) => {
                let mut client = pool.get().await.map_err(storage)?;
                let tx = client.transaction().await.map_err(storage)?;
                let (user_id, _) = Self::consume(&tx, &digest, ActivationPurpose::Activate).await?;
                let updated = tx
                    .execute(
                        "UPDATE users SET password_hash = $1, must_change_password = false WHERE id = $2 AND is_active",
                        &[&hash, &user_id],
                    )
                    .await
                    .map_err(storage)?;
                if updated != 1 {
                    return Err(ActivationError::InvalidToken);
                }
                tx.commit().await.map_err(storage)?;
                let mut inner = self.state.inner.write().await;
                Self::apply_password(&mut inner, &user_id.to_string(), hash);
                tracing::info!(user_id = %user_id, "Account activated");
                return Ok(());
            }
            ActivationStore::Memory => self.state.inner.write().await,
        };
        let (user_id, _) =
            Self::consume_in_memory(&mut inner, &digest, ActivationPurpose::Activate)?;
        Self::apply_password(&mut inner, &user_id, hash);
        tracing::info!(user_id = %user_id, "Account activated");
        Ok(())
    }

    fn apply_password(inner: &mut crate::state::AppStateInner, user_id: &str, hash: String) {
        if let Some(user) = inner
            .users
            .iter_mut()
            .find(|u| crate::db::parse_id_to_i64(&u.id) == crate::db::parse_id_to_i64(user_id))
        {
            user.password_hash = Some(hash);
            user.must_change_password = false;
        }
    }

    /// Apply a pending login email change once the new address confirms it.
    ///
    /// # Errors
    /// [`ActivationError::InvalidToken`] for any unusable token or an address taken meanwhile.
    pub async fn confirm_email(&self, request: ConfirmEmailRequest) -> Result<(), ActivationError> {
        let digest = crate::auth::token_digest(request.token.trim());
        let (user_id, new_email) = match &self.store {
            ActivationStore::Postgres(pool) => Self::confirm_email_in_db(pool, &digest).await?,
            ActivationStore::Memory => {
                let mut inner = self.state.inner.write().await;
                let (id, email) =
                    Self::consume_in_memory(&mut inner, &digest, ActivationPurpose::EmailChange)?;
                let email = email.ok_or(ActivationError::InvalidToken)?;
                if inner
                    .users
                    .iter()
                    .any(|u| u.id != id && crate::domain::email::same_email(&u.email, &email))
                {
                    return Err(ActivationError::InvalidToken);
                }
                (id, email)
            }
        };
        let mut inner = self.state.inner.write().await;
        if let Some(user) = inner
            .users
            .iter_mut()
            .find(|u| crate::db::parse_id_to_i64(&u.id) == crate::db::parse_id_to_i64(&user_id))
        {
            user.email = new_email;
        }
        tracing::info!(user_id = %user_id, "Login email change confirmed");
        Ok(())
    }

    async fn confirm_email_in_db(
        pool: &Pool,
        digest: &str,
    ) -> Result<(String, String), ActivationError> {
        let mut client = pool.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        let (user_id, new_email) =
            Self::consume(&tx, digest, ActivationPurpose::EmailChange).await?;
        let new_email = new_email.ok_or(ActivationError::InvalidToken)?;
        let taken = tx
            .query_opt(
                "SELECT 1 FROM users WHERE lower(email) = lower($1) AND id <> $2",
                &[&new_email, &user_id],
            )
            .await
            .map_err(storage)?;
        if taken.is_some() {
            return Err(ActivationError::InvalidToken);
        }
        let row = tx
            .query_opt(
                "UPDATE users SET email = $1 WHERE id = $2 AND is_active RETURNING person_id",
                &[&new_email, &user_id],
            )
            .await
            .map_err(storage)?
            .ok_or(ActivationError::InvalidToken)?;
        let person_id: Option<i64> = row.get(0);
        if let Some(person_id) = person_id {
            tx.execute(
                "UPDATE persons SET email = $1 WHERE id = $2",
                &[&new_email, &person_id],
            )
            .await
            .map_err(storage)?;
        }
        tx.commit().await.map_err(storage)?;
        Ok((user_id.to_string(), new_email))
    }

    async fn consume<C: GenericClient>(
        client: &C,
        digest: &str,
        purpose: ActivationPurpose,
    ) -> Result<(i64, Option<String>), ActivationError> {
        let row = client
            .query_opt(
                "UPDATE account_activations SET used_at = now() WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING user_id, purpose, new_email",
                &[&digest],
            )
            .await
            .map_err(storage)?
            .ok_or(ActivationError::InvalidToken)?;
        let stored: String = row.get(1);
        if ActivationPurpose::parse(&stored) != Some(purpose) {
            return Err(ActivationError::InvalidToken);
        }
        Ok((row.get(0), row.get(2)))
    }

    fn consume_in_memory(
        inner: &mut crate::state::AppStateInner,
        digest: &str,
        purpose: ActivationPurpose,
    ) -> Result<(String, Option<String>), ActivationError> {
        let entry = inner
            .account_activations
            .get_mut(digest)
            .filter(|a| !a.used && a.expires_at > Utc::now() && a.purpose == purpose)
            .ok_or(ActivationError::InvalidToken)?;
        entry.used = true;
        Ok((entry.user_id.clone(), entry.new_email.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokens_are_256_bit_hex_and_unique() {
        let a = new_token();
        let b = new_token();
        assert_eq!(a.len(), 64);
        assert!(a.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b);
    }

    #[test]
    fn purpose_round_trips() {
        for purpose in [ActivationPurpose::Activate, ActivationPurpose::EmailChange] {
            assert_eq!(ActivationPurpose::parse(purpose.as_str()), Some(purpose));
        }
        assert_eq!(ActivationPurpose::parse("RESET"), None);
    }

    #[test]
    fn link_carries_the_token_under_the_public_url() {
        let link = public_link("activate", "abc");
        assert!(link.ends_with("/#/activate?token=abc"));
    }

    #[test]
    fn invalid_token_message_is_the_public_constant() {
        assert_eq!(ActivationError::InvalidToken.to_string(), INVALID_TOKEN);
    }
}
