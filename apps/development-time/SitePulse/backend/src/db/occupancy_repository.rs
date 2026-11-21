//! Executes unit state transitions (EPIC-08 §3.3, STORY-08-06..10).
//!
//! Every move-in, move-out, compound move, owner registration and title transfer
//! runs here, inside the caller's transaction with the unit row locked. The
//! precondition is checked against the source-of-truth tables
//! (`unit_ownerships`, `unit_occupancies`) through `domain::unit_state::plan`;
//! an illegal command returns an error before any row changes. Projections on
//! `units` are maintained by triggers (V15, V31), and each transition is
//! recorded in `occupancy_transitions`.

use chrono::NaiveDate;
use deadpool_postgres::Transaction;
use rust_decimal::Decimal;

use crate::domain::unit_state::{
    self, Command, Occupancy, Occupant, Ownership, SessionRole, TransitionError, TransitionPlan,
    UnitState,
};

/// Why a transition could not be applied.
#[derive(Debug, thiserror::Error)]
pub enum OccupancyError {
    #[error(transparent)]
    Rule(#[from] TransitionError),
    #[error("Unit not found")]
    UnitNotFound,
    #[error("Person not found")]
    PersonNotFound,
    #[error("The incoming tenant must be named")]
    TenantRequired,
    #[error("This person is an owner of the unit; use owner move-in instead of tenant move-in")]
    TenantIsOwner,
    #[error("This person is already the unit's tenant")]
    SameTenant,
    #[error("Only an owner on record can move in as owner; a new owner is recorded by a title deed transfer")]
    NotAnOwner,
    #[error("The buyer is already an owner of the unit")]
    BuyerIsOwner,
    #[error("The unit has several owners; choose which owner moves in")]
    OwnerChoiceRequired,
    #[error("{0} is not an occupancy command; use owner registration or title transfer")]
    UnsupportedCommand(&'static str),
    #[error("{0}")]
    InvalidEmail(String),
    #[error("Invalid date {0}; expected YYYY-MM-DD")]
    InvalidDate(String),
    #[error(
        "The unit already has an owner on record; a new owner is recorded by a title deed transfer"
    )]
    UnitHasOwner,
    #[error(transparent)]
    Person(#[from] crate::services::person_service::PersonApiError),
    #[error("Database error: {0}")]
    Storage(String),
}

impl From<tokio_postgres::Error> for OccupancyError {
    fn from(error: tokio_postgres::Error) -> Self {
        // "db error" alone hides the cause; keep the server's message for the log.
        let detail = error
            .as_db_error()
            .map_or_else(|| error.to_string(), |db| db.message().to_string());
        Self::Storage(detail)
    }
}

/// An owner on record.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct OwnerOnRecord {
    pub person_id: i64,
    pub full_name: String,
    pub share_percentage: Decimal,
    pub start_date: NaiveDate,
}

/// The unit's active occupancy session.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ActiveSession {
    pub occupancy_id: i64,
    pub person_id: i64,
    pub full_name: String,
    pub role: SessionRole,
    pub start_date: NaiveDate,
}

/// The unit's state as read from the source-of-truth tables, under the row lock.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct UnitSnapshot {
    pub unit_id: i64,
    pub site_id: i64,
    pub state: UnitState,
    pub owners: Vec<OwnerOnRecord>,
    pub session: Option<ActiveSession>,
}

impl UnitSnapshot {
    pub fn is_owner(&self, person_id: i64) -> bool {
        self.owners.iter().any(|o| o.person_id == person_id)
    }

    /// The owner who moves in: the requested one (must be an owner), or the
    /// only owner when there is just one (decision A1).
    pub fn resolve_owner(&self, requested: Option<i64>) -> Result<i64, OccupancyError> {
        match requested {
            Some(person_id) if self.is_owner(person_id) => Ok(person_id),
            Some(_) => Err(OccupancyError::NotAnOwner),
            None => match self.owners.as_slice() {
                [only] => Ok(only.person_id),
                [] => Err(TransitionError::OwnerRequired.into()),
                _ => Err(OccupancyError::OwnerChoiceRequired),
            },
        }
    }
}

/// Parameters of one transition.
#[derive(Debug, Clone, Default)]
pub struct TransitionInput {
    pub effective_date: NaiveDate,
    pub today: NaiveDate,
    /// The incoming tenant (T2, C1, C2).
    pub tenant_person_id: Option<i64>,
    /// The owner who moves in (T3, C3), or the registered owner (T1).
    pub owner_person_id: Option<i64>,
    /// The buyer of a title transfer (T6).
    pub new_owner_person_id: Option<i64>,
    pub notes: Option<String>,
}

