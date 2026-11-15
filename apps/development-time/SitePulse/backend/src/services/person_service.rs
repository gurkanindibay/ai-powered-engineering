//! Unified person API: scoped search, role-free creation, card reads and
//! version-checked edits. Every query is limited to the caller's site.

use std::collections::HashMap;

use crate::db::person_repository::{self, DuplicateMatch, ResolvePersonError};
use crate::db::Storage;
use crate::domain::email::NormalizedEmail;
use crate::models::{
    CreatePersonRequest, NewPerson, PersonCard, PersonCardResponse, PersonEligibility,
    PersonLoginState, PersonMutationResponse, PersonRef, PersonRole, PersonSearchContext,
    PersonSearchItem, PersonSearchQuery, PersonSearchResponse, PersonUnitRelation,
    UpdatePersonRequest,
};
use crate::services::account_activation_service::{
    self as activation, AccountActivationService, ActivationDelivery, ActivationPurpose,
};
use crate::services::site_admin_service::validate_phone;
use crate::state::AppState;

const DEFAULT_LIMIT: i64 = 20;
const MAX_LIMIT: i64 = 50;
const MAX_NAME_LEN: usize = 120;
/// `persons.person_type` for cards that hold no role yet: none (V35).
const ROLE_FREE_PERSON_TYPE: Option<&str> = None;

#[derive(Debug, thiserror::Error)]
pub enum PersonApiError {
    #[error("Person not found")]
    NotFound,
    #[error("{0}")]
    Validation(String),
    #[error("Person identity is already recorded")]
    IdentityTaken(i64),
    #[error("Possible duplicate people")]
    PossibleDuplicate(Vec<DuplicateMatch>),
    #[error("The person already has an active login")]
    LoginAlreadyActive,
    #[error("The person has no login to remove")]
    NoLogin,
    #[error("The person card changed since it was loaded")]
    StaleVersion,
    #[error("Person records need the database")]
    Unavailable,
    #[error("Person storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> PersonApiError {
    PersonApiError::Storage(e.to_string())
}

/// Collapses internal whitespace and rejects empty or oversized names.
fn clean_name(raw: &str) -> Result<String, PersonApiError> {
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if name.is_empty() {
        return Err(PersonApiError::Validation("Full name is required.".into()));
    }
    if name.chars().count() > MAX_NAME_LEN {
        return Err(PersonApiError::Validation("Full name is too long.".into()));
    }
    Ok(name)
}

fn clean_phone(raw: Option<&str>) -> Result<Option<String>, PersonApiError> {
    match raw.map(str::trim).filter(|v| !v.is_empty()) {
        None => Ok(None),
        Some(phone) => validate_phone(phone)
            .map(|()| Some(phone.to_string()))
            .map_err(PersonApiError::Validation),
    }
}

fn clean_email(raw: Option<&str>) -> Result<Option<String>, PersonApiError> {
    match raw.map(str::trim).filter(|v| !v.is_empty()) {
        None => Ok(None),
        Some(email) => NormalizedEmail::parse(email)
            .map(|e| Some(e.into_string()))
            .map_err(|e| PersonApiError::Validation(e.to_string())),
    }
}

const CARD_SELECT: &str = "SELECT person_id, full_name, email, phone, national_id_masked, version, \
     is_owner, is_owner_occupant, is_tenant, is_member, is_primary_contact, login_state, unit_labels \
     FROM v_person_card";

fn card_of(row: &tokio_postgres::Row) -> PersonCard {
    let flags: [(usize, PersonRole); 5] = [
        (6, PersonRole::Owner),
        (7, PersonRole::OccupantOwner),
        (8, PersonRole::Tenant),
        (9, PersonRole::Member),
        (10, PersonRole::PrimaryContact),
    ];
    let roles = flags
        .iter()
        .filter(|(idx, _)| row.get::<_, bool>(*idx))
        .map(|(_, role)| *role)
        .collect();
    let login: String = row.get(11);
    let version: i32 = row.get(5);
    PersonCard {
        person_id: row.get(0),
        full_name: row.get(1),
        email: row.get(2),
        phone: row.get(3),
        masked_national_id: row.get(4),
        roles,
        unit_labels: row.get(12),
        login: if login == "ACTIVE" {
            PersonLoginState::Active
        } else {
            PersonLoginState::None
        },
        version: i64::from(version),
        allowed_actions: if login == "ACTIVE" {
            vec!["EDIT".to_string(), "REMOVE_LOGIN".to_string()]
        } else {
            vec!["EDIT".to_string(), "OPEN_LOGIN".to_string()]
        },
    }
}

