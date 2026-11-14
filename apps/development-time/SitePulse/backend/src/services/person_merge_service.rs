//! Merging one person card into another (unified owners and residents design,
//! "Merge A into B").
//!
//! A merge runs in one transaction. Both cards are locked in ID order, so two
//! merges that touch the same cards serialise instead of deadlocking, and the
//! second one sees the first one's tombstone and is refused. Every relationship row
//! is repointed to the surviving card. The append-only payment ledger is never
//! touched: it keeps the old person ID, and `sp_canonical_person` (V34) resolves the
//! tombstone for readers that need the current card.

use serde::{Deserialize, Serialize};

use crate::authorization::AuthzContext;
use crate::db::Storage;
use crate::state::AppState;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PersonMergeError {
    #[error("Person not found")]
    NotFound,
    #[error("A person cannot be merged into itself")]
    SamePerson,
    #[error("Archived or already merged cards cannot be merged")]
    NotMergeable,
    #[error("The target card changed since it was loaded")]
    VersionMismatch,
    #[error("Both cards hold conflicting roles on unit {unit_id}")]
    RoleConflict { unit_id: i64 },
    #[error("Merging a person needs a recent step-up verification")]
    StepUpRequired,
    #[error("Person merge needs the database")]
    Unavailable,
    #[error("Person merge storage error: {0}")]
    Storage(String),
}

fn storage(e: impl std::fmt::Display) -> PersonMergeError {
    PersonMergeError::Storage(e.to_string())
}

