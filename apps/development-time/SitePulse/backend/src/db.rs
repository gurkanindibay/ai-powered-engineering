use chrono::{DateTime, NaiveDate, Utc};
use deadpool_postgres::{Config, ManagerConfig, Pool, RecyclingMethod, Runtime};
use rust_decimal::Decimal;
use tokio_postgres::NoTls;
use tracing::{info, warn};

use crate::models::{
    AllocationBreakdownItem, BankTransactionItem, BlockDto, DebtStatus, DuesLiability,
    HomeownerPaymentRecord, IndependentUnit, OccupancyHistoryItem, PaymentEntry, PaymentMatchStatus,
    PaymentReceipt, PendingRegistrationResponse, ReconciliationMatch, ReconciliationStatus, Role,
    Site, SiteBankAccount, UnitInviteLinkResponse, UnitMemberDto, User,
};
use crate::services::VirtualIbanService;
use crate::state::AppStateInner;

/// Builds the PostgreSQL pool from the environment.
///
/// * `DB_PASS` has no default: credentials never live in source code. Without
///   it the backend refuses to start, unless `SITEPULSE_IN_MEMORY=true` asks for
///   the database-less demo mode explicitly (never allowed in production).
/// * `DB_SSLMODE=require` encrypts the connection with TLS (rustls, verified
///   against the Mozilla root store). The default is `disable` for local
///   development; production requires `require`.
pub fn create_pool() -> Option<Pool> {
    let in_memory = std::env::var("SITEPULSE_IN_MEMORY").map(|v| v == "true").unwrap_or(false);
    let production = crate::state::AppStateInner::is_production();
    let password = match std::env::var("DB_PASS") {
        Ok(p) if !p.is_empty() => p,
        _ if in_memory && !production => {
            warn!("SITEPULSE_IN_MEMORY=true: running without PostgreSQL; nothing will be persisted");
            return None;
        }
        _ => panic!("DB_PASS is required (set it in backend/.env); use SITEPULSE_IN_MEMORY=true for a database-less demo"),
    };
    let host = std::env::var("DB_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("DB_PORT").ok().and_then(|p| p.parse::<u16>().ok()).unwrap_or(5432);
    let user = std::env::var("DB_USER").unwrap_or_else(|_| "sitepulse_user".to_string());
    let dbname = std::env::var("DB_NAME").unwrap_or_else(|_| "sitepulse".to_string());
    let ssl_mode = std::env::var("DB_SSLMODE").unwrap_or_else(|_| "disable".to_string()).to_lowercase();
    if production && ssl_mode != "require" {
        panic!("DB_SSLMODE=require is mandatory in production");
    }

    let mut cfg = Config::new();
    cfg.host = Some(host);
    cfg.port = Some(port);
    cfg.user = Some(user);
    cfg.password = Some(password);
    cfg.dbname = Some(dbname);
    cfg.manager = Some(ManagerConfig { recycling_method: RecyclingMethod::Fast });

    let pool = match ssl_mode.as_str() {
        "require" => {
            let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
            let tls_config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("rustls protocol versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
            cfg.create_pool(Some(Runtime::Tokio1), tokio_postgres_rustls::MakeRustlsConnect::new(tls_config))
        }
        "disable" => cfg.create_pool(Some(Runtime::Tokio1), NoTls),
        other => panic!("Unsupported DB_SSLMODE '{}': use 'disable' or 'require'", other),
    };
    match pool {
        Ok(pool) => {
            info!("PostgreSQL connection pool configured (sslmode={})", ssl_mode);
            Some(pool)
        }
        Err(e) => panic!("Failed to create PostgreSQL connection pool: {}", e),
    }
}

/// Parses an in-memory id into its PostgreSQL BIGINT id.
///
/// Accepts a bare positive integer or a known prefix followed by one
/// (`site-1`, `d-14`, `person-7`, ...). Anything else is `None`: there are no
/// hard-coded name mappings and no hex fallback, so an unknown id can never be
/// silently mapped onto some other row.
pub fn parse_id_to_i64(s: &str) -> Option<i64> {
    const PREFIXES: [&str; 21] = [
        "site-", "unit-", "d-", "b-", "borc-", "person-", "kisi-", "blk-", "blok-", "sba-", "txn-", "cproj-",
        "cinst-", "cdis-", "usr-", "user-", "req-", "inv-", "match-", "ref-", "due-",
    ];
    let s = s.trim();
    let positive = |n: i64| if n > 0 { Some(n) } else { None };
    if let Ok(n) = s.parse::<i64>() {
        return positive(n);
    }
    PREFIXES
        .iter()
        .find_map(|p| s.strip_prefix(p))
        .and_then(|rest| rest.parse::<i64>().ok())
        .and_then(positive)
}

/// Turns a read error into `None` *after logging it*, for read paths that can
/// fall back to cached data. Database errors are never dropped silently.
pub fn logged<T, E: std::fmt::Display>(result: Result<T, E>, what: &str) -> Option<T> {
    match result {
        Ok(v) => Some(v),
        Err(e) => {
            tracing::error!("Database read failed ({}): {}", what, e);
            None
        }
    }
}

/// Like `parse_id_to_i64` but returns a descriptive error for use with `?`.
pub fn require_id(kind: &str, s: &str) -> Result<i64, String> {
    parse_id_to_i64(s).ok_or_else(|| format!("Invalid {} id: '{}'", kind, s))
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
        // Never drop data automatically: refuse to start and let an operator migrate.
        return Err("Legacy VARCHAR-id schema detected in this database. Refusing to start: \
                    migrate or restore it manually (SitePulse no longer drops tables at boot)."
            .into());
    }

    // Apply pending versioned migrations (backend/migrations is the only schema source).
    drop(client);
    let applied = crate::migrations::run(pool).await?;
    if !applied.is_empty() {
        info!("Applied schema migrations {:?}; schema is at V{}", applied, crate::migrations::latest_version());
    }
    let client = pool.get().await?;

    // Seed system reference data (banks, configs, root SaaS admin).
    client
        .batch_execute(include_str!("../db/seed/01-system-seed.sql"))
        .await?;

    // 2. Synchronize sequences
    client
        .batch_execute(
            r#"
            DO $$
            DECLARE r record;
            BEGIN
                FOR r IN SELECT table_name, column_name FROM information_schema.columns
                         WHERE table_schema = 'public' AND is_identity = 'YES' LOOP
                    EXECUTE format(
                        'SELECT setval(pg_get_serial_sequence(%L, %L), COALESCE((SELECT MAX(%I) FROM %I), 0) + 1, false)',
                        r.table_name, r.column_name, r.column_name, r.table_name);
                END LOOP;
            END $$;
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
        .batch_execute(include_str!("../db/seed/02-test-seed.sql"))
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

            DO $$
            DECLARE r record;
            BEGIN
                FOR r IN SELECT table_name, column_name FROM information_schema.columns
                         WHERE table_schema = 'public' AND is_identity = 'YES' LOOP
                    EXECUTE format(
                        'SELECT setval(pg_get_serial_sequence(%L, %L), COALESCE((SELECT MAX(%I) FROM %I), 0) + 1, false)',
                        r.table_name, r.column_name, r.column_name, r.table_name);
                END LOOP;
            END $$;
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
            -- with the migrations automatically; init_db() recreates everything from them.
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
            -- with the migrations automatically; init_db() recreates everything from them.
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

/// Replaces the element with the same id, or appends it. One copy per id.
fn upsert_by_id<T>(items: &mut Vec<T>, item: T, id: impl Fn(&T) -> &String) {
    let key = id(&item).clone();
    if let Some(pos) = items.iter().position(|x| *id(x) == key) {
        items[pos] = item;
    } else {
        items.push(item);
    }
}

pub async fn load_all_from_db(pool: &Pool, state: &mut AppStateInner) -> DbResult<()> {
    let client = pool.get().await?;

    // 1. Load Sites
    {
        let rows = client.query("SELECT id, name, address, slug, status, plan_type, license_end_date, timezone FROM sites WHERE deleted_at IS NULL",
            &[],).await?;
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
                timezone: row.get::<_, Option<String>>(7).unwrap_or_else(crate::models::default_site_timezone),
            };

            upsert_by_id(&mut state.sites, s, |x| &x.id);
        }
        info!("Loaded {} sites from PostgreSQL", state.sites.len());
    }

    // 2. Load Users
    {
        let rows = client.query("SELECT u.id, u.site_id, COALESCE(p.full_name, ''), u.email, COALESCE(p.phone, ''), u.password_hash, u.role, u.must_change_password, u.auth_provider, u.google_sub, u.avatar_url, u.created_at, u.person_id
             FROM users u
             LEFT JOIN persons p ON u.person_id = p.id",
            &[],).await?;
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
                site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
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

            // Drop any in-memory bootstrap copy of the same account.
            state.users.retain(|u| u.id == user.id || !u.email.eq_ignore_ascii_case(&user.email));
            upsert_by_id(&mut state.users, user, |x| &x.id);
        }
        info!("Loaded {} users from PostgreSQL", state.users.len());
    }

    // 2b. Load Persons into users state for resident resolution
    {
        let rows = client.query("SELECT id, full_name, email, phone, person_type FROM persons",
            &[],).await?;
        for row in rows {
            let p_id: i64 = row.get(0);
            let p_name: String = row.get(1);
            let p_email: Option<String> = row.get(2);
            let p_phone: Option<String> = row.get(3);
            let p_type: String = row.get(4);
            let role = Role::from_str_loose(&p_type);

            // Persons live in their own id namespace (`person-<id>`) so they can
            // never collide with, or overwrite, a real login account.
            let user = User {
                id: format!("person-{}", p_id),
                site_id: String::new(),
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

            upsert_by_id(&mut state.users, user, |x| &x.id);
        }
        info!("Loaded {} persons into users from PostgreSQL", state.users.len());
    }

    // 3. Load Units
    {
        let rows = client.query("SELECT id, block_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, site_id, virtual_iban, house_type FROM units",
            &[],).await?;
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
                    &site_id.map(|s| s.to_string()).unwrap_or_default(),
                    block_label,
                    unit_number,
                ))
            });

            let unit = IndependentUnit {
                id: id.to_string(),
                site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
                block_id: block_id.to_string(),
                unit_number,
                floor,
                land_share,
                owner_user_id: owner_person_id.map(|p| format!("person-{}", p)),
                tenant_user_id: tenant_person_id.map(|p| format!("person-{}", p)),
                virtual_iban: resolved_viban,
                house_type,
            };

            // Register unit payer names (tenant first as primary payer, then owner)
            for (p_id, primary) in [(tenant_person_id, true), (owner_person_id, false)] {
                let Some(p_id) = p_id else { continue };
                let key = format!("person-{}", p_id);
                if let Some(p) = state.users.iter().find(|u| u.id == key) {
                    let name = p.full_name.clone();
                    let entry = state.unit_payer_names.entry(unit.id.clone()).or_default();
                    if !entry.contains(&name) {
                        if primary { entry.insert(0, name) } else { entry.push(name) }
                    }
                }
            }

            upsert_by_id(&mut state.units, unit, |x| &x.id);
        }
        info!("Loaded {} units from PostgreSQL", state.units.len());
    }

    // 3b. Load House Types (Tariffs)
    {
        let rows = client.query("SELECT id, site_id, type_name, dues_amount, description FROM house_types",
            &[],).await?;
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
    {
        let rows = client.query("SELECT id, site_id, block_name, total_floors FROM blocks",
            &[],).await?;
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
    {
        let rows = client.query("SELECT id, unit_id, period, principal_amount, due_date, status, delay_penalty, paid_principal, paid_penalty, debtor_type, expense_type FROM dues_liabilities",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let unit_id: i64 = row.get(1);
            let period: String = row.get(2);
            let principal_amount: Decimal = row.get(3);
            let due_date: NaiveDate = row.get(4);
            let status_str: String = row.get(5);
            let delay_penalty: Decimal = row.get(6);
            let paid_principal: Decimal = row.get(7);
            let paid_penalty: Decimal = row.get(8);
            let debtor_type: String = row.get(9);
            let expense_type: String = row.get(10);

            let status = match status_str.to_uppercase().as_str() {
                "PAID" => DebtStatus::Paid,
                "OVERDUE" => DebtStatus::Overdue,
                _ => DebtStatus::Pending,
            };

            let mut due = DuesLiability {
                id: id.to_string(),
                unit_id: unit_id.to_string(),
                period,
                principal_amount,
                due_date,
                status,
                delay_penalty,
                total_amount: Decimal::ZERO,
                paid_principal,
                paid_penalty,
                debtor_type,
                expense_type,
            };
            crate::services::dues_ledger::refresh(&mut due);
            upsert_by_id(&mut state.dues, due, |x| &x.id);
        }
        info!("Loaded {} dues liabilities from PostgreSQL", state.dues.len());
    }

    // 4b. Load Dues Periods
    {
        let rows = client.query("SELECT id, site_id, period_name, due_date, status, created_at FROM dues_periods ORDER BY due_date ASC",
            &[],).await?;
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
    {
        let rows = client.query("SELECT id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at FROM site_bank_accounts",
            &[],).await?;
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
    {
        let rows = client.query("SELECT id, site_id, unit_id, dues_liability_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, external_reference, payment_date, created_at FROM payment_entries ORDER BY payment_date ASC",
            &[],).await?;
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

    // 6b. Load Payment Receipts
    {
        let rows = client.query("SELECT id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference, allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text, is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at FROM payment_receipts ORDER BY sequence_number ASC",
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let site_id: i64 = row.get(1);
            let unit_id: i64 = row.get(2);
            let receipt_number: String = row.get(3);
            let sequence_number: i64 = row.get(4);
            let payer_name: String = row.get(5);
            let payer_role: String = row.get(6);
            let on_behalf_of_name: Option<String> = row.get(7);
            let on_behalf_of_role: Option<String> = row.get(8);
            let total_amount: Decimal = row.get(9);
            let payment_channel: String = row.get(10);
            let channel_reference: Option<String> = row.get(11);
            let allocated_principal: Decimal = row.get(12);
            let allocated_penalty: Decimal = row.get(13);
            let allocated_advance: Decimal = row.get(14);
            let breakdown_str: String = row.get(15);
            let is_rent_offset_eligible: bool = row.get(16);
            let legal_statutory_note: Option<String> = row.get(17);
            let verification_hash: String = row.get(18);
            let issued_at: Option<DateTime<Utc>> = row.get(19);

            let allocation_breakdown: Vec<AllocationBreakdownItem> =
                serde_json::from_str(&breakdown_str).unwrap_or_default();

            let receipt = PaymentReceipt {
                id,
                site_id: site_id.to_string(),
                unit_id: unit_id.to_string(),
                receipt_number,
                sequence_number,
                payer_name,
                payer_role,
                on_behalf_of_name,
                on_behalf_of_role,
                total_amount,
                payment_channel,
                channel_reference,
                allocated_principal,
                allocated_penalty,
                allocated_advance,
                allocation_breakdown,
                is_rent_offset_eligible,
                legal_statutory_note,
                verification_hash,
                issued_at: issued_at.unwrap_or_else(Utc::now),
            };

            if let Some(pos) = state.payment_receipts.iter().position(|r| r.id == id) {
                state.payment_receipts[pos] = receipt;
            } else {
                state.payment_receipts.push(receipt);
            }
        }
        info!(
            "Loaded {} payment receipts from PostgreSQL",
            state.payment_receipts.len()
        );
    }

    // 7. Load Pending Registrations
    {
        let rows = client.query("SELECT request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident, status, submitted_at FROM pending_registrations",
            &[],).await?;
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
    {
        let rows = client.query(r#"
            SELECT uo.unit_id, om.id, om.full_name, om.relationship, om.phone, om.email,
                   om.occupancy_id, om.person_id, om.resident_user_id,
                   (uo.occupancy_type = 'OWNER') AS is_owner
            FROM occupancy_members om
            JOIN unit_occupancies uo ON om.occupancy_id = uo.id
            WHERE uo.is_active = true
            ORDER BY om.id ASC
            "#,
            &[],).await?;
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

    // 8b. Load Occupancy History
    {
        let rows = client.query(r#"
            SELECT uo.id, uo.unit_id, uo.person_id, p.full_name, p.phone, p.email,
                   uo.occupancy_type, uo.start_date, uo.end_date, uo.is_active,
                   COALESCE(uo.exit_balance, 0.00), uo.notes, uo.created_at
            FROM unit_occupancies uo
            JOIN persons p ON uo.person_id = p.id
            ORDER BY uo.start_date ASC
            "#,
            &[],).await?;
        for row in rows {
            let id: i64 = row.get(0);
            let unit_id: i64 = row.get(1);
            let person_id: i64 = row.get(2);
            let person_name: String = row.get(3);
            let person_phone: Option<String> = row.get(4);
            let person_email: Option<String> = row.get(5);
            let role: String = row.get(6);
            let start_date: NaiveDate = row.get(7);
            let end_date: Option<NaiveDate> = row.get(8);
            let is_active: bool = row.get(9);
            let exit_balance: Decimal = row.get(10);
            let notes: Option<String> = row.get(11);
            let created_at: Option<DateTime<Utc>> = row.get(12);

            let item = OccupancyHistoryItem {
                id,
                unit_id,
                person_id,
                person_name,
                person_phone,
                person_email,
                role,
                start_date: start_date.to_string(),
                end_date: end_date.map(|d| d.to_string()),
                is_active,
                exit_balance,
                notes,
                created_at: created_at.unwrap_or_else(Utc::now),
            };

            let key = unit_id.to_string();
            let history = state.unit_occupancies.entry(key).or_default();
            if !history.iter().any(|h| h.id == item.id) {
                history.push(item);
            }
        }
        info!("Loaded occupancy history for {} units from PostgreSQL", state.unit_occupancies.len());
    }

    // 9. Load Invitation Tokens
    {
        let rows = client.query("SELECT token, site_id, unit_id, building, unit_number, relationship, invite_url, security_notice, expires_at FROM invitation_tokens",
            &[],).await?;
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
    {
        let rows = client.query("SELECT unit_id, balance FROM advance_balances",
            &[],).await?;
        for row in rows {
            let unit_id: i64 = row.get(0);
            let balance: Decimal = row.get(1);
            state.advance_payments.insert(unit_id.to_string(), balance);
        }
        info!("Loaded {} advance balances from PostgreSQL", state.advance_payments.len());
    }

    // 11. Load Unit Sender IBANs
    {
        let rows = client.query("SELECT sender_iban, unit_id, label, bank_name FROM unit_sender_ibans",
            &[],).await?;
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
    {
        let rows = client.query("SELECT unit_id, payer_name FROM unit_payer_names",
            &[],).await?;
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
    {
        let rows = client.query("SELECT match_id, transaction_id, txn_date, amount, currency, description, sender_name, sender_iban, reference_no, matched_unit_id, matched_block, matched_unit_number, matched_resident_name, confidence_score, matched_due_id, outstanding_balance, amount_matches_balance, status, status_code, notes FROM reconciliation_queue ORDER BY txn_date ASC",
            &[],).await?;
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
    Ok(())
}

pub async fn save_site(pool: &Pool, site: &Site) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let maybe_id = parse_id_to_i64(&site.id);
    let id_num = match maybe_id {
        Some(id) if id > 0 => {
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
                        &id,
                        &site.name,
                        &site.address,
                        &site.slug,
                        &site.status,
                        &site.plan_type,
                        &site.license_end_date,
                    ],
                )
                .await?;
            id
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
                    VALUES ($1, $2, $3, $4, $5, $6)
                    ON CONFLICT (slug) DO UPDATE SET
                        name = EXCLUDED.name,
                        address = EXCLUDED.address,
                        status = EXCLUDED.status,
                        plan_type = EXCLUDED.plan_type,
                        license_end_date = EXCLUDED.license_end_date
                    RETURNING id
                    "#,
                    &[
                        &site.name,
                        &site.address,
                        &site.slug,
                        &site.status,
                        &site.plan_type,
                        &site.license_end_date,
                    ],
                )
                .await?;
            row.get(0)
        }
    };
    info!("Saved site {} (numeric ID: {}) ({}) to PostgreSQL sites", site.id, id_num, site.name);
    Ok(())
}

/// Marks a site deleted (soft delete); financial history is never removed.
pub async fn soft_delete_site(pool: &Pool, site_id: &str) -> DbResult<()> {
    let id = require_id("site", site_id)?;
    let client = pool.get().await?;
    let n = client
        .execute("UPDATE sites SET status = 'DELETED', deleted_at = CURRENT_TIMESTAMP WHERE id = $1 AND deleted_at IS NULL", &[&id])
        .await?;
    if n == 0 {
        return Err(format!("Site {} not found", site_id).into());
    }
    Ok(())
}

/// Whether a site may be used (exists, not deleted, not suspended).
pub async fn site_is_active(pool: &Pool, site_id: &str) -> DbResult<bool> {
    let Some(id) = parse_id_to_i64(site_id) else { return Ok(false) };
    let client = pool.get().await?;
    Ok(client
        .query_opt("SELECT 1 FROM sites WHERE id = $1 AND deleted_at IS NULL AND status <> 'SUSPENDED'", &[&id])
        .await?
        .is_some())
}

/// Hard delete, used only by the development purge tooling.
pub async fn delete_site(pool: &Pool, site_id: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let id_num = require_id("entity", site_id)?;
    client.execute("DELETE FROM sites WHERE id = $1", &[&id_num]).await?;
    info!("Deleted site {} (numeric ID: {}) from PostgreSQL sites", site_id, id_num);
    Ok(())
}

pub async fn save_user(pool: &Pool, user: &User) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let role_str = user.role.as_str();
    let email = user.email.trim().to_lowercase();
    let site_id_num = if user.site_id.is_empty() { None } else { Some(require_id("site", &user.site_id)?) };

    // Resolve, link, and synchronize person_id
    let person_id: Option<i64> = if let Some(pid) = user.person_id {
        if !user.full_name.is_empty() {
            client
                .execute("UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3", &[&user.full_name, &user.phone, &pid])
                .await?;
        }
        Some(pid)
    } else {
        let p_row = client.query_opt("SELECT id FROM persons WHERE LOWER(email) = $1", &[&email]).await?;
        if let Some(r) = p_row {
            let pid: i64 = r.get(0);
            if !user.full_name.is_empty() {
                client
                    .execute("UPDATE persons SET full_name = $1, phone = $2 WHERE id = $3", &[&user.full_name, &user.phone, &pid])
                    .await?;
            }
            Some(pid)
        } else if !user.full_name.is_empty() {
            let p_type = match user.role {
                Role::HomeOwner => "HOME_OWNER",
                Role::HomeResident => "HOME_RESIDENT",
                Role::SaasAdmin => "SAAS_ADMIN",
                Role::SiteManager => "SITE_MANAGER",
            };
            let row = client
                .query_one(
                    "INSERT INTO persons (full_name, phone, email, person_type) VALUES ($1, $2, $3, $4) RETURNING id",
                    &[&user.full_name, &user.phone, &email, &p_type],
                )
                .await?;
            Some(row.get(0))
        } else {
            None
        }
    };

    // Accounts are identified by e-mail (unique, case-insensitive). The database
    // assigns ids; an in-memory id is never used to pick the row to overwrite.
    let updated = client
        .execute(
            r#"
            UPDATE users SET
                site_id = COALESCE($1, site_id),
                password_hash = COALESCE($3, password_hash),
                role = $4,
                must_change_password = $5,
                auth_provider = $6,
                google_sub = COALESCE($7, google_sub),
                avatar_url = COALESCE($8, avatar_url),
                person_id = COALESCE($9, person_id)
            WHERE LOWER(email) = $2
            "#,
            &[
                &site_id_num,
                &email,
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
                INSERT INTO users (site_id, email, password_hash, role, must_change_password, auth_provider, google_sub, avatar_url, person_id, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                "#,
                &[
                    &site_id_num,
                    &email,
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
    Ok(())
}

pub async fn save_unit(pool: &Pool, unit: &IndependentUnit) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
    let site_id_num = require_id("entity", &period.site_id)?;
    let maybe_id = parse_id_to_i64(&period.id);

    match maybe_id {
        Some(id_num) if id_num > 0 => {
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
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO dues_periods (site_id, period_name, due_date, status)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (site_id, period_name) DO UPDATE SET
                        due_date = EXCLUDED.due_date,
                        status = EXCLUDED.status
                    RETURNING id
                    "#,
                    &[
                        &site_id_num,
                        &period.period_name,
                        &period.due_date,
                        &period.status,
                    ],
                )
                .await?;
            let new_id: i64 = row.get(0);
            info!("Saved dues period '{}' (auto-assigned ID: {}) for site {} to PostgreSQL", period.period_name, new_id, period.site_id);
        }
    }
    Ok(())
}

#[allow(dead_code)]
pub async fn get_dues_periods_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<crate::models::DuesPeriod>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
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
    let due_id_num = require_id("entity", &due.id)?;
    let unit_id_num = require_id("entity", &due.unit_id)?;

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
    let due_id_num = require_id("entity", due_id)?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET status = $2,
                paid_amount = CASE 
                    WHEN $3 > 0::numeric THEN LEAST(paid_amount + $3, principal_amount + delay_penalty)
                    WHEN $2 = 'PAID' THEN principal_amount + delay_penalty
                    ELSE paid_amount
                END,
                paid_principal = CASE
                    WHEN $3 > 0::numeric THEN LEAST(paid_principal + $3, principal_amount)
                    WHEN $2 = 'PAID' THEN principal_amount
                    ELSE paid_principal
                END,
                payment_date = CURRENT_TIMESTAMP
            WHERE id = $1
            "#,
            &[&due_id_num, &status, &paid_amount],
        )
        .await?;
    info!("Updated dues liability {} (numeric ID: {}) to status {} in PostgreSQL", due_id, due_id_num, status);
    Ok(())
}

pub async fn record_due_allocation(
    pool: &Pool,
    due_id_num: i64,
    allocated_principal: Decimal,
    allocated_penalty: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET paid_principal = LEAST(paid_principal + $2, principal_amount),
                paid_penalty = LEAST(paid_penalty + $3, delay_penalty),
                paid_amount = LEAST(paid_amount + $2 + $3, principal_amount + delay_penalty),
                status = CASE
                    WHEN (paid_principal + $2 >= principal_amount) AND (paid_penalty + $3 >= delay_penalty) THEN 'PAID'
                    ELSE 'PARTIALLY_PAID'
                END,
                payment_date = CURRENT_TIMESTAMP
            WHERE id = $1
            "#,
            &[&due_id_num, &allocated_principal, &allocated_penalty],
        )
        .await?;
    Ok(())
}

pub async fn save_payment_receipt(
    pool: &Pool,
    receipt: &PaymentReceipt,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &receipt.site_id)?;
    let unit_id_num = require_id("entity", &receipt.unit_id)?;
    let breakdown_json_str = serde_json::to_string(&receipt.allocation_breakdown)?;

    let row = client
        .query_one(
            r#"
            INSERT INTO payment_receipts (
                site_id, unit_id, receipt_number, sequence_number,
                payer_name, payer_role, on_behalf_of_name, on_behalf_of_role,
                total_amount, payment_channel, channel_reference,
                allocated_principal, allocated_penalty, allocated_advance,
                allocation_breakdown, is_rent_offset_eligible, legal_statutory_note,
                verification_hash, issued_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19)
            ON CONFLICT (site_id, receipt_number) DO UPDATE SET
                payer_name = EXCLUDED.payer_name,
                total_amount = EXCLUDED.total_amount
            RETURNING id
            "#,
            &[
                &site_id_num,
                &unit_id_num,
                &receipt.receipt_number,
                &receipt.sequence_number,
                &receipt.payer_name,
                &receipt.payer_role,
                &receipt.on_behalf_of_name,
                &receipt.on_behalf_of_role,
                &receipt.total_amount,
                &receipt.payment_channel,
                &receipt.channel_reference,
                &receipt.allocated_principal,
                &receipt.allocated_penalty,
                &receipt.allocated_advance,
                &breakdown_json_str,
                &receipt.is_rent_offset_eligible,
                &receipt.legal_statutory_note,
                &receipt.verification_hash,
                &receipt.issued_at,
            ],
        )
        .await?;
    let receipt_id: i64 = row.get(0);
    info!("Saved payment receipt {} (id: {}) to PostgreSQL", receipt.receipt_number, receipt_id);
    Ok(receipt_id)
}

pub async fn get_next_receipt_sequence(
    pool: &Pool,
    site_id: &str,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
    let row = client
        .query_one(
            "SELECT COALESCE(MAX(sequence_number), 0) + 1 FROM payment_receipts WHERE site_id = $1",
            &[&site_id_num],
        )
        .await?;
    let next_seq: i64 = row.get(0);
    Ok(next_seq)
}

pub async fn save_payment_entry(
    pool: &Pool,
    entry: &PaymentEntry,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &entry.site_id)?;
    let unit_id_num = require_id("entity", &entry.unit_id)?;

    let row = client
        .query_one(
            r#"
            INSERT INTO payment_entries (
                site_id, unit_id, payer_name, payer_role, receipt_id,
                amount, payment_channel, settlement_status, description,
                external_reference, payment_date, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            RETURNING id
            "#,
            &[
                &site_id_num,
                &unit_id_num,
                &entry.payer_name,
                &entry.payer_role,
                &entry.receipt_id,
                &entry.amount,
                &entry.payment_channel,
                &entry.settlement_status,
                &entry.description,
                &entry.external_reference,
                &entry.payment_date,
                &entry.created_at,
            ],
        )
        .await?;
    let entry_id: i64 = row.get(0);
    info!("Saved payment entry (id: {}) to PostgreSQL", entry_id);
    Ok(entry_id)
}

pub async fn save_payment_allocation(
    pool: &Pool,
    payment_entry_id: i64,
    dues_liability_id: i64,
    principal_amount: Decimal,
    penalty_amount: Decimal,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let row = client
        .query_one(
            r#"
            INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at)
            VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
            RETURNING id
            "#,
            &[&payment_entry_id, &dues_liability_id, &principal_amount, &penalty_amount],
        )
        .await?;
    let alloc_id: i64 = row.get(0);
    Ok(alloc_id)
}

#[allow(clippy::too_many_arguments)]
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
    let maybe_id = parse_id_to_i64(&account.id);
    let site_id_num = require_id("entity", &account.site_id)?;
    let config_by_num = account.configured_by.as_deref().and_then(parse_id_to_i64);

    match maybe_id {
        Some(id_num) if id_num > 0 => {
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
        }
        _ => {
            let row = client
                .query_one(
                    r#"
                    INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by, created_at, updated_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
                    RETURNING id
                    "#,
                    &[
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
            let new_id: i64 = row.get(0);
            info!("Saved site bank account (auto-assigned ID: {}) to PostgreSQL", new_id);
        }
    }
    Ok(())
}

/// Stores a unit's total advance balance without touching other debtors' credit.
///
/// `advance_balances` is per (unit, debtor_type) while the in-memory view keeps one
/// total per unit. The TENANT bucket is set so that all buckets add up to `total`
/// (owner credit is never overwritten), and every change is written to
/// `advance_ledger_entries` so the balance stays tied to its ledger.
pub async fn save_advance_balance(pool: &Pool, unit_id: &str, total: Decimal) -> DbResult<()> {
    let unit = require_id("unit", unit_id)?;
    let mut client = pool.get().await?;
    let tx = client.transaction().await?;
    let rows = tx
        .query("SELECT debtor_type, balance FROM advance_balances WHERE unit_id = $1 FOR UPDATE", &[&unit])
        .await?;
    let mut tenant = Decimal::ZERO;
    let mut others = Decimal::ZERO;
    for r in rows {
        let kind: String = r.get(0);
        let bal: Decimal = r.get(1);
        if kind == "TENANT" { tenant = bal } else { others += bal }
    }
    let new_tenant = (total - others).max(Decimal::ZERO);
    let delta = new_tenant - tenant;
    if delta != Decimal::ZERO {
        tx.execute(
            "INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at) VALUES ($1, 'TENANT', $2, CURRENT_TIMESTAMP)
             ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance, updated_at = CURRENT_TIMESTAMP",
            &[&unit, &new_tenant],
        )
        .await?;
        let entry_type = if delta > Decimal::ZERO { "PAYMENT_SURPLUS" } else { "OFFSET_APPLIED" };
        tx.execute(
            "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description, created_at)
             VALUES ($1, 'TENANT', $2, $3, 'Advance balance change', CURRENT_TIMESTAMP)",
            &[&unit, &entry_type, &delta.abs()],
        )
        .await?;
    }
    tx.commit().await?;
    Ok(())
}

/// Writes a liability's payment state (absolute values from the ledger).
pub async fn sync_due_payment_state(pool: &Pool, due: &DuesLiability) -> DbResult<()> {
    let id = require_id("dues liability", &due.id)?;
    let status = match due.status {
        DebtStatus::Paid => "PAID",
        _ if due.paid_principal + due.paid_penalty > Decimal::ZERO => "PARTIALLY_PAID",
        DebtStatus::Overdue => "OVERDUE",
        DebtStatus::Pending => "PENDING",
    };
    let client = pool.get().await?;
    client
        .execute(
            r#"
            UPDATE dues_liabilities
            SET delay_penalty  = GREATEST(delay_penalty, $2, $4),
                paid_principal = $3,
                paid_penalty   = $4,
                paid_amount    = $3 + $4,
                status         = $5,
                payment_date   = CASE WHEN $3 + $4 > paid_amount THEN CURRENT_TIMESTAMP ELSE payment_date END,
                version        = version + 1
            WHERE id = $1
            "#,
            &[&id, &due.delay_penalty, &due.paid_principal, &due.paid_penalty, &status],
        )
        .await?;
    Ok(())
}

pub async fn save_advance_balance_with_type(
    pool: &Pool,
    unit_id: &str,
    debtor_type: &str,
    balance: Decimal,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    client
        .execute(
            r#"
            INSERT INTO advance_balances (unit_id, balance, debtor_type, updated_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id, debtor_type) DO UPDATE SET
                balance = EXCLUDED.balance,
                updated_at = CURRENT_TIMESTAMP
            "#,
            &[&unit_id_num, &balance, &debtor_type],
        )
        .await?;
    info!("Saved advance balance (₺{}) for unit {} ({}) to PostgreSQL", balance, unit_id, debtor_type);
    Ok(())
}

pub async fn save_advance_ledger_entry(
    pool: &Pool,
    unit_id: &str,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference_id: Option<&str>,
    description: Option<&str>,
) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let unit_id_num = require_id("entity", unit_id)?;
    let row = client
        .query_one(
            r#"
            INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)
            RETURNING id
            "#,
            &[&unit_id_num, &debtor_type, &entry_type, &amount, &reference_id, &description],
        )
        .await?;
    let entry_id: i64 = row.get(0);
    Ok(entry_id)
}

pub async fn save_pending_registration(
    pool: &Pool,
    req: &PendingRegistrationResponse,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", &req.site_id)?;
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

/// Records a bank webhook transaction id. Returns `false` when it was already processed.
/// Removes every recoverable clear-text password from `users`: legacy placeholder
/// formats (`ARGON2_HASH_x`, `HASH_x`, `argon2id_hash_placeholder:x`, plaintext) are
/// re-hashed with argon2id and the account must change its password on next login.
/// Unsalted SHA-256 digests cannot be upgraded, so those accounts are locked until
/// an administrator resets them. Returns the number of rows changed.
pub async fn upgrade_legacy_password_hashes(pool: &Pool) -> Result<u64, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let rows = client
        .query("SELECT id, password_hash FROM users WHERE password_hash IS NOT NULL AND password_hash NOT LIKE '$argon2%'", &[])
        .await?;
    let mut changed = 0;
    for row in rows {
        let id: i64 = row.get(0);
        let stored: String = row.get(1);
        let new_hash = match crate::auth::legacy_plaintext(&stored) {
            Some(plain) => crate::auth::hash_password(&plain),
            None => crate::auth::hash_password(&uuid::Uuid::new_v4().to_string()),
        };
        changed += client
            .execute("UPDATE users SET password_hash = $1, must_change_password = TRUE WHERE id = $2", &[&new_hash, &id])
            .await?;
    }
    if changed > 0 {
        warn!("Upgraded {} legacy password hash(es) to argon2id; affected users must change their password", changed);
    }
    Ok(changed)
}

/// Creates the first SaaS administrator when none exists (see `bootstrap_admin_password`).
pub async fn ensure_bootstrap_admin(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let exists = client.query_opt("SELECT 1 FROM users WHERE role = 'SAAS_ADMIN' LIMIT 1", &[]).await?.is_some();
    if exists {
        return Ok(());
    }
    let email = std::env::var("SITEPULSE_BOOTSTRAP_ADMIN_EMAIL").unwrap_or_else(|_| "admin@sitepulse.io".to_string()).to_lowercase();
    let hash = crate::auth::hash_password(&crate::state::bootstrap_admin_password());
    let person_id: i64 = client
        .query_one(
            "INSERT INTO persons (full_name, email, person_type) VALUES ('SaaS Platform Admin', $1, 'SAAS_ADMIN')
             ON CONFLICT (email) DO UPDATE SET full_name = persons.full_name RETURNING id",
            &[&email],
        )
        .await?
        .get(0);
    client
        .execute(
            "INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
             VALUES (NULL, $1, $2, $3, 'SAAS_ADMIN', TRUE)",
            &[&person_id, &email, &hash],
        )
        .await?;
    warn!("Created bootstrap SaaS administrator {}", email);
    Ok(())
}

pub async fn claim_bank_webhook_transaction(pool: &Pool, transaction_id: &str) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let n = client
        .execute(
            "INSERT INTO processed_bank_webhooks (transaction_id) VALUES ($1) ON CONFLICT (transaction_id) DO NOTHING",
            &[&transaction_id],
        )
        .await?;
    Ok(n == 1)
}

