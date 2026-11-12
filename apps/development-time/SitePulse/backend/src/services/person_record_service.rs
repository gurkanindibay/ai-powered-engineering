//! What a manager keeps on a person beside the directory (person module F7/F9/F10):
//! the optional national ID used for payer matching, contact preferences, the
//! person's own channel consents (read-only here), and duplicate detection before a
//! new person is created.

use serde::{Deserialize, Serialize};
use tokio_postgres::error::SqlState;

use crate::authorization::AuthzContext;
use crate::db::Storage;
use crate::domain::email::NormalizedEmail;
use crate::domain::tax_id::is_valid_tckn;
use crate::domain::text::fold_turkish;
use crate::services::person_directory_service::{summary, PersonSummary, SUMMARY_SELECT};
use crate::state::AppState;

/// Most candidates a duplicate check returns.
pub const MAX_DUPLICATES: usize = 10;

/// Channels a person can prefer; the consentable ones match `communication_consents`.
pub const CHANNELS: [&str; 4] = ["EMAIL", "SMS", "WHATSAPP", "PHONE"];
pub const LANGUAGES: [&str; 2] = ["tr", "en"];
const CONSENT_CHANNELS: [&str; 4] = ["EMAIL", "SMS", "PUSH", "WHATSAPP"];

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PersonRecordError {
    #[error("Person not found")]
    NotFound,
    #[error("Invalid national ID")]
    InvalidNationalId,
    #[error("This national ID is already recorded for another person of the site")]
    NationalIdInUse,
    #[error("Invalid contact preference: {0}")]
    InvalidPreference(&'static str),
    #[error("Person records need the database")]
    Unavailable,
    #[error("Person record storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> PersonRecordError {
    PersonRecordError::Storage(e.to_string())
}

/// How the site reaches a person (F7).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContactPreferences {
    pub preferred_channel: String,
    pub preferred_language: String,
    #[serde(default)]
    pub emergency_contact_name: Option<String>,
    #[serde(default)]
    pub emergency_contact_phone: Option<String>,
}

