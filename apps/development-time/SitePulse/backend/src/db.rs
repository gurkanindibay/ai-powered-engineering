use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::{Config, ManagerConfig, Pool, RecyclingMethod, Runtime};
use rust_decimal::Decimal;
use tokio_postgres::NoTls;
use tracing::{info, warn};

use crate::models::{
    BankTransactionItem, BlockDto, DebtStatus, DuesLiability, HomeownerPaymentRecord, IndependentUnit,
    PaymentEntry, PaymentMatchStatus, PendingRegistrationResponse, ReconciliationMatch,
    ReconciliationStatus, Role, Site, SiteBankAccount, UnitInviteLinkResponse, UnitMemberDto, User,
};
use crate::services::VirtualIbanService;
use crate::state::AppStateInner;

pub fn create_pool() -> Option<Pool> {
    let host = std::env::var("DB_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("DB_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5432);
    let user = std::env::var("DB_USER").unwrap_or_else(|_| "sitepulse_user".to_string());
    let password = std::env::var("DB_PASS").unwrap_or_else(|_| "sitepulse_secret".to_string());
    let dbname = std::env::var("DB_NAME").unwrap_or_else(|_| "sitepulse".to_string());

    let mut cfg = Config::new();
    cfg.host = Some(host);
    cfg.port = Some(port);
    cfg.user = Some(user);
    cfg.password = Some(password);
    cfg.dbname = Some(dbname);
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });

    match cfg.create_pool(Some(Runtime::Tokio1), NoTls) {
        Ok(pool) => {
            info!("PostgreSQL connection pool configured successfully");
            Some(pool)
        }
        Err(e) => {
            warn!("Failed to create PostgreSQL connection pool: {}", e);
            None
        }
    }
}

pub fn parse_id_to_i64(s: &str) -> Option<i64> {
    if let Ok(num) = s.parse::<i64>() {
        return Some(num);
    }
    if s == "blok-A" || s == "blk-A" || s == "A Blok" || s == "A" {
        return Some(1);
    }
    if s == "blok-B" || s == "blk-B" || s == "B Blok" || s == "B" {
        return Some(2);
    }
    if s == "blok-C" || s == "blk-C" || s == "C Blok" || s == "C" {
        return Some(3);
    }
    if s == "blok-D" || s == "blk-D" || s == "D Blok" || s == "D" {
        return Some(4);
    }
    if s == "usr-saas-root" {
        return Some(1);
    }
    if s == "usr-site-manager-1" {
        return Some(2);
    }
    if s == "usr-home-owner-1" {
        return Some(3);
    }

    let stripped = s
        .trim_start_matches("site-")
        .trim_start_matches("blok-")
        .trim_start_matches("blk-")
        .trim_start_matches("kisi-")
        .trim_start_matches("usr-")
        .trim_start_matches("d-")
        .trim_start_matches("b-")
        .trim_start_matches("borc-")
        .trim_start_matches("sba-")
        .trim_start_matches("txn-")
        .trim_start_matches("cproj-");

    if let Ok(num) = stripped.parse::<i64>() {
        return Some(num);
    }

    let hex_clean: String = stripped.chars().filter(|c| c.is_ascii_hexdigit()).take(12).collect();
    if !hex_clean.is_empty() {
        if let Ok(hex_num) = i64::from_str_radix(&hex_clean, 16) {
            return Some(hex_num.abs());
        }
    }

    None
}

pub async fn init_db(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Verifying PostgreSQL schema tables (Auto-Increment Identity)...");

    // Check if legacy schema with VARCHAR primary keys is in place
    let is_legacy: bool = client
        .query_opt(
            "SELECT 1 FROM information_schema.columns WHERE table_name = 'sites' AND column_name = 'id' AND data_type LIKE '%char%'",
            &[],
        )
        .await
        .ok()
        .flatten()
        .is_some();

    if is_legacy {
        info!("Detected legacy VARCHAR ID schema. Migrating to auto-increment BIGINT IDENTITY keys...");
        client
            .batch_execute(
                r#"
                DROP TABLE IF EXISTS collection_transactions, dues_liabilities, site_bank_accounts, units, users, persons, blocks, sites CASCADE;
                "#,
            )
            .await?;
        info!("Legacy tables dropped cleanly for migration.");
    }

    // Apply the versioned schema and hardening scripts. These SQL files are the
    // single source of truth, shared with docker-entrypoint-initdb.d and
    // scripts/reset-and-init-db.sh, so the Rust bootstrap can never drift from them.
    for schema_sql in [
        include_str!("../db/init/00-01-init-schema.sql"),
        include_str!("../db/init/00-02-saas-multi-tenancy.sql"),
        include_str!("../db/init/00-03-auth-and-permission-providers.sql"),
        include_str!("../db/init/00-04-site-bank-account.sql"),
        include_str!("../db/init/00-05-payment-tracking-and-receipts.sql"),
        include_str!("../db/init/00-06-capital-expenditure-and-fixtures.sql"),
        include_str!("../db/init/00-07-viable-occupancy-ownership-and-identity.sql"),
        include_str!("../db/init/00-08-referential-and-financial-integrity.sql"),
        include_str!("../db/init/00-09-ledger-and-referential-integrity.sql"),
        include_str!("../db/init/00-10-consolidate-household-members.sql"),
    ] {
        client.batch_execute(schema_sql).await?;
    }

    // Seed system reference data (banks, configs, root SaaS admin).
    client
        .batch_execute(include_str!("../db/init/01-system-seed.sql"))
        .await?;

    // 2. Synchronize sequences
    client
        .batch_execute(
            r#"
            SELECT setval(pg_get_serial_sequence('sites', 'id'), COALESCE((SELECT MAX(id) FROM sites), 1));
            SELECT setval(pg_get_serial_sequence('blocks', 'id'), COALESCE((SELECT MAX(id) FROM blocks), 1));
            SELECT setval(pg_get_serial_sequence('persons', 'id'), COALESCE((SELECT MAX(id) FROM persons), 1));
            SELECT setval(pg_get_serial_sequence('users', 'id'), COALESCE((SELECT MAX(id) FROM users), 1));
            SELECT setval(pg_get_serial_sequence('units', 'id'), COALESCE((SELECT MAX(id) FROM units), 1));
            SELECT setval(pg_get_serial_sequence('site_bank_accounts', 'id'), COALESCE((SELECT MAX(id) FROM site_bank_accounts), 1));
            SELECT setval(pg_get_serial_sequence('dues_liabilities', 'id'), 1, false);
            SELECT setval(pg_get_serial_sequence('payment_entries', 'id'), 1, false);
            "#,
        )
        .await?;

    info!("PostgreSQL schema verified and ready with auto-increment BIGINT identity (zero test mock data auto-added).");
    Ok(())
}

/// Seeds development/testing site fixtures (Begonya Sitesi, Kardelen Rezidans, test units, persons, and bank account).
/// Separated from startup/init_db so restarts maintain clean database state without auto-adding mock data.
pub async fn seed_test_data(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Seeding development test fixtures into PostgreSQL...");
    client
        .batch_execute(include_str!("../db/init/02-test-seed.sql"))
        .await?;
    info!("Development test fixtures seeded successfully into PostgreSQL.");
    Ok(())
}

