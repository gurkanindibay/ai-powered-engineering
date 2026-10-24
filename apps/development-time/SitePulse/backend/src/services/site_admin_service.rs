use chrono::{Datelike, Utc};
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

            // Insert or update unit
            let unit_row = client
                .query_one(
                    r#"
                    INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, virtual_iban, house_type)
                    VALUES ($1, $2, $3, $4, 1, $5, $6, $7)
                    ON CONFLICT (block_id, unit_number) DO UPDATE SET
                        site_id = EXCLUDED.site_id,
                        floor = EXCLUDED.floor,
                        owner_person_id = EXCLUDED.owner_person_id,
                        virtual_iban = EXCLUDED.virtual_iban,
                        house_type = EXCLUDED.house_type
                    RETURNING id
                    "#,
                    &[
                        &block_numeric_id,
                        &site_numeric_id,
                        &request.unit_no,
                        &effective_floor,
                        &person_numeric_id,
                        &viban,
                        &effective_house_type,
                    ],
                )
                .await
                .map_err(|e| format!("Failed to insert unit: {}", e))?;
            unit_numeric_id = unit_row.get(0);

            // Insert due liability if dues > 0
            if monthly_dues > Decimal::ZERO {
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
            password_hash: Some(password_hash),
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

        let unit = IndependentUnit {
            id: unit_id.clone(),
            site_id: site_id.to_string(),
            block_id: block_id_str,
            unit_number: request.unit_no,
            floor: effective_floor,
            land_share: 1,
            owner_user_id: Some(user_id.clone()),
            tenant_user_id: None,
            virtual_iban: Some(viban),
            house_type: effective_house_type.clone(),
        };

        // Insert or update in-memory unit
        if let Some(pos) = inner
            .units
            .iter()
            .position(|u| u.id == unit.id || (u.site_id == unit.site_id && u.unit_number == unit.unit_number))
        {
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
            .entry(legacy_unit_id)
            .or_default()
            .push(request.owner_full_name.clone());

        // Also add due liability in memory if > 0
        if monthly_dues > Decimal::ZERO {
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
                id: format!("DUE-{}-{}", unit.id, Uuid::new_v4().simple()),
                unit_id: unit.id.clone(),
                period,
                principal_amount: monthly_dues,
                delay_penalty: Decimal::ZERO,
                total_amount: monthly_dues,
                due_date: Utc::now().date_naive() + chrono::Days::new(15),
                status: DebtStatus::Pending,
            });
        }

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
        })
    }

    pub async fn get_home_owners_for_site(&self, site_id: &str) -> Vec<HomeOwnerResponse> {
        let site_numeric = crate::db::parse_id_to_i64(site_id).unwrap_or(1);

        // 1. Try DB first if pool available
        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let query = r#"
                    SELECT 
                        COALESCE(u.id::text, 'p-' || p.id::text) as unit_id,
                        COALESCE(u.site_id, $1) as site_id,
                        COALESCE(b.block_name, 'A Blok') as block_name,
                        COALESCE(u.unit_number, 0) as unit_number,
                        COALESCE(u.floor, 1) as floor,
                        p.full_name,
                        COALESCE(p.email, '') as email,
                        COALESCE(p.phone, '') as phone,
                        COALESCE(u.land_share, 24) as land_share,
                        u.house_type,
                        COALESCE((SELECT principal_amount FROM dues_liabilities WHERE unit_id = u.id ORDER BY id DESC LIMIT 1), 1400.00) as monthly_dues,
                        COALESCE(usr.must_change_password, false) as must_change_password,
                        COALESCE(usr.created_at, NOW()) as created_at,
                        CASE 
                            WHEN u.tenant_person_id = p.id THEN true
                            WHEN p.person_type IN ('KAT_SAKINI', 'TENANT', 'RESIDENT') THEN true
                            WHEN u.tenant_person_id IS NULL THEN true
                            ELSE false
                        END as is_resident
                    FROM persons p
                    LEFT JOIN units u ON (u.owner_person_id = p.id OR u.tenant_person_id = p.id)
                    LEFT JOIN blocks b ON u.block_id = b.id
                    LEFT JOIN users usr ON LOWER(usr.email) = LOWER(p.email)
                    WHERE (u.site_id = $1 OR (u.site_id IS NULL AND (usr.site_id = $1 OR usr.site_id IS NULL)))
                    ORDER BY b.block_name NULLS LAST, u.unit_number NULLS LAST, p.full_name
                "#;
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

                            let clean_email = email.trim().to_lowercase();
                            let dedup_key = if !clean_email.is_empty() {
                                clean_email
                            } else {
                                format!("{}-{}-{}", block_name, unit_no, full_name.to_lowercase())
                            };
                            if !seen.insert(dedup_key) {
                                continue;
                            }
                            let floor_val: i32 = r.get("floor");
                            let land_share_val: i32 = r.get("land_share");
                            let dues_val: Decimal = r.get("monthly_dues");
                            let is_resident: bool = r.get("is_resident");

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

            let dedup_key = if !user.email.trim().is_empty() {
                user.email.trim().to_lowercase()
            } else {
                format!("{}-{}", user.id, user.full_name.to_lowercase())
            };
            if !seen.insert(dedup_key) {
                continue;
            }

            let monthly_dues = inner
                .dues
                .iter()
                .find(|d| d.unit_id == unit_id)
                .map(|d| d.principal_amount)
                .unwrap_or_else(|| Decimal::from_str_exact("1400.00").unwrap());

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
                            "SELECT id, block_id, unit_number, floor, owner_person_id, house_type FROM units WHERE (id = $1 OR owner_person_id = $1) AND site_id = $2",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                } else {
                    client
                        .query_opt(
                            "SELECT u.id, u.block_id, u.unit_number, u.floor, u.owner_person_id, u.house_type FROM units u JOIN persons p ON u.owner_person_id = p.id WHERE p.email = $1 AND u.site_id = $2",
                            &[&unit_or_user_id, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                };

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    let p_id: i64 = u_row.get(4);

                    if let Some(ref name) = req.owner_full_name {
                        let _ = client.execute("UPDATE persons SET full_name = $1 WHERE id = $2", &[name, &p_id]).await;
                        let _ = client.execute("UPDATE users SET full_name = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[name, &site_numeric, &p_id]).await;
                    }
                    if let Some(ref phone) = req.phone {
                        let _ = client.execute("UPDATE persons SET phone = $1 WHERE id = $2", &[phone, &p_id]).await;
                        let _ = client.execute("UPDATE users SET phone = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[phone, &site_numeric, &p_id]).await;
                    }
                    if let Some(ref email) = req.email {
                        let email_norm = email.trim().to_lowercase();
                        let _ = client.execute("UPDATE persons SET email = $1 WHERE id = $2", &[&email_norm, &p_id]).await;
                        let _ = client.execute("UPDATE users SET email = $1 WHERE site_id = $2 AND email = (SELECT email FROM persons WHERE id = $3)", &[&email_norm, &site_numeric, &p_id]).await;
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

        if let Some(uidx) = unit_idx {
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
                            "SELECT id, owner_person_id FROM units WHERE (id = $1 OR owner_person_id = $1) AND site_id = $2",
                            &[&uid, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                } else {
                    client
                        .query_opt(
                            "SELECT u.id, u.owner_person_id FROM units u JOIN persons p ON u.owner_person_id = p.id WHERE p.email = $1 AND u.site_id = $2",
                            &[&unit_or_user_id, &site_numeric],
                        )
                        .await
                        .ok()
                        .flatten()
                };

                if let Some(u_row) = unit_row_opt {
                    let u_id: i64 = u_row.get(0);
                    let p_id: Option<i64> = u_row.get(1);
                    let u_id_str = u_id.to_string();

                    // Delete dependent records
                    let _ = client.execute("DELETE FROM collection_transactions WHERE unit_id = $1 OR dues_liability_id IN (SELECT id FROM dues_liabilities WHERE unit_id = $1)", &[&u_id]).await;
                    let _ = client.execute("DELETE FROM dues_liabilities WHERE unit_id = $1", &[&u_id]).await;
                    let _ = client.execute("DELETE FROM unit_members WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM advance_balances WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM unit_sender_ibans WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM unit_payer_names WHERE unit_id = $1 OR unit_id = $2", &[&u_id_str, &format!("d-{}", u_id)]).await;
                    let _ = client.execute("DELETE FROM units WHERE id = $1", &[&u_id]).await;

                    if let Some(person_id) = p_id {
                        let other_units = client
                            .query_one("SELECT COUNT(*) FROM units WHERE owner_person_id = $1", &[&person_id])
                            .await
                            .map(|r| r.get::<_, i64>(0))
                            .unwrap_or(0);
                        if other_units == 0 {
                            let _ = client.execute("DELETE FROM users WHERE site_id = $1 AND email = (SELECT email FROM persons WHERE id = $2)", &[&site_numeric, &person_id]).await;
                            let _ = client.execute("DELETE FROM persons WHERE id = $1", &[&person_id]).await;
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
}

fn generate_resident_temporary_password() -> String {
    let part: String = rand::thread_rng()
        .sample_iter(&Alphanumeric)
        .take(4)
        .map(char::from)
        .collect();
    format!("SP-SAKIN-{}", part.to_uppercase())
}

