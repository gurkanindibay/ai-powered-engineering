use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};

use crate::models::{
    AuthProvider, HomeResidentResponse, RegisterHomeResidentRequest, Role, UnitInviteLinkResponse,
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
            .take(24)
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
        // Only a digest of the token is kept, in memory and in PostgreSQL.
        let mut stored = response.clone();
        stored.token = crate::auth::token_digest(&token);
        stored.invite_url = String::new();
        let mut inner_write = self.state.inner.write().await;
        inner_write.unit_invite_tokens.insert(stored.token.clone(), stored.clone());
        drop(inner_write);

        if let Some(ref pool) = self.state.pool {
            if let Err(e) = crate::db::save_invitation_token(pool, &stored).await {
                tracing::error!("Failed to persist invitation token: {}", e);
            }
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

        let digest = crate::auth::token_digest(request.token.trim());
        let token_info = inner
            .unit_invite_tokens
            .get(&digest)
            .cloned()
            .ok_or_else(|| "Invitation token is invalid or has already been used.".to_string())?;
        if token_info.expires_at < Utc::now() {
            inner.unit_invite_tokens.remove(&digest);
            return Err("Invitation token has expired.".to_string());
        }
        let unit_id = token_info.unit_id.clone();
        let site_id = inner
            .units
            .iter()
            .find(|u| crate::auth::same_id(&u.id, &unit_id))
            .map(|u| u.site_id.clone())
            .ok_or_else(|| "The invited unit no longer exists.".to_string())?;
        inner.unit_invite_tokens.remove(&digest);
        let relationship = request
            .relationship
            .unwrap_or_else(|| token_info.relationship.clone());

        let max_user = inner
            .users
            .iter()
            .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
            .max()
            .unwrap_or(0);
        let resident_id = (max_user + 1).to_string();
        let temp_pass = generate_temporary_password();

        let resident_user = User {
            id: resident_id.clone(),
            site_id,
            full_name: request.full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone().unwrap_or_else(|| "-".to_string()),
            password_hash: Some(crate::auth::hash_password(&temp_pass)),
            role: Role::HomeResident,
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: None,
        };
        inner.users.push(resident_user.clone());

        let member_dto = UnitMemberDto {
            resident_id: resident_id.clone(),
            full_name: request.full_name.clone(),
            relationship,
            phone: request.phone.clone().unwrap_or_else(|| "-".to_string()),
            email: email_norm.clone(),
            is_owner: false,
            occupancy_id: None,
            person_id: None,
            resident_user_id: None,
        };

        inner
            .unit_members
            .entry(unit_id.clone())
            .or_default()
            .push(member_dto.clone());

        drop(inner);

        let mut final_resident_id = resident_id.clone();
        if let Some(ref pool) = self.state.pool {
            crate::db::delete_invitation_token(pool, &digest).await.map_err(|e| e.to_string())?;
            crate::db::save_user(pool, &resident_user).await.map_err(|e| format!("Failed to persist resident: {}", e))?;
            if let Ok(client) = pool.get().await {
                if let Ok(Some(row)) = client.query_opt("SELECT id FROM users WHERE LOWER(email) = $1", &[&email_norm]).await {
                    let db_id: i64 = row.get("id");
                    final_resident_id = db_id.to_string();
                }
            }
            crate::db::save_unit_member(
                pool,
                &unit_id,
                &member_dto.full_name,
                &member_dto.relationship,
                &member_dto.phone,
                &member_dto.email,
            )
            .await
            .map_err(|e| format!("Failed to persist household member: {}", e))?;
        }

        Ok(HomeResidentResponse {
            resident_id: final_resident_id,
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
                if let Some(rows) = crate::db::logged(client
                    .query(
                        r#"
                        SELECT om.id, om.full_name, om.relationship, om.phone, om.email,
                               (uo.occupancy_type = 'OWNER'), om.occupancy_id, om.person_id, om.resident_user_id
                        FROM occupancy_members om
                        JOIN unit_occupancies uo ON om.occupancy_id = uo.id
                        WHERE uo.unit_id = $1 AND uo.is_active = true
                        ORDER BY om.id ASC
                        "#,
                        &[&crate::db::parse_id_to_i64(unit_id).unwrap_or(0)],
                    )
                    .await, "home_resident_invitation_service") {
                    if !rows.is_empty() {
                        return rows
                            .into_iter()
                            .map(|r| UnitMemberDto {
                                resident_id: r.get::<_, i64>(0).to_string(),
                                full_name: r.get(1),
                                relationship: r.get(2),
                                phone: r.get::<_, Option<String>>(3).unwrap_or_default(),
                                email: r.get::<_, Option<String>>(4).unwrap_or_default(),
                                is_owner: r.get(5),
                                occupancy_id: r.try_get(6).ok().flatten(),
                                person_id: r.try_get(7).ok().flatten(),
                                resident_user_id: r.try_get(8).ok().flatten(),
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
    crate::auth::generate_temporary_password("SP-HANE-")
}