pub async fn reset_db_to_seed_data(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Resetting PostgreSQL database to clean initial state (clean debts and payments)...");
    client
        .batch_execute(
            r#"
            TRUNCATE TABLE payment_entries RESTART IDENTITY CASCADE;
            TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;
            TRUNCATE TABLE reconciliation_queue CASCADE;
            TRUNCATE TABLE advance_balances CASCADE;
            TRUNCATE TABLE pending_registrations CASCADE;
            TRUNCATE TABLE invitation_tokens CASCADE;
            TRUNCATE TABLE unit_sender_ibans CASCADE;
            TRUNCATE TABLE unit_payer_names RESTART IDENTITY CASCADE;
            UPDATE units SET owner_person_id = 1, tenant_person_id = NULL, occupancy_status = 'OWNER_OCCUPIED' WHERE id = 14;
            UPDATE units SET owner_person_id = 4, tenant_person_id = NULL, occupancy_status = 'OWNER_OCCUPIED' WHERE id = 3;
            DELETE FROM unit_occupancies WHERE unit_id NOT IN (14, 3);
            DELETE FROM units WHERE id NOT IN (14, 3);
            DELETE FROM blocks WHERE id NOT IN (1, 2);
            DELETE FROM sites WHERE id NOT IN (1, 2);
            DELETE FROM users WHERE id NOT IN (1, 2, 3, 4);
            DELETE FROM persons WHERE id NOT IN (1, 2, 3, 4);
            DELETE FROM site_bank_accounts WHERE id > 1;

            SELECT setval(pg_get_serial_sequence('sites', 'id'), COALESCE((SELECT MAX(id) FROM sites), 1));
            SELECT setval(pg_get_serial_sequence('blocks', 'id'), COALESCE((SELECT MAX(id) FROM blocks), 1));
            SELECT setval(pg_get_serial_sequence('persons', 'id'), COALESCE((SELECT MAX(id) FROM persons), 1));
            SELECT setval(pg_get_serial_sequence('users', 'id'), COALESCE((SELECT MAX(id) FROM users), 1));
            SELECT setval(pg_get_serial_sequence('units', 'id'), COALESCE((SELECT MAX(id) FROM units), 1));
            SELECT setval(pg_get_serial_sequence('site_bank_accounts', 'id'), COALESCE((SELECT MAX(id) FROM site_bank_accounts), 1));
            SELECT setval(pg_get_serial_sequence('dues_liabilities', 'id'), 1, false);
            SELECT setval(pg_get_serial_sequence('payment_entries', 'id'), 1, false);
            "#,
        )
        .await?;
    info!("PostgreSQL database reset to clean initial seed fixtures successfully.");
    Ok(())
}

pub async fn recreate_db_schema_and_seed(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Dropping all database tables to recreate clean initial state...");
    client
        .batch_execute(
            r#"
            -- Dropping the schema (not a hand-maintained table list) keeps this in sync
            -- with db/init automatically; init_db() recreates everything from the SQL files.
            DROP SCHEMA IF EXISTS public CASCADE;
            CREATE SCHEMA public;
            GRANT USAGE ON SCHEMA public TO PUBLIC;
            "#,
        )
        .await?;
    init_db(pool).await?;
    seed_test_data(pool).await?;
    info!("All database tables dropped and recreated with clean initial state.");
    Ok(())
}

pub async fn wipe_all_db_data(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Dropping all database tables to purge all sites, units, and residents for fresh start...");
    client
        .batch_execute(
            r#"
            -- Dropping the schema (not a hand-maintained table list) keeps this in sync
            -- with db/init automatically; init_db() recreates everything from the SQL files.
            DROP SCHEMA IF EXISTS public CASCADE;
            CREATE SCHEMA public;
            GRANT USAGE ON SCHEMA public TO PUBLIC;
            "#,
        )
        .await?;
    init_db(pool).await?;
    info!("All database tables recreated cleanly with zero sites, zero units, zero homeowners, and zero residents.");
    Ok(())
}