pub async fn delete_invitation_token(pool: &Pool, token_digest: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    client.execute("DELETE FROM invitation_tokens WHERE token = $1", &[&token_digest]).await?;
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
    let unit_id_num = require_id("entity", unit_id)?;
    client.execute("DELETE FROM unit_payer_names WHERE unit_id = $1", &[&unit_id_num]).await?;
    for name in names {
        client
            .execute(
                "INSERT INTO unit_payer_names (unit_id, payer_name) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                &[&unit_id_num, &name],
            )
            .await.map_err(|e| e.to_string())?;
    }
    info!("Saved {} payer names for unit {} to PostgreSQL", names.len(), unit_id);
    Ok(())
}

pub async fn save_reconciliation_match_for_site(
    pool: &Pool,
    m: &ReconciliationMatch,
    site_id: &str,
    bank_account_id: Option<i64>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let status_str = format!("{:?}", m.status);
    let confidence_i32 = m.confidence_score as i32;
    let matched_unit_num = m.matched_unit_id.as_deref().and_then(parse_id_to_i64);
    let matched_due_num = m.matched_due_id.as_deref().and_then(parse_id_to_i64);
    let site_id_num = require_id("entity", site_id)?;
    client
        .execute(
            r#"
            INSERT INTO reconciliation_queue (
                match_id, transaction_id, txn_date, amount, currency, description,
                sender_name, sender_iban, reference_no, matched_unit_id, matched_block,
                matched_unit_number, matched_resident_name, confidence_score, matched_due_id,
                outstanding_balance, amount_matches_balance, status, status_code, notes,
                site_id, site_bank_account_id, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, CURRENT_TIMESTAMP)
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
                &site_id_num,
                &bank_account_id,
            ],
        )
        .await?;
    info!("Saved reconciliation match {} to PostgreSQL", m.match_id);
    Ok(())
}

