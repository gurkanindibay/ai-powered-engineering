use chrono::NaiveDate;
use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{logged, parse_id_to_i64, require_id, DbResult};
use crate::models::{BlockDto, PlanType, SaasGlobalStatsDto, SaasSiteSummaryDto, Site, SiteStatus};
pub async fn save_site(
    pool: &Pool,
    site: &Site,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = pool.get().await?;
    let maybe_id = parse_id_to_i64(&site.id);
    let id_num = match maybe_id {
        Some(id) if id > 0 => {
            let tx = super::tenant_guard::begin_tenant_tx(&mut client, id).await?;
            tx.execute(
                r#"
                    INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date, tax_id, tax_office, proration_enabled)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                    ON CONFLICT (id) DO UPDATE SET
                        name = EXCLUDED.name,
                        address = EXCLUDED.address,
                        slug = EXCLUDED.slug,
                        status = EXCLUDED.status,
                        plan_type = EXCLUDED.plan_type,
                        license_end_date = EXCLUDED.license_end_date,
                        tax_id = EXCLUDED.tax_id,
                        tax_office = EXCLUDED.tax_office,
                        proration_enabled = EXCLUDED.proration_enabled
                    "#,
                &[
                    &id,
                    &site.name,
                    &site.address,
                    &site.slug,
                    &site.status,
                    &site.plan_type,
                    &site.license_end_date,
                    &site.tax_id,
                    &site.tax_office,
                    &site.proration_enabled,
                ],
            )
            .await?;
            tx.commit().await?;
            id
        }
        _ => {
            // tenant-guard: platform — new site creation before id is assigned.
            let tx = super::tenant_guard::begin_platform_tx(&mut client).await?;
            let row = tx
                .query_one(
                    r#"
                    INSERT INTO sites (name, address, slug, status, plan_type, license_end_date, tax_id, tax_office, proration_enabled)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                    ON CONFLICT (slug) WHERE deleted_at IS NULL DO UPDATE SET
                        name = EXCLUDED.name,
                        address = EXCLUDED.address,
                        status = EXCLUDED.status,
                        plan_type = EXCLUDED.plan_type,
                        license_end_date = EXCLUDED.license_end_date,
                        proration_enabled = EXCLUDED.proration_enabled,
                        tax_id = EXCLUDED.tax_id,
                        tax_office = EXCLUDED.tax_office
                    RETURNING id
                    "#,
                    &[
                        &site.name,
                        &site.address,
                        &site.slug,
                        &site.status,
                        &site.plan_type,
                        &site.license_end_date,
                        &site.tax_id,
                        &site.tax_office,
                        &site.proration_enabled,
                    ],
                )
                .await?;
            let new_id: i64 = row.get(0);
            tx.commit().await?;
            new_id
        }
    };
    info!(
        "Saved site {} (numeric ID: {}) ({}) to PostgreSQL sites",
        site.id, id_num, site.name
    );
    Ok(())
}

/// Persists whether a site has explicitly enabled occupancy-aware dues proration.
pub async fn set_proration_policy(pool: &Pool, site_id: &str, enabled: bool) -> DbResult<()> {
    let site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_tenant_tx(&mut client, site).await?;
    let rows = tx
        .execute(
            "UPDATE sites SET proration_enabled = $2 WHERE id = $1 AND deleted_at IS NULL",
            &[&site, &enabled],
        )
        .await?;
    if rows != 1 {
        return Err(format!("site {} not found", site_id).into());
    }
    tx.commit().await?;
    Ok(())
}

/// Marks a site deleted (soft delete); financial history is never removed.
pub async fn soft_delete_site(pool: &Pool, site_id: &str) -> DbResult<()> {
    let id = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, id).await?;
    let deleted = tx
        .query_opt(
            "UPDATE sites SET status = 'DELETED', deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL RETURNING id",
            &[&id],
        )
        .await?;
    if deleted.is_none() {
        return Err(format!("Site {} not found", site_id).into());
    }
    tx.execute(
        "UPDATE users SET is_active = FALSE, auth_version = auth_version + 1 WHERE site_id = $1 AND is_active",
        &[&id],
    )
    .await?;
    tx.execute(
        "UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, now()) WHERE revoked_at IS NULL AND user_id IN (SELECT id FROM users WHERE site_id = $1)",
        &[&id],
    )
    .await?;
    tx.execute(
        "UPDATE account_activations SET used_at = COALESCE(used_at, now()) WHERE used_at IS NULL AND user_id IN (SELECT id FROM users WHERE site_id = $1)",
        &[&id],
    )
    .await?;
    tx.execute(
        "UPDATE persons SET deleted_at = now() WHERE site_id = $1 AND deleted_at IS NULL",
        &[&id],
    )
    .await?;
    tx.commit().await?;
    Ok(())
}

/// Whether a site may be used (exists, not deleted, not suspended).
pub async fn site_is_active(pool: &Pool, site_id: &str) -> DbResult<bool> {
    let Some(id) = parse_id_to_i64(site_id) else {
        return Ok(false);
    };
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_tenant_read(&mut client, id).await?;
    let active = tx
        .query_opt(
            "SELECT 1 FROM sites WHERE id=$1 AND deleted_at IS NULL AND status IN ('ACTIVE','TRIAL')",
            &[&id],
        )
        .await?
        .is_some();
    tx.commit().await?;
    Ok(active)
}

