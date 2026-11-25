//! PostgreSQL tests for merging person cards (task-38, D1).
//!
//! They run the service against a throwaway database (created and dropped per
//! test) and need PostgreSQL and `DB_PASS`:
//!
//! ```text
//! cargo nextest run --locked --profile db --test it -E 'test(/db_person_merge_tests::/)' --run-ignored ignored-only --test-threads 4
//! ```
//!
//! The verification gate `rust-db-test` runs them.

use deadpool_postgres::Pool;
use sitepulse_backend::authorization::AuthzContext;
use sitepulse_backend::models::{Permission, Role};
use sitepulse_backend::services::person_merge_service::{
    MergePersonRequest, PersonMergeError, PersonMergeService,
};
use sitepulse_backend::{auth, state::AppState};

struct TestDb {
    name: String,
    admin: Pool,
    pool: Pool,
    site: i64,
}

impl TestDb {
    async fn create(tag: &str) -> Self {
        let crate::test_db::TestDatabase { name, admin, pool } = crate::test_db::create(tag).await;
        let site: i64 = pool
            .get()
            .await
            .expect("connection")
            .query_one("SELECT id FROM sites WHERE slug = 'begonya-sitesi'", &[])
            .await
            .expect("site")
            .get(0);
        Self {
            name,
            admin,
            pool,
            site,
        }
    }

    async fn drop_db(self) {
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

    async fn exec(&self, sql: &str) {
        let client = self.pool.get().await.expect("connection");
        client.batch_execute(sql).await.expect(sql);
    }

    async fn int(&self, sql: &str) -> i64 {
        let client = self.pool.get().await.expect("connection");
        client.query_one(sql, &[]).await.expect(sql).get(0)
    }

    async fn person(&self, name: &str, email: Option<&str>) -> i64 {
        let client = self.pool.get().await.expect("connection");
        client
            .query_one(
                "INSERT INTO persons (full_name, email, person_type, site_id) \
                 VALUES ($1, $2, 'HOME_OWNER', $3) RETURNING id",
                &[&name, &email, &self.site],
            )
            .await
            .expect("person")
            .get(0)
    }

    async fn unit(&self, number: i32) -> i64 {
        self.int(&format!(
            "INSERT INTO units (block_id, unit_number, floor, site_id) \
             SELECT b.id, {number}, 1, b.site_id FROM blocks b WHERE b.site_id = {} \
             ORDER BY b.id LIMIT 1 RETURNING id",
            self.site
        ))
        .await
    }

    async fn own(&self, unit: i64, person: i64) {
        self.exec(&format!(
            "INSERT INTO unit_ownerships (unit_id, person_id) VALUES ({unit}, {person})"
        ))
        .await;
    }

    async fn rent(&self, unit: i64, person: i64) {
        self.exec(&format!(
            "INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type) \
             VALUES ({unit}, {person}, 'TENANT')"
        ))
        .await;
    }

    fn service(&self) -> PersonMergeService {
        PersonMergeService::new(&AppState::with_pool(Some(self.pool.clone())))
    }

    fn ctx(&self, stepped_up: bool) -> AuthzContext {
        let token = auth::issue_token(
            "usr-merge",
            "",
            Role::SiteManager,
            &self.site.to_string(),
            None,
        )
        .expect("token");
        AuthzContext {
            claims: auth::verify_token(&token).expect("claims"),
            permissions: Permission::permissions_for_role(Role::SiteManager),
            request_id: "person-merge".to_string(),
            stepped_up,
        }
    }

    async fn merge(
        &self,
        source: i64,
        target: i64,
    ) -> Result<sitepulse_backend::services::person_merge_service::MergeOutcome, PersonMergeError>
    {
        self.service()
            .merge(
                &self.ctx(true),
                &self.site.to_string(),
                source,
                &MergePersonRequest {
                    target_person_id: target.to_string(),
                    expected_target_version: None,
                },
            )
            .await
    }
}

// covers: SC-12-01-01
#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn merge_repoints_relationships_and_leaves_a_tombstone() {
    let t = TestDb::create("repoint").await;
    let source = t
        .person("Ayse Duplicate", Some("ayse.dup@example.com"))
        .await;
    let target = t.person("Ayse Survivor", None).await;
    let unit = t.unit(901).await;
    t.own(unit, source).await;
    t.exec(&format!(
        "UPDATE units SET owner_person_id = {source}, primary_contact_person_id = {source} WHERE id = {unit}"
    ))
    .await;

    let outcome = t.merge(source, target).await.expect("merge");
    assert_eq!(outcome.target_person_id, target.to_string());

