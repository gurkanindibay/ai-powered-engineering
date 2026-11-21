use deadpool_postgres::Pool;
use rust_decimal::Decimal;
use tracing::info;

use super::base::{parse_id_to_i64, require_id, DbResult};
use super::user_repository::save_user;
use crate::models::{CreateUnitsRequest, IndependentUnit, UnitDto, User};
use crate::services::virtual_iban_service::VirtualIbanService;
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
            .query_opt(
                "SELECT id FROM persons WHERE id = $1 AND deleted_at IS NULL",
                &[&oid],
            )
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
                super::person_repository::ensure_legacy_person(
                    &client,
                    oid,
                    &name,
                    Some(&ph),
                    &email,
                    "HOME_OWNER",
                )
                .await?;
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
            .query_opt(
                "SELECT id FROM persons WHERE id = $1 AND deleted_at IS NULL",
                &[&tid],
            )
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
                super::person_repository::ensure_legacy_person(
                    &client,
                    tid,
                    &name,
                    Some(&ph),
                    &email,
                    "HOME_RESIDENT",
                )
                .await?;
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

/// Raised when a household member is added to a unit without an active occupancy.
pub const NO_CURRENT_OCCUPANT: &str = "Unit has no current occupant";

pub async fn save_unit_member(
    pool: &Pool,
    unit_id: &str,
    full_name: &str,
    relationship: &str,
    phone: &str,
    email: &str,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let mut connection = pool.get().await?;
    let client = connection.transaction().await?;
    let u_num = require_id("unit", unit_id)?;
    // Serialize occupancy selection and membership creation on the actual unit.
    let unit = client.query_opt(
        "SELECT owner_person_id,tenant_person_id,site_id FROM units WHERE id=$1 AND deleted_at IS NULL FOR UPDATE",
        &[&u_num],
    ).await?.ok_or_else(|| format!("Unit {unit_id} not found"))?;
    let existing = client.query_opt(
        "SELECT id FROM unit_occupancies WHERE unit_id=$1 AND is_active AND end_date IS NULL ORDER BY id DESC LIMIT 1",
        &[&u_num],
    ).await?;
    // Invariant 6 (EPIC-08 §3.4): a member joins the active occupancy; adding
    // one never opens a session, which only a move-in or registration does.
    let occupancy_id: i64 = existing
        .map(|row| row.get(0))
        .ok_or_else(|| NO_CURRENT_OCCUPANT.to_string())?;
    let normalized_email = crate::domain::email::NormalizedEmail::normalize(email);
    // S1: a household member is the unit's site's person; an address is matched only in that site.
    let site_id: Option<i64> = unit.get(2);
    let existing_person = if normalized_email.is_empty() {
        None
    } else {
        client.query_opt(
            "SELECT id FROM persons WHERE site_id IS NOT DISTINCT FROM $1 AND lower(email)=$2 AND deleted_at IS NULL",
            &[&site_id,&normalized_email],
        ).await?
    };
    let person_id: i64 = match existing_person {
        Some(row) => row.get(0),
        None => {
            if let Some(site) = site_id {
                super::person_repository::resolve_new_site_person(
                    &client,
                    full_name,
                    Some(phone),
                    (!normalized_email.is_empty()).then_some(normalized_email.as_str()),
                    "HOME_RESIDENT",
                    site,
                    true,
                )
                .await?
            } else {
                super::person_repository::insert_site_person(
                    &client,
                    full_name,
                    Some(phone),
                    (!normalized_email.is_empty()).then_some(normalized_email.as_str()),
                    "HOME_RESIDENT",
                    None,
                )
                .await?
            }
        }
    };
    let row = client.query_one(
        "INSERT INTO occupancy_members(occupancy_id,person_id,full_name,relationship,phone,email,is_emergency_contact) VALUES ($1,$2,$3,$4,$5,$6,false) ON CONFLICT(occupancy_id,person_id) WHERE person_id IS NOT NULL DO UPDATE SET full_name=EXCLUDED.full_name,relationship=EXCLUDED.relationship,phone=EXCLUDED.phone,email=EXCLUDED.email RETURNING id",
        &[&occupancy_id,&person_id,&full_name,&relationship,&phone,&normalized_email],
    ).await?;
    client.commit().await?;

    let member_id: i64 = row.get(0);
    info!(
        "Saved household member #{} for unit {} (occupancy {})",
        member_id, unit_id, occupancy_id
    );
    Ok(member_id)
}

