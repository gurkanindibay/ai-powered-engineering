use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use uuid::Uuid;

use crate::models::{
    ApprovalResultResponse, PendingRegistrationResponse, Role, SiteInvitationLinkResponse,
    SubmitSelfRegistrationRequest, User,
};
use crate::state::AppState;

pub struct RegistrationApprovalService {
    state: AppState,
}

impl RegistrationApprovalService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn generate_invitation_link(&self, site_id: &str) -> SiteInvitationLinkResponse {
        let inner = self.state.inner.read().await;
        let site = inner.sites.iter().find(|s| s.id == site_id);
        let site_name = site
            .map(|s| s.name.clone())
            .unwrap_or_else(|| format!("Site {}", site_id));
        let slug = site
            .map(|s| s.slug.clone())
            .unwrap_or_else(|| crate::services::to_slug(site_id));

        let token_part: String = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(6)
            .map(char::from)
            .collect();
        let token = format!("SP-INV-{}", token_part.to_uppercase());
        let join_url = format!("https://sitepulse.app/join/{}?token={}", slug, token);
        let expires_at = Utc::now() + chrono::Days::new(7);

        SiteInvitationLinkResponse {
            site_id: site_id.to_string(),
            site_name,
            slug,
            token,
            join_url,
            expires_at,
        }
    }

    pub async fn submit_self_registration(
        &self,
        slug: &str,
        request: SubmitSelfRegistrationRequest,
    ) -> Result<PendingRegistrationResponse, String> {
        if request.full_name.trim().is_empty() {
            return Err("Full name cannot be empty".to_string());
        }
        if request.email.trim().is_empty() {
            return Err("Email cannot be empty".to_string());
        }
        if request.block.trim().is_empty() {
            return Err("Block cannot be empty".to_string());
        }

        let mut inner = self.state.inner.write().await;
        let email_norm = request.email.trim().to_lowercase();

        if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
            return Err(format!(
                "An account with this email address already exists (zaten mevcut): {}",
                request.email
            ));
        }

        let request_id = format!("req-{}", &Uuid::new_v4().to_string()[..8]);
        let site_id = inner
            .sites
            .iter()
            .find(|s| s.slug == slug)
            .map(|s| s.id.clone())
            .unwrap_or_else(|| "site-1".to_string());

        let item = PendingRegistrationResponse {
            request_id: request_id.clone(),
            site_id,
            block: request.block,
            unit_no: request.unit_no,
            floor: request.floor,
            full_name: request.full_name,
            email: email_norm,
            phone: request.phone,
            is_resident: request.is_resident,
            status: "PENDING".to_string(),
            submitted_at: Utc::now(),
        };

        inner.pending_registrations.push(item.clone());
        Ok(item)
    }

    pub async fn get_pending_registrations(&self, site_id: &str) -> Vec<PendingRegistrationResponse> {
        let inner = self.state.inner.read().await;
        let mut list: Vec<_> = inner
            .pending_registrations
            .iter()
            .filter(|r| r.site_id == site_id && r.status == "PENDING")
            .cloned()
            .collect();
        list.sort_by(|a, b| b.submitted_at.cmp(&a.submitted_at));
        list
    }

    pub async fn approve_registration(
        &self,
        request_id: &str,
    ) -> Result<ApprovalResultResponse, String> {
        let mut inner = self.state.inner.write().await;
        let index = inner
            .pending_registrations
            .iter()
            .position(|r| r.request_id == request_id)
            .ok_or_else(|| format!("Registration request not found: {}", request_id))?;

        if inner.pending_registrations[index].status != "PENDING" {
            return Err(format!(
                "This application has already been processed: {}",
                inner.pending_registrations[index].status
            ));
        }

        let req = inner.pending_registrations[index].clone();
        let temp_pass = generate_resident_temporary_password();
        let password_hash = format!("argon2id_hash_placeholder:{}", &temp_pass);

        let user_id = format!("usr-resident-{}", &Uuid::new_v4().to_string()[..8]);
        let resident_user = User {
            id: user_id,
            site_id: req.site_id.clone(),
            full_name: req.full_name.clone(),
            email: req.email.clone(),
            phone: req.phone.clone(),
            password_hash: Some(password_hash),
            role: Role::HomeResident,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
        };
        inner.users.push(resident_user.clone());

        if let Some(ref pool) = self.state.pool {
            let pool = pool.clone();
            let u = resident_user.clone();
            tokio::spawn(async move {
                let _ = crate::db::save_user(&pool, &u).await;
            });
        }

        inner.pending_registrations[index].status = "APPROVED".to_string();

        let unit_id = format!("unit-{}", &Uuid::new_v4().to_string()[..8]);

        Ok(ApprovalResultResponse {
            request_id: request_id.to_string(),
            site_id: req.site_id,
            status: "APPROVED".to_string(),
            unit_id,
            email: req.email,
            temporary_password: temp_pass,
            approved_at: Utc::now(),
        })
    }

    pub async fn reject_registration(
        &self,
        request_id: &str,
    ) -> Result<PendingRegistrationResponse, String> {
        let mut inner = self.state.inner.write().await;
        let index = inner
            .pending_registrations
            .iter()
            .position(|r| r.request_id == request_id)
            .ok_or_else(|| format!("Registration request not found: {}", request_id))?;

        inner.pending_registrations[index].status = "REJECTED".to_string();
        Ok(inner.pending_registrations[index].clone())
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
