//! Shared PostgreSQL test fixture: migrate and seed one database per nextest run, then clone it.

use std::sync::OnceLock;

use deadpool_postgres::Pool;
use sitepulse_backend::{db, migrations};

static MANUAL_RUN_ID: OnceLock<String> = OnceLock::new();
const TEMPLATE_LOCK_ID: i64 = 8_378_001;

pub struct TestDatabase {
    pub name: String,
    /// The `postgres` database, used to create and drop throwaway databases.
    pub admin: Pool,
    /// The clone as the schema owner: fixture SQL and assertions, which must not be
    /// narrowed by row-level security and may need DDL.
    pub owner: Pool,
    /// The clone as the runtime identity: the application under test.
    pub pool: Pool,
}

/// Creates a disposable database from the run's migrated, seeded template.
pub async fn create(tag: &str) -> TestDatabase {
    let template = ensure_template().await;
    let safe_tag = tag
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || *character == '_')
        .take(20)
        .collect::<String>();
    let name = format!("sp_it_{}_{}", safe_tag, uuid::Uuid::new_v4().simple());
    let admin = db::create_admin_pool_for("postgres").expect("DB_PASS is required for PostgreSQL tests");
    admin
        .get()
        .await
        .expect("PostgreSQL admin connection")
        .batch_execute(&format!("CREATE DATABASE {name} TEMPLATE {template}"))
        .await
        .expect("clone PostgreSQL test template");
    let owner = db::create_admin_pool_for(&name).expect("owner connection pool");
    // The application pool uses the runtime identity (`DB_USER`): when CI splits
    // it from the owner, row-level security applies to every query it makes.
    let pool = db::create_pool_for(&name).expect("test database connection pool");

    TestDatabase { name, admin, owner, pool }
}

async fn ensure_template() -> String {
    let run_id = std::env::var("NEXTEST_RUN_ID").unwrap_or_else(|_| {
        MANUAL_RUN_ID
            .get_or_init(|| format!("manual_{}", uuid::Uuid::new_v4().simple()))
            .clone()
    });
    let safe_run_id = run_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(40)
        .collect::<String>();
    let template = format!(
        "sp_it_tpl_{}_v{}",
        safe_run_id,
        migrations::latest_version()
    );
    let admin = db::create_admin_pool_for("postgres").expect("DB_PASS is required for PostgreSQL tests");
    let client = admin.get().await.expect("PostgreSQL admin connection");
    client
        .query_one("SELECT pg_advisory_lock($1)", &[&TEMPLATE_LOCK_ID])
        .await
        .expect("lock PostgreSQL test template initialization");
    let exists: bool = client
        .query_one(
            "SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)",
            &[&template],
        )
        .await
        .expect("check PostgreSQL test template")
        .get(0);

    if !exists {
        client
            .batch_execute(&format!("CREATE DATABASE {template}"))
            .await
            .expect("create PostgreSQL test template");
        // The template is migrated and seeded by the schema owner, so a cloned
        // database carries both the schema and the owner's privileges.
        let template_pool =
            db::create_admin_pool_for(&template).expect("template connection pool");
        db::init_db(&template_pool)
            .await
            .expect("apply migrations to PostgreSQL test template");
        db::seed_test_data(&template_pool)
            .await
            .expect("seed PostgreSQL test template");
        // Only when CI splits the identities: the runtime role needs the tenant
        // role V25 uses for `SET LOCAL ROLE` binding.
        if db::admin_credentials().is_some() {
            let runtime_role = std::env::var("DB_USER").unwrap_or_else(|_| "sitepulse_user".to_string());
            db::provision_runtime_role(&template_pool, &runtime_role)
                .await
                .expect("grant the tenant role to the runtime identity");
        }
        drop(template_pool);
    }

    client
        .query_one("SELECT pg_advisory_unlock($1)", &[&TEMPLATE_LOCK_ID])
        .await
        .expect("unlock PostgreSQL test template initialization");
    template
}

impl TestDatabase {
    pub async fn drop_db(self) {
        drop(self.pool);
        if let Ok(client) = self.admin.get().await {
            let _ = client
                .batch_execute(&format!(
                    "DROP DATABASE IF EXISTS {} WITH (FORCE)",
                    self.name
                ))
                .await;
        }
    }
}
