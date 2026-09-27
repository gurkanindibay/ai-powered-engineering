use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{HomeOwnerResponse, RegisterHomeOwnerRequest, Role, User};
use crate::state::AppState;

pub struct SiteAdminService {
    state: AppState,
}

impl SiteAdminService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn register_home_owner(
        &self,
        site_id: &str,
        request: RegisterHomeOwnerRequest,
    ) -> Result<HomeOwnerResponse, String> {
        if site_id.trim().is_empty() {
            return Err("Site ID cannot be empty".to_string());
        }
        if request.owner_full_name.trim().is_empty() {
            return Err("Home owner name cannot be empty".to_string());
        }
        if request.email.trim().is_empty() {
            return Err("Home owner email cannot be empty".to_string());
        }
        if request.block.trim().is_empty() {
            return Err("Block name cannot be empty".to_string());
        }

        let mut inner = self.state.inner.write().await;
        let email_norm = request.email.trim().to_lowercase();

        if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
            return Err(format!(
                "An account with this email address already exists (zaten mevcut): {}",
                request.email
            ));
        }

        let temp_pass = generate_resident_temporary_password();
        let password_hash = format!("argon2id_hash_placeholder:{}", &temp_pass);

        let user_id = format!("usr-resident-{}", &Uuid::new_v4().to_string()[..8]);
        let resident_user = User {
            id: user_id,
            site_id: site_id.to_string(),
            full_name: request.owner_full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone(),
            password_hash: Some(password_hash),
            role: Role::HomeResident,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
        };
        inner.users.push(resident_user);

        let unit_id = format!("unit-{}", &Uuid::new_v4().to_string()[..8]);

        Ok(HomeOwnerResponse {
            unit_id,
            site_id: site_id.to_string(),
            block: request.block,
            unit_no: request.unit_no,
            floor: request.floor,
            owner_full_name: request.owner_full_name,
            email: email_norm,
            phone: request.phone,
            land_share: request.land_share.unwrap_or_else(|| "1/24".to_string()),
            monthly_dues: request
                .monthly_dues
                .unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap()),
            is_resident: request.is_resident,
            temporary_password: Some(temp_pass),
            must_change_password: true,
            created_at: Utc::now(),
        })
    }

    pub async fn get_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let inner = self.state.inner.read().await;
        let mut result = Vec::new();
        let mut counter = 1;

        for user in inner
            .users
            .iter()
            .filter(|u| u.site_id == site_id && u.role == Role::HomeResident)
        {
            result.push(HomeOwnerResponse {
                unit_id: format!("unit-auto-{}", counter),
                site_id: site_id.to_string(),
                block: "A Blok".to_string(),
                unit_no: 10 + counter,
                floor: counter,
                owner_full_name: user.full_name.clone(),
                email: user.email.clone(),
                phone: user.phone.clone(),
                land_share: "1/24".to_string(),
                monthly_dues: Decimal::from_str_exact("1400.00").unwrap(),
                is_resident: true,
                temporary_password: None,
                must_change_password: user.must_change_password,
                created_at: user.created_at,
            });
            counter += 1;
        }

        result
    }
}

fn generate_resident_temporary_password() -> String {
    let part: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(4)
        .map(char::from)
        .collect();
    format!("SP-SAKIN-{}", part.to_uppercase())
}