pub async fn load_all_from_db(pool: &Pool, state: &mut AppStateInner) {
    let client = match pool.get().await {
        Ok(c) => c,
        Err(e) => {
            warn!("Could not acquire PostgreSQL connection for initial load: {}", e);
            return;
        }
    };

    // 1. Load Sites
    if let Ok(rows) = client
        .query(
            "SELECT id, name, address, slug, status, plan_type, license_end_date FROM sites",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let name: String = row.get(1);
            let address: String = row.get::<_, Option<String>>(2).unwrap_or_default();
            let slug: String = row.get::<_, Option<String>>(3).unwrap_or_else(|| id.to_string());
            let status: String = row
                .get::<_, Option<String>>(4)
                .unwrap_or_else(|| "ACTIVE".to_string());
            let plan_type: String = row
                .get::<_, Option<String>>(5)
                .unwrap_or_else(|| "STANDARD".to_string());
            let license_end_date: Option<NaiveDate> = row.get(6);

            let s = Site {
                id: id.to_string(),
                name,
                address,
                slug,
                status,
                plan_type,
                license_end_date: license_end_date
                    .unwrap_or_else(|| Utc::now().date_naive() + chrono::Days::new(365)),
            };

            let legacy_id = format!("site-{}", id);
            if let Some(pos) = state.sites.iter().position(|site| site.id == s.id || site.id == legacy_id) {
                state.sites[pos] = s.clone();
            } else {
                state.sites.push(s.clone());
            }
            if !state.sites.iter().any(|site| site.id == legacy_id) {
                let mut legacy_site = s;
                legacy_site.id = legacy_id;
                state.sites.push(legacy_site);
            }
        }
        info!("Loaded {} sites from PostgreSQL", state.sites.len());
    }

    // 2. Load Users
    if let Ok(rows) = client
        .query(
            "SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
             FROM users u
             LEFT JOIN persons p ON u.person_id = p.id",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: Option<i64> = row.get(1);
            let full_name: String = row.get(2);
            let email: String = row.get(3);
            let phone: Option<String> = row.get(4);
            let password_hash: Option<String> = row.get(5);
            let role_str: String = row.get(6);
            let must_change_password: bool = row.get(7);
            let auth_provider: Option<String> = row.get(8);
            let google_sub: Option<String> = row.get(9);
            let avatar_url: Option<String> = row.get(10);
            let created_at: Option<DateTime<Utc>> = row.get(11);
            let person_id: Option<i64> = row.try_get(12).ok().flatten();

            let user = User {
                id: id.to_string(),
                site_id: site_id.map(|s| s.to_string()).unwrap_or_else(|| "1".to_string()),
                full_name,
                email,
                phone: phone.unwrap_or_default(),
                password_hash,
                role: Role::from_str_loose(&role_str),
                must_change_password,
                auth_provider: auth_provider.unwrap_or_else(|| "LOCAL".to_string()),
                google_sub,
                avatar_url,
                created_at: created_at.unwrap_or_else(Utc::now),
                person_id,
            };

            let legacy_id = match id {
                1 => "usr-saas-root".to_string(),
                2 => "usr-site-manager-1".to_string(),
                3 => "usr-home-owner-1".to_string(),
                _ => format!("usr-{}", id),
            };

            if let Some(pos) = state.users.iter().position(|u| u.id == user.id || u.id == legacy_id) {
                state.users[pos] = user.clone();
            } else {
                state.users.push(user.clone());
            }
            if !state.users.iter().any(|u| u.id == legacy_id) {
                let mut legacy_user = user;
                legacy_user.id = legacy_id;
                state.users.push(legacy_user);
            }
        }
        info!("Loaded {} users from PostgreSQL", state.users.len());
    }

    // 2b. Load Persons into users state for resident resolution
    if let Ok(rows) = client
        .query(
            "SELECT id, full_name, email, phone, person_type FROM persons",
            &[],
        )
        .await
    {
        for row in rows {
            let p_id: i64 = row.get(0);
            let p_name: String = row.get(1);
            let p_email: Option<String> = row.get(2);
            let p_phone: Option<String> = row.get(3);
            let p_type: String = row.get(4);
            let role = Role::from_str_loose(&p_type);

            let user = User {
                id: p_id.to_string(),
                site_id: "1".to_string(),
                full_name: p_name,
                email: p_email.unwrap_or_else(|| format!("kisi-{}@sitepulse.local", p_id)),
                phone: p_phone.unwrap_or_default(),
                password_hash: None,
                role,
                must_change_password: false,
                auth_provider: "LOCAL".to_string(),
                google_sub: None,
                avatar_url: None,
                created_at: Utc::now(),
                person_id: Some(p_id),
            };

            let legacy_p_id = format!("kisi-0{}", p_id);
            if let Some(pos) = state.users.iter().position(|u| u.id == user.id || u.id == legacy_p_id) {
                state.users[pos] = user.clone();
            } else {
                state.users.push(user.clone());
            }
            if !state.users.iter().any(|u| u.id == legacy_p_id) {
                let mut legacy_u = user;
                legacy_u.id = legacy_p_id;
                state.users.push(legacy_u);
            }
        }
        info!("Loaded {} persons into users from PostgreSQL", state.users.len());
    }

    // 3. Load Units
    if let Ok(rows) = client
        .query(
            "SELECT id, block_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, site_id, virtual_iban, house_type FROM units",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let block_id: i64 = row.get(1);
            let unit_number: i32 = row.get(2);
            let floor: i32 = row.get(3);
            let land_share: i32 = row.get(4);
            let owner_person_id: Option<i64> = row.get(5);
            let tenant_person_id: Option<i64> = row.get(6);
            let site_id: Option<i64> = row.get(7);
            let virtual_iban: Option<String> = row.get(8);
            let house_type: Option<String> = row.get(9);

            let block_label = if block_id == 1 { "blok-A" } else { "blok-B" };
            let resolved_viban = virtual_iban.or_else(|| {
                Some(VirtualIbanService::generate_virtual_iban(
                    VirtualIbanService::KUVEYT_TURK_BANK_CODE,
                    &site_id.unwrap_or(1).to_string(),
                    block_label,
                    unit_number,
                ))
            });

            let unit = IndependentUnit {
                id: id.to_string(),
                site_id: site_id.unwrap_or(1).to_string(),
                block_id: block_id.to_string(),
                unit_number,
                floor,
                land_share,
                owner_user_id: owner_person_id.map(|p| p.to_string()),
                tenant_user_id: tenant_person_id.map(|p| p.to_string()),
                virtual_iban: resolved_viban,
                house_type,
            };

            // Register unit payer names (tenant takes precedence as primary resident payer if present, else owner)
            let primary_pid = tenant_person_id.or(owner_person_id);
            if let Some(p_id) = primary_pid {
                let p_str = p_id.to_string();
                let legacy_p = format!("kisi-0{}", p_id);
                if let Some(p) = state.users.iter().find(|u| u.id == p_str || u.id == legacy_p) {
                    let entry = state.unit_payer_names.entry(unit.id.clone()).or_default();
                    if !entry.contains(&p.full_name) {
                        entry.insert(0, p.full_name.clone());
                    }
                    let legacy_entry = state.unit_payer_names.entry(format!("d-{}", unit_number)).or_default();
                    if !legacy_entry.contains(&p.full_name) {
                        legacy_entry.insert(0, p.full_name.clone());
                    }
                }
            }
            if let Some(o_id) = owner_person_id {
                let o_str = o_id.to_string();
                let legacy_o = format!("kisi-0{}", o_id);
                if let Some(p) = state.users.iter().find(|u| u.id == o_str || u.id == legacy_o) {
                    let entry = state.unit_payer_names.entry(unit.id.clone()).or_default();
                    if !entry.contains(&p.full_name) {
                        entry.push(p.full_name.clone());
                    }
                    let legacy_entry = state.unit_payer_names.entry(format!("d-{}", unit_number)).or_default();
                    if !legacy_entry.contains(&p.full_name) {
                        legacy_entry.push(p.full_name.clone());
                    }
                }
            }

            let legacy_id = format!("d-{}", unit_number);
            if let Some(pos) = state.units.iter().position(|u| u.id == unit.id || u.id == legacy_id) {
                state.units[pos] = unit.clone();
            } else {
                state.units.push(unit.clone());
            }
            if !state.units.iter().any(|u| u.id == legacy_id) {
                let mut legacy_u = unit;
                legacy_u.id = legacy_id;
                state.units.push(legacy_u);
            }
        }
        info!("Loaded {} units from PostgreSQL", state.units.len());
    }

    // 3b. Load House Types (Tariffs)
    if let Ok(rows) = client
        .query(
            "SELECT id, site_id, type_name, dues_amount, description FROM house_types",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let type_name: String = row.get(2);
            let dues_amount: Decimal = row.get(3);
            let description: Option<String> = row.get(4);

            let ht = crate::models::HouseTypeTariff {
                id: id.to_string(),
                site_id: site_id.to_string(),
                type_name,
                dues_amount,
                description,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.house_types.iter().position(|h| h.id == ht.id || (h.site_id == ht.site_id && h.type_name == ht.type_name)) {
                state.house_types[pos] = ht.clone();
            } else {
                state.house_types.push(ht.clone());
            }
            if !state.house_types.iter().any(|h| h.site_id == legacy_site_id && h.type_name == ht.type_name) {
                let mut legacy_ht = ht;
                legacy_ht.site_id = legacy_site_id;
                state.house_types.push(legacy_ht);
            }
        }
        info!("Loaded {} house type tariffs from PostgreSQL", state.house_types.len());
    }

    // 3c. Load Blocks
    if let Ok(rows) = client
        .query(
            "SELECT id, site_id, block_name, total_floors FROM blocks",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let block_name: String = row.get(2);
            let total_floors: i32 = row.get(3);

            let block = crate::models::BlockDto {
                id: id.to_string(),
                site_id: site_id.to_string(),
                block_name: block_name.clone(),
                total_floors,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.blocks.iter().position(|b| b.id == block.id || (b.site_id == block.site_id && b.block_name == block.block_name)) {
                state.blocks[pos] = block.clone();
            } else {
                state.blocks.push(block.clone());
            }
            if !state.blocks.iter().any(|b| b.site_id == legacy_site_id && b.block_name == block.block_name) {
                let mut legacy_b = block;
                legacy_b.site_id = legacy_site_id;
                state.blocks.push(legacy_b);
            }
        }
        info!("Loaded {} blocks from PostgreSQL", state.blocks.len());
    }

    // 4. Load Dues Liabilities
    if let Ok(rows) = client
        .query(
            "SELECT id, unit_id, period, principal_amount, due_date, status, delay_penalty, paid_amount FROM dues_liabilities",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let unit_id: i64 = row.get(1);
            let period: String = row.get(2);
            let principal_amount: Decimal = row.get(3);
            let due_date: NaiveDate = row.get(4);
            let status_str: String = row.get(5);
            let delay_penalty: Decimal = row.get(6);
            let _paid_amount: Decimal = row.get(7);

            let status = match status_str.to_uppercase().as_str() {
                "PAID" => DebtStatus::Paid,
                "OVERDUE" => DebtStatus::Overdue,
                _ => DebtStatus::Pending,
            };

            let due = DuesLiability {
                id: id.to_string(),
                unit_id: unit_id.to_string(),
                period,
                principal_amount,
                due_date,
                status,
                delay_penalty,
                total_amount: principal_amount + delay_penalty,
            };

            let legacy_id = format!("b-{}", id);
            let legacy_borc_id = format!("borc-{}", id);
            let legacy_unit_id = format!("d-{}", unit_id);

            if let Some(pos) = state.dues.iter().position(|d| d.id == due.id || d.id == legacy_id || d.id == legacy_borc_id) {
                state.dues[pos] = due.clone();
            } else {
                state.dues.push(due.clone());
            }

            if !state.dues.iter().any(|d| d.id == legacy_id) {
                let mut leg_d = due.clone();
                leg_d.id = legacy_id;
                leg_d.unit_id = legacy_unit_id.clone();
                state.dues.push(leg_d);
            }
            if !state.dues.iter().any(|d| d.id == legacy_borc_id) {
                let mut leg_d = due;
                leg_d.id = legacy_borc_id;
                leg_d.unit_id = legacy_unit_id;
                state.dues.push(leg_d);
            }
        }
        info!("Loaded {} dues liabilities from PostgreSQL", state.dues.len());
    }

    // 4b. Load Dues Periods
    if let Ok(rows) = client
        .query(
            "SELECT id, site_id, period_name, due_date, status, created_at FROM dues_periods ORDER BY due_date ASC",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let period_name: String = row.get(2);
            let due_date: NaiveDate = row.get(3);
            let status: String = row.get(4);
            let created_at: Option<DateTime<Utc>> = row.get(5);

            let site_id_str = site_id.to_string();
            let period_item = crate::models::DuesPeriod {
                id: id.to_string(),
                site_id: site_id_str.clone(),
                period_name: period_name.clone(),
                due_date,
                status,
                created_at,
            };

            let legacy_site_id = format!("site-{}", site_id);
            if let Some(pos) = state.dues_periods.iter().position(|p| {
                (p.site_id == site_id_str || p.site_id == legacy_site_id) && p.period_name == period_name
            }) {
                state.dues_periods[pos] = period_item.clone();
            } else {
                state.dues_periods.push(period_item.clone());
            }

            if !state.dues_periods.iter().any(|p| p.site_id == legacy_site_id && p.period_name == period_name) {
                let mut leg_p = period_item;
                leg_p.site_id = legacy_site_id;
                state.dues_periods.push(leg_p);
            }
        }
        info!("Loaded {} dues periods from PostgreSQL", state.dues_periods.len());
    }

    // 5. Load Site Bank Accounts
    if let Ok(rows) = client
        .query(
            "SELECT id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at FROM site_bank_accounts",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let bank_code: String = row.get(2);
            let bank_name: String = row.get(3);
            let iban: String = row.get(4);
            let account_holder: String = row.get(5);
            let statement_format: String = row.get(6);
            let is_active: bool = row.get(7);
            let configured_by: Option<i64> = row.get(8);
            let created_at: Option<DateTime<Utc>> = row.get(9);
            let updated_at: Option<DateTime<Utc>> = row.get(10);

            let sba = SiteBankAccount {
                id: id.to_string(),
                site_id: site_id.to_string(),
                bank_code,
                bank_name,
                iban,
                account_holder,
                statement_format,
                is_active,
                configured_by: configured_by.map(|c| c.to_string()),
                created_at: created_at.unwrap_or_else(Utc::now),
                updated_at: updated_at.unwrap_or_else(Utc::now),
            };

            let legacy_id = format!("sba-{}", id);
            if let Some(pos) = state.site_bank_accounts.iter().position(|b| b.id == sba.id || b.id == legacy_id) {
                state.site_bank_accounts[pos] = sba.clone();
            } else {
                state.site_bank_accounts.push(sba.clone());
            }
            if !state.site_bank_accounts.iter().any(|b| b.id == legacy_id) {
                let mut leg_sba = sba;
                leg_sba.id = legacy_id;
                state.site_bank_accounts.push(leg_sba);
            }
        }
        info!(
            "Loaded {} site bank accounts from PostgreSQL",
            state.site_bank_accounts.len()
        );
    }

    // 6. Load the unified payment ledger (payment_entries) and derive the legacy
    // homeowner-payment view from it so existing endpoints keep working.
    if let Ok(rows) = client
        .query(
            "SELECT id, site_id, unit_id, dues_liability_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, external_reference, payment_date, created_at FROM payment_entries ORDER BY payment_date ASC",
            &[],
        )
        .await
    {
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let unit_id: i64 = row.get(2);
            let _dues_liability_id: Option<i64> = row.get(3);
            let payer_name: String = row.get(4);
            let payer_role: String = row.get(5);
            let receipt_id: Option<i64> = row.get(6);
            let amount: Decimal = row.get(7);
            let payment_channel: String = row.get(8);
            let settlement_status: String = row.get(9);
            let description: Option<String> = row.get(10);
            let external_reference: Option<String> = row.get(11);
            let payment_date: Option<DateTime<Utc>> = row.get(12);
            let created_at: Option<DateTime<Utc>> = row.get(13);

            let entry = PaymentEntry {
                id,
                site_id: site_id.to_string(),
                unit_id: unit_id.to_string(),
                unit_label: None,
                payer_name: payer_name.clone(),
                payer_role,
                receipt_id,
                receipt_number: None,
                amount,
                payment_channel: payment_channel.clone(),
                settlement_status: settlement_status.clone(),
                description: description.clone(),
                external_reference: external_reference.clone(),
                payment_date: payment_date.unwrap_or_else(Utc::now),
                created_at: created_at.unwrap_or_else(Utc::now),
            };

            if let Some(pos) = state.payment_entries.iter().position(|e| e.id == id) {
                state.payment_entries[pos] = entry;
            } else {
                state.payment_entries.push(entry);
            }

            // Derive the legacy homeowner-payment record for the match/reconcile endpoints.
            let matched_unit = state.units.iter().find(|u| parse_id_to_i64(&u.id) == Some(unit_id));
            let record = HomeownerPaymentRecord {
                id: id.to_string(),
                unit_id: unit_id.to_string(),
                block_id: matched_unit.map(|u| u.block_id.clone()).unwrap_or_default(),
                unit_number: matched_unit.map(|u| u.unit_number).unwrap_or(0),
                homeowner_name: Some(payer_name),
                amount,
                payment_method: payment_channel,
                reference_code: external_reference,
                note: description,
                status: if settlement_status == "SETTLED" {
                    PaymentMatchStatus::MatchedDebt
                } else if settlement_status == "UNMATCHED" {
                    PaymentMatchStatus::Pending
                } else {
                    PaymentMatchStatus::MatchedDebt
                },
                cleared_debt_amount: if settlement_status == "SETTLED" { amount } else { Decimal::ZERO },
                advance_credit_amount: Decimal::ZERO,
                created_at: created_at.unwrap_or_else(Utc::now),
            };
            if let Some(pos) = state.homeowner_payments.iter().position(|h| h.id == record.id) {
                state.homeowner_payments[pos] = record;
            } else {
                state.homeowner_payments.push(record);
            }
        }
        info!(
            "Loaded {} payment entries from PostgreSQL",
            state.payment_entries.len()
        );
    }

    // 7. Load Pending Registrations
    if let Ok(rows) = client
        .query(
            "SELECT request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at FROM pending_registrations",
            &[],
        )
        .await
    {
        for row in rows {
            let req = PendingRegistrationResponse {
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
                submitted_at: row.get::<_, Option<DateTime<Utc>>>(10).unwrap_or_else(Utc::now),
            };
            if let Some(pos) = state.pending_registrations.iter().position(|r| r.request_id == req.request_id) {
                state.pending_registrations[pos] = req;
            } else {
                state.pending_registrations.push(req);
            }
        }
        info!("Loaded {} pending registrations from PostgreSQL", state.pending_registrations.len());
    }

    // 8. Load Household Members (occupancy_members — the canonical table)
    if let Ok(rows) = client
        .query(
            r#"
            SELECT uo.unit_id, om.id, om.full_name, om.relationship, om.phone, om.email,
                   om.occupancy_id, om.person_id, om.resident_user_id,
                   (uo.occupancy_type = 'OWNER') AS is_owner
            FROM occupancy_members om
            JOIN unit_occupancies uo ON om.occupancy_id = uo.id
            WHERE uo.is_active = true
            ORDER BY om.id ASC
            "#,
            &[],
        )
        .await
    {
        for row in rows {
            let unit_id: i64 = row.get(0);
            let key = unit_id.to_string();
            let member = UnitMemberDto {
                resident_id: row.get::<_, i64>(1).to_string(),
                full_name: row.get(2),
                relationship: row.get(3),
                phone: row.get::<_, Option<String>>(4).unwrap_or_default(),
                email: row.get::<_, Option<String>>(5).unwrap_or_default(),
                is_owner: row.get(9),
                occupancy_id: row.try_get(6).ok().flatten(),
                person_id: row.try_get(7).ok().flatten(),
                resident_user_id: row.try_get(8).ok().flatten(),
            };
            let list = state.unit_members.entry(key).or_default();
            if !list.iter().any(|m| m.resident_id == member.resident_id) {
                list.push(member);
            }
        }
        info!("Loaded household members for {} units from PostgreSQL", state.unit_members.len());
    }

    // 9. Load Invitation Tokens
    if let Ok(rows) = client
        .query(
            "SELECT token, site_id, unit_id, building, unit_number, relationship, invite_url, security_notice, expires_at FROM invitation_tokens",
            &[],
        )
        .await
    {
        for row in rows {
            let token: String = row.get(0);
            let unit_id: Option<i64> = row.get(2);
            let building: Option<String> = row.get(3);
            let unit_number: Option<String> = row.get(4);
            let relationship: Option<String> = row.get(5);
            let invite_url: String = row.get(6);
            let security_notice: Option<String> = row.get(7);
            let expires_at: DateTime<Utc> = row.get(8);

            let invite = UnitInviteLinkResponse {
                invite_url,
                token: token.clone(),
                unit_id: unit_id.map(|v| v.to_string()).unwrap_or_default(),
                building: building.unwrap_or_default(),
                unit_number: unit_number.unwrap_or_default(),
                relationship: relationship.unwrap_or_default(),
                expires_at,
                security_notice: security_notice.unwrap_or_default(),
            };
            state.unit_invite_tokens.insert(token, invite);
        }
    }

    // 10. Load Advance Balances
    if let Ok(rows) = client
        .query(
            "SELECT unit_id, balance FROM advance_balances",
            &[],
        )
        .await
    {
        for row in rows {
            let unit_id: i64 = row.get(0);
            let balance: Decimal = row.get(1);
            state.advance_payments.insert(unit_id.to_string(), balance);
        }
        info!("Loaded {} advance balances from PostgreSQL", state.advance_payments.len());
    }

    // 11. Load Unit Sender IBANs
    if let Ok(rows) = client
        .query(
            "SELECT sender_iban, unit_id, label, bank_name FROM unit_sender_ibans",
            &[],
        )
        .await
    {
        for row in rows {
            let sender_iban: String = row.get(0);
            let unit_id: i64 = row.get(1);
            let label: Option<String> = row.get(2);
            let bank_name: Option<String> = row.get(3);

            state.remembered_sender_ibans.insert(sender_iban.clone(), unit_id.to_string());
            state.sender_iban_metadata.insert(sender_iban, (label, bank_name));
        }
        info!("Loaded {} remembered sender IBANs from PostgreSQL", state.remembered_sender_ibans.len());
    }

    // 12. Load Unit Payer Names
    if let Ok(rows) = client
        .query(
            "SELECT unit_id, payer_name FROM unit_payer_names",
            &[],
        )
        .await
    {
        for row in rows {
            let unit_id: i64 = row.get(0);
            let payer_name: String = row.get(1);
            let list = state.unit_payer_names.entry(unit_id.to_string()).or_default();
            if !list.contains(&payer_name) {
                list.push(payer_name);
            }
        }
    }

    // 13. Load Reconciliation Queue
    if let Ok(rows) = client
        .query(
            "SELECT match_id, transaction_id, txn_date, amount, currency, description, sender_name, sender_iban, reference_no, matched_unit_id, matched_block, matched_unit_number, matched_resident_name, confidence_score, matched_due_id, outstanding_balance, amount_matches_balance, status, status_code, notes FROM reconciliation_queue ORDER BY txn_date ASC",
            &[],
        )
        .await
    {
        for row in rows {
            let match_id: String = row.get(0);
            let transaction_id: String = row.get(1);
            let txn_date: NaiveDate = row.get(2);
            let amount: Decimal = row.get(3);
            let currency: String = row.get(4);
            let description: String = row.get(5);
            let sender_name: Option<String> = row.get(6);
            let sender_iban: Option<String> = row.get(7);
            let reference_no: Option<String> = row.get(8);
            let matched_unit_id: Option<i64> = row.get(9);
            let matched_block: Option<String> = row.get(10);
            let matched_unit_number: Option<i32> = row.get(11);
            let matched_resident_name: Option<String> = row.get(12);
            let confidence_score: i32 = row.get(13);
            let matched_due_id: Option<i64> = row.get(14);
            let outstanding_balance: Option<Decimal> = row.get(15);
            let amount_matches_balance: bool = row.get(16);
            let status_str: String = row.get(17);
            let status_code: String = row.get(18);
            let notes: Option<String> = row.get(19);

            let status = match status_str.as_str() {
                "APPROVED" | "ONAYLANDI" => ReconciliationStatus::Approved,
                "ALREADY_PROCESSED" => ReconciliationStatus::AlreadyProcessed,
                "UNMATCHED" | "ESLESTIRILEMEDI" => ReconciliationStatus::Unmatched,
                _ => ReconciliationStatus::PendingApproval,
            };

            let m = ReconciliationMatch {
                match_id: match_id.clone(),
                transaction: BankTransactionItem {
                    transaction_id,
                    date: txn_date,
                    amount,
                    currency,
                    description,
                    sender_name,
                    sender_iban,
                    reference_no,
                },
                matched_unit_id: matched_unit_id.map(|v| v.to_string()),
                matched_block,
                matched_unit_number,
                matched_resident_name,
                confidence_score: confidence_score as u8,
                matched_due_id: matched_due_id.map(|v| v.to_string()),
                outstanding_balance,
                amount_matches_balance,
                status,
                status_code,
                notes,
            };

            if let Some(pos) = state.reconciliation_queue.iter().position(|q| q.match_id == m.match_id) {
                state.reconciliation_queue[pos] = m;
            } else {
                state.reconciliation_queue.push(m);
            }
        }
        info!("Loaded {} reconciliation queue items from PostgreSQL", state.reconciliation_queue.len());
    }
}