pub async fn save_reconciliation_match(
    pool: &Pool,
    m: &ReconciliationMatch,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // The site is derived from the matched unit; never defaulted to site 1.
    let unit = m
        .matched_unit_id
        .as_deref()
        .ok_or("reconciliation match has no unit; use save_reconciliation_match_for_site")?;
    let unit_id = require_id("unit", unit)?;
    let client = pool.get().await?;
    let site: i64 = client
        .query_opt("SELECT site_id FROM units WHERE id = $1", &[&unit_id])
        .await?
        .and_then(|r| r.get::<_, Option<i64>>(0))
        .ok_or_else(|| format!("unit {} has no site", unit_id))?;
    drop(client);
    save_reconciliation_match_for_site(pool, m, &site.to_string(), None).await
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
        .query_opt("SELECT person_id FROM users WHERE LOWER(email) = LOWER($1)", &[&new_user.email])
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
        tx
            .execute(
                r#"
                UPDATE unit_occupancies
                SET is_active = false, end_date = $2, exit_balance = $3, notes = COALESCE($4, notes)
                WHERE unit_id = $1 AND is_active = true AND occupancy_type = 'OWNER'
                "#,
                &[&unit_id_num, &transfer_date, &exit_balance, &notes],
            )
            .await?;

        // 6. Update units owner
        tx
            .execute(
                "UPDATE units SET owner_person_id = $2 WHERE id = $1",
                &[&unit_id_num, &pid],
            )
            .await?;
    }

    info!("Transferred ownership for unit {} to user {} in PostgreSQL", unit_id, new_user.email);
    tx.commit().await?;
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

    let parsed_unit_id = require_id("entity", &rec.unit_id)?;
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
            id: id.to_string(),
            site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
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
            id: id.to_string(),
            site_id: site_id.map(|s| s.to_string()).unwrap_or_default(),
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
    let site_id_num = require_id("entity", site_id)?;
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
        }));
    }
    Ok(None)
}