impl Default for ContactPreferences {
    fn default() -> Self {
        Self {
            preferred_channel: "EMAIL".into(),
            preferred_language: "tr".into(),
            emergency_contact_name: None,
            emergency_contact_phone: None,
        }
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

impl ContactPreferences {
    /// Normalized preferences, or the first invalid field.
    ///
    /// # Errors
    /// An unknown channel or language, an emergency contact with only one of name and
    /// phone, a name over 255 characters, or an invalid phone.
    pub fn validated(self) -> Result<Self, PersonRecordError> {
        let channel = self.preferred_channel.trim().to_ascii_uppercase();
        if !CHANNELS.contains(&channel.as_str()) {
            return Err(PersonRecordError::InvalidPreference("preferred_channel"));
        }
        let language = self.preferred_language.trim().to_ascii_lowercase();
        if !LANGUAGES.contains(&language.as_str()) {
            return Err(PersonRecordError::InvalidPreference("preferred_language"));
        }
        let name = non_empty(self.emergency_contact_name);
        let phone = non_empty(self.emergency_contact_phone);
        if name.is_some() != phone.is_some() {
            return Err(PersonRecordError::InvalidPreference("emergency_contact"));
        }
        if name.as_ref().is_some_and(|n| n.chars().count() > 255) {
            return Err(PersonRecordError::InvalidPreference(
                "emergency_contact_name",
            ));
        }
        if let Some(p) = &phone {
            if crate::services::site_admin_service::validate_phone(p).is_err() || p.len() > 20 {
                return Err(PersonRecordError::InvalidPreference(
                    "emergency_contact_phone",
                ));
            }
        }
        Ok(Self {
            preferred_channel: channel,
            preferred_language: language,
            emergency_contact_name: name,
            emergency_contact_phone: phone,
        })
    }
}

/// A channel consent as the person set it; a channel without a record is granted.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelConsent {
    pub channel: String,
    pub granted: bool,
}

/// The record shown on the person profile.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct PersonRecord {
    /// Last four digits only; the full number is never stored (V15).
    pub national_id_masked: Option<String>,
    pub preferences: ContactPreferences,
    /// Empty when the person has no login account, so cannot have chosen any.
    pub consents: Vec<ChannelConsent>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SetNationalIdRequest {
    /// Absent or empty clears the recorded ID.
    #[serde(default)]
    pub national_id: Option<String>,
}

/// Why a person looks like the one being entered (F9).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DuplicateReason {
    SameEmail,
    SamePhone,
    SameNationalId,
    SimilarName,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct DuplicateQuery {
    #[serde(default)]
    pub full_name: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub phone: Option<String>,
    #[serde(default)]
    pub national_id: Option<String>,
    /// The person being edited, so it does not match itself.
    #[serde(default)]
    pub exclude_person_id: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DuplicateCandidate {
    pub person: PersonSummary,
    pub reasons: Vec<DuplicateReason>,
}

/// The comparable form of a person.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PersonKeys {
    pub email: Option<String>,
    pub phone: Option<String>,
    pub national_id_hash: Option<String>,
    pub name: Option<String>,
}

impl PersonKeys {
    pub fn of(full_name: &str, email: &str, phone: &str, national_id_hash: Option<String>) -> Self {
        Self {
            email: Some(NormalizedEmail::normalize(email)).filter(|e| !e.is_empty()),
            phone: phone_key(phone),
            national_id_hash,
            name: name_key(full_name),
        }
    }
}

/// The last ten digits, so `0532…`, `+90 532…` and `532…` compare equal.
pub fn phone_key(raw: &str) -> Option<String> {
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    (digits.len() >= 10).then(|| digits[digits.len() - 10..].to_string())
}

/// Case-, diacritic- and word-order-insensitive name.
pub fn name_key(raw: &str) -> Option<String> {
    let folded = fold_turkish(raw);
    let mut words: Vec<&str> = folded.split_whitespace().collect();
    words.sort_unstable();
    let key = words.join(" ");
    (!key.is_empty()).then_some(key)
}

/// At most one edit between two strings (insert, delete or substitute).
fn within_one_edit(a: &str, b: &str) -> bool {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    let (short, long) = if a.len() <= b.len() { (a, b) } else { (b, a) };
    if long.len() - short.len() > 1 {
        return false;
    }
    let prefix = short.iter().zip(&long).take_while(|(x, y)| x == y).count();
    if short.len() == long.len() {
        prefix == short.len() || short[prefix + 1..] == long[prefix + 1..]
    } else {
        short[prefix..] == long[prefix + 1..]
    }
}

/// Why `candidate` may be the same person as `probe`; empty when it is not.
pub fn match_reasons(candidate: &PersonKeys, probe: &PersonKeys) -> Vec<DuplicateReason> {
    let same = |a: &Option<String>, b: &Option<String>| a.is_some() && a == b;
    let mut reasons = Vec::new();
    if same(&candidate.national_id_hash, &probe.national_id_hash) {
        reasons.push(DuplicateReason::SameNationalId);
    }
    if same(&candidate.email, &probe.email) {
        reasons.push(DuplicateReason::SameEmail);
    }
    if same(&candidate.phone, &probe.phone) {
        reasons.push(DuplicateReason::SamePhone);
    }
    if let (Some(a), Some(b)) = (&candidate.name, &probe.name) {
        // A one-letter typo counts only for names long enough that it is not chance.
        if a == b || (a.chars().count() >= 8 && within_one_edit(a, b)) {
            reasons.push(DuplicateReason::SimilarName);
        }
    }
    reasons
}

/// Only digits; a national ID is never matched by its formatting.
fn national_id_digits(raw: &str) -> String {
    raw.chars().filter(char::is_ascii_digit).collect()
}

pub struct PersonRecordService {
    state: AppState,
    store: Storage,
}

impl PersonRecordService {
    pub fn new(state: AppState) -> Self {
        let store = Storage::of(&state);
        Self { state, store }
    }

    fn pool(&self) -> Result<&deadpool_postgres::Pool, PersonRecordError> {
        match &self.store {
            Storage::Postgres(pool) => Ok(pool),
            Storage::Memory => Err(PersonRecordError::Unavailable),
        }
    }