pub async fn save_site(pool: &Pool, site: &Site) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(&site.id).unwrap_or(1);
    client
        .execute(
            r#"
            INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (id) DO UPDATE SET
                name = EXCLUDED.name,
                address = EXCLUDED.address,
                slug = EXCLUDED.slug,
                status = EXCLUDED.status,
                plan_type = EXCLUDED.plan_type,
                license_end_date = EXCLUDED.license_end_date
            "#,
            &[
                &id_num,
                &site.name,
                &site.address,
                &site.slug,
                &site.status,
                &site.plan_type,
                &site.license_end_date,
            ],
        )
        .await?;
    info!("Saved site {} (numeric ID: {}) ({}) to PostgreSQL sites", site.id, id_num, site.name);
    Ok(())
}

pub async fn delete_site(pool: &Pool, site_id: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(site_id).unwrap_or(0);
    client.execute("DELETE FROM sites WHERE id = $1", &[&id_num]).await?;
    info!("Deleted site {} (numeric ID: {}) from PostgreSQL sites", site_id, id_num);
    Ok(())
}

pub async fn save_user(pool: &Pool, user: &User) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let role_str = user.role.as_str();
    let id_num = parse_id_to_i64(&user.id).unwrap_or(1);
    let site_id_num = parse_id_to_i64(&user.site_id);
    
    // Resolve, link, and synchronize person_id
    let person_id: Option<i64> = if let Some(pid) = user.person_id {
        if !user.full_name.is_empty() {
            let _ = client.execute(
                "UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3",
                &[&user.full_name, &user.phone, &pid],
            ).await;
        }
        Some(pid)
    } else {
        let p_row = client
            .query_opt("SELECT id FROM persons WHERE LOWER(email) = LOWER($1)", &[&user.email])
            .await?;
        if let Some(r) = p_row {
            let pid: i64 = r.get(0);
            if !user.full_name.is_empty() {
                let _ = client.execute(
                    "UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3",
                    &[&user.full_name, &user.phone, &pid],
                ).await;
            }
            Some(pid)
        } else if !user.full_name.is_empty() {
            let p_type = match user.role {
                Role::HomeOwner => "HOME_OWNER",
                Role::HomeResident => "HOME_RESIDENT",
                _ => "SITE_MANAGER",
            };
            let row = client
                .query_one(
                    "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, $4) RETURNING id",
                    &[&user.full_name, &user.phone, &user.email.to_lowercase(), &p_type],
                )
                .await?;
            Some(row.get(0))
        } else {
            None
        }
    };
    
    let updated = client
        .execute(
            r#"
            UPDATE users SET
                site_id = COALESCE($2, site_id),
                password_hash = COALESCE($4, password_hash),
                role = $5,
                must_change_password = $6,
                auth_provider = $7,
                google_sub = COALESCE($8, google_sub),
                avatar_url = COALESCE($9, avatar_url),
                person_id = COALESCE($10, person_id)
            WHERE id = $1 OR LOWER(email) = LOWER($3)
            "#,
            &[
                &id_num,
                &site_id_num,
                &user.email,
                &user.password_hash,
                &role_str,
                &user.must_change_password,
                &user.auth_provider,
                &user.google_sub,
                &user.avatar_url,
                &person_id,
            ],
        )
        .await?;

    if updated == 0 {
        client
            .execute(
                r#"
                INSERT INTO users (id, site_id, email, password_hash, role, must_change_password, auth_provider, google_sub, avatar_url, person_id, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                ON CONFLICT (id) DO UPDATE SET
                    site_id = EXCLUDED.site_id,
                    email = EXCLUDED.email,
                    password_hash = COALESCE(EXCLUDED.password_hash, users.password_hash),
                    role = EXCLUDED.role,
                    must_change_password = EXCLUDED.must_change_password,
                    auth_provider = EXCLUDED.auth_provider,
                    google_sub = COALESCE(EXCLUDED.google_sub, users.google_sub),
                    avatar_url = COALESCE(EXCLUDED.avatar_url, users.avatar_url),
                    person_id = COALESCE(EXCLUDED.person_id, users.person_id)
                "#,
                &[
                    &id_num,
                    &site_id_num,
                    &user.email,
                    &user.password_hash,
                    &role_str,
                    &user.must_change_password,
                    &user.auth_provider,
                    &user.google_sub,
                    &user.avatar_url,
                    &person_id,
                    &user.created_at,
                ],
            )
            .await?;
    }
    info!("Saved user {} (numeric ID: {}) ({}) to PostgreSQL users", user.id, id_num, user.email);
    Ok(())
}