/// A household member added through a [`PersonRef`](crate::models::PersonRef).
pub struct SavedMember {
    pub member_id: i64,
    pub person_id: i64,
    pub full_name: String,
    pub phone: String,
    pub email: String,
}

/// Adds a household member to the unit's active occupancy, resolving the person
/// by reference in the same transaction. The legacy contact columns of
/// `occupancy_members` are filled from the card until they are dropped.
pub async fn save_unit_member_ref(
    pool: &Pool,
    unit_id: &str,
    person: &crate::models::PersonRef,
    relationship: &str,
) -> Result<SavedMember, Box<dyn std::error::Error + Send + Sync>> {
    let mut connection = pool.get().await?;
    let tx = connection.transaction().await?;
    let u_num = require_id("unit", unit_id)?;
    let unit = tx
        .query_opt(
            "SELECT site_id FROM units WHERE id=$1 AND deleted_at IS NULL AND site_id IS NOT NULL FOR UPDATE",
            &[&u_num],
        )
        .await?
        .ok_or_else(|| format!("Unit {unit_id} not found"))?;
    let site: i64 = unit.get(0);
    let occupancy_id: i64 = tx
        .query_opt(
            "SELECT id FROM unit_occupancies WHERE unit_id=$1 AND is_active AND end_date IS NULL ORDER BY id DESC LIMIT 1",
            &[&u_num],
        )
        .await?
        .map(|row| row.get(0))
        .ok_or_else(|| NO_CURRENT_OCCUPANT.to_string())?;
    let person_id = crate::services::person_service::resolve_person_ref(&tx, site, person).await?;
    let card = tx
        .query_one(
            "SELECT full_name, COALESCE(phone, ''), COALESCE(email, '') FROM persons WHERE id=$1",
            &[&person_id],
        )
        .await?;
    let (full_name, phone, email): (String, String, String) =
        (card.get(0), card.get(1), card.get(2));
    let row = tx
        .query_one(
            "INSERT INTO occupancy_members(occupancy_id,person_id,full_name,relationship,phone,email,is_emergency_contact) VALUES ($1,$2,$3,$4,$5,$6,false) ON CONFLICT(occupancy_id,person_id) WHERE person_id IS NOT NULL DO UPDATE SET relationship=EXCLUDED.relationship RETURNING id",
            &[&occupancy_id, &person_id, &full_name, &relationship, &phone, &email],
        )
        .await?;
    tx.commit().await?;
    Ok(SavedMember {
        member_id: row.get(0),
        person_id,
        full_name,
        phone,
        email,
    })
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

/// Options of a title deed transfer (T6, STORY-08-05 and 08-09).
#[derive(Debug, Clone)]
pub struct TitleTransfer<'a> {
    pub unit_id: &'a str,
    pub site_id: &'a str,
    /// Created (with its person) when `buyer_person_id` is not given.
    pub new_user: &'a User,
    pub buyer_person_id: Option<i64>,
    pub new_owner_moves_in: bool,
    pub transfer_date: chrono::NaiveDate,
    pub today: chrono::NaiveDate,
    pub notes: Option<&'a str>,
}

