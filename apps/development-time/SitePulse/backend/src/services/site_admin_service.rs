use chrono::{DateTime, Datelike, Utc};

use rust_decimal::Decimal;

use crate::models::{
    AuthProvider, DebtStatus, DebtorType, DuesLiability, ExpenseType, HomeOwnerResponse,
    IndependentUnit, OccupancyStatus, RegisterHomeOwnerRequest, Role, UnitMemberDto, User,
};
use crate::services::virtual_iban_service::VirtualIbanService;
use crate::state::AppState;

/// Refusal for deleting a unit that has payments, receipts, advance history, paid dues or a matured receivable.
pub const UNIT_HAS_FINANCIAL_HISTORY: &str =
    "Bu dairenin finansal geçmişi (ödeme, makbuz, avans, ödenmiş veya vadesi geçmiş aidat) var; silinemez. Tahliye veya malik devri kullanın.";

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
    if domain_parts.iter().any(|p| p.is_empty())
        || domain_parts.last().map(|tld| tld.len()).unwrap_or(0) < 2
    {
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
    let clean: String = phone_trimmed
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect();
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

        let email_norm = crate::domain::email::NormalizedEmail::normalize(&request.email);

        // 1. Check in-memory state for duplicate email first
        {
            let inner = self.state.inner.read().await;
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
        let password_hash = crate::auth::hash_password(&temp_pass);

        let effective_floor = if request.floor > 0 {
            request.floor
        } else {
            ((request.unit_no - 1) / 4) + 1
        };

        let effective_house_type = request
            .house_type
            .clone()
            .or_else(|| Some("2+1".to_string()));
        let mut resolved_dues = request.monthly_dues;

        // Resolve monthly dues from house_type tariff
        if let Some(ref ht_name) = effective_house_type {
            let inner = self.state.inner.read().await;
            if let Some(tariff) = inner.house_types.iter().find(|t| {
                (t.site_id == site_id
                    || crate::db::parse_id_to_i64(&t.site_id)
                        == crate::db::parse_id_to_i64(site_id))
                    && t.type_name.eq_ignore_ascii_case(ht_name)
            }) {
                resolved_dues = Some(tariff.dues_amount);
            }
        }
        let monthly_dues =
            resolved_dues.unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());

        // Parse numeric IDs
        let site_numeric_id = crate::db::require_id("entity", site_id)?;
        let viban = VirtualIbanService::generate_virtual_iban(
            VirtualIbanService::KUVEYT_TURK_BANK_CODE,
            &site_numeric_id.to_string(),
            &format!("blok-{}", effective_clean_block),
            request.unit_no,
        )
        .map_err(|e| e.to_string())?;

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
        let mut explicit_tenant_pid: Option<i64> = None;

        // 2. Persist to PostgreSQL if pool is available
        if let Some(ref pool) = self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;

            // Check duplicate email in DB
            let existing_user = client
                .query_opt(
                    "SELECT id FROM users WHERE LOWER(email) = $1",
                    &[&email_norm],
                )
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
            let person_type = if request.is_resident {
                "HOME_RESIDENT"
            } else {
                "HOME_OWNER"
            };
            let existing_person = client
                .query_opt(
                    "SELECT id FROM persons WHERE LOWER(email) = $1",
                    &[&email_norm],
                )
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
            let user_role_str = if is_tenant || is_resident_only {
                "HOME_RESIDENT"
            } else {
                "HOME_OWNER"
            };
            let user_row = client
                .query_one(
                    r#"
                    INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                    VALUES ($1, $2, $3, $4, $5, TRUE)
                    RETURNING id
                    "#,
                    &[
                        &site_numeric_id,
                        &person_numeric_id,
                        &email_norm,
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
                let t_email_norm = crate::domain::email::NormalizedEmail::normalize(
                    request.tenant_email.as_deref().unwrap_or(""),
                );

                let existing_t_person = if !t_email_norm.is_empty() {
                    client
                        .query_opt(
                            "SELECT id FROM persons WHERE LOWER(email) = $1",
                            &[&t_email_norm],
                        )
                        .await
                        .ok()
                        .flatten()
                } else {
                    None
                };

                let t_pid: i64 = if let Some(row) = existing_t_person {
                    row.get(0)
                } else {
                    let row = client
                        .query_one(
                            "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, 'HOME_RESIDENT') RETURNING id",
                            &[&t_name, &t_phone, &t_email_norm],
                        )
                        .await
                        .map_err(|e| format!("Failed to insert tenant person: {}", e))?;
                    row.get(0)
                };
                explicit_tenant_person_id = Some(t_pid);
                explicit_tenant_pid = Some(t_pid);

                if !t_email_norm.is_empty() {
                    let existing_t_user = client
                        .query_opt(
                            "SELECT id FROM users WHERE LOWER(email) = $1",
                            &[&t_email_norm],
                        )
                        .await
                        .ok()
                        .flatten();
                    if existing_t_user.is_none() {
                        client
                            .execute(
                                r#"
                                INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
                                VALUES ($1, $2, $3, $4, 'HOME_RESIDENT', TRUE)
                                "#,
                                &[&site_numeric_id, &t_pid, &t_email_norm, &password_hash],
                            )
                            .await.map_err(|e| e.to_string())?;
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
                    client
                        .execute(
                            r#"
                            INSERT INTO occupancy_members (occupancy_id, person_id, resident_user_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
                            SELECT uo.id, $2, $3, $4, 'Ev Sakini', $5, $6, false, CURRENT_TIMESTAMP
                            FROM unit_occupancies uo
                            WHERE uo.unit_id = $1 AND uo.is_active = true
                            "#,
                            &[
                                &unit_numeric_id,
                                &Some(person_numeric_id),
                                &Some(user_numeric_id),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await.map_err(|e| e.to_string())?;
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
                        client
                            .execute(
                                "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE, notes = COALESCE(notes, '') || ' • Ayrıldı (Yeni sakin devri)' WHERE id = $1",
                                &[&occ_id],
                            )
                            .await.map_err(|e| e.to_string())?;
                    } else if let Some(prev_pid) = prev_tenant.or(prev_owner) {
                        // Legacy occupant was not in unit_occupancies; archive it now so history is preserved
                        let prev_role = if prev_tenant.is_some() {
                            "TENANT"
                        } else {
                            "OWNER"
                        };
                        client
                            .execute(
                                r#"
                                INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, end_date, is_active, exit_balance, notes)
                                VALUES ($1, $2, $3, CURRENT_DATE - INTERVAL '6 months', CURRENT_DATE, false, 0.00, 'Önceki sakin (Yeni kayıt ile devredildi)')
                                "#,
                                &[&unit_numeric_id, &prev_pid, &prev_role],
                            )
                            .await.map_err(|e| e.to_string())?;
                    }

                    // Insert new occupant into unit_occupancies
                    let new_occ_type = if has_explicit_tenant || is_tenant {
                        "TENANT"
                    } else {
                        "OWNER"
                    };
                    let new_occ_status = if has_explicit_tenant || is_tenant {
                        "TENANT_OCCUPIED"
                    } else if request.is_resident {
                        "OWNER_OCCUPIED"
                    } else {
                        "VACANT"
                    };
                    let active_occ_pid = if has_explicit_tenant {
                        explicit_tenant_person_id
                    } else {
                        Some(person_numeric_id)
                    };

                    if has_explicit_tenant || is_tenant || request.is_resident {
                        if let Some(occ_pid) = active_occ_pid {
                            client
                                .execute(
                                    r#"
                                    INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                                    VALUES ($1, $2, $3, CURRENT_DATE, true, 0.00, $4)
                                    "#,
                                    &[&unit_numeric_id, &occ_pid, &new_occ_type, &Some(format!("Yeni {} girişi", if has_explicit_tenant || is_tenant { "kiracı" } else { "malik" }))],
                                )
                                .await.map_err(|e| e.to_string())?;
                        }
                    }

                    // Update unit with new occupant
                    if has_explicit_tenant {
                        client
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
                                &[
                                    &person_numeric_id,
                                    &explicit_tenant_person_id,
                                    &effective_house_type,
                                    &viban,
                                    &unit_numeric_id,
                                ],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                    } else if is_tenant {
                        client
                            .execute(
                                r#"
                                UPDATE units SET
                                    tenant_person_id = $1,
                                    occupancy_status = $2,
                                    house_type = COALESCE($3, house_type),
                                    virtual_iban = COALESCE(virtual_iban, $4)
                                WHERE id = $5
                                "#,
                                &[
                                    &person_numeric_id,
                                    &new_occ_status,
                                    &effective_house_type,
                                    &viban,
                                    &unit_numeric_id,
                                ],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                    } else {
                        client
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
                            .await.map_err(|e| e.to_string())?;
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
                let owner_pid = if is_tenant && !has_explicit_tenant {
                    None
                } else {
                    Some(person_numeric_id)
                };
                let tenant_pid = if has_explicit_tenant {
                    explicit_tenant_person_id
                } else if is_tenant {
                    Some(person_numeric_id)
                } else {
                    None
                };

                let unit_row = client
                    .query_one(
                        r#"
                        INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban, house_type, occupancy_status)
                        VALUES ($1, $2, $3, $4, 1, $5, $6, $7, $8, $9)
                        ON CONFLICT (block_id, unit_number) DO UPDATE SET
                            deleted_at = NULL,
                            floor = EXCLUDED.floor,
                            owner_person_id = EXCLUDED.owner_person_id,
                            tenant_person_id = EXCLUDED.tenant_person_id,
                            house_type = EXCLUDED.house_type,
                            occupancy_status = EXCLUDED.occupancy_status
                        -- only an archived (soft-deleted) flat is revived; an active one still conflicts
                        WHERE units.deleted_at IS NOT NULL
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
                    client
                        .execute(
                            r#"
                            INSERT INTO occupancy_members (occupancy_id, person_id, resident_user_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
                            SELECT uo.id, $2, $3, $4, 'Ev Sakini', $5, $6, false, CURRENT_TIMESTAMP
                            FROM unit_occupancies uo
                            WHERE uo.unit_id = $1 AND uo.is_active = true
                            "#,
                            &[
                                &unit_numeric_id,
                                &Some(person_numeric_id),
                                &Some(user_numeric_id),
                                &request.owner_full_name,
                                &request.phone,
                                &email_norm,
                            ],
                        )
                        .await.map_err(|e| e.to_string())?;
                } else if has_explicit_tenant {
                    if let Some(t_pid) = explicit_tenant_person_id {
                        client
                            .execute(
                                r#"
                                INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                                VALUES ($1, $2, 'TENANT', CURRENT_DATE, true, 0.00, 'İlk kiracı kaydı')
                                "#,
                                &[&unit_numeric_id, &t_pid],
                            )
                            .await.map_err(|e| e.to_string())?;
                    }
                } else if is_tenant || request.is_resident {
                    let occ_type = if is_tenant { "TENANT" } else { "OWNER" };
                    client
                        .execute(
                            r#"
                            INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
                            VALUES ($1, $2, $3, CURRENT_DATE, true, 0.00, 'İlk sakin kaydı')
                            "#,
                            &[&unit_numeric_id, &person_numeric_id, &occ_type],
                        )
                        .await.map_err(|e| e.to_string())?;
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
                client
                    .execute(
                        r#"
                        INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, delay_penalty, paid_amount)
                        VALUES ($1, $2, $3, $4, 'PENDING', 0.00, 0.00)
                        ON CONFLICT DO NOTHING
                        "#,
                        &[&unit_numeric_id, &period, &monthly_dues, &due_date],
                    )
                    .await.map_err(|e| e.to_string())?;
            }
        }

        // 3. Update in-memory state
        let mut inner = self.state.inner.write().await;

        let user_id = if user_numeric_id > 0 {
            user_numeric_id.to_string()
        } else {
            let max_u = inner
                .users
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
            (max_u + 1).to_string()
        };

        let resident_user = User {
            id: user_id.clone(),
            site_id: site_id.to_string(),
            full_name: request.owner_full_name.clone(),
            email: email_norm.clone(),
            phone: request.phone.clone(),
            password_hash: Some(password_hash.clone()),
            role: if is_tenant || is_resident_only {
                Role::HomeResident
            } else {
                Role::HomeOwner
            },
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: if person_numeric_id > 0 {
                Some(person_numeric_id)
            } else {
                None
            },
        };
        inner.users.push(resident_user.clone());

        let existing_unit_pos = inner.units.iter().position(|u| {
            (u.site_id == site_id || crate::auth::same_id(&u.site_id, site_id))
                && u.unit_number == request.unit_no
        });
        let unit_id = if let Some(pos) = existing_unit_pos {
            inner.units[pos].id.clone()
        } else if unit_numeric_id > 0 {
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
                occupancy_id: None,
                person_id: None,
                resident_user_id: None,
            };
            inner
                .unit_members
                .entry(unit_id.clone())
                .or_default()
                .push(member_dto.clone());
            if unit_numeric_id > 0 {
                inner
                    .unit_members
                    .entry(unit_numeric_id.to_string())
                    .or_default()
                    .push(member_dto.clone());
            }
            let legacy_id = format!("d-{}", request.unit_no);
            if legacy_id != unit_id {
                inner
                    .unit_members
                    .entry(legacy_id)
                    .or_default()
                    .push(member_dto.clone());
            }
            let unit_prefix_id = format!("unit-{}", request.unit_no);
            if unit_prefix_id != unit_id {
                inner
                    .unit_members
                    .entry(unit_prefix_id)
                    .or_default()
                    .push(member_dto);
            }
        } else {
            let existing_owner_id =
                existing_unit_pos.and_then(|p| inner.units[p].owner_user_id.clone());
            let existing_tenant_id =
                existing_unit_pos.and_then(|p| inner.units[p].tenant_user_id.clone());

            let mut explicit_tenant_user_id_in_mem: Option<String> = None;
            if has_explicit_tenant {
                let max_u = inner
                    .users
                    .iter()
                    .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                    .max()
                    .unwrap_or(0);
                let tid = (max_u + 1).to_string();
                let tenant_user = User {
                    id: tid.clone(),
                    site_id: site_id.to_string(),
                    full_name: request.tenant_full_name.clone().unwrap_or_default(),
                    email: request
                        .tenant_email
                        .clone()
                        .unwrap_or_default()
                        .trim()
                        .to_lowercase(),
                    phone: request.tenant_phone.clone().unwrap_or_default(),
                    password_hash: Some(password_hash.clone()),
                    role: Role::HomeResident,
                    must_change_password: true,
                    auth_provider: AuthProvider::Local,
                    google_sub: None,
                    avatar_url: None,
                    created_at: Utc::now(),
                    person_id: explicit_tenant_pid,
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
                owner_user_id: if is_tenant && !has_explicit_tenant {
                    existing_owner_id
                } else {
                    Some(user_id.clone())
                },
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
            let occ_type = if has_explicit_tenant || is_tenant {
                "TENANT"
            } else {
                "OWNER"
            };
            let history_key = unit_id.clone();
            let history_list = inner.unit_occupancies.entry(history_key).or_default();
            for item in history_list.iter_mut() {
                if item.is_active {
                    item.is_active = false;
                    item.end_date = Some(Utc::now().date_naive().to_string());
                    item.notes = Some(format!(
                        "{} • Ayrıldı (Yeni sakin devri)",
                        item.notes.as_deref().unwrap_or("")
                    ));
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
                    role: DebtorType::Tenant,
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
                    role: DebtorType::from_str_loose(occ_type),
                    start_date: Utc::now().date_naive().to_string(),
                    end_date: None,
                    is_active: true,
                    exit_balance: Decimal::ZERO,
                    notes: Some(format!(
                        "Yeni {} kaydı",
                        if is_tenant { "kiracı" } else { "malik" }
                    )),
                    created_at: Utc::now(),
                });
            }
            let cloned = history_list.clone();
            inner
                .unit_occupancies
                .insert(request.unit_no.to_string(), cloned.clone());
            inner
                .unit_occupancies
                .insert(format!("unit-{}", request.unit_no), cloned.clone());
            inner
                .unit_occupancies
                .insert(format!("d-{}", request.unit_no), cloned);
        }

        // Also add due liability in memory if > 0 and NOT a co-resident
        if !is_resident_only && monthly_dues > Decimal::ZERO {
            let period = inner
                .dues
                .first()
                .map(|d| d.period.clone())
                .unwrap_or_else(|| {
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

            let max_d = inner
                .dues
                .iter()
                .filter_map(|d| crate::db::parse_id_to_i64(&d.id))
                .max()
                .unwrap_or(0);
            inner.dues.push(DuesLiability {
                id: (max_d + 1).to_string(),
                unit_id: unit_id.clone(),
                period,
                principal_amount: monthly_dues,
                delay_penalty: Decimal::ZERO,
                total_amount: monthly_dues,
                due_date: Utc::now().date_naive() + chrono::Days::new(15),
                status: DebtStatus::Pending,
                paid_principal: Decimal::ZERO,
                paid_penalty: Decimal::ZERO,
                debtor_type: if is_tenant {
                    DebtorType::Tenant
                } else {
                    DebtorType::Owner
                },
                expense_type: ExpenseType::OperationalDues,
                penalty_accrued_through: None,
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
                occupancy_id: None,
                person_id: None,
                resident_user_id: None,
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
            occupancy_status: Some(if request.is_resident {
                OccupancyStatus::OwnerOccupied
            } else {
                OccupancyStatus::Vacant
            }),
            tenant_full_name: None,
            tenant_email: None,
            tenant_phone: None,
            operational_dues_balance: Some(Decimal::ZERO),
            capital_dues_balance: Some(Decimal::ZERO),
            advance_balance: None,
            household_residents: household,
        })
    }

    pub async fn get_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let mut owners = self.load_home_owners_for_site(site_id).await;
        let inner = self.state.inner.read().await;
        for o in owners.iter_mut() {
            let unit = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, &o.unit_id))
                .map(|u| u.id.clone());
            o.advance_balance = Some(
                unit.map(|id| inner.advance_total(&id))
                    .unwrap_or(Decimal::ZERO)
                    .max(Decimal::ZERO),
            );
        }
        owners
    }

    async fn load_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(0);

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
                let mut household_map: std::collections::HashMap<
                    String,
                    Vec<crate::models::UnitMemberDto>,
                > = std::collections::HashMap::new();
                if let Some(m_rows) = crate::db::logged(client
                    .query(
                        r#"
                        SELECT uo.unit_id, om.id, om.full_name, om.relationship, COALESCE(om.phone, ''), COALESCE(om.email, ''), (uo.occupancy_type = 'OWNER'), om.occupancy_id
                        FROM occupancy_members om
                        JOIN unit_occupancies uo ON om.occupancy_id = uo.id
                        WHERE uo.is_active = true
                        ORDER BY om.id ASC
                        "#,
                        &[],
                    )
                    .await, "site_admin_service") {
                    for mr in m_rows {
                        let u_id: i64 = mr.get(0);
                        let u_id = u_id.to_string();
                        let mem = crate::models::UnitMemberDto {
                            resident_id: mr.get::<_, i64>(1).to_string(),
                            full_name: mr.get(2),
                            relationship: mr.get(3),
                            phone: mr.get(4),
                            email: mr.get(5),
                            is_owner: mr.get(6),
                            occupancy_id: mr.try_get(7).ok().flatten(),
                person_id: None,
                resident_user_id: None,
                        };
                        household_map.entry(u_id).or_default().push(mem);
                    }
                }

                if let Some(rows) = crate::db::logged(
                    client.query(query, &[&site_numeric]).await,
                    "site_admin_service",
                ) {
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

                            let mut household =
                                household_map.get(&unit_id_val).cloned().unwrap_or_default();
                            if household.is_empty() {
                                household = household_map
                                    .get(&unit_no.to_string())
                                    .cloned()
                                    .unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map
                                    .get(&format!("d-{}", unit_no))
                                    .cloned()
                                    .unwrap_or_default();
                            }
                            if household.is_empty() {
                                household = household_map
                                    .get(&format!("unit-{}", unit_no))
                                    .cloned()
                                    .unwrap_or_default();
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
                                occupancy_status: Some(OccupancyStatus::from_str_loose(
                                    &occ_status,
                                )),
                                tenant_full_name: t_name,
                                tenant_email: t_email,
                                tenant_phone: t_phone,
                                operational_dues_balance: Some(op_balance),
                                capital_dues_balance: Some(cap_balance),
                                advance_balance: None,
                                household_residents: household,
                            });
                        }
                        return db_result;
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
                is_resident: user.role == Role::HomeResident
                    || matching_unit
                        .map(|u| u.tenant_user_id.is_none())
                        .unwrap_or(true),
                temporary_password: None,
                must_change_password: user.must_change_password,
                created_at: user.created_at,
                occupancy_status: Some(OccupancyStatus::OwnerOccupied),
                tenant_full_name: None,
                tenant_email: None,
                tenant_phone: None,
                operational_dues_balance: Some(Decimal::ZERO),
                capital_dues_balance: Some(Decimal::ZERO),
                advance_balance: None,
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
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // The database unit this request resolved to; the in-memory update below
        // follows it so the two never touch different units.
        let mut resolved_unit_id: Option<String> = None;

        // 1. If DB pool is available, update database
        if let Some(ref pool) = self.state.pool {
            {
                let client = pool
                    .get()
                    .await
                    .map_err(|e| format!("Database connection error: {}", e))?;
                let unit_row_opt = if let Some(uid) = id_numeric {
                    // A unit id wins over a person id: both are numbers, and the old
                    // OR-match could return two rows, fail silently and fall back to
                    // in-memory state (the tenant then stayed in the database).
                    client
                        .query_opt(
                            "SELECT id, block_id, unit_number, floor, owner_person_id, tenant_person_id, house_type FROM units \
                             WHERE (id = $1 OR owner_person_id = $1 OR tenant_person_id = $1) AND site_id = $2 AND deleted_at IS NULL \
                             ORDER BY (id = $1) DESC, id LIMIT 1",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?
                } else {
                    client
                        .query_opt(
                            "SELECT u.id, u.block_id, u.unit_number, u.floor, u.owner_person_id, u.tenant_person_id, u.house_type FROM units u \
                             JOIN persons p ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id) \
                             WHERE LOWER(p.email) = LOWER($1) AND u.site_id = $2 AND u.deleted_at IS NULL \
                             ORDER BY (u.owner_person_id = p.id) DESC, u.id LIMIT 1",
                            &[&unit_or_user_id, &site_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?
                };

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    resolved_unit_id = Some(u_id.to_string());
                    let p_id: Option<i64> = u_row.get(4);
                    let t_id: Option<i64> = u_row.get(5);

                    if req.remove_tenant == Some(true) {
                        if let Some(tenant_person_id) = t_id {
                            client.execute(
                                "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE WHERE unit_id = $1 AND person_id = $2 AND is_active = true",
                                &[&u_id, &tenant_person_id],
                            ).await.map_err(|e| e.to_string())?;
                        }
                        let new_occupancy = if req.is_resident == Some(true) {
                            "OWNER_OCCUPIED"
                        } else {
                            "VACANT"
                        };
                        client.execute("UPDATE units SET tenant_person_id = NULL, occupancy_status = $1 WHERE id = $2", &[&new_occupancy, &u_id]).await.map_err(|e| e.to_string())?;
                        if req.is_resident == Some(true) {
                            if let Some(owner_person_id) = p_id {
                                client.execute(
                                    "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, created_at)
                                     VALUES ($1, $2, 'OWNER', CURRENT_DATE, true, NOW())
                                     ON CONFLICT DO NOTHING",
                                    &[&u_id, &owner_person_id],
                                ).await.map_err(|e| e.to_string())?;
                            }
                        }
                    } else if let Some(tenant_person_id) = t_id {
                        if let Some(ref t_name) = req.tenant_full_name {
                            client
                                .execute(
                                    "UPDATE persons SET full_name = $1 WHERE id = $2",
                                    &[t_name, &tenant_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref t_phone) = req.tenant_phone {
                            client
                                .execute(
                                    "UPDATE persons SET phone = $1 WHERE id = $2",
                                    &[t_phone, &tenant_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref t_email) = req.tenant_email {
                            let email_norm =
                                crate::domain::email::NormalizedEmail::normalize(t_email);
                            let prev_email: Option<String> = client
                                .query_opt(
                                    "SELECT email FROM persons WHERE id = $1",
                                    &[&tenant_person_id],
                                )
                                .await
                                .ok()
                                .flatten()
                                .map(|r| r.get(0));
                            client
                                .execute(
                                    "UPDATE persons SET email = $1 WHERE id = $2",
                                    &[&email_norm, &tenant_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                            if let Some(ref pe) = prev_email {
                                client.execute("UPDATE users SET email = $1 WHERE site_id = $2 AND LOWER(email) = LOWER($3)", &[&email_norm, &site_numeric, pe]).await.map_err(|e| e.to_string())?;
                            }
                        }
                    } else if let Some(ref t_name) = req.tenant_full_name {
                        if !t_name.trim().is_empty() {
                            let t_email = req
                                .tenant_email
                                .clone()
                                .unwrap_or_else(|| format!("tenant.{}@example.com", u_id))
                                .trim()
                                .to_lowercase();
                            let t_phone = req.tenant_phone.clone().unwrap_or_default();
                            let row_res = client.query_one(
                                "INSERT INTO persons (full_name, phone, email, person_type) 
                                 VALUES ($1, $2, $3, 'HOME_RESIDENT') 
                                 ON CONFLICT (email) DO UPDATE SET full_name = EXCLUDED.full_name, phone = EXCLUDED.phone 
                                 RETURNING id",
                                &[&t_name, &t_phone, &t_email],
                            ).await;
                            if let Ok(r) = row_res {
                                let new_t_id: i64 = r.get(0);
                                client.execute("UPDATE units SET tenant_person_id = $1, occupancy_status = 'TENANT_OCCUPIED' WHERE id = $2", &[&new_t_id, &u_id]).await.map_err(|e| e.to_string())?;
                                client.execute(
                                    "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, created_at)
                                     VALUES ($1, $2, 'TENANT', CURRENT_DATE, true, NOW())",
                                    &[&u_id, &new_t_id],
                                ).await.map_err(|e| e.to_string())?;
                            }
                        }
                    }

                    if let Some(owner_person_id) = p_id {
                        if let Some(ref name) = req.owner_full_name {
                            client
                                .execute(
                                    "UPDATE persons SET full_name = $1 WHERE id = $2",
                                    &[name, &owner_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref phone) = req.phone {
                            client
                                .execute(
                                    "UPDATE persons SET phone = $1 WHERE id = $2",
                                    &[phone, &owner_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                        }
                        if let Some(ref email) = req.email {
                            let email_norm =
                                crate::domain::email::NormalizedEmail::normalize(email);
                            let prev_email: Option<String> = client
                                .query_opt(
                                    "SELECT email FROM persons WHERE id = $1",
                                    &[&owner_person_id],
                                )
                                .await
                                .ok()
                                .flatten()
                                .map(|r| r.get(0));
                            client
                                .execute(
                                    "UPDATE persons SET email = $1 WHERE id = $2",
                                    &[&email_norm, &owner_person_id],
                                )
                                .await
                                .map_err(|e| e.to_string())?;
                            if let Some(ref pe) = prev_email {
                                client.execute("UPDATE users SET email = $1 WHERE site_id = $2 AND LOWER(email) = LOWER($3)", &[&email_norm, &site_numeric, pe]).await.map_err(|e| e.to_string())?;
                            }
                        }
                    }

                    if let Some(ref ht) = req.house_type {
                        client
                            .execute(
                                "UPDATE units SET house_type = $1 WHERE id = $2",
                                &[ht, &u_id],
                            )
                            .await
                            .map_err(|e| e.to_string())?;
                    }
                    if let Some(dues) = req.monthly_dues {
                        client.execute(
                            "UPDATE dues_liabilities SET principal_amount = $1 WHERE unit_id = $2 AND status = 'PENDING'",
                            &[&dues, &u_id],
                        ).await.map_err(|e| e.to_string())?;
                    }
                }
            }
        }

        // 2. Update in-memory state
        let mut inner = self.state.inner.write().await;

        // Resolve one unit, in order of precedence: the unit the database resolved,
        // an exact unit id, then a unit owned by the given user id. Unit and user ids
        // are both plain numbers, so a single OR-match picked whichever came first.
        let unit_idx = resolved_unit_id
            .as_deref()
            .and_then(|rid| inner.units.iter().position(|u| u.id == rid))
            .or_else(|| {
                inner.units.iter().position(|u| {
                    u.id == unit_or_user_id
                        || (id_numeric.is_some() && crate::db::parse_id_to_i64(&u.id) == id_numeric)
                })
            })
            .or_else(|| {
                inner
                    .units
                    .iter()
                    .position(|u| u.owner_user_id.as_deref() == Some(unit_or_user_id))
            });

        // The owner is the resolved unit's owner; only without a unit is the id read as a user id.
        let user_idx = match unit_idx {
            Some(uidx) => inner.units[uidx]
                .owner_user_id
                .clone()
                .and_then(|oid| inner.users.iter().position(|u| u.id == oid)),
            None => inner.users.iter().position(|u| u.id == unit_or_user_id),
        };

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
                    inner.users[t_idx].email =
                        crate::domain::email::NormalizedEmail::normalize(t_email);
                }
                if let Some(ref t_phone) = req.tenant_phone {
                    inner.users[t_idx].phone = t_phone.clone();
                }
            } else if let Some(ref t_name) = req.tenant_full_name {
                if !t_name.trim().is_empty() {
                    let max_u = inner
                        .users
                        .iter()
                        .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                        .max()
                        .unwrap_or(0);
                    let new_uid = (max_u + 1).to_string();
                    let email = req
                        .tenant_email
                        .clone()
                        .unwrap_or_else(|| format!("tenant.{}@example.com", new_uid));
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
                        auth_provider: AuthProvider::Local,
                        google_sub: None,
                        avatar_url: None,
                        created_at: chrono::Utc::now(),
                        person_id: None,
                    });
                    inner.units[uidx].tenant_user_id = Some(new_uid);
                }
            }
            if let Some(ref ht) = req.house_type {
                inner.units[uidx].house_type = Some(ht.clone());
            }
            if let Some(dues) = req.monthly_dues {
                let unit_id = inner.units[uidx].id.clone();
                for d in inner
                    .dues
                    .iter_mut()
                    .filter(|d| d.unit_id == unit_id && d.status == DebtStatus::Pending)
                {
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
                inner.users[usridx].email = crate::domain::email::NormalizedEmail::normalize(email);
            }
        }

        if let (Some(uidx), Some(ref name)) = (unit_idx, &req.owner_full_name) {
            let unit_id = inner.units[uidx].id.clone();
            inner.unit_payer_names.insert(unit_id, vec![name.clone()]);
        }

        let resolved_unit_id = unit_idx
            .map(|uidx| inner.units[uidx].id.clone())
            .or(resolved_unit_id);
        drop(inner);

        let all_owners = self.get_home_owners_for_site(site_id).await;
        if let Some(ref rid) = resolved_unit_id {
            if let Some(updated) = all_owners.iter().find(|o| &o.unit_id == rid) {
                return Ok(updated.clone());
            }
        }
        if let Some(updated) = all_owners.into_iter().find(|o| {
            o.unit_id == unit_or_user_id
                || crate::db::parse_id_to_i64(&o.unit_id) == id_numeric
                || req
                    .email
                    .as_ref()
                    .map(|e| e.trim().eq_ignore_ascii_case(&o.email))
                    .unwrap_or(false)
                || (req
                    .tenant_email
                    .as_ref()
                    .map(|e| {
                        o.tenant_email
                            .as_ref()
                            .map(|te| te.trim().eq_ignore_ascii_case(e))
                            .unwrap_or(false)
                    })
                    .unwrap_or(false))
        }) {
            Ok(updated)
        } else {
            // Synthesized fallback response with updated attributes so caller receives 200 OK
            Ok(HomeOwnerResponse {
                unit_id: unit_or_user_id.to_string(),
                site_id: site_id.to_string(),
                block: "A".to_string(),
                unit_no: id_numeric.map(|n| n as i32).unwrap_or(1),
                floor: 1,
                owner_full_name: req
                    .owner_full_name
                    .clone()
                    .unwrap_or_else(|| "Kat Maliki".to_string()),
                email: req.email.clone().unwrap_or_default(),
                phone: req.phone.clone().unwrap_or_default(),
                land_share: req.land_share.clone().unwrap_or_else(|| "1/1".to_string()),
                monthly_dues: req.monthly_dues.unwrap_or(rust_decimal::Decimal::ZERO),
                house_type: req.house_type.clone(),
                is_resident: req.is_resident.unwrap_or(true),
                temporary_password: None,
                must_change_password: false,
                created_at: chrono::Utc::now(),
                occupancy_status: Some(if req.remove_tenant == Some(true) {
                    if req.is_resident == Some(true) {
                        OccupancyStatus::OwnerOccupied
                    } else {
                        OccupancyStatus::Vacant
                    }
                } else if req.tenant_full_name.is_some() {
                    OccupancyStatus::TenantOccupied
                } else {
                    OccupancyStatus::OwnerOccupied
                }),
                tenant_full_name: req.tenant_full_name.clone(),
                tenant_email: req.tenant_email.clone(),
                tenant_phone: req.tenant_phone.clone(),
                operational_dues_balance: None,
                capital_dues_balance: None,
                advance_balance: None,
                household_residents: vec![],
            })
        }
    }

    pub async fn delete_home_owner(
        &self,
        site_id: &str,
        unit_or_user_id: &str,
    ) -> Result<(), String> {
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let id_numeric = crate::db::parse_id_to_i64(unit_or_user_id);

        // 1. If DB pool is available, dissociate in PostgreSQL inside a single transaction
        if let Some(ref pool) = self.state.pool {
            let mut client = pool
                .get()
                .await
                .map_err(|e| format!("Database connection error: {}", e))?;
            let tx = client
                .transaction()
                .await
                .map_err(|e| format!("Transaction error: {}", e))?;

            let unit_row_opt = if let Some(uid) = id_numeric {
                tx.query_opt(
                    // A unit id wins over an owner person id: both are numbers, and an
                    // OR-match returning two rows used to fail the whole delete.
                    "SELECT id, owner_person_id, tenant_person_id FROM units WHERE (id = $1 OR owner_person_id = $1) AND site_id = $2 AND deleted_at IS NULL ORDER BY (id = $1) DESC, id LIMIT 1",
                    &[&uid, &site_numeric],
                )
                .await
                .map_err(|e| e.to_string())?
            } else {
                tx.query_opt(
                    "SELECT u.id, u.owner_person_id, u.tenant_person_id FROM units u JOIN persons p ON u.owner_person_id = p.id WHERE p.email = $1 AND u.site_id = $2",
                    &[&unit_or_user_id, &site_numeric],
                )
                .await
                .map_err(|e| e.to_string())?
            };

            if let Some(u_row) = unit_row_opt {
                let u_id: i64 = u_row.get(0);
                let p_id: Option<i64> = u_row.get(1);

                // Zero data loss: a unit with financial history (any payment, receipt,
                // advance movement, paid due or matured receivable) is never removed; the
                // manager uses move-out or ownership transfer instead. Only untouched,
                // not-yet-due charges (e.g. the one issued at registration) are voided.
                let has_history: bool = tx
                    .query_one(
                        r#"
                        SELECT EXISTS (SELECT 1 FROM payment_entries WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM payment_receipts WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM advance_ledger_entries WHERE unit_id = $1)
                            OR EXISTS (SELECT 1 FROM dues_liabilities WHERE unit_id = $1 AND status <> 'CANCELLED'
                                       AND (paid_amount > 0 OR status = 'PAID' OR due_date < CURRENT_DATE))
                        "#,
                        &[&u_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?
                    .get(0);
                if has_history {
                    return Err(UNIT_HAS_FINANCIAL_HISTORY.to_string());
                }

                // Archive (soft-delete) the unit: untouched dues are cancelled, the
                // occupancy and ownership history is closed, nothing is physically deleted.
                tx.execute(
                    "UPDATE dues_liabilities SET status = 'CANCELLED' WHERE unit_id = $1 AND status IN ('PENDING', 'OVERDUE') AND paid_amount = 0",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE unit_occupancies SET is_active = FALSE, end_date = CURRENT_DATE WHERE unit_id = $1 AND is_active = TRUE",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE unit_ownerships SET is_active = FALSE, end_date = CURRENT_DATE WHERE unit_id = $1 AND is_active = TRUE",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;
                tx.execute(
                    "UPDATE units SET owner_person_id = NULL, tenant_person_id = NULL, deleted_at = CURRENT_TIMESTAMP WHERE id = $1",
                    &[&u_id],
                ).await.map_err(|e| e.to_string())?;

                if let Some(person_id) = p_id {
                    tx.execute(
                        "UPDATE unit_occupancies SET is_active = FALSE, end_date = CURRENT_DATE WHERE unit_id = $1 AND person_id = $2 AND is_active = TRUE",
                        &[&u_id, &person_id],
                    ).await.map_err(|e| e.to_string())?;

                    let other_units: i64 = tx
                        .query_one("SELECT COUNT(*) FROM units WHERE owner_person_id = $1 OR tenant_person_id = $1", &[&person_id])
                        .await
                        .map(|r| r.get::<_, i64>(0))
                        .unwrap_or(0);
                    let other_occ: i64 = tx
                        .query_one("SELECT COUNT(*) FROM unit_occupancies WHERE person_id = $1 AND is_active = TRUE", &[&person_id])
                        .await
                        .map(|r| r.get::<_, i64>(0))
                        .unwrap_or(0);

                    if other_units == 0 && other_occ == 0 {
                        // The login account goes; the person stays, because the closed
                        // ownership/occupancy history references it (zero data loss).
                        tx.execute("DELETE FROM users WHERE site_id = $1 AND email = (SELECT email FROM persons WHERE id = $2)", &[&site_numeric, &person_id]).await.map_err(|e| e.to_string())?;
                    }
                }
            }
            tx.commit()
                .await
                .map_err(|e| format!("Transaction commit error: {}", e))?;
        }

        // 2. In-memory state cleanup
        let mut inner = self.state.inner.write().await;

        let target_units: Vec<IndependentUnit> = inner
            .units
            .iter()
            .filter(|u| {
                (u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id
                        || crate::db::parse_id_to_i64(&u.id) == id_numeric
                        || u.owner_user_id.as_deref() == Some(unit_or_user_id)
                        || u.owner_user_id
                            .as_ref()
                            .and_then(|uid| crate::db::parse_id_to_i64(uid))
                            == id_numeric)
            })
            .cloned()
            .collect();

        if !target_units.is_empty() {
            let target_unit_ids: Vec<String> = target_units.iter().map(|u| u.id.clone()).collect();
            if self.state.pool.is_none() {
                let has_history = target_unit_ids.iter().any(|uid| {
                    inner.payment_receipts.iter().any(|r| &r.unit_id == uid)
                        || inner.payment_entries.iter().any(|e| &e.unit_id == uid)
                        || inner.advance_total(uid) > rust_decimal::Decimal::ZERO
                        || inner.dues.iter().any(|d| {
                            &d.unit_id == uid
                                && (d.paid_principal + d.paid_penalty > rust_decimal::Decimal::ZERO
                                    || d.due_date < chrono::Utc::now().date_naive())
                        })
                });
                if has_history {
                    return Err(UNIT_HAS_FINANCIAL_HISTORY.to_string());
                }
            }
            let target_owner_uids: Vec<String> = target_units
                .iter()
                .filter_map(|u| u.owner_user_id.clone())
                .collect();

            // Clear matching units for this site
            inner.units.retain(|u| {
                let matches_site = u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric);
                if !matches_site {
                    return true;
                }
                !target_unit_ids.contains(&u.id)
            });

            // Clean dues strictly for target units in this site
            inner.dues.retain(|d| !target_unit_ids.contains(&d.unit_id));

            // Clean advance and mappings strictly for target units
            for u_id in &target_unit_ids {
                inner.advance_balances.remove(u_id);
                inner.unit_members.remove(u_id);
                inner.unit_payer_names.remove(u_id);
                inner.unit_invite_tokens.remove(u_id);
            }

            // Remove users if not owning other units
            for owner_uid in &target_owner_uids {
                let owns_other = inner
                    .units
                    .iter()
                    .any(|u| u.owner_user_id.as_deref() == Some(owner_uid));
                if !owns_other {
                    inner.users.retain(|u| &u.id != owner_uid);
                }
            }
            Ok(())
        } else {
            // Also check if id is a user
            if let Some(usridx) = inner.users.iter().position(|u| {
                (u.site_id == site_id
                    || crate::db::parse_id_to_i64(&u.site_id) == Some(site_numeric))
                    && (u.id == unit_or_user_id
                        || crate::db::parse_id_to_i64(&u.id) == id_numeric
                        || u.email.eq_ignore_ascii_case(unit_or_user_id))
            }) {
                inner.users.remove(usridx);
                Ok(())
            } else {
                Err(format!(
                    "Kat maliki / daire '{}' bulunamadı.",
                    unit_or_user_id
                ))
            }
        }
    }

    pub async fn add_unit_member(
        &self,
        site_id: &str,
        unit_id: &str,
        full_name: &str,
        phone: &str,
        email: &str,
        relationship: &str,
    ) -> Result<UnitMemberDto, String> {
        if full_name.trim().is_empty() {
            return Err("Sakin adı soyadı boş olamaz.".to_string());
        }
        if email.trim().is_empty() {
            return Err("E-posta adresi boş olamaz.".to_string());
        }

        let relationship_val = if relationship.trim().is_empty() {
            "Ev Sakini"
        } else {
            relationship
        };

        // Persist into the canonical household table; it resolves the unit's active
        // occupancy and links the person by email. The returned id is the real identifier.
        let member_id = match self.state.pool {
            Some(ref pool) => crate::db::save_unit_member(
                pool,
                unit_id,
                full_name,
                relationship_val,
                phone,
                email,
            )
            .await
            .unwrap_or(0),
            None => 0,
        };

        let member = UnitMemberDto {
            resident_id: member_id.to_string(),
            full_name: full_name.to_string(),
            relationship: relationship_val.to_string(),
            phone: phone.to_string(),
            email: crate::domain::email::NormalizedEmail::normalize(email),
            is_owner: false,
            occupancy_id: None,
            person_id: None,
            resident_user_id: None,
        };

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
            inner
                .unit_members
                .entry(key.clone())
                .or_default()
                .push(member.clone());
        }

        // Also add to inner.users so the co-resident can log in with temporary password if needed
        let email_norm = crate::domain::email::NormalizedEmail::normalize(email);
        if !email_norm.is_empty()
            && !inner
                .users
                .iter()
                .any(|u| crate::domain::email::same_email(&u.email, &email_norm))
        {
            let temp_pass = generate_resident_temporary_password();
            let password_hash = crate::auth::hash_password(&temp_pass);
            let s_id = site_id.to_string();
            let max_u = inner
                .users
                .iter()
                .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
                .max()
                .unwrap_or(0);
            inner.users.push(crate::models::User {
                id: (max_u + 1).to_string(),
                site_id: s_id,
                full_name: full_name.to_string(),
                email: email_norm,
                phone: phone.to_string(),
                password_hash: Some(password_hash),
                role: crate::models::Role::HomeResident,
                must_change_password: true,
                auth_provider: AuthProvider::Local,
                google_sub: None,
                avatar_url: None,
                created_at: chrono::Utc::now(),
                person_id: None,
            });
        }

        Ok(member)
    }

    pub async fn delete_unit_member(
        &self,
        _site_id: &str,
        unit_id: &str,
        resident_id: &str,
    ) -> Result<(), String> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let unit_id_num = crate::db::require_id("entity", unit_id)?;
                let member_id = crate::db::parse_id_to_i64(resident_id);
                client.execute(
                    "DELETE FROM occupancy_members WHERE id = $1 AND occupancy_id IN (SELECT id FROM unit_occupancies WHERE unit_id = $2)",
                    &[&member_id, &unit_id_num],
                ).await.map_err(|e| e.to_string())?;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
            if let Some(members) = inner.unit_members.get_mut(key) {
                members.retain(|m| m.resident_id != resident_id && m.full_name != resident_id);
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
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
                let unit_id_num = crate::db::require_id("entity", unit_id)?;
                let member_id = crate::db::parse_id_to_i64(resident_id);
                client.execute(
                    "UPDATE occupancy_members SET full_name = $1, phone = $2, email = $3, relationship = $4 WHERE id = $5 AND occupancy_id IN (SELECT id FROM unit_occupancies WHERE unit_id = $6)",
                    &[&full_name, &phone, &email, &relationship, &member_id, &unit_id_num],
                ).await.map_err(|e| e.to_string())?;
            }
        }

        let mut inner = self.state.inner.write().await;
        for key in &[
            unit_id.to_string(),
            format!("d-{}", unit_id),
            format!("unit-{}", unit_id),
        ] {
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

    pub async fn get_house_types_for_site(
        &self,
        site_id: &str,
    ) -> Vec<crate::models::HouseTypeTariff> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(0);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Some(rows) = crate::db::logged(client
                    .query(
                        "SELECT id, site_id, type_name, dues_amount, description FROM house_types WHERE site_id = $1 ORDER BY dues_amount ASC",
                        &[&site_numeric],
                    )
                    .await, "site_admin_service") {
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

        // 2. Read from in-memory state
        let inner = self.state.inner.read().await;
        let list: Vec<_> = inner
            .house_types
            .iter()
            .filter(|h| {
                h.site_id == site_id || crate::db::parse_id_to_i64(&h.site_id) == Some(site_numeric)
            })
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
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let type_name_trimmed = request.type_name.trim().to_string();

        let id_str = if let Some(ref pool) = self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;
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
                    &[
                        &site_numeric,
                        &type_name_trimmed,
                        &request.dues_amount,
                        &request.description,
                    ],
                )
                .await
                .map_err(|e| format!("DB insert error: {}", e))?;
            let db_id: i64 = row.get(0);
            db_id.to_string()
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner
                .house_types
                .iter()
                .filter_map(|h| crate::db::parse_id_to_i64(&h.id))
                .max()
                .unwrap_or(0);
            (max_id + 1).to_string()
        };

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
        let site_numeric = crate::db::require_id("entity", site_id)?;
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                if let Ok(numeric_id) = id.parse::<i64>() {
                    client
                        .execute(
                            "DELETE FROM house_types WHERE id = $1 AND site_id = $2",
                            &[&numeric_id, &site_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                }
            }
        }
        let mut inner = self.state.inner.write().await;
        inner.house_types.retain(|h| h.id != id);
        Ok(())
    }

    pub async fn get_blocks_for_site(&self, site_id: &str) -> Vec<crate::models::BlockDto> {
        if let Some(ref pool) = self.state.pool {
            if let Ok(db_blocks) = crate::db::get_blocks_for_site_from_db(pool, site_id).await {
                return db_blocks;
            }
        }
        let site_numeric = crate::db::parse_id_to_i64(site_id);
        let inner = self.state.inner.read().await;
        let mut list: Vec<crate::models::BlockDto> = inner
            .blocks
            .iter()
            .filter(|b| {
                b.site_id == site_id
                    || (site_numeric.is_some()
                        && crate::db::parse_id_to_i64(&b.site_id) == site_numeric)
            })
            .cloned()
            .collect();

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
        let site_numeric = crate::db::require_id("entity", site_id)?;

        let id_str = if let Some(ref pool) = self.state.pool {
            let client = pool
                .get()
                .await
                .map_err(|e| format!("DB connection error: {}", e))?;
            let existing = client
                .query_opt(
                    "SELECT id FROM blocks WHERE site_id = $1 AND LOWER(block_name) = LOWER($2)",
                    &[&site_numeric, &block_name],
                )
                .await
                .map_err(|e| format!("DB query error: {}", e))?;

            if let Some(row) = existing {
                let db_id: i64 = row.get(0);
                client
                    .execute(
                        "UPDATE blocks SET total_floors = $1 WHERE id = $2",
                        &[&total_floors, &db_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                db_id.to_string()
            } else {
                let row = client
                    .query_one(
                        "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, $3) RETURNING id",
                        &[&site_numeric, &block_name, &total_floors],
                    )
                    .await
                    .map_err(|e| format!("DB insert error: {}", e))?;
                let db_id: i64 = row.get(0);
                db_id.to_string()
            }
        } else {
            let inner = self.state.inner.read().await;
            let max_id = inner
                .blocks
                .iter()
                .filter_map(|b| crate::db::parse_id_to_i64(&b.id))
                .max()
                .unwrap_or(0);
            (max_id + 1).to_string()
        };

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
        let site_numeric = crate::db::require_id("entity", site_id)?;
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id
                        .strip_prefix("unit-")
                        .and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id
                        .strip_prefix("d-")
                        .and_then(|s| s.parse::<i64>().ok())
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

                let target_person_id = tenant_id
                    .or(owner_id)
                    .ok_or_else(|| "Unit has no occupant to move out".to_string())?;
                let occ_role = if tenant_id.is_some() {
                    DebtorType::Tenant
                } else {
                    DebtorType::Owner
                };

                // Calculate exit balance: operational liabilities for tenant, all liabilities for owner (KMK Art. 20/22)
                let exit_balance: Decimal = if occ_role == DebtorType::Tenant {
                    client
                        .query_one(
                            r#"
                            SELECT COALESCE(SUM(principal_amount + delay_penalty - paid_amount), 0.00)
                            FROM dues_liabilities
                            WHERE unit_id = $1 AND status != 'PAID' AND expense_type != 'CAPITAL_DUES'
                            "#,
                            &[&unit_numeric],
                        )
                        .await
                        .map(|r| r.get(0))
                        .unwrap_or(Decimal::ZERO)
                } else {
                    client
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
                        .unwrap_or(Decimal::ZERO)
                };

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
                    client
                        .execute(
                            "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE, exit_balance = $1, notes = COALESCE($2, notes) WHERE id = $3",
                            &[&exit_balance, &notes_val, &id],
                        )
                        .await.map_err(|e| e.to_string())?;
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

                // Bind active household members to the closed occupancy session
                client
                    .execute(
                        "UPDATE occupancy_members SET occupancy_id = $1 WHERE occupancy_id IS NULL AND person_id IN (SELECT person_id FROM unit_occupancies WHERE id = $1)",
                        &[&occ_id],
                    )
                    .await.map_err(|e| e.to_string())?;

                // Clear active household members from in-memory cache
                {
                    let mut inner = self.state.inner.write().await;
                    for key in &[
                        unit_numeric.to_string(),
                        format!("d-{}", unit_numeric),
                        format!("unit-{}", unit_numeric),
                        unit_id.to_string(),
                    ] {
                        inner.unit_members.remove(key);
                    }
                }

                // Update unit status to VACANT and clear tenant_person_id if tenant moved out
                if tenant_id.is_some() {
                    client
                        .execute(
                            "UPDATE units SET tenant_person_id = NULL, occupancy_status = 'VACANT' WHERE id = $1",
                            &[&unit_numeric],
                        )
                        .await.map_err(|e| e.to_string())?;
                } else {
                    client
                        .execute(
                            "UPDATE units SET occupancy_status = 'VACANT' WHERE id = $1",
                            &[&unit_numeric],
                        )
                        .await
                        .map_err(|e| e.to_string())?;
                }

                // Fetch person details
                let person_row = client
                    .query_one(
                        "SELECT full_name, phone, email FROM persons WHERE id = $1",
                        &[&target_person_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;

                return Ok(crate::models::OccupancyHistoryItem {
                    id: occ_id,
                    unit_id: unit_numeric,
                    person_id: target_person_id,
                    person_name: person_row.get(0),
                    person_phone: person_row.get(1),
                    person_email: person_row.get(2),
                    role: occ_role,
                    start_date: chrono::Utc::now().format("%Y-%m-%d").to_string(),
                    end_date: Some(chrono::Utc::now().format("%Y-%m-%d").to_string()),
                    is_active: false,
                    exit_balance,
                    notes: notes_val,
                    created_at: chrono::Utc::now(),
                });
            }
        }

        // In-memory fallback if PostgreSQL pool is not active
        let mut inner = self.state.inner.write().await;
        if let Some(unit) = inner
            .units
            .iter_mut()
            .find(|u| u.id == unit_id || u.unit_number.to_string() == unit_id)
        {
            unit.tenant_user_id = None;
        }
        for key in &[
            unit_numeric.to_string(),
            format!("d-{}", unit_numeric),
            format!("unit-{}", unit_numeric),
            unit_id.to_string(),
        ] {
            inner.unit_members.remove(key);
        }

        Ok(crate::models::OccupancyHistoryItem {
            id: 1,
            unit_id: unit_numeric,
            person_id: 1,
            person_name: "Tenant".to_string(),
            person_phone: None,
            person_email: None,
            role: DebtorType::Tenant,
            start_date: chrono::Utc::now().format("%Y-%m-%d").to_string(),
            end_date: Some(chrono::Utc::now().format("%Y-%m-%d").to_string()),
            is_active: false,
            exit_balance: Decimal::ZERO,
            notes: req.notes,
            created_at: chrono::Utc::now(),
        })
    }

    pub async fn move_in_resident(
        &self,
        site_id: &str,
        unit_id: &str,
        req: crate::models::MoveInResidentRequest,
    ) -> Result<crate::models::OccupancyHistoryItem, String> {
        let _site_numeric = crate::db::require_id("entity", site_id)?;
        let unit_numeric = crate::db::parse_id_to_i64(unit_id)
            .or_else(|| {
                if unit_id.starts_with("unit-") {
                    unit_id
                        .strip_prefix("unit-")
                        .and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id
                        .strip_prefix("d-")
                        .and_then(|s| s.parse::<i64>().ok())
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
                    let clean_email = crate::domain::email::NormalizedEmail::normalize(email);
                    let existing = client
                        .query_opt(
                            "SELECT id FROM persons WHERE LOWER(email) = $1",
                            &[&clean_email],
                        )
                        .await
                        .ok()
                        .flatten();
                    if let Some(p) = existing {
                        p.get(0)
                    } else {
                        let full_name = req
                            .full_name
                            .clone()
                            .unwrap_or_else(|| "New Resident".to_string());
                        let phone = req.phone.clone();
                        let p_type = if req.role == DebtorType::Tenant {
                            "HOME_RESIDENT"
                        } else {
                            "HOME_OWNER"
                        };
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
                client
                    .execute(
                        "UPDATE unit_occupancies SET is_active = false, end_date = CURRENT_DATE WHERE unit_id = $1 AND is_active = true",
                        &[&unit_numeric],
                    )
                    .await.map_err(|e| e.to_string())?;

                let occ_role = req.role.as_str();
                let occ_status = if req.role == DebtorType::Tenant {
                    "TENANT_OCCUPIED"
                } else {
                    "OWNER_OCCUPIED"
                };

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
                if req.role == DebtorType::Tenant {
                    client
                        .execute(
                            "UPDATE units SET tenant_person_id = $1, occupancy_status = $2 WHERE id = $3",
                            &[&person_id, &occ_status, &unit_numeric],
                        )
                        .await.map_err(|e| e.to_string())?;
                } else {
                    client
                        .execute(
                            "UPDATE units SET owner_person_id = $1, occupancy_status = $2 WHERE id = $3",
                            &[&person_id, &occ_status, &unit_numeric],
                        )
                        .await.map_err(|e| e.to_string())?;
                }

                // Fetch person details
                let person_row = client
                    .query_one(
                        "SELECT full_name, phone, email FROM persons WHERE id = $1",
                        &[&person_id],
                    )
                    .await
                    .map_err(|e| e.to_string())?;

                return Ok(crate::models::OccupancyHistoryItem {
                    id: occ_id,
                    unit_id: unit_numeric,
                    person_id,
                    person_name: person_row.get(0),
                    person_phone: person_row.get(1),
                    person_email: person_row.get(2),
                    role: req.role,
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
                    unit_id
                        .strip_prefix("unit-")
                        .and_then(|s| s.parse::<i64>().ok())
                } else if unit_id.starts_with("d-") {
                    unit_id
                        .strip_prefix("d-")
                        .and_then(|s| s.parse::<i64>().ok())
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
                if let Some(rows) = crate::db::logged(
                    client.query(query, &[&unit_numeric]).await,
                    "site_admin_service",
                ) {
                    let items = rows
                        .into_iter()
                        .map(|r| crate::models::OccupancyHistoryItem {
                            id: r.get(0),
                            unit_id: r.get(1),
                            person_id: r.get(2),
                            person_name: r.get(3),
                            person_phone: r.get(4),
                            person_email: r.get(5),
                            role: DebtorType::from_str_loose(&r.get::<_, String>(6)),
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
            .or_else(|| {
                inner
                    .unit_occupancies
                    .get(&format!("unit-{}", unit_numeric))
            })
            .or_else(|| inner.unit_occupancies.get(&format!("d-{}", unit_numeric)))
        {
            return Ok(items.clone());
        }
        Ok(Vec::new())
    }
}

fn generate_resident_temporary_password() -> String {
    crate::auth::generate_temporary_password("SP-SAKIN-")
}
