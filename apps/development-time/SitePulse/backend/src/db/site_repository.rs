use chrono::{NaiveDate, Utc};
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use crate::models::{BlockDto, PlanType, SaasSiteSummaryDto, Site, SiteStatus};
use super::base::{logged, parse_id_to_i64, require_id, DbResult};
pub async fn save_site(pool: &Pool, site: &Site) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let maybe_id = parse_id_to_i64(&site.id);
    let id_num = match maybe_id {
        Some(id) if id > 0 => {
            client
                .execute(
                    r#"
                    INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (id) DO UPDATE SET
                        name = EXCLUDED.name,
                        address = EXCLUDED.address,
                        slug = EXCLUDED.slug,
                        status = EXCLUDED.status,
                        plan_type = EXCLUDED.plan_type,
                        license_end_date = EXCLUDED.license_end_date
                    "#,
                    &[
                        &id,
                        &site.name,
                        &site.address,
                        &site.slug,
                        &site.status,
                        &site.plan_type,
                        &site.license_end_date,
                    ],
                )
                .await?;
            id
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
                    VALUES ($1, $2, $3, $4, $5, $6)
                    ON CONFLICT (slug) DO UPDATE SET
                        name = EXCLUDED.name,
                        address = EXCLUDED.address,
                        status = EXCLUDED.status,
                        plan_type = EXCLUDED.plan_type,
                        license_end_date = EXCLUDED.license_end_date
                    RETURNING id
                    "#,
                    &[
                        &site.name,
                        &site.address,
                        &site.slug,
                        &site.status,
                        &site.plan_type,
                        &site.license_end_date,
                    ],
                )
                .await?;
            row.get(0)
        }
    };
    info!("Saved site {} (numeric ID: {}) ({}) to PostgreSQL sites", site.id, id_num, site.name);
    Ok(())
}

/// Marks a site deleted (soft delete); financial history is never removed.
pub async fn soft_delete_site(pool: &Pool, site_id: &str) -> DbResult<()> {
    let id = require_id("site", site_id)?;
    let client = pool.get().await?;
    let n = client
        .execute("UPDATE sites SET status = 'DELETED', deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL", &[&id])
        .await?;
    if n == 0 {
        return Err(format!("Site {} not found", site_id).into());
    }
    Ok(())
}

/// Whether a site may be used (exists, not deleted, not suspended).
pub async fn site_is_active(pool: &Pool, site_id: &str) -> DbResult<bool> {
    let Some(id) = parse_id_to_i64(site_id) else { return Ok(false) };
    let client = pool.get().await?;
    Ok(client
        .query_opt("SELECT 1 FROM sites WHERE id = $1 AND deleted_at IS NULL AND status <> 'SUSPENDED'", &[&id])
        .await?
        .is_some())
}

/// Hard delete, used only by the development purge tooling.
pub async fn delete_site(pool: &Pool, site_id: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = require_id("entity", site_id)?;
    client.execute("DELETE FROM sites WHERE id = $1", &[&id_num]).await?;
    info!("Deleted site {} (numeric ID: {}) from PostgreSQL sites", site_id, id_num);
    Ok(())
}

#[derive(Debug, Clone)]
pub struct CreatedSiteRegistration {
    pub site_id: String,
    pub user_id: String,
    pub blocks: Vec<BlockDto>,
    pub person_id: i64,
}

