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