    /// The profile record of a person the caller has already resolved in `site`.
    ///
    /// # Errors
    /// A storage failure, or [`PersonRecordError::NotFound`].
    pub async fn record(
        &self,
        site: i64,
        person_id: i64,
    ) -> Result<PersonRecord, PersonRecordError> {
        let client = self.pool()?.get().await.map_err(storage)?;
        let row = client
            .query_opt(
                "SELECT p.national_id_masked, p.preferred_channel, p.preferred_language, \
                        p.emergency_contact_name, p.emergency_contact_phone, \
                        (SELECT u.id::text FROM users u WHERE u.person_id = p.id AND u.is_active LIMIT 1) \
                 FROM persons p WHERE p.id = $1 AND p.site_id = $2 AND p.deleted_at IS NULL",
                &[&person_id, &site],
            )
            .await
            .map_err(storage)?
            .ok_or(PersonRecordError::NotFound)?;
        let user_ref: Option<String> = row.get(5);
        let consents = match user_ref {
            None => Vec::new(),
            Some(user_ref) => {
                let refused: Vec<String> = client
                    .query(
                        "SELECT channel FROM communication_consents \
                         WHERE site_id = $1 AND user_ref = $2 AND NOT granted",
                        &[&site, &user_ref],
                    )
                    .await
                    .map_err(storage)?
                    .iter()
                    .map(|r| r.get(0))
                    .collect();
                CONSENT_CHANNELS
                    .iter()
                    .map(|c| ChannelConsent {
                        channel: (*c).to_string(),
                        granted: !refused.iter().any(|r| r == c),
                    })
                    .collect()
            }
        };
        Ok(PersonRecord {
            national_id_masked: row.get(0),
            preferences: ContactPreferences {
                preferred_channel: row.get(1),
                preferred_language: row.get(2),
                emergency_contact_name: row.get(3),
                emergency_contact_phone: row.get(4),
            },
            consents,
        })
    }

    /// Records or clears a person's national ID (TCKN). The database keeps only a keyed
    /// hash, for payer matching, and the masked form (V15). Returns the masked form.
    ///
    /// # Errors
    /// An invalid TCKN, an ID already recorded for another person of the site, a person
    /// of another site, or a storage failure.
    pub async fn set_national_id(
        &self,
        ctx: &AuthzContext,
        site_id: &str,
        person_id: i64,
        national_id: Option<&str>,
    ) -> Result<Option<String>, PersonRecordError> {
        let site = crate::db::parse_id_to_i64(site_id).ok_or(PersonRecordError::NotFound)?;
        let digits = national_id
            .map(national_id_digits)
            .filter(|d| !d.is_empty());
        if digits.as_deref().is_some_and(|d| !is_valid_tckn(d)) {
            return Err(PersonRecordError::InvalidNationalId);
        }
        let mut client = self.pool()?.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        // Tenant guardrail (RLS, V25).
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;
        let updated = match &digits {
            Some(d) => tx
                .query_opt(
                    "UPDATE persons SET national_id = $1 WHERE id = $2 AND site_id = $3 AND deleted_at IS NULL RETURNING national_id_masked",
                    &[d, &person_id, &site],
                )
                .await
                .map_err(|e| {
                    if e.code() == Some(&SqlState::UNIQUE_VIOLATION) {
                        PersonRecordError::NationalIdInUse
                    } else {
                        storage(e)
                    }
                })?,
            None => tx
                .query_opt(
                    "UPDATE persons SET national_id_hash = NULL, national_id_masked = NULL \
                     WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL RETURNING national_id_masked",
                    &[&person_id, &site],
                )
                .await
                .map_err(storage)?,
        };
        let masked: Option<String> = updated.ok_or(PersonRecordError::NotFound)?.get(0);
        let action = if digits.is_some() {
            "PERSON_NATIONAL_ID_SET"
        } else {
            "PERSON_NATIONAL_ID_CLEARED"
        };
        tx.execute(
            "INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,resource_id,outcome,changes) \
             VALUES ($1,'USER',$2,$3,$4,$5,'persons',$6,'SUCCESS',jsonb_build_object('person_id',$7::bigint))",
            &[&ctx.request_id, &ctx.claims.sub, &ctx.claims.role.as_str(), &site, &action, &person_id.to_string(), &person_id],
        )
        .await
        .map_err(storage)?;
        tx.commit().await.map_err(storage)?;
        Ok(masked)
    }

    /// Saves how the site reaches a person.
    ///
    /// # Errors
    /// An invalid preference, a person of another site, or a storage failure.
    pub async fn update_preferences(
        &self,
        site_id: &str,
        person_id: i64,
        preferences: ContactPreferences,
    ) -> Result<ContactPreferences, PersonRecordError> {
        let site = crate::db::parse_id_to_i64(site_id).ok_or(PersonRecordError::NotFound)?;
        let p = preferences.validated()?;
        let client = self.pool()?.get().await.map_err(storage)?;
        let changed = client
            .execute(
                "UPDATE persons SET preferred_channel = $1, preferred_language = $2, \
                        emergency_contact_name = $3, emergency_contact_phone = $4 \
                 WHERE id = $5 AND site_id = $6",
                &[
                    &p.preferred_channel,
                    &p.preferred_language,
                    &p.emergency_contact_name,
                    &p.emergency_contact_phone,
                    &person_id,
                    &site,
                ],
            )
            .await
            .map_err(storage)?;
        if changed == 0 {
            return Err(PersonRecordError::NotFound);
        }
        Ok(p)
    }

