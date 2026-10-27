use chrono::{DateTime, Datelike, Utc};
use rand::{distributions::Alphanumeric, Rng};
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{
    DebtStatus, DuesLiability, HomeOwnerResponse, IndependentUnit, RegisterHomeOwnerRequest, Role,
    User,
};
use crate::services::virtual_iban_service::VirtualIbanService;
use crate::state::AppState;

pub struct SiteAdminService {
    state: AppState,
}

pub fn validate_email(email: &str) -> Result<(), String> {
    let email = email.trim();
    if email.is_empty() {
        return Err("E-posta adresi boş bırakılamaz.".to_string());
    }
    let parts: Vec<&str> = email.split('@').collect();
    if parts.len() != 2 || parts[0].is_empty() || parts[1].is_empty() {
        return Err("Geçerli bir e-posta adresi giriniz (örn: sakin@sitepulse.io).".to_string());
    }
    let domain = parts[1];
    if !domain.contains('.') || domain.starts_with('.') || domain.ends_with('.') {
        return Err("Geçerli bir e-posta adresi giriniz (örn: sakin@sitepulse.io).".to_string());
    }
    let domain_parts: Vec<&str> = domain.split('.').collect();
    if domain_parts.iter().any(|p| p.is_empty()) || domain_parts.last().map(|tld| tld.len()).unwrap_or(0) < 2 {
        return Err("Geçerli bir e-posta adresi giriniz (örn: sakin@sitepulse.io).".to_string());
    }
    if email.contains(' ') || email.contains('\t') || email.contains('\n') {
        return Err("E-posta adresi boşluk içeremez.".to_string());
    }
    Ok(())
}

