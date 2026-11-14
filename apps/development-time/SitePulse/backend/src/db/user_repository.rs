use chrono::{DateTime, Utc};
use deadpool_postgres::Pool;
use tracing::{info, warn};

use super::base::{parse_id_to_i64, require_id};
use crate::models::{AuthProvider, Role, UnitInviteLinkResponse, User};
pub async fn save_user(
    pool: &Pool,
    user: &User,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut connection = pool.get().await?;
    let client = connection.transaction().await?;
    let role_str = user.role.as_str();
    let email = crate::domain::email::NormalizedEmail::normalize(&user.email);
    let site_id_num = if user.site_id.is_empty() {
        None
    } else {
        Some(require_id("site", &user.site_id)?)
    };

    // Resolve, link, and synchronize person_id
    let person_id: Option<i64> = if let Some(pid) = user.person_id {
        if !user.full_name.is_empty() {
            client
                .execute(
                    "UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3",
                    &[&user.full_name, &user.phone, &pid],
                )
                .await?;
        }
        Some(pid)
    } else {
        let p_row = client
            .query_opt(
                "SELECT id FROM persons WHERE site_id IS NOT DISTINCT FROM $2 AND LOWER(email) = $1 AND deleted_at IS NULL",
                &[&email, &site_id_num],
            )
            .await?;
        if let Some(r) = p_row {
            let pid: i64 = r.get(0);
            if !user.full_name.is_empty() {
                client
                    .execute(
                        "UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3",
                        &[&user.full_name, &user.phone, &pid],
                    )
                    .await?;
            }
            Some(pid)
        } else if !user.full_name.is_empty() {
            let p_type = match user.role {
                Role::HomeOwner => "HOME_OWNER",
                Role::HomeResident => "HOME_RESIDENT",
                Role::SaasAdmin => "SAAS_ADMIN",
                Role::SiteManager => "SITE_MANAGER",
                Role::Auditor => "AUDITOR",
            };
            Some(if let Some(site_id) = site_id_num {
                super::person_repository::resolve_new_site_person(
                    &client,
                    &user.full_name,
                    Some(&user.phone),
                    Some(&email),
                    p_type,
                    site_id,
                    false,
                )
                .await?
            } else {
                super::person_repository::insert_site_person(
                    &client,
                    &user.full_name,
                    Some(&user.phone),
                    Some(&email),
                    p_type,
                    None,
                )
                .await?
            })
        } else {
            None
        }
    };

    // Accounts are identified by e-mail (unique, case-insensitive). The database
    // assigns ids; an in-memory id is never used to pick the row to overwrite.
    let updated = client
        .execute(
            r#"
            UPDATE users SET
                site_id = COALESCE($1, site_id),
                password_hash = COALESCE($3, password_hash),
                role = $4,
                must_change_password = $5,
                auth_provider = $6,
                google_sub = COALESCE($7, google_sub),
                avatar_url = COALESCE($8, avatar_url),
                person_id = COALESCE($9, person_id)
            WHERE LOWER(email) = $2 AND is_active
            "#,
            &[
                &site_id_num,
                &email,
                &user.password_hash,
                &role_str,
                &user.must_change_password,
                &user.auth_provider,
                &user.google_sub,
                &user.avatar_url,
                &person_id,
            ],
        )
        .await?;
    if updated == 0 {
        client
            .execute(
                r#"
                INSERT INTO users (site_id, email, password_hash, role, must_change_password, auth_provider, google_sub, avatar_url, person_id, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                "#,
                &[
                    &site_id_num,
                    &email,
                    &user.password_hash,
                    &role_str,
                    &user.must_change_password,
                    &user.auth_provider,
                    &user.google_sub,
                    &user.avatar_url,
                    &person_id,
                    &user.created_at,
                ],
            )
            .await?;
    }
    client.commit().await?;
    Ok(())
}

pub async fn save_invitation_token(
    pool: &Pool,
    invite: &UnitInviteLinkResponse,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = if invite.unit_id.is_empty() {
        None
    } else {
        parse_id_to_i64(&invite.unit_id)
    };
    client
        .execute(
            r#"
            INSERT INTO invitation_tokens (token, token_type, unit_id, building, unit_number, relationship, invite_url, security_notice, expires_at)
            VALUES ($1, 'UNIT', $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (token) DO UPDATE SET
                expires_at = EXCLUDED.expires_at
            "#,
            &[
                &invite.token,
                &unit_id_num,
                &invite.building,
                &invite.unit_number,
                &invite.relationship,
                &invite.invite_url,
                &invite.security_notice,
                &invite.expires_at,
            ],
        )
        .await?;
    info!("Saved unit invitation to PostgreSQL");
    Ok(())
}

/// Records a bank webhook transaction id. Returns `false` when it was already processed.
/// Removes every recoverable clear-text password from `users`: legacy placeholder
/// formats (`ARGON2_HASH_x`, `HASH_x`, `argon2id_hash_placeholder:x`, plaintext) are
/// re-hashed with argon2id and the account must change its password on next login.
/// Unsalted SHA-256 digests cannot be upgraded, so those accounts are locked until
/// an administrator resets them. Returns the number of rows changed.
pub async fn upgrade_legacy_password_hashes(
    pool: &Pool,
) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let rows = client
        .query("SELECT id, password_hash FROM users WHERE password_hash IS NOT NULL AND password_hash NOT LIKE '$argon2%'", &[])
        .await?;
    let mut changed = 0;
    for row in rows {
        let id: i64 = row.get(0);
        let stored: String = row.get(1);
        let new_hash = match crate::auth::legacy_plaintext(&stored) {
            Some(plain) => crate::auth::hash_password_async(plain).await?,
            None => crate::auth::hash_password_async(uuid::Uuid::new_v4().to_string()).await?,
        };
        changed += client
            .execute(
                "UPDATE users SET password_hash = $1, must_change_password = TRUE WHERE id = $2",
                &[&new_hash, &id],
            )
            .await?;
    }
    if changed > 0 {
        warn!("Upgraded {} legacy password hash(es) to argon2id; affected users must change their password", changed);
    }
    Ok(changed)
}

/// Creates the first SaaS administrator when none exists (see `bootstrap_admin_password`).
pub async fn ensure_bootstrap_admin(
    pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let exists = client
        .query_opt("SELECT 1 FROM users WHERE role = 'SAAS_ADMIN' LIMIT 1", &[])
        .await?
        .is_some();
    if exists {
        return Ok(());
    }
    let email = std::env::var("SITEPULSE_BOOTSTRAP_ADMIN_EMAIL")
        .unwrap_or_else(|_| "admin@sitepulse.io".to_string())
        .to_lowercase();
    let hash = crate::auth::hash_password_async(crate::state::bootstrap_admin_password()).await?;
    // Platform people have no site; persons are unique per site, so look up before inserting.
    let existing = client
        .query_opt(
            "SELECT id FROM persons WHERE site_id IS NULL AND lower(email) = $1 AND deleted_at IS NULL",
            &[&email],
        )
        .await?;
    let person_id: i64 = match existing {
        Some(row) => row.get(0),
        None => {
            super::person_repository::insert_platform_person(
                &client,
                "SaaS Platform Admin",
                &email,
                "SAAS_ADMIN",
            )
            .await?
        }
    };
    client
        .execute(
            "INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
             VALUES (NULL, $1, $2, $3, 'SAAS_ADMIN', TRUE)",
            &[&person_id, &email, &hash],
        )
        .await?;
    warn!("Created bootstrap SaaS administrator {}", email);
    Ok(())
}

pub async fn delete_invitation_token(
    pool: &Pool,
    token_digest: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            "DELETE FROM invitation_tokens WHERE token = $1",
            &[&token_digest],
        )
        .await?;
    Ok(())
}

