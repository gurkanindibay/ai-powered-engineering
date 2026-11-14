use chrono::Utc;
use rand::{distributions::Alphanumeric, Rng};

use crate::models::{
    ApprovalResultResponse, AuthProvider, PendingRegistrationResponse, RegistrationStatus, Role,
    SiteInvitationLinkResponse, SubmitSelfRegistrationRequest, User,
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
        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);

        if inner
            .users
            .iter()
            .any(|u| crate::domain::email::same_email(&u.email, &email_norm))
        {
            return Err(format!(
                "An account with this email address already exists (zaten mevcut): {}",
                request.email
            ));
        }

        let max_req = inner
            .pending_registrations
            .iter()
            .filter_map(|r| crate::db::parse_id_to_i64(&r.request_id))
            .max()
            .unwrap_or(0);
        let request_id = (max_req + 1).to_string();
        let site_id = inner
            .sites
            .iter()
            .find(|s| s.slug == slug)
            .map(|s| s.id.clone())
            .unwrap_or_default();

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
            status: RegistrationStatus::Pending,
            submitted_at: Utc::now(),
        };

        inner.pending_registrations.push(item.clone());
        drop(inner);

        if let Some(ref pool) = self.state.pool {
            crate::db::save_pending_registration(pool, &item)
                .await
                .map_err(|e| e.to_string())?;
        }

        Ok(item)
    }

    pub async fn get_pending_registrations(
        &self,
        site_id: &str,
    ) -> Vec<PendingRegistrationResponse> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(rows) = crate::db::logged(client
                    .query(
                        "SELECT request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at FROM pending_registrations WHERE site_id = $1 AND status = 'PENDING' ORDER BY submitted_at DESC",
                        &[&crate::db::parse_id_to_i64(site_id).unwrap_or(0)],
                    )
                    .await, "registration_approval_service") {
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

        let inner = self.state.inner.read().await;
        let mut list: Vec<_> = inner
            .pending_registrations
            .iter()
            .filter(|r| r.site_id == site_id && r.status == RegistrationStatus::Pending)
            .cloned()
            .collect();
        list.sort_by_key(|r| std::cmp::Reverse(r.submitted_at));
        list
    }

    /// Perform scoped registration review atomically.
    ///
    /// # Errors
    /// Rejects unauthorized scope, processed requests and unavailable storage.
    pub async fn approve_registration(
        &self,
        ctx: &crate::authorization::AuthzContext,
        request_id: &str,
    ) -> Result<ApprovalResultResponse, crate::authorization::SecurityError> {
        self.approve_registration_with(ctx, request_id, None).await
    }

    /// Approves a request, optionally linking it to an existing person card of the
    /// site instead of creating one.
    pub async fn approve_registration_with(
        &self,
        ctx: &crate::authorization::AuthzContext,
        request_id: &str,
        person_id: Option<i64>,
    ) -> Result<ApprovalResultResponse, crate::authorization::SecurityError> {
        use crate::authorization::SecurityError;
        ctx.require(
            crate::models::Permission::ResidentApprove,
            &ctx.claims.site_id,
        )?;
        let today = {
            let inner = self.state.inner.read().await;
            crate::services::finance_common::site_today(&inner, &ctx.claims.site_id)
        };
        let password = generate_resident_temporary_password();
        let hash = crate::auth::hash_password_async(password.clone())
            .await
            .map_err(|_| SecurityError::Unavailable)?;
        if let Some(mut client) = crate::db::security_connection(&self.state).await? {
            let tx = client
                .transaction()
                .await
                .map_err(|_| SecurityError::Unavailable)?;
            let site = crate::db::require_id("site", &ctx.claims.site_id)
                .map_err(|_| SecurityError::BadRequest)?;
            // Tenant guardrail (RLS, V21): other sites' rows are invisible from here on.
            crate::db::tx_bind_tenant(&tx, site)
                .await
                .map_err(|_| SecurityError::Unavailable)?;
            let row=tx.query_opt("SELECT block,unit_no,floor,full_name,email,phone,is_resident,status FROM pending_registrations WHERE request_id=$1 AND site_id=$2 FOR UPDATE",&[&request_id,&site]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::NotFound)?;
            if row.get::<_, String>(7) != "PENDING" {
                return Err(SecurityError::Conflict);
            }
            let block: String = row.get(0);
            let number: i32 = row.get(1);
            let floor: i32 = row.get(2);
            let name: String = row.get(3);
            let email: String = row.get(4);
            let phone: String = row.get(5);
            let resident: bool = row.get(6);
            let active=tx.query_opt("SELECT 1 FROM sites WHERE id=$1 AND status IN ('ACTIVE','TRIAL') AND deleted_at IS NULL FOR SHARE",&[&site]).await.map_err(|_|SecurityError::Unavailable)?.is_some();
            if !active {
                return Err(SecurityError::NotFound);
            }
            let block_row = tx
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id=$1 AND block_name=$2",
                    &[&site, &block],
                )
                .await
                .map_err(|_| SecurityError::Unavailable)?;
            let block_id: i64 = if let Some(row) = block_row {
                row.get(0)
            } else {
                tx.query_one("INSERT INTO blocks(site_id,block_name,total_floors) VALUES ($1,$2,10) RETURNING id",&[&site,&block]).await.map_err(|_|SecurityError::Unavailable)?.get(0)
            };
            let role = if resident {
                Role::HomeResident
            } else {
                Role::HomeOwner
            };
            let person = if let Some(chosen) = person_id {
                // Link the chosen card; it must belong to this site and have no login yet.
                let card = tx
                    .query_opt(
                        "SELECT id FROM persons WHERE id=$1 AND site_id=$2 AND deleted_at IS NULL AND merged_into_person_id IS NULL FOR UPDATE",
                        &[&chosen, &site],
                    )
                    .await
                    .map_err(|_| SecurityError::Unavailable)?
                    .ok_or(SecurityError::NotFound)?;
                let has_login = tx
                    .query_opt(
                        "SELECT 1 FROM users WHERE person_id=$1 AND is_active",
                        &[&chosen],
                    )
                    .await
                    .map_err(|_| SecurityError::Unavailable)?
                    .is_some();
                if has_login {
                    return Err(SecurityError::Conflict);
                }
                card.get::<_, i64>(0)
            } else {
                crate::db::person_repository::resolve_new_site_person(
                    &tx,
                    &name,
                    Some(&phone),
                    Some(&email),
                    role.as_str(),
                    site,
                    true,
                )
                .await
                .map_err(|_| SecurityError::Conflict)?
            };
            let user_id:i64=tx.query_one("INSERT INTO users(site_id,person_id,email,password_hash,role,must_change_password) VALUES ($1,$2,$3,$4,$5,true) RETURNING id",&[&site,&person,&email,&hash,&role.as_str()]).await.map_err(|_|SecurityError::Conflict)?.get(0);
            let existing=tx.query_opt("SELECT id FROM units WHERE block_id=$1 AND unit_number=$2 AND site_id=$3 FOR UPDATE",&[&block_id,&number,&site]).await.map_err(|_|SecurityError::Unavailable)?;
            let unit_id: i64 = if let Some(row) = existing {
                row.get(0)
            } else {
                tx.query_one("INSERT INTO units(block_id,site_id,unit_number,floor,land_share) VALUES ($1,$2,$3,$4,1) RETURNING id",&[&block_id,&site,&number,&floor]).await.map_err(|_|SecurityError::Unavailable)?.get(0)
            };
            tx.execute(
                "INSERT INTO user_site_roles(user_id,site_id,role) VALUES ($1,$2,$3)",
                &[&user_id, &site, &role.as_str()],
            )
            .await
            .map_err(|_| SecurityError::Unavailable)?;
            // STORY-08-07: an approval is a guarded transition. An owner is
            // registered only on a unit without one (T1, residing); a tenant
            // moves in only on a vacant unit with an owner (T2).
            approve_occupancy(&tx, site, unit_id, person, resident, today).await?;
            tx.execute("UPDATE pending_registrations SET status='APPROVED' WHERE request_id=$1 AND site_id=$2",&[&request_id,&site]).await.map_err(|_|SecurityError::Unavailable)?;
            tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
            let mut inner = self.state.inner.write().await;
            if let Some(item) = inner
                .pending_registrations
                .iter_mut()
                .find(|r| r.request_id == request_id)
            {
                item.status = RegistrationStatus::Approved;
            }
            return Ok(ApprovalResultResponse {
                request_id: request_id.to_string(),
                site_id: site.to_string(),
                status: RegistrationStatus::Approved,
                unit_id: unit_id.to_string(),
                email,
                temporary_password: password,
                approved_at: Utc::now(),
            });
        }
        // Demonstration storage applies the entire transition while holding one lock.
        let mut inner = self.state.inner.write().await;
        let index = inner
            .pending_registrations
            .iter()
            .position(|r| {
                r.request_id == request_id
                    && crate::authorization::same_site(&r.site_id, &ctx.claims.site_id)
            })
            .ok_or(SecurityError::NotFound)?;
        let req = inner.pending_registrations[index].clone();
        if req.status != RegistrationStatus::Pending {
            return Err(SecurityError::Conflict);
        }
        let role = if req.is_resident {
            Role::HomeResident
        } else {
            Role::HomeOwner
        };
        let id = uuid::Uuid::new_v4().to_string();
        let unit_id = inner
            .units
            .iter()
            .find(|u| {
                crate::authorization::same_site(&u.site_id, &req.site_id)
                    && u.unit_number == req.unit_no
            })
            .map(|u| u.id.clone())
            .unwrap_or_else(|| {
                (inner
                    .units
                    .iter()
                    .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                    .max()
                    .unwrap_or(0)
                    + 1)
                .to_string()
            });
        inner.users.push(User {
            id: id.clone(),
            site_id: req.site_id.clone(),
            full_name: req.full_name.clone(),
            email: req.email.clone(),
            phone: req.phone.clone(),
            password_hash: Some(hash),
            role,
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: None,
        });
        if let Some(u) = inner.units.iter_mut().find(|u| u.id == unit_id) {
            if req.is_resident {
                u.tenant_user_id = Some(id);
            } else {
                u.owner_user_id = Some(id);
            }
        } else {
            inner.units.push(crate::models::IndependentUnit {
                id: unit_id.clone(),
                site_id: req.site_id.clone(),
                block_id: req.block.clone(),
                unit_number: req.unit_no,
                floor: req.floor,
                land_share: 1,
                owner_user_id: if req.is_resident {
                    None
                } else {
                    Some(id.clone())
                },
                tenant_user_id: if req.is_resident { Some(id) } else { None },
                virtual_iban: None,
                house_type: None,
            });
        }
        inner.pending_registrations[index].status = RegistrationStatus::Approved;
        Ok(ApprovalResultResponse {
            request_id: request_id.to_string(),
            site_id: req.site_id,
            status: RegistrationStatus::Approved,
            unit_id,
            email: req.email,
            temporary_password: password,
            approved_at: Utc::now(),
        })
    }

    /// Perform scoped registration review atomically.
    ///
    /// # Errors
    /// Rejects unauthorized scope, processed requests and unavailable storage.
    pub async fn reject_registration(
        &self,
        ctx: &crate::authorization::AuthzContext,
        request_id: &str,
    ) -> Result<PendingRegistrationResponse, crate::authorization::SecurityError> {
        use crate::authorization::SecurityError;
        ctx.require(
            crate::models::Permission::ResidentApprove,
            &ctx.claims.site_id,
        )?;
        if let Some(mut client) = crate::db::security_connection(&self.state).await? {
            let tx = client
                .transaction()
                .await
                .map_err(|_| SecurityError::Unavailable)?;
            let site = crate::db::require_id("site", &ctx.claims.site_id)
                .map_err(|_| SecurityError::BadRequest)?;
            // Tenant guardrail (RLS, V21): other sites' rows are invisible from here on.
            crate::db::tx_bind_tenant(&tx, site)
                .await
                .map_err(|_| SecurityError::Unavailable)?;
            let row=tx.query_opt("UPDATE pending_registrations SET status='REJECTED' WHERE request_id=$1 AND site_id=$2 AND status='PENDING' RETURNING block,unit_no,floor,full_name,email,phone,is_resident,submitted_at",&[&request_id,&site]).await.map_err(|_|SecurityError::Unavailable)?.ok_or(SecurityError::NotFound)?;
            let result = PendingRegistrationResponse {
                request_id: request_id.to_string(),
                site_id: site.to_string(),
                block: row.get(0),
                unit_no: row.get(1),
                floor: row.get(2),
                full_name: row.get(3),
                email: row.get(4),
                phone: row.get(5),
                is_resident: row.get(6),
                status: RegistrationStatus::Rejected,
                submitted_at: row.get(7),
            };
            tx.commit().await.map_err(|_| SecurityError::Unavailable)?;
            if let Some(r) = self
                .state
                .inner
                .write()
                .await
                .pending_registrations
                .iter_mut()
                .find(|r| r.request_id == request_id)
            {
                r.status = RegistrationStatus::Rejected;
            }
            return Ok(result);
        }
        let mut inner = self.state.inner.write().await;
        let req = inner
            .pending_registrations
            .iter_mut()
            .find(|r| {
                r.request_id == request_id
                    && crate::authorization::same_site(&r.site_id, &ctx.claims.site_id)
            })
            .ok_or(SecurityError::NotFound)?;
        if req.status != RegistrationStatus::Pending {
            return Err(SecurityError::Conflict);
        }
        req.status = RegistrationStatus::Rejected;
        Ok(req.clone())
    }
}