pub fn validate_phone(phone: &str) -> Result<(), String> {
    let phone_trimmed = phone.trim();
    if phone_trimmed.is_empty() {
        return Err("Telefon numarası boş bırakılamaz.".to_string());
    }
    let clean: String = phone_trimmed.chars().filter(|c| c.is_ascii_digit()).collect();
    if clean.is_empty() {
        return Err("Telefon numarası geçerli rakamlar içermelidir.".to_string());
    }
    let is_valid = (clean.len() == 10 && clean.starts_with('5'))
        || (clean.len() == 11 && clean.starts_with("05"))
        || (clean.len() == 12 && clean.starts_with("905"))
        || (clean.len() >= 10 && clean.len() <= 13);

    if !is_valid {
        return Err("Geçerli bir cep telefonu numarası giriniz (örn: 05XX XXX XX XX).".to_string());
    }
    Ok(())
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
        if request.block.trim().is_empty() {
            return Err("Block name cannot be empty".to_string());
        }

        // Validate email & phone
        validate_email(&request.email)?;
        validate_phone(&request.phone)?;

        let email_norm = request.email.trim().to_lowercase();

        // 1. Check in-memory state for duplicate email first
        {
            let inner = self.state.inner.read().await;
            if inner.users.iter().any(|u| u.email.to_lowercase() == email_norm) {
                return Err(format!(
                    "An account with this email address already exists (zaten mevcut): {}",
                    request.email
                ));
            }
        }

        let clean_block = request
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

        let temp_pass = generate_resident_temporary_password();
        let password_hash = format!("argon2id_hash_placeholder:{}", &temp_pass);

        let effective_floor = if request.floor > 0 {
            request.floor
        } else {
            ((request.unit_no - 1) / 4) + 1
        };

        let effective_house_type = request.house_type.clone().or_else(|| Some("2+1".to_string()));
        let mut resolved_dues = request.monthly_dues;

        // Resolve monthly dues from house_type tariff
        if let Some(ref ht_name) = effective_house_type {
            let inner = self.state.inner.read().await;
            if let Some(tariff) = inner.house_types.iter().find(|t| {
                (t.site_id == site_id || crate::db::parse_id_to_i64(&t.site_id) == crate::db::parse_id_to_i64(site_id))
                    && t.type_name.eq_ignore_ascii_case(ht_name)
            }) {
                resolved_dues = Some(tariff.dues_amount);
            }
        }
        let monthly_dues = resolved_dues.unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());

        // Parse numeric IDs
        let site_numeric_id = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let viban = VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_numeric_id.to_string(),
            &format!("blok-{}", effective_clean_block),
            request.unit_no,
        );

        let mut user_numeric_id = 0i64;
        #[allow(unused_assignments)]
        let mut person_numeric_id = 0i64;
        let mut block_numeric_id = 1i64;
        let mut unit_numeric_id = 0i64;
        let req_role = request.role.as_deref().unwrap_or("OWNER").to_uppercase();
        let is_tenant = req_role == "TENANT";
        let is_resident_only = req_role == "RESIDENT";
        let has_explicit_tenant = request
            .tenant_full_name
            .as_ref()
            .map(|s| !s.trim().is_empty())
            .unwrap_or(false);

        // 2. Persist to PostgreSQL if pool is available
        if let Some(ref pool) = self.state.pool {
            let client = pool.get().await.map_err(|e| format!("DB connection error: {}", e))?;

            // Check duplicate email in DB
            let existing_user = client
                .query_opt("SELECT id FROM users WHERE LOWER(email) = $1", &[&email_norm])
                .await
                .map_err(|e| format!("DB query error: {}", e))?;
            if existing_user.is_some() {
                return Err(format!(
                    "An account with this email address already exists (zaten mevcut): {}",
                    request.email
                ));
            }

            // Find or create block
            let existing_block = client
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id = $1 AND (block_name ILIKE $2 OR block_name ILIKE $3)",
                    &[&site_numeric_id, &formatted_block_name, &effective_clean_block],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            block_numeric_id = if let Some(row) = existing_block {
                row.get(0)
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id",
                        &[&site_numeric_id, &formatted_block_name],
                    )
                    .await
                    .map_err(|e| format!("Failed to insert block: {}", e))?;
                row.get(0)
            };

            // Find or create person
            let person_type = if request.is_resident { "KAT_SAKINI" } else { "KAT_MALIKI" };
            let existing_person = client
                .query_opt("SELECT id FROM persons WHERE LOWER(email) = $1", &[&email_norm])
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            person_numeric_id = if let Some(row) = existing_person {
                row.get(0)
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, $4) RETURNING id",
                        &[&request.owner_full_name, &request.phone, &email_norm, &person_type],
                    )
                    .await
                    .map_err(|e| format!("Failed to insert person: {}", e))?;
                row.get(0)
            };

            // Insert user
            let user_role_str = "HOME_RESIDENT";
            let user_row = client
                .query_one(
                    r#"
                    INSERT INTO users (site_id, full_name, email, phone, password_hash, role, must_change_password)
                    VALUES ($1, $2, $3, $4, $5, $6, TRUE)
                    RETURNING id
                    "#,
                    &[
                        &site_numeric_id,
                        &request.owner_full_name,
                        &email_norm,
                        &request.phone,
                        &password_hash,
                        &user_role_str,
                    ],
                )
                .await
                .map_err(|e| format!("Failed to insert user: {}", e))?;
            user_numeric_id = user_row.get(0);

            // Handle optional explicit tenant when registered together with owner
            let mut explicit_tenant_person_id: Option<i64> = None;

            if has_explicit_tenant {
                let t_name = request.tenant_full_name.as_deref().unwrap_or("").trim();
                let t_phone = request.tenant_phone.as_deref().unwrap_or("").trim();
                let t_email_norm = request.tenant_email.as_deref().unwrap_or("").trim().to_lowercase();

                let existing_t_person = if !t_email_norm.is_empty() {
                    client.query_opt("SELECT id FROM persons WHERE LOWER(email) = $1", &[&t_email_norm]).await.ok().flatten()
                } else {
                    None
                };

                let t_pid: i64 = if let Some(row) = existing_t_person {
                    row.get(0)
                } else {
                    let row = client
                        .query_one(
                            "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, 'KAT_SAKINI') RETURNING id",
                            &[&t_name, &t_phone, &t_email_norm],
                        )
                        .await
                        .map_err(|e| format!("Failed to insert tenant person: {}", e))?;
                    row.get(0)
                };
                explicit_tenant_person_id = Some(t_pid);

                if !t_email_norm.is_empty() {
                    let existing_t_user = client.query_opt("SELECT id FROM users WHERE LOWER(email) = $1", &[&t_email_norm]).await.ok().flatten();
                    if existing_t_user.is_none() {
                        let _ = client
                            .execute(
                                r#"
                                INSERT INTO users (site_id, full_name, email, phone, password_hash, role, must_change_password)
                                VALUES ($1, $2, $3, $4, $5, 'HOME_RESIDENT', TRUE)
                                "#,
                                &[&site_numeric_id, &t_name, &t_email_norm, &t_phone, &password_hash],
                            )
                            .await;
                    }
                }
            }

            // Check if unit already exists
            let existing_unit_opt = client
                .query_opt(
                    "SELECT id, owner_person_id, tenant_person_id, occupancy_status FROM units WHERE block_id = $1 AND unit_number = $2",
                    &[&block_numeric_id, &request.unit_no],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            if let Some(existing_unit) = existing_unit_opt {
                unit_numeric_id = existing_unit.get("id");
                let prev_owner: Option<i64> = existing_unit.get("owner_person_id");
                let prev_tenant: Option<i64> = existing_unit.get("tenant_person_id");

                if is_resident_only {
                    let _ = client
                        .execute(
                            r#"
                            INSERT INTO unit_members (unit_id, resident_id, full_name, relationship, phone, email, is_owner, created_at)
                            VALUES ($1, $2, $3, 'Ev Sakini', $4, $5, false, CURRENT_TIMESTAMP)
                            "#,
                            &[
                                &unit_numeric_id.to_string(),
                                &user_numeric_id.to_string(),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await;
                } else {
                    // Check active occupancy in unit_occupancies
                    let active_occ_row = client
                        .query_opt(
                            "SELECT id FROM unit_occupancies WHERE unit_id = $1 AND is_active = true",
                            &[&unit_numeric_id],
                        )
                        .await
                        .ok()
                        .flatten();

                    if let Some(occ_row) = active_occ_row {
                        let occ_id: i64 = occ_row.get(0);
                        let _ = client
                            .execute(
                                "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE, notes = COALESCE(notes, '') || ' • Ayrıldı (Yeni sakin devri)' WHERE id = $1",
                                &[&occ_id],
                            )
                            .await;
                    } else if let Some(prev_pid) = prev_tenant.or(prev_owner) {
                        // Legacy occupant was not in unit_occupancies; archive it now so history is preserved
                        let prev_role = if prev_tenant.is_some() { "TENANT" } else { "OWNER" };
                        let _ = client
                            .execute(
                                r#"
                                INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, end_date, is_active, exit_balance, notes)
                                VALUES ($1, $2, $3, CURRENT_DATE - INTERVAL '6 months', CURRENT_DATE, false, 0.00, 'Önceki sakin (Yeni kayıt ile devredildi)')
                                "#,
                                &[&unit_numeric_id, &prev_pid, &prev_role],
                            )
                            .await;
                    }

                    // Insert new occupant into unit_occupancies
                    let new_occ_type = if has_explicit_tenant || is_tenant { "TENANT" } else { "OWNER" };
                    let new_occ_status = if has_explicit_tenant || is_tenant { "TENANT_OCCUPIED" } else if request.is_resident { "OWNER_OCCUPIED" } else { "VACANT" };
                    let active_occ_pid = if has_explicit_tenant { explicit_tenant_person_id } else { Some(person_numeric_id) };

                    if has_explicit_tenant || is_tenant || request.is_resident {
                        if let Some(occ_pid) = active_occ_pid {
                            let _ = client
                                .execute(
                                    r#"
                                    INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                                    VALUES ($1, $2, $3, CURRENT_DATE, true, 0.00, $4)
                                    "#,
                                    &[&unit_numeric_id, &occ_pid, &new_occ_type, &Some(format!("Yeni {} girişi", if has_explicit_tenant || is_tenant { "kiracı" } else { "malik" }))],
                                )
                                .await;
                        }
                    }

                    // Update unit with new occupant
                    if has_explicit_tenant {
                        let _ = client
                            .execute(
                                r#"
                                UPDATE units SET
                                    owner_person_id = $1,
                                    tenant_person_id = $2,
                                    occupancy_status = 'TENANT_OCCUPIED',
                                    house_type = COALESCE($3, house_type),
                                    virtual_iban = COALESCE(virtual_iban, $4)
                                WHERE id = $5
                                "#,
                                &[&person_numeric_id, &explicit_tenant_person_id, &effective_house_type, &viban, &unit_numeric_id],
                            )
                            .await;
                    } else if is_tenant {
                        let _ = client
                            .execute(
                                r#"
                                UPDATE units SET
                                    tenant_person_id = $1,
                                    occupancy_status = $2,
                                    house_type = COALESCE($3, house_type),
                                    virtual_iban = COALESCE(virtual_iban, $4)
                                WHERE id = $5
                                "#,
                                &[&person_numeric_id, &new_occ_status, &effective_house_type, &viban, &unit_numeric_id],
                            )
                            .await;
                    } else {
                        let _ = client
                            .execute(
                                r#"
                                UPDATE units SET
                                    owner_person_id = $1,
                                    tenant_person_id = CASE WHEN $2 = true THEN NULL ELSE tenant_person_id END,
                                    occupancy_status = $3,
                                    house_type = COALESCE($4, house_type),
                                    virtual_iban = COALESCE(virtual_iban, $5)
                                WHERE id = $6
                                "#,
                                &[&person_numeric_id, &request.is_resident, &new_occ_status, &effective_house_type, &viban, &unit_numeric_id],
                            )
                            .await;
                    }
                }
            } else {
                // New Unit
                let occ_status = if has_explicit_tenant || is_tenant {
                    "TENANT_OCCUPIED"
                } else if request.is_resident {
                    "OWNER_OCCUPIED"
                } else {
                    "VACANT"
                };
                let owner_pid = if is_tenant && !has_explicit_tenant { None } else { Some(person_numeric_id) };
                let tenant_pid = if has_explicit_tenant { explicit_tenant_person_id } else if is_tenant { Some(person_numeric_id) } else { None };

                let unit_row = client
                    .query_one(
                        r#"
                        INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban, house_type, occupancy_status)
                        VALUES ($1, $2, $3, $4, 1, $5, $6, $7, $8, $9)
                        RETURNING id
                        "#,
                        &[
                            &block_numeric_id,
                            &site_numeric_id,
                            &request.unit_no,
                            &effective_floor,
                            &owner_pid,
                            &tenant_pid,
                            &viban,
                            &effective_house_type,
                            &occ_status,
                        ],
                    )
                    .await
                    .map_err(|e| format!("Failed to insert unit: {}", e))?;
                unit_numeric_id = unit_row.get(0);
                if is_resident_only {
                    let _ = client
                        .execute(
                            r#"
                            INSERT INTO unit_members (unit_id, resident_id, full_name, relationship, phone, email, is_owner, created_at)
                            VALUES ($1, $2, $3, 'Ev Sakini', $4, $5, false, CURRENT_TIMESTAMP)
                            "#,
                            &[
                                &unit_numeric_id.to_string(),
                                &user_numeric_id.to_string(),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await;
                } else if has_explicit_tenant {
                    if let Some(t_pid) = explicit_tenant_person_id {
                        let _ = client
                            .execute(
                                r#"
                                INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                                VALUES ($1, $2, 'TENANT', CURRENT_DATE, true, 0.00, 'İlk kiracı kaydı')
                                "#,
                                &[&unit_numeric_id, &t_pid],
                            )
                            .await;
                    }
                } else if is_tenant || request.is_resident {
                    let occ_type = if is_tenant { "TENANT" } else { "OWNER" };
                    let _ = client
                        .execute(
                            r#"
                            INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                            VALUES ($1, $2, $3, CURRENT_DATE, true, 0.00, 'İlk sakin kaydı')
                            "#,
                            &[&unit_numeric_id, &person_numeric_id, &occ_type],
                        )
                        .await;
                }
            }

            // Insert due liability if dues > 0 and NOT co-resident
            if !is_resident_only && monthly_dues > Decimal::ZERO {
                let now = Utc::now();
                let month_name = match now.month() {
                    1 => "Ocak",
                    2 => "Şubat",
                    3 => "Mart",
                    4 => "Nisan",
                    5 => "Mayıs",
                    6 => "Haziran",
                    7 => "Temmuz",
                    8 => "Ağustos",
                    9 => "Eylül",
                    10 => "Ekim",
                    11 => "Kasım",
                    12 => "Aralık",
                    _ => "Ocak",
                };
                let period = format!("{} {}", month_name, now.year());
                let due_date = now.date_naive() + chrono::Days::new(15);
                let _ = client
                    .execute(
                        r#"
                        INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, delay_penalty, paid_amount)
                        VALUES ($1, $2, $3, $4, 'PENDING', 0.00, 0.00)
                        ON CONFLICT DO NOTHING
                        "#,
                        &[&unit_numeric_id, &period, &monthly_dues, &due_date],
                    )
                    .await;
            }
        }

        // 3. Update in-memory state
        let mut inner = self.state.inner.write().await;

        let user_id = if user_numeric_id > 0 {
            user_numeric_id.to_string()
        } else {
            format!("usr-resident-{}", &Uuid::new_v4().to_string()[..8])
        };

        let resident_user = User {
            id: user_id.clone(),
            site_id: site_id.to_string(),
            full_name: request.owner_full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone(),
            password_hash: Some(password_hash.clone()),
            role: Role::HomeResident,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
        };
        inner.users.push(resident_user.clone());

        let unit_id = if unit_numeric_id > 0 {
            unit_numeric_id.to_string()
        } else {
            format!("unit-{}", request.unit_no)
        };

        let block_id_str = if block_numeric_id > 0 {
            block_numeric_id.to_string()
        } else {
            format!("blok-{}", effective_clean_block)
        };

        if is_resident_only {
            let member_dto = crate::models::UnitMemberDto {
                resident_id: user_id.clone(),
                full_name: request.owner_full_name.clone(),
                relationship: "Ev Sakini".to_string(),
                phone: request.phone.clone(),
                email: email_norm.clone(),
                is_owner: false,
            };
            inner.unit_members.entry(unit_id.clone()).or_default().push(member_dto.clone());
            if unit_numeric_id > 0 {
                inner.unit_members.entry(unit_numeric_id.to_string()).or_default().push(member_dto.clone());
            }
            inner.unit_members.entry(request.unit_no.to_string()).or_default().push(member_dto.clone());
            inner.unit_members.entry(format!("unit-{}", request.unit_no)).or_default().push(member_dto.clone());
            inner.unit_members.entry(format!("d-{}", request.unit_no)).or_default().push(member_dto);
        } else {
            let existing_unit_pos = inner.units.iter().position(|u| u.id == unit_id || (u.site_id == site_id && u.unit_number == request.unit_no));
            let existing_owner_id = existing_unit_pos.and_then(|p| inner.units[p].owner_user_id.clone());
            let existing_tenant_id = existing_unit_pos.and_then(|p| inner.units[p].tenant_user_id.clone());

            let mut explicit_tenant_user_id_in_mem: Option<String> = None;
            if has_explicit_tenant {
                let tid = format!("usr-tenant-{}", &Uuid::new_v4().to_string()[..8]);
                let tenant_user = User {
                    id: tid.clone(),
                    site_id: site_id.to_string(),
                    full_name: request.tenant_full_name.clone().unwrap_or_default(),
                    email: request.tenant_email.clone().unwrap_or_default().trim().to_lowercase(),
                    phone: request.tenant_phone.clone().unwrap_or_default(),
                    password_hash: Some(password_hash.clone()),
                    role: Role::HomeResident,
                    must_change_password: true,
                    auth_provider: "LOCAL".to_string(),
                    google_sub: None,
                    avatar_url: None,
                    created_at: Utc::now(),
                };
                inner.users.push(tenant_user);
                explicit_tenant_user_id_in_mem = Some(tid);
            }

            let unit = IndependentUnit {
                id: unit_id.clone(),
                site_id: site_id.to_string(),
                block_id: block_id_str,
                unit_number: request.unit_no,
                floor: effective_floor,
                land_share: 1,
                owner_user_id: if is_tenant && !has_explicit_tenant { existing_owner_id } else { Some(user_id.clone()) },
                tenant_user_id: if has_explicit_tenant {
                    explicit_tenant_user_id_in_mem
                } else if is_tenant {
                    Some(user_id.clone())
                } else if request.is_resident {
                    None
                } else {
                    existing_tenant_id
                },
                virtual_iban: Some(viban),
                house_type: effective_house_type.clone(),
            };

            // Insert or update in-memory unit
            if let Some(pos) = existing_unit_pos {
                inner.units[pos] = unit.clone();
            } else {
                inner.units.push(unit.clone());
            }

            // Add legacy alias for unit
            let legacy_unit_id = format!("d-{}", request.unit_no);
            if !inner.units.iter().any(|u| u.id == legacy_unit_id) {
                let mut leg = unit.clone();
                leg.id = legacy_unit_id.clone();
                inner.units.push(leg);
            }

            // Register unit payer names
            inner
                .unit_payer_names
                .entry(unit.id.clone())
                .or_default()
                .push(request.owner_full_name.clone());
            inner
                .unit_payer_names
                .entry(legacy_unit_id.clone())
                .or_default()
                .push(request.owner_full_name.clone());

            if let Some(ref t_name) = request.tenant_full_name {
                inner
                    .unit_payer_names
                    .entry(unit.id.clone())
                    .or_default()
                    .push(t_name.clone());
                inner
                    .unit_payer_names
                    .entry(legacy_unit_id)
                    .or_default()
                    .push(t_name.clone());
            }
        }

        if !is_resident_only {
            let occ_type = if has_explicit_tenant || is_tenant { "TENANT" } else { "OWNER" };
            let history_key = unit_id.clone();
            let history_list = inner.unit_occupancies.entry(history_key).or_default();
            for item in history_list.iter_mut() {
                if item.is_active {
                    item.is_active = false;
                    item.end_date = Some(Utc::now().date_naive().to_string());
                    item.notes = Some(format!("{} • Ayrıldı (Yeni sakin devri)", item.notes.as_deref().unwrap_or("")));
                }
            }
            if has_explicit_tenant {
                history_list.push(crate::models::OccupancyHistoryItem {
                    id: (history_list.len() + 1) as i64,
                    unit_id: unit_numeric_id,
                    person_id: 202,
                    person_name: request.tenant_full_name.clone().unwrap_or_default(),
                    person_phone: request.tenant_phone.clone(),
                    person_email: request.tenant_email.clone(),
                    role: "TENANT".to_string(),
                    start_date: Utc::now().date_naive().to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: Some("Yeni kiracı kaydı".to_string()),
                    created_at: Utc::now(),
                });
            } else if is_tenant || request.is_resident {
                history_list.push(crate::models::OccupancyHistoryItem {
                    id: (history_list.len() + 1) as i64,
                    unit_id: unit_numeric_id,
                    person_id: person_numeric_id,
                    person_name: request.owner_full_name.clone(),
                    person_phone: Some(request.phone.clone()),
                    person_email: Some(email_norm.clone()),
                    role: occ_type.to_string(),
                    start_date: Utc::now().date_naive().to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: Some(format!("Yeni {} kaydı", if is_tenant { "kiracı" } else { "malik" })),
                    created_at: Utc::now(),
                });
            }
            let cloned = history_list.clone();
            inner.unit_occupancies.insert(request.unit_no.to_string(), cloned.clone());
            inner.unit_occupancies.insert(format!("unit-{}", request.unit_no), cloned.clone());
            inner.unit_occupancies.insert(format!("d-{}", request.unit_no), cloned);
        }

        // Also add due liability in memory if > 0 and NOT a co-resident
        if !is_resident_only && monthly_dues > Decimal::ZERO {
            let period = inner.dues.first().map(|d| d.period.clone()).unwrap_or_else(|| {
                let now = Utc::now();
                let month_name = match now.month() {
                    1 => "Ocak",
                    2 => "Şubat",
                    3 => "Mart",
                    4 => "Nisan",
                    5 => "Mayıs",
                    6 => "Haziran",
                    7 => "Temmuz",
                    8 => "Ağustos",
                    9 => "Eylül",
                    10 => "Ekim",
                    11 => "Kasım",
                    12 => "Aralık",
                    _ => "Ocak",
                };
                format!("{} {}", month_name, now.year())
            });

            inner.dues.push(DuesLiability {
                id: format!("DUE-{}-{}", unit_id, Uuid::new_v4().simple()),
                unit_id: unit_id.clone(),
                period,
                principal_amount: monthly_dues,
                delay_penalty: Decimal::ZERO,
                total_amount: monthly_dues,
                due_date: Utc::now().date_naive() + chrono::Days::new(15),
                status: DebtStatus::Pending,
            });
        }

        let household = if is_resident_only {
            vec![crate::models::UnitMemberDto {
                resident_id: user_id.clone(),
                full_name: request.owner_full_name.clone(),
                relationship: "Ev Sakini".to_string(),
                phone: request.phone.clone(),
                email: email_norm.clone(),
                is_owner: false,
            }]
        } else {
            Vec::new()
        };

        Ok(HomeOwnerResponse {
            unit_id,
            site_id: site_id.to_string(),
            block: request.block,
            unit_no: request.unit_no,
            floor: effective_floor,
            owner_full_name: request.owner_full_name,
            email: email_norm,
            phone: request.phone,
            land_share: request.land_share.unwrap_or_else(|| "1/24".to_string()),
            monthly_dues,
            house_type: effective_house_type,
            is_resident: request.is_resident,
            temporary_password: Some(temp_pass),
            must_change_password: true,
            created_at: Utc::now(),
            occupancy_status: Some(if request.is_resident { "OWNER_OCCUPIED".to_string() } else { "VACANT".to_string() }),
            tenant_full_name: None,
            tenant_email: None,
            tenant_phone: None,
            operational_dues_balance: Some(Decimal::ZERO),
            capital_dues_balance: Some(Decimal::ZERO),
            household_residents: household,
        })
    }

    pub async fn get_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let query = r#"
                    SELECT 
                        u.id::text as unit_id,
                        u.site_id as site_id,
                        COALESCE(b.block_name, 'A Blok') as block_name,
                        COALESCE(u.unit_number, 0) as unit_number,
                        COALESCE(u.floor, 1) as floor,
                        COALESCE(po.full_name, 'Kat Maliki Tanımlanmamış') as full_name,
                        COALESCE(po.email, '') as email,
                        COALESCE(po.phone, '') as phone,
                        COALESCE(u.land_share, 24) as land_share,
                        u.house_type,
                        COALESCE((SELECT principal_amount FROM dues_liabilities WHERE unit_id = u.id ORDER BY id DESC LIMIT 1), 1400.00) as monthly_dues,
                        COALESCE(usr.must_change_password, false) as must_change_password,
                        COALESCE(usr.created_at, NOW()) as created_at,
                        COALESCE(u.occupancy_status, 'OWNER_OCCUPIED') as occupancy_status,
                        pt.full_name as tenant_full_name,
                        pt.email as tenant_email,
                        pt.phone as tenant_phone,
                        COALESCE((SELECT SUM(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities WHERE unit_id = u.id AND status != 'PAID' AND (expense_type = 'OPERATIONAL_DUES' OR debtor_type = 'TENANT')), 0.00) as operational_dues_balance,
                        COALESCE((SELECT SUM(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities WHERE unit_id = u.id AND status != 'PAID' AND (expense_type = 'CAPITAL_DUES' OR debtor_type = 'OWNER')), 0.00) as capital_dues_balance,
                        CASE 
                            WHEN u.tenant_person_id IS NOT NULL THEN false
                            ELSE true
                        END as is_resident
                    FROM units u
                    LEFT JOIN blocks b ON u.block_id = b.id
                    LEFT JOIN persons po ON u.owner_person_id = po.id
                    LEFT JOIN persons pt ON u.tenant_person_id = pt.id
                    LEFT JOIN users usr ON LOWER(usr.email) = LOWER(po.email)
                    WHERE u.site_id = $1
                    ORDER BY b.block_name, u.unit_number
                "#;
                let mut household_map: std::collections::HashMap<String, Vec<crate::models::UnitMemberDto>> = std::collections::HashMap::new();
                if let Ok(m_rows) = client
                    .query(
                        "SELECT unit_id, resident_id, full_name, relationship, COALESCE(phone, ''), COALESCE(email, ''), is_owner FROM unit_members ORDER BY id ASC",
                        &[],
                    )
                    .await
                {
                    for mr in m_rows {
                        let u_id: String = mr.get(0);
                        let mem = crate::models::UnitMemberDto {
                            resident_id: mr.get(1),
                            full_name: mr.get(2),
                            relationship: mr.get(3),
                            phone: mr.get(4),
                            email: mr.get(5),
                            is_owner: mr.get(6),
                        };
                        household_map.entry(u_id).or_default().push(mem);
                    }
                }

                if let Ok(rows) = client.query(query, &[&site_numeric]).await {
                    if !rows.is_empty() {
                        let mut db_result = Vec::new();
                        let mut seen = std::collections::HashSet::new();
                        for r in rows {
                            let email: String = r.get("email");
                            let full_name: String = r.get("full_name");
                            let block_name: String = r.get("block_name");
                            let unit_no: i32 = r.get("unit_number");
                            let unit_id_val: String = r.get("unit_id");

                            let dedup_key = format!("{}-{}", block_name, unit_no);
                            if !seen.insert(dedup_key) {
                                continue;
                            }
                            let floor_val: i32 = r.get("floor");
                            let land_share_val: i32 = r.get("land_share");
                            let dues_val: Decimal = r.get("monthly_dues");
                            let is_resident: bool = r.get("is_resident");
                            let occ_status: String = r.get("occupancy_status");
                            let t_name: Option<String> = r.get("tenant_full_name");
                            let t_email: Option<String> = r.get("tenant_email");
                            let t_phone: Option<String> = r.get("tenant_phone");
                            let op_balance: Decimal = r.get("operational_dues_balance");
                            let cap_balance: Decimal = r.get("capital_dues_balance");

                            let mut household = household_map.get(&unit_id_val).cloned().unwrap_or_default();
                            if household.is_empty() {
                                household = household_map.get(&unit_no.to_string()).cloned().unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map.get(&format!("d-{}", unit_no)).cloned().unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map.get(&format!("unit-{}", unit_no)).cloned().unwrap_or_default();
                            }

                            db_result.push(HomeOwnerResponse {
                                unit_id: unit_id_val,
                                site_id: site_id.to_string(),
                                block: block_name,
                                unit_no,
                                floor: floor_val,
                                owner_full_name: full_name,
                                email,
                                phone: r.get("phone"),
                                land_share: format!("{}/24", land_share_val),
                                monthly_dues: dues_val,
                                house_type: r.get("house_type"),
                                is_resident,
                                temporary_password: None,
                                must_change_password: r.get("must_change_password"),
                                created_at: r.get("created_at"),
                                occupancy_status: Some(occ_status),
                                tenant_full_name: t_name,
                                tenant_email: t_email,
                                tenant_phone: t_phone,
                                operational_dues_balance: Some(op_balance),
                                capital_dues_balance: Some(cap_balance),
                                household_residents: household,
                            });
                        }
                        if !db_result.is_empty() {
                            return db_result;
                        }
                    }
                }
            }
        }

        // 2. In-memory fallback
        let inner = self.state.inner.read().await;
        let mut result = Vec::new();
        let mut seen = std::collections::HashSet::new();

        for user in inner.users.iter().filter(|u| {
            (u.site_id == site_id
                || crate::db::parse_id_to_i64(&u.site_id) == crate::db::parse_id_to_i64(site_id))
                && (u.role == Role::HomeResident || u.role == Role::HomeOwner)
        }) {
            let matching_unit = inner.units.iter().find(|u| {
                u.owner_user_id.as_deref() == Some(&user.id)
                    || u.tenant_user_id.as_deref() == Some(&user.id)
                    || inner
                        .unit_payer_names
                        .get(&u.id)
                        .map(|names| names.contains(&user.full_name))
                        .unwrap_or(false)
            });

            let (unit_id, block, unit_no, floor) = if let Some(u) = matching_unit {
                let clean_blk = u
                    .block_id
                    .to_uppercase()
                    .replace("BLOK", "")
                    .replace(['-', '_', ' '], "")
                    .trim()
                    .to_string();
                let effective_blk = if clean_blk.is_empty() {
                    u.block_id.clone()
                } else {
                    format!("{} Blok", clean_blk)
                };
                (u.id.clone(), effective_blk, u.unit_number, u.floor)
            } else {
                (format!("unit-{}", user.id), "A Blok".to_string(), 1, 1)
            };

            let dedup_key = format!("{}-{}", block, unit_no);
            if !seen.insert(dedup_key) {
                continue;
            }

            let monthly_dues = inner
                .dues
                .iter()
                .find(|d| d.unit_id == unit_id)
                .map(|d| d.principal_amount)
                .unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());

            let household = inner
                .unit_members
                .get(&unit_id)
                .cloned()
                .or_else(|| inner.unit_members.get(&unit_no.to_string()).cloned())
                .or_else(|| inner.unit_members.get(&format!("d-{}", unit_no)).cloned())
                .or_else(|| inner.unit_members.get(&format!("unit-{}", unit_no)).cloned())
                .unwrap_or_default();

            result.push(HomeOwnerResponse {
                unit_id,
                site_id: site_id.to_string(),
                block,
                unit_no,
                floor,
                owner_full_name: user.full_name.clone(),
                email: user.email.clone(),
                phone: user.phone.clone(),
                land_share: "1/24".to_string(),
                monthly_dues,
                house_type: matching_unit.and_then(|u| u.house_type.clone()),
                is_resident: user.role == Role::HomeResident || matching_unit.map(|u| u.tenant_user_id.is_none()).unwrap_or(true),
                temporary_password: None,
                must_change_password: user.must_change_password,
                created_at: user.created_at,
                occupancy_status: Some("OWNER_OCCUPIED".to_string()),
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                operational_dues_balance: Some(Decimal::ZERO),
                capital_dues_balance: Some(Decimal::ZERO),
                household_residents: household,
            });
        }

        result
    }

    pub async fn update_home_owner(
        &self,
        site_id: &str,
        unit_or_user_id: &str,
        req: crate::models::UpdateHomeOwnerRequest,
    ) -> Result<HomeOwnerResponse, String> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // 1. If DB pool is available, update database
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let unit_row_opt = if let Some(uid) = id_numeric {
                    client
                        .query_opt(
                            "SELECT id, block_id, unit_number, floor, owner_person_id, tenant_person_id, house_type FROM units WHERE (id = $1 OR owner_person_id = $1 OR tenant_person_id = $1) AND site_id = $2",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                } else {
                    client
                        .query_opt(
                            "SELECT u.id, u.block_id, u.unit_number, u.floor, u.owner_person_id, u.tenant_person_id, u.house_type FROM units u JOIN persons p ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id) WHERE p.email = $1 AND u.site_id = $2",
                            &[&unit_or_user_id, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                };

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    let p_id: Option<i64> = u_row.get(4);
                    let t_id: Option<i64> = u_row.get(5);

                    if req.remove_tenant == Some(true) {
                        if let Some(tenant_person_id) = t_id {
                            let _ = client.execute(
                                "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE WHERE unit_id = $1 AND person_id = $2 AND is_active = true",
                                &[&u_id, &tenant_person_id],
                            ).await;
                        }
                        let new_occupancy = if req.is_resident == Some(true) { "OWNER_OCCUPIED" } else { "VACANT" };
                        let _ = client.execute("UPDATE units SET tenant_person_id = NULL, occupancy_status = $1 WHERE id = $2", &[&new_occupancy, &u_id]).await;
                        if req.is_resident == Some(true) {
                            if let Some(owner_person_id) = p_id {
                                let _ = client.execute(
                                    "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, created_at)
                                     VALUES ($1, $2, 'OWNER', CURRENT_DATE, true, NOW())
                                     ON CONFLICT DO NOTHING",
                                    &[&u_id, &owner_person_id],
                                ).await;
                            }
                        }
                    } else if let Some(tenant_person_id) = t_id {
                        if let Some(ref t_name) = req.tenant_full_name {
                            let _ = client.execute("UPDATE persons SET full_name = $1 WHERE id = $2", &[t_name, &tenant_person_id]).await;
                            let _ = client.execute("UPDATE users SET full_name = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[t_name, &site_numeric, &tenant_person_id]).await;
                        }
                        if let Some(ref t_phone) = req.tenant_phone {
                            let _ = client.execute("UPDATE persons SET phone = $1 WHERE id = $2", &[t_phone, &tenant_person_id]).await;
                            let _ = client.execute("UPDATE users SET phone = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[t_phone, &site_numeric, &tenant_person_id]).await;
                        }
                        if let Some(ref t_email) = req.tenant_email {
                            let email_norm = t_email.trim().to_lowercase();
                            let prev_email: Option<String> = client.query_opt("SELECT email FROM persons WHERE id = $1", &[&tenant_person_id]).await.ok().flatten().map(|r| r.get(0));
                            let _ = client.execute("UPDATE persons SET email = $1 WHERE id = $2", &[&email_norm, &tenant_person_id]).await;
                            if let Some(ref pe) = prev_email {
                                let _ = client.execute("UPDATE users SET email = $1 WHERE site_id = $2 AND LOWER(email) = LOWER($3)", &[&email_norm, &site_numeric, pe]).await;
                            }
                        }
                    } else if let Some(ref t_name) = req.tenant_full_name {
                        if !t_name.trim().is_empty() {
                            let t_email = req.tenant_email.clone().unwrap_or_else(|| format!("tenant.{}@example.com", u_id)).trim().to_lowercase();
                            let t_phone = req.tenant_phone.clone().unwrap_or_default();
                            let row_res = client.query_one(
                                "INSERT INTO persons (full_name, phone, email, person_type) 
                                 VALUES ($1, $2, $3, 'KAT_SAKINI') 
                                 ON CONFLICT (email) DO UPDATE SET full_name = EXCLUDED.full_name, phone = EXCLUDED.phone 
                                 RETURNING id",
                                &[&t_name, &t_phone, &t_email],
                            ).await;
                            if let Ok(r) = row_res {
                                let new_t_id: i64 = r.get(0);
                                let _ = client.execute("UPDATE units SET tenant_person_id = $1, occupancy_status = 'TENANT_OCCUPIED' WHERE id = $2", &[&new_t_id, &u_id]).await;
                                let _ = client.execute(
                                    "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, created_at)
                                     VALUES ($1, $2, 'TENANT', CURRENT_DATE, true, NOW())",
                                    &[&u_id, &new_t_id],
                                ).await;
                            }
                        }
                    }

                    if let Some(owner_person_id) = p_id {
                        if let Some(ref name) = req.owner_full_name {
                            let _ = client.execute("UPDATE persons SET full_name = $1 WHERE id = $2", &[name, &owner_person_id]).await;
                            let _ = client.execute("UPDATE users SET full_name = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[name, &site_numeric, &owner_person_id]).await;
                        }
                        if let Some(ref phone) = req.phone {
                            let _ = client.execute("UPDATE persons SET phone = $1 WHERE id = $2", &[phone, &owner_person_id]).await;
                            let _ = client.execute("UPDATE users SET phone = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[phone, &site_numeric, &owner_person_id]).await;
                        }
                        if let Some(ref email) = req.email {
                            let email_norm = email.trim().to_lowercase();
                            let prev_email: Option<String> = client.query_opt("SELECT email FROM persons WHERE id = $1", &[&owner_person_id]).await.ok().flatten().map(|r| r.get(0));
                            let _ = client.execute("UPDATE persons SET email = $1 WHERE id = $2", &[&email_norm, &owner_person_id]).await;
                            if let Some(ref pe) = prev_email {
                                let _ = client.execute("UPDATE users SET email = $1 WHERE site_id = $2 AND LOWER(email) = LOWER($3)", &[&email_norm, &site_numeric, pe]).await;
                            }
                        }
                    }

                    if let Some(ref ht) = req.house_type {
                        let _ = client.execute("UPDATE units SET house_type = $1 WHERE id = $2", &[ht, &u_id]).await;
                    }
                    if let Some(dues) = req.monthly_dues {
                        let _ = client.execute(
                            "UPDATE dues_liabilities SET principal_amount = $1 WHERE unit_id = $2 AND status = 'PENDING'",
                            &[&dues, &u_id],
                        ).await;
                    }
                }
            }
        }

        // 2. Update in-memory state
        let mut inner = self.state.inner.write().await;

        let unit_idx = inner.units.iter().position(|u| {
            u.id == unit_or_user_id
                || u.owner_user_id.as_deref() == Some(unit_or_user_id)
                || crate::db::parse_id_to_i64(&u.id) == id_numeric
        });

        let user_idx = inner.users.iter().position(|u| {
            u.id == unit_or_user_id
                || crate::db::parse_id_to_i64(&u.id) == id_numeric
                || (unit_idx.is_some() && inner.units[unit_idx.unwrap()].owner_user_id.as_deref() == Some(&u.id))
        });

        let tenant_user_idx = if let Some(uidx) = unit_idx {
            if let Some(ref tuid) = inner.units[uidx].tenant_user_id {
                inner.users.iter().position(|u| &u.id == tuid)
            } else {
                None
            }
        } else {
            None
        };

        if let Some(uidx) = unit_idx {
            if req.remove_tenant == Some(true) {
                inner.units[uidx].tenant_user_id = None;
            } else if let Some(t_idx) = tenant_user_idx {
                if let Some(ref t_name) = req.tenant_full_name {
                    inner.users[t_idx].full_name = t_name.clone();
                }
                if let Some(ref t_email) = req.tenant_email {
                    inner.users[t_idx].email = t_email.trim().to_lowercase();
                }
                if let Some(ref t_phone) = req.tenant_phone {
                    inner.users[t_idx].phone = t_phone.clone();
                }
            } else if let Some(ref t_name) = req.tenant_full_name {
                if !t_name.trim().is_empty() {
                    let new_uid = format!("usr-t-{}", inner.users.len() + 1);
                    let email = req.tenant_email.clone().unwrap_or_else(|| format!("tenant.{}@example.com", inner.users.len() + 1));
                    let phone = req.tenant_phone.clone().unwrap_or_default();
                    inner.users.push(crate::models::User {
                        id: new_uid.clone(),
                        full_name: t_name.clone(),
                        email,
                        phone,
                        password_hash: None,
                        role: crate::models::Role::HomeResident,
                        site_id: site_id.to_string(),
                        must_change_password: true,
                        auth_provider: "LOCAL".to_string(),
                        google_sub: None,
                        avatar_url: None,
                        created_at: chrono::Utc::now(),
                    });
                    inner.units[uidx].tenant_user_id = Some(new_uid);
                }
            }
            if let Some(ref ht) = req.house_type {
                inner.units[uidx].house_type = Some(ht.clone());
            }
            if let Some(dues) = req.monthly_dues {
                let unit_id = inner.units[uidx].id.clone();
                for d in inner.dues.iter_mut().filter(|d| d.unit_id == unit_id && d.status == DebtStatus::Pending) {
                    d.principal_amount = dues;
                    d.total_amount = dues;
                }
            }
        }

        if let Some(usridx) = user_idx {
            if let Some(ref name) = req.owner_full_name {
                inner.users[usridx].full_name = name.clone();
            }
            if let Some(ref phone) = req.phone {
                inner.users[usridx].phone = phone.clone();
            }
            if let Some(ref email) = req.email {
                inner.users[usridx].email = email.trim().to_lowercase();
            }
        }

        if let (Some(uidx), Some(ref name)) = (unit_idx, &req.owner_full_name) {
            let unit_id = inner.units[uidx].id.clone();
            inner.unit_payer_names.insert(unit_id, vec![name.clone()]);
        }

        drop(inner);

        let all_owners = self.get_home_owners_for_site(site_id).await;
        if let Some(updated) = all_owners.into_iter().find(|o| {
            o.unit_id == unit_or_user_id
                || crate::db::parse_id_to_i64(&o.unit_id) == id_numeric
                || req.email.as_ref().map(|e| e.trim().eq_ignore_ascii_case(&o.email)).unwrap_or(false)
                || (req.tenant_email.as_ref().map(|e| o.tenant_email.as_ref().map(|te| te.trim().eq_ignore_ascii_case(e)).unwrap_or(false)).unwrap_or(false))
        }) {
            Ok(updated)
        } else {
            Err("Home owner updated but could not reload fresh state".to_string())
        }
    }

    pub async fn delete_home_owner(&self, site_id: &str, unit_or_user_id: &str) -> Result<(), String> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // 1. If DB pool is available, delete from PostgreSQL
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let unit_row_opt = if let Some(uid) = id_numeric {
                    client
                        .query_opt(
                            "SELECT id, owner_person_id, tenant_person_id FROM units WHERE (id = $1 OR owner_person_id = $1 OR tenant_person_id = $1) AND site_id = $2",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                } else {
                    client
                        .query_opt(
                            "SELECT u.id, u.owner_person_id, u.tenant_person_id FROM units u JOIN persons p ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id) WHERE p.email = $1 AND u.site_id = $2",
                            &[&unit_or_user_id, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                };

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    let p_id: Option<i64> = u_row.get(1);
                    let t_id: Option<i64> = u_row.get(2);
                    let u_id_str = u_id.to_string();

                    // Delete dependent records safely adhering to foreign key hierarchy
                    let _ = client.execute("DELETE FROM collection_transactions WHERE unit_id = $1 OR dues_liability_id IN (SELECT id FROM dues_liabilities WHERE unit_id = $1)", &[&u_id]).await;
                    let _ = client.execute("DELETE FROM dues_liabilities WHERE unit_id = $1", &[&u_id]).await;
                    let _ = client.execute("DELETE FROM unit_occupancies WHERE unit_id = $1", &[&u_id]).await;
                    let _ = client.execute("DELETE FROM unit_members WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM advance_balances WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM unit_sender_ibans WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM unit_payer_names WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM units WHERE id = $1", &[&u_id]).await;

                    // Clean up person and user if no other units or occupancies exist
                    for person_opt in &[p_id, t_id] {
                        if let Some(person_id) = person_opt {
                            let other_units = client
                                .query_one("SELECT COUNT(*) FROM units WHERE owner_person_id = $1 OR tenant_person_id = $1", &[person_id])
                                .await
                                .map(|r| r.get::<_, i64>(0))
                                .unwrap_or(0);
                            let other_occ = client
                                .query_one("SELECT COUNT(*) FROM unit_occupancies WHERE person_id = $1", &[person_id])
                                .await
                                .map(|r| r.get::<_, i64>(0))
                                .unwrap_or(0);
                            if other_units == 0 && other_occ == 0 {
                                let _ = client.execute("DELETE FROM users WHERE site_id = $1 AND email = (SELECT email FROM persons WHERE id = $2)", &[&site_numeric, person_id]).await;
                                let _ = client.execute("DELETE FROM persons WHERE id = $1", &[person_id]).await;
                            }
                        }
                    }
                }
            }
        }

        // 2. In-memory state cleanup
        let mut inner = self.state.inner.write().await;

        let target_units: Vec<IndependentUnit> = inner
            .units
            .iter()
            .filter(|u| {
                (u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id
                        || crate::db::parse_id_to_i64(&u.id) == id_numeric
                        || u.owner_user_id.as_deref() == Some(unit_or_user_id)
                        || u.owner_user_id.as_ref().and_then(|uid| crate::db::parse_id_to_i64(uid)) == id_numeric)
            })
            .cloned()
            .collect();

        if !target_units.is_empty() {
            let target_unit_ids: Vec<String> = target_units.iter().map(|u| u.id.clone()).collect();
            let target_unit_nos: Vec<i32> = target_units.iter().map(|u| u.unit_number).collect();
            let target_owner_uids: Vec<String> = target_units
                .iter()
                .filter_map(|u| u.owner_user_id.clone())
                .collect();

            // Retain only unrelated units
            inner.units.retain(|u| {
                let matches_site = u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric);
                if !matches_site {
                    return true;
                }
                !(target_unit_ids.contains(&u.id) || target_unit_nos.contains(&u.unit_number))
            });

            // Clean dues
            inner.dues.retain(|d| {
                !target_unit_ids.contains(&d.unit_id)
                    && !target_unit_nos.iter().any(|n| d.unit_id == format!("d-{}", n) || d.unit_id == n.to_string())
            });

            // Clean advance
            for u_id in &target_unit_ids {
                inner.advance_payments.remove(u_id);
                inner.unit_members.remove(u_id);
                inner.unit_payer_names.remove(u_id);
                inner.unit_invite_tokens.remove(u_id);
            }
            for n in &target_unit_nos {
                let leg_id = format!("d-{}", n);
                inner.advance_payments.remove(&leg_id);
                inner.unit_members.remove(&leg_id);
                inner.unit_payer_names.remove(&leg_id);
                inner.unit_invite_tokens.remove(&leg_id);
            }

            // Remove users if not owning other units
            for owner_uid in &target_owner_uids {
                let owns_other = inner.units.iter().any(|u| u.owner_user_id.as_deref() == Some(owner_uid));
                if !owns_other {
                    inner.users.retain(|u| &u.id != owner_uid);
                }
            }
            Ok(())
        } else {
            // Also check if id is a user
            if let Some(usridx) = inner.users.iter().position(|u| {
                (u.site_id == site_id || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id || crate::db::parse_id_to_i64(&u.id) == id_numeric || u.email.eq_ignore_ascii_case(unit_or_user_id))
            }) {
                inner.users.remove(usridx);
                Ok(())
            } else {
                Err(format!("Kat maliki / daire '{}' bulunamadı.", unit_or_user_id))
            }
        }
    }

    pub async fn delete_unit_member(&self, _site_id: &str, unit_id: &str, resident_id: &str) -> Result<(), String> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let _ = client.execute(
                    "DELETE FROM unit_members WHERE (unit_id = $1 OR unit_id = $2 OR unit_id = (SELECT unit_number::text FROM units WHERE id::text = $1) OR unit_id = (SELECT id::text FROM units WHERE unit_number::text = $1)) AND (resident_id = $3 OR full_name = $3 OR id::text = $3)",
                    &[&unit_id, &format!("d-{}", unit_id), &resident_id],
                ).await;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[unit_id.to_string(), format!("d-{}", unit_id), format!("unit-{}", unit_id)] {
            if let Some(members) = inner.unit_members.get_mut(key) {
                members.retain(|m| m.resident_id != resident_id && m.full_name != resident_id);
            }
        }
        Ok(())
    }

    pub async fn update_unit_member(
        &self,
        _site_id: &str,
        unit_id: &str,
        resident_id: &str,
        full_name: &str,
        phone: &str,
        email: &str,
        relationship: &str,
    ) -> Result<(), String> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let _ = client.execute(
                    "UPDATE unit_members SET full_name = $1, phone = $2, email = $3, relationship = $4 WHERE (unit_id = $5 OR unit_id = $6 OR unit_id = (SELECT unit_number::text FROM units WHERE id::text = $5) OR unit_id = (SELECT id::text FROM units WHERE unit_number::text = $5)) AND (resident_id = $7 OR full_name = $7 OR id::text = $7)",
                    &[&full_name, &phone, &email, &relationship, &unit_id, &format!("d-{}", unit_id), &resident_id],
                ).await;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[unit_id.to_string(), format!("d-{}", unit_id), format!("unit-{}", unit_id)] {
            if let Some(members) = inner.unit_members.get_mut(key) {
                for m in members.iter_mut() {
                    if m.resident_id == resident_id || m.full_name == resident_id {
                        m.full_name = full_name.to_string();
                        m.phone = phone.to_string();
                        m.email = email.to_string();
                        m.relationship = relationship.to_string();
                    }
                }
            }
        }
        Ok(())
    }

    pub async fn get_house_types_for_site(&self, site_id: &str) -> Vec<crate::models::HouseTypeTariff> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(rows) = client
                    .query(
                        "SELECT id, site_id, type_name, dues_amount, description FROM house_types WHERE site_id = $1 ORDER BY dues_amount ASC",
                        &[&site_numeric],
                    )
                    .await
                {
                    if !rows.is_empty() {
                        return rows
                            .into_iter()
                            .map(|row| {
                                let id: i64 = row.get(0);
                                let s_id: i64 = row.get(1);
                                let type_name: String = row.get(2);
                                let dues_amount: Decimal = row.get(3);
                                let description: Option<String> = row.get(4);
                                crate::models::HouseTypeTariff {
                                    id: id.to_string(),
                                    site_id: s_id.to_string(),
                                    type_name,
                                    dues_amount,
                                    description,
                                }
                            })
                            .collect();
                    }
                }
            }
        }

        // 2. Read from in-memory state
        let inner = self.state.inner.read().await;
        let list: Vec<_> = inner
            .house_types
            .iter()
            .filter(|h| h.site_id == site_id || crate::db::parse_id_to_i64(&h.site_id) == Some(site_numeric))
            .cloned()
            .collect();
        if !list.is_empty() {
            return list;
        }

        // 3. Defaults fallback
        vec![
            crate::models::HouseTypeTariff {
                id: "1".to_string(),
                site_id: site_id.to_string(),
                type_name: "1+1".to_string(),
                dues_amount: Decimal::from(1000),
                description: Some("1 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "2".to_string(),
                site_id: site_id.to_string(),
                type_name: "2+1".to_string(),
                dues_amount: Decimal::from(1400),
                description: Some("2 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "3".to_string(),
                site_id: site_id.to_string(),
                type_name: "3+1".to_string(),
                dues_amount: Decimal::from(1800),
                description: Some("3 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "4".to_string(),
                site_id: site_id.to_string(),
                type_name: "4+1".to_string(),
                dues_amount: Decimal::from(2200),
                description: Some("4 Oda 1 Salon".to_string()),
            },
            crate::models::HouseTypeTariff {
                id: "5".to_string(),
                site_id: site_id.to_string(),
                type_name: "Dublex".to_string(),
                dues_amount: Decimal::from(2500),
                description: Some("Çatı Dubleks / Bahçe Katı".to_string()),
            },
        ]
    }

    pub async fn create_or_update_house_type(
        &self,
        site_id: &str,
        request: crate::models::CreateHouseTypeRequest,
    ) -> Result<crate::models::HouseTypeTariff, String> {
        if request.type_name.trim().is_empty() {
            return Err("Konut tipi adı boş olamaz (örn: 3+1).".to_string());
        }
        if request.dues_amount <= Decimal::ZERO {
            return Err("Aidat tutarı sıfırdan büyük olmalıdır.".to_string());
        }
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let type_name_trimmed = request.type_name.trim().to_string();

        let mut id_str = format!("ht-{}", &Uuid::new_v4().to_string()[..8]);

        // Save to DB if pool available
        if let Some(ref pool) = self.state.pool {
            let client = pool.get().await.map_err(|e| format!("DB connection error: {}", e))?;
            let row = client
                .query_one(
                    r#"
                    INSERT INTO house_types (site_id, type_name, dues_amount, description)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (site_id, type_name) DO UPDATE SET
                        dues_amount = EXCLUDED.dues_amount,
                        description = EXCLUDED.description
                    RETURNING id
                    "#,
                    &[&site_numeric, &type_name_trimmed, &request.dues_amount, &request.description],
                )
                .await
                .map_err(|e| format!("DB insert error: {}", e))?;
            let db_id: i64 = row.get(0);
            id_str = db_id.to_string();
        }

        let tariff = crate::models::HouseTypeTariff {
            id: id_str,
            site_id: site_id.to_string(),
            type_name: type_name_trimmed,
            dues_amount: request.dues_amount,
            description: request.description,
        };

        // Update in-memory state
        let mut inner = self.state.inner.write().await;
        if let Some(pos) = inner.house_types.iter().position(|h| {
            (h.site_id == site_id || crate::db::parse_id_to_i64(&h.site_id) == Some(site_numeric))
                && h.type_name.eq_ignore_ascii_case(&tariff.type_name)
        }) {
            inner.house_types[pos] = tariff.clone();
        } else {
            inner.house_types.push(tariff.clone());
        }

        Ok(tariff)
    }

    pub async fn delete_house_type(&self, site_id: &str, id: &str) -> Result<(), String> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(numeric_id) = id.parse::<i64>() {
                    let _ = client
                        .execute(
                            "DELETE FROM house_types WHERE id = $1 AND site_id = $2",
                            &[&numeric_id, &site_numeric],
                        )
                        .await;
                }
            }
        }
        let mut inner = self.state.inner.write().await;
        inner.house_types.retain(|h| h.id != id);
        Ok(())
    }

    pub async fn get_blocks_for_site(&self, site_id: &str) -> Vec<crate::models::BlockDto> {
        let mut list = Vec::new();
        if let Some(ref pool) = self.state.pool {
            if let Ok(db_blocks) = crate::db::get_blocks_for_site_from_db(pool, site_id).await {
                if !db_blocks.is_empty() {
                    list = db_blocks;
                }
            }
        }

        if list.is_empty() {
            let site_numeric = crate::db::parse_id_to_i64(site_id);
            let inner = self.state.inner.read().await;
            list = inner
                .blocks
                .iter()
                .filter(|b| {
                    b.site_id == site_id
                        || (site_numeric.is_some()
                            && crate::db::parse_id_to_i64(&b.site_id) == site_numeric)
                })
                .cloned()
                .collect();
        }

        if list.is_empty() {
            list = vec![
                crate::models::BlockDto {
                    id: "b-1".to_string(),
                    site_id: site_id.to_string(),
                    block_name: "A Blok".to_string(),
                    total_floors: 10,
                },
                crate::models::BlockDto {
                    id: "b-2".to_string(),
                    site_id: site_id.to_string(),
                    block_name: "B Blok".to_string(),
                    total_floors: 10,
                },
            ];
        }

        // Strictly deduplicate by block_name
        let mut unique_list: Vec<crate::models::BlockDto> = Vec::new();
        for b in list {
            if !unique_list
                .iter()
                .any(|u| u.block_name.eq_ignore_ascii_case(&b.block_name))
            {
                unique_list.push(b);
            }
        }
        unique_list
    }

    pub async fn create_or_update_block(
        &self,
        site_id: &str,
        request: crate::models::CreateBlockRequest,
    ) -> Result<crate::models::BlockDto, String> {
        let block_name = request.block_name.trim();
        if block_name.is_empty() {
            return Err("Blok adı boş olamaz (örn: A Blok).".to_string());
        }
        let total_floors = request.total_floors.unwrap_or(10);
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);

        let mut id_str = format!("blk-{}", &Uuid::new_v4().to_string()[..8]);

        if let Some(ref pool) = self.state.pool {
            let client = pool.get().await.map_err(|e| format!("DB connection error: {}", e))?;
            let existing = client
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id = $1 AND LOWER(block_name) = LOWER($2)",
                    &[&site_numeric, &block_name],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            if let Some(row) = existing {
                let db_id: i64 = row.get(0);
                id_str = db_id.to_string();
                let _ = client
                    .execute(
                        "UPDATE blocks SET total_floors = $1 WHERE id = $2",
                        &[&total_floors, &db_id],
                    )
                    .await;
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, $3) RETURNING id",
                        &[&site_numeric, &block_name, &total_floors],
                    )
                    .await
                    .map_err(|e| format!("DB insert error: {}", e))?;
                let db_id: i64 = row.get(0);
                id_str = db_id.to_string();
            }
        }

        let block = crate::models::BlockDto {
            id: id_str,
            site_id: site_id.to_string(),
            block_name: block_name.to_string(),
            total_floors,
        };

        let mut inner = self.state.inner.write().await;
        if let Some(pos) = inner.blocks.iter().position(|b| {
            (b.site_id == site_id || crate::db::parse_id_to_i64(&b.site_id) == Some(site_numeric))
                && b.block_name.eq_ignore_ascii_case(&block.block_name)
        }) {
            inner.blocks[pos] = block.clone();
        } else {
            inner.blocks.push(block.clone());
        }

        Ok(block)
    }

    pub async fn move_out_resident(
        &self,
        site_id: &str,
        unit_id: &str,
        req: crate::models::MoveOutResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id.strip_prefix("unit-").and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id.strip_prefix("d-").and_then(|s| s.parse::<i64>().ok())
                } else {
                    None
                }
            })
            .ok_or_else(|| format!("Invalid unit ID: {}", unit_id))?;

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                // Find unit
                let unit_row = client
                    .query_opt(
                        "SELECT id, owner_person_id, tenant_person_id, occupancy_status FROM units WHERE id = $1 AND site_id = $2",
                        &[&unit_numeric, &site_numeric],
                    )
                    .await
                    .map_err(|e| e.to_string())?
                    .ok_or_else(|| format!("Unit {} not found for site {}", unit_id, site_id))?;

                let owner_id: Option<i64> = unit_row.get(1);
                let tenant_id: Option<i64> = unit_row.get(2);

                let target_person_id = tenant_id.or(owner_id).ok_or_else(|| "Unit has no occupant to move out".to_string())?;
                let occ_role = if tenant_id.is_some() { "TENANT" } else { "OWNER" };

                // Calculate exit balance: unpaid liabilities for this unit
                let exit_balance: Decimal = client
                    .query_one(
                        r#"
                        SELECT COALESCE(SUM(principal_amount + delay_penalty - paid_amount), 0.00)
                        FROM dues_liabilities
                        WHERE unit_id = $1 AND status != 'PAID'
                        "#,
                        &[&unit_numeric],
                    )
                    .await
                    .map(|r| r.get(0))
                    .unwrap_or(Decimal::ZERO);

                let notes_val = req.notes.clone();

                // Check if active record exists in unit_occupancies
                let active_occ = client
                    .query_opt(
                        "SELECT id FROM unit_occupancies WHERE unit_id = $1 AND person_id = $2 AND is_active = true ORDER BY id DESC LIMIT 1",
                        &[&unit_numeric, &target_person_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;

                let occ_id: i64 = if let Some(row) = active_occ {
                    let id: i64 = row.get(0);
                    let _ = client
                        .execute(
                            "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE, exit_balance = $1, notes = COALESCE($2, notes) WHERE id = $3",
                            &[&exit_balance, &notes_val, &id],
                        )
                        .await;
                    id
                } else {
                    let row = client
                        .query_one(
                            r#"
                            INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, end_date, is_active, exit_balance, notes)
                            VALUES ($1, $2, $3, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, false, $4, $5)
                            RETURNING id
                            "#,
                            &[&unit_numeric, &target_person_id, &occ_role, &exit_balance, &notes_val],
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                    row.get(0)
                };

                // Update unit status to VACANT and clear tenant_person_id if tenant moved out
                if tenant_id.is_some() {
                    let _ = client
                        .execute(
                            "UPDATE units SET tenant_person_id = NULL, occupancy_status = 'VACANT' WHERE id = $1",
                            &[&unit_numeric],
                        )
                        .await;
                } else {
                    let _ = client
                        .execute(
                            "UPDATE units SET occupancy_status = 'VACANT' WHERE id = $1",
                            &[&unit_numeric],
                        )
                        .await;
                }

                // Fetch person details
                let person_row = client
                    .query_one("SELECT full_name, phone, email FROM persons WHERE id = $1", &[&target_person_id])
                    .await
                    .map_err(|e| e.to_string())?;

                return Ok(crate::models::OccupancyHistoryItem {
                    id: occ_id,
                    unit_id: unit_numeric,
                    person_id: target_person_id,
                    person_name: person_row.get(0),
                    person_phone: person_row.get(1),
                    person_email: person_row.get(2),
                    role: occ_role.to_string(),
                    start_date: chrono::Utc::now().format("%Y-%m-%d").to_string(),
                    end_date: Some(chrono::Utc::now().format("%Y-%m-%d").to_string()),
                    is_active: false,
                    exit_balance,
                    notes: notes_val,
                    created_at: chrono::Utc::now(),
                });
            }
        }

        Err("Database connection unavailable".to_string())
    }

    pub async fn move_in_resident(
        &self,
        site_id: &str,
        unit_id: &str,
        req: crate::models::MoveInResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        let _site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id.strip_prefix("unit-").and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id.strip_prefix("d-").and_then(|s| s.parse::<i64>().ok())
                } else {
                    None
                }
            })
            .ok_or_else(|| format!("Invalid unit ID: {}", unit_id))?;

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                // Resolve or create person
                let person_id: i64 = if let Some(pid) = req.person_id {
                    pid
                } else if let Some(ref email) = req.email {
                    let clean_email = email.trim().to_lowercase();
                    let existing = client
                        .query_opt("SELECT id FROM persons WHERE LOWER(email) = $1", &[&clean_email])
                        .await
                        .ok()
                        .flatten();
                    if let Some(p) = existing {
                        p.get(0)
                    } else {
                        let full_name = req.full_name.clone().unwrap_or_else(|| "New Resident".to_string());
                        let phone = req.phone.clone();
                        let p_role = req.role.to_uppercase();
                        let p_type = if p_role == "TENANT" { "KAT_SAKINI" } else { "KAT_MALIKI" };
                        let row = client
                            .query_one(
                                "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, $4) RETURNING id",
                                &[&full_name, &phone, &clean_email, &p_type],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                        row.get(0)
                    }
                } else {
                    return Err("Either person_id or email must be provided".to_string());
                };

                // Close any existing active occupancy for this unit
                let _ = client
                    .execute(
                        "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE WHERE unit_id = $1 AND is_active = true",
                        &[&unit_numeric],
                    )
                    .await;

                let occ_role = if req.role.to_uppercase() == "TENANT" { "TENANT" } else { "OWNER" };
                let occ_status = if occ_role == "TENANT" { "TENANT_OCCUPIED" } else { "OWNER_OCCUPIED" };

                // Insert into unit_occupancies
                let notes_val = req.notes.clone();
                let occ_row = client
                    .query_one(
                        r#"
                        INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                        VALUES ($1, $2, $3, CURRENT_DATE, true, 0.00, $4)
                        RETURNING id, start_date::text, created_at
                        "#,
                        &[&unit_numeric, &person_id, &occ_role, &notes_val],
                    )
                    .await
                    .map_err(|e| e.to_string())?;

                let occ_id: i64 = occ_row.get(0);
                let start_date_str: String = occ_row.get(1);
                let created_at: DateTime<Utc> = occ_row.get(2);

                // Update unit
                if occ_role == "TENANT" {
                    let _ = client
                        .execute(
                            "UPDATE units SET tenant_person_id = $1, occupancy_status = $2 WHERE id = $3",
                            &[&person_id, &occ_status, &unit_numeric],
                        )
                        .await;
                } else {
                    let _ = client
                        .execute(
                            "UPDATE units SET owner_person_id = $1, occupancy_status = $2 WHERE id = $3",
                            &[&person_id, &occ_status, &unit_numeric],
                        )
                        .await;
                }

                // Fetch person details
                let person_row = client
                    .query_one("SELECT full_name, phone, email FROM persons WHERE id = $1", &[&person_id])
                    .await
                    .map_err(|e| e.to_string())?;

                return Ok(crate::models::OccupancyHistoryItem {
                    id: occ_id,
                    unit_id: unit_numeric,
                    person_id,
                    person_name: person_row.get(0),
                    person_phone: person_row.get(1),
                    person_email: person_row.get(2),
                    role: occ_role.to_string(),
                    start_date: start_date_str,
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: notes_val,
                    created_at,
                });
            }
        }

        Err("Database connection unavailable".to_string())
    }

    pub async fn get_unit_occupancy_history(
        &self,
        _site_id: &str,
        unit_id: &str,
    ) -> Result<Vec<crate::models::OccupancyHistoryItem>, String> {
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id.strip_prefix("unit-").and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id.strip_prefix("d-").and_then(|s| s.parse::<i64>().ok())
                } else {
                    None
                }
            })
            .ok_or_else(|| format!("Invalid unit ID: {}", unit_id))?;

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let query = r#"
                    SELECT 
                        uo.id,
                        uo.unit_id,
                        uo.person_id,
                        p.full_name,
                        p.phone,
                        p.email,
                        uo.occupancy_type,
                        uo.start_date::text,
                        uo.end_date::text,
                        uo.is_active,
                        uo.exit_balance,
                        uo.notes,
                        uo.created_at
                    FROM unit_occupancies uo
                    JOIN persons p ON uo.person_id = p.id
                    WHERE uo.unit_id = $1
                    ORDER BY uo.start_date DESC, uo.id DESC
                "#;
                if let Ok(rows) = client.query(query, &[&unit_numeric]).await {
                    let items = rows
                        .into_iter()
                        .map(|r| crate::models::OccupancyHistoryItem {
                            id: r.get(0),
                            unit_id: r.get(1),
                            person_id: r.get(2),
                            person_name: r.get(3),
                            person_phone: r.get(4),
                            person_email: r.get(5),
                            role: r.get(6),
                            start_date: r.get(7),
                            end_date: r.get(8),
                            is_active: r.get(9),
                            exit_balance: r.get(10),
                            notes: r.get(11),
                            created_at: r.get(12),
                        })
                        .collect::<Vec<_>>();
                    if !items.is_empty() {
                        return Ok(items);
                    }
                }
            }
        }

        let inner = self.state.inner.read().await;
        if let Some(items) = inner
            .unit_occupancies
            .get(unit_id)
            .or_else(|| inner.unit_occupancies.get(&unit_numeric.to_string()))
            .or_else(|| inner.unit_occupancies.get(&format!("unit-{}", unit_numeric)))
            .or_else(|| inner.unit_occupancies.get(&format!("d-{}", unit_numeric)))
        {
            return Ok(items.clone());
        }
        Ok(Vec::new())
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

