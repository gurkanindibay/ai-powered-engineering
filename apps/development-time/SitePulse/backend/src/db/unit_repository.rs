use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{parse_id_to_i64, require_id};
use super::user_repository::save_user;
use crate::models::{IndependentUnit, User};
pub async fn save_unit(
    pool: &Pool,
    unit: &IndependentUnit,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(&unit.id).unwrap_or(unit.unit_number as i64);
    let site_id_num = require_id("entity", &unit.site_id)?;

    // Ensure site exists in PostgreSQL before inserting unit
    let site_exists = client
        .query_opt("SELECT id FROM sites WHERE id = $1", &[&site_id_num])
        .await?
        .is_some();
    if !site_exists {
        client
            .execute(
                r#"
                INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
                VALUES ($1, 'Site', 'Adres', 'site', 'ACTIVE', 'STANDARD', CURRENT_DATE + INTERVAL '1 year')
                ON CONFLICT (id) DO NOTHING
                "#,
                &[&site_id_num],
            )
            .await?;
    }

    // Resolve or insert valid block_id for this site
    let block_id_num: i64 = match client
        .query_opt(
            "SELECT id FROM blocks WHERE site_id = $1 AND (block_name ILIKE $2 OR block_name ILIKE $3)",
            &[&site_id_num, &unit.block_id, &format!("{} Blok", unit.block_id)],
        )
        .await?
    {
        Some(r) => r.get(0),
        None => {
            let bname = if unit.block_id.trim().is_empty() {
                "A Blok".to_string()
            } else {
                unit.block_id.clone()
            };
            let r = client
                .query_one(
                    "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id",
                    &[&site_id_num, &bname],
                )
                .await?;
            r.get(0)
        }
    };

    let owner_id_num = unit.owner_user_id.as_deref().and_then(parse_id_to_i64);
    let effective_owner_id = if let Some(oid) = owner_id_num {
        let exists = client
            .query_opt("SELECT id FROM persons WHERE id = $1", &[&oid])
            .await?
            .is_some();
        if exists {
            Some(oid)
        } else {
            let user_row = client.query_opt("SELECT COALESCE(p.full_name, ''), COALESCE(p.phone, ''), u.email FROM users u LEFT JOIN persons p ON u.person_id = p.id WHERE u.id = $1", &[&oid]).await?;
            if let Some(ur) = user_row {
                let name: String = ur.get(0);
                let phone: Option<String> = ur.get(1);
                let email: String = ur.get(2);
                let ph = phone.unwrap_or_default();
                client.execute(
                    "INSERT INTO persons (id, full_name, phone, email, person_type) VALUES ($1, $2, $3, $4, 'HOME_OWNER') ON CONFLICT (id) DO NOTHING",
                    &[&oid, &name, &ph, &email],
                ).await?;
                Some(oid)
            } else {
                None
            }
        }
    } else {
        None
    };

    let tenant_id_num = unit.tenant_user_id.as_deref().and_then(parse_id_to_i64);
    let effective_tenant_id = if let Some(tid) = tenant_id_num {
        let exists = client
            .query_opt("SELECT id FROM persons WHERE id = $1", &[&tid])
            .await?
            .is_some();
        if exists {
            Some(tid)
        } else {
            let user_row = client.query_opt("SELECT COALESCE(p.full_name, ''), COALESCE(p.phone, ''), u.email FROM users u LEFT JOIN persons p ON u.person_id = p.id WHERE u.id = $1", &[&tid]).await?;
            if let Some(ur) = user_row {
                let name: String = ur.get(0);
                let phone: Option<String> = ur.get(1);
                let email: String = ur.get(2);
                let ph = phone.unwrap_or_default();
                client.execute(
                    "INSERT INTO persons (id, full_name, phone, email, person_type) VALUES ($1, $2, $3, $4, 'HOME_RESIDENT') ON CONFLICT (id) DO NOTHING",
                    &[&tid, &name, &ph, &email],
                ).await?;
                Some(tid)
            } else {
                None
            }
        }
    } else {
        None
    };

    client
        .execute(
            r#"
            INSERT INTO units (id, block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (id) DO UPDATE SET
                block_id = EXCLUDED.block_id,
                site_id = EXCLUDED.site_id,
                unit_number = EXCLUDED.unit_number,
                floor = EXCLUDED.floor,
                land_share = EXCLUDED.land_share,
                owner_person_id = EXCLUDED.owner_person_id,
                tenant_person_id = EXCLUDED.tenant_person_id,
                virtual_iban = EXCLUDED.virtual_iban
            "#,
            &[
                &id_num,
                &block_id_num,
                &site_id_num,
                &unit.unit_number,
                &unit.floor,
                &unit.land_share,
                &effective_owner_id,
                &effective_tenant_id,
                &unit.virtual_iban,
            ],
        )
        .await?;
    info!(
        "Saved unit {} (numeric ID: {}, D:{}) to PostgreSQL units",
        unit.id, id_num, unit.unit_number
    );
    Ok(())
}

pub async fn save_unit_member(
    pool: &Pool,
    unit_id: &str,
    full_name: &str,
    relationship: &str,
    phone: &str,
    email: &str,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let u_num = require_id("entity", unit_id)?;

    // Household members live on an occupancy session; fall back to the active one.
    let occ_id: Option<i64> = client
        .query_opt(
            "SELECT id FROM unit_occupancies WHERE unit_id = $1 AND is_active = true ORDER BY id DESC LIMIT 1",
            &[&u_num],
        )
        .await?
        .map(|r| r.get(0));

    let Some(occupancy_id) = occ_id else {
        return Err(format!("unit {} has no active occupancy session", unit_id).into());
    };

    // Link the household member to the person record when one exists for this email.
    let person_id: Option<i64> = client
        .query_opt(
            "SELECT id FROM persons WHERE LOWER(email) = LOWER($1)",
            &[&email.trim()],
        )
        .await?
        .map(|r| r.get(0));

    let row = client
        .query_one(
            r#"
            INSERT INTO occupancy_members (occupancy_id, person_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, false, CURRENT_TIMESTAMP)
            ON CONFLICT (occupancy_id, person_id) WHERE person_id IS NOT NULL
            DO UPDATE SET full_name = EXCLUDED.full_name,
                          relationship = EXCLUDED.relationship,
                          phone = EXCLUDED.phone,
                          email = EXCLUDED.email
            RETURNING id
            "#,
            &[
                &occupancy_id,
                &person_id,
                &full_name,
                &relationship,
                &phone,
                &email,
            ],
        )
        .await?;

    let member_id: i64 = row.get(0);
    info!(
        "Saved household member #{} ({}) for unit {} (occupancy {})",
        member_id, full_name, unit_id, occupancy_id
    );
    Ok(member_id)
}

pub async fn save_remembered_sender_iban(
    pool: &Pool,
    iban: &str,
    unit_id: &str,
    label: Option<&str>,
    bank_name: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    client
        .execute(
            r#"
            INSERT INTO unit_sender_ibans (sender_iban, unit_id, site_id, label, bank_name, created_at)
            VALUES ($1, $2, (SELECT site_id FROM units WHERE id = $2), $3, $4, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id, sender_iban) DO UPDATE SET
                label = EXCLUDED.label,
                bank_name = EXCLUDED.bank_name
            "#,
            &[&iban, &unit_id_num, &label, &bank_name],
        )
        .await?;
    info!(
        "Saved remembered sender IBAN {} for unit {} to PostgreSQL",
        iban, unit_id
    );
    Ok(())
}

pub async fn delete_remembered_sender_iban(
    pool: &Pool,
    iban: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            "DELETE FROM unit_sender_ibans WHERE sender_iban = $1",
            &[&iban],
        )
        .await?;
    info!("Deleted remembered sender IBAN {} from PostgreSQL", iban);
    Ok(())
}

