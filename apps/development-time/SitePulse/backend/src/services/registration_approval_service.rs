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
        drop(inner);

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::save_pending_registration(pool, &item).await;
        }

        Ok(item)
    }

    pub async fn get_pending_registrations(&self, site_id: &str) -> Vec<PendingRegistrationResponse> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(rows) = client
                    .query(
                        "SELECT request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at FROM pending_registrations WHERE site_id = $1 AND status = 'PENDING' ORDER BY submitted_at DESC",
                        &[&crate::db::parse_id_to_i64(site_id).unwrap_or(1)],
                    )
                    .await
                {
                    if !rows.is_empty() {
                        return rows
                            .into_iter()
                            .map(|row| PendingRegistrationResponse {
                                request_id: row.get(0),
                                site_id: row.get::<_, i64>(1).to_string(),
                                block: row.get(2),
                                unit_no: row.get(3),
                                floor: row.get(4),
                                full_name: row.get(5),
                                email: row.get(6),
                                phone: row.get(7),
                                is_resident: row.get(8),
                                status: row.get(9),
                                submitted_at: row.get::<_, Option<chrono::DateTime<chrono::Utc>>>(10).unwrap_or_else(chrono::Utc::now),
                            })
                            .collect();
                    }
                }
            }
        }

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
        inner.pending_registrations[index].status = "APPROVED".to_string();
        drop(inner); // drop write lock before doing DB operations

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::update_pending_registration_status(pool, request_id, "APPROVED").await;
        }

        let temp_pass = generate_resident_temporary_password();
        let password_hash = format!("argon2id_hash_placeholder:{}", &temp_pass);

        let clean_block = req
            .block
            .to_uppercase()
            .replace("BLOK", "")
            .replace(['-', '_', ' '], "")
            .trim()
            .to_string();
        let effective_clean_block = if clean_block.is_empty() {
            "A".to_string()
        } else {
            clean_block
        };
        let formatted_block_name = format!("{} Blok", effective_clean_block);

        let effective_floor = if req.floor > 0 {
            req.floor
        } else {
            ((req.unit_no - 1) / 4) + 1
        };

        let site_numeric_id = crate::db::parse_id_to_i64(&req.site_id).unwrap_or(1);
        let viban = crate::services::virtual_iban_service::VirtualIbanService::generate_virtual_iban(
            crate::services::virtual_iban_service::VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_numeric_id.to_string(),
            &format!("blok-{}", effective_clean_block),
            req.unit_no,
        );

        let mut user_numeric_id = 0i64;
        #[allow(unused_assignments)]
        let mut person_numeric_id = 0i64;
        let mut block_numeric_id = 1i64;
        let mut unit_numeric_id = 0i64;

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                // Find or create block
                let existing_block = client
                    .query_opt(
                        "SELECT id FROM blocks WHERE site_id = $1 AND (block_name ILIKE $2 OR block_name ILIKE $3)",
                        &[&site_numeric_id, &formatted_block_name, &effective_clean_block],
                    )
                    .await
                    .ok()
                    .flatten();

                block_numeric_id = if let Some(row) = existing_block {
                    row.get(0)
                } else if let Ok(row) = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id",
                        &[&site_numeric_id, &formatted_block_name],
                    )
                    .await
                {
                    row.get(0)
                } else {
                    1
                };

                // Find or create person
                let person_type = if req.is_resident { "HOME_RESIDENT" } else { "HOME_OWNER" };
                let existing_person = client
                    .query_opt("SELECT id FROM persons WHERE LOWER(email) = $1", &[&req.email])
                    .await
                    .ok()
                    .flatten();

                person_numeric_id = if let Some(row) = existing_person {
                    row.get(0)
                } else if let Ok(row) = client
                    .query_one(
                        "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, $4) RETURNING id",
                        &[&req.full_name, &req.phone, &req.email, &person_type],
                    )
                    .await
                {
                    row.get(0)
                } else {
                    0
                };

                // Insert user
                let user_role_str = "HOME_RESIDENT";
                let person_id_opt: Option<i64> = if person_numeric_id > 0 { Some(person_numeric_id) } else { None };
                if let Ok(user_row) = client
                    .query_one(
                        r#"
                        INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                        VALUES ($1, $2, $3, $4, $5, TRUE)
                        RETURNING id
                        "#,
                        &[
                            &site_numeric_id,
                            &person_id_opt,
                            &req.email,
                            &password_hash,
                            &user_role_str,
                        ],
                    )
                    .await
                {
                    user_numeric_id = user_row.get(0);
                }

                // Insert unit
                if let Ok(unit_row) = client
                    .query_one(
                        r#"
                        INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, virtual_iban)
                        VALUES ($1, $2, $3, $4, 1, $5, $6)
                        ON CONFLICT (block_id, unit_number) DO UPDATE SET
                            site_id = EXCLUDED.site_id,
                            floor = EXCLUDED.floor,
                            owner_person_id = EXCLUDED.owner_person_id,
                            virtual_iban = EXCLUDED.virtual_iban
                        RETURNING id
                        "#,
                        &[
                            &block_numeric_id,
                            &site_numeric_id,
                            &req.unit_no,
                            &effective_floor,
                            &person_numeric_id,
                            &viban,
                        ],
                    )
                    .await
                {
                    unit_numeric_id = unit_row.get(0);
                }
            }
        }

        let mut inner = self.state.inner.write().await;

        let user_id = if user_numeric_id > 0 {
            user_numeric_id.to_string()
        } else {
            format!("usr-resident-{}", &Uuid::new_v4().to_string()[..8])
        };

        let resident_user = User {
            id: user_id.clone(),
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
            person_id: if person_numeric_id > 0 { Some(person_numeric_id) } else { None },
        };
        inner.users.push(resident_user.clone());

        let unit_id = if unit_numeric_id > 0 {
            unit_numeric_id.to_string()
        } else {
            format!("unit-{}", req.unit_no)
        };

        let block_id_str = if block_numeric_id > 0 {
            block_numeric_id.to_string()
        } else {
            format!("blok-{}", effective_clean_block)
        };

        let unit = crate::models::IndependentUnit {
            id: unit_id.clone(),
            site_id: req.site_id.clone(),
            block_id: block_id_str,
            unit_number: req.unit_no,
            floor: effective_floor,
            land_share: 1,
            owner_user_id: Some(user_id.clone()),
            tenant_user_id: None,
            virtual_iban: Some(viban),
            house_type: Some("2+1".to_string()),
        };

        if let Some(pos) = inner
            .units
            .iter()
            .position(|u| u.id == unit.id || (u.site_id == unit.site_id && u.unit_number == unit.unit_number))
        {
            inner.units[pos] = unit.clone();
        } else {
            inner.units.push(unit.clone());
        }

        let legacy_unit_id = format!("d-{}", req.unit_no);
        if !inner.units.iter().any(|u| u.id == legacy_unit_id) {
            let mut leg = unit.clone();
            leg.id = legacy_unit_id.clone();
            inner.units.push(leg);
        }

        inner
            .unit_payer_names
            .entry(unit.id.clone())
            .or_default()
            .push(req.full_name.clone());
        inner
            .unit_payer_names
            .entry(legacy_unit_id)
            .or_default()
            .push(req.full_name.clone());

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
        let result = inner.pending_registrations[index].clone();
        drop(inner);

        if let Some(ref pool) = self.state.pool {
            let _ = crate::db::update_pending_registration_status(pool, request_id, "REJECTED").await;
        }

        Ok(result)
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