/// Closes the old ownership, opens the new one and applies the occupancy
/// effect of the transfer in one transaction (§3.3 T6). Returns the exit
/// balance of the occupancy session the transfer closed, if any.
pub async fn transfer_unit_ownership_db(
    pool: &Pool,
    transfer: &TitleTransfer<'_>,
) -> Result<Option<Decimal>, crate::db::occupancy_repository::OccupancyError> {
    use crate::db::occupancy_repository::{self as occupancy, OccupancyError, TransitionInput};
    use crate::domain::unit_state::{self, Command, SessionRole};

    let storage =
        |e: Box<dyn std::error::Error + Send + Sync>| OccupancyError::Storage(e.to_string());
    let unit_id_num =
        require_id("unit", transfer.unit_id).map_err(|_| OccupancyError::UnitNotFound)?;
    let site_id_num =
        require_id("site", transfer.site_id).map_err(|_| OccupancyError::UnitNotFound)?;

    // 1. A new buyer gets an account and a person record first.
    if transfer.buyer_person_id.is_none() {
        save_user(pool, transfer.new_user).await.map_err(storage)?;
    }

    // 2. All ownership and occupancy changes commit together or not at all.
    let mut client = pool
        .get()
        .await
        .map_err(|e| OccupancyError::Storage(e.to_string()))?;
    let tx = client.transaction().await?;
    crate::db::tx_bind_tenant(&tx, site_id_num)
        .await
        .map_err(storage)?;
    let snapshot = occupancy::lock_unit_snapshot(&tx, site_id_num, unit_id_num).await?;
    let buyer: i64 = match transfer.buyer_person_id {
        Some(person_id) => tx
            .query_opt(
                "SELECT id FROM persons WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL",
                &[&person_id, &site_id_num],
            )
            .await?
            .map(|r| r.get(0))
            .ok_or(OccupancyError::PersonNotFound)?,
        None => tx
            .query_opt(
                "SELECT person_id FROM users WHERE LOWER(email) = $1 AND is_active AND person_id IS NOT NULL",
                &[&crate::domain::email::NormalizedEmail::normalize(
                    &transfer.new_user.email,
                )],
            )
            .await?
            .map(|r| r.get(0))
            .ok_or(OccupancyError::PersonNotFound)?,
    };
    if snapshot.is_owner(buyer) {
        return Err(OccupancyError::BuyerIsOwner);
    }
    let buyer_is_tenant = snapshot
        .session
        .as_ref()
        .is_some_and(|s| s.role == SessionRole::Tenant && s.person_id == buyer);
    let plan = unit_state::plan(
        snapshot.state,
        Command::TitleTransfer {
            buyer_is_tenant,
            new_owner_moves_in: transfer.new_owner_moves_in,
        },
    )?;
    unit_state::validate_effective_date(transfer.transfer_date, transfer.today)?;

    // 3. Close every active ownership; an owner known only from the unit
    //    column (no ownership history) is archived so the history is complete.
    let closed_ownerships = tx
        .execute(
            "UPDATE unit_ownerships SET is_active = false, end_date = $2, start_date = LEAST(start_date, $2) WHERE unit_id = $1 AND is_active = true",
            &[&unit_id_num, &transfer.transfer_date],
        )
        .await?;
    if closed_ownerships == 0 {
        for owner in &snapshot.owners {
            tx.execute(
                r#"
                INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, end_date, is_active, created_at)
                VALUES ($1, $2, 100.00, LEAST($3::date, $4::date), $4, false, CURRENT_TIMESTAMP)
                ON CONFLICT DO NOTHING
                "#,
                &[&unit_id_num, &owner.person_id, &owner.start_date, &transfer.transfer_date],
            )
            .await?;
        }
    }

    // 4. Open the new ownership (the owner column follows by trigger, V15).
    tx.execute(
        r#"
        INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active, created_at)
        VALUES ($1, $2, 100.00, $3, true, CURRENT_TIMESTAMP)
        "#,
        &[&unit_id_num, &buyer, &transfer.transfer_date],
    )
    .await?;
    tx.execute(
        "UPDATE units SET owner_person_id = $2 WHERE id = $1",
        &[&unit_id_num, &buyer],
    )
    .await?;

    // 5. Occupancy effect: close the old owner's or the buying tenant's
    //    session, and open the buyer's when they move in.
    let input = TransitionInput {
        effective_date: transfer.transfer_date,
        today: transfer.today,
        tenant_person_id: None,
        owner_person_id: None,
        new_owner_person_id: Some(buyer),
        notes: transfer.notes.map(str::to_string),
    };
    let incoming = plan.opens.map(|_| buyer);
    let outcome = occupancy::execute_plan(&tx, &snapshot, plan, incoming, &input).await?;

    tx.commit().await?;
    info!(
        unit_id = unit_id_num,
        from = %outcome.plan.from.label(),
        to = %outcome.plan.to.label(),
        "Transferred unit ownership in PostgreSQL"
    );
    Ok(outcome.closed.map(|c| c.exit_balance))
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct UnitSummaryDto {
    pub unit_id: String,
    pub site_id: String,
    pub site_name: String,
    pub block: String,
    pub unit_number: i32,
    pub floor: i32,
    pub resident_name: String,
    pub email: String,
    pub virtual_iban: String,
    pub current_debt: String,
    pub advance_balance: String,
}

