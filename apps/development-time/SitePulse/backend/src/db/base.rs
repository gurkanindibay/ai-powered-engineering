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
pub fn create_pool() -> Result<Option<Pool>, String> {
    create_pool_named(std::env::var("DB_NAME").ok(), None)
}

/// Like [`create_pool`] for an explicit database (throwaway test databases).
/// Credentials, host and TLS mode still come from the environment.
pub fn create_pool_for(dbname: &str) -> Option<Pool> {
    create_pool_named(Some(dbname.to_string()), None)
        .ok()
        .flatten()
}

/// Schema-owner pool for fixtures that provision a throwaway database.
///
/// Reads `DB_ADMIN_USER`/`DB_ADMIN_PASS` and falls back to the runtime identity
/// (`DB_USER`/`DB_PASS`) when they are not set. CI sets both so the database is
/// created and migrated as the owner while the application runs as a
/// non-superuser runtime role, which is what makes row-level security apply.
pub fn create_admin_pool_for(dbname: &str) -> Option<Pool> {
    create_pool_named(Some(dbname.to_string()), admin_credentials())
        .ok()
        .flatten()
}

/// `(user, password)` of the schema owner when it differs from the runtime identity.
pub fn admin_credentials() -> Option<(String, String)> {
    let user = std::env::var("DB_ADMIN_USER")
        .ok()
        .filter(|u| !u.is_empty())?;
    let password = std::env::var("DB_ADMIN_PASS")
        .ok()
        .filter(|p| !p.is_empty())?;
    Some((user, password))
}

fn create_pool_named(
    dbname: Option<String>,
    credentials: Option<(String, String)>,
) -> Result<Option<Pool>, String> {
    let in_memory = std::env::var("SITEPULSE_IN_MEMORY")
        .map(|v| v == "true")
        .unwrap_or(false);
    let production = crate::state::AppStateInner::is_production();
    let (user, password) = if let Some(credentials) = credentials {
        credentials
    } else {
        let password = match std::env::var("DB_PASS") {
            Ok(p) if !p.is_empty() => p,
            _ if in_memory && !production => {
                warn!(
                    "SITEPULSE_IN_MEMORY=true: running without PostgreSQL; nothing will be persisted"
                );
                return Ok(None);
            }
            _ => {
                return Err(
                    "DB_PASS is required; use SITEPULSE_IN_MEMORY=true for a database-less demo"
                        .to_string(),
                )
            }
        };
        let user = std::env::var("DB_USER").unwrap_or_else(|_| "sitepulse_user".to_string());
        (user, password)
    };
    let host = std::env::var("DB_HOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = std::env::var("DB_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5432);
    let dbname = dbname.unwrap_or_else(|| "sitepulse".to_string());
    let ssl_mode = std::env::var("DB_SSLMODE")
        .unwrap_or_else(|_| "disable".to_string())
        .to_lowercase();
    if production && ssl_mode != "require" {
        return Err("DB_SSLMODE=require is mandatory in production".to_string());
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
            .map_err(|e| e.to_string())?
            .with_root_certificates(roots)
            .with_no_client_auth();
            cfg.builder(tokio_postgres_rustls::MakeRustlsConnect::new(tls_config))
                .map(|b| {
                    b.runtime(Runtime::Tokio1)
                        .post_create(crate::audit::checkout_hook())
                        .post_recycle(crate::audit::checkout_hook())
                        .build()
                })
        }
        "disable" => cfg.builder(NoTls).map(|b| {
            b.runtime(Runtime::Tokio1)
                .post_create(crate::audit::checkout_hook())
                .post_recycle(crate::audit::checkout_hook())
                .build()
        }),
        other => return Err(format!("Unsupported DB_SSLMODE: {}", other)),
    };
    match pool {
        Ok(Ok(pool)) => {
            info!(
                "PostgreSQL connection pool configured (sslmode={})",
                ssl_mode
            );
            Ok(Some(pool))
        }
        Ok(Err(e)) => Err(format!(
            "Failed to create PostgreSQL connection pool: {}",
            e
        )),
        Err(e) => Err(format!(
            "Failed to configure PostgreSQL connection pool: {}",
            e
        )),
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
    // tenant-guard: platform — startup system seed and sequence sync.
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_platform_tx(&mut client).await?;

    // Seed system reference data (banks, configs, root SaaS admin).
    tx.batch_execute(include_str!("../../db/seed/01-system-seed.sql"))
        .await?;

    // 2. Synchronize sequences
    // `pg_sequence_last_value` keeps the sync from ever moving a sequence backwards:
    // row-level security can hide rows from `MAX(..)` (audit tables fail closed even
    // for platform transactions), and resetting to 1 would break the next insert.
    tx.batch_execute(
        r#"
            DO $$
            DECLARE r record;
                    seq text;
                    seen bigint;
                    issued bigint;
            BEGIN
                FOR r IN SELECT table_name, column_name FROM information_schema.columns
                         WHERE table_schema = 'public' AND is_identity = 'YES' LOOP
                    seq := pg_get_serial_sequence(format('public.%I', r.table_name), r.column_name);
                    CONTINUE WHEN seq IS NULL;
                    EXECUTE format('SELECT COALESCE(MAX(%I), 0) FROM public.%I',
                                   r.column_name, r.table_name) INTO seen;
                    EXECUTE format('SELECT pg_sequence_last_value(%L::regclass)', seq) INTO issued;
                    EXECUTE format('SELECT setval(%L, GREATEST(%s, %s) + 1, false)',
                                   seq, seen, COALESCE(issued, 0));
                END LOOP;
            END $$;
            "#,
    )
    .await?;
    tx.commit().await?;

    info!("PostgreSQL schema verified and ready with auto-increment BIGINT identity (zero test mock data auto-added).");
    Ok(())
}