pub async fn get_blocks_for_site_from_db(
    pool: &Pool,
    site_id: &str,
) -> Result<Vec<BlockDto>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let site_id_num = require_id("entity", site_id)?;
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
            id: id.to_string(),
            site_id: s_id.to_string(),
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
        save_site(pool, site).await.map_err(|e| e.to_string())?;
    }

    // 2. Sync Blocks
    for block in &state.blocks {
        let site_id_num = require_id("entity", &block.site_id)?;
        if let Some(block_id_num) = parse_id_to_i64(&block.id) {
            client
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
                .await.map_err(|e| e.to_string())?;
        } else {
            client
                .execute(
                    r#"
                    INSERT INTO blocks (site_id, block_name, total_floors)
                    VALUES ($1, $2, $3)
                    ON CONFLICT DO NOTHING
                    "#,
                    &[&site_id_num, &block.block_name, &block.total_floors],
                )
                .await.map_err(|e| e.to_string())?;
        }
    }

    // 3. Sync Users and Persons
    for user in &state.users {
        save_user(pool, user).await.map_err(|e| e.to_string())?;
    }

    // 4. Sync Units
    for unit in &state.units {
        save_unit(pool, unit).await.map_err(|e| e.to_string())?;
    }

    // 5. Sync Dues Liabilities
    for due in &state.dues {
        save_due_liability(pool, due).await.map_err(|e| e.to_string())?;
    }

    // 6. Sync Remembered Sender IBANs & Payer Names
    for (iban, unit_id) in &state.remembered_sender_ibans {
        let meta = state.sender_iban_metadata.get(iban);
        let label = meta.and_then(|m| m.0.as_deref());
        let bank = meta.and_then(|m| m.1.as_deref());
        save_remembered_sender_iban(pool, iban, unit_id, label, bank).await.map_err(|e| e.to_string())?;
    }
    for (unit_id, names) in &state.unit_payer_names {
        save_unit_payer_names(pool, unit_id, names).await.map_err(|e| e.to_string())?;
    }

    // 7. Sync Advance Balances
    for (unit_id, bal) in &state.advance_payments {
        save_advance_balance(pool, unit_id, *bal).await.map_err(|e| e.to_string())?;
    }

    // 8. Sync Payment Receipts
    for r in &state.payment_receipts {
        save_payment_receipt(pool, r).await.map_err(|e| e.to_string())?;
    }

    info!("Synchronized all in-memory state to PostgreSQL database successfully.");
    Ok(())
}