pub async fn save_unit(pool: &Pool, unit: &IndependentUnit) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(&unit.id).unwrap_or(unit.unit_number as i64);
    let site_id_num = parse_id_to_i64(&unit.site_id).unwrap_or(1);

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
        let exists = client.query_opt("SELECT id FROM persons WHERE id = $1", &[&oid]).await?.is_some();
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
        let exists = client.query_opt("SELECT id FROM persons WHERE id = $1", &[&tid]).await?.is_some();
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
    info!("Saved unit {} (numeric ID: {}, D:{}) to PostgreSQL units", unit.id, id_num, unit.unit_number);
    Ok(())
}

pub async fn save_dues_period(
    pool: &Pool,
    period: &crate::models::DuesPeriod,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(&period.id).unwrap_or(1);
    let site_id_num = parse_id_to_i64(&period.site_id).unwrap_or(1);

    client
        .execute(
            r#"
            INSERT INTO dues_periods (id, site_id, period_name, due_date, status)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (site_id, period_name) DO UPDATE SET
                due_date = EXCLUDED.due_date,
                status = EXCLUDED.status
            "#,
            &[
                &id_num,
                &site_id_num,
                &period.period_name,
                &period.due_date,
                &period.status,
            ],
        )
        .await?;
    info!("Saved dues period '{}' (numeric ID: {}) for site {} to PostgreSQL", period.period_name, id_num, period.site_id);
    Ok(())
}

