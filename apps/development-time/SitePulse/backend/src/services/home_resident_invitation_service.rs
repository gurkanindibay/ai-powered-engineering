use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};
use uuid::Uuid;

use crate::models::{
    HomeResidentResponse, RegisterHomeResidentRequest, Role, UnitInviteLinkResponse,
    UnitMemberDto, User,
};
use crate::state::AppState;

pub struct HomeResidentInvitationService {
    state: AppState,
}

impl HomeResidentInvitationService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    pub async fn generate_unit_invite_link(
        &self,
        unit_id: &str,
        relationship: Option<String>,
    ) -> UnitInviteLinkResponse {
        let inner = self.state.inner.read().await;
        let unit = inner.units.iter().find(|u| u.id == unit_id);
        let site_slug = unit
            .as_ref()
            .and_then(|u| inner.sites.iter().find(|s| s.id == u.site_id))
            .map(|s| s.slug.clone())
            .unwrap_or_else(|| "site".to_string());

        let building = unit
            .map(|u| format!("{} Blok", u.block_id))
            .unwrap_or_else(|| "Bağımsız Bölüm".to_string());
        let unit_number = unit
            .map(|u| u.unit_number.to_string())
            .unwrap_or_else(|| unit_id.to_string());

        let token_part: String = rand::thread_rng()
            .sample_iter(&Alphanumeric)
            .take(6)
            .map(char::from)
            .collect();
        let token = format!("SP-HANE-{}", token_part.to_uppercase());
        let invite_url = format!(
            "https://sitepulse.app/join/{}/units/{}?token={}",
            site_slug, unit_id, token
        );
        let expires_at = Utc::now() + chrono::Days::new(7);

        let rel = relationship
            .filter(|r| !r.trim().is_empty())
            .unwrap_or_else(|| "Aile Üyesi / Sakin".to_string());
        let security_notice = format!(
            "Bu link sadece {} D:{} yetkisi tanımlar. Başka daire bilgilerine veya yönetim fonksiyonlarına erişemez.",
            building, unit_number
        );

        let response = UnitInviteLinkResponse {
            invite_url,
            token: token.clone(),
            unit_id: unit_id.to_string(),
            building,
            unit_number,
            relationship: rel,
            expires_at,
            security_notice,
        };

        drop(inner);
        let mut inner_write = self.state.inner.write().await;
        inner_write
            .unit_invite_tokens
            .insert(token, response.clone());
        drop(inner_write);

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_invitation_token(pool, &response).await;
        }

        response
    }

    pub async fn register_home_resident(
        &self,
        request: RegisterHomeResidentRequest,
    ) -> Result<HomeResidentResponse, String> {
        if request.token.trim().is_empty() {
            return Err("Invitation token is required".to_string());
        }
        if request.full_name.trim().is_empty() {
            return Err("Full name is required".to_string());
        }
        if request.email.trim().is_empty() {
            return Err("Email is required".to_string());
        }

        let mut inner = self.state.inner.write().await;
        let email_norm = request.email.trim().to_lowercase();

        if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
            return Err(format!(
                "An account with this email address already exists (zaten mevcut): {}",
                request.email
            ));
        }

        let token_info = inner.unit_invite_tokens.get(&request.token);
        let unit_id = token_info
            .map(|t| t.unit_id.clone())
            .unwrap_or_else(|| "d-14".to_string());
        let relationship = request
            .relationship
            .or_else(|| token_info.map(|t| t.relationship.clone()))
            .unwrap_or_else(|| "Sakin / Aile Üyesi".to_string());

        let resident_id = format!("usr-res-{}", &Uuid::new_v4().to_string()[..8]);
        let temp_pass = generate_temporary_password();

        let resident_user = User {
            id: resident_id.clone(),
            site_id: "site-1".to_string(),
            full_name: request.full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone().unwrap_or_else(|| "-".to_string()),
            password_hash: Some(format!("HASH_{}", &temp_pass)),
            role: Role::HomeResident,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
        };
        inner.users.push(resident_user.clone());

        let member_dto = UnitMemberDto {
            resident_id: resident_id.clone(),
            full_name: request.full_name.clone(),
            relationship,
            phone: request.phone.clone().unwrap_or_else(|| "-".to_string()),
            email: email_norm.clone(),
            is_owner: false,
        };

        inner
            .unit_members
            .entry(unit_id.clone())
            .or_default()
            .push(member_dto.clone());

        drop(inner);

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_user(pool, &resident_user).await;
            let _ = crate::db::save_unit_member(pool, &unit_id, &member_dto).await;
        }

        Ok(HomeResidentResponse {
            resident_id,
            full_name: request.full_name,
            email: email_norm,
            phone: request.phone,
            unit_id: unit_id.clone(),
            role: "HOME_RESIDENT".to_string(),
            temporary_password: temp_pass,
            permission_scope: format!("UNIT_ONLY ({})", unit_id),
            created_at: Utc::now(),
        })
    }

    pub async fn get_unit_members(&self, unit_id: &str) -> Vec<UnitMemberDto> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(rows) = client
                    .query(
                        "SELECT resident_id, full_name, relationship, phone, email, is_owner FROM unit_members WHERE unit_id = $1 ORDER BY id ASC",
                        &[&unit_id],
                    )
                    .await
                {
                    if !rows.is_empty() {
                        return rows
                            .into_iter()
                            .map(|r| UnitMemberDto {
                                resident_id: r.get(0),
                                full_name: r.get(1),
                                relationship: r.get(2),
                                phone: r.get::<_, Option<String>>(3).unwrap_or_default(),
                                email: r.get::<_, Option<String>>(4).unwrap_or_default(),
                                is_owner: r.get(5),
                            })
                            .collect();
                    }
                }
            }
        }

        let inner = self.state.inner.read().await;
        inner.unit_members.get(unit_id).cloned().unwrap_or_default()
    }
}

fn generate_temporary_password() -> String {
    let part: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(4)
        .map(char::from)
        .collect();
    format!("SP-HANE-{}", part.to_uppercase())
}
