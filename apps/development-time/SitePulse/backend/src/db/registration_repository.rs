use deadpool_postgres::Pool;
use tracing::info;

use crate::models::PendingRegistrationResponse;
use super::base::require_id;
pub async fn save_pending_registration(
    pool: &Pool,
    req: &PendingRegistrationResponse,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &req.site_id)?;
    client
        .execute(
            r#"
            INSERT INTO pending_registrations (request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            ON CONFLICT (request_id) DO UPDATE SET
                status = EXCLUDED.status,
                full_name = EXCLUDED.full_name,
                email = EXCLUDED.email,
                phone = EXCLUDED.phone
            "#,
            &[
                &req.request_id,
                &site_id_num,
                &req.block,
                &req.unit_no,
                &req.floor,
                &req.full_name,
                &req.email,
                &req.phone,
                &req.is_resident,
                &req.status,
                &req.submitted_at,
            ],
        )
        .await?;
    info!("Saved pending registration {} ({}) to PostgreSQL", req.request_id, req.email);
    Ok(())
}

pub async fn update_pending_registration_status(
    pool: &Pool,
    request_id: &str,
    status: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            "UPDATE pending_registrations SET status = $2 WHERE request_id = $1",
            &[&request_id, &status],
        )
        .await?;
    info!("Updated pending registration {} status to {} in PostgreSQL", request_id, status);
    Ok(())
}