// ---------------------------------------------------------------------------
// Transaction-scoped payment persistence (C7, H1–H4, H6, H9).
// Every helper runs on the caller's transaction; nothing is committed until the
// caller commits, and any error rolls the whole payment back.
// ---------------------------------------------------------------------------

pub type DbResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Receipt previously issued for this idempotency key, if any.
pub async fn tx_find_idempotent_receipt(tx: &deadpool_postgres::Transaction<'_>, site_id: i64, key: &str) -> DbResult<Option<i64>> {
    Ok(tx
        .query_opt(
            "SELECT receipt_id FROM payment_idempotency_keys WHERE site_id = $1 AND idempotency_key = $2",
            &[&site_id, &key],
        )
        .await?
        .map(|r| r.get(0)))
}

pub async fn tx_store_idempotency_key(tx: &deadpool_postgres::Transaction<'_>, site_id: i64, key: &str, receipt_id: i64) -> DbResult<()> {
    tx.execute(
        "INSERT INTO payment_idempotency_keys (site_id, idempotency_key, receipt_id) VALUES ($1, $2, $3)",
        &[&site_id, &key, &receipt_id],
    )
    .await?;
    Ok(())
}

/// Locks the unit row and checks that it belongs to the site.
pub async fn tx_lock_unit(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64, site_id: i64) -> DbResult<bool> {
    Ok(tx
        .query_opt("SELECT id FROM units WHERE id = $1 AND site_id = $2 FOR UPDATE", &[&unit_id, &site_id])
        .await?
        .is_some())
}

