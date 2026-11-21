use chrono::Utc;
use regex::Regex;
use std::sync::LazyLock;

use rust_decimal::Decimal;

use crate::models::{
    AuthProvider, DebtStatus, DebtorType, HomeOwnerResponse, IndependentUnit, OccupancyStatus,
    RegisterHomeOwnerRequest, Role, UnitMemberDto, User,
};
use crate::services::account_activation_service::{
    self as activation, AccountActivationService, ActivationPurpose, IssuedToken,
};
use crate::services::virtual_iban_service::VirtualIbanService;
use crate::state::AppState;

/// Refusal for deleting a unit that has payments, receipts, advance history, paid dues or a matured receivable.
pub const UNIT_HAS_FINANCIAL_HISTORY: &str =
    "Bu dairenin finansal geçmişi (ödeme, makbuz, avans, ödenmiş veya vadesi geçmiş aidat) var; silinemez. Tahliye veya malik devri kullanın.";

/// S8: one refusal for an address in use anywhere, without echoing it back.
pub const EMAIL_NOT_AVAILABLE: &str =
    "This email address cannot be used for a new account. Check it or contact support.";

/// A login email change was asked without identity permission and a recent step-up.
pub const LOGIN_CHANGE_NEEDS_STEP_UP: &str =
    "Changing a login email requires identity permission and a recent password check.";

/// Monthly dues used when neither a house type tariff nor an amount is given (F4).
pub const DEFAULT_MONTHLY_DUES: Decimal = Decimal::from_parts(140000, 0, 0, false, 2);
/// Response warning: the dues amount was not given and the default was used.
pub const WARNING_DUES_DEFAULTED: &str = "DUES_DEFAULTED";
/// Response warning: no land share was given; the site's most common share was used.
pub const WARNING_LAND_SHARE_DEFAULTED: &str = "LAND_SHARE_DEFAULTED";
static EMAIL_PATTERN: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"));

/// A land share that is not a positive whole number.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("Land share must be a positive whole number of shares.")]
pub struct InvalidLandShare;

/// F3: a land share is a positive whole number of shares; `n/d` from older clients reads as `n`.
pub fn parse_land_share(value: Option<&str>) -> Result<Option<i32>, InvalidLandShare> {
    let Some(raw) = value.map(str::trim).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };
    let numerator = match raw.split_once('/') {
        Some((numerator, denominator)) => {
            if denominator.contains('/')
                || !matches!(denominator.trim().parse::<i32>(), Ok(value) if value > 0)
            {
                return Err(InvalidLandShare);
            }
            numerator.trim()
        }
        None => raw,
    };
    numerator
        .parse::<i32>()
        .ok()
        .filter(|n| *n > 0)
        .map(Some)
        .ok_or(InvalidLandShare)
}

/// The chosen person is not one of this site's people.
pub const PERSON_NOT_FOUND: &str = "Person not found";

/// The unit is not in this site (or does not exist); never answered with invented data.
pub const UNIT_NOT_FOUND: &str = "Unit not found";
/// A household member joins the active occupancy; a vacant unit has none.
pub const NO_HOUSEHOLD_TO_JOIN: &str =
    "The unit is vacant; move a tenant or the owner in before adding household members";

/// A login email change staged until the new address confirms it.
struct PendingEmailChange {
    user_id: String,
    name: String,
    old_email: String,
    new_email: String,
    issued: IssuedToken,
}

/// Why a person's email change was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum EmailChangeError {
    #[error("{0}")]
    Invalid(String),
    #[error("{EMAIL_NOT_AVAILABLE}")]
    NotAvailable,
    #[error("{UNIT_NOT_FOUND}")]
    NotFound,
    /// A login email change needs `PersonIdentityManage` and a recent step-up.
    #[error("{LOGIN_CHANGE_NEEDS_STEP_UP}")]
    LoginChangeNotAllowed,
    #[error("DB error: {0}")]
    Storage(String),
}

fn email_storage(e: impl std::fmt::Display) -> EmailChangeError {
    EmailChangeError::Storage(e.to_string())
}

/// S5: change a person's email. A contact-only person is updated at once; a person
/// with a login gets a confirmation link at the new address and keeps the old login
/// until it is used.
async fn stage_person_email_change<C: deadpool_postgres::GenericClient>(
    client: &C,
    person_id: i64,
    requested: &str,
    site: i64,
    changes: &mut Vec<PendingEmailChange>,
    login_change_allowed: bool,
) -> Result<(), EmailChangeError> {
    let new_email = crate::domain::email::NormalizedEmail::normalize(requested);
    validate_email(&new_email).map_err(EmailChangeError::Invalid)?;
    let row = client
        .query_opt(
            "SELECT COALESCE(p.email, ''), p.full_name, u.id, COALESCE(u.email, '') FROM persons p \
             LEFT JOIN users u ON u.person_id = p.id AND u.is_active \
             WHERE p.id = $1 AND (p.site_id = $2 OR p.site_id IS NULL) LIMIT 1",
            &[&person_id, &site],
        )
        .await
        .map_err(email_storage)?
        .ok_or(EmailChangeError::NotFound)?;
    let contact_email: String = row.get(0);
    let name: String = row.get(1);
    let user_id: Option<i64> = row.get(2);
    let login_email: String = row.get(3);
    let current = if login_email.is_empty() {
        contact_email
    } else {
        login_email
    };
    if crate::domain::email::same_email(&current, &new_email) {
        return Ok(());
    }
    let taken_in_site = client
        .query_opt(
            "SELECT 1 FROM persons WHERE site_id = $1 AND lower(email) = $2 AND id <> $3 AND deleted_at IS NULL",
            &[&site, &new_email, &person_id],
        )
        .await
        .map_err(email_storage)?
        .is_some();
    if taken_in_site {
        return Err(EmailChangeError::NotAvailable);
    }
    match user_id {
        None => {
            client
                .execute(
                    "UPDATE persons SET email = $1 WHERE id = $2",
                    &[&new_email, &person_id],
                )
                .await
                .map_err(email_storage)?;
        }
        Some(user_id) => {
            if !login_change_allowed {
                return Err(EmailChangeError::LoginChangeNotAllowed);
            }
            let taken = client
                .query_opt(
                    "SELECT 1 FROM users WHERE lower(email) = $1 AND id <> $2 AND is_active",
                    &[&new_email, &user_id],
                )
                .await
                .map_err(email_storage)?
                .is_some();
            if taken {
                return Err(EmailChangeError::NotAvailable);
            }
            let issued = activation::issue_in(
                client,
                user_id,
                Some(site),
                ActivationPurpose::EmailChange,
                Some(&new_email),
            )
            .await
            .map_err(email_storage)?;
            changes.push(PendingEmailChange {
                user_id: user_id.to_string(),
                name,
                old_email: current,
                new_email,
                issued,
            });
        }
    }
    Ok(())
}

/// The no-database counterpart of [`stage_person_email_change`] for a login user.
fn stage_memory_email_change(
    inner: &mut crate::state::AppStateInner,
    user_idx: usize,
    requested: &str,
    changes: &mut Vec<PendingEmailChange>,
    login_change_allowed: bool,
) -> Result<(), EmailChangeError> {
    let new_email = crate::domain::email::NormalizedEmail::normalize(requested);
    validate_email(&new_email).map_err(EmailChangeError::Invalid)?;
    let user = inner.users[user_idx].clone();
    if crate::domain::email::same_email(&user.email, &new_email) {
        return Ok(());
    }
    if !login_change_allowed {
        return Err(EmailChangeError::LoginChangeNotAllowed);
    }
    if inner
        .users
        .iter()
        .any(|u| u.id != user.id && crate::domain::email::same_email(&u.email, &new_email))
    {
        return Err(EmailChangeError::NotAvailable);
    }
    let issued = activation::issue_in_memory(
        inner,
        &user.id,
        ActivationPurpose::EmailChange,
        Some(&new_email),
    );
    changes.push(PendingEmailChange {
        user_id: user.id,
        name: user.full_name,
        old_email: user.email,
        new_email,
        issued,
    });
    Ok(())
}

pub struct SiteAdminService {
    state: AppState,
}

pub fn validate_email(email: &str) -> Result<(), String> {
    let email = email.trim();
    if email.is_empty() {
        return Err("E-posta adresi boş bırakılamaz.".to_string());
    }
    let pattern = EMAIL_PATTERN
        .as_ref()
        .map_err(|_| "Email validation is unavailable".to_string())?;
    if !pattern.is_match(email) {
        return Err("Geçerli bir e-posta adresi giriniz (örn: sakin@sitepulse.io).".to_string());
    }
    Ok(())
}

pub fn validate_phone(phone: &str) -> Result<(), String> {
    let phone_trimmed = phone.trim();
    if phone_trimmed.is_empty() {
        return Err("Telefon numarası boş bırakılamaz.".to_string());
    }
    let clean: String = phone_trimmed
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect();
    if clean.is_empty() {
        return Err("Telefon numarası geçerli rakamlar içermelidir.".to_string());
    }
    let is_valid = (clean.len() == 10 && clean.starts_with('5'))
        || (clean.len() == 11 && clean.starts_with("05"))
        || (clean.len() == 12 && clean.starts_with("905"));

    if !is_valid {
        return Err("Geçerli bir cep telefonu numarası giriniz (örn: 05XX XXX XX XX).".to_string());
    }
    Ok(())
}

/// The code a block is registered under: "a blok", "A-Blok" and "A" are all `A`;
/// an empty name is `A`.
pub fn block_code(name: &str) -> String {
    let code = name
        .to_uppercase()
        .replace("BLOK", "")
        .replace(['-', '_', ' '], "")
        .trim()
        .to_string();
    if code.is_empty() {
        "A".to_string()
    } else {
        code
    }
}

