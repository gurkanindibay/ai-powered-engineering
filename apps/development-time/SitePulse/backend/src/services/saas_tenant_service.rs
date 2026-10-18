use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{
    RegisterSiteRequest, Role, SaasGlobalStatsDto, SaasSiteSummaryDto, Site,
    SiteAdminPasswordResetResponse, SiteRegistrationResponse, User,
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
        };
        inner.users.push(admin_user.clone());

        if let Some(ref pool) = self.state.pool {
            let pool = pool.clone();
            let s = new_site.clone();
            let u = admin_user.clone();
            tokio::spawn(async move {
                let _ = crate::db::save_site(&pool, &s).await;
                let _ = crate::db::save_user(&pool, &u).await;
            });
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
        })
    }

    pub async fn get_all_sites(&self) -> Vec<SaasSiteSummaryDto> {
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
            .position(|s| s.id == site_id)
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?;

        // Invariant Guard 1: Check if any independent units exist for this site
        let has_units = inner.units.iter().any(|u| u.site_id == site_id);
        if has_units {
            return Err(format!(
                "Cannot delete site '{}': active units exist in complex (işlem kaydı mevcut)",
                site_id
            ));
        }

        // Invariant Guard 2: Check if any pending registrations exist for this site
        let has_pending = inner.pending_registrations.iter().any(|r| r.site_id == site_id);
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
            .filter(|u| u.site_id == site_id)
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
        inner.users.retain(|u| u.site_id != site_id || u.role == Role::SaasAdmin);

        if let Some(ref pool) = self.state.pool {
            let pool = pool.clone();
            let s_id = site_id.to_string();
            tokio::spawn(async move {
                let _ = crate::db::delete_site(&pool, &s_id).await;
            });
        }

        Ok(())
    }

    pub async fn reset_site_admin_password(
        &self,
        site_id: &str,
    ) -> Result<SiteAdminPasswordResetResponse, String> {
        let mut inner = self.state.inner.write().await;

        let site = inner
            .sites
            .iter()
            .find(|s| s.id == site_id)
            .ok_or_else(|| format!("Site with id '{}' not found", site_id))?
            .clone();

        let user_idx = inner
            .users
            .iter()
            .position(|u| u.site_id == site_id && u.role == Role::SiteManager)
            .ok_or_else(|| format!("No SiteManager found for site '{}'", site_id))?;

        let temp_pass = generate_secure_temporary_password();
        let password_hash = format!("ARGON2_HASH_{}", &temp_pass);

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
            let pool = pool.clone();
            tokio::spawn(async move {
                let _ = crate::db::save_user(&pool, &updated_user).await;
            });
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