/// Check site availability on an existing attributed connection.
///
/// # Errors
/// Propagates database failures.
pub async fn site_is_active_from_client(
    client: &impl tokio_postgres::GenericClient,
    site_id: &str,
) -> DbResult<bool> {
    let Some(id) = parse_id_to_i64(site_id) else {
        return Ok(false);
    };
    Ok(client.query_opt(
        "SELECT 1 FROM sites WHERE id=$1 AND deleted_at IS NULL AND status IN ('ACTIVE','TRIAL')",
        &[&id],
    ).await?.is_some())
}

/// Hard delete, used only by the development purge tooling.
pub async fn delete_site(
    pool: &Pool,
    site_id: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut client = pool.get().await?;
    let id_num = require_id("entity", site_id)?;
    let tx = super::tenant_guard::begin_tenant_tx(&mut client, id_num).await?;
    tx.execute("DELETE FROM sites WHERE id = $1", &[&id_num])
        .await?;
    tx.commit().await?;
    info!(
        "Deleted site {} (numeric ID: {}) from PostgreSQL sites",
        site_id, id_num
    );
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
    // tenant-guard: platform — SaaS admin creates a new site before its id exists.
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_platform(&tx).await?;
    let normalized_email = crate::domain::email::NormalizedEmail::normalize(admin_email);
    if tx
        .query_opt(
            // person-scope: platform — SaaS admin creates a site before its id exists; the admin email is globally unique
            "SELECT 1 FROM users WHERE LOWER(email) = $1 AND is_active",
            &[&normalized_email],
        )
        .await?
        .is_some()
    {
        return Err("An account with this email address already exists".into());
    }

    let site_row = tx
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

    let p_id = super::person_repository::resolve_new_site_person(
        &tx,
        admin_full_name,
        Some(admin_phone),
        Some(admin_email),
        "SITE_MANAGER",
        numeric_site,
        true,
    )
    .await?;

    let user_row = tx
        .query_one(
            // person-scope: platform — SaaS admin creates a site before its id exists
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
        let block_row = tx
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

    tx.commit().await?;
    Ok(CreatedSiteRegistration {
        site_id: s_id,
        user_id: u_id,
        blocks: created_blocks,
        person_id: p_id,
    })
}

pub async fn fetch_all_saas_site_summaries(pool: &Pool) -> DbResult<Vec<SaasSiteSummaryDto>> {
    // tenant-guard: platform — SaaS admin site summary list.
    let mut conn = pool.get().await?;
    let client = super::tenant_guard::begin_platform_read(&mut conn).await?;
    let rows = client
        .query(
            "SELECT s.id, s.name, s.slug, s.address, s.status, s.plan_type, s.license_end_date, s.timezone FROM sites s WHERE s.deleted_at IS NULL ORDER BY s.id ASC",
            &[],
        )
        .await?;

    let mut result = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let name: String = row.get(1);
        let slug: String = row
            .get::<_, Option<String>>(2)
            .unwrap_or_else(|| id.to_string());
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
                 WHERE (u.site_id = $1 OR u.site_id::text = $2) AND u.role = 'SITE_MANAGER' AND u.is_active ORDER BY u.id ASC LIMIT 1",
                &[&id, &id.to_string()],
            )
            .await
            .ok()
            .flatten();

        let (primary_manager_name, primary_manager_email, primary_manager_phone) = match manager_row
        {
            Some(m_row) => (
                m_row.get::<_, String>(0),
                m_row.get::<_, String>(1),
                m_row
                    .get::<_, Option<String>>(2)
                    .unwrap_or_else(|| "-".to_string()),
            ),
            None => ("Unassigned".to_string(), "-".to_string(), "-".to_string()),
        };

        let unit_count_row = logged(
            client
                .query_one("SELECT COUNT(*) FROM units WHERE site_id = $1", &[&id])
                .await,
            "fetch site units",
        );
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
        let monthly_dues_volume: Decimal =
            dues_volume_row.map(|r| r.get(0)).unwrap_or(Decimal::ZERO);

        let block_rows = client
            .query(
                "SELECT block_name FROM blocks WHERE site_id = $1 ORDER BY id ASC",
                &[&id],
            )
            .await
            .unwrap_or_default();
        let blocks: Vec<String> = block_rows.iter().map(|r| r.get(0)).collect();

        result.push(SaasSiteSummaryDto {
            site_id: id.to_string(),
            site_name: name,
            slug,
            address,
            status,
            plan_type,
            license_end_date: license_end_date.unwrap_or_else(|| {
                let timezone = row
                    .get::<_, Option<String>>(7)
                    .unwrap_or_else(crate::models::default_site_timezone);
                crate::domain::clock::default_license_end(&timezone, crate::e2e_clock::now_utc())
            }),
            total_units: total_units as i32,
            monthly_dues_volume,
            primary_manager_name,
            primary_manager_email,
            primary_manager_phone,
            blocks,
        });
    }

    client.commit().await?;
    Ok(result)
}

