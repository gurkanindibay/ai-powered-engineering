//! Tenant-scoped persistence for the selected unit contact.
use crate::models::PrimaryResponsibleContact;

pub async fn save(
    pool: &deadpool_postgres::Pool,
    site_id: i64,
    unit_id: i64,
    contact: &PrimaryResponsibleContact,
) -> super::DbResult<bool> {
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site_id).await?;
    let value = serde_json::to_value(contact)?;
    let count = tx
        .execute(
            "UPDATE units SET primary_responsible_contact = $1 WHERE id = $2 AND site_id = $3",
            &[&value, &unit_id, &site_id],
        )
        .await?;
    tx.commit().await?;
    Ok(count == 1)
}

/// Selects the primary contact by person card. The person must hold an active
/// relation to the unit (owner, tenant, owner occupant or household member).
/// Returns `None` when the unit is missing or the person is not on it.
pub async fn save_by_person(
    pool: &deadpool_postgres::Pool,
    site_id: i64,
    unit_id: i64,
    person_id: i64,
) -> super::DbResult<Option<PrimaryResponsibleContact>> {
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, site_id).await?;
    let relations = tx
        .query(
            "SELECT relation FROM v_person_unit_relations \
             WHERE site_id = $1 AND unit_id = $2 AND person_id = $3 AND active",
            &[&site_id, &unit_id, &person_id],
        )
        .await?;
    let kinds: Vec<String> = relations.iter().map(|r| r.get(0)).collect();
    let role = if kinds.iter().any(|k| k == "OWNER") {
        "OWNER"
    } else if kinds.iter().any(|k| k == "TENANT") {
        "TENANT"
    } else if kinds.iter().any(|k| k == "HOUSEHOLD_MEMBER") {
        "RESIDENT"
    } else {
        return Ok(None);
    };
    let Some(person) = tx
        .query_opt(
            "SELECT full_name, COALESCE(phone, ''), COALESCE(email, '') FROM persons \
             WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL AND merged_into_person_id IS NULL",
            &[&person_id, &site_id],
        )
        .await?
    else {
        return Ok(None);
    };
    let contact = PrimaryResponsibleContact {
        primary_responsible_name: person.get(0),
        primary_responsible_role: role.to_string(),
        primary_responsible_phone: person.get(1),
        primary_responsible_email: person.get(2),
        primary_responsible_member_id: None,
    };
    let value = serde_json::to_value(&contact)?;
    let count = tx
        .execute(
            "UPDATE units SET primary_responsible_contact = $1, primary_contact_person_id = $2 \
             WHERE id = $3 AND site_id = $4",
            &[&value, &person_id, &unit_id, &site_id],
        )
        .await?;
    tx.commit().await?;
    Ok((count == 1).then_some(contact))
}
