//! Person persistence. All new person rows are inserted through this module.

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

/// Inserts a site person through a pooled client for legacy non-transactional callers.
pub async fn insert_site_person_client(
    client: &deadpool_postgres::Client,
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