/// Reconciles a site's blocks with `blocks` by name, in one transaction.
///
/// Blocks whose name is kept stay untouched (units reference them with an
/// `ON DELETE RESTRICT` foreign key), new names are inserted, and only blocks
/// that disappeared from the list are deleted. Removing a block that still has
/// units fails and rolls the whole change back.
pub async fn replace_site_blocks(pool: &Pool, site_id: &str, blocks: &[String]) -> DbResult<()> {
    let numeric_site = require_id("site", site_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    super::tx_bind_tenant(&tx, numeric_site).await?;
    let existing: Vec<String> = tx
        .query(
            "SELECT block_name FROM blocks WHERE site_id = $1",
            &[&numeric_site],
        )
        .await?
        .iter()
        .map(|row| row.get(0))
        .collect();
    let removed: Vec<&String> = existing
        .iter()
        .filter(|name| !blocks.contains(name))
        .collect();
    for bname in removed {
        tx.execute(
            "DELETE FROM blocks WHERE site_id = $1 AND block_name = $2",
            &[&numeric_site, bname],
        )
        .await?;
    }
    for bname in blocks.iter().filter(|name| !existing.contains(name)) {
        tx.execute(
            "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10)",
            &[&numeric_site, bname],
        )
        .await?;
    }
    tx.commit().await?;
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
    let mut conn = pool.get().await?;
    let numeric_site = require_id("site", site_id)?;
    let client = super::tenant_guard::begin_tenant_tx(&mut conn, numeric_site).await?;
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
                    // person-scope: person — the user id is the site's SITE_MANAGER, resolved with u.site_id = $1
                    "UPDATE users SET password_hash = $1, must_change_password = true WHERE id = $2",
                    &[&password_hash, &u_id],
                )
                .await?;
            client.commit().await?;

            return Ok(Some(ResetPasswordResult {
                site_id: s_id,
                site_name: s_name,
                user_id: u_id,
                user_name: u_name,
                user_email: u_email,
            }));
        }
    }
    client.commit().await?;
    Ok(None)
}

pub async fn get_blocks_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<BlockDto>, Box<dyn std::error::Error + Send + Sync>> {
    let mut conn = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let client = super::tenant_guard::begin_tenant_read(&mut conn, site_id_num).await?;
    let rows = client
        .query(
            "SELECT id, site_id, block_name, total_floors FROM blocks WHERE site_id = $1 ORDER BY id ASC",
            &[&site_id_num],
        )
        .await?;
    client.commit().await?;

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

pub async fn fetch_saas_global_stats(pool: &Pool) -> DbResult<SaasGlobalStatsDto> {
    // tenant-guard: platform — SaaS admin global statistics.
    let mut conn = pool.get().await?;
    let client = super::tenant_guard::begin_platform_read(&mut conn).await?;
    let sites_row = client
        .query_one(
            "SELECT COUNT(*)::bigint, COUNT(*) FILTER (WHERE status = 'ACTIVE')::bigint FROM sites WHERE deleted_at IS NULL",
            &[],
        )
        .await?;
    let total_sites: i64 = sites_row.get(0);
    let active_sites: i64 = sites_row.get(1);

    let units_row = client
        .query_one("SELECT COUNT(*)::bigint FROM units", &[])
        .await?;
    let total_units: i64 = units_row.get(0);

    let dues_row = client
        .query_one(
            "SELECT COALESCE(SUM(principal_amount), 0) FROM dues_liabilities",
            &[],
        )
        .await?;
    let monthly_collection_volume: Decimal = dues_row.get(0);
    client.commit().await?;

    Ok(SaasGlobalStatsDto {
        total_sites: total_sites as usize,
        active_sites: active_sites as usize,
        total_units: total_units as usize,
        monthly_collection_volume,
    })
}

/// Stores a site's accrual schedule (STORY-07-10). Periods already accrued keep their dates.
pub async fn save_site_accrual_schedule(
    pool: &Pool,
    site_id: &str,
    schedule: &crate::domain::accrual_schedule::AccrualSchedule,
) -> DbResult<()> {
    let id = require_id("site", site_id)?;
    let mut conn = pool.get().await?;
    let client = super::tenant_guard::begin_tenant_tx(&mut conn, id).await?;
    let small = |v: u32| i16::try_from(v).unwrap_or(0);
    let updated = client
        .execute(
            "UPDATE sites SET accrual_day = $2, due_day = $3, grace_days = $4, \
             catch_up_limit_months = $5, go_live_date = $6 WHERE id = $1 AND deleted_at IS NULL",
            &[
                &id,
                &small(schedule.accrual_day),
                &small(schedule.due_day),
                &small(schedule.grace_days),
                &small(schedule.catch_up_limit_months),
                &schedule.go_live_date,
            ],
        )
        .await?;
    if updated == 0 {
        return Err(format!("Site {} not found", site_id).into());
    }
    client.commit().await?;
    Ok(())
}
