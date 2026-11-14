//! Person persistence. All new person rows are inserted through this module.

/// Candidate found by the shared soft duplicate rules.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DuplicateMatch {
    pub person_id: i64,
    pub reasons: Vec<crate::services::person_record_service::DuplicateReason>,
}

#[derive(Debug, thiserror::Error)]
pub enum ResolvePersonError {
    #[error("Person identity is already recorded: {0}")]
    IdentityTaken(i64),
    #[error("Possible duplicate people: {0:?}")]
    PossibleDuplicate(Vec<DuplicateMatch>),
    #[error(transparent)]
    Database(#[from] tokio_postgres::Error),
}

/// Resolves a new site person in the caller's transaction after duplicate checks.
pub async fn resolve_new_site_person(
    tx: &deadpool_postgres::Transaction<'_>,
    full_name: &str,
    phone: Option<&str>,
    email: Option<&str>,
    person_type: &str,
    site_id: i64,
    confirm_distinct: bool,
) -> Result<i64, ResolvePersonError> {
    if let Some(email) = email.filter(|value| !value.trim().is_empty()) {
        if let Some(row) = tx
            .query_opt(
                "SELECT id FROM persons WHERE site_id = $1 AND lower(email) = lower($2) AND deleted_at IS NULL",
                &[&site_id, &email],
            )
            .await?
        {
            return Err(ResolvePersonError::IdentityTaken(row.get(0)));
        }
    }
    let candidates = duplicate_candidates(
        tx,
        site_id,
        full_name,
        email.unwrap_or_default(),
        phone.unwrap_or_default(),
    )
    .await?;
    if !candidates.is_empty() && !confirm_distinct {
        return Err(ResolvePersonError::PossibleDuplicate(candidates));
    }
    insert_site_person(tx, full_name, phone, email, person_type, Some(site_id))
        .await
        .map_err(ResolvePersonError::Database)
}

/// Finds possible duplicates inside the caller's transaction and tenant scope.
pub async fn duplicate_candidates(
    tx: &deadpool_postgres::Transaction<'_>,
    site_id: i64,
    full_name: &str,
    email: &str,
    phone: &str,
) -> Result<Vec<DuplicateMatch>, tokio_postgres::Error> {
    use crate::services::person_record_service::{match_reasons, PersonKeys};

    let rows = tx
        .query(
            "SELECT id, full_name, COALESCE(email, ''), COALESCE(phone, ''), national_id_hash \
             FROM persons WHERE site_id = $1 AND deleted_at IS NULL ORDER BY id LIMIT 10000",
            &[&site_id],
        )
        .await?;
    let probe = PersonKeys::of(full_name, email, phone, None);
    let mut matches = rows
        .iter()
        .filter_map(|row| {
            let existing = PersonKeys::of(row.get(1), row.get(2), row.get(3), row.get(4));
            let reasons = match_reasons(&existing, &probe);
            (!reasons.is_empty()).then(|| DuplicateMatch {
                person_id: row.get(0),
                reasons,
            })
        })
        .collect::<Vec<_>>();
    matches.truncate(10);
    Ok(matches)
}

/// Inserts a site person and returns the database assigned identity.
pub async fn insert_site_person(
    client: &deadpool_postgres::Transaction<'_>,
    full_name: &str,
    phone: Option<&str>,
    email: Option<&str>,
    person_type: &str,
    site_id: Option<i64>,
) -> Result<i64, tokio_postgres::Error> {
    let row = client
        .query_one(
            "INSERT INTO persons (full_name, phone, email, person_type, site_id) VALUES ($1, $2, $3, $4, $5) RETURNING id",
            &[&full_name, &phone, &email, &person_type, &site_id],
        )
        .await?;
    Ok(row.get(0))
}

/// Inserts a platform person without a tenant site.
pub async fn insert_platform_person(
    client: &deadpool_postgres::Client,
    full_name: &str,
    email: &str,
    person_type: &str,
) -> Result<i64, tokio_postgres::Error> {
    let row = client
        .query_one(
            "INSERT INTO persons (full_name, email, person_type) VALUES ($1, $2, $3) RETURNING id",
            &[&full_name, &email, &person_type],
        )
        .await?;
    Ok(row.get(0))
}

/// Imports a legacy identity using its historical ID when it is not present.
pub async fn ensure_legacy_person(
    client: &deadpool_postgres::Client,
    id: i64,
    full_name: &str,
    phone: Option<&str>,
    email: &str,
    person_type: &str,
) -> Result<(), tokio_postgres::Error> {
    client
        .execute(
            "INSERT INTO persons (id, full_name, phone, email, person_type) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING",
            &[&id, &full_name, &phone, &email, &person_type],
        )
        .await?;
    Ok(())
}