    /// People of the site who may be the person being entered, strongest match first.
    ///
    /// # Errors
    /// A storage failure.
    pub async fn duplicates(
        &self,
        site_id: &str,
        query: &DuplicateQuery,
    ) -> Result<Vec<DuplicateCandidate>, PersonRecordError> {
        let digits = query
            .national_id
            .as_deref()
            .map(national_id_digits)
            .filter(|d| !d.is_empty());
        match &self.store {
            Storage::Postgres(pool) => self.duplicates_in_db(pool, site_id, query, digits).await,
            Storage::Memory => Ok(self.duplicates_in_memory(site_id, query).await),
        }
    }

    async fn duplicates_in_db(
        &self,
        pool: &deadpool_postgres::Pool,
        site_id: &str,
        query: &DuplicateQuery,
        national_id: Option<String>,
    ) -> Result<Vec<DuplicateCandidate>, PersonRecordError> {
        let Some(site) = crate::db::parse_id_to_i64(site_id) else {
            return Ok(Vec::new());
        };
        let client = pool.get().await.map_err(storage)?;
        let hash: Option<String> = match &national_id {
            Some(d) => client
                .query_one(
                    "SELECT encode(hmac(convert_to($1, 'UTF8'), (SELECT hmac_key FROM pii_settings), 'sha256'), 'hex')",
                    &[d],
                )
                .await
                .map_err(storage)?
                .get(0),
            None => None,
        };
        let probe = probe_keys(query, hash);
        let rows = client
            .query(
                "SELECT id, full_name, COALESCE(email, ''), COALESCE(phone, ''), national_id_hash \
                 FROM persons WHERE site_id = $1 AND deleted_at IS NULL",
                &[&site],
            )
            .await
            .map_err(storage)?;
        let mut matched: Vec<(i64, Vec<DuplicateReason>)> = rows
            .iter()
            .filter(|r| Some(r.get::<_, i64>(0)) != query.exclude_person_id)
            .filter_map(|r| {
                let keys = PersonKeys::of(r.get(1), r.get(2), r.get(3), r.get(4));
                let reasons = match_reasons(&keys, &probe);
                (!reasons.is_empty()).then(|| (r.get(0), reasons))
            })
            .collect();
        rank(&mut matched);
        let ids: Vec<i64> = matched.iter().map(|(id, _)| *id).collect();
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let summaries: Vec<PersonSummary> = client
            .query(
                &format!("{SUMMARY_SELECT} WHERE p.id = ANY($1) AND p.site_id = $2"),
                &[&ids, &site],
            )
            .await
            .map_err(storage)?
            .iter()
            .map(summary)
            .collect();
        Ok(matched
            .into_iter()
            .filter_map(|(id, reasons)| {
                let person = summaries.iter().find(|s| s.person_id == id)?.clone();
                Some(DuplicateCandidate { person, reasons })
            })
            .collect())
    }