#[allow(clippy::too_many_arguments)]
pub async fn create_site_with_manager_and_blocks(
    pool: &Pool,
    site_name: &str,
    address: &str,
    slug: &str,
    plan: &str,
    license_end: NaiveDate,
    admin_full_name: &str,
    admin_phone: &str,
    admin_email: &str,
    password_hash: &str,
    block_names: &[String],
) -> DbResult<CreatedSiteRegistration> {
    let client = pool.get().await?;

    let site_row = client
        .query_one(
            r#"
            INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
            VALUES ($1, $2, $3, 'ACTIVE', $4, $5)
            RETURNING id
            "#,
            &[&site_name, &address, &slug, &plan, &license_end],
        )
        .await?;
    let numeric_site: i64 = site_row.get(0);
    let s_id = numeric_site.to_string();

    let person_row = client
        .query_one(
            r#"
            INSERT INTO persons (full_name, phone, email, person_type)
            VALUES ($1, $2, $3, 'SITE_MANAGER')
            RETURNING id
            "#,
            &[&admin_full_name, &admin_phone, &admin_email],
        )
        .await?;
    let p_id: i64 = person_row.get(0);

    let user_row = client
        .query_one(
            r#"
            INSERT INTO users (site_id, email, password_hash, role, must_change_password, person_id)
            VALUES ($1, $2, $3, 'SITE_MANAGER', true, $4)
            RETURNING id
            "#,
            &[&numeric_site, &admin_email, &password_hash, &p_id],
        )
        .await?;
    let numeric_user: i64 = user_row.get(0);
    let u_id = numeric_user.to_string();

    let mut created_blocks = Vec::new();
    for bname in block_names {
        let block_row = client
            .query_one(
                "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id",
                &[&numeric_site, bname],
            )
            .await?;
        let numeric_block: i64 = block_row.get(0);
        created_blocks.push(BlockDto {
            id: numeric_block.to_string(),
            site_id: s_id.clone(),
            block_name: bname.clone(),
            total_floors: 10,
        });
    }

    Ok(CreatedSiteRegistration {
        site_id: s_id,
        user_id: u_id,
        blocks: created_blocks,
        person_id: p_id,
    })
}

pub async fn fetch_all_saas_site_summaries(pool: &Pool) -> DbResult<Vec<SaasSiteSummaryDto>> {
    let client = pool.get().await?;
    let rows = client
        .query(
            "SELECT s.id, s.name, s.slug, s.address, s.status, s.plan_type, s.license_end_date FROM sites s WHERE s.deleted_at IS NULL ORDER BY s.id ASC",
            &[],
        )
        .await?;

    let mut result = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let name: String = row.get(1);
        let slug: String = row.get::<_, Option<String>>(2).unwrap_or_else(|| id.to_string());
        let address: String = row.get::<_, Option<String>>(3).unwrap_or_default();
        let status: SiteStatus = row
            .get::<_, Option<String>>(4)
            .as_deref()
            .map(SiteStatus::from_str_loose)
            .unwrap_or(SiteStatus::Active);
        let plan_type: PlanType = row
            .get::<_, Option<String>>(5)
            .as_deref()
            .map(PlanType::from_str_loose)
            .unwrap_or(PlanType::Standard);
        let license_end_date: Option<NaiveDate> = row.get(6);

        let manager_row = client
            .query_opt(
                "SELECT COALESCE(p.full_name, 'Site Manager'), u.email, COALESCE(p.phone, '-')
                 FROM users u
                 LEFT JOIN persons p ON u.person_id = p.id
                 WHERE (u.site_id = $1 OR u.site_id::text = $2) AND u.role = 'SITE_MANAGER' ORDER BY u.id ASC LIMIT 1",
                &[&id, &id.to_string()],
            )
            .await
            .ok()
            .flatten();

        let (primary_manager_name, primary_manager_email, primary_manager_phone) = match manager_row {
            Some(m_row) => (
                m_row.get::<_, String>(0),
                m_row.get::<_, String>(1),
                m_row.get::<_, Option<String>>(2).unwrap_or_else(|| "-".to_string()),
            ),
            None => ("Unassigned".to_string(), "-".to_string(), "-".to_string()),
        };

        let unit_count_row = logged(client.query_one("SELECT COUNT(*) FROM units WHERE site_id = $1", &[&id]).await, "fetch site units");
        let total_units: i64 = unit_count_row.map(|r| r.get(0)).unwrap_or(0);

        let dues_volume_row = logged(
            client
                .query_one(
                    "SELECT COALESCE(SUM(principal_amount), 0) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id = $1",
                    &[&id],
                )
                .await,
            "site dues volume",
        );
        let monthly_dues_volume: Decimal = dues_volume_row.map(|r| r.get(0)).unwrap_or(Decimal::ZERO);

        let block_rows = client
            .query("SELECT block_name FROM blocks WHERE site_id = $1 ORDER BY id ASC", &[&id])
            .await
            .unwrap_or_default();
        let mut blocks: Vec<String> = block_rows.iter().map(|r| r.get(0)).collect();
        if blocks.is_empty() {
            blocks = vec!["A Blok".to_string(), "B Blok".to_string()];
        }

        result.push(SaasSiteSummaryDto {
            site_id: id.to_string(),
            site_name: name,
            slug,
            address,
            status,
            plan_type,
            license_end_date: license_end_date.unwrap_or_else(|| Utc::now().date_naive() + chrono::Days::new(365)),
            total_units: total_units as i32,
            monthly_dues_volume,
            primary_manager_name,
            primary_manager_email,
            primary_manager_phone,
            blocks,
        });
    }

    Ok(result)
}