impl SiteAdminService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn register_home_owner(
        &self,
        site_id: &str,
        request: RegisterHomeOwnerRequest,
    ) -> Result<HomeOwnerResponse, String> {
        if site_id.trim().is_empty() {
            return Err("Site ID cannot be empty".to_string());
        }
        let mut request = request;
        prefill_person_refs(&self.state, site_id, &mut request)
            .await
            .map_err(|e| e.to_string())?;
        if request.owner_full_name.trim().is_empty() {
            return Err("Home owner name cannot be empty".to_string());
        }
        if request.block.trim().is_empty() {
            return Err("Block name cannot be empty".to_string());
        }

        // Validate email & phone
        validate_email(&request.email)?;
        validate_phone(&request.phone)?;
        if let Some(email) = request
            .tenant_email
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            validate_email(email)?;
        }
        if let Some(phone) = request
            .tenant_phone
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            validate_phone(phone)?;
        }

        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);

        // PostgreSQL owns active identity availability; cached people can outlive archival.
        if self.state.pool.is_none() {
            let inner = self.state.inner.read().await;
            if inner
                .users
                .iter()
                .any(|u| crate::domain::email::same_email(&u.email, &email_norm))
            {
                return Err(EMAIL_NOT_AVAILABLE.to_string());
            }
        }

        let effective_clean_block = block_code(&request.block);
        let formatted_block_name = format!("{} Blok", effective_clean_block);

        let effective_floor = if request.floor > 0 {
            request.floor
        } else {
            ((request.unit_no - 1) / 4) + 1
        };

        let effective_house_type = request
            .house_type
            .clone()
            .or_else(|| Some("2+1".to_string()));
        let custom_tariff_override = request.monthly_dues;
        let mut resolved_dues = request.monthly_dues;

        // Resolve monthly dues from house_type tariff
        if let Some(ref ht_name) = effective_house_type {
            let inner = self.state.inner.read().await;
            if let Some(tariff) = inner.house_types.iter().find(|t| {
                (t.site_id == site_id
                    || crate::db::parse_id_to_i64(&t.site_id)
                        == crate::db::parse_id_to_i64(site_id))
                    && t.type_name.eq_ignore_ascii_case(ht_name)
            }) {
                if resolved_dues.is_none() {
                    resolved_dues = Some(tariff.dues_amount);
                }
            }
        }
        // F4: a fallback amount is never applied silently; the response says so.
        let mut warnings: Vec<String> = Vec::new();
        let monthly_dues = resolved_dues.unwrap_or_else(|| {
            warnings.push(WARNING_DUES_DEFAULTED.to_string());
            DEFAULT_MONTHLY_DUES
        });
        // F3: the unit's land share weights capital costs, so it is stored as given.
        let requested_land_share =
            parse_land_share(request.land_share.as_deref()).map_err(|e| e.to_string())?;
        let mut effective_land_share = requested_land_share.unwrap_or(1);

        // Parse numeric IDs
        let site_numeric_id = crate::db::require_id("entity", site_id)?;
        let viban = VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_numeric_id.to_string(),
            &format!("blok-{}", effective_clean_block),
            request.unit_no,
        )
        .map_err(|e| e.to_string())?;

        let mut user_numeric_id = 0i64;
        #[allow(unused_assignments)]
        let mut person_numeric_id = 0i64;
        let mut block_numeric_id = 1i64;
        let mut unit_numeric_id = 0i64;
        let req_role = request.role.as_deref().unwrap_or("OWNER").to_uppercase();
        let is_tenant = req_role == "TENANT";
        let is_resident_only = req_role == "RESIDENT";
        let has_explicit_tenant = request
            .tenant_full_name
            .as_ref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);
        let mut explicit_tenant_pid: Option<i64> = None;
        // Activation tokens issued inside the transaction, delivered after commit:
        // (user id, display name, email).
        let mut pending_activations: Vec<(i64, String, String, IssuedToken)> = Vec::new();
        // Whether PostgreSQL holds the data (and its tokens); otherwise memory is the store.
        let mut persisted = false;

        let registration_today = {
            let inner = self.state.inner.read().await;
            crate::services::finance_common::site_today(&inner, site_id)
        };
        // 2. Persist to PostgreSQL if pool is available
        if let Some(ref pool) = self.state.pool {
            let mut connection = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;
            // F11: the person, account, block, unit, occupancy and dues are one unit of work.
            let client = connection
                .transaction()
                .await
                .map_err(|e| format!("Transaction error: {}", e))?;
            persisted = true;
            // Tenant guardrail (RLS, V25): the new unit and its dues stay in this site.
            crate::db::tx_bind_tenant(&client, site_numeric_id)
                .await
                .map_err(|e| format!("Transaction error: {}", e))?;

            // The owner reference is resolved in this transaction, so the card and the
            // registration commit or roll back together.
            let owner_ref_pid: Option<i64> = match &request.owner {
                Some(reference) => Some(
                    crate::services::person_service::resolve_person_ref(
                        &client,
                        site_numeric_id,
                        reference,
                    )
                    .await
                    .map_err(|e| e.to_string())?,
                ),
                None => None,
            };

            // Check duplicate email in DB. An owner card that already has this login
            // keeps it: registering another unit must not need a second account.
            let existing_user = client
                .query_opt(
                    "SELECT id, person_id FROM users WHERE LOWER(email) = $1 AND is_active",
                    &[&email_norm],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;
            let reused_user_id: Option<i64> = match (&existing_user, owner_ref_pid) {
                (Some(row), Some(pid)) if row.get::<_, Option<i64>>(1) == Some(pid) => {
                    Some(row.get(0))
                }
                (Some(_), _) => return Err(EMAIL_NOT_AVAILABLE.to_string()),
                (None, _) => None,
            };

            // Find or create block
            let existing_block = client
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id = $1 AND (block_name ILIKE $2 OR block_name ILIKE $3)",
                    &[&site_numeric_id, &formatted_block_name, &effective_clean_block],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            block_numeric_id = if let Some(row) = existing_block {
                row.get(0)
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id",
                        &[&site_numeric_id, &formatted_block_name],
                    )
                    .await
                    .map_err(|e| format!("Failed to insert block: {}", e))?;
                row.get(0)
            };

            // Find or create person
            let person_type = if request.is_resident {
                "HOME_RESIDENT"
            } else {
                "HOME_OWNER"
            };
            // S1: a person is matched only inside this site.
            let existing_person = client
                .query_opt(
                    "SELECT id FROM persons WHERE site_id = $2 AND LOWER(email) = $1 AND deleted_at IS NULL",
                    &[&email_norm, &site_numeric_id],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            person_numeric_id = if let Some(pid) = owner_ref_pid {
                pid
            } else if let Some(row) = existing_person {
                row.get(0)
            } else {
                crate::db::person_repository::resolve_new_site_person(
                    &client,
                    &request.owner_full_name,
                    Some(&request.phone),
                    Some(&email_norm),
                    person_type,
                    site_numeric_id,
                    true,
                )
                .await
                .map_err(|e| format!("Failed to insert person: {}", e))?
            };

            // Insert user
            if let Some(existing_login) = reused_user_id {
                user_numeric_id = existing_login;
            } else {
                let user_role_str = if is_tenant || is_resident_only {
                    "HOME_RESIDENT"
                } else {
                    "HOME_OWNER"
                };
                let user_row = client
                .query_one(
                    r#"
                    INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                    VALUES ($1, $2, $3, NULL, $4, TRUE)
                    RETURNING id
                    "#,
                    &[
                        &site_numeric_id,
                        &person_numeric_id,
                        &email_norm,
                        &user_role_str,
                    ],
                )
                .await
                .map_err(|e| format!("Failed to insert user: {}", e))?;
                user_numeric_id = user_row.get(0);
                // S2/S3: no password is issued; the person sets one through their own link.
                let issued = activation::issue_in(
                    &client,
                    user_numeric_id,
                    Some(site_numeric_id),
                    ActivationPurpose::Activate,
                    None,
                )
                .await
                .map_err(|e| e.to_string())?;
                pending_activations.push((
                    user_numeric_id,
                    request.owner_full_name.clone(),
                    email_norm.clone(),
                    issued,
                ));
            }

            // Handle optional explicit tenant when registered together with owner
            let mut explicit_tenant_person_id: Option<i64> = None;

            if has_explicit_tenant {
                let t_name = request.tenant_full_name.as_deref().unwrap_or("").trim();
                let t_phone = request.tenant_phone.as_deref().unwrap_or("").trim();
                let t_email_norm = crate::domain::email::NormalizedEmail::normalize(
                    request.tenant_email.as_deref().unwrap_or(""),
                );

                let existing_t_person = if !t_email_norm.is_empty() {
                    client
                        .query_opt(
                            "SELECT id FROM persons WHERE site_id = $2 AND LOWER(email) = $1 AND deleted_at IS NULL",
                            &[&t_email_norm, &site_numeric_id],
                        )
                        .await
                        .map_err(|e| format!("DB query error: {}", e))?
                } else {
                    None
                };

                let tenant_ref_pid: Option<i64> = match &request.tenant {
                    Some(reference) => Some(
                        crate::services::person_service::resolve_person_ref(
                            &client,
                            site_numeric_id,
                            reference,
                        )
                        .await
                        .map_err(|e| e.to_string())?,
                    ),
                    None => None,
                };
                let t_pid: i64 = if let Some(pid) = tenant_ref_pid {
                    pid
                } else if let Some(row) = existing_t_person {
                    row.get(0)
                } else {
                    crate::db::person_repository::resolve_new_site_person(
                        &client,
                        t_name,
                        Some(t_phone),
                        Some(&t_email_norm),
                        "HOME_RESIDENT",
                        site_numeric_id,
                        true,
                    )
                    .await
                    .map_err(|e| format!("Failed to insert tenant person: {}", e))?
                };
                explicit_tenant_person_id = Some(t_pid);
                explicit_tenant_pid = Some(t_pid);

                if !t_email_norm.is_empty() {
                    let existing_t_user = client
                        .query_opt(
                            "SELECT id FROM users WHERE LOWER(email) = $1 AND is_active",
                            &[&t_email_norm],
                        )
                        .await
                        .map_err(|e| format!("DB query error: {}", e))?;
                    if existing_t_user.is_none() {
                        // S2: the tenant gets their own account and their own activation link.
                        let tenant_user_id: i64 = client
                            .query_one(
                                r#"
                                INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                                VALUES ($1, $2, $3, NULL, 'HOME_RESIDENT', TRUE)
                                RETURNING id
                                "#,
                                &[&site_numeric_id, &t_pid, &t_email_norm],
                            )
                            .await
                            .map_err(|e| e.to_string())?
                            .get(0);
                        let issued = activation::issue_in(
                            &client,
                            tenant_user_id,
                            Some(site_numeric_id),
                            ActivationPurpose::Activate,
                            None,
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                        pending_activations.push((
                            tenant_user_id,
                            t_name.to_string(),
                            t_email_norm.clone(),
                            issued,
                        ));
                    }
                }
            }

            if requested_land_share.is_none() {
                // The site's most common share, so a missing value does not shrink the unit's weight.
                let typical: Option<i32> = client
                    .query_one(
                        "SELECT mode() WITHIN GROUP (ORDER BY land_share) FROM units WHERE site_id = $1 AND deleted_at IS NULL",
                        &[&site_numeric_id],
                    )
                    .await
                    .map_err(|e| format!("DB query error: {}", e))?
                    .get(0);
                effective_land_share = typical.unwrap_or(1);
            }

            // Check if unit already exists
            let existing_unit_opt = client
                .query_opt(
                    "SELECT id, owner_person_id, tenant_person_id, occupancy_status FROM units WHERE block_id = $1 AND unit_number = $2",
                    &[&block_numeric_id, &request.unit_no],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            if let Some(existing_unit) = existing_unit_opt {
                unit_numeric_id = existing_unit.get("id");

                if is_resident_only {
                    client
                        .execute(
                            r#"
                            INSERT INTO occupancy_members (occupancy_id, person_id, resident_user_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
                            SELECT uo.id, $2, $3, $4, 'OTHER', $5, $6, false, CURRENT_TIMESTAMP
                            FROM unit_occupancies uo
                            WHERE uo.unit_id = $1 AND uo.is_active = true
                            "#,
                            &[
                                &unit_numeric_id,
                                &Some(person_numeric_id),
                                &Some(user_numeric_id),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await.map_err(|e| e.to_string())?;
                } else {
                    // T1 (+T2) through the guarded transitions: an existing
                    // owner is never replaced and no session is closed here.
                    register_occupancy(
                        &client,
                        site_numeric_id,
                        unit_numeric_id,
                        registration_today,
                        person_numeric_id,
                        is_tenant,
                        request.is_resident && !has_explicit_tenant,
                        explicit_tenant_person_id,
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                    client
                        .execute(
                            "UPDATE units SET house_type = COALESCE($1, house_type), virtual_iban = COALESCE(virtual_iban, $2), monthly_tariff_override = COALESCE($3, monthly_tariff_override) WHERE id = $4",
                            &[&effective_house_type, &viban, &custom_tariff_override, &unit_numeric_id],
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                }
            } else {
                // New Unit: owner, tenant and status are projections that the
                // transitions below fill in.
                let owner_pid: Option<i64> = None;
                let tenant_pid: Option<i64> = None;
                let occ_status = "VACANT";
                let unit_row = client
                    .query_one(
                        r#"
                        INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban, house_type, occupancy_status, monthly_tariff_override)
                        VALUES ($1, $2, $3, $4, $10, $5, $6, $7, $8, $9, $11)
                        ON CONFLICT (block_id, unit_number) DO UPDATE SET
                            deleted_at = NULL,
                            floor = EXCLUDED.floor,
                            owner_person_id = EXCLUDED.owner_person_id,
                            tenant_person_id = EXCLUDED.tenant_person_id,
                            house_type = EXCLUDED.house_type,
                            occupancy_status = EXCLUDED.occupancy_status,
                            monthly_tariff_override = COALESCE(EXCLUDED.monthly_tariff_override, units.monthly_tariff_override)
                        -- only an archived (soft-deleted) flat is revived; an active one still conflicts
                        WHERE units.deleted_at IS NOT NULL
                        RETURNING id
                        "#,
                        &[
                            &block_numeric_id,
                            &site_numeric_id,
                            &request.unit_no,
                            &effective_floor,
                            &owner_pid,
                            &tenant_pid,
                            &viban,
                            &effective_house_type,
                            &occ_status,
                            &effective_land_share,
                            &custom_tariff_override,
                        ],
                    )
                    .await
                    .map_err(|e| format!("Failed to insert unit: {}", e))?;
                unit_numeric_id = unit_row.get(0);
                if is_resident_only {
                    client
                        .execute(
                            r#"
                            INSERT INTO occupancy_members (occupancy_id, person_id, resident_user_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
                            SELECT uo.id, $2, $3, $4, 'OTHER', $5, $6, false, CURRENT_TIMESTAMP
                            FROM unit_occupancies uo
                            WHERE uo.unit_id = $1 AND uo.is_active = true
                            "#,
                            &[
                                &unit_numeric_id,
                                &Some(person_numeric_id),
                                &Some(user_numeric_id),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await.map_err(|e| e.to_string())?;
                } else {
                    register_occupancy(
                        &client,
                        site_numeric_id,
                        unit_numeric_id,
                        registration_today,
                        person_numeric_id,
                        is_tenant,
                        request.is_resident && !has_explicit_tenant,
                        explicit_tenant_person_id,
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                }
            }

            // An explicitly given land share also corrects an existing unit.
            if let Some(share) = requested_land_share {
                client
                    .execute(
                        "UPDATE units SET land_share = $1 WHERE id = $2",
                        &[&share, &unit_numeric_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
            }

            // Household members given by reference join the unit's active occupancy.
            for member in &request.members {
                let relationship =
                    crate::domain::household_relationship::HouseholdRelationship::from_input(
                        member.relationship.as_deref().unwrap_or("OTHER"),
                    )
                    .ok_or_else(|| {
                        crate::domain::household_relationship::UNKNOWN_RELATIONSHIP.to_string()
                    })?
                    .as_str();
                let member_pid = crate::services::person_service::resolve_person_ref(
                    &client,
                    site_numeric_id,
                    &member.person,
                )
                .await
                .map_err(|e| e.to_string())?;
                let joined = client
                    .execute(
                        r#"
                        INSERT INTO occupancy_members (occupancy_id, person_id, full_name, relationship, phone, email, is_emergency_contact)
                        SELECT uo.id, p.id, p.full_name, $3, COALESCE(p.phone, ''), COALESCE(p.email, ''), false
                        FROM unit_occupancies uo JOIN persons p ON p.id = $2
                        WHERE uo.unit_id = $1 AND uo.is_active AND uo.end_date IS NULL
                        ORDER BY uo.id DESC LIMIT 1
                        ON CONFLICT (occupancy_id, person_id) WHERE person_id IS NOT NULL
                        DO UPDATE SET relationship = EXCLUDED.relationship
                        "#,
                        &[&unit_numeric_id, &member_pid, &relationship],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                if joined == 0 {
                    return Err(NO_HOUSEHOLD_TO_JOIN.to_string());
                }
            }

            client
                .commit()
                .await
                .map_err(|e| format!("Transaction commit error: {}", e))?;
        }

        // 3. Update in-memory state
        let mut inner = self.state.inner.write().await;

        let user_id = if user_numeric_id > 0 {
            user_numeric_id.to_string()
        } else {
            let max_u = inner
                .users
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
            (max_u + 1).to_string()
        };

        let resident_user = User {
            id: user_id.clone(),
            site_id: site_id.to_string(),
            full_name: request.owner_full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone(),
            password_hash: None,
            role: if is_tenant || is_resident_only {
                Role::HomeResident
            } else {
                Role::HomeOwner
            },
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: if person_numeric_id > 0 {
                Some(person_numeric_id)
            } else {
                None
            },
        };
        let mut memory_activations: Vec<(String, String, String, IssuedToken)> = Vec::new();
        if !persisted {
            let issued = activation::issue_in_memory(
                &mut inner,
                &user_id,
                ActivationPurpose::Activate,
                None,
            );
            memory_activations.push((
                user_id.clone(),
                request.owner_full_name.clone(),
                email_norm.clone(),
                issued,
            ));
        }
        inner.users.push(resident_user.clone());

        let existing_unit_pos = inner.units.iter().position(|u| {
            (u.site_id == site_id || crate::auth::same_id(&u.site_id, site_id))
                && u.unit_number == request.unit_no
        });
        let unit_id = if let Some(pos) = existing_unit_pos {
            inner.units[pos].id.clone()
        } else if unit_numeric_id > 0 {
            unit_numeric_id.to_string()
        } else {
            format!("unit-{}", request.unit_no)
        };

        let block_id_str = if block_numeric_id > 0 {
            block_numeric_id.to_string()
        } else {
            format!("blok-{}", effective_clean_block)
        };

        if is_resident_only {
            let member_dto = crate::models::UnitMemberDto {
                resident_id: user_id.clone(),
                full_name: request.owner_full_name.clone(),
                relationship: "OTHER".to_string(),
                phone: request.phone.clone(),
                email: email_norm.clone(),
                is_owner: false,
                occupancy_id: None,
                person_id: None,
                resident_user_id: None,
            };
            inner
                .unit_members
                .entry(unit_id.clone())
                .or_default()
                .push(member_dto.clone());
            if unit_numeric_id > 0 {
                inner
                    .unit_members
                    .entry(unit_numeric_id.to_string())
                    .or_default()
                    .push(member_dto.clone());
            }
            let legacy_id = format!("d-{}", request.unit_no);
            if legacy_id != unit_id {
                inner
                    .unit_members
                    .entry(legacy_id)
                    .or_default()
                    .push(member_dto.clone());
            }
            let unit_prefix_id = format!("unit-{}", request.unit_no);
            if unit_prefix_id != unit_id {
                inner
                    .unit_members
                    .entry(unit_prefix_id)
                    .or_default()
                    .push(member_dto);
            }
        } else {
            let existing_owner_id =
                existing_unit_pos.and_then(|p| inner.units[p].owner_user_id.clone());
            let existing_tenant_id =
                existing_unit_pos.and_then(|p| inner.units[p].tenant_user_id.clone());

            let mut explicit_tenant_user_id_in_mem: Option<String> = None;
            if has_explicit_tenant {
                let max_u = inner
                    .users
                    .iter()
                    .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                    .max()
                    .unwrap_or(0);
                let tenant_email_norm = crate::domain::email::NormalizedEmail::normalize(
                    request.tenant_email.as_deref().unwrap_or(""),
                );
                let tid = pending_activations
                    .iter()
                    .find(|(_, _, email, _)| !email.is_empty() && *email == tenant_email_norm)
                    .map(|(id, _, _, _)| id.to_string())
                    .unwrap_or_else(|| (max_u + 1).to_string());
                let tenant_user = User {
                    id: tid.clone(),
                    site_id: site_id.to_string(),
                    full_name: request.tenant_full_name.clone().unwrap_or_default(),
                    email: request
                        .tenant_email
                        .clone()
                        .unwrap_or_default()
                        .trim()
                        .to_lowercase(),
                    phone: request.tenant_phone.clone().unwrap_or_default(),
                    password_hash: None,
                    role: Role::HomeResident,
                    must_change_password: true,
                    auth_provider: AuthProvider::Local,
                    google_sub: None,
                    avatar_url: None,
                    created_at: Utc::now(),
                    person_id: explicit_tenant_pid,
                };
                if !persisted && !tenant_user.email.is_empty() {
                    let issued = activation::issue_in_memory(
                        &mut inner,
                        &tid,
                        ActivationPurpose::Activate,
                        None,
                    );
                    memory_activations.push((
                        tid.clone(),
                        tenant_user.full_name.clone(),
                        tenant_user.email.clone(),
                        issued,
                    ));
                }
                inner.users.push(tenant_user);
                explicit_tenant_user_id_in_mem = Some(tid);
            }

            let unit = IndependentUnit {
                id: unit_id.clone(),
                site_id: site_id.to_string(),
                block_id: block_id_str,
                unit_number: request.unit_no,
                floor: effective_floor,
                land_share: effective_land_share,
                owner_user_id: if is_tenant && !has_explicit_tenant {
                    existing_owner_id
                } else {
                    Some(user_id.clone())
                },
                tenant_user_id: if has_explicit_tenant {
                    explicit_tenant_user_id_in_mem
                } else if is_tenant {
                    Some(user_id.clone())
                } else if request.is_resident {
                    None
                } else {
                    existing_tenant_id
                },
                virtual_iban: Some(viban),
                house_type: effective_house_type.clone(),
                monthly_tariff_override: custom_tariff_override,
                created_on: Some(Utc::now().date_naive()),
            };

            // Insert or update in-memory unit
            if let Some(pos) = existing_unit_pos {
                inner.units[pos] = unit.clone();
            } else {
                inner.units.push(unit.clone());
            }

            // Add legacy alias for unit
            let legacy_unit_id = format!("d-{}", request.unit_no);
            if !inner.units.iter().any(|u| u.id == legacy_unit_id) {
                let mut leg = unit.clone();
                leg.id = legacy_unit_id.clone();
                inner.units.push(leg);
            }

            // Register unit payer names
            inner
                .unit_payer_names
                .entry(unit.id.clone())
                .or_default()
                .push(request.owner_full_name.clone());
            inner
                .unit_payer_names
                .entry(legacy_unit_id.clone())
                .or_default()
                .push(request.owner_full_name.clone());

            if let Some(ref t_name) = request.tenant_full_name {
                inner
                    .unit_payer_names
                    .entry(unit.id.clone())
                    .or_default()
                    .push(t_name.clone());
                inner
                    .unit_payer_names
                    .entry(legacy_unit_id)
                    .or_default()
                    .push(t_name.clone());
            }
        }

        if !is_resident_only {
            let occ_type = if has_explicit_tenant || is_tenant {
                "TENANT"
            } else {
                "OWNER"
            };
            let history_key = unit_id.clone();
            let history_list = inner.unit_occupancies.entry(history_key).or_default();
            for item in history_list.iter_mut() {
                if item.is_active {
                    item.is_active = false;
                    item.end_date = Some(Utc::now().date_naive().to_string());
                    item.notes = Some(format!(
                        "{} • Ayrıldı (Yeni sakin devri)",
                        item.notes.as_deref().unwrap_or("")
                    ));
                }
            }
            if has_explicit_tenant {
                history_list.push(crate::models::OccupancyHistoryItem {
                    id: (history_list.len() + 1) as i64,
                    unit_id: unit_numeric_id,
                    person_id: 202,
                    person_name: request.tenant_full_name.clone().unwrap_or_default(),
                    person_phone: request.tenant_phone.clone(),
                    person_email: request.tenant_email.clone(),
                    role: DebtorType::Tenant,
                    start_date: Utc::now().date_naive().to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: Some("Yeni kiracı kaydı".to_string()),
                    created_at: Utc::now(),
                });
            } else if is_tenant || request.is_resident {
                history_list.push(crate::models::OccupancyHistoryItem {
                    id: (history_list.len() + 1) as i64,
                    unit_id: unit_numeric_id,
                    person_id: person_numeric_id,
                    person_name: request.owner_full_name.clone(),
                    person_phone: Some(request.phone.clone()),
                    person_email: Some(email_norm.clone()),
                    role: DebtorType::from_str_loose(occ_type),
                    start_date: Utc::now().date_naive().to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: Some(format!(
                        "Yeni {} kaydı",
                        if is_tenant { "kiracı" } else { "malik" }
                    )),
                    created_at: Utc::now(),
                });
            }
            let cloned = history_list.clone();
            inner
                .unit_occupancies
                .insert(request.unit_no.to_string(), cloned.clone());
            inner
                .unit_occupancies
                .insert(format!("unit-{}", request.unit_no), cloned.clone());
            inner
                .unit_occupancies
                .insert(format!("d-{}", request.unit_no), cloned);
        }

        let household = if is_resident_only {
            vec![crate::models::UnitMemberDto {
                resident_id: user_id.clone(),
                full_name: request.owner_full_name.clone(),
                relationship: "OTHER".to_string(),
                phone: request.phone.clone(),
                email: email_norm.clone(),
                is_owner: false,
                occupancy_id: None,
                person_id: None,
                resident_user_id: None,
            }]
        } else {
            Vec::new()
        };

        drop(inner);
        // Deliver after the data is committed, so a link never points at a rolled-back account.
        let activations = AccountActivationService::new(self.state.clone());
        let mut deliveries: Vec<(String, String, String, IssuedToken)> = pending_activations
            .into_iter()
            .map(|(id, name, email, issued)| (id.to_string(), name, email, issued))
            .collect();
        deliveries.extend(memory_activations);
        let mut owner_activation = None;
        let mut tenant_activation = None;
        for (id, name, email, issued) in &deliveries {
            let delivery = activations.deliver(
                &format!("user-{}", id),
                name,
                email,
                ActivationPurpose::Activate,
                issued,
            );
            if crate::auth::same_id(id, &user_id) {
                owner_activation = Some(delivery);
            } else {
                tenant_activation = Some(delivery);
            }
        }

        Ok(HomeOwnerResponse {
            primary_responsible: None,
            unit_id,
            site_id: site_id.to_string(),
            block: request.block,
            unit_no: request.unit_no,
            floor: effective_floor,
            owner_full_name: request.owner_full_name,
            email: email_norm,
            phone: request.phone,
            land_share: format!("{}/24", effective_land_share),
            monthly_dues,
            house_type: effective_house_type,
            is_resident: request.is_resident,
            activation: owner_activation,
            tenant_activation,
            pending_email_changes: Vec::new(),
            warnings: {
                if requested_land_share.is_none() {
                    warnings.push(WARNING_LAND_SHARE_DEFAULTED.to_string());
                }
                warnings
            },
            must_change_password: true,
            created_at: Utc::now(),
            occupancy_status: Some(if request.is_resident {
                OccupancyStatus::OwnerOccupied
            } else {
                OccupancyStatus::Vacant
            }),
            tenant_full_name: None,
            tenant_email: None,
            tenant_phone: None,
            operational_dues_balance: Some(Decimal::ZERO),
            capital_dues_balance: Some(Decimal::ZERO),
            advance_balance: None,
            household_residents: household,
            owner_person_id: None,
            tenant_person_id: None,
        })
    }

    pub async fn get_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let mut owners = self.load_home_owners_for_site(site_id).await;
        let inner = self.state.inner.read().await;
        for o in owners.iter_mut() {
            let stored = o.primary_responsible.clone().or_else(|| {
                if self.state.pool.is_none() {
                    inner.unit_primary_contacts.get(&o.unit_id).cloned()
                } else {
                    None
                }
            });
            o.primary_responsible = stored.and_then(|contact| {
                crate::services::responsible_contact_service::resolve_contact(
                    o,
                    &crate::models::SelectResponsibleContactRequest {
                        person_id: None,
                        role: contact.primary_responsible_role,
                        resident_name: contact.primary_responsible_name,
                        member_id: contact.primary_responsible_member_id,
                    },
                )
                .ok()
            });
            let unit = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, &o.unit_id))
                .map(|u| u.id.clone());
            o.advance_balance = Some(
                unit.map(|id| inner.advance_total(&id))
                    .unwrap_or(Decimal::ZERO)
                    .max(Decimal::ZERO),
            );
        }
        owners
    }

    async fn load_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(0);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let query = r#"
                    SELECT 
                        u.id::text as unit_id,
                        u.primary_responsible_contact,
                        u.site_id as site_id,
                        COALESCE(b.block_name, 'A Blok') as block_name,
                        COALESCE(u.unit_number, 0) as unit_number,
                        COALESCE(u.floor, 1) as floor,
                        COALESCE(po.full_name, 'Kat Maliki Tanımlanmamış') as full_name,
                        COALESCE(po.email, '') as email,
                        COALESCE(po.phone, '') as phone,
                        COALESCE(u.land_share, 24) as land_share,
                        u.house_type,
                        COALESCE(
                            u.monthly_tariff_override,
                            (SELECT ht.dues_amount FROM house_types ht WHERE ht.site_id = u.site_id AND LOWER(ht.type_name) = LOWER(u.house_type) LIMIT 1),
                            (SELECT principal_amount FROM dues_liabilities WHERE unit_id = u.id ORDER BY id DESC LIMIT 1),
                            1400.00
                        ) as monthly_dues,
                        COALESCE(usr.must_change_password, false) as must_change_password,
                        COALESCE(usr.created_at, NOW()) as created_at,
                        COALESCE(u.occupancy_status, 'OWNER_OCCUPIED') as occupancy_status,
                        pt.full_name as tenant_full_name,
                        pt.email as tenant_email,
                        pt.phone as tenant_phone,
                        u.owner_person_id as owner_person_id,
                        u.tenant_person_id as tenant_person_id,
                        COALESCE((SELECT SUM(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities WHERE unit_id = u.id AND status != 'PAID' AND (expense_type = 'OPERATIONAL_DUES' OR debtor_type = 'TENANT')), 0.00) as operational_dues_balance,
                        COALESCE((SELECT SUM(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities WHERE unit_id = u.id AND status != 'PAID' AND (expense_type = 'CAPITAL_DUES' OR debtor_type = 'OWNER')), 0.00) as capital_dues_balance,
                        CASE 
                            WHEN u.tenant_person_id IS NOT NULL THEN false
                            ELSE true
                        END as is_resident
                    FROM units u
                    LEFT JOIN blocks b ON u.block_id = b.id
                    LEFT JOIN persons po ON u.owner_person_id = po.id
                    LEFT JOIN persons pt ON u.tenant_person_id = pt.id
                    LEFT JOIN users usr ON LOWER(usr.email) = LOWER(po.email)
                    WHERE u.site_id = $1
                    ORDER BY b.block_name, u.unit_number
                "#;
                let mut household_map: std::collections::HashMap<
                    String,
                    Vec<crate::models::UnitMemberDto>,
                > = std::collections::HashMap::new();
                if let Some(m_rows) = crate::db::logged(client
                    .query(
                        r#"
                        SELECT uo.unit_id, om.id, om.full_name, om.relationship, COALESCE(om.phone, ''), COALESCE(om.email, ''), (uo.occupancy_type = 'OWNER'), om.occupancy_id, om.person_id
                        FROM occupancy_members om
                        JOIN unit_occupancies uo ON om.occupancy_id = uo.id
                        WHERE uo.is_active = true
                        ORDER BY om.id ASC
                        "#,
                        &[],
                    )
                    .await, "site_admin_service") {
                    for mr in m_rows {
                        let u_id: i64 = mr.get(0);
                        let u_id = u_id.to_string();
                        let mem = crate::models::UnitMemberDto {
                            resident_id: mr.get::<_, i64>(1).to_string(),
                            full_name: mr.get(2),
                            relationship: mr.get(3),
                            phone: mr.get(4),
                            email: mr.get(5),
                            is_owner: mr.get(6),
                            occupancy_id: mr.try_get(7).ok().flatten(),
                            person_id: mr.try_get(8).ok().flatten(),
                            resident_user_id: None,
                        };
                        household_map.entry(u_id).or_default().push(mem);
                    }
                }

                if let Some(rows) = crate::db::logged(
                    client.query(query, &[&site_numeric]).await,
                    "site_admin_service",
                ) {
                    if !rows.is_empty() {
                        let mut db_result = Vec::new();
                        let mut seen = std::collections::HashSet::new();
                        for r in rows {
                            let email: String = r.get("email");
                            let full_name: String = r.get("full_name");
                            let block_name: String = r.get("block_name");
                            let unit_no: i32 = r.get("unit_number");
                            let unit_id_val: String = r.get("unit_id");

                            let dedup_key = format!("{}-{}", block_name, unit_no);
                            if !seen.insert(dedup_key) {
                                continue;
                            }
                            let floor_val: i32 = r.get("floor");
                            let land_share_val: i32 = r.get("land_share");
                            let dues_val: Decimal = r.get("monthly_dues");
                            let is_resident: bool = r.get("is_resident");
                            let occ_status: String = r.get("occupancy_status");
                            let t_name: Option<String> = r.get("tenant_full_name");
                            let t_email: Option<String> = r.get("tenant_email");
                            let t_phone: Option<String> = r.get("tenant_phone");
                            let op_balance: Decimal = r.get("operational_dues_balance");
                            let cap_balance: Decimal = r.get("capital_dues_balance");

                            let mut household =
                                household_map.get(&unit_id_val).cloned().unwrap_or_default();
                            if household.is_empty() {
                                household = household_map
                                    .get(&unit_no.to_string())
                                    .cloned()
                                    .unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map
                                    .get(&format!("d-{}", unit_no))
                                    .cloned()
                                    .unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map
                                    .get(&format!("unit-{}", unit_no))
                                    .cloned()
                                    .unwrap_or_default();
                            }

                            db_result.push(HomeOwnerResponse {
                                primary_responsible: r
                                    .get::<_, Option<serde_json::Value>>(
                                        "primary_responsible_contact",
                                    )
                                    .and_then(|value| serde_json::from_value(value).ok()),
                                unit_id: unit_id_val,
                                site_id: site_id.to_string(),
                                block: block_name,
                                unit_no,
                                floor: floor_val,
                                owner_full_name: full_name,
                                email,
                                phone: r.get("phone"),
                                land_share: format!("{}/24", land_share_val),
                                monthly_dues: dues_val,
                                house_type: r.get("house_type"),
                                is_resident,
                                activation: None,
                                tenant_activation: None,
                                pending_email_changes: Vec::new(),
                                warnings: Vec::new(),
                                must_change_password: r.get("must_change_password"),
                                created_at: r.get("created_at"),
                                occupancy_status: Some(OccupancyStatus::from_str_loose(
                                    &occ_status,
                                )),
                                tenant_full_name: t_name,
                                tenant_email: t_email,
                                tenant_phone: t_phone,
                                operational_dues_balance: Some(op_balance),
                                capital_dues_balance: Some(cap_balance),
                                advance_balance: None,
                                household_residents: household,
                                owner_person_id: r.get("owner_person_id"),
                                tenant_person_id: r.get("tenant_person_id"),
                            });
                        }
                        return db_result;
                    }
                }
            }
        }

        // 2. In-memory fallback
        let inner = self.state.inner.read().await;
        let mut result = Vec::new();
        let mut seen = std::collections::HashSet::new();

        for user in inner.users.iter().filter(|u| {
            (u.site_id == site_id
                || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(site_id))
                && (u.role == Role::HomeResident || u.role == Role::HomeOwner)
        }) {
            let matching_unit = inner.units.iter().find(|u| {
                u.owner_user_id.as_deref() == Some(&user.id)
                    || u.tenant_user_id.as_deref() == Some(&user.id)
                    || inner
                        .unit_payer_names
                        .get(&u.id)
                        .map(|names| names.contains(&user.full_name))
                        .unwrap_or(false)
            });

            let (unit_id, block, unit_no, floor) = if let Some(u) = matching_unit {
                let clean_blk = u
                    .block_id
                    .to_uppercase()
                    .replace("BLOK", "")
                    .replace(['-', '_', ' '], "")
                    .trim()
                    .to_string();
                let effective_blk = if clean_blk.is_empty() {
                    u.block_id.clone()
                } else {
                    format!("{} Blok", clean_blk)
                };
                (u.id.clone(), effective_blk, u.unit_number, u.floor)
            } else {
                (format!("unit-{}", user.id), "A Blok".to_string(), 1, 1)
            };

            let dedup_key = format!("{}-{}", block, unit_no);
            if !seen.insert(dedup_key) {
                continue;
            }

            let monthly_dues = matching_unit
                .and_then(|u| u.monthly_tariff_override)
                .or_else(|| {
                    matching_unit.and_then(|u| {
                        let ht = u.house_type.as_deref()?;
                        inner
                            .house_types
                            .iter()
                            .find(|h| {
                                (h.site_id == site_id || crate::auth::same_id(&h.site_id, site_id))
                                    && h.type_name.eq_ignore_ascii_case(ht)
                            })
                            .map(|h| h.dues_amount)
                    })
                })
                .or_else(|| {
                    inner
                        .dues
                        .iter()
                        .find(|d| d.unit_id == unit_id)
                        .map(|d| d.principal_amount)
                })
                .unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());

            let household = inner
                .unit_members
                .get(&unit_id)
                .cloned()
                .unwrap_or_default();

            result.push(HomeOwnerResponse {
                primary_responsible: None,
                unit_id,
                site_id: site_id.to_string(),
                block,
                unit_no,
                floor,
                owner_full_name: user.full_name.clone(),
                email: user.email.clone(),
                phone: user.phone.clone(),
                land_share: "1/24".to_string(),
                monthly_dues,
                house_type: matching_unit.and_then(|u| u.house_type.clone()),
                is_resident: user.role == Role::HomeResident
                    || matching_unit
                        .map(|u| u.tenant_user_id.is_none())
                        .unwrap_or(true),
                activation: None,
                tenant_activation: None,
                pending_email_changes: Vec::new(),
                warnings: Vec::new(),
                must_change_password: user.must_change_password,
                created_at: user.created_at,
                occupancy_status: Some(OccupancyStatus::OwnerOccupied),
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                operational_dues_balance: Some(Decimal::ZERO),
                capital_dues_balance: Some(Decimal::ZERO),
                advance_balance: None,
                household_residents: household,
                owner_person_id: None,
                tenant_person_id: None,
            });
        }

        result
    }

    pub async fn update_home_owner(
        &self,
        site_id: &str,
        unit_or_user_id: &str,
        req: crate::models::UpdateHomeOwnerRequest,
        login_change_allowed: bool,
    ) -> Result<HomeOwnerResponse, String> {
        if let Some(email) = req.email.as_deref() {
            validate_email(email)?;
        }
        if let Some(phone) = req.phone.as_deref() {
            validate_phone(phone)?;
        }
        if let Some(email) = req
            .tenant_email
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            validate_email(email)?;
        }
        if let Some(phone) = req
            .tenant_phone
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            validate_phone(phone)?;
        }
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // The database unit this request resolved to; the in-memory update below
        // follows it so the two never touch different units.
        let mut resolved_unit_id: Option<String> = None;

        // Login email changes waiting for the new address to confirm them.
        let mut email_changes: Vec<PendingEmailChange> = Vec::new();
        // Whether PostgreSQL holds the data; otherwise memory is the store.
        let mut persisted = false;
        let edit_today = {
            let inner = self.state.inner.read().await;
            crate::services::finance_common::site_today(&inner, site_id)
        };

        // 1. If DB pool is available, update database
        if let Some(ref pool) = self.state.pool {
            {
                let mut connection = pool
                    .get()
                    .await
                    .map_err(|e| format!("Database connection error: {}", e))?;
                let client = connection
                    .transaction()
                    .await
                    .map_err(|e| format!("Transaction error: {}", e))?;
                // Tenant guardrail (RLS, V25).
                crate::db::tx_bind_tenant(&client, site_numeric)
                    .await
                    .map_err(|e| format!("Transaction error: {}", e))?;
                persisted = true;
                // S7: the route authorizes `:id` as a unit of this site, so it is read as nothing else.
                let unit_row_opt = match id_numeric {
                    Some(uid) => client
                        .query_opt(
                            "SELECT id, block_id, unit_number, floor, owner_person_id, tenant_person_id, house_type FROM units \
                             WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL FOR UPDATE",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?,
                    None => None,
                };
                if unit_row_opt.is_none() {
                    return Err(UNIT_NOT_FOUND.to_string());
                }

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    resolved_unit_id = Some(u_id.to_string());
                    let p_id: Option<i64> = u_row.get(4);
                    let t_id: Option<i64> = u_row.get(5);

                    if req.remove_tenant == Some(true) {
                        // STORY-08-08: the same commands as the occupancy actions,
                        // so the outgoing tenant is settled with an exit balance.
                        if t_id.is_some() {
                            let command = if req.is_resident == Some(true) {
                                crate::domain::unit_state::Command::OwnerTakesBack
                            } else {
                                crate::domain::unit_state::Command::MoveOut
                            };
                            crate::db::occupancy_repository::apply_occupancy_command(
                                &client,
                                site_numeric,
                                u_id,
                                command,
                                &edit_transition_input(edit_today, None, p_id),
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                        }
                    } else if let Some(tenant_person_id) = t_id {
                        if let Some(ref t_name) = req.tenant_full_name {
                            client
                                .execute(
                                    "UPDATE persons SET full_name = $1 WHERE id = $2",
                                    &[t_name, &tenant_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref t_phone) = req.tenant_phone {
                            client
                                .execute(
                                    "UPDATE persons SET phone = $1 WHERE id = $2",
                                    &[t_phone, &tenant_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref t_email) = req.tenant_email {
                            stage_person_email_change(
                                &client,
                                tenant_person_id,
                                t_email,
                                site_numeric,
                                &mut email_changes,
                                login_change_allowed,
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                        }
                    } else if let Some(ref t_name) = req.tenant_full_name {
                        if !t_name.trim().is_empty() {
                            let t_email = crate::domain::email::NormalizedEmail::normalize(
                                req.tenant_email.as_deref().unwrap_or(""),
                            );
                            if !t_email.is_empty() {
                                validate_email(&t_email)?;
                            }
                            let t_phone = req.tenant_phone.clone().unwrap_or_default();
                            // S1: reuse a person of this site only; never invent an address.
                            let existing = if t_email.is_empty() {
                                None
                            } else {
                                client
                                    .query_opt(
                                        "SELECT id FROM persons WHERE site_id = $1 AND lower(email) = $2 AND deleted_at IS NULL",
                                        &[&site_numeric, &t_email],
                                    )
                                    .await
                                    .map_err(|e| e.to_string())?
                            };
                            let new_t_id: i64 = match existing {
                                Some(row) => row.get(0),
                                None => crate::db::person_repository::resolve_new_site_person(
                                    &client,
                                    t_name,
                                    Some(&t_phone),
                                    Some(&t_email),
                                    "HOME_RESIDENT",
                                    site_numeric,
                                    true,
                                )
                                .await
                                .map_err(|e| format!("Failed to save tenant: {}", e))?,
                            };
                            {
                                // T2 on a vacant unit, C2 when the owner lives there.
                                let snapshot = crate::db::occupancy_repository::lock_unit_snapshot(
                                    &client,
                                    site_numeric,
                                    u_id,
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                                let command = if snapshot.state.occupancy
                                    == crate::domain::unit_state::Occupancy::OwnerOccupied
                                {
                                    crate::domain::unit_state::Command::OwnerRentsOut
                                } else {
                                    crate::domain::unit_state::Command::TenantMoveIn
                                };
                                crate::db::occupancy_repository::apply_occupancy_command(
                                    &client,
                                    site_numeric,
                                    u_id,
                                    command,
                                    &edit_transition_input(edit_today, Some(new_t_id), None),
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                            }
                        }
                    }

                    if let Some(owner_person_id) = p_id {
                        if let Some(ref name) = req.owner_full_name {
                            client
                                .execute(
                                    "UPDATE persons SET full_name = $1 WHERE id = $2",
                                    &[name, &owner_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref phone) = req.phone {
                            client
                                .execute(
                                    "UPDATE persons SET phone = $1 WHERE id = $2",
                                    &[phone, &owner_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref email) = req.email {
                            stage_person_email_change(
                                &client,
                                owner_person_id,
                                email,
                                site_numeric,
                                &mut email_changes,
                                login_change_allowed,
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                        }
                    }

                    if let Some(ref ht) = req.house_type {
                        client
                            .execute(
                                "UPDATE units SET house_type = $1 WHERE id = $2",
                                &[ht, &u_id],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                    }
                    if let Some(dues) = req.monthly_dues {
                        client
                            .execute(
                                "UPDATE units SET monthly_tariff_override = $1 WHERE id = $2",
                                &[&dues, &u_id],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                        client.execute(
                            "UPDATE dues_liabilities SET principal_amount = $1 WHERE unit_id = $2 AND status = 'PENDING'",
                            &[&dues, &u_id],
                        ).await.map_err(|e| e.to_string())?;
                    }
                }
                client
                    .commit()
                    .await
                    .map_err(|e| format!("Transaction commit error: {}", e))?;
            }
        }

        // 2. Update in-memory state
        let mut inner = self.state.inner.write().await;

        // Resolve one unit, in order of precedence: the unit the database resolved,
        // an exact unit id, then a unit owned by the given user id. Unit and user ids
        // are both plain numbers, so a single OR-match picked whichever came first.
        let unit_idx = resolved_unit_id
            .as_deref()
            .and_then(|rid| inner.units.iter().position(|u| u.id == rid))
            .or_else(|| {
                inner.units.iter().position(|u| {
                    u.id == unit_or_user_id
                        || (id_numeric.is_some() && crate::db::parse_id_to_i64(&u.id) == id_numeric)
                })
            })
            .or_else(|| {
                inner
                    .units
                    .iter()
                    .position(|u| u.owner_user_id.as_deref() == Some(unit_or_user_id))
            });

        // The owner is the resolved unit's owner; only without a unit is the id read as a user id.
        let user_idx = match unit_idx {
            Some(uidx) => inner.units[uidx]
                .owner_user_id
                .clone()
                .and_then(|oid| inner.users.iter().position(|u| u.id == oid)),
            None => inner.users.iter().position(|u| u.id == unit_or_user_id),
        };

        let tenant_user_idx = if let Some(uidx) = unit_idx {
            if let Some(ref tuid) = inner.units[uidx].tenant_user_id {
                inner.users.iter().position(|u| &u.id == tuid)
            } else {
                None
            }
        } else {
            None
        };

        if let Some(uidx) = unit_idx {
            if req.remove_tenant == Some(true) {
                inner.units[uidx].tenant_user_id = None;
            } else if let Some(t_idx) = tenant_user_idx {
                if let Some(ref t_name) = req.tenant_full_name {
                    inner.users[t_idx].full_name = t_name.clone();
                }
                if let Some(ref t_email) = req.tenant_email {
                    if !persisted {
                        stage_memory_email_change(
                            &mut inner,
                            t_idx,
                            t_email,
                            &mut email_changes,
                            login_change_allowed,
                        )
                        .map_err(|e| e.to_string())?;
                    }
                }
                if let Some(ref t_phone) = req.tenant_phone {
                    inner.users[t_idx].phone = t_phone.clone();
                }
            } else if let Some(ref t_name) = req.tenant_full_name {
                if !t_name.trim().is_empty() {
                    let max_u = inner
                        .users
                        .iter()
                        .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                        .max()
                        .unwrap_or(0);
                    let new_uid = (max_u + 1).to_string();
                    let email = crate::domain::email::NormalizedEmail::normalize(
                        req.tenant_email.as_deref().unwrap_or(""),
                    );
                    let phone = req.tenant_phone.clone().unwrap_or_default();
                    inner.users.push(crate::models::User {
                        id: new_uid.clone(),
                        full_name: t_name.clone(),
                        email,
                        phone,
                        password_hash: None,
                        role: crate::models::Role::HomeResident,
                        site_id: site_id.to_string(),
                        must_change_password: true,
                        auth_provider: AuthProvider::Local,
                        google_sub: None,
                        avatar_url: None,
                        created_at: chrono::Utc::now(),
                        person_id: None,
                    });
                    inner.units[uidx].tenant_user_id = Some(new_uid);
                }
            }
            if let Some(ref ht) = req.house_type {
                inner.units[uidx].house_type = Some(ht.clone());
            }
            if let Some(dues) = req.monthly_dues {
                inner.units[uidx].monthly_tariff_override = Some(dues);
                let unit_id = inner.units[uidx].id.clone();
                for d in inner
                    .dues
                    .iter_mut()
                    .filter(|d| d.unit_id == unit_id && d.status == DebtStatus::Pending)
                {
                    d.principal_amount = dues;
                    d.total_amount = dues;
                }
            }
        }

        if let Some(usridx) = user_idx {
            if let Some(ref name) = req.owner_full_name {
                inner.users[usridx].full_name = name.clone();
            }
            if let Some(ref phone) = req.phone {
                inner.users[usridx].phone = phone.clone();
            }
            if let Some(ref email) = req.email {
                if !persisted {
                    stage_memory_email_change(
                        &mut inner,
                        usridx,
                        email,
                        &mut email_changes,
                        login_change_allowed,
                    )
                    .map_err(|e| e.to_string())?;
                }
            }
        }

        if let (Some(uidx), Some(ref name)) = (unit_idx, &req.owner_full_name) {
            let unit_id = inner.units[uidx].id.clone();
            inner.unit_payer_names.insert(unit_id, vec![name.clone()]);
        }

        let resolved_unit_id = unit_idx
            .map(|uidx| inner.units[uidx].id.clone())
            .or(resolved_unit_id);
        drop(inner);

        // S5: tell the new address how to confirm and the old one that a change was asked for.
        let activations = AccountActivationService::new(self.state.clone());
        let mut pending = Vec::new();
        for change in &email_changes {
            let reference = format!("user-{}", change.user_id);
            let delivery = activations.deliver(
                &reference,
                &change.name,
                &change.new_email,
                ActivationPurpose::EmailChange,
                &change.issued,
            );
            activations.notify_previous_email(&reference, &change.name, &change.old_email);
            pending.push(crate::models::PendingEmailChange {
                new_email: change.new_email.clone(),
                delivery,
            });
        }

        let all_owners = self.get_home_owners_for_site(site_id).await;
        let mut updated = resolved_unit_id
            .as_ref()
            .and_then(|rid| all_owners.iter().find(|o| &o.unit_id == rid).cloned())
            .or_else(|| {
                all_owners
                    .iter()
                    .find(|o| {
                        o.unit_id == unit_or_user_id
                            || crate::db::parse_id_to_i64(&o.unit_id) == id_numeric
                    })
                    .cloned()
            })
            .ok_or_else(|| UNIT_NOT_FOUND.to_string())?;
        updated.pending_email_changes = pending;
        Ok(updated)
    }

    pub async fn delete_home_owner(
        &self,
        site_id: &str,
        unit_or_user_id: &str,
    ) -> Result<(), String> {
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // 1. If DB pool is available, dissociate in PostgreSQL inside a single transaction
        if let Some(ref pool) = self.state.pool {
            let mut client = pool
                .get()
                .await
                .map_err(|e| format!("Database connection error: {}", e))?;
            let tx = client
                .transaction()
                .await
                .map_err(|e| format!("Transaction error: {}", e))?;
            // Tenant guardrail (V21): rows of other sites are invisible from here on.
            crate::db::tx_bind_tenant(&tx, site_numeric)
                .await
                .map_err(|e| format!("Transaction error: {}", e))?;

            let unit_row_opt = if let Some(uid) = id_numeric {
                tx.query_opt(
                    // S7: the route authorizes `:id` as a unit of this site, so it is read as nothing else.
                    "SELECT id, owner_person_id, tenant_person_id FROM units WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL FOR UPDATE",
                    &[&uid, &site_numeric],
                )
                .await
                .map_err(|e| e.to_string())?
            } else {
                None
            };

            if let Some(u_row) = unit_row_opt {
                let u_id: i64 = u_row.get(0);
                let related_people = tx
                    .query(
                        "SELECT person_id FROM (SELECT owner_person_id AS person_id FROM units WHERE id = $1 UNION SELECT tenant_person_id FROM units WHERE id = $1 UNION SELECT person_id FROM unit_occupancies WHERE unit_id = $1 UNION SELECT m.person_id FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id WHERE o.unit_id = $1 UNION SELECT person_id FROM unit_ownerships WHERE unit_id = $1) related WHERE person_id IS NOT NULL",
                        &[&u_row.get::<_, i64>(0)],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                let person_ids: Vec<i64> = related_people
                    .into_iter()
                    .map(|row| row.get(0))
                    .collect::<std::collections::BTreeSet<_>>()
                    .into_iter()
                    .collect();

                // Zero data loss: a unit with financial history (any payment, receipt,
                // advance movement, paid due or matured receivable) is never removed; the
                // manager uses move-out or ownership transfer instead. Only untouched,
                // not-yet-due charges (e.g. the one issued at registration) are voided.
                let has_history: bool = tx
                    .query_one(
                        r#"
                        SELECT EXISTS (SELECT 1 FROM payment_entries WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM payment_receipts WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM advance_ledger_entries WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM dues_liabilities WHERE unit_id = $1 AND status <> 'CANCELLED'
                                       AND (paid_amount > 0 OR status = 'PAID' OR due_date < CURRENT_DATE))
                        "#,
                        &[&u_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?
                    .get(0);
                if has_history {
                    return Err(UNIT_HAS_FINANCIAL_HISTORY.to_string());
                }

                // Archive (soft-delete) the unit: untouched dues are cancelled, the
                // occupancy and ownership history is closed, nothing is physically deleted.
                tx.execute(
                    "UPDATE dues_liabilities SET status = 'CANCELLED' WHERE unit_id = $1 AND status IN ('PENDING', 'OVERDUE') AND paid_amount = 0",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE unit_occupancies SET is_active = FALSE, end_date = GREATEST(start_date, CURRENT_DATE) WHERE unit_id = $1 AND is_active = TRUE",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE unit_ownerships SET is_active = FALSE, end_date = GREATEST(start_date, CURRENT_DATE) WHERE unit_id = $1 AND is_active = TRUE",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE units SET owner_person_id = NULL, tenant_person_id = NULL, deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;

                for person_id in person_ids {
                    let other_units: i64 = tx
                        .query_one(
                            "SELECT COUNT(*) FROM units u WHERE u.deleted_at IS NULL AND (u.owner_person_id = $1 OR u.tenant_person_id = $1 OR EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.person_id = $1 AND o.is_active))",
                            &[&person_id],
                        )
                        .await
                        .map_err(|e| e.to_string())?
                        .get(0);
                    let other_occ: i64 = tx
                        .query_one(
                            "SELECT COUNT(*) FROM unit_occupancies o JOIN units u ON u.id = o.unit_id WHERE o.person_id = $1 AND o.is_active AND o.end_date IS NULL AND u.deleted_at IS NULL",
                            &[&person_id],
                        )
                        .await
                        .map_err(|e| e.to_string())?
                        .get(0);
                    let other_members: i64 = tx
                        .query_one(
                            "SELECT COUNT(*) FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id AND o.is_active AND o.end_date IS NULL JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL WHERE m.person_id = $1",
                            &[&person_id],
                        )
                        .await
                        .map_err(|e| e.to_string())?
                        .get(0);

                    if other_units == 0 && other_occ == 0 && other_members == 0 {
                        // Keep historical references while releasing the retired person's identifiers.
                        tx.execute("UPDATE users SET is_active = false, auth_version = auth_version + 1 WHERE site_id = $1 AND person_id = $2 AND is_active", &[&site_numeric, &person_id]).await.map_err(|e| e.to_string())?;
                        tx.execute("UPDATE persons SET deleted_at = now() WHERE site_id = $1 AND id = $2 AND deleted_at IS NULL", &[&site_numeric, &person_id]).await.map_err(|e| e.to_string())?;
                        tx.execute("UPDATE auth_sessions SET revoked_at = now() WHERE revoked_at IS NULL AND user_id IN (SELECT id FROM users WHERE site_id = $1 AND person_id = $2)", &[&site_numeric, &person_id]).await.map_err(|e| e.to_string())?;
                        tx.execute("UPDATE account_activations SET used_at = now() WHERE used_at IS NULL AND user_id IN (SELECT id FROM users WHERE site_id = $1 AND person_id = $2)", &[&site_numeric, &person_id]).await.map_err(|e| e.to_string())?;
                    }
                }
            }
            tx.commit()
                .await
                .map_err(|e| format!("Transaction commit error: {}", e))?;
        }

        // 2. In-memory state cleanup
        let mut inner = self.state.inner.write().await;

        let target_units: Vec<IndependentUnit> = inner
            .units
            .iter()
            .filter(|u| {
                (u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id
                        || crate::db::parse_id_to_i64(&u.id) == id_numeric
                        || u.owner_user_id.as_deref() == Some(unit_or_user_id)
                        || u.owner_user_id
                            .as_ref()
                            .and_then(|uid| crate::db::parse_id_to_i64(uid))
                            == id_numeric
                        || u.tenant_user_id.as_deref() == Some(unit_or_user_id)
                        || u.tenant_user_id
                            .as_ref()
                            .and_then(|uid| crate::db::parse_id_to_i64(uid))
                            == id_numeric)
            })
            .cloned()
            .collect();

        if !target_units.is_empty() {
            let target_unit_ids: Vec<String> = target_units.iter().map(|u| u.id.clone()).collect();
            if self.state.pool.is_none() {
                let has_history = target_unit_ids.iter().any(|uid| {
                    inner.payment_receipts.iter().any(|r| &r.unit_id == uid)
                        || inner.payment_entries.iter().any(|e| &e.unit_id == uid)
                        || inner.advance_total(uid) > rust_decimal::Decimal::ZERO
                        || inner.dues.iter().any(|d| {
                            &d.unit_id == uid
                                && (d.paid_principal + d.paid_penalty > rust_decimal::Decimal::ZERO
                                    || d.due_date < chrono::Utc::now().date_naive())
                        })
                });
                if has_history {
                    return Err(UNIT_HAS_FINANCIAL_HISTORY.to_string());
                }
            }
            let target_user_ids: std::collections::BTreeSet<String> = target_units
                .iter()
                .flat_map(|u| [u.owner_user_id.clone(), u.tenant_user_id.clone()])
                .flatten()
                .collect();
            let target_members: Vec<UnitMemberDto> = target_unit_ids
                .iter()
                .filter_map(|unit_id| inner.unit_members.get(unit_id))
                .flatten()
                .cloned()
                .collect();
            let target_user_ids: std::collections::BTreeSet<String> = target_user_ids
                .into_iter()
                .chain(
                    target_members
                        .iter()
                        .filter_map(|m| m.resident_user_id.map(|id| id.to_string())),
                )
                .collect();
            let target_person_ids: std::collections::BTreeSet<i64> = inner
                .users
                .iter()
                .filter(|u| target_user_ids.contains(&u.id))
                .filter_map(|u| u.person_id)
                .chain(target_members.iter().filter_map(|m| m.person_id))
                .collect();
            let target_emails: std::collections::BTreeSet<String> = inner
                .users
                .iter()
                .filter(|u| {
                    target_user_ids.contains(&u.id)
                        || u.person_id
                            .is_some_and(|id| target_person_ids.contains(&id))
                })
                .map(|u| crate::domain::email::NormalizedEmail::normalize(&u.email))
                .chain(
                    target_members
                        .iter()
                        .map(|m| crate::domain::email::NormalizedEmail::normalize(&m.email)),
                )
                .collect();

            // Clear matching units for this site
            inner.units.retain(|u| {
                let matches_site = u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric);
                if !matches_site {
                    return true;
                }
                !target_unit_ids.contains(&u.id)
            });

            // Clean dues strictly for target units in this site
            inner.dues.retain(|d| !target_unit_ids.contains(&d.unit_id));

            // Clean advance and mappings strictly for target units
            for u_id in &target_unit_ids {
                inner.advance_balances.remove(u_id);
                inner.unit_members.remove(u_id);
                inner.unit_payer_names.remove(u_id);
                inner.unit_invite_tokens.remove(u_id);
            }

            let active_user_ids: std::collections::BTreeSet<String> = inner
                .units
                .iter()
                .flat_map(|u| [u.owner_user_id.clone(), u.tenant_user_id.clone()])
                .flatten()
                .chain(
                    inner
                        .unit_members
                        .values()
                        .flatten()
                        .filter_map(|m| m.resident_user_id.map(|id| id.to_string())),
                )
                .collect();
            let active_person_ids: std::collections::BTreeSet<i64> = inner
                .users
                .iter()
                .filter(|u| active_user_ids.contains(&u.id))
                .filter_map(|u| u.person_id)
                .chain(
                    inner
                        .unit_members
                        .values()
                        .flatten()
                        .filter_map(|m| m.person_id),
                )
                .collect();
            let active_emails: std::collections::BTreeSet<String> = inner
                .users
                .iter()
                .filter(|u| {
                    active_user_ids.contains(&u.id)
                        || u.person_id
                            .is_some_and(|id| active_person_ids.contains(&id))
                })
                .map(|u| crate::domain::email::NormalizedEmail::normalize(&u.email))
                .chain(
                    inner
                        .unit_members
                        .values()
                        .flatten()
                        .map(|m| crate::domain::email::NormalizedEmail::normalize(&m.email)),
                )
                .collect();
            inner.users.retain(|u| {
                let is_archived_identity = target_user_ids.contains(&u.id)
                    || u.person_id
                        .is_some_and(|id| target_person_ids.contains(&id))
                    || target_emails
                        .contains(&crate::domain::email::NormalizedEmail::normalize(&u.email));
                !is_archived_identity
                    || active_user_ids.contains(&u.id)
                    || u.person_id
                        .is_some_and(|id| active_person_ids.contains(&id))
                    || active_emails
                        .contains(&crate::domain::email::NormalizedEmail::normalize(&u.email))
            });
            Ok(())
        } else {
            // Also check if id is a user
            if let Some(usridx) = inner.users.iter().position(|u| {
                (u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id
                        || crate::db::parse_id_to_i64(&u.id) == id_numeric
                        || u.email.eq_ignore_ascii_case(unit_or_user_id))
            }) {
                inner.users.remove(usridx);
                Ok(())
            } else {
                Err(format!(
                    "Kat maliki / daire '{}' bulunamadı.",
                    unit_or_user_id
                ))
            }
        }
    }

    pub async fn add_unit_member(
        &self,
        _site_id: &str, // the unit, authorized for this site, determines the site
        unit_id: &str,
        full_name: &str,
        phone: &str,
        email: &str,
        relationship: &str,
    ) -> Result<UnitMemberDto, String> {
        if full_name.trim().is_empty() {
            return Err("Sakin adı soyadı boş olamaz.".to_string());
        }
        // A household member (a child, for example) may have no address; one that is given must be valid.
        if !email.trim().is_empty() {
            validate_email(email)?;
        }
        if !phone.trim().is_empty() {
            validate_phone(phone)?;
        }

        // F5: one of the fixed codes (legacy labels are read, unknown text is refused).
        let relationship_val =
            crate::domain::household_relationship::HouseholdRelationship::from_input(relationship)
                .ok_or_else(|| {
                    crate::domain::household_relationship::UNKNOWN_RELATIONSHIP.to_string()
                })?
                .as_str();

        // Persist into the canonical household table; it resolves the unit's active
        // occupancy and links the person by email. The returned id is the real identifier.
        let member_id = match self.state.pool {
            Some(ref pool) => crate::db::save_unit_member(
                pool,
                unit_id,
                full_name,
                relationship_val,
                phone,
                email,
            )
            .await
            .map_err(|e| {
                // A vacant unit has no household to join (EPIC-08 invariant 6).
                if e.to_string() == crate::db::NO_CURRENT_OCCUPANT {
                    NO_HOUSEHOLD_TO_JOIN.to_string()
                } else {
                    "Household storage unavailable".to_string()
                }
            })?,
            None => 0,
        };

        let member = UnitMemberDto {
            resident_id: member_id.to_string(),
            full_name: full_name.to_string(),
            relationship: relationship_val.to_string(),
            phone: phone.to_string(),
            email: crate::domain::email::NormalizedEmail::normalize(email),
            is_owner: false,
            occupancy_id: None,
            person_id: None,
            resident_user_id: None,
        };

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
            inner
                .unit_members
                .entry(key.clone())
                .or_default()
                .push(member.clone());
        }

        Ok(member)
    }

    pub async fn delete_unit_member(
        &self,
        _site_id: &str,
        unit_id: &str,
        resident_id: &str,
    ) -> Result<(), String> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let unit_id_num = crate::db::require_id("entity", unit_id)?;
                let member_id = crate::db::parse_id_to_i64(resident_id);
                client.execute(
                    "DELETE FROM occupancy_members WHERE id = $1 AND occupancy_id IN (SELECT id FROM unit_occupancies WHERE unit_id = $2)",
                    &[&member_id, &unit_id_num],
                ).await.map_err(|e| e.to_string())?;
                crate::db::responsible_contact_repository::clear_stale_primary_contact(
                    &client,
                    unit_id_num,
                )
                .await
                .map_err(|e| e.to_string())?;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
            if let Some(members) = inner.unit_members.get_mut(key) {
                members.retain(|m| m.resident_id != resident_id && m.full_name != resident_id);
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_unit_member(
        &self,
        _site_id: &str,
        unit_id: &str,
        resident_id: &str,
        full_name: &str,
        phone: &str,
        email: &str,
        relationship: &str,
    ) -> Result<(), String> {
        let relationship =
            crate::domain::household_relationship::HouseholdRelationship::from_input(relationship)
                .ok_or_else(|| {
                    crate::domain::household_relationship::UNKNOWN_RELATIONSHIP.to_string()
                })?
                .as_str();
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let unit_id_num = crate::db::require_id("entity", unit_id)?;
                let member_id = crate::db::parse_id_to_i64(resident_id);
                client.execute(
                    "UPDATE occupancy_members SET full_name = $1, phone = $2, email = $3, relationship = $4 WHERE id = $5 AND occupancy_id IN (SELECT id FROM unit_occupancies WHERE unit_id = $6)",
                    &[&full_name, &phone, &email, &relationship, &member_id, &unit_id_num],
                ).await.map_err(|e| e.to_string())?;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
            if let Some(members) = inner.unit_members.get_mut(key) {
                for m in members.iter_mut() {
                    if m.resident_id == resident_id || m.full_name == resident_id {
                        m.full_name = full_name.to_string();
                        m.phone = phone.to_string();
                        m.email = email.to_string();
                        m.relationship = relationship.to_string();
                    }
                }
            }
        }
        Ok(())
    }

    pub async fn get_house_types_for_site(
        &self,
        site_id: &str,
    ) -> Vec<crate::models::HouseTypeTariff> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(0);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(rows) = crate::db::logged(client
                    .query(
                        "SELECT id, site_id, type_name, dues_amount, description FROM house_types WHERE site_id = $1 ORDER BY dues_amount ASC",
                        &[&site_numeric],
                    )
                    .await, "site_admin_service") {
                    return rows
                        .into_iter()
                        .map(|row| {
                            let id: i64 = row.get(0);
                            let s_id: i64 = row.get(1);
                            let type_name: String = row.get(2);
                            let dues_amount: Decimal = row.get(3);
                            let description: Option<String> = row.get(4);
                            crate::models::HouseTypeTariff {
                                id: id.to_string(),
                                site_id: s_id.to_string(),
                                type_name,
                                dues_amount,
                                description,
                            }
                        })
                        .collect();
                }
            }
        }

        // 2. Read from in-memory state
        let inner = self.state.inner.read().await;
        let list: Vec<_> = inner
            .house_types
            .iter()
            .filter(|h| {
                h.site_id == site_id || crate::db::parse_id_to_i64(&h.site_id) == Some(site_numeric)
            })
            .cloned()
            .collect();
        if !list.is_empty() {
            return list;
        }

        // 3. Defaults fallback
        vec![
            crate::models::HouseTypeTariff {
                id: "1".to_string(),
                site_id: site_id.to_string(),
                type_name: "1+1".to_string(),
                dues_amount: Decimal::from(1000),
                description: Some("1 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "2".to_string(),
                site_id: site_id.to_string(),
                type_name: "2+1".to_string(),
                dues_amount: Decimal::from(1400),
                description: Some("2 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "3".to_string(),
                site_id: site_id.to_string(),
                type_name: "3+1".to_string(),
                dues_amount: Decimal::from(1800),
                description: Some("3 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "4".to_string(),
                site_id: site_id.to_string(),
                type_name: "4+1".to_string(),
                dues_amount: Decimal::from(2200),
                description: Some("4 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "5".to_string(),
                site_id: site_id.to_string(),
                type_name: "Dublex".to_string(),
                dues_amount: Decimal::from(2500),
                description: Some("Çatı Dubleks / Bahçe Katı".to_string()),
            },
        ]
    }

    pub async fn create_or_update_house_type(
        &self,
        site_id: &str,
        request: crate::models::CreateHouseTypeRequest,
    ) -> Result<crate::models::HouseTypeTariff, String> {
        if request.type_name.trim().is_empty() {
            return Err("Konut tipi adı boş olamaz (örn: 3+1).".to_string());
        }
        if request.dues_amount <= Decimal::ZERO {
            return Err("Aidat tutarı sıfırdan büyük olmalıdır.".to_string());
        }
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let type_name_trimmed = request.type_name.trim().to_string();

        let id_str = if let Some(ref pool) = self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;
            let row = client
                .query_one(
                    r#"
                    INSERT INTO house_types (site_id, type_name, dues_amount, description)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (site_id, type_name) DO UPDATE SET
                        dues_amount = EXCLUDED.dues_amount,
                        description = EXCLUDED.description
                    RETURNING id
                    "#,
                    &[
                        &site_numeric,
                        &type_name_trimmed,
                        &request.dues_amount,
                        &request.description,
                    ],
                )
                .await
                .map_err(|e| format!("DB insert error: {}", e))?;
            let db_id: i64 = row.get(0);
            db_id.to_string()
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner
                .house_types
                .iter()
                .filter_map(|h| crate::db::parse_id_to_i64(&h.id))
                .max()
                .unwrap_or(0);
            (max_id + 1).to_string()
        };

        let tariff = crate::models::HouseTypeTariff {
            id: id_str,
            site_id: site_id.to_string(),
            type_name: type_name_trimmed,
            dues_amount: request.dues_amount,
            description: request.description,
        };

        // Update in-memory state
        let mut inner = self.state.inner.write().await;
        if let Some(pos) = inner.house_types.iter().position(|h| {
            (h.site_id == site_id || crate::db::parse_id_to_i64(&h.site_id) == Some(site_numeric))
                && h.type_name.eq_ignore_ascii_case(&tariff.type_name)
        }) {
            inner.house_types[pos] = tariff.clone();
        } else {
            inner.house_types.push(tariff.clone());
        }

        Ok(tariff)
    }

    pub async fn delete_house_type(&self, site_id: &str, id: &str) -> Result<(), String> {
        let site_numeric = crate::db::require_id("entity", site_id)?;
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(numeric_id) = id.parse::<i64>() {
                    client
                        .execute(
                            "DELETE FROM house_types WHERE id = $1 AND site_id = $2",
                            &[&numeric_id, &site_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                }
            }
        }
        let mut inner = self.state.inner.write().await;
        inner.house_types.retain(|h| h.id != id);
        Ok(())
    }

    pub async fn get_blocks_for_site(&self, site_id: &str) -> Vec<crate::models::BlockDto> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(db_blocks) = crate::db::get_blocks_for_site_from_db(pool, site_id).await {
                return db_blocks;
            }
        }
        let site_numeric = crate::db::parse_id_to_i64(site_id);
        let inner = self.state.inner.read().await;
        let mut list: Vec<crate::models::BlockDto> = inner
            .blocks
            .iter()
            .filter(|b| {
                b.site_id == site_id
                    || (site_numeric.is_some()
                        && crate::db::parse_id_to_i64(&b.site_id) == site_numeric)
            })
            .cloned()
            .collect();

        let site_exists = inner.sites.iter().any(|s| {
            s.id == site_id
                || (site_numeric.is_some() && crate::db::parse_id_to_i64(&s.id) == site_numeric)
        });

        if !site_exists && list.is_empty() {
            list = vec![
                crate::models::BlockDto {
                    id: "b-1".to_string(),
                    site_id: site_id.to_string(),
                    block_name: "A Blok".to_string(),
                    total_floors: 10,
                },
                crate::models::BlockDto {
                    id: "b-2".to_string(),
                    site_id: site_id.to_string(),
                    block_name: "B Blok".to_string(),
                    total_floors: 10,
                },
            ];
        }

        // Strictly deduplicate by block_name
        let mut unique_list: Vec<crate::models::BlockDto> = Vec::new();
        for b in list {
            if !unique_list
                .iter()
                .any(|u| u.block_name.eq_ignore_ascii_case(&b.block_name))
            {
                unique_list.push(b);
            }
        }
        unique_list
    }

    pub async fn create_or_update_block(
        &self,
        site_id: &str,
        request: crate::models::CreateBlockRequest,
    ) -> Result<crate::models::BlockDto, String> {
        let block_name = request.block_name.trim();
        if block_name.is_empty() {
            return Err("Blok adı boş olamaz (örn: A Blok).".to_string());
        }
        let total_floors = request.total_floors.unwrap_or(10);
        let site_numeric = crate::db::require_id("entity", site_id)?;

        let id_str = if let Some(ref pool) = self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;
            let existing = client
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id = $1 AND LOWER(block_name) = LOWER($2)",
                    &[&site_numeric, &block_name],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            if let Some(row) = existing {
                let db_id: i64 = row.get(0);
                client
                    .execute(
                        "UPDATE blocks SET total_floors = $1 WHERE id = $2",
                        &[&total_floors, &db_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                db_id.to_string()
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, $3) RETURNING id",
                        &[&site_numeric, &block_name, &total_floors],
                    )
                    .await
                    .map_err(|e| format!("DB insert error: {}", e))?;
                let db_id: i64 = row.get(0);
                db_id.to_string()
            }
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner
                .blocks
                .iter()
                .filter_map(|b| crate::db::parse_id_to_i64(&b.id))
                .max()
                .unwrap_or(0);
            (max_id + 1).to_string()
        };

        let block = crate::models::BlockDto {
            id: id_str,
            site_id: site_id.to_string(),
            block_name: block_name.to_string(),
            total_floors,
        };

        let mut inner = self.state.inner.write().await;
        if let Some(pos) = inner.blocks.iter().position(|b| {
            (b.site_id == site_id || crate::db::parse_id_to_i64(&b.site_id) == Some(site_numeric))
                && b.block_name.eq_ignore_ascii_case(&block.block_name)
        }) {
            inner.blocks[pos] = block.clone();
        } else {
            inner.blocks.push(block.clone());
        }

        Ok(block)
    }

    pub async fn create_units(
        &self,
        site_id: &str,
        req: crate::models::CreateUnitsRequest,
    ) -> crate::error::AppResult<Vec<crate::models::UnitDto>> {
        let block_name_trimmed = req.block_name.trim();
        if block_name_trimmed.is_empty() {
            return Err(crate::error::AppError::Validation(
                "Block name cannot be empty".to_string(),
                None,
            ));
        }

        let mut unit_numbers: Vec<i32> = if let Some(nums) = req.unit_numbers.clone() {
            if nums.is_empty() {
                return Err(crate::error::AppError::Validation(
                    "unit_numbers list cannot be empty".to_string(),
                    None,
                ));
            }
            if nums.len() > 500 {
                return Err(crate::error::AppError::Validation(
                    "Cannot create more than 500 units at once".to_string(),
                    None,
                ));
            }
            for &n in &nums {
                if n <= 0 {
                    return Err(crate::error::AppError::Validation(
                        format!("unit_number must be greater than 0, got {}", n),
                        None,
                    ));
                }
            }
            nums
        } else if let (Some(s), Some(e)) = (req.start_unit, req.end_unit) {
            if s <= 0 {
                return Err(crate::error::AppError::Validation(
                    "start_unit must be greater than 0".to_string(),
                    None,
                ));
            }
            if e < s {
                return Err(crate::error::AppError::Validation(
                    "end_unit must be greater than or equal to start_unit".to_string(),
                    None,
                ));
            }
            if e - s + 1 > 500 {
                return Err(crate::error::AppError::Validation(
                    "Cannot create more than 500 units at once".to_string(),
                    None,
                ));
            }
            (s..=e).collect()
        } else if let Some(u) = req.unit_number {
            if u <= 0 {
                return Err(crate::error::AppError::Validation(
                    "unit_number must be greater than 0".to_string(),
                    None,
                ));
            }
            vec![u]
        } else {
            return Err(crate::error::AppError::Validation(
                "Either unit_number, start_unit..end_unit, or unit_numbers must be specified"
                    .to_string(),
                None,
            ));
        };

        unit_numbers.sort_unstable();
        unit_numbers.dedup();

        let site_numeric = crate::db::require_id("entity", site_id)
            .map_err(|e| crate::error::AppError::Validation(e.to_string(), None))?;
        let land_share = req.land_share.unwrap_or(1).max(1);

        tracing::info!(
            site_id = %site_id,
            block = %block_name_trimmed,
            count = unit_numbers.len(),
            "Creating units for site"
        );

        let storage = crate::db::Storage::of(&self.state);
        if let crate::db::Storage::Postgres(ref pool) = storage {
            let result_dtos = crate::db::create_units_in_db(pool, site_id, &req, &unit_numbers)
                .await
                .map_err(|e| {
                    let err_msg = e.to_string();
                    if err_msg.contains("already exist") {
                        crate::error::AppError::Conflict(err_msg)
                    } else {
                        crate::error::AppError::Internal(err_msg)
                    }
                })?;

            // Also keep in-memory cache in sync without overwriting occupied units
            {
                let mut inner = self.state.inner.write().await;
                if let Some(first) = result_dtos.first() {
                    let block_id_str = &first.block_id;
                    let actual_block_name = &first.block_name;
                    if !inner.blocks.iter().any(|b| {
                        b.id == *block_id_str
                            || (b.site_id == site_id && b.block_name == *actual_block_name)
                    }) {
                        inner.blocks.push(crate::models::BlockDto {
                            id: block_id_str.clone(),
                            site_id: site_id.to_string(),
                            block_name: actual_block_name.clone(),
                            total_floors: 10,
                        });
                    }

                    for dto in &result_dtos {
                        let ind_unit = crate::models::IndependentUnit {
                            id: dto.id.clone(),
                            site_id: site_id.to_string(),
                            block_id: dto.block_id.clone(),
                            unit_number: dto.unit_number,
                            floor: dto.floor,
                            land_share,
                            owner_user_id: None,
                            tenant_user_id: None,
                            virtual_iban: dto.virtual_iban.clone(),
                            house_type: req.house_type.clone(),
                            monthly_tariff_override: None,
                            created_on: Some(chrono::Utc::now().date_naive()),
                        };
                        if !inner.units.iter().any(|u| u.id == dto.id) {
                            inner.units.push(ind_unit);
                        }
                    }
                }
            }

            return Ok(result_dtos);
        }

        let mut inner = self.state.inner.write().await;
        let existing_block = inner
            .blocks
            .iter()
            .find(|b| {
                (b.site_id == site_id
                    || crate::db::parse_id_to_i64(&b.site_id) == Some(site_numeric))
                    && (b.block_name.eq_ignore_ascii_case(block_name_trimmed)
                        || b.block_name
                            .eq_ignore_ascii_case(&format!("{} Blok", block_name_trimmed)))
            })
            .cloned();

        let (blk_id, blk_name) = if let Some(b) = existing_block {
            (b.id, b.block_name)
        } else {
            let new_id = format!("blk-{}-{}", site_id, inner.blocks.len() + 1);
            let new_b = crate::models::BlockDto {
                id: new_id.clone(),
                site_id: site_id.to_string(),
                block_name: block_name_trimmed.to_string(),
                total_floors: 10,
            };
            inner.blocks.push(new_b);
            (new_id, block_name_trimmed.to_string())
        };

        // Check if any unit already exists in this block in memory
        let existing_in_mem: Vec<i32> = inner
            .units
            .iter()
            .filter(|u| u.block_id == blk_id && unit_numbers.contains(&u.unit_number))
            .map(|u| u.unit_number)
            .collect();
        if !existing_in_mem.is_empty() {
            return Err(crate::error::AppError::Conflict(format!(
                "Units already exist in block {}: {:?}",
                blk_name, existing_in_mem
            )));
        }

        let mut result_dtos = Vec::new();
        for unit_no in &unit_numbers {
            let floor = req.floor.unwrap_or_else(|| ((unit_no - 1) / 4) + 1);
            let clean_block = blk_name
                .trim()
                .trim_end_matches(" Blok")
                .trim_end_matches(" blok")
                .trim_end_matches(" BLOK")
                .trim();
            let label = format!("{}-{:02}", clean_block, unit_no);
            let viban =
                VirtualIbanService::generate_virtual_iban("00205", site_id, clean_block, *unit_no)
                    .ok();

            let unit_id = format!("u-{}-{}-{}", site_id, blk_id, unit_no);
            let ind_unit = crate::models::IndependentUnit {
                id: unit_id.clone(),
                site_id: site_id.to_string(),
                block_id: blk_id.clone(),
                unit_number: *unit_no,
                floor,
                land_share,
                owner_user_id: None,
                tenant_user_id: None,
                virtual_iban: viban.clone(),
                house_type: req.house_type.clone(),
                monthly_tariff_override: None,
                created_on: Some(chrono::Utc::now().date_naive()),
            };

            inner.units.push(ind_unit);

            result_dtos.push(crate::models::UnitDto {
                id: unit_id,
                site_id: site_id.to_string(),
                block_id: blk_id.clone(),
                block_name: blk_name.clone(),
                unit_number: *unit_no,
                floor,
                label,
                owner_person_id: None,
                tenant_person_id: None,
                virtual_iban: viban,
                occupancy_status: "VACANT".to_string(),
            });
        }

        Ok(result_dtos)
    }

    pub async fn get_units_for_site(
        &self,
        site_id: &str,
        block_id: Option<&str>,
    ) -> Result<Vec<crate::models::UnitDto>, crate::error::AppError> {
        let storage = crate::db::Storage::of(&self.state);
        if let crate::db::Storage::Postgres(ref pool) = storage {
            match crate::db::get_units_for_site_from_db(pool, site_id, block_id).await {
                Ok(db_units) => return Ok(db_units),
                Err(e) => {
                    tracing::error!(
                        site_id = %site_id,
                        error = %e,
                        "Failed to load units from database"
                    );
                    return Err(crate::error::AppError::Internal(e.to_string()));
                }
            }
        }

        let site_numeric = match crate::db::require_id("entity", site_id) {
            Ok(id) => id,
            Err(_) => return Ok(Vec::new()),
        };

        // In-memory fallback
        let inner = self.state.inner.read().await;
        let mut list = Vec::new();
        for u in &inner.units {
            if u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric)
            {
                let blk_name = inner
                    .blocks
                    .iter()
                    .find(|b| b.id == u.block_id)
                    .map(|b| b.block_name.clone())
                    .unwrap_or_else(|| "A".to_string());
                let clean_block = blk_name
                    .trim()
                    .trim_end_matches(" Blok")
                    .trim_end_matches(" blok")
                    .trim_end_matches(" BLOK")
                    .trim();
                let label = format!("{}-{:02}", clean_block, u.unit_number);

                let occ_status = if u.tenant_user_id.is_some() {
                    "TENANT_OCCUPIED"
                } else if u.owner_user_id.is_some() {
                    "OWNER_OCCUPIED"
                } else {
                    "VACANT"
                };

                list.push(crate::models::UnitDto {
                    id: u.id.clone(),
                    site_id: site_id.to_string(),
                    block_id: u.block_id.clone(),
                    block_name: blk_name,
                    unit_number: u.unit_number,
                    floor: u.floor,
                    label,
                    owner_person_id: u.owner_user_id.clone(),
                    tenant_person_id: u.tenant_user_id.clone(),
                    virtual_iban: u.virtual_iban.clone(),
                    occupancy_status: occ_status.to_string(),
                });
            }
        }
        list.sort_by(|a, b| {
            a.block_name
                .cmp(&b.block_name)
                .then_with(|| a.unit_number.cmp(&b.unit_number))
        });
        if let Some(b_id) = block_id {
            list.retain(|u| u.block_id == b_id);
        }
        Ok(list)
    }

    /// T4/T5 move-out through the guarded transition service (STORY-08-07).
    pub async fn move_out_resident(
        &self,
        site_id: &str,
        unit_id: &str,
        req: crate::models::MoveOutResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        if self.state.pool.is_none() {
            return self.move_out_in_memory(unit_id, req).await;
        }
        let request = crate::models::OccupancyTransitionRequest {
            person: None,
            command: crate::domain::unit_state::CommandKind::MoveOut,
            effective_date: parse_effective_date(req.end_date.as_deref())
                .map_err(|e| e.to_string())?,
            person_id: None,
            full_name: None,
            phone: None,
            email: None,
            owner_person_id: None,
            notes: req.notes,
        };
        crate::services::occupancy_service::OccupancyService::new(self.state.clone())
            .transition(site_id, unit_id, request)
            .await
            .map_err(|e| e.to_string())?
            .closed
            .ok_or_else(|| "Move-out closed no occupancy".to_string())
    }

    /// Demonstration storage (no PostgreSQL): only a tenant can move out.
    async fn move_out_in_memory(
        &self,
        unit_id: &str,
        req: crate::models::MoveOutResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        let unit_numeric = crate::services::occupancy_service::parse_unit_id(unit_id)
            .ok_or_else(|| format!("Invalid unit ID: {}", unit_id))?;
        let mut inner = self.state.inner.write().await;
        let unit = inner
            .units
            .iter_mut()
            .find(|u| u.id == unit_id || crate::db::parse_id_to_i64(&u.id) == Some(unit_numeric))
            .ok_or_else(|| UNIT_NOT_FOUND.to_string())?;
        let state = crate::domain::unit_state::UnitState::new(
            if unit.owner_user_id.is_some() {
                crate::domain::unit_state::Ownership::Owned
            } else {
                crate::domain::unit_state::Ownership::Unowned
            },
            if unit.tenant_user_id.is_some() {
                crate::domain::unit_state::Occupancy::TenantOccupied
            } else {
                crate::domain::unit_state::Occupancy::Vacant
            },
        );
        crate::domain::unit_state::plan(state, crate::domain::unit_state::Command::MoveOut)
            .map_err(|e| e.to_string())?;
        let tenant = unit.tenant_user_id.take();
        for key in [
            unit_numeric.to_string(),
            format!("d-{}", unit_numeric),
            format!("unit-{}", unit_numeric),
            unit_id.to_string(),
        ] {
            inner.unit_members.remove(&key);
        }
        let person_name = tenant
            .as_deref()
            .and_then(|id| inner.users.iter().find(|u| u.id == id))
            .map_or_else(|| "Tenant".to_string(), |u| u.full_name.clone());
        let today = chrono::Utc::now().format("%Y-%m-%d").to_string();
        Ok(crate::models::OccupancyHistoryItem {
            id: 1,
            unit_id: unit_numeric,
            person_id: 1,
            person_name,
            person_phone: None,
            person_email: None,
            role: DebtorType::Tenant,
            start_date: today.clone(),
            end_date: Some(req.end_date.unwrap_or(today)),
            is_active: false,
            exit_balance: Decimal::ZERO,
            notes: req.notes,
            created_at: chrono::Utc::now(),
        })
    }

    /// T2 tenant move-in or T3 owner move-in (STORY-08-06): an owner move-in
    /// names an owner on record and never changes ownership.
    pub async fn move_in_resident(
        &self,
        site_id: &str,
        unit_id: &str,
        req: crate::models::MoveInResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        let request = move_in_request(req).map_err(|e| e.to_string())?;
        crate::services::occupancy_service::OccupancyService::new(self.state.clone())
            .transition(site_id, unit_id, request)
            .await
            .map_err(|e| e.to_string())?
            .opened
            .ok_or_else(|| "Move-in opened no occupancy".to_string())
    }

    pub async fn get_unit_occupancy_history(
        &self,
        _site_id: &str,
        unit_id: &str,
    ) -> Result<Vec<crate::models::OccupancyHistoryItem>, String> {
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id
                        .strip_prefix("unit-")
                        .and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id
                        .strip_prefix("d-")
                        .and_then(|s| s.parse::<i64>().ok())
                } else {
                    None
                }
            })
            .ok_or_else(|| format!("Invalid unit ID: {}", unit_id))?;

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let query = r#"
                    SELECT 
                        uo.id,
                        uo.unit_id,
                        uo.person_id,
                        p.full_name,
                        p.phone,
                        p.email,
                        uo.occupancy_type,
                        uo.start_date::text,
                        uo.end_date::text,
                        uo.is_active,
                        uo.exit_balance,
                        uo.notes,
                        uo.created_at
                    FROM unit_occupancies uo
                    JOIN persons p ON uo.person_id = p.id
                    WHERE uo.unit_id = $1
                    ORDER BY uo.start_date DESC, uo.id DESC
                "#;
                if let Some(rows) = crate::db::logged(
                    client.query(query, &[&unit_numeric]).await,
                    "site_admin_service",
                ) {
                    let items = rows
                        .into_iter()
                        .map(|r| crate::models::OccupancyHistoryItem {
                            id: r.get(0),
                            unit_id: r.get(1),
                            person_id: r.get(2),
                            person_name: r.get(3),
                            person_phone: r.get(4),
                            person_email: r.get(5),
                            role: DebtorType::from_str_loose(&r.get::<_, String>(6)),
                            start_date: r.get(7),
                            end_date: r.get(8),
                            is_active: r.get(9),
                            exit_balance: r.get(10),
                            notes: r.get(11),
                            created_at: r.get(12),
                        })
                        .collect::<Vec<_>>();
                    if !items.is_empty() {
                        return Ok(items);
                    }
                }
            }
        }

        let inner = self.state.inner.read().await;
        if let Some(items) = inner
            .unit_occupancies
            .get(unit_id)
            .or_else(|| inner.unit_occupancies.get(&unit_numeric.to_string()))
            .or_else(|| {
                inner
                    .unit_occupancies
                    .get(&format!("unit-{}", unit_numeric))
            })
            .or_else(|| inner.unit_occupancies.get(&format!("d-{}", unit_numeric)))
        {
            return Ok(items.clone());
        }
        Ok(Vec::new())
    }
}

/// Reads an optional `YYYY-MM-DD` effective date from a move request.
pub fn parse_effective_date(
    value: Option<&str>,
) -> Result<Option<chrono::NaiveDate>, crate::db::occupancy_repository::OccupancyError> {
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        None => Ok(None),
        Some(text) => chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d")
            .map(Some)
            .map_err(|_| {
                crate::db::occupancy_repository::OccupancyError::InvalidDate(text.to_string())
            }),
    }
}

/// The guarded command a move-in request stands for: the role picks T2 or T3.
pub fn move_in_request(
    req: crate::models::MoveInResidentRequest,
) -> Result<
    crate::models::OccupancyTransitionRequest,
    crate::db::occupancy_repository::OccupancyError,
> {
    let command = match req.role {
        DebtorType::Tenant => crate::domain::unit_state::CommandKind::TenantMoveIn,
        DebtorType::Owner => crate::domain::unit_state::CommandKind::OwnerMoveIn,
    };
    Ok(crate::models::OccupancyTransitionRequest {
        person: None,
        command,
        effective_date: parse_effective_date(req.start_date.as_deref())?,
        person_id: req.person_id,
        full_name: req.full_name,
        phone: req.phone,
        email: req.email,
        owner_person_id: None,
        notes: req.notes,
    })
}

/// The occupancy part of a registration, as guarded transitions: T1 for an
/// owner (with residence when the owner lives there), T2 for a tenant, and T2
/// for a tenant named next to the owner. An owner on record is never
/// replaced; that is a title deed transfer.
#[allow(clippy::too_many_arguments)]
async fn register_occupancy(
    tx: &deadpool_postgres::Transaction<'_>,
    site: i64,
    unit: i64,
    today: chrono::NaiveDate,
    person: i64,
    is_tenant: bool,
    resides: bool,
    explicit_tenant: Option<i64>,
) -> Result<(), crate::db::occupancy_repository::OccupancyError> {
    use crate::db::occupancy_repository::{self as repo, TransitionInput};
    use crate::domain::unit_state::{self, Command, Ownership};

    let input = |tenant: Option<i64>, owner: Option<i64>| TransitionInput {
        effective_date: today,
        today,
        tenant_person_id: tenant,
        owner_person_id: owner,
        new_owner_person_id: None,
        notes: None,
    };
    if is_tenant {
        repo::apply_occupancy_command(
            tx,
            site,
            unit,
            Command::TenantMoveIn,
            &input(Some(person), None),
        )
        .await?;
        return Ok(());
    }
    let snapshot = repo::lock_unit_snapshot(tx, site, unit).await?;
    if !snapshot.is_owner(person) {
        if snapshot.state.ownership == Ownership::Owned {
            return Err(crate::db::occupancy_repository::OccupancyError::UnitHasOwner);
        }
        let plan = unit_state::plan(snapshot.state, Command::RegisterOwner { resides })?;
        tx.execute(
            "INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) VALUES ($1, $2, 100.00, $3, TRUE)",
            &[&unit, &person, &today],
        )
        .await
        ?;
        repo::execute_plan(
            tx,
            &snapshot,
            plan,
            plan.opens.map(|_| person),
            &input(None, Some(person)),
        )
        .await?;
    }
    if let Some(tenant) = explicit_tenant {
        repo::apply_occupancy_command(
            tx,
            site,
            unit,
            Command::TenantMoveIn,
            &input(Some(tenant), None),
        )
        .await?;
    }
    Ok(())
}

/// Today's move by the owner edit screen, as a guarded transition input.
fn edit_transition_input(
    today: chrono::NaiveDate,
    tenant: Option<i64>,
    owner: Option<i64>,
) -> crate::db::occupancy_repository::TransitionInput {
    crate::db::occupancy_repository::TransitionInput {
        effective_date: today,
        today,
        tenant_person_id: tenant,
        owner_person_id: owner,
        new_owner_person_id: None,
        notes: None,
    }
}

/// Copies the contact data of `owner` and `tenant` references into the legacy
/// request fields, so validation and the in-memory projection see one shape. The
/// references themselves are resolved later, inside the registration transaction.
async fn prefill_person_refs(
    state: &crate::state::AppState,
    site_id: &str,
    request: &mut RegisterHomeOwnerRequest,
) -> Result<(), crate::services::person_service::PersonApiError> {
    use crate::models::PersonRef;
    use crate::services::person_service::PersonApiError;
    if request.owner.is_none() && request.tenant.is_none() && request.members.is_empty() {
        return Ok(());
    }
    if state.pool.is_none() {
        return Err(PersonApiError::Unavailable);
    }
    let site = crate::db::parse_id_to_i64(site_id)
        .ok_or_else(|| PersonApiError::Validation("Site ID is not valid".into()))?;
    let people = crate::services::person_service::PersonService::new(state);
    let contact = |reference: PersonRef| {
        let people = &people;
        async move {
            match reference {
                PersonRef::Existing { person_id } => people
                    .card(site, person_id)
                    .await
                    .map(|c| (c.card.full_name, c.card.email, c.card.phone)),
                PersonRef::New { card, .. } => Ok((card.full_name, card.email, card.phone)),
            }
        }
    };
    if let Some(owner) = request.owner.clone() {
        let (name, email, phone) = contact(owner).await?;
        request.owner_full_name = name;
        request.email = email.unwrap_or_default();
        request.phone = phone.unwrap_or_default();
    }
    if let Some(tenant) = request.tenant.clone() {
        let (name, email, phone) = contact(tenant).await?;
        request.tenant_full_name = Some(name);
        request.tenant_email = email;
        request.tenant_phone = phone;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn when_registering_home_owner_then_does_not_create_due_liability() {
        let state = AppState::new_with_test_fixtures();
        let service = SiteAdminService::new(state.clone());

        let req = RegisterHomeOwnerRequest {
            block: "A".to_string(),
            unit_no: 99,
            floor: 1,
            owner: None,
            tenant: None,
            members: Vec::new(),
            owner_full_name: "Yeni Malik".to_string(),
            email: "yeni.malik.286@sitepulse.test".to_string(),
            phone: "+90 555 123 4567".to_string(),
            tenant_full_name: None,
            tenant_email: None,
            tenant_phone: None,
            land_share: Some("24/24".to_string()),
            monthly_dues: Some(Decimal::new(1500, 0)),
            house_type: Some("2+1".to_string()),
            is_resident: true,
            role: Some("OWNER".to_string()),
        };

        let response = service
            .register_home_owner("site-1", req)
            .await
            .expect("registration should succeed");

        let inner = state.inner.read().await;
        let created_dues: Vec<_> = inner
            .dues
            .iter()
            .filter(|d| d.unit_id == response.unit_id)
            .collect();

        assert!(
            created_dues.is_empty(),
            "registering an owner must not generate dues liabilities (issue #286)"
        );

        let unit = inner
            .units
            .iter()
            .find(|u| u.id == response.unit_id)
            .expect("unit must exist");
        assert_eq!(
            unit.monthly_tariff_override,
            Some(Decimal::new(1500, 0)),
            "per-unit custom tariff override must be persisted on unit (issue #297)"
        );
        assert_eq!(
            response.monthly_dues,
            Decimal::new(1500, 0),
            "registration response must return the custom tariff override (issue #297)"
        );
        assert_eq!(
            crate::scheduler::tariff_for(&inner, unit),
            Some(Decimal::new(1500, 0)),
            "scheduler::tariff_for must prefer custom override over house type tariff (issue #297)"
        );
    }

    #[tokio::test]
    async fn when_updating_unit_monthly_dues_then_tariff_override_is_updated() {
        let state = AppState::new_with_test_fixtures();
        let service = SiteAdminService::new(state.clone());

        let req = crate::models::UpdateHomeOwnerRequest {
            owner_full_name: None,
            email: None,
            phone: None,
            tenant_full_name: None,
            tenant_email: None,
            tenant_phone: None,
            remove_tenant: None,
            house_type: None,
            monthly_dues: Some(Decimal::new(2500, 0)),
            land_share: None,
            is_resident: None,
        };

        service
            .update_home_owner("site-1", "d-14", req, false)
            .await
            .expect("update should succeed");

        let inner = state.inner.read().await;
        let unit = inner
            .units
            .iter()
            .find(|u| u.id == "d-14")
            .expect("unit d-14 must exist");
        assert_eq!(
            unit.monthly_tariff_override,
            Some(Decimal::new(2500, 0)),
            "unit update must store monthly_tariff_override (issue #297)"
        );
        assert_eq!(
            crate::scheduler::tariff_for(&inner, unit),
            Some(Decimal::new(2500, 0)),
            "tariff_for must reflect the updated override"
        );
    }
}