/// Open liabilities of a unit, oldest first, locked for update.
pub async fn tx_load_open_dues(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64) -> DbResult<Vec<DuesLiability>> {
    let rows = tx
        .query(
            r#"
            SELECT id, period, principal_amount, delay_penalty, paid_principal, paid_penalty,
                   due_date, status, debtor_type, expense_type
            FROM dues_liabilities
            WHERE unit_id = $1 AND status NOT IN ('PAID', 'CANCELLED')
            ORDER BY due_date, id
            FOR UPDATE
            "#,
            &[&unit_id],
        )
        .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let status: String = r.get(7);
            let mut d = DuesLiability {
                id: r.get::<_, i64>(0).to_string(),
                unit_id: unit_id.to_string(),
                period: r.get(1),
                principal_amount: r.get(2),
                delay_penalty: r.get(3),
                total_amount: Decimal::ZERO,
                due_date: r.get(6),
                status: if status == "OVERDUE" { DebtStatus::Overdue } else { DebtStatus::Pending },
                paid_principal: r.get(4),
                paid_penalty: r.get(5),
                debtor_type: r.get(8),
                expense_type: r.get(9),
            };
            crate::services::dues_ledger::refresh(&mut d);
            d
        })
        .collect())
}

/// Next receipt sequence for a site. The counter row is locked by the UPDATE
/// until commit, so concurrent payments serialize and never share a number.
pub async fn tx_next_receipt_sequence(tx: &deadpool_postgres::Transaction<'_>, site_id: i64) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO receipt_counters (site_id, last_sequence)
            VALUES ($1, COALESCE((SELECT MAX(sequence_number) FROM payment_receipts WHERE site_id = $1), 0) + 1)
            ON CONFLICT (site_id) DO UPDATE SET last_sequence = receipt_counters.last_sequence + 1
            RETURNING last_sequence
            "#,
            &[&site_id],
        )
        .await?;
    Ok(row.get(0))
}