pub async fn replace_site_blocks(pool: &Pool, site_id: &str, blocks: &[String]) -> DbResult<()> {
    let client = pool.get().await?;
    let numeric_site = require_id("site", site_id)?;
    client.execute("DELETE FROM blocks WHERE site_id = $1", &[&numeric_site]).await?;
    for bname in blocks {
        client
            .execute(
                "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10)",
                &[&numeric_site, bname],
            )
            .await?;
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct ResetPasswordResult {
    pub site_id: i64,
    pub site_name: String,
    pub user_id: i64,
    pub user_name: String,
    pub user_email: String,
}

pub async fn reset_site_admin_password_by_site(
    pool: &Pool,
    site_id: &str,
    password_hash: &str,
) -> DbResult<Option<ResetPasswordResult>> {
    let client = pool.get().await?;
    let numeric_site = require_id("site", site_id)?;
    let site_row_opt = client
        .query_opt(
            "SELECT id, name FROM sites WHERE id = $1 OR id::text = $2",
            &[&numeric_site, &site_id],
        )
        .await?;

    if let Some(srow) = site_row_opt {
        let s_id: i64 = srow.get(0);
        let s_name: String = srow.get(1);

        let user_row_opt = client
            .query_opt(
                "SELECT u.id, COALESCE(p.full_name, 'Site Manager'), u.email
                 FROM users u
                 LEFT JOIN persons p ON u.person_id = p.id
                 WHERE (u.site_id = $1 OR u.site_id::text = $2) AND u.role = 'SITE_MANAGER' LIMIT 1",
                &[&s_id, &site_id],
            )
            .await?;

        if let Some(urow) = user_row_opt {
            let u_id: i64 = urow.get(0);
            let u_name: String = urow.get(1);
            let u_email: String = urow.get(2);

            client
                .execute(
                    "UPDATE users SET password_hash = $1, must_change_password = true WHERE id = $2",
                    &[&password_hash, &u_id],
                )
                .await?;

            return Ok(Some(ResetPasswordResult {
                site_id: s_id,
                site_name: s_name,
                user_id: u_id,
                user_name: u_name,
                user_email: u_email,
            }));
        }
    }
    Ok(None)
}


pub async fn get_blocks_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<BlockDto>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let rows = client
        .query(
            "SELECT id, site_id, block_name, total_floors FROM blocks WHERE site_id = $1 ORDER BY id ASC",
            &[&site_id_num],
        )
        .await?;

    let mut list = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let s_id: i64 = row.get(1);
        let block_name: String = row.get(2);
        let total_floors: i32 = row.get(3);

        list.push(BlockDto {
            id: id.to_string(),
            site_id: s_id.to_string(),
            block_name,
            total_floors,
        });
    }
    Ok(list)
}