fn generate_resident_temporary_password() -> String {
    crate::auth::generate_temporary_password("SP-RESIDENT-")
}

/// Applies the occupancy effect of an approved registration (T1 or T2), or
/// refuses it with a conflict when the unit's state does not allow it.
async fn approve_occupancy(
    tx: &deadpool_postgres::Transaction<'_>,
    site: i64,
    unit: i64,
    person: i64,
    tenant: bool,
    today: chrono::NaiveDate,
) -> Result<(), crate::authorization::SecurityError> {
    use crate::authorization::SecurityError;
    use crate::db::occupancy_repository::{self as repo, OccupancyError, TransitionInput};
    use crate::domain::unit_state::{self, Command};

    let refuse = |e: OccupancyError| match e {
        OccupancyError::Storage(detail) => {
            tracing::error!(error = %detail, "Registration approval occupancy storage failure");
            SecurityError::Unavailable
        }
        other => {
            tracing::warn!(unit_id = unit, reason = %other, "Registration approval refused by unit state");
            SecurityError::Conflict
        }
    };
    let input = TransitionInput {
        effective_date: today,
        today,
        tenant_person_id: tenant.then_some(person),
        owner_person_id: (!tenant).then_some(person),
        new_owner_person_id: None,
        notes: None,
    };
    if tenant {
        repo::apply_occupancy_command(tx, site, unit, Command::TenantMoveIn, &input)
            .await
            .map_err(refuse)?;
        return Ok(());
    }
    let snapshot = repo::lock_unit_snapshot(tx, site, unit)
        .await
        .map_err(refuse)?;
    let plan = unit_state::plan(snapshot.state, Command::RegisterOwner { resides: true })
        .map_err(|e| refuse(e.into()))?;
    tx.execute(
        "INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) VALUES ($1, $2, 100.00, $3, TRUE)",
        &[&unit, &person, &today],
    )
    .await
    .map_err(|_| SecurityError::Unavailable)?;
    repo::execute_plan(tx, &snapshot, plan, Some(person), &input)
        .await
        .map_err(refuse)?;
    Ok(())
}