/// Whether `relations` (the person's active relations to the unit) permit `context`.
pub(crate) fn eligibility_for(
    context: PersonSearchContext,
    relations: &[String],
) -> PersonEligibility {
    let has = |name: &str| relations.iter().any(|r| r == name);
    let code = match context {
        PersonSearchContext::Owner if has("OWNER") => Some("ALREADY_OWNER_OF_UNIT"),
        PersonSearchContext::Tenant if has("OWNER") => Some("OWNER_CANNOT_BE_TENANT"),
        PersonSearchContext::Tenant if has("TENANT") => Some("ALREADY_TENANT_OF_UNIT"),
        PersonSearchContext::Household if has("HOUSEHOLD_MEMBER") => Some("ALREADY_MEMBER_OF_UNIT"),
        PersonSearchContext::PrimaryContact if relations.is_empty() => Some("NOT_ON_UNIT"),
        _ => None,
    };
    PersonEligibility {
        allowed: code.is_none(),
        code: code.map(str::to_string),
    }
}

/// Resolves a [`PersonRef`] inside the caller's transaction so the action and the
/// card it uses commit or roll back together.
///
/// `Existing` locks the card in the caller's site and rejects archived or merged
/// cards. `New` validates and normalizes the fields and applies the duplicate rules.
///
/// # Errors
/// A missing card, invalid fields, a taken identity or an unconfirmed duplicate.
pub async fn resolve_person_ref(
    tx: &deadpool_postgres::Transaction<'_>,
    site: i64,
    person: &PersonRef,
) -> Result<i64, PersonApiError> {
    match person {
        PersonRef::Existing { person_id } => tx
            .query_opt(
                "SELECT id FROM persons WHERE id = $1 AND site_id = $2 \
                 AND deleted_at IS NULL AND merged_into_person_id IS NULL FOR UPDATE",
                &[person_id, &site],
            )
            .await
            .map_err(storage)?
            .map(|row| row.get(0))
            .ok_or(PersonApiError::NotFound),
        PersonRef::New {
            card,
            confirm_distinct,
        } => {
            let name = clean_name(&card.full_name)?;
            let phone = clean_phone(card.phone.as_deref())?;
            let email = clean_email(card.email.as_deref())?;
            person_repository::resolve_new_site_person(
                tx,
                &name,
                phone.as_deref(),
                email.as_deref(),
                ROLE_FREE_PERSON_TYPE,
                site,
                *confirm_distinct,
            )
            .await
            .map_err(|e| match e {
                ResolvePersonError::IdentityTaken(id) => PersonApiError::IdentityTaken(id),
                ResolvePersonError::PossibleDuplicate(found) => {
                    PersonApiError::PossibleDuplicate(found)
                }
                ResolvePersonError::Database(e) => storage(e),
            })
        }
    }
}

pub struct PersonService {
    state: AppState,
    store: Storage,
}