pub async fn tx_insert_receipt(tx: &deadpool_postgres::Transaction<'_>, receipt: &PaymentReceipt, site_id: i64, unit_id: i64) -> DbResult<i64> {
    let breakdown = serde_json::to_string(&receipt.allocation_breakdown)?;
    let row = tx
        .query_one(
            r#"
            INSERT INTO payment_receipts (
                site_id, unit_id, receipt_number, sequence_number,
                payer_name, payer_role, on_behalf_of_name, on_behalf_of_role,
                total_amount, payment_channel, channel_reference,
                allocated_principal, allocated_penalty, allocated_advance,
                allocation_breakdown, is_rent_offset_eligible, legal_statutory_note,
                verification_hash, issued_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15::text::jsonb, $16, $17, $18, $19)
            RETURNING id
            "#,
            &[
                &site_id,
                &unit_id,
                &receipt.receipt_number,
                &receipt.sequence_number,
                &receipt.payer_name,
                &receipt.payer_role,
                &receipt.on_behalf_of_name,
                &receipt.on_behalf_of_role,
                &receipt.total_amount,
                &receipt.payment_channel,
                &receipt.channel_reference,
                &receipt.allocated_principal,
                &receipt.allocated_penalty,
                &receipt.allocated_advance,
                &breakdown,
                &receipt.is_rent_offset_eligible,
                &receipt.legal_statutory_note,
                &receipt.verification_hash,
                &receipt.issued_at,
            ],
        )
        .await?;
    Ok(row.get(0))
}