pub async fn get_user_by_email(
    pool: &Pool,
    email: &str,
) -> Result<Option<User>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let email_norm = crate::domain::email::NormalizedEmail::normalize(email);
    let row = client
        .query_opt(
            "SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
             FROM users u
             LEFT JOIN persons p ON u.person_id = p.id
             WHERE LOWER(u.email) = $1 AND u.is_active LIMIT 1",
            &[&email_norm],
        )
        .await?;

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: Option<i64> = row.get(1);
        let full_name: String = row.get(2);
        let email: String = row.get(3);
        let phone: Option<String> = row.get(4);
        let password_hash: Option<String> = row.get(5);
        let role_str: String = row.get(6);
        let must_change_password: bool = row.get(7);
        let auth_provider: Option<String> = row.get(8);
        let google_sub: Option<String> = row.get(9);
        let avatar_url: Option<String> = row.get(10);
        let created_at: Option<DateTime<Utc>> = row.get(11);
        let person_id: Option<i64> = row.try_get(12).ok().flatten();

        let user = User {
            id: id.to_string(),
            site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
            full_name,
            email,
            phone: phone.unwrap_or_default(),
            password_hash,
            role: Role::parse(&role_str)?,
            must_change_password,
            auth_provider: auth_provider
                .as_deref()
                .map(AuthProvider::from_str_loose)
                .unwrap_or(AuthProvider::Local),
            google_sub,
            avatar_url,
            created_at: created_at.unwrap_or_else(Utc::now),
            person_id,
        };
        return Ok(Some(user));
    }
    Ok(None)
}

pub async fn get_user_by_id(
    pool: &Pool,
    user_id: &str,
) -> Result<Option<User>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    get_user_by_id_from_client(&client, user_id).await
}

/// Read current identity using an already attributed repository connection.
///
/// # Errors
/// Propagates database and identity decoding failures.
pub async fn get_user_by_id_from_client(
    client: &tokio_postgres::Client,
    user_id: &str,
) -> Result<Option<User>, Box<dyn std::error::Error + Send + Sync>> {
    let id_num = parse_id_to_i64(user_id);
    let row = if let Some(num) = id_num {
        client
            .query_opt(
                "SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
                 FROM users u
                 LEFT JOIN persons p ON u.person_id = p.id
                 WHERE u.id = $1 LIMIT 1",
                &[&num],
            )
            .await?
    } else {
        None
    };

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: Option<i64> = row.get(1);
        let full_name: String = row.get(2);
        let email: String = row.get(3);
        let phone: Option<String> = row.get(4);
        let password_hash: Option<String> = row.get(5);
        let role_str: String = row.get(6);
        let must_change_password: bool = row.get(7);
        let auth_provider: Option<String> = row.get(8);
        let google_sub: Option<String> = row.get(9);
        let avatar_url: Option<String> = row.get(10);
        let created_at: Option<DateTime<Utc>> = row.get(11);
        let person_id: Option<i64> = row.try_get(12).ok().flatten();

        let user = User {
            id: id.to_string(),
            site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
            full_name,
            email,
            phone: phone.unwrap_or_default(),
            password_hash,
            role: Role::parse(&role_str)?,
            must_change_password,
            auth_provider: auth_provider
                .as_deref()
                .map(AuthProvider::from_str_loose)
                .unwrap_or(AuthProvider::Local),
            google_sub,
            avatar_url,
            created_at: created_at.unwrap_or_else(Utc::now),
            person_id,
        };
        return Ok(Some(user));
    }
    Ok(None)
}