/// A session closed by a transition.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct ClosedSession {
    pub occupancy_id: i64,
    pub person_id: i64,
    pub role: SessionRole,
    pub start_date: NaiveDate,
    pub end_date: NaiveDate,
    pub exit_balance: Decimal,
}

/// A session opened by a transition.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct OpenedSession {
    pub occupancy_id: i64,
    pub person_id: i64,
    pub role: SessionRole,
    pub start_date: NaiveDate,
}

/// What a transition did.
#[derive(Debug, Clone, PartialEq)]
pub struct TransitionOutcome {
    pub plan: TransitionPlan,
    pub closed: Option<ClosedSession>,
    pub opened: Option<OpenedSession>,
}

/// Locks the unit and reads its state from the source-of-truth tables.
pub async fn lock_unit_snapshot(
    tx: &Transaction<'_>,
    site_id: i64,
    unit_id: i64,
) -> Result<UnitSnapshot, OccupancyError> {
    tx.query_opt(
        "SELECT id FROM units WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL FOR UPDATE",
        &[&unit_id, &site_id],
    )
    .await?
    .ok_or(OccupancyError::UnitNotFound)?;
    read_snapshot(tx, site_id, unit_id, true).await
}

async fn read_snapshot(
    tx: &Transaction<'_>,
    site_id: i64,
    unit_id: i64,
    lock: bool,
) -> Result<UnitSnapshot, OccupancyError> {
    let owners = tx
        .query(
            r#"
            SELECT o.person_id, p.full_name, COALESCE(w.share_percentage, 100.00), COALESCE(w.start_date, u.created_at::date, CURRENT_DATE)
            FROM sp_unit_owner_ids($1) o
            JOIN persons p ON p.id = o.person_id
            JOIN units u ON u.id = $1
            LEFT JOIN unit_ownerships w ON w.unit_id = $1 AND w.person_id = o.person_id AND w.is_active
            ORDER BY 3 DESC, 4, 1
            "#,
            &[&unit_id],
        )
        .await?
        .into_iter()
        .map(|row| OwnerOnRecord {
            person_id: row.get(0),
            full_name: row.get(1),
            share_percentage: row.get(2),
            start_date: row.get(3),
        })
        .collect::<Vec<_>>();
    let session_sql = if lock {
        "SELECT oc.id, oc.person_id, p.full_name, oc.occupancy_type, oc.start_date \
         FROM unit_occupancies oc JOIN persons p ON p.id = oc.person_id \
         WHERE oc.unit_id = $1 AND oc.is_active \
         ORDER BY oc.start_date DESC, oc.id DESC LIMIT 1 FOR UPDATE OF oc"
    } else {
        "SELECT oc.id, oc.person_id, p.full_name, oc.occupancy_type, oc.start_date \
         FROM unit_occupancies oc JOIN persons p ON p.id = oc.person_id \
         WHERE oc.unit_id = $1 AND oc.is_active \
         ORDER BY oc.start_date DESC, oc.id DESC LIMIT 1"
    };
    let session = tx
        .query_opt(session_sql, &[&unit_id])
        .await?
        .map(|row| ActiveSession {
            occupancy_id: row.get(0),
            person_id: row.get(1),
            full_name: row.get(2),
            role: SessionRole::from_stored(&row.get::<_, String>(3)),
            start_date: row.get(4),
        });
    let ownership = if owners.is_empty() {
        Ownership::Unowned
    } else {
        Ownership::Owned
    };
    let occupancy = Occupancy::from_session(session.as_ref().map(|s| s.role));
    Ok(UnitSnapshot {
        unit_id,
        site_id,
        state: UnitState::new(ownership, occupancy),
        owners,
        session,
    })
}

/// Applies an occupancy command (T2-T5, C1-C3) that does not change ownership.
pub async fn apply_occupancy_command(
    tx: &Transaction<'_>,
    site_id: i64,
    unit_id: i64,
    command: Command,
    input: &TransitionInput,
) -> Result<TransitionOutcome, OccupancyError> {
    let snapshot = lock_unit_snapshot(tx, site_id, unit_id).await?;
    let plan = unit_state::plan(snapshot.state, command)?;
    let incoming = incoming_person(&snapshot, &plan, input)?;
    unit_state::validate_effective_date(input.effective_date, input.today)?;
    execute_plan(tx, &snapshot, plan, incoming, input).await
}

