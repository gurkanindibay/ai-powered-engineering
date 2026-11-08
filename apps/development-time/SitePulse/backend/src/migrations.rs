//! Versioned schema migrations.
//!
//! `backend/migrations/V<n>__<name>.sql` is the only schema source. Each file is
//! applied once, in version order, inside its own transaction, and recorded in
//! `schema_migrations` with a SHA-256 checksum. An applied migration whose file
//! later changes stops startup: released migrations are append-only.
//!
//! Databases created before this runner existed re-ran every schema file on each
//! boot, so all migrations are idempotent; on such a database the pending ones
//! are simply applied once and recorded.

use deadpool_postgres::Pool;
use sha2::{Digest, Sha256};

pub struct Migration {
    pub version: i32,
    pub name: &'static str,
    pub sql: &'static str,
}

macro_rules! migration {
    ($v:expr, $file:literal) => {
        Migration {
            version: $v,
            name: $file,
            sql: include_str!(concat!("../migrations/", $file)),
        }
    };
}

pub const MIGRATIONS: &[Migration] = &[
    migration!(1, "V1__init_schema.sql"),
    migration!(2, "V2__saas_multi_tenancy.sql"),
    migration!(3, "V3__auth_and_permission_providers.sql"),
    migration!(4, "V4__site_bank_account.sql"),
    migration!(5, "V5__payment_tracking_and_receipts.sql"),
    migration!(6, "V6__capital_expenditure_and_fixtures.sql"),
    migration!(7, "V7__viable_occupancy_ownership_and_identity.sql"),
    migration!(8, "V8__schema_integrity_fixes.sql"),
    migration!(9, "V9__referential_and_financial_integrity.sql"),
    migration!(10, "V10__ledger_and_referential_integrity.sql"),
    migration!(11, "V11__consolidate_household_members.sql"),
    migration!(12, "V12__financial_and_tenancy_remediation.sql"),
    migration!(13, "V13__security_hardening.sql"),
    migration!(14, "V14__referential_ledger_and_vocabulary_integrity.sql"),
    migration!(15, "V15__duplicated_facts_sync_and_pii.sql"),
    migration!(16, "V16__payment_ledger_integrity.sql"),
    migration!(17, "V17__payment_ledger_hardening.sql"),
    migration!(18, "V18__payments_phase2.sql"),
];

/// Arbitrary constant for `pg_advisory_lock`, so concurrent instances migrate one at a time.
const MIGRATION_LOCK_KEY: i64 = 0x5349_5445_5055_4C53; // "SITEPULS"

pub fn checksum(sql: &str) -> String {
    hex::encode(Sha256::digest(sql.as_bytes()))
}

/// Latest schema version known to this build.
pub fn latest_version() -> i32 {
    MIGRATIONS.last().map(|m| m.version).unwrap_or(0)
}

/// Applies pending migrations. Returns the versions applied by this call.
pub async fn run(pool: &Pool) -> crate::db::DbResult<Vec<i32>> {
    let mut client = pool.get().await?;
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (
                 version    INT PRIMARY KEY,
                 name       TEXT NOT NULL,
                 checksum   TEXT NOT NULL,
                 applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
             )",
        )
        .await?;
    client
        .execute("SELECT pg_advisory_lock($1)", &[&MIGRATION_LOCK_KEY])
        .await?;
    let result = apply_pending(&mut client).await;
    client
        .execute("SELECT pg_advisory_unlock($1)", &[&MIGRATION_LOCK_KEY])
        .await?;
    result
}

async fn apply_pending(client: &mut deadpool_postgres::Object) -> crate::db::DbResult<Vec<i32>> {
    let applied: std::collections::HashMap<i32, String> = client
        .query("SELECT version, checksum FROM schema_migrations", &[])
        .await?
        .into_iter()
        .map(|r| (r.get(0), r.get(1)))
        .collect();
    let mut newly = Vec::new();
    for m in MIGRATIONS {
        let sum = checksum(m.sql);
        if let Some(existing) = applied.get(&m.version) {
            if existing != &sum {
                return Err(format!(
                    "Migration {} was modified after it was applied (checksum mismatch). Add a new migration instead.",
                    m.name
                )
                .into());
            }
            continue;
        }
        let tx = client.transaction().await?;
        tx.batch_execute(m.sql).await.map_err(|e| {
            let detail = e
                .as_db_error()
                .map(|d| format!("{} ({:?})", d.message(), d.where_()))
                .unwrap_or_else(|| e.to_string());
            format!("Migration {} failed: {}", m.name, detail)
        })?;
        tx.execute(
            "INSERT INTO schema_migrations (version, name, checksum) VALUES ($1, $2, $3)",
            &[&m.version, &m.name, &sum],
        )
        .await?;
        tx.commit().await?;
        tracing::info!("Applied migration {}", m.name);
        newly.push(m.version);
    }
    Ok(newly)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_migration_file_is_registered_in_order() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
        let mut files: Vec<(i32, String)> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with('V') && n.ends_with(".sql"))
            .map(|n| (n[1..n.find("__").unwrap()].parse().unwrap(), n))
            .collect();
        files.sort();
        let registered: Vec<(i32, String)> = MIGRATIONS
            .iter()
            .map(|m| (m.version, m.name.to_string()))
            .collect();
        assert_eq!(
            registered, files,
            "MIGRATIONS must list every file in migrations/, in version order"
        );
        for w in MIGRATIONS.windows(2) {
            assert_eq!(
                w[1].version,
                w[0].version + 1,
                "versions must be contiguous"
            );
        }
    }
}