/// Seeds development/testing site fixtures (Begonya Sitesi, Kardelen Rezidans, test units, persons, and bank account).
/// Separated from startup/init_db so restarts maintain clean database state without auto-adding mock data.
pub async fn seed_test_data(pool: &Pool) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // tenant-guard: platform — dev/test fixture seeding.
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_platform_tx(&mut client).await?;
    info!("Seeding development test fixtures into PostgreSQL...");
    tx.batch_execute(include_str!("../../db/seed/02-test-seed.sql"))
        .await?;
    tx.commit().await?;
    info!("Development test fixtures seeded successfully into PostgreSQL.");
    Ok(())
}

pub async fn reset_db_to_seed_data(
    pool: &Pool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // tenant-guard: platform — dev/test database reset.
    let mut client = pool.get().await?;
    let tx = super::tenant_guard::begin_platform_tx(&mut client).await?;
    info!("Resetting PostgreSQL database to clean initial state (clean debts and payments)...");
    tx.batch_execute(
        r#"
            TRUNCATE TABLE payment_entries RESTART IDENTITY CASCADE;
            TRUNCATE TABLE payment_intents RESTART IDENTITY CASCADE;
            TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;
            TRUNCATE TABLE operating_budgets RESTART IDENTITY CASCADE;
            TRUNCATE TABLE reconciliation_queue CASCADE;
            TRUNCATE TABLE advance_balances CASCADE;
            TRUNCATE TABLE person_advance_holds CASCADE;
            TRUNCATE TABLE pending_registrations CASCADE;
            TRUNCATE TABLE invitation_tokens CASCADE;
            TRUNCATE TABLE unit_sender_ibans CASCADE;
            TRUNCATE TABLE unit_payer_names RESTART IDENTITY CASCADE;
            TRUNCATE TABLE occupancy_transitions RESTART IDENTITY;
            -- Only the seeded owners' sessions survive a reset (status is derived, V31).
            DELETE FROM occupancy_members WHERE occupancy_id IN (SELECT id FROM unit_occupancies WHERE occupancy_type <> 'OWNER');
            DELETE FROM unit_occupancies WHERE occupancy_type <> 'OWNER';
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
    tx.commit().await?;
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
    // tenant-guard: platform — full schema wipe.
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

/// Verify that a production runtime cannot bypass row policies or disable evidence triggers.
///
/// # Errors
/// Rejects privileged/owner roles and failed privilege inspection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeRoleStatus {
    pub superuser: bool,
    pub bypass_rls: bool,
    pub create_role: bool,
    pub create_database: bool,
    pub owns_public_tables: bool,
}

impl RuntimeRoleStatus {
    pub fn is_safe(self) -> bool {
        !self.superuser
            && !self.bypass_rls
            && !self.create_role
            && !self.create_database
            && !self.owns_public_tables
    }
}

/// Probe tenant policy and role readiness when PostgreSQL is configured.
pub async fn tenant_rls_readiness(
    pool: Option<&Pool>,
) -> DbResult<Option<(bool, RuntimeRoleStatus)>> {
    match pool {
        Some(pool) => Ok(Some((
            crate::db::rls_guard_installed(pool).await?,
            runtime_role_status(pool).await?,
        ))),
        None => Ok(None),
    }
}

/// Inspect role attributes that can bypass tenant policies or mutate the schema.
pub async fn runtime_role_status(pool: &Pool) -> DbResult<RuntimeRoleStatus> {
    let client = pool.get().await?;
    let row = client
        .query_one(
            "SELECT r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb,
         EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public' AND c.relkind='r'
                  AND pg_has_role(r.oid,c.relowner,'MEMBER'))
         FROM pg_roles r WHERE r.rolname=current_user",
            &[],
        )
        .await?;
    Ok(RuntimeRoleStatus {
        superuser: row.get(0),
        bypass_rls: row.get(1),
        create_role: row.get(2),
        create_database: row.get(3),
        owns_public_tables: row.get(4),
    })
}

/// Verify that the configured production role cannot bypass tenant row policies.
pub async fn validate_runtime_role(pool: &Pool) -> DbResult<()> {
    let role = runtime_role_status(pool).await?;
    if !role.is_safe() {
        tracing::error!(
            runtime_role_superuser = role.superuser,
            runtime_role_bypassrls = role.bypass_rls,
            runtime_role_createrole = role.create_role,
            runtime_role_createdb = role.create_database,
            runtime_role_owns_public_tables = role.owns_public_tables,
            "Production runtime role fails tenant RLS safety requirements"
        );
        return Err("Production requires a non-owner runtime role without SUPERUSER or BYPASSRLS; run migrations separately".into());
    }
    Ok(())
}

/// Where a service keeps its data, chosen once when the service is built, so each
/// operation has a single storage path instead of branching on the pool itself.
pub enum Storage {
    Postgres(deadpool_postgres::Pool),
    Memory,
}

impl Storage {
    pub fn of(state: &crate::state::AppState) -> Self {
        match state.pool.clone() {
            Some(pool) => Self::Postgres(pool),
            None => Self::Memory,
        }
    }
}
