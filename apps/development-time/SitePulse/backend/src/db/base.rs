use deadpool_postgres::{
    Config, ManagerConfig, Pool, PoolConfig, RecyclingMethod, Runtime, Timeouts,
};
use tokio_postgres::NoTls;
use tracing::{info, warn};

/// A database error with PostgreSQL's own message and detail (tokio-postgres'
/// `Display` prints only "db error").
pub fn describe_db_error(e: &(dyn std::error::Error + Send + Sync + 'static)) -> String {
    if let Some(pg) = e.downcast_ref::<tokio_postgres::Error>() {
        if let Some(db) = pg.as_db_error() {
            return match db.detail() {
                Some(detail) => format!("{} ({})", db.message(), detail),
                None => db.message().to_string(),
            };
        }
    }
    e.to_string()
}

pub type DbResult<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;
/// Builds the PostgreSQL pool from the environment.
///
/// * `DB_PASS` has no default: credentials never live in source code. Without
///   it the backend refuses to start, unless `SITEPULSE_IN_MEMORY=true` asks for
///   the database-less demo mode explicitly (never allowed in production).
/// * `DB_SSLMODE=require` encrypts the connection with TLS (rustls, verified
///   against the Mozilla root store). The default is `disable` for local
///   development; production requires `require`.
pub fn create_pool() -> Option<Pool> {
    let in_memory = std::env::var("SITEPULSE_IN_MEMORY")
        .map(|v| v == "true")
        .unwrap_or(false);
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
    let port = std::env::var("DB_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5432);
    let user = std::env::var("DB_USER").unwrap_or_else(|_| "sitepulse_user".to_string());
    let dbname = std::env::var("DB_NAME").unwrap_or_else(|_| "sitepulse".to_string());
    let ssl_mode = std::env::var("DB_SSLMODE")
        .unwrap_or_else(|_| "disable".to_string())
        .to_lowercase();
    if production && ssl_mode != "require" {
        panic!("DB_SSLMODE=require is mandatory in production");
    }

    let mut cfg = Config::new();
    cfg.host = Some(host);
    cfg.port = Some(port);
    cfg.user = Some(user);
    cfg.password = Some(password);
    cfg.dbname = Some(dbname);
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let pool_cfg = PoolConfig {
        timeouts: Timeouts::wait_millis(10_000),
        ..Default::default()
    };
    cfg.pool = Some(pool_cfg);

    let pool = match ssl_mode.as_str() {
        "require" => {
            let roots = rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
            };
            let tls_config = rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("rustls protocol versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
            cfg.create_pool(
                Some(Runtime::Tokio1),
                tokio_postgres_rustls::MakeRustlsConnect::new(tls_config),
            )
        }
        "disable" => cfg.create_pool(Some(Runtime::Tokio1), NoTls),
        other => panic!(
            "Unsupported DB_SSLMODE '{}': use 'disable' or 'require'",
            other
        ),
    };
    match pool {
        Ok(pool) => {
            info!(
                "PostgreSQL connection pool configured (sslmode={})",
                ssl_mode
            );
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
        "site-", "unit-", "d-", "b-", "borc-", "person-", "kisi-", "blk-", "blok-", "sba-", "txn-",
        "cproj-", "cinst-", "cdis-", "usr-", "user-", "req-", "inv-", "match-", "ref-", "due-",
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
        return Err(
            "Legacy VARCHAR-id schema detected in this database. Refusing to start: \
                    migrate or restore it manually (SitePulse no longer drops tables at boot)."
                .into(),
        );
    }

    // Apply pending versioned migrations (backend/migrations is the only schema source).
    drop(client);
    let applied = crate::migrations::run(pool).await?;
    if !applied.is_empty() {
        info!(
            "Applied schema migrations {:?}; schema is at V{}",
            applied,
            crate::migrations::latest_version()
        );
    }
    let client = pool.get().await?;

    // Seed system reference data (banks, configs, root SaaS admin).
    client
        .batch_execute(include_str!("../../db/seed/01-system-seed.sql"))
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
        .batch_execute(include_str!("../../db/seed/02-test-seed.sql"))
        .await?;
    info!("Development test fixtures seeded successfully into PostgreSQL.");
    Ok(())
}

pub async fn reset_db_to_seed_data(
    pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    info!("Resetting PostgreSQL database to clean initial state (clean debts and payments)...");
    client
        .batch_execute(
            r#"
            TRUNCATE TABLE payment_entries RESTART IDENTITY CASCADE;
            TRUNCATE TABLE payment_intents RESTART IDENTITY CASCADE;
            TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;
            TRUNCATE TABLE operating_budgets RESTART IDENTITY CASCADE;
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

pub async fn recreate_db_schema_and_seed(
    pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
    info!(
        "Dropping all database tables to purge all sites, units, and residents for fresh start..."
    );
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