#[allow(dead_code)]
pub async fn get_dues_periods_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<crate::models::DuesPeriod>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = parse_id_to_i64(site_id).unwrap_or(1);
    let rows = client
        .query(
            "SELECT id, site_id, period_name, due_date, status, created_at FROM dues_periods WHERE site_id = $1 ORDER BY due_date ASC",
            &[&site_id_num],
        )
        .await?;
    let mut list = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let s_id: i64 = row.get(1);
        let period_name: String = row.get(2);
        let due_date: NaiveDate = row.get(3);
        let status: String = row.get(4);
        let created_at: Option<DateTime<Utc>> = row.get(5);
        list.push(crate::models::DuesPeriod {
            id: id.to_string(),
            site_id: s_id.to_string(),
            period_name,
            due_date,
            status,
            created_at,
        });
    }
    Ok(list)
}

pub async fn save_due_liability(
    pool: &Pool,
    due: &DuesLiability,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let status_str = match due.status {
        DebtStatus::Paid => "PAID",
        DebtStatus::Overdue => "OVERDUE",
        DebtStatus::Pending => "PENDING",
    };
    let due_id_num = parse_id_to_i64(&due.id).unwrap_or(101);
    let unit_id_num = parse_id_to_i64(&due.unit_id).unwrap_or(14);

    client
        .execute(
            r#"
            INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (id) DO UPDATE SET
                unit_id = EXCLUDED.unit_id,
                period = EXCLUDED.period,
                principal_amount = EXCLUDED.principal_amount,
                due_date = EXCLUDED.due_date,
                status = EXCLUDED.status,
                delay_penalty = EXCLUDED.delay_penalty
            "#,
            &[
                &due_id_num,
                &unit_id_num,
                &due.period,
                &due.principal_amount,
                &due.due_date,
                &status_str,
                &due.delay_penalty,
            ],
        )
        .await?;
    info!("Saved due liability {} (numeric ID: {}) for unit {} to PostgreSQL", due.id, due_id_num, unit_id_num);
    Ok(())
}

pub async fn update_due_liability(
    pool: &Pool,
    due_id: &str,
    status: &str,
    paid_amount: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let due_id_num = parse_id_to_i64(due_id).unwrap_or(101);
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET status = $2, paid_amount = $3, payment_date = CURRENT_TIMESTAMP
            WHERE id = $1
            "#,
            &[&due_id_num, &status, &paid_amount],
        )
        .await?;
    info!("Updated dues liability {} (numeric ID: {}) to status {} in PostgreSQL", due_id, due_id_num, status);
    Ok(())
}