    async fn duplicates_in_memory(
        &self,
        site_id: &str,
        query: &DuplicateQuery,
    ) -> Vec<DuplicateCandidate> {
        let probe = probe_keys(query, None);
        let inner = self.state.inner.read().await;
        let mut found: Vec<DuplicateCandidate> = inner
            .users
            .iter()
            .filter(|u| crate::auth::same_id(&u.site_id, site_id))
            .filter(|u| u.person_id.is_none() || u.person_id != query.exclude_person_id)
            .filter_map(|u| {
                let reasons = match_reasons(
                    &PersonKeys::of(&u.full_name, &u.email, &u.phone, None),
                    &probe,
                );
                (!reasons.is_empty()).then(|| DuplicateCandidate {
                    person: PersonSummary {
                        person_id: u.person_id.unwrap_or_default(),
                        full_name: u.full_name.clone(),
                        email: u.email.clone(),
                        phone: u.phone.clone(),
                        role: u.role.as_str().to_string(),
                        owned_units: 0,
                        occupied_units: 0,
                        login: crate::services::person_directory_service::LoginState::Active,
                    },
                    reasons,
                })
            })
            .collect();
        found.sort_by_key(|c| std::cmp::Reverse(strength(&c.reasons)));
        found.truncate(MAX_DUPLICATES);
        found
    }
}

fn probe_keys(query: &DuplicateQuery, national_id_hash: Option<String>) -> PersonKeys {
    PersonKeys::of(
        query.full_name.as_deref().unwrap_or_default(),
        query.email.as_deref().unwrap_or_default(),
        query.phone.as_deref().unwrap_or_default(),
        national_id_hash,
    )
}

/// An identifier match outweighs any number of name matches.
fn strength(reasons: &[DuplicateReason]) -> u32 {
    reasons
        .iter()
        .map(|r| match r {
            DuplicateReason::SameNationalId => 100,
            DuplicateReason::SameEmail | DuplicateReason::SamePhone => 10,
            DuplicateReason::SimilarName => 1,
        })
        .sum()
}

fn rank(matched: &mut Vec<(i64, Vec<DuplicateReason>)>) {
    matched.sort_by_key(|(id, reasons)| (std::cmp::Reverse(strength(reasons)), *id));
    matched.truncate(MAX_DUPLICATES);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phone_numbers_compare_by_their_last_ten_digits() {
        assert_eq!(phone_key("0532 111 22 33"), phone_key("+90 (532) 111-2233"));
        assert_eq!(phone_key("5321112233").as_deref(), Some("5321112233"));
        assert_eq!(phone_key("12345"), None);
    }

    #[test]
    fn names_ignore_case_diacritics_and_word_order() {
        assert_eq!(name_key("Ayşe  YILMAZ"), name_key("yilmaz ayse"));
        assert_eq!(name_key("   "), None);
    }

    #[test]
    fn identifier_and_name_matches_are_reported() {
        let existing = PersonKeys::of(
            "Mehmet Öztürk",
            "Mehmet@Example.com",
            "0532 111 22 33",
            Some("h".into()),
        );
        let probe = PersonKeys::of(
            "mehmet ozturk",
            "mehmet@example.com",
            "5321112233",
            Some("h".into()),
        );
        assert_eq!(
            match_reasons(&existing, &probe),
            vec![
                DuplicateReason::SameNationalId,
                DuplicateReason::SameEmail,
                DuplicateReason::SamePhone,
                DuplicateReason::SimilarName
            ]
        );
        let typo = PersonKeys::of("Mehmet Ozturkk", "", "", None);
        assert_eq!(
            match_reasons(&existing, &typo),
            vec![DuplicateReason::SimilarName]
        );
        let short = PersonKeys::of("Ali Can", "", "", None);
        assert!(match_reasons(&PersonKeys::of("Ali Cam", "", "", None), &short).is_empty());
        assert!(match_reasons(&existing, &PersonKeys::default()).is_empty());
    }

    #[test]
    fn edit_distance_of_one_is_detected() {
        assert!(within_one_edit("abcdef", "abcdef"));
        assert!(within_one_edit("abcdef", "abcxef"));
        assert!(within_one_edit("abcdef", "abcdefg"));
        assert!(within_one_edit("abcdef", "bcdef"));
        assert!(!within_one_edit("abcdef", "abxdxf"));
        assert!(!within_one_edit("abc", "abcde"));
    }

    #[test]
    fn preferences_are_normalized_and_validated() {
        let p = ContactPreferences {
            preferred_channel: " sms ".into(),
            preferred_language: "EN".into(),
            emergency_contact_name: Some(" Ali Veli ".into()),
            emergency_contact_phone: Some("0532 111 22 33".into()),
        }
        .validated();
        assert_eq!(
            p.map(|p| (
                p.preferred_channel,
                p.preferred_language,
                p.emergency_contact_name
            )),
            Ok(("SMS".into(), "en".into(), Some("Ali Veli".into())))
        );
        let half = ContactPreferences {
            emergency_contact_name: Some("Ali".into()),
            ..ContactPreferences::default()
        };
        assert_eq!(
            half.validated(),
            Err(PersonRecordError::InvalidPreference("emergency_contact"))
        );
        let fax = ContactPreferences {
            preferred_channel: "FAX".into(),
            ..ContactPreferences::default()
        };
        assert_eq!(
            fax.validated(),
            Err(PersonRecordError::InvalidPreference("preferred_channel"))
        );
    }
}