/// The person whose session the plan opens, validated against the owners.
fn incoming_person(
    snapshot: &UnitSnapshot,
    plan: &TransitionPlan,
    input: &TransitionInput,
) -> Result<Option<i64>, OccupancyError> {
    let Some((_, occupant)) = plan.opens else {
        return Ok(None);
    };
    match occupant {
        Occupant::IncomingTenant => {
            let tenant = input
                .tenant_person_id
                .ok_or(OccupancyError::TenantRequired)?;
            if snapshot.is_owner(tenant) {
                return Err(OccupancyError::TenantIsOwner);
            }
            if snapshot
                .session
                .as_ref()
                .is_some_and(|s| s.person_id == tenant)
            {
                return Err(OccupancyError::SameTenant);
            }
            Ok(Some(tenant))
        }
        Occupant::OwnerOnRecord => match plan.from.ownership {
            // T1: the owner being registered is not on record yet.
            Ownership::Unowned => input
                .owner_person_id
                .map(Some)
                .ok_or(OccupancyError::NotAnOwner),
            Ownership::Owned => snapshot.resolve_owner(input.owner_person_id).map(Some),
        },
        Occupant::NewOwner => input
            .new_owner_person_id
            .map(Some)
            .ok_or(OccupancyError::PersonNotFound),
    }
}

/// Closes and opens the sessions the plan names and records the transition.
/// The caller has validated the plan, the incoming person and the date.
pub async fn execute_plan(
    tx: &Transaction<'_>,
    snapshot: &UnitSnapshot,
    plan: TransitionPlan,
    incoming: Option<i64>,
    input: &TransitionInput,
) -> Result<TransitionOutcome, OccupancyError> {
    let closed = match (plan.closes, snapshot.session.as_ref()) {
        (Some(_), Some(session)) => Some(
            close_session(
                tx,
                snapshot,
                session,
                input.effective_date,
                input.notes.as_deref(),
            )
            .await?,
        ),
        (Some(_), None) => {
            return Err(OccupancyError::Storage(
                "the unit has no active occupancy session to close".to_string(),
            ))
        }
        _ => None,
    };
    let opened = match (plan.opens, incoming) {
        (Some((role, _)), Some(person_id)) => Some(
            open_session(
                tx,
                snapshot.unit_id,
                person_id,
                role,
                input.effective_date,
                input.notes.as_deref(),
            )
            .await?,
        ),
        (Some(_), None) => return Err(OccupancyError::TenantRequired),
        _ => None,
    };
    record_transition(
        tx,
        snapshot,
        &plan,
        input.effective_date,
        closed.as_ref(),
        opened.as_ref(),
    )
    .await?;
    let (new_occupancy_status, new_tenant_person_id) = match plan.to.occupancy {
        crate::domain::unit_state::Occupancy::Vacant => ("VACANT", None),
        crate::domain::unit_state::Occupancy::OwnerOccupied => ("OWNER_OCCUPIED", None),
        crate::domain::unit_state::Occupancy::TenantOccupied => {
            let pid = opened
                .as_ref()
                .filter(|o| o.role == SessionRole::Tenant)
                .map(|o| o.person_id)
                .or_else(|| {
                    snapshot
                        .session
                        .as_ref()
                        .filter(|s| s.role == SessionRole::Tenant)
                        .map(|s| s.person_id)
                });
            ("TENANT_OCCUPIED", pid)
        }
    };
    tx.execute(
        "UPDATE units SET occupancy_status = $1, tenant_person_id = $2 WHERE id = $3",
        &[
            &new_occupancy_status,
            &new_tenant_person_id,
            &snapshot.unit_id,
        ],
    )
    .await?;
    super::responsible_contact_repository::clear_stale_primary_contact(tx, snapshot.unit_id)
        .await?;
    Ok(TransitionOutcome {
        plan,
        closed,
        opened,
    })
}