pub async fn tx_insert_entry(tx: &deadpool_postgres::Transaction<'_>, entry: &PaymentEntry, site_id: i64, unit_id: i64) -> DbResult<i64> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO payment_entries (
                site_id, unit_id, payer_name, payer_role, receipt_id,
                amount, payment_channel, settlement_status, description,
                external_reference, payment_date, created_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
            RETURNING id
            "#,
            &[
                &site_id,
                &unit_id,
                &entry.payer_name,
                &entry.payer_role,
                &entry.receipt_id,
                &entry.amount,
                &entry.payment_channel,
                &entry.settlement_status,
                &entry.description,
                &entry.external_reference,
                &entry.payment_date,
                &entry.created_at,
            ],
        )
        .await?;
    Ok(row.get(0))
}

/// Records a settlement on a liability (paid amounts only; owed amounts untouched
/// except that the accrued penalty is brought up to date) plus its allocation row.
pub async fn tx_settle_due(
    tx: &deadpool_postgres::Transaction<'_>,
    entry_id: i64,
    due: &DuesLiability,
    principal: Decimal,
    penalty: Decimal,
) -> DbResult<()> {
    let due_id = require_id("dues liability", &due.id)?;
    let status = if due.status == DebtStatus::Paid { "PAID" } else { "PARTIALLY_PAID" };
    let n = tx
        .execute(
            r#"
            UPDATE dues_liabilities
            SET delay_penalty  = $2,
                paid_principal = paid_principal + $3,
                paid_penalty   = paid_penalty + $4,
                paid_amount    = paid_amount + $3 + $4,
                status         = $5,
                payment_date   = CURRENT_TIMESTAMP,
                version        = version + 1
            WHERE id = $1
            "#,
            &[&due_id, &due.delay_penalty, &principal, &penalty, &status],
        )
        .await?;
    if n != 1 {
        return Err(format!("dues liability {} disappeared during payment", due_id).into());
    }
    tx.execute(
        "INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at)
         VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)",
        &[&entry_id, &due_id, &principal, &penalty],
    )
    .await?;
    Ok(())
}

/// Credits a unit's advance balance for one debtor type by `amount` (an increment,
/// never an overwrite) and writes the matching ledger entry. Returns the new balance.
pub async fn tx_credit_advance(
    tx: &deadpool_postgres::Transaction<'_>,
    unit_id: i64,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference: Option<&str>,
    description: Option<&str>,
) -> DbResult<Decimal> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO advance_balances (unit_id, debtor_type, balance, updated_at)
            VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
            ON CONFLICT (unit_id, debtor_type) DO UPDATE SET
                balance = advance_balances.balance + EXCLUDED.balance,
                updated_at = CURRENT_TIMESTAMP
            RETURNING balance
            "#,
            &[&unit_id, &debtor_type, &amount],
        )
        .await?;
    tx.execute(
        "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)",
        &[&unit_id, &debtor_type, &entry_type, &amount, &reference, &description],
    )
    .await?;
    Ok(row.get(0))
}

pub async fn get_payment_receipt_by_id(pool: &Pool, receipt_id: i64) -> DbResult<Option<PaymentReceipt>> {
    let client = pool.get().await?;
    let row = client
        .query_opt(
            r#"
            SELECT id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role,
                   on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference,
                   allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text,
                   is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at
            FROM payment_receipts WHERE id = $1
            "#,
            &[&receipt_id],
        )
        .await?;
    let Some(r) = row else { return Ok(None) };
    let breakdown: Option<String> = r.get(15);
    Ok(Some(PaymentReceipt {
        id: r.get(0),
        site_id: r.get::<_, i64>(1).to_string(),
        unit_id: r.get::<_, i64>(2).to_string(),
        receipt_number: r.get(3),
        sequence_number: r.get(4),
        payer_name: r.get(5),
        payer_role: r.get(6),
        on_behalf_of_name: r.get(7),
        on_behalf_of_role: r.get(8),
        total_amount: r.get(9),
        payment_channel: r.get(10),
        channel_reference: r.get(11),
        allocated_principal: r.get(12),
        allocated_penalty: r.get(13),
        allocated_advance: r.get(14),
        allocation_breakdown: breakdown.and_then(|b| serde_json::from_str(&b).ok()).unwrap_or_default(),
        is_rent_offset_eligible: r.get(16),
        legal_statutory_note: r.get(17),
        verification_hash: r.get(18),
        issued_at: r.get(19),
    }))
}

/// Locks and returns one debtor's advance balance for a unit (0 when absent).
pub async fn tx_lock_advance(tx: &deadpool_postgres::Transaction<'_>, unit_id: i64, debtor_type: &str) -> DbResult<Decimal> {
    Ok(tx
        .query_opt(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2 FOR UPDATE",
            &[&unit_id, &debtor_type],
        )
        .await?
        .map(|r| r.get(0))
        .unwrap_or(Decimal::ZERO))
}

/// Debits an advance balance (never below zero) and writes the ledger entry.
pub async fn tx_debit_advance(
    tx: &deadpool_postgres::Transaction<'_>,
    unit_id: i64,
    debtor_type: &str,
    entry_type: &str,
    amount: Decimal,
    reference: Option<&str>,
    description: Option<&str>,
) -> DbResult<Decimal> {
    let row = tx
        .query_opt(
            "UPDATE advance_balances SET balance = balance - $3, updated_at = CURRENT_TIMESTAMP
             WHERE unit_id = $1 AND debtor_type = $2 AND balance >= $3 RETURNING balance",
            &[&unit_id, &debtor_type, &amount],
        )
        .await?
        .ok_or("insufficient advance balance")?;
    tx.execute(
        "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at)
         VALUES ($1, $2, $3, $4, $5, $6, CURRENT_TIMESTAMP)",
        &[&unit_id, &debtor_type, &entry_type, &amount, &reference, &description],
    )
    .await?;
    Ok(row.get(0))
}

/// Inserts an accrued liability and returns its id, or `None` when the unit
/// already has one for this period and expense type (`uq_unit_period_expense`).
pub async fn insert_accrued_due(pool: &Pool, due: &DuesLiability) -> DbResult<Option<i64>> {
    let unit = require_id("unit", &due.unit_id)?;
    let client = pool.get().await?;
    let row = client
        .query_opt(
            r#"
            INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, delay_penalty, debtor_type, expense_type)
            VALUES ($1, $2, $3, $4, 'PENDING', 0, $5, $6)
            ON CONFLICT (unit_id, period, expense_type) WHERE capital_project_id IS NULL DO NOTHING
            RETURNING id
            "#,
            &[&unit, &due.period, &due.principal_amount, &due.due_date, &due.debtor_type, &due.expense_type],
        )
        .await?;
    Ok(row.map(|r| r.get(0)))
}

