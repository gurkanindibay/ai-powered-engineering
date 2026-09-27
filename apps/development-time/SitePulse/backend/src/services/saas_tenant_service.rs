use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{
    RegisterSiteRequest, Role, SaasGlobalStatsDto, SaasSiteSummaryDto, Site,
    SiteRegistrationResponse, User,
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
        inner.sites.push(new_site);

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
        inner.users.push(admin_user);

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

                let default_units = if site.id == "site-1" { 24 } else { 16 };
                let default_dues = if site.id == "site-1" {
                    Decimal::from_str_exact("96000.00").unwrap()
                } else {
                    Decimal::from_str_exact("64000.00").unwrap()
                };

                SaasSiteSummaryDto {
                    site_id: site.id.clone(),
                    site_name: site.name.clone(),
                    slug: site.slug.clone(),
                    address: site.address.clone(),
                    status: site.status.clone(),
                    plan_type: site.plan_type.clone(),
                    license_end_date: site.license_end_date,
                    total_units: default_units,
                    monthly_dues_volume: default_dues,
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
}

fn to_slug(input: &str) -> String {
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