pub async fn save_collection_transaction(
    pool: &Pool,
    _id: &str,
    dues_liability_id: Option<&str>,
    unit_id: Option<&str>,
    transaction_type: &str,
    paid_amount: Decimal,
    reference_code: Option<&str>,
    description: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;

    let parsed_due_id = dues_liability_id.and_then(parse_id_to_i64);
    let parsed_unit_id = unit_id.and_then(parse_id_to_i64).or(Some(14));

    // The unified ledger is FK-bound to both sites and units, so resolve the site
    // from the unit instead of trusting the caller's string site id.
    let site_id: i64 = client
        .query_opt("SELECT site_id FROM units WHERE id = $1", &[&parsed_unit_id])
        .await?
        .map(|r| r.get(0))
        .unwrap_or(1);

    let channel = match transaction_type {
        "CREDIT_CARD_POS" => "CREDIT_CARD",
        "BANK_TRANSFER" => "BANK_TRANSFER",
        "CASH" => "MANUAL_CASH",
        other => other,
    };

    client
        .execute(
            r#"
            INSERT INTO payment_entries (site_id, unit_id, dues_liability_id, payer_name, payer_role, amount, payment_channel, settlement_status, description, external_reference, payment_date, created_at)
            VALUES ($1, $2, $3, $4, 'OWNER', $5, $6, 'SETTLED', $7, $8, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            "#,
            &[
                &site_id,
                &parsed_unit_id,
                &parsed_due_id,
                &description.map(|d| d.to_string()).unwrap_or_else(|| "Unknown payer".to_string()),
                &paid_amount,
                &channel,
                &description,
                &reference_code,
            ],
        )
        .await?;

    info!(
        "Saved collection transaction (₺{}) to the unified payment_entries ledger",
        paid_amount
    );
    Ok(())
}

pub async fn save_site_bank_account(
    pool: &Pool,
    account: &SiteBankAccount,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(&account.id).unwrap_or(1);
    let site_id_num = parse_id_to_i64(&account.site_id).unwrap_or(1);
    let config_by_num = account.configured_by.as_deref().and_then(parse_id_to_i64);

    client
        .execute(
            r#"
            INSERT INTO site_bank_accounts (id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            ON CONFLICT (id) DO UPDATE SET
                site_id = EXCLUDED.site_id,
                bank_code = EXCLUDED.bank_code,
                bank_name = EXCLUDED.bank_name,
                iban = EXCLUDED.iban,
                account_holder = EXCLUDED.account_holder,
                statement_format = EXCLUDED.statement_format,
                is_active = EXCLUDED.is_active,
                configured_by = EXCLUDED.configured_by,
                updated_at = CURRENT_TIMESTAMP
            "#,
            &[
                &id_num,
                &site_id_num,
                &account.bank_code,
                &account.bank_name,
                &account.iban,
                &account.account_holder,
                &account.statement_format,
                &account.is_active,
                &config_by_num,
                &account.created_at,
                &account.updated_at,
            ],
        )
        .await?;
    info!("Saved site bank account {} (numeric ID: {}) to PostgreSQL", account.id, id_num);
    Ok(())
}

pub async fn save_advance_balance(
    pool: &Pool,
    unit_id: &str,
    balance: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = parse_id_to_i64(unit_id).unwrap_or(1);
    client
        .execute(
            r#"
            INSERT INTO advance_balances (unit_id, balance, updated_at)
            VALUES ($1, $2, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id) DO UPDATE SET
                balance = EXCLUDED.balance,
                updated_at = CURRENT_TIMESTAMP
            "#,
            &[&unit_id_num, &balance],
        )
        .await?;
    info!("Saved advance balance (₺{}) for unit {} to PostgreSQL", balance, unit_id);
    Ok(())
}

pub async fn save_pending_registration(
    pool: &Pool,
    req: &PendingRegistrationResponse,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = parse_id_to_i64(&req.site_id).unwrap_or(1);
    client
        .execute(
            r#"
            INSERT INTO pending_registrations (request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            ON CONFLICT (request_id) DO UPDATE SET
                status = EXCLUDED.status,
                full_name = EXCLUDED.full_name,
                email = EXCLUDED.email,
                phone = EXCLUDED.phone
            "#,
            &[
                &req.request_id,
                &site_id_num,
                &req.block,
                &req.unit_no,
                &req.floor,
                &req.full_name,
                &req.email,
                &req.phone,
                &req.is_resident,
                &req.status,
                &req.submitted_at,
            ],
        )
        .await?;
    info!("Saved pending registration {} ({}) to PostgreSQL", req.request_id, req.email);
    Ok(())
}

pub async fn update_pending_registration_status(
    pool: &Pool,
    request_id: &str,
    status: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            "UPDATE pending_registrations SET status = $2 WHERE request_id = $1",
            &[&request_id, &status],
        )
        .await?;
    info!("Updated pending registration {} status to {} in PostgreSQL", request_id, status);
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
    let u_num = parse_id_to_i64(unit_id).unwrap_or(1);

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

pub async fn save_invitation_token(
    pool: &Pool,
    invite: &UnitInviteLinkResponse,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = if invite.unit_id.is_empty() {
        None
    } else {
        parse_id_to_i64(&invite.unit_id)
    };
    client
        .execute(
            r#"
            INSERT INTO invitation_tokens (token, token_type, unit_id, building, unit_number, relationship, invite_url, security_notice, expires_at)
            VALUES ($1, 'UNIT', $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (token) DO UPDATE SET
                expires_at = EXCLUDED.expires_at
            "#,
            &[
                &invite.token,
                &unit_id_num,
                &invite.building,
                &invite.unit_number,
                &invite.relationship,
                &invite.invite_url,
                &invite.security_notice,
                &invite.expires_at,
            ],
        )
        .await?;
    info!("Saved invitation token {} to PostgreSQL", invite.token);
    Ok(())
}

pub async fn save_remembered_sender_iban(
    pool: &Pool,
    iban: &str,
    unit_id: &str,
    label: Option<&str>,
    bank_name: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = parse_id_to_i64(unit_id).unwrap_or(1);
    client
        .execute(
            r#"
            INSERT INTO unit_sender_ibans (sender_iban, unit_id, label, bank_name, created_at)
            VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
            ON CONFLICT (sender_iban) DO UPDATE SET
                unit_id = EXCLUDED.unit_id,
                label = EXCLUDED.label,
                bank_name = EXCLUDED.bank_name
            "#,
            &[&iban, &unit_id_num, &label, &bank_name],
        )
        .await?;
    info!("Saved remembered sender IBAN {} for unit {} to PostgreSQL", iban, unit_id);
    Ok(())
}

pub async fn delete_remembered_sender_iban(
    pool: &Pool,
    iban: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute("DELETE FROM unit_sender_ibans WHERE sender_iban = $1", &[&iban])
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
    let unit_id_num = parse_id_to_i64(unit_id).unwrap_or(1);
    client.execute("DELETE FROM unit_payer_names WHERE unit_id = $1", &[&unit_id_num]).await?;
    for name in names {
        let _ = client
            .execute(
                "INSERT INTO unit_payer_names (unit_id, payer_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                &[&unit_id_num, &name],
            )
            .await;
    }
    info!("Saved {} payer names for unit {} to PostgreSQL", names.len(), unit_id);
    Ok(())
}

pub async fn save_reconciliation_match(
    pool: &Pool,
    m: &ReconciliationMatch,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let status_str = format!("{:?}", m.status);
    let confidence_i32 = m.confidence_score as i32;
    let matched_unit_num = m.matched_unit_id.as_deref().and_then(parse_id_to_i64);
    let matched_due_num = m.matched_due_id.as_deref().and_then(parse_id_to_i64);
    client
        .execute(
            r#"
            INSERT INTO reconciliation_queue (match_id, transaction_id, txn_date, amount, currency, description, sender_name, sender_iban, reference_no, matched_unit_id, matched_block, matched_unit_number, matched_resident_name, confidence_score, matched_due_id, outstanding_balance, amount_matches_balance, status, status_code, notes, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, CURRENT_TIMESTAMP)
            ON CONFLICT (match_id) DO UPDATE SET
                status = EXCLUDED.status,
                status_code = EXCLUDED.status_code,
                notes = EXCLUDED.notes
            "#,
            &[
                &m.match_id,
                &m.transaction.transaction_id,
                &m.transaction.date,
                &m.transaction.amount,
                &m.transaction.currency,
                &m.transaction.description,
                &m.transaction.sender_name,
                &m.transaction.sender_iban,
                &m.transaction.reference_no,
                &matched_unit_num,
                &m.matched_block,
                &m.matched_unit_number,
                &m.matched_resident_name,
                &confidence_i32,
                &matched_due_num,
                &m.outstanding_balance,
                &m.amount_matches_balance,
                &status_str,
                &m.status_code,
                &m.notes,
            ],
        )
        .await?;
    info!("Saved reconciliation match {} to PostgreSQL", m.match_id);
    Ok(())
}

pub async fn update_reconciliation_status(
    pool: &Pool,
    match_id: &str,
    status: &str,
    status_code: &str,
    notes: Option<&str>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            "UPDATE reconciliation_queue SET status = $2, status_code = $3, notes = COALESCE($4, notes) WHERE match_id = $1",
            &[&match_id, &status, &status_code, &notes],
        )
        .await?;
    info!("Updated reconciliation match {} status to {} in PostgreSQL", match_id, status);
    Ok(())
}

pub async fn save_homeowner_payment(
    pool: &Pool,
    rec: &HomeownerPaymentRecord,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;

    let parsed_unit_id = parse_id_to_i64(&rec.unit_id).unwrap_or(1);
    let site_id: i64 = client
        .query_opt("SELECT site_id FROM units WHERE id = $1", &[&parsed_unit_id])
        .await?
        .map(|r| r.get(0))
        .unwrap_or(1);

    let settlement_status = match rec.status {
        PaymentMatchStatus::Pending => "UNMATCHED",
        _ => "SETTLED",
    };

    client
        .execute(
            r#"
            INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, amount, payment_channel, settlement_status, description, external_reference, payment_date, created_at)
            VALUES ($1, $2, $3, 'OWNER', $4, $5, $6, $7, $8, $9, $9)
            "#,
            &[
                &site_id,
                &parsed_unit_id,
                &rec.homeowner_name.clone().unwrap_or_else(|| "Unknown payer".to_string()),
                &rec.amount,
                &rec.payment_method,
                &settlement_status,
                &rec.note,
                &rec.reference_code.clone().unwrap_or_else(|| rec.id.clone()),
                &rec.created_at,
            ],
        )
        .await?;
    info!("Saved homeowner payment {} (₺{}) to the unified payment_entries ledger", rec.id, rec.amount);
    Ok(())
}

pub async fn update_homeowner_payment_match(
    pool: &Pool,
    id: &str,
    status: &str,
    _cleared: Decimal,
    _advance: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // The debt/advance split is recomputed in memory by match_all; persist only the
    // resulting settlement state onto the canonical ledger (identified by external ref).
    let settlement_status = match status {
        "Pending" => "UNMATCHED",
        "Unmatched" => "UNMATCHED",
        "Refunded" => "REFUNDED",
        _ => "SETTLED",
    };
    let client = pool.get().await?;
    client
        .execute(
            "UPDATE payment_entries SET settlement_status = $2 WHERE external_reference = $1 OR id::text = $1",
            &[&id, &settlement_status],
        )
        .await?;
    info!("Updated payment entry {} match in PostgreSQL", id);
    Ok(())
}

pub async fn get_user_by_email(
    pool: &Pool,
    email: &str,
) -> Result<Option<User>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let email_norm = email.trim().to_lowercase();
    let row = client
        .query_opt(
            "SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
             FROM users u
             LEFT JOIN persons p ON u.person_id = p.id
             WHERE LOWER(u.email) = $1 LIMIT 1",
            &[&email_norm],
        )
        .await?;

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: Option<i64> = row.get(1);
        let full_name: String = row.get(2);
        let email: String = row.get(3);
        let phone: Option<String> = row.get(4);
        let password_hash: Option<String> = row.get(5);
        let role_str: String = row.get(6);
        let must_change_password: bool = row.get(7);
        let auth_provider: Option<String> = row.get(8);
        let google_sub: Option<String> = row.get(9);
        let avatar_url: Option<String> = row.get(10);
        let created_at: Option<DateTime<Utc>> = row.get(11);
        let person_id: Option<i64> = row.try_get(12).ok().flatten();

        let user = User {
            id: match id {
                1 => "usr-saas-root".to_string(),
                2 => "usr-site-manager-1".to_string(),
                3 => "usr-home-owner-1".to_string(),
                _ => format!("usr-{}", id),
            },
            site_id: site_id.map(|s| s.to_string()).unwrap_or_else(|| "1".to_string()),
            full_name,
            email,
            phone: phone.unwrap_or_default(),
            password_hash,
            role: Role::from_str_loose(&role_str),
            must_change_password,
            auth_provider: auth_provider.unwrap_or_else(|| "LOCAL".to_string()),
            google_sub,
            avatar_url,
            created_at: created_at.unwrap_or_else(Utc::now),
            person_id,
        };
        return Ok(Some(user));
    }
    Ok(None)
}