#[derive(Debug, Clone, Deserialize)]
pub struct MergePersonRequest {
    /// The card that survives.
    pub target_person_id: String,
    /// Version of the target card the caller saw; a stale value is refused.
    #[serde(default)]
    pub expected_target_version: Option<i32>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct MergeOutcome {
    pub source_person_id: String,
    pub target_person_id: String,
    pub target_version: i32,
}

/// Units on which the two cards hold different active roles (owner against tenant).
const ROLE_CONFLICT_SQL: &str = "\
    WITH roles AS ( \
        SELECT unit_id, person_id, 'OWNER' AS role FROM unit_ownerships \
          WHERE is_active AND person_id = ANY($1) \
        UNION ALL SELECT id, owner_person_id, 'OWNER' FROM units \
          WHERE owner_person_id = ANY($1) AND deleted_at IS NULL \
        UNION ALL SELECT unit_id, person_id, 'TENANT' FROM unit_occupancies \
          WHERE is_active AND end_date IS NULL AND occupancy_type = 'TENANT' AND person_id = ANY($1) \
        UNION ALL SELECT id, tenant_person_id, 'TENANT' FROM units \
          WHERE tenant_person_id = ANY($1) AND deleted_at IS NULL) \
    SELECT a.unit_id FROM roles a \
      JOIN roles b ON b.unit_id = a.unit_id AND b.role <> a.role \
     WHERE a.person_id = $2 AND b.person_id = $3 \
     ORDER BY a.unit_id LIMIT 1";

pub struct PersonMergeService {
    store: Storage,
}

impl PersonMergeService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: Storage::of(state),
        }
    }

    /// Merges `source_id` into the card named by the request.
    ///
    /// # Errors
    /// Missing step-up, unknown or foreign cards, archived or merged cards, a stale
    /// target version, conflicting unit roles, or a storage failure.
    pub async fn merge(
        &self,
        ctx: &AuthzContext,
        site_id: &str,
        source_id: i64,
        request: &MergePersonRequest,
    ) -> Result<MergeOutcome, PersonMergeError> {
        if !ctx.stepped_up {
            return Err(PersonMergeError::StepUpRequired);
        }
        let site = crate::db::parse_id_to_i64(site_id).ok_or(PersonMergeError::NotFound)?;
        let target_id = crate::db::parse_id_to_i64(&request.target_person_id)
            .ok_or(PersonMergeError::NotFound)?;
        if source_id == target_id {
            return Err(PersonMergeError::SamePerson);
        }
        let Storage::Postgres(pool) = &self.store else {
            return Err(PersonMergeError::Unavailable);
        };
        let mut client = pool.get().await.map_err(storage)?;
        let tx = client.transaction().await.map_err(storage)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(storage)?;

        let ids = vec![source_id, target_id];
        let locked = tx
            .query(
                "SELECT id, deleted_at IS NOT NULL OR merged_into_person_id IS NOT NULL, \
                        COALESCE(email, ''), COALESCE(phone, ''), version \
                 FROM persons WHERE id = ANY($1) AND site_id = $2 ORDER BY id FOR UPDATE",
                &[&ids, &site],
            )
            .await
            .map_err(storage)?;
        if locked.len() != 2 {
            return Err(PersonMergeError::NotFound);
        }
        let row_of = |id: i64| locked.iter().find(|r| r.get::<_, i64>(0) == id);
        let (source, target) = match (row_of(source_id), row_of(target_id)) {
            (Some(s), Some(t)) => (s, t),
            _ => return Err(PersonMergeError::NotFound),
        };
        if source.get::<_, bool>(1) || target.get::<_, bool>(1) {
            return Err(PersonMergeError::NotMergeable);
        }
        let target_version: i32 = target.get(4);
        if request
            .expected_target_version
            .is_some_and(|expected| expected != target_version)
        {
            return Err(PersonMergeError::VersionMismatch);
        }
        if let Some(conflict) = tx
            .query_opt(ROLE_CONFLICT_SQL, &[&ids, &source_id, &target_id])
            .await
            .map_err(storage)?
        {
            return Err(PersonMergeError::RoleConflict {
                unit_id: conflict.get(0),
            });
        }

        let source_email: String = source.get(2);
        let source_phone: String = source.get(3);
        let target_email: String = target.get(2);
        let target_phone: String = target.get(3);
        let move_email = target_email.is_empty() && !source_email.is_empty();
        let move_phone = target_phone.is_empty() && !source_phone.is_empty();

        // Login: the target's login wins; otherwise the source's login follows the card.
        tx.execute(
            "UPDATE users SET is_active = FALSE WHERE person_id = $1 AND is_active \
               AND EXISTS (SELECT 1 FROM users t WHERE t.person_id = $2 AND t.is_active)",
            &[&source_id, &target_id],
        )
        .await
        .map_err(storage)?;
        tx.execute(
            "UPDATE users SET person_id = $2 WHERE person_id = $1 AND is_active",
            &[&source_id, &target_id],
        )
        .await
        .map_err(storage)?;

        // Household members: drop rows that would duplicate, repoint the rest.
        tx.execute(
            "DELETE FROM occupancy_members s WHERE s.person_id = $1 AND EXISTS ( \
               SELECT 1 FROM occupancy_members t \
                WHERE t.occupancy_id = s.occupancy_id AND t.person_id = $2)",
            &[&source_id, &target_id],
        )
        .await
        .map_err(storage)?;
        for sql in [
            "UPDATE occupancy_members SET person_id = $2 WHERE person_id = $1",
            "UPDATE unit_ownerships SET person_id = $2 WHERE person_id = $1",
            "UPDATE unit_occupancies SET person_id = $2 WHERE person_id = $1",
            "UPDATE units SET owner_person_id = $2 WHERE owner_person_id = $1 AND site_id = $3",
            "UPDATE units SET tenant_person_id = $2 WHERE tenant_person_id = $1 AND site_id = $3",
            "UPDATE units SET primary_contact_person_id = $2 \
             WHERE primary_contact_person_id = $1 AND site_id = $3",
        ] {
            if sql.contains("$3") {
                tx.execute(sql, &[&source_id, &target_id, &site])
                    .await
                    .map_err(storage)?;
            } else {
                tx.execute(sql, &[&source_id, &target_id])
                    .await
                    .map_err(storage)?;
            }
        }

        // The tombstone first: the unique e-mail index must release the address
        // before the surviving card takes it. Payment tables are not updated.
        tx.execute(
            "UPDATE persons SET merged_into_person_id = $2, deleted_at = CURRENT_TIMESTAMP, \
                    version = version + 1, \
                    email = CASE WHEN $3 THEN NULL ELSE email END \
             WHERE id = $1",
            &[&source_id, &target_id, &move_email],
        )
        .await
        .map_err(storage)?;
        let merged = tx
            .query_one(
                "UPDATE persons SET version = version + 1, \
                        email = CASE WHEN $2 THEN $3 ELSE email END, \
                        phone = CASE WHEN $4 THEN $5 ELSE phone END \
                 WHERE id = $1 RETURNING version",
                &[
                    &target_id,
                    &move_email,
                    &source_email,
                    &move_phone,
                    &source_phone,
                ],
            )
            .await
            .map_err(storage)?;
        let new_version: i32 = merged.get(0);

        tx.execute(
            "INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,site_id,action,resource_type,resource_id,outcome,changes) \
             VALUES ($1,'USER',$2,$3,$4,'PERSON_MERGED','persons',$5,'SUCCESS', \
                     jsonb_build_object('source_person_id',$6::bigint,'target_person_id',$7::bigint))",
            &[
                &ctx.request_id,
                &ctx.claims.sub,
                &ctx.claims.role.as_str(),
                &site,
                &source_id.to_string(),
                &source_id,
                &target_id,
            ],
        )
        .await
        .map_err(storage)?;
        tx.commit().await.map_err(storage)?;
        Ok(MergeOutcome {
            source_person_id: source_id.to_string(),
            target_person_id: target_id.to_string(),
            target_version: new_version,
        })
    }
}
