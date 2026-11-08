use chrono::Utc;

use rust_decimal::Decimal;

use crate::models::{
    AuthProvider, PlanType, RegisterSiteRequest, Role, SaasGlobalStatsDto, SaasSiteSummaryDto,
    Site, SiteAdminPasswordResetResponse, SiteRegistrationResponse, SiteStatus, UpdateSiteRequest,
    User,
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
        if inner
            .users
            .iter()
            .any(|u| u.email.to_lowercase() == email_norm)
        {
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

        let plan = request
            .plan_type
            .as_deref()
            .map(PlanType::from_str_loose)
            .unwrap_or(PlanType::Standard);
        let license_end = Utc::now().date_naive() + chrono::Days::new(365);

        let temp_pass = generate_secure_temporary_password();
        let password_hash = crate::auth::hash_password_async(temp_pass.clone()).await?;

        let blocks_list: Vec<String> = request
            .blocks
            .filter(|b| !b.is_empty())
            .unwrap_or_else(|| vec!["A Blok".to_string(), "B Blok".to_string()]);

        let (site_id, user_id, block_dtos, person_id) = if let Some(ref pool) = self.state.pool {
            let reg = crate::db::create_site_with_manager_and_blocks(
                pool,
                &request.site_name,
                &request.address,
                &slug,
                plan.as_str(),
                license_end,
                &request.site_admin_full_name,
                &request.site_admin_phone,
                &email_norm,
                &password_hash,
                &blocks_list,
            )
            .await
            .map_err(|e| e.to_string())?;

            (reg.site_id, reg.user_id, reg.blocks, Some(reg.person_id))
        } else {
            let max_site = inner
                .sites
                .iter()
                .filter_map(|s| crate::db::parse_id_to_i64(&s.id))
                .max()
                .unwrap_or(0);
            let s_id = (max_site + 1).to_string();

            let max_user = inner
                .users
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
            let u_id = (max_user + 1).to_string();

            let mut max_block = inner
                .blocks
                .iter()
                .filter_map(|b| crate::db::parse_id_to_i64(&b.id))
                .max()
                .unwrap_or(0);
            let mut created_blocks = Vec::new();
            for bname in &blocks_list {
                max_block += 1;
                created_blocks.push(crate::models::BlockDto {
                    id: max_block.to_string(),
                    site_id: s_id.clone(),
                    block_name: bname.clone(),
                    total_floors: 10,
                });
            }

            (s_id, u_id, created_blocks, None)
        };

        let new_site = Site {
            id: site_id.clone(),
            name: request.site_name.clone(),
            address: request.address.clone(),
            slug: slug.clone(),
            status: SiteStatus::Active,
            plan_type: plan,
            license_end_date: license_end,
            timezone: crate::models::default_site_timezone(),
            tax_id: None,
            tax_office: None,
        };
        inner.sites.push(new_site);

        let admin_user = User {
            id: user_id.clone(),
            site_id: site_id.clone(),
            full_name: request.site_admin_full_name.clone(),
            email: email_norm.clone(),
            phone: request.site_admin_phone.clone(),
            password_hash: Some(password_hash),
            role: Role::SiteManager,
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id,
        };
        inner.users.push(admin_user);

        for b in block_dtos {
            inner.blocks.push(b);
        }

        Ok(SiteRegistrationResponse {
            site_id,
            site_name: request.site_name,
            slug,
            status: SiteStatus::Active,
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
            if let Ok(summaries) = crate::db::fetch_all_saas_site_summaries(pool).await {
                if !summaries.is_empty() {
                    return summaries;
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
                    status: site.status,
                    plan_type: site.plan_type,
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
            .filter(|s| s.status == SiteStatus::Active)
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
            .position(|s| {
                s.id == site_id
                    || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id)
            })
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?;

        let actual_site_id = inner.sites[site_idx].id.clone();

        // Invariant Guard 1: Check if any independent units exist for this site
        let has_units = inner.units.iter().any(|u| {
            u.site_id == actual_site_id
                || crate::db::parse_id_to_i64(&u.site_id)
                    == crate::db::parse_id_to_i64(&actual_site_id)
        });
        if has_units {
            return Err(format!(
                "Cannot delete site '{}': active units exist in complex (işlem kaydı mevcut)",
                site_id
            ));
        }

        // Invariant Guard 2: Check if any pending registrations exist for this site
        let has_pending = inner.pending_registrations.iter().any(|r| {
            r.site_id == actual_site_id
                || crate::db::parse_id_to_i64(&r.site_id)
                    == crate::db::parse_id_to_i64(&actual_site_id)
        });
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
            .filter(|u| {
                u.site_id == actual_site_id
                    || crate::db::parse_id_to_i64(&u.site_id)
                        == crate::db::parse_id_to_i64(&actual_site_id)
            })
            .map(|u| u.id.clone())
            .collect();
        let has_dues = inner.dues.iter().any(|d| unit_ids.contains(&d.unit_id));
        if has_dues {
            return Err(format!(
                "Cannot delete site '{}': financial dues liabilities exist",
                site_id
            ));
        }

        // Invariants passed: soft-delete. The row (and anything that references it)
        // is kept for audit; the site disappears from listings and its users can
        // no longer sign in. The database is updated first, memory only on success.
        if let Some(ref pool) = self.state.pool {
            crate::db::soft_delete_site(pool, &actual_site_id)
                .await
                .map_err(|e| e.to_string())?;
        }
        inner.sites.remove(site_idx);
        inner.users.retain(|u| {
            !crate::auth::same_id(&u.site_id, &actual_site_id) || u.role == Role::SaasAdmin
        });

        Ok(())
    }

    pub async fn update_site(
        &self,
        site_id: &str,
        req: UpdateSiteRequest,
    ) -> Result<SaasSiteSummaryDto, String> {
        // Issuer tax id printed on receipts (O-5): validated before anything changes.
        let tax_id: Option<Option<String>> = match req.tax_id.as_deref() {
            None => None,
            Some(raw) => {
                let clean: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
                let valid = clean.is_empty()
                    || ((clean.len() == 10 || clean.len() == 11)
                        && clean.chars().all(|c| c.is_ascii_digit()));
                if !valid {
                    return Err("tax_id must be 10 (VKN) or 11 (TCKN) digits".to_string());
                }
                Some(if clean.is_empty() { None } else { Some(clean) })
            }
        };
        let mut inner = self.state.inner.write().await;
        let site_idx = inner
            .sites
            .iter()
            .position(|s| {
                s.id == site_id
                    || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id)
            })
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
            inner.sites[site_idx].status = SiteStatus::from_str_loose(status);
        }
        if let Some(ref plan) = req.plan_type {
            inner.sites[site_idx].plan_type = PlanType::from_str_loose(plan);
        }
        if let Some(tax_id) = tax_id.clone() {
            inner.sites[site_idx].tax_id = tax_id;
        }
        if let Some(ref office) = req.tax_office {
            let office = office.trim();
            inner.sites[site_idx].tax_office = if office.is_empty() {
                None
            } else {
                Some(office.to_string())
            };
        }

        let actual_site_id = inner.sites[site_idx].id.clone();
        let updated_site = inner.sites[site_idx].clone();

        // Check email uniqueness if a new email is provided
        if let Some(ref email) = req.site_admin_email {
            let email_clean = email.trim().to_lowercase();
            if !email_clean.is_empty() {
                let user_idx = inner.users.iter().position(|u| {
                    (u.site_id == actual_site_id
                        || crate::db::parse_id_to_i64(&u.site_id)
                            == crate::db::parse_id_to_i64(&actual_site_id))
                        && u.role == Role::SiteManager
                });
                let current_user_id = user_idx.map(|idx| inner.users[idx].id.clone());
                let email_exists = inner.users.iter().any(|u| {
                    Some(&u.id) != current_user_id.as_ref() && u.email.to_lowercase() == email_clean
                });
                if email_exists {
                    return Err(format!(
                        "An account with this email address already exists (zaten mevcut): {}",
                        email
                    ));
                }
            }
        }

        // Update site admin user if details are provided
        let mut admin_user_to_save: Option<User> = None;
        if req.site_admin_full_name.is_some()
            || req.site_admin_email.is_some()
            || req.site_admin_phone.is_some()
        {
            if let Some(user) = inner.users.iter_mut().find(|u| {
                (u.site_id == actual_site_id
                    || crate::db::parse_id_to_i64(&u.site_id)
                        == crate::db::parse_id_to_i64(&actual_site_id))
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
            inner.blocks.retain(|b| {
                b.site_id != actual_site_id
                    && crate::db::parse_id_to_i64(&b.site_id)
                        != crate::db::parse_id_to_i64(&actual_site_id)
            });
            let mut max_block = inner
                .blocks
                .iter()
                .filter_map(|b| crate::db::parse_id_to_i64(&b.id))
                .max()
                .unwrap_or(0);
            for bname in new_blocks {
                let trimmed = bname.trim();
                if !trimmed.is_empty() {
                    max_block += 1;
                    inner.blocks.push(crate::models::BlockDto {
                        id: max_block.to_string(),
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
                .filter(|b| {
                    b.site_id == actual_site_id
                        || crate::db::parse_id_to_i64(&b.site_id)
                            == crate::db::parse_id_to_i64(&actual_site_id)
                })
                .map(|b| b.block_name.clone())
                .collect();
        }

        // Find current admin info for summary
        let admin_info = inner.users.iter().find(|u| {
            (u.site_id == actual_site_id
                || crate::db::parse_id_to_i64(&u.site_id)
                    == crate::db::parse_id_to_i64(&actual_site_id))
                && u.role == Role::SiteManager
        });

        let primary_name = admin_info
            .map(|u| u.full_name.clone())
            .unwrap_or_else(|| "Unassigned".to_string());
        let primary_email = admin_info
            .map(|u| u.email.clone())
            .unwrap_or_else(|| "-".to_string());
        let primary_phone = admin_info
            .map(|u| u.phone.clone())
            .unwrap_or_else(|| "-".to_string());

        let total_units = inner
            .units
            .iter()
            .filter(|u| {
                u.site_id == actual_site_id
                    || crate::db::parse_id_to_i64(&u.site_id)
                        == crate::db::parse_id_to_i64(&actual_site_id)
            })
            .count() as i32;

        let site_unit_ids: std::collections::HashSet<&str> = inner
            .units
            .iter()
            .filter(|u| {
                u.site_id == actual_site_id
                    || crate::db::parse_id_to_i64(&u.site_id)
                        == crate::db::parse_id_to_i64(&actual_site_id)
            })
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
            crate::db::save_site(pool, &updated_site)
                .await
                .map_err(|e| e.to_string())?;
            if let Some(ref u) = admin_user_to_save {
                crate::db::save_user(pool, u)
                    .await
                    .map_err(|e| e.to_string())?;
            }
            // Blocks are rewritten only when the request names them: re-inserting an
            // unchanged list would delete blocks that units still reference.
            if req.blocks.is_some() {
                crate::db::replace_site_blocks(pool, &actual_site_id, &updated_blocks)
                    .await
                    .map_err(|e| e.to_string())?;
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
        let password_hash = crate::auth::hash_password_async(temp_pass.clone()).await?;

        if let Some(ref pool) = self.state.pool {
            let res_opt =
                crate::db::reset_site_admin_password_by_site(pool, site_id, &password_hash)
                    .await
                    .map_err(|e| e.to_string())?;

            if let Some(res) = res_opt {
                // Sync in-memory state
                let mut inner = self.state.inner.write().await;
                if let Some(user) = inner.users.iter_mut().find(|u| {
                    u.id == res.user_id.to_string()
                        || crate::db::parse_id_to_i64(&u.id) == Some(res.user_id)
                        || u.email.to_lowercase() == res.user_email.to_lowercase()
                }) {
                    user.password_hash = Some(password_hash.clone());
                    user.must_change_password = true;
                }

                return Ok(SiteAdminPasswordResetResponse {
                    site_id: res.site_id.to_string(),
                    site_name: res.site_name,
                    admin_user_id: res.user_id.to_string(),
                    admin_full_name: res.user_name,
                    admin_email: res.user_email,
                    temporary_password: temp_pass,
                    must_change_password: true,
                    renewed_at: Utc::now(),
                });
            } else {
                return Err(format!(
                    "Site {} not found or has no active site manager",
                    site_id
                ));
            }
        }

        let mut inner = self.state.inner.write().await;

        let site = inner
            .sites
            .iter()
            .find(|s| {
                s.id == site_id
                    || crate::db::parse_id_to_i64(&s.id) == crate::db::parse_id_to_i64(site_id)
            })
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?
            .clone();

        let actual_site_id = site.id.clone();

        let user_idx = inner
            .users
            .iter()
            .position(|u| {
                (u.site_id == actual_site_id
                    || crate::db::parse_id_to_i64(&u.site_id)
                        == crate::db::parse_id_to_i64(&actual_site_id))
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
            crate::db::save_user(pool, &updated_user)
                .await
                .map_err(|e| e.to_string())?;
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
    crate::auth::generate_temporary_password("SP-")
}