pub async fn get_user_by_id(
    pool: &Pool,
    user_id: &str,
) -> Result<Option<User>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = parse_id_to_i64(user_id);
    let row = if let Some(num) = id_num {
        client
            .query_opt(
                "SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
                 FROM users u
                 LEFT JOIN persons p ON u.person_id = p.id
                 WHERE u.id = $1 LIMIT 1",
                &[&num],
            )
            .await?
    } else {
        None
    };

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: Option<i64> = row.get(1);
        let full_name: String = row.get(2);
        let email: String = row.get(3);
        let phone: Option<String> = row.get(4);
        let password_hash: Option<String> = row.get(5);
        let role_str: String = row.get(6);
        let must_change_password: bool = row.get(7);
        let auth_provider: Option<String> = row.get(8);
        let google_sub: Option<String> = row.get(9);
        let avatar_url: Option<String> = row.get(10);
        let created_at: Option<DateTime<Utc>> = row.get(11);
        let person_id: Option<i64> = row.try_get(12).ok().flatten();

        let user = User {
            id: match id {
                1 => "usr-saas-root".to_string(),
                2 => "usr-site-manager-1".to_string(),
                3 => "usr-home-owner-1".to_string(),
                _ => format!("usr-{}", id),
            },
            site_id: site_id.map(|s| s.to_string()).unwrap_or_else(|| "1".to_string()),
            full_name,
            email,
            phone: phone.unwrap_or_default(),
            password_hash,
            role: Role::from_str_loose(&role_str),
            must_change_password,
            auth_provider: auth_provider.unwrap_or_else(|| "LOCAL".to_string()),
            google_sub,
            avatar_url,
            created_at: created_at.unwrap_or_else(Utc::now),
            person_id,
        };
        return Ok(Some(user));
    }
    Ok(None)
}

pub async fn get_active_site_bank_account(
    pool: &Pool,
    site_id: &str,
) -> Result<Option<SiteBankAccount>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = parse_id_to_i64(site_id).unwrap_or(1);
    let row = client
        .query_opt(
            "SELECT id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at FROM site_bank_accounts WHERE site_id = $1 AND is_active = TRUE ORDER BY updated_at DESC LIMIT 1",
            &[&site_id_num],
        )
        .await?;

    if let Some(row) = row {
        let id: i64 = row.get(0);
        let site_id: i64 = row.get(1);
        let bank_code: String = row.get(2);
        let bank_name: String = row.get(3);
        let iban: String = row.get(4);
        let account_holder: String = row.get(5);
        let statement_format: String = row.get(6);
        let is_active: bool = row.get(7);
        let configured_by: Option<i64> = row.get(8);
        let created_at: Option<DateTime<Utc>> = row.get(9);
        let updated_at: Option<DateTime<Utc>> = row.get(10);

        return Ok(Some(SiteBankAccount {
            id: format!("sba-{}", id),
            site_id: format!("site-{}", site_id),
            bank_code,
            bank_name,
            iban,
            account_holder,
            statement_format,
            is_active,
            configured_by: configured_by.map(|c| format!("usr-{}", c)),
            created_at: created_at.unwrap_or_else(Utc::now),
            updated_at: updated_at.unwrap_or_else(Utc::now),
        }));
    }
    Ok(None)
}

pub async fn get_blocks_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<BlockDto>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = parse_id_to_i64(site_id).unwrap_or(1);
    let rows = client
        .query(
            "SELECT id, site_id, block_name, total_floors FROM blocks WHERE site_id = $1 ORDER BY id ASC",
            &[&site_id_num],
        )
        .await?;

    let mut list = Vec::new();
    for row in rows {
        let id: i64 = row.get(0);
        let s_id: i64 = row.get(1);
        let block_name: String = row.get(2);
        let total_floors: i32 = row.get(3);

        list.push(BlockDto {
            id: format!("b-{}", id),
            site_id: format!("site-{}", s_id),
            block_name,
            total_floors,
        });
    }
    Ok(list)
}

pub async fn sync_all_in_memory_to_db(
    pool: &Pool,
    state: &AppStateInner,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;

    // 1. Sync Sites
    for site in &state.sites {
        let _ = save_site(pool, site).await;
    }

    // 2. Sync Blocks
    for block in &state.blocks {
        let block_id_num = parse_id_to_i64(&block.id).unwrap_or(1);
        let site_id_num = parse_id_to_i64(&block.site_id).unwrap_or(1);
        let _ = client
            .execute(
                r#"
                INSERT INTO blocks (id, site_id, block_name, total_floors)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (id) DO UPDATE SET
                    site_id = EXCLUDED.site_id,
                    block_name = EXCLUDED.block_name,
                    total_floors = EXCLUDED.total_floors
                "#,
                &[&block_id_num, &site_id_num, &block.block_name, &block.total_floors],
            )
            .await;
    }

    // 3. Sync Users and Persons
    for user in &state.users {
        let user_id_num = parse_id_to_i64(&user.id).unwrap_or(1);
        let p_type = match user.role {
            Role::HomeOwner => "HOME_OWNER",
            Role::HomeResident => "HOME_RESIDENT",
            _ => "SITE_MANAGER",
        };
        let _ = client
            .execute(
                r#"
                INSERT INTO persons (id, full_name, phone, email, person_type)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (id) DO UPDATE SET
                    full_name = EXCLUDED.full_name,
                    phone = EXCLUDED.phone,
                    email = EXCLUDED.email,
                    person_type = EXCLUDED.person_type
                "#,
                &[&user_id_num, &user.full_name, &user.phone, &user.email, &p_type],
            )
            .await;

        let _ = save_user(pool, user).await;
    }

    // 4. Sync Units
    for unit in &state.units {
        let _ = save_unit(pool, unit).await;
    }

    // 5. Sync Dues Liabilities
    for due in &state.dues {
        let _ = save_due_liability(pool, due).await;
    }

    // 6. Sync Remembered Sender IBANs & Payer Names
    for (iban, unit_id) in &state.remembered_sender_ibans {
        let meta = state.sender_iban_metadata.get(iban);
        let label = meta.and_then(|m| m.0.as_deref());
        let bank = meta.and_then(|m| m.1.as_deref());
        let _ = save_remembered_sender_iban(pool, iban, unit_id, label, bank).await;
    }
    for (unit_id, names) in &state.unit_payer_names {
        let _ = save_unit_payer_names(pool, unit_id, names).await;
    }

    info!("Synchronized all in-memory state to PostgreSQL database successfully.");
    Ok(())
}