impl PersonService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
            store: Storage::of(state),
        }
    }

    fn pool(&self) -> Result<&deadpool_postgres::Pool, PersonApiError> {
        match &self.store {
            Storage::Postgres(pool) => Ok(pool),
            Storage::Memory => Err(PersonApiError::Unavailable),
        }
    }

    /// Type-ahead search with optional role eligibility for a unit.
    ///
    /// # Errors
    /// An invalid unit reference or a storage failure.
    pub async fn search(
        &self,
        site: i64,
        query: &PersonSearchQuery,
    ) -> Result<PersonSearchResponse, PersonApiError> {
        let limit = query.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
        let page = query.page.unwrap_or(1).max(1);
        let offset = page.saturating_sub(1).saturating_mul(limit);
        let term = query.q.as_deref().unwrap_or_default().trim().to_lowercase();
        let digits: String = term.chars().filter(char::is_ascii_digit).collect();
        let client = self.pool()?.get().await.map_err(storage)?;
        let filter = " WHERE site_id = $1 AND ($2 = '' OR strpos(lower(full_name), $2) > 0 \
             OR strpos(lower(COALESCE(email, '')), $2) > 0 \
             OR ($3 <> '' AND strpos(regexp_replace(COALESCE(phone, ''), '\\D', '', 'g'), $3) > 0))";
        let total: i64 = client
            .query_one(
                &format!("SELECT count(*) FROM v_person_card{filter}"),
                &[&site, &term, &digits],
            )
            .await
            .map_err(storage)?
            .get(0);
        let rows = client
            .query(
                &format!(
                    "{CARD_SELECT}{filter} ORDER BY lower(full_name), person_id LIMIT $4 OFFSET $5"
                ),
                &[&site, &term, &digits, &limit, &offset],
            )
            .await
            .map_err(storage)?;
        let relations = self.unit_relations(&client, site, query).await?;
        let items = rows
            .iter()
            .map(card_of)
            .map(|card| {
                let eligibility = query.context.map(|context| {
                    let own = relations.get(&card.person_id).cloned().unwrap_or_default();
                    eligibility_for(context, &own)
                });
                PersonSearchItem { card, eligibility }
            })
            .collect();
        Ok(PersonSearchResponse {
            items,
            total,
            page,
            page_size: limit,
        })
    }

    async fn unit_relations(
        &self,
        client: &deadpool_postgres::Client,
        site: i64,
        query: &PersonSearchQuery,
    ) -> Result<HashMap<i64, Vec<String>>, PersonApiError> {
        let Some(raw_unit) = query.unit_id.as_deref().filter(|_| query.context.is_some()) else {
            return Ok(HashMap::new());
        };
        let unit = crate::db::parse_id_to_i64(raw_unit)
            .ok_or_else(|| PersonApiError::Validation("Unit reference is not valid.".into()))?;
        let rows = client
            .query(
                "SELECT person_id, relation FROM v_person_unit_relations \
                 WHERE site_id = $1 AND unit_id = $2 AND active",
                &[&site, &unit],
            )
            .await
            .map_err(storage)?;
        let mut map: HashMap<i64, Vec<String>> = HashMap::new();
        for row in &rows {
            map.entry(row.get(0)).or_default().push(row.get(1));
        }
        Ok(map)
    }

    /// Creates a role-free card after validation and the shared duplicate rules.
    ///
    /// # Errors
    /// Invalid fields, a taken identity, an unconfirmed duplicate or a storage failure.
    pub async fn create(
        &self,
        site: i64,
        request: &CreatePersonRequest,
    ) -> Result<PersonMutationResponse, PersonApiError> {
        let card: &NewPerson = &request.card;
        let name = clean_name(&card.full_name)?;
        let phone = clean_phone(card.phone.as_deref())?;
        let email = clean_email(card.email.as_deref())?;
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        let id = person_repository::resolve_new_site_person(
            &tx,
            &name,
            phone.as_deref(),
            email.as_deref(),
            ROLE_FREE_PERSON_TYPE,
            site,
            request.confirm_distinct,
        )
        .await
        .map_err(|e| match e {
            ResolvePersonError::IdentityTaken(id) => PersonApiError::IdentityTaken(id),
            ResolvePersonError::PossibleDuplicate(found) => {
                PersonApiError::PossibleDuplicate(found)
            }
            ResolvePersonError::Database(e) => storage(e),
        })?;
        tx.commit().await.map_err(storage)?;
        Ok(PersonMutationResponse {
            card: self.load_card(site, id).await?,
        })
    }

    async fn load_card(&self, site: i64, person_id: i64) -> Result<PersonCard, PersonApiError> {
        let client = self.pool()?.get().await.map_err(storage)?;
        client
            .query_opt(
                &format!("{CARD_SELECT} WHERE site_id = $1 AND person_id = $2"),
                &[&site, &person_id],
            )
            .await
            .map_err(storage)?
            .map(|row| card_of(&row))
            .ok_or(PersonApiError::NotFound)
    }

    /// One card with its unit history.
    ///
    /// # Errors
    /// [`PersonApiError::NotFound`] for a card of another site, archived or merged.
    pub async fn card(
        &self,
        site: i64,
        person_id: i64,
    ) -> Result<PersonCardResponse, PersonApiError> {
        let card = self.load_card(site, person_id).await?;
        let client = self.pool()?.get().await.map_err(storage)?;
        let rows = client
            .query(
                "SELECT unit_id, unit_label, relation, start_date, end_date, active \
                 FROM v_person_unit_relations WHERE site_id = $1 AND person_id = $2 \
                 ORDER BY active DESC, start_date DESC NULLS LAST",
                &[&site, &person_id],
            )
            .await
            .map_err(storage)?;
        let units = rows
            .iter()
            .map(|row| {
                let relation: String = row.get(2);
                PersonUnitRelation {
                    unit_id: row.get::<_, i64>(0).to_string(),
                    unit_label: row.get::<_, String>(1).trim().to_string(),
                    relation: match relation.as_str() {
                        "OWNER" => PersonRole::Owner,
                        "TENANT" => PersonRole::Tenant,
                        _ => PersonRole::Member,
                    },
                    start_date: row.get(3),
                    end_date: row.get(4),
                    active: row.get(5),
                }
            })
            .collect();
        Ok(PersonCardResponse { card, units })
    }

    /// Checks a reference without keeping anything: an existing card must be usable,
    /// a new card must pass validation and the duplicate rules. Lets a caller return
    /// the coded error before a long operation resolves the reference for real.
    ///
    /// # Errors
    /// The same errors as [`resolve_person_ref`].
    pub async fn preflight(&self, site: i64, person: &PersonRef) -> Result<(), PersonApiError> {
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        resolve_person_ref(&tx, site, person).await?;
        // Dropping the transaction rolls the probe back.
        Ok(())
    }

    /// Opens a login for the person (or re-sends the activation link while it is
    /// still pending). Needs an email; no password is ever issued.
    ///
    /// # Errors
    /// A missing card or email, an email used by another login, or a storage failure.
    pub async fn open_login(
        &self,
        site: i64,
        person_id: i64,
    ) -> Result<ActivationDelivery, PersonApiError> {
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        let person = tx
            .query_opt(
                "SELECT p.full_name, COALESCE(p.email, ''), \
                        EXISTS (SELECT 1 FROM v_person_roles r WHERE r.person_id = p.id AND r.is_owner) \
                 FROM persons p WHERE p.id = $1 AND p.site_id = $2 \
                 AND p.deleted_at IS NULL AND p.merged_into_person_id IS NULL FOR UPDATE",
                &[&person_id, &site],
            )
            .await
            .map_err(storage)?
            .ok_or(PersonApiError::NotFound)?;
        let (name, email, is_owner): (String, String, bool) =
            (person.get(0), person.get(1), person.get(2));
        if email.trim().is_empty() {
            return Err(PersonApiError::Validation(
                "An email address is required to open a login.".into(),
            ));
        }
        let existing = tx
            .query_opt(
                "SELECT id, role, (password_hash IS NOT NULL OR google_sub IS NOT NULL) \
                 FROM users WHERE person_id = $1 AND site_id = $2 AND is_active",
                &[&person_id, &site],
            )
            .await
            .map_err(storage)?;
        let user_id: i64 = match existing {
            Some(row) => {
                let role: String = row.get(1);
                let active: bool = row.get(2);
                if active || !matches!(role.as_str(), "HOME_OWNER" | "HOME_RESIDENT") {
                    return Err(PersonApiError::LoginAlreadyActive);
                }
                row.get(0)
            }
            None => {
                let role = if is_owner {
                    "HOME_OWNER"
                } else {
                    "HOME_RESIDENT"
                };
                tx.query_one(
                    "INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) \
                     VALUES ($1, $2, $3, NULL, $4, TRUE) RETURNING id",
                    &[&site, &person_id, &email, &role],
                )
                .await
                .map_err(|_| {
                    PersonApiError::Validation("This email is already used by another login.".into())
                })?
                .get(0)
            }
        };
        let issued =
            activation::issue_in(&tx, user_id, Some(site), ActivationPurpose::Activate, None)
                .await
                .map_err(storage)?;
        tx.commit().await.map_err(storage)?;
        Ok(AccountActivationService::new(self.state.clone()).deliver(
            &format!("user-{user_id}"),
            &name,
            &email,
            ActivationPurpose::Activate,
            &issued,
        ))
    }

    /// Deactivates the person's resident login and revokes its sessions and links.
    ///
    /// # Errors
    /// A missing card, no removable login, or a storage failure.
    pub async fn remove_login(&self, site: i64, person_id: i64) -> Result<(), PersonApiError> {
        self.load_card(site, person_id).await?;
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        let ids: Vec<i64> = tx
            .query(
                "UPDATE users SET is_active = false, auth_version = auth_version + 1 \
                 WHERE site_id = $1 AND person_id = $2 AND is_active \
                 AND role IN ('HOME_OWNER', 'HOME_RESIDENT') RETURNING id",
                &[&site, &person_id],
            )
            .await
            .map_err(storage)?
            .iter()
            .map(|r| r.get(0))
            .collect();
        if ids.is_empty() {
            return Err(PersonApiError::NoLogin);
        }
        tx.execute(
            "UPDATE auth_sessions SET revoked_at = now() WHERE revoked_at IS NULL AND user_id = ANY($1)",
            &[&ids],
        )
        .await
        .map_err(storage)?;
        tx.execute(
            "UPDATE account_activations SET used_at = now() WHERE used_at IS NULL AND user_id = ANY($1)",
            &[&ids],
        )
        .await
        .map_err(storage)?;
        tx.commit().await.map_err(storage)
    }

    /// Edits name, phone and email under optimistic version checking.
    ///
    /// # Errors
    /// Invalid fields, a missing card, a stale version, or a taken email.
    pub async fn update(
        &self,
        site: i64,
        person_id: i64,
        request: &UpdatePersonRequest,
    ) -> Result<PersonMutationResponse, PersonApiError> {
        let name = request.full_name.as_deref().map(clean_name).transpose()?;
        let phone = clean_phone(request.phone.as_deref())?;
        let email = clean_email(request.email.as_deref())?;
        let version = i32::try_from(request.version)
            .map_err(|_| PersonApiError::Validation("Version is not valid.".into()))?;
        self.load_card(site, person_id).await?;
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        if let Some(email) = email.as_deref() {
            let taken = tx
                .query_opt(
                    "SELECT id FROM persons WHERE site_id = $1 AND lower(email) = lower($2) \
                     AND id <> $3 AND deleted_at IS NULL",
                    &[&site, &email, &person_id],
                )
                .await
                .map_err(storage)?;
            if let Some(row) = taken {
                return Err(PersonApiError::IdentityTaken(row.get(0)));
            }
        }
        person_repository::update_person_contact(
            &tx,
            site,
            person_id,
            name.as_deref(),
            phone.as_deref(),
            email.as_deref(),
            version,
        )
        .await
        .map_err(storage)?
        .ok_or(PersonApiError::StaleVersion)?;
        tx.commit().await.map_err(storage)?;
        Ok(PersonMutationResponse {
            card: self.load_card(site, person_id).await?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn owner_cannot_be_tenant_of_the_same_unit() {
        let e = eligibility_for(PersonSearchContext::Tenant, &rel(&["OWNER"]));
        assert!(!e.allowed);
        assert_eq!(e.code.as_deref(), Some("OWNER_CANNOT_BE_TENANT"));
    }

    #[test]
    fn primary_contact_must_be_on_the_unit() {
        assert!(!eligibility_for(PersonSearchContext::PrimaryContact, &[]).allowed);
        assert!(
            eligibility_for(
                PersonSearchContext::PrimaryContact,
                &rel(&["HOUSEHOLD_MEMBER"])
            )
            .allowed
        );
    }

    #[test]
    fn unrelated_person_may_be_added_as_member() {
        assert!(eligibility_for(PersonSearchContext::Household, &[]).allowed);
    }

    #[test]
    fn names_are_collapsed_and_validated() {
        assert_eq!(clean_name("  Ayşe   Demir ").unwrap(), "Ayşe Demir");
        assert!(clean_name("   ").is_err());
        assert!(clean_phone(Some("123")).is_err());
        assert_eq!(clean_phone(Some(" ")).unwrap(), None);
        assert!(clean_email(Some("nope")).is_err());
    }
}