/// The departing person's own unpaid liabilities for this unit (STORY-08-10):
/// liabilities charged to them, or tied to their session, or, for rows without
/// a debtor link, those of their role that fell due during their period. A
/// tenant owes operational dues only; capital dues stay with the owner.
pub async fn exit_balance(
    tx: &Transaction<'_>,
    unit_id: i64,
    session: &ActiveSession,
    period_start: NaiveDate,
    until: NaiveDate,
) -> Result<Decimal, OccupancyError> {
    let include_capital = session.role == SessionRole::Owner;
    let role = session.role.as_str();
    let row = tx
        .query_one(
            r#"
            SELECT COALESCE(SUM(principal_amount + delay_penalty - paid_amount), 0.00)
            FROM dues_liabilities
            WHERE unit_id = $1
              AND status NOT IN ('PAID', 'CANCELLED')
              AND ($2 OR expense_type <> 'CAPITAL_DUES')
              AND (liable_person_id = $3
                   OR occupancy_id = $4
                   OR (liable_person_id IS NULL AND occupancy_id IS NULL
                       AND debtor_type = $5 AND due_date >= $6 AND due_date <= $7))
            "#,
            &[
                &unit_id,
                &include_capital,
                &session.person_id,
                &session.occupancy_id,
                &role,
                &period_start,
                &until,
            ],
        )
        .await?;
    Ok(row.get(0))
}

async fn close_session(
    tx: &Transaction<'_>,
    snapshot: &UnitSnapshot,
    session: &ActiveSession,
    end_date: NaiveDate,
    notes: Option<&str>,
) -> Result<ClosedSession, OccupancyError> {
    // An owner owes what accrued to them as owner, including vacant periods.
    // The session never starts after the day it ends.
    let start_date = session.start_date.min(end_date);
    let period_start = match session.role {
        SessionRole::Owner => snapshot
            .owners
            .iter()
            .find(|o| o.person_id == session.person_id)
            .map_or(start_date, |o| o.start_date.min(start_date)),
        SessionRole::Tenant => start_date,
    };
    let balance = exit_balance(tx, snapshot.unit_id, session, period_start, end_date).await?;
    // Closing the session also archives its household members: active members
    // are those of an active session.
    tx.execute(
        r#"
        UPDATE unit_occupancies
        SET is_active = FALSE, start_date = $5, end_date = $2, exit_balance = $3,
            notes = COALESCE($4, notes)
        WHERE id = $1
        "#,
        &[
            &session.occupancy_id,
            &end_date,
            &balance,
            &notes,
            &start_date,
        ],
    )
    .await?;
    Ok(ClosedSession {
        occupancy_id: session.occupancy_id,
        person_id: session.person_id,
        role: session.role,
        start_date,
        end_date,
        exit_balance: balance,
    })
}

async fn open_session(
    tx: &Transaction<'_>,
    unit_id: i64,
    person_id: i64,
    role: SessionRole,
    start_date: NaiveDate,
    notes: Option<&str>,
) -> Result<OpenedSession, OccupancyError> {
    let row = tx
        .query_one(
            r#"
            INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active, exit_balance, notes)
            VALUES ($1, $2, $3, $4, TRUE, 0.00, $5)
            RETURNING id
            "#,
            &[&unit_id, &person_id, &role.as_str(), &start_date, &notes],
        )
        .await?;
    Ok(OpenedSession {
        occupancy_id: row.get(0),
        person_id,
        role,
        start_date,
    })
}

async fn record_transition(
    tx: &Transaction<'_>,
    snapshot: &UnitSnapshot,
    plan: &TransitionPlan,
    effective_date: NaiveDate,
    closed: Option<&ClosedSession>,
    opened: Option<&OpenedSession>,
) -> Result<(), OccupancyError> {
    tx.execute(
        r#"
        INSERT INTO occupancy_transitions (
            site_id, unit_id, command, from_ownership, from_occupancy, to_ownership, to_occupancy,
            effective_date, closed_occupancy_id, opened_occupancy_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        "#,
        &[
            &snapshot.site_id,
            &snapshot.unit_id,
            &plan.command.as_str(),
            &plan.from.ownership.as_str(),
            &plan.from.occupancy.as_str(),
            &plan.to.ownership.as_str(),
            &plan.to.occupancy.as_str(),
            &effective_date,
            &closed.map(|c| c.occupancy_id),
            &opened.map(|o| o.occupancy_id),
        ],
    )
    .await?;
    Ok(())
}

/// Reads the unit's state without changing it (for the state endpoint and UI).
pub async fn read_unit_snapshot(
    tx: &Transaction<'_>,
    site_id: i64,
    unit_id: i64,
) -> Result<UnitSnapshot, OccupancyError> {
    tx.query_opt(
        "SELECT id FROM units WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL",
        &[&unit_id, &site_id],
    )
    .await?
    .ok_or(OccupancyError::UnitNotFound)?;
    read_snapshot(tx, site_id, unit_id, false).await
}