    assert_eq!(
        t.int(&format!(
            "SELECT person_id FROM unit_ownerships WHERE unit_id = {unit}"
        ))
        .await,
        target
    );
    assert_eq!(
        t.int(&format!(
            "SELECT owner_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        target
    );
    assert_eq!(
        t.int(&format!(
            "SELECT primary_contact_person_id FROM units WHERE id = {unit}"
        ))
        .await,
        target
    );
    assert_eq!(
        t.int(&format!(
            "SELECT merged_into_person_id FROM persons WHERE id = {source}"
        ))
        .await,
        target
    );
    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM persons WHERE id = {source} AND deleted_at IS NOT NULL"
        ))
        .await,
        1
    );
    // The surviving card takes the e-mail the tombstone released.
    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM persons WHERE id = {target} AND email = 'ayse.dup@example.com'"
        ))
        .await,
        1
    );
    assert_eq!(
        t.int(&format!("SELECT sp_canonical_person({source})"))
            .await,
        target
    );
    assert_eq!(
        t.int(&format!("SELECT sp_canonical_person({target})"))
            .await,
        target
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn merge_leaves_payment_ledger_ids_intact() {
    let t = TestDb::create("ledger").await;
    let source = t.person("Ledger Payer", None).await;
    let target = t.person("Ledger Survivor", None).await;
    let before = t
        .int("SELECT count(*) FROM payment_entries WHERE payer_person_id IS NOT NULL")
        .await;
    t.exec(&format!(
        "UPDATE payment_entries SET payer_person_id = {source} WHERE id = (SELECT min(id) FROM payment_entries)"
    ))
    .await;
    let with_source = t
        .int(&format!(
            "SELECT count(*) FROM payment_entries WHERE payer_person_id = {source}"
        ))
        .await;

    t.merge(source, target).await.expect("merge");

    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM payment_entries WHERE payer_person_id = {source}"
        ))
        .await,
        with_source,
        "ledger rows keep the old person id"
    );
    assert!(before >= 0);
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn merge_is_refused_when_roles_conflict_on_a_unit() {
    let t = TestDb::create("conflict").await;
    let owner = t.person("Conflict Owner", None).await;
    let tenant = t.person("Conflict Tenant", None).await;
    let unit = t.unit(902).await;
    t.own(unit, owner).await;
    t.rent(unit, tenant).await;

    let err = t.merge(tenant, owner).await.expect_err("conflict");
    assert_eq!(err, PersonMergeError::RoleConflict { unit_id: unit });
    assert_eq!(
        t.int(&format!(
            "SELECT count(*) FROM persons WHERE id = {tenant} AND merged_into_person_id IS NULL"
        ))
        .await,
        1,
        "a refused merge changes nothing"
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn merge_needs_step_up_and_refuses_self_and_merged_cards() {
    let t = TestDb::create("guards").await;
    let a = t.person("Guard A", None).await;
    let b = t.person("Guard B", None).await;
    let c = t.person("Guard C", None).await;

    let request = MergePersonRequest {
        target_person_id: b.to_string(),
        expected_target_version: None,
    };
    let site = t.site.to_string();
    assert_eq!(
        t.service()
            .merge(&t.ctx(false), &site, a, &request)
            .await
            .unwrap_err(),
        PersonMergeError::StepUpRequired
    );
    assert_eq!(
        t.merge(a, a).await.unwrap_err(),
        PersonMergeError::SamePerson
    );
    t.merge(a, b).await.expect("first merge");
    // The second of two competing merges sees the tombstone.
    assert_eq!(
        t.merge(a, c).await.unwrap_err(),
        PersonMergeError::NotMergeable
    );
    assert_eq!(
        t.merge(c, a).await.unwrap_err(),
        PersonMergeError::NotMergeable
    );

    let stale = MergePersonRequest {
        target_person_id: b.to_string(),
        expected_target_version: Some(-1),
    };
    assert_eq!(
        t.service()
            .merge(&t.ctx(true), &site, c, &stale)
            .await
            .unwrap_err(),
        PersonMergeError::VersionMismatch
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn concurrent_merges_of_one_card_apply_once() {
    let t = TestDb::create("race").await;
    let source = t.person("Race Source", None).await;
    let first = t.person("Race First", None).await;
    let second = t.person("Race Second", None).await;
    let (r1, r2) = tokio::join!(t.merge(source, first), t.merge(source, second));
    assert_eq!([r1.is_ok(), r2.is_ok()].iter().filter(|ok| **ok).count(), 1);
    assert_eq!(
        t.int(&format!("SELECT count(*) FROM persons WHERE merged_into_person_id IS NOT NULL AND id = {source}")).await,
        1
    );
    t.drop_db().await;
}

#[tokio::test]
#[ignore = "needs PostgreSQL and DB_PASS"]
async fn a_foreign_site_card_cannot_be_merged() {
    let t = TestDb::create("tenant").await;
    let mine = t.person("Mine", None).await;
    let other_site = t
        .int("INSERT INTO sites (name, slug) VALUES ('Other', 'other-merge-site') RETURNING id")
        .await;
    let foreign = t
        .int(&format!(
            "INSERT INTO persons (full_name, person_type, site_id) VALUES ('Foreign', 'HOME_OWNER', {other_site}) RETURNING id"
        ))
        .await;
    assert_eq!(
        t.merge(mine, foreign).await.unwrap_err(),
        PersonMergeError::NotFound
    );
    t.drop_db().await;
}