pub async fn fetch_units_summary_from_db(pool: &Pool) -> DbResult<Vec<UnitSummaryDto>> {
    let client = pool.get().await?;
    let rows = client
        .query(
            r#"
            SELECT
                u.id::text,
                u.site_id::text,
                s.name as site_name,
                b.block_name,
                u.unit_number,
                u.floor,
                COALESCE(op.full_name, tp.full_name, 'Daire Sakini ' || u.unit_number) as resident_name,
                COALESCE(op.email, tp.email, '') as email,
                COALESCE(u.virtual_iban, '') as virtual_iban,
                COALESCE(
                    (SELECT SUM(dl.principal_amount + dl.delay_penalty - dl.paid_amount)
                     FROM dues_liabilities dl
                     WHERE dl.unit_id = u.id AND dl.status != 'PAID' AND dl.status != 'CANCELLED'),
                    0.00
                ) as current_debt,
                COALESCE(
                    (SELECT SUM(ab.balance)
                     FROM advance_balances ab
                     WHERE ab.unit_id = u.id),
                    0.00
                ) as advance_balance
            FROM units u
            JOIN sites s ON u.site_id = s.id
            JOIN blocks b ON u.block_id = b.id
            LEFT JOIN persons op ON u.owner_person_id = op.id
            LEFT JOIN persons tp ON u.tenant_person_id = tp.id
            WHERE u.deleted_at IS NULL
            ORDER BY u.site_id, b.block_name, u.unit_number
            "#,
            &[],
        )
        .await?;

    let mut list = Vec::new();
    for row in rows {
        let unit_id: String = row.get(0);
        let site_id: String = row.get(1);
        let site_name: String = row.get(2);
        let block: String = row.get(3);
        let unit_number: i32 = row.get(4);
        let floor: i32 = row.get(5);
        let resident_name: String = row.get(6);
        let email: String = row.get(7);
        let virtual_iban: String = row.get(8);
        let current_debt: Decimal = row.get(9);
        let advance_balance: Decimal = row.get(10);

        list.push(UnitSummaryDto {
            unit_id,
            site_id,
            site_name,
            block,
            unit_number,
            floor,
            resident_name,
            email,
            virtual_iban,
            current_debt: current_debt.to_string(),
            advance_balance: advance_balance.to_string(),
        });
    }
    Ok(list)
}

pub async fn get_units_for_site_from_db(
    pool: &Pool,
    site_id: &str,
    block_id: Option<&str>,
) -> DbResult<Vec<UnitDto>> {
    let site_numeric = match require_id("entity", site_id) {
        Ok(id) => id,
        Err(_) => return Ok(Vec::new()),
    };

    let client = pool.get().await?;
    let query = r#"
        SELECT u.id, u.site_id, u.block_id, b.block_name, u.unit_number, u.floor,
               u.occupancy_status, u.virtual_iban,
               u.owner_person_id, u.tenant_person_id
        FROM units u
        JOIN blocks b ON u.block_id = b.id
        WHERE u.site_id = $1 AND u.deleted_at IS NULL
        ORDER BY b.block_name ASC, u.unit_number ASC
    "#;
    let rows = client.query(query, &[&site_numeric]).await?;
    let mut list = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let s_id: i64 = row.get(1);
        let blk_id: i64 = row.get(2);
        let blk_name: String = row.get(3);
        let unit_number: i32 = row.get(4);
        let floor: i32 = row.get(5);
        let occ_status: String = row.get(6);
        let viban: Option<String> = row.get(7);
        let owner_pid: Option<i64> = row.get(8);
        let tenant_pid: Option<i64> = row.get(9);

        let clean_block = blk_name
            .trim()
            .trim_end_matches(" Blok")
            .trim_end_matches(" blok")
            .trim_end_matches(" BLOK")
            .trim();
        let label = format!("{}-{:02}", clean_block, unit_number);

        list.push(UnitDto {
            id: id.to_string(),
            site_id: s_id.to_string(),
            block_id: blk_id.to_string(),
            block_name: blk_name,
            unit_number,
            floor,
            label,
            owner_person_id: owner_pid.map(|p| p.to_string()),
            tenant_person_id: tenant_pid.map(|p| p.to_string()),
            virtual_iban: viban,
            occupancy_status: occ_status,
        });
    }
    if let Some(b_id) = block_id {
        list.retain(|u| u.block_id == b_id);
    }
    Ok(list)
}