pub async fn save_unit_payer_names(
    pool: &Pool,
    unit_id: &str,
    names: &[String],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    client
        .execute(
            "DELETE FROM unit_payer_names WHERE unit_id = $1",
            &[&unit_id_num],
        )
        .await?;
    for name in names {
        client
            .execute(
                "INSERT INTO unit_payer_names (unit_id, payer_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                &[&unit_id_num, &name],
            )
            .await.map_err(|e| e.to_string())?;
    }
    info!(
        "Saved {} payer names for unit {} to PostgreSQL",
        names.len(),
        unit_id
    );
    Ok(())
}

pub async fn transfer_unit_ownership_db(
    pool: &Pool,
    unit_id: &str,
    new_user: &User,
    transfer_date: chrono::NaiveDate,
    exit_balance: Decimal,
    notes: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let unit_id_num = require_id("unit", unit_id)?;

    // 1. Ensure new user is saved and person is created
    save_user(pool, new_user).await?;

    // 2. All ownership changes commit together or not at all.
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let new_person_id: Option<i64> = tx
        .query_opt(
            "SELECT person_id FROM users WHERE LOWER(email) = LOWER($1)",
            &[&new_user.email],
        )
        .await?
        .and_then(|r| r.get(0));

    // 3. Deactivate old ownership in unit_ownerships
    tx
        .execute(
            "UPDATE unit_ownerships SET is_active = false, end_date = $2 WHERE unit_id = $1 AND is_active = true",
            &[&unit_id_num, &transfer_date],
        )
        .await?;

    // 4. Insert new ownership
    if let Some(pid) = new_person_id {
        tx
            .execute(
                r#"
                INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active, created_at)
                VALUES ($1, $2, 100.00, $3, true, CURRENT_TIMESTAMP)
                "#,
                &[&unit_id_num, &pid, &transfer_date],
            )
            .await?;

        // 5. Deactivate old owner occupancy if active
        tx.execute(
            r#"
                UPDATE unit_occupancies
                SET is_active = false, end_date = $2, exit_balance = $3, notes = COALESCE($4, notes)
                WHERE unit_id = $1 AND is_active = true AND occupancy_type = 'OWNER'
                "#,
            &[&unit_id_num, &transfer_date, &exit_balance, &notes],
        )
        .await?;

        // 6. Update units owner
        tx.execute(
            "UPDATE units SET owner_person_id = $2 WHERE id = $1",
            &[&unit_id_num, &pid],
        )
        .await?;
    }

    info!(
        "Transferred ownership for unit {} to user {} in PostgreSQL",
        unit_id, new_user.email
    );
    tx.commit().await?;
    Ok(())
}
