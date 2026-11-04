use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{
    RegisterSiteRequest, Role, SaasGlobalStatsDto, SaasSiteSummaryDto, Site,
    SiteAdminPasswordResetResponse, SiteRegistrationResponse, UpdateSiteRequest, User,
};
use crate::state::AppState;

pub struct SaasTenantService {
    state: AppState,
}

impl SaasTenantService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn register_site(
        &self,
        request: RegisterSiteRequest,
    ) -> Result<SiteRegistrationResponse, String> {
        if request.site_name.trim().is_empty() {
            return Err("Site name cannot be empty".to_string());
        }
        if request.site_admin_email.trim().is_empty() {
            return Err("Site manager email cannot be empty".to_string());
        }
        if request.site_admin_full_name.trim().is_empty() {
            return Err("Site manager full name cannot be empty".to_string());
        }

        let mut inner = self.state.inner.write().await;

        let email_norm = request.site_admin_email.trim().to_lowercase();
        if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
            return Err(format!(
                "An account with this email address already exists (zaten mevcut): {}",
                request.site_admin_email
            ));
        }

        let base_slug = to_slug(&request.site_name);
        let mut slug = base_slug.clone();
        let mut counter = 1;
        while inner.sites.iter().any(|s| s.slug == slug) {
            slug = format!("{}-{}", base_slug, counter);
            counter += 1;
        }

        let site_id = format!("site-{}", &Uuid::new_v4().to_string()[..8]);
        let plan = request
            .plan_type
            .unwrap_or_else(|| "STANDARD".to_string())
            .to_uppercase();
        let license_end = Utc::now().date_naive() + chrono::Days::new(365);

        let new_site = Site {
            id: site_id.clone(),
            name: request.site_name.clone(),
            address: request.address.clone(),
            slug: slug.clone(),
            status: "ACTIVE".to_string(),
            plan_type: plan.clone(),
            license_end_date: license_end,
        };
        inner.sites.push(new_site.clone());

        let temp_pass = generate_secure_temporary_password();
        let password_hash = format!("ARGON2_HASH_{}", &temp_pass);

        let user_id = format!("usr-{}", &Uuid::new_v4().to_string()[..8]);
        let admin_user = User {
            id: user_id.clone(),
            site_id: site_id.clone(),
            full_name: request.site_admin_full_name.clone(),
            email: email_norm.clone(),
            phone: request.site_admin_phone.clone(),
            password_hash: Some(password_hash),
            role: Role::SiteManager,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: None,
        };
        inner.users.push(admin_user.clone());

        let blocks_list: Vec<String> = request
            .blocks
            .filter(|b| !b.is_empty())
            .unwrap_or_else(|| vec!["A Blok".to_string(), "B Blok".to_string()]);

        for (idx, bname) in blocks_list.iter().enumerate() {
            inner.blocks.push(crate::models::BlockDto {
                id: format!("blk-{}-{}", &site_id[..6.min(site_id.len())], idx + 1),
                site_id: site_id.clone(),
                block_name: bname.clone(),
                total_floors: 10,
            });
        }

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_site(pool, &new_site).await;
            let _ = crate::db::save_user(pool, &admin_user).await;
            if let Ok(client) = pool.get().await {
                let numeric_site = crate::db::parse_id_to_i64(&site_id).unwrap_or(1);
                for bname in &blocks_list {
                    let _ = client
                        .execute(
                            "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) ON CONFLICT DO NOTHING",
                            &[&numeric_site, bname],
                        )
                        .await;
                }
            }
        }

        Ok(SiteRegistrationResponse {
            site_id,
            site_name: request.site_name,
            slug,
            status: "ACTIVE".to_string(),
            plan_type: plan,
            admin_user_id: user_id,
            admin_full_name: request.site_admin_full_name,
            admin_email: email_norm,
            temporary_password: temp_pass,
            must_change_password: true,
            created_at: Utc::now(),
            blocks: blocks_list,
        })
    }

    pub async fn get_all_sites(&self) -> Vec<SaasSiteSummaryDto> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(rows) = client
                    .query(
                        "SELECT s.id, s.name, s.slug, s.address, s.status, s.plan_type, s.license_end_date FROM sites s ORDER BY s.id ASC",
                        &[],
                    )
                    .await
                {
                    let mut result = Vec::new();
                    for row in rows {
                        let id: i64 = row.get(0);
                        let name: String = row.get(1);
                        let slug: String = row.get::<_, Option<String>>(2).unwrap_or_else(|| id.to_string());
                        let address: String = row.get::<_, Option<String>>(3).unwrap_or_default();
                        let status: String = row.get::<_, Option<String>>(4).unwrap_or_else(|| "ACTIVE".to_string());
                        let plan_type: String = row.get::<_, Option<String>>(5).unwrap_or_else(|| "STANDARD".to_string());
                        let license_end_date: Option<chrono::NaiveDate> = row.get(6);

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

                        let unit_count_row = client
                            .query_one("SELECT COUNT(*) FROM units WHERE site_id = $1", &[&id])
                            .await
                            .ok();
                        let total_units: i64 = unit_count_row.map(|r| r.get(0)).unwrap_or(0);

                        let dues_volume_row = client
                            .query_one(
                                "SELECT COALESCE(SUM(principal_amount), 0) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id = $1",
                                &[&id],
                            )
                            .await
                            .ok();
                        let monthly_dues_volume: Decimal = dues_volume_row
                            .map(|r| r.get(0))
                            .unwrap_or(Decimal::ZERO);

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
                            license_end_date: license_end_date.unwrap_or_else(|| chrono::Utc::now().date_naive() + chrono::Days::new(365)),
                            total_units: total_units as i32,
                            monthly_dues_volume,
                            primary_manager_name,
                            primary_manager_email,
                            primary_manager_phone,
                            blocks,
                        });
                    }
                    if !result.is_empty() {
                        return result;
                    }
                }
            }
        }

        let inner = self.state.inner.read().await;
        inner
            .sites
            .iter()
            .map(|site| {
                let primary_manager = inner
                    .users
                    .iter()
                    .find(|u| u.site_id == site.id && u.role == Role::SiteManager);

                let total_units = inner.units.iter().filter(|u| u.site_id == site.id).count();
                let site_unit_ids: std::collections::HashSet<&str> = inner
                    .units
                    .iter()
                    .filter(|u| u.site_id == site.id)
                    .map(|u| u.id.as_str())
                    .collect();
                let monthly_dues_volume: Decimal = inner
                    .dues
                    .iter()
                    .filter(|d| site_unit_ids.contains(d.unit_id.as_str()))
                    .map(|d| d.principal_amount)
                    .sum();

                let site_blocks: Vec<String> = inner
                    .blocks
                    .iter()
                    .filter(|b| b.site_id == site.id || site.id.ends_with(&b.site_id))
                    .map(|b| b.block_name.clone())
                    .collect();
                let blocks = if site_blocks.is_empty() {
                    vec!["A Blok".to_string(), "B Blok".to_string()]
                } else {
                    site_blocks
                };

                SaasSiteSummaryDto {
                    site_id: site.id.clone(),
                    site_name: site.name.clone(),
                    slug: site.slug.clone(),
                    address: site.address.clone(),
                    status: site.status.clone(),
                    plan_type: site.plan_type.clone(),
                    license_end_date: site.license_end_date,
                    total_units: total_units as i32,
                    monthly_dues_volume,
                    primary_manager_name: primary_manager
                        .map(|m| m.full_name.clone())
                        .unwrap_or_else(|| "Unassigned".to_string()),
                    primary_manager_email: primary_manager
                        .map(|m| m.email.clone())
                        .unwrap_or_else(|| "-".to_string()),
                    primary_manager_phone: primary_manager
                        .map(|m| m.phone.clone())
                        .unwrap_or_else(|| "-".to_string()),
                    blocks,
                }
            })
            .collect()
    }

    pub async fn get_global_stats(&self) -> SaasGlobalStatsDto {
        let inner = self.state.inner.read().await;
        let total_sites = inner.sites.len();
        let active_sites = inner
            .sites
            .iter()
            .filter(|s| s.status.eq_ignore_ascii_case("ACTIVE"))
            .count();
        let total_units = total_sites * 20;
        let volume = Decimal::from_str_exact("80000.00").unwrap() * Decimal::from(total_sites);

        SaasGlobalStatsDto {
            total_sites,
            active_sites,
            total_units,
            monthly_collection_volume: volume,
        }
    }

    pub async fn delete_site(&self, site_id: &str) -> Result<(), String> {
        let mut inner = self.state.inner.write().await;
        let site_idx = inner
            .sites
            .iter()
            .position(|s| s.id == site_id || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id))
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?;

        let actual_site_id = inner.sites[site_idx].id.clone();

        // Invariant Guard 1: Check if any independent units exist for this site
        let has_units = inner.units.iter().any(|u| u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id));
        if has_units {
            return Err(format!(
                "Cannot delete site '{}': active units exist in complex (işlem kaydı mevcut)",
                site_id
            ));
        }

        // Invariant Guard 2: Check if any pending registrations exist for this site
        let has_pending = inner.pending_registrations.iter().any(|r| r.site_id == actual_site_id || crate::db::parse_id_to_i64(&r.site_id) == crate::db::parse_id_to_i64(&actual_site_id));
        if has_pending {
            return Err(format!(
                "Cannot delete site '{}': pending registration requests exist",
                site_id
            ));
        }

        // Invariant Guard 3: Check if any dues liabilities exist for units belonging to this site
        let unit_ids: Vec<String> = inner
            .units
            .iter()
            .filter(|u| u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
            .map(|u| u.id.clone())
            .collect();
        let has_dues = inner.dues.iter().any(|d| unit_ids.contains(&d.unit_id));
        if has_dues {
            return Err(format!(
                "Cannot delete site '{}': financial dues liabilities exist",
                site_id
            ));
        }

        // Invariant passed: purge site
        inner.sites.remove(site_idx);

        // Purge unactivated tenant admin user(s) created for this site
        inner.users.retain(|u| (u.site_id != actual_site_id && crate::db::parse_id_to_i64(&u.site_id) != crate::db::parse_id_to_i64(&actual_site_id)) || u.role == Role::SaasAdmin);

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::delete_site(pool, site_id).await;
            if actual_site_id != site_id {
                let _ = crate::db::delete_site(pool, &actual_site_id).await;
            }
        }

        Ok(())
    }

    pub async fn update_site(
        &self,
        site_id: &str,
        req: UpdateSiteRequest,
    ) -> Result<SaasSiteSummaryDto, String> {
        let mut inner = self.state.inner.write().await;
        let site_idx = inner
            .sites
            .iter()
            .position(|s| s.id == site_id || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id))
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?;

        if let Some(ref name) = req.site_name {
            if name.trim().is_empty() {
                return Err("Site name cannot be empty".to_string());
            }
            inner.sites[site_idx].name = name.trim().to_string();
            inner.sites[site_idx].slug = to_slug(name);
        }
        if let Some(ref addr) = req.address {
            inner.sites[site_idx].address = addr.trim().to_string();
        }
        if let Some(ref status) = req.status {
            inner.sites[site_idx].status = status.trim().to_uppercase();
        }
        if let Some(ref plan) = req.plan_type {
            inner.sites[site_idx].plan_type = plan.trim().to_uppercase();
        }

        let actual_site_id = inner.sites[site_idx].id.clone();
        let updated_site = inner.sites[site_idx].clone();

        // Check email uniqueness if a new email is provided
        if let Some(ref email) = req.site_admin_email {
            let email_clean = email.trim().to_lowercase();
            if !email_clean.is_empty() {
                let user_idx = inner.users.iter().position(|u| {
                    (u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
                        && u.role == Role::SiteManager
                });
                let current_user_id = user_idx.map(|idx| inner.users[idx].id.clone());
                let email_exists = inner.users.iter().any(|u| Some(&u.id) != current_user_id.as_ref() && u.email.to_lowercase() == email_clean);
                if email_exists {
                    return Err(format!("An account with this email address already exists (zaten mevcut): {}", email));
                }
            }
        }

        // Update site admin user if details are provided
        let mut admin_user_to_save: Option<User> = None;
        if req.site_admin_full_name.is_some() || req.site_admin_email.is_some() || req.site_admin_phone.is_some() {
            if let Some(user) = inner.users.iter_mut().find(|u| {
                (u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
                    && u.role == Role::SiteManager
            }) {
                if let Some(ref fname) = req.site_admin_full_name {
                    if !fname.trim().is_empty() {
                        user.full_name = fname.trim().to_string();
                    }
                }
                if let Some(ref email) = req.site_admin_email {
                    let email_clean = email.trim().to_lowercase();
                    if !email_clean.is_empty() {
                        user.email = email_clean;
                    }
                }
                if let Some(ref phone) = req.site_admin_phone {
                    user.phone = phone.trim().to_string();
                }
                admin_user_to_save = Some(user.clone());
            }
        }

        // Update blocks if provided
        let mut updated_blocks: Vec<String> = Vec::new();
        if let Some(ref new_blocks) = req.blocks {
            inner.blocks.retain(|b| b.site_id != actual_site_id && crate::db::parse_id_to_i64(&b.site_id) != crate::db::parse_id_to_i64(&actual_site_id));
            for (idx, bname) in new_blocks.iter().enumerate() {
                let trimmed = bname.trim();
                if !trimmed.is_empty() {
                    inner.blocks.push(crate::models::BlockDto {
                        id: format!("blk-{}-{}", &actual_site_id[..6.min(actual_site_id.len())], idx + 1),
                        site_id: actual_site_id.clone(),
                        block_name: trimmed.to_string(),
                        total_floors: 10,
                    });
                    updated_blocks.push(trimmed.to_string());
                }
            }
        } else {
            updated_blocks = inner
                .blocks
                .iter()
                .filter(|b| b.site_id == actual_site_id || crate::db::parse_id_to_i64(&b.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
                .map(|b| b.block_name.clone())
                .collect();
        }

        // Find current admin info for summary
        let admin_info = inner.users.iter().find(|u| {
            (u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
                && u.role == Role::SiteManager
        });

        let primary_name = admin_info.map(|u| u.full_name.clone()).unwrap_or_else(|| "Unassigned".to_string());
        let primary_email = admin_info.map(|u| u.email.clone()).unwrap_or_else(|| "-".to_string());
        let primary_phone = admin_info.map(|u| u.phone.clone()).unwrap_or_else(|| "-".to_string());

        let total_units = inner.units.iter().filter(|u| {
            u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id)
        }).count() as i32;

        let site_unit_ids: std::collections::HashSet<&str> = inner
            .units
            .iter()
            .filter(|u| u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
            .map(|u| u.id.as_str())
            .collect();

        let volume: Decimal = inner
            .dues
            .iter()
            .filter(|d| site_unit_ids.contains(d.unit_id.as_str()))
            .map(|d| d.principal_amount)
            .sum();

        // Synchronous PostgreSQL persistence
        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_site(pool, &updated_site).await;
            if let Some(ref u) = admin_user_to_save {
                let _ = crate::db::save_user(pool, u).await;
            }
            if let Ok(client) = pool.get().await {
                let numeric_site = crate::db::parse_id_to_i64(&actual_site_id).unwrap_or(1);
                let _ = client.execute("DELETE FROM blocks WHERE site_id = $1", &[&numeric_site]).await;
                for bname in &updated_blocks {
                    let _ = client
                        .execute(
                            "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10)",
                            &[&numeric_site, bname],
                        )
                        .await;
                }
            }
        }

        Ok(SaasSiteSummaryDto {
            site_id: actual_site_id,
            site_name: updated_site.name,
            slug: updated_site.slug,
            address: updated_site.address,
            status: updated_site.status,
            plan_type: updated_site.plan_type,
            license_end_date: updated_site.license_end_date,
            total_units,
            monthly_dues_volume: volume,
            primary_manager_name: primary_name,
            primary_manager_email: primary_email,
            primary_manager_phone: primary_phone,
            blocks: updated_blocks,
        })
    }

    pub async fn reset_site_admin_password(
        &self,
        site_id: &str,
    ) -> Result<SiteAdminPasswordResetResponse, String> {
        let temp_pass = generate_secure_temporary_password();
        let password_hash = format!("ARGON2_HASH_{}", &temp_pass);

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let numeric_site = crate::db::parse_id_to_i64(site_id).unwrap_or(0);
                let site_row_opt = client
                    .query_opt(
                        "SELECT id, name FROM sites WHERE id = $1 OR id::text = $2",
                        &[&numeric_site, &site_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;

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
                        .await
                        .map_err(|e| e.to_string())?;

                    if let Some(urow) = user_row_opt {
                        let u_id: i64 = urow.get(0);
                        let u_name: String = urow.get(1);
                        let u_email: String = urow.get(2);

                        client
                            .execute(
                                "UPDATE users SET password_hash = $1, must_change_password = true WHERE id = $2",
                                &[&password_hash, &u_id],
                            )
                            .await
                            .map_err(|e| e.to_string())?;

                        // Sync in-memory state
                        let mut inner = self.state.inner.write().await;
                        if let Some(user) = inner.users.iter_mut().find(|u| {
                            u.id == u_id.to_string()
                                || crate::db::parse_id_to_i64(&u.id) == Some(u_id)
                                || u.email.to_lowercase() == u_email.to_lowercase()
                        }) {
                            user.password_hash = Some(password_hash.clone());
                            user.must_change_password = true;
                        }

                        return Ok(SiteAdminPasswordResetResponse {
                            site_id: s_id.to_string(),
                            site_name: s_name,
                            admin_user_id: u_id.to_string(),
                            admin_full_name: u_name,
                            admin_email: u_email,
                            temporary_password: temp_pass,
                            must_change_password: true,
                            renewed_at: Utc::now(),
                        });
                    }
                }
            }
        }

        let mut inner = self.state.inner.write().await;

        let site = inner
            .sites
            .iter()
            .find(|s| s.id == site_id || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id))
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?
            .clone();

        let actual_site_id = site.id.clone();

        let user_idx = inner
            .users
            .iter()
            .position(|u| {
                (u.site_id == actual_site_id || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(&actual_site_id))
                    && u.role == Role::SiteManager
            })
            .ok_or_else(|| format!("No SiteManager found for site '{}'", site_id))?;

        let admin_user_id;
        let admin_full_name;
        let admin_email;
        let updated_user = {
            let user = &mut inner.users[user_idx];
            user.password_hash = Some(password_hash);
            user.must_change_password = true;
            admin_user_id = user.id.clone();
            admin_full_name = user.full_name.clone();
            admin_email = user.email.clone();
            user.clone()
        };

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_user(pool, &updated_user).await;
        }

        Ok(SiteAdminPasswordResetResponse {
            site_id: site.id,
            site_name: site.name,
            admin_user_id,
            admin_full_name,
            admin_email,
            temporary_password: temp_pass,
            must_change_password: true,
            renewed_at: Utc::now(),
        })
    }
}

pub fn to_slug(input: &str) -> String {
    let s = input
        .to_lowercase()
        .replace('ı', "i")
        .replace('ğ', "g")
        .replace('ü', "u")
        .replace('ş', "s")
        .replace('ö', "o")
        .replace('ç', "c");
    let cleaned: String = s
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect();
    let trimmed = cleaned.trim_matches('-');
    if trimmed.is_empty() {
        "site".to_string()
    } else {
        trimmed.to_string()
    }
}

fn generate_secure_temporary_password() -> String {
    let part1: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(4)
        .map(char::from)
        .collect();
    let part2: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(4)
        .map(char::from)
        .collect();
    format!("SP-{}-{}", part1.to_uppercase(), part2.to_uppercase())
}