pub async fn create_units_in_db(
    pool: &Pool,
    site_id: &str,
    req: &CreateUnitsRequest,
    unit_numbers: &[i32],
) -> DbResult<Vec<UnitDto>> {
    let site_numeric = require_id("entity", site_id)?;
    let land_share = req.land_share.unwrap_or(1).max(1);
    let block_name_trimmed = req.block_name.trim();

    let mut client = pool.get().await?;
    let tx = client.transaction().await?;

    let existing_block_opt = tx
        .query_opt(
            "SELECT id, block_name FROM blocks WHERE site_id = $1 AND (LOWER(block_name) = LOWER($2) OR LOWER(block_name) = LOWER($3)) LIMIT 1",
            &[&site_numeric, &block_name_trimmed, &format!("{} Blok", block_name_trimmed)],
        )
        .await?;

    let (block_numeric_id, db_block_name) = if let Some(row) = existing_block_opt {
        let id: i64 = row.get(0);
        let name: String = row.get(1);
        (id, name)
    } else {
        let new_block_row = tx
            .query_one(
                "INSERT INTO blocks (site_id, block_name, total_floors) VALUES ($1, $2, 10) RETURNING id, block_name",
                &[&site_numeric, &block_name_trimmed],
            )
            .await?;
        (new_block_row.get(0), new_block_row.get(1))
    };

    let block_id_str = block_numeric_id.to_string();
    let actual_block_name = db_block_name;

    // Check if any unit already exists in this block (including soft-deleted units)
    let existing_rows = tx
        .query(
            "SELECT unit_number FROM units WHERE block_id = $1 AND unit_number = ANY($2) ORDER BY unit_number",
            &[&block_numeric_id, &unit_numbers],
        )
        .await?;
    if !existing_rows.is_empty() {
        let existing_nums: Vec<i32> = existing_rows.iter().map(|r| r.get(0)).collect();
        return Err(format!(
            "Units already exist in block {}: {:?}",
            actual_block_name, existing_nums
        )
        .into());
    }

    // Resolve house_type_id if house_type matches a registered house_type for this site
    let house_type_id_opt: Option<i64> = if let Some(ref ht_name) = req.house_type {
        tx.query_opt(
            "SELECT id FROM house_types WHERE site_id = $1 AND (type_name = $2 OR LOWER(type_name) = LOWER($2)) LIMIT 1",
            &[&site_numeric, ht_name],
        )
        .await?
        .map(|r| r.get(0))
    } else {
        None
    };

    let mut result_dtos = Vec::new();
    for unit_no in unit_numbers {
        let floor = req.floor.unwrap_or_else(|| ((unit_no - 1) / 4) + 1);
        let clean_block = actual_block_name
            .trim()
            .trim_end_matches(" Blok")
            .trim_end_matches(" blok")
            .trim_end_matches(" BLOK")
            .trim();
        let label = format!("{}-{:02}", clean_block, unit_no);
        let viban =
            VirtualIbanService::generate_virtual_iban("00205", site_id, clean_block, *unit_no).ok();

        let unit_row = tx
            .query_one(
                r#"
                INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, virtual_iban, house_type, house_type_id)
                VALUES ($1, $2, $3, $4, $5, 'VACANT', $6, $7, $8)
                RETURNING id, owner_person_id, tenant_person_id, occupancy_status, virtual_iban
                "#,
                &[
                    &block_numeric_id,
                    &site_numeric,
                    unit_no,
                    &floor,
                    &land_share,
                    &viban,
                    &req.house_type,
                    &house_type_id_opt,
                ],
            )
            .await?;

        let unit_db_id: i64 = unit_row.get(0);
        let owner_pid: Option<i64> = unit_row.get(1);
        let tenant_pid: Option<i64> = unit_row.get(2);
        let occ_status: String = unit_row.get(3);
        let final_viban: Option<String> = unit_row.get(4);

        result_dtos.push(UnitDto {
            id: unit_db_id.to_string(),
            site_id: site_id.to_string(),
            block_id: block_id_str.clone(),
            block_name: actual_block_name.clone(),
            unit_number: *unit_no,
            floor,
            label,
            owner_person_id: owner_pid.map(|p| p.to_string()),
            tenant_person_id: tenant_pid.map(|p| p.to_string()),
            virtual_iban: final_viban,
            occupancy_status: occ_status,
        });
    }

    tx.commit().await?;
    Ok(result_dtos)
}
