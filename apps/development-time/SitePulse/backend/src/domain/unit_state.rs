//! Unit ownership and occupancy state machine (EPIC-08 §3, STORY-08-06..10).
//!
//! A unit carries two independent facts: who holds the title deed (ownership)
//! and who lives in it (occupancy). Move-in and move-out change only occupancy;
//! owner registration and title transfer are the only commands that change
//! ownership. This module decides, without I/O, whether a command is legal in
//! the unit's current state and which occupancy sessions it closes and opens.
//! The database executor (`db::occupancy_repository`) applies the plan.

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

/// Whether the unit has an owner on record.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Ownership {
    Unowned,
    Owned,
}

impl Ownership {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unowned => "UNOWNED",
            Self::Owned => "OWNED",
        }
    }
}

/// Who lives in the unit, as implied by its active occupancy session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Occupancy {
    Vacant,
    OwnerOccupied,
    TenantOccupied,
}

impl Occupancy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Vacant => "VACANT",
            Self::OwnerOccupied => "OWNER_OCCUPIED",
            Self::TenantOccupied => "TENANT_OCCUPIED",
        }
    }

    /// The occupancy implied by the type of the active session (`None`: no session).
    pub fn from_session(session: Option<SessionRole>) -> Self {
        match session {
            None => Self::Vacant,
            Some(SessionRole::Owner) => Self::OwnerOccupied,
            Some(SessionRole::Tenant) => Self::TenantOccupied,
        }
    }

    fn session(self) -> Option<SessionRole> {
        match self {
            Self::Vacant => None,
            Self::OwnerOccupied => Some(SessionRole::Owner),
            Self::TenantOccupied => Some(SessionRole::Tenant),
        }
    }
}

/// The type of an occupancy session (`unit_occupancies.occupancy_type`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SessionRole {
    Owner,
    Tenant,
}

impl SessionRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "OWNER",
            Self::Tenant => "TENANT",
        }
    }

    /// Reads a stored `occupancy_type`; anything that is not `OWNER` is a tenancy.
    pub fn from_stored(value: &str) -> Self {
        if value.eq_ignore_ascii_case("OWNER") {
            Self::Owner
        } else {
            Self::Tenant
        }
    }
}

/// Both dimensions of a unit's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct UnitState {
    pub ownership: Ownership,
    pub occupancy: Occupancy,
}

impl UnitState {
    pub const fn new(ownership: Ownership, occupancy: Occupancy) -> Self {
        Self {
            ownership,
            occupancy,
        }
    }

    /// Human-readable form used in error messages and audit records.
    pub fn label(self) -> String {
        match self.ownership {
            Ownership::Unowned => format!("UNOWNED, {}", self.occupancy.as_str()),
            Ownership::Owned => self.occupancy.as_str().to_string(),
        }
    }
}

/// A command a site manager (or an approval) issues against a unit (§3.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE", tag = "command")]
pub enum Command {
    /// T1: the first owner is registered; `resides` opens an owner session.
    RegisterOwner { resides: bool },
    /// T2: a tenant moves into a vacant unit.
    TenantMoveIn,
    /// T3: the owner on record moves into a vacant unit.
    OwnerMoveIn,
    /// T4 or T5: the current occupant leaves.
    MoveOut,
    /// C1: T4 then T2.
    ReplaceTenant,
    /// C2: T5 then T2.
    OwnerRentsOut,
    /// C3: T4 then T3.
    OwnerTakesBack,
    /// T6: the title deed moves to a new owner.
    TitleTransfer {
        /// The buyer is the unit's current tenant.
        buyer_is_tenant: bool,
        /// The new owner moves in at transfer (owner-occupied units only).
        new_owner_moves_in: bool,
    },
}

/// The occupancy commands, without parameters (for menus and audit records).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum CommandKind {
    RegisterOwner,
    TenantMoveIn,
    OwnerMoveIn,
    MoveOut,
    ReplaceTenant,
    OwnerRentsOut,
    OwnerTakesBack,
    TitleTransfer,
}

impl CommandKind {
    pub const ALL: [Self; 8] = [
        Self::RegisterOwner,
        Self::TenantMoveIn,
        Self::OwnerMoveIn,
        Self::MoveOut,
        Self::ReplaceTenant,
        Self::OwnerRentsOut,
        Self::OwnerTakesBack,
        Self::TitleTransfer,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::RegisterOwner => "REGISTER_OWNER",
            Self::TenantMoveIn => "TENANT_MOVE_IN",
            Self::OwnerMoveIn => "OWNER_MOVE_IN",
            Self::MoveOut => "MOVE_OUT",
            Self::ReplaceTenant => "REPLACE_TENANT",
            Self::OwnerRentsOut => "OWNER_RENTS_OUT",
            Self::OwnerTakesBack => "OWNER_TAKES_BACK",
            Self::TitleTransfer => "TITLE_TRANSFER",
        }
    }

    /// The command with default parameters, used to test legality per state.
    fn probe(self) -> Command {
        match self {
            Self::RegisterOwner => Command::RegisterOwner { resides: false },
            Self::TenantMoveIn => Command::TenantMoveIn,
            Self::OwnerMoveIn => Command::OwnerMoveIn,
            Self::MoveOut => Command::MoveOut,
            Self::ReplaceTenant => Command::ReplaceTenant,
            Self::OwnerRentsOut => Command::OwnerRentsOut,
            Self::OwnerTakesBack => Command::OwnerTakesBack,
            Self::TitleTransfer => Command::TitleTransfer {
                buyer_is_tenant: false,
                new_owner_moves_in: false,
            },
        }
    }
}

impl Command {
    pub fn kind(self) -> CommandKind {
        match self {
            Self::RegisterOwner { .. } => CommandKind::RegisterOwner,
            Self::TenantMoveIn => CommandKind::TenantMoveIn,
            Self::OwnerMoveIn => CommandKind::OwnerMoveIn,
            Self::MoveOut => CommandKind::MoveOut,
            Self::ReplaceTenant => CommandKind::ReplaceTenant,
            Self::OwnerRentsOut => CommandKind::OwnerRentsOut,
            Self::OwnerTakesBack => CommandKind::OwnerTakesBack,
            Self::TitleTransfer { .. } => CommandKind::TitleTransfer,
        }
    }
}

/// Which person a session opened by a plan belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Occupant {
    /// The incoming tenant named in the request.
    IncomingTenant,
    /// An owner on record (T3, C3, T1 with residence).
    OwnerOnRecord,
    /// The buyer of a title transfer.
    NewOwner,
}

/// What a legal command does: the session it closes, the one it opens, the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransitionPlan {
    pub command: CommandKind,
    pub from: UnitState,
    pub to: UnitState,
    /// The active session that is closed with an exit balance.
    pub closes: Option<SessionRole>,
    /// The session that is opened, and for whom.
    pub opens: Option<(SessionRole, Occupant)>,
    /// The command closes the old ownership and opens a new one (T1, T6).
    pub changes_ownership: bool,
}

/// Why a transition was refused. Messages are user-presentable sentences.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TransitionError {
    #[error("{command} is not allowed while the unit is {state}")]
    IllegalCommand {
        command: &'static str,
        state: String,
    },
    #[error(
        "A tenant cannot move into a unit that has no owner on record; register the owner first"
    )]
    OwnerRequired,
    #[error("The new owner can move in at transfer only when the unit is owner-occupied; use owner move-in after the transfer")]
    MoveInAtTransferNotAllowed,
    #[error("The effective date {date} is in the future")]
    FutureDate { date: NaiveDate },
}

fn illegal(command: Command, state: UnitState) -> TransitionError {
    if state.ownership == Ownership::Unowned
        && matches!(
            command,
            Command::TenantMoveIn | Command::OwnerMoveIn | Command::OwnerTakesBack
        )
    {
        return TransitionError::OwnerRequired;
    }
    TransitionError::IllegalCommand {
        command: command.kind().as_str(),
        state: state.label(),
    }
}

/// Decides whether `command` is legal in `state` and what it does (§3.3).
pub fn plan(state: UnitState, command: Command) -> Result<TransitionPlan, TransitionError> {
    use Occupancy::{OwnerOccupied, TenantOccupied, Vacant};
    use Ownership::{Owned, Unowned};

    let owned = |occupancy| UnitState::new(Owned, occupancy);
    let step = |to: UnitState,
                closes: Option<SessionRole>,
                opens: Option<(SessionRole, Occupant)>,
                changes_ownership: bool| TransitionPlan {
        command: command.kind(),
        from: state,
        to,
        closes,
        opens,
        changes_ownership,
    };
    let tenant_in = Some((SessionRole::Tenant, Occupant::IncomingTenant));
    let owner_in = Some((SessionRole::Owner, Occupant::OwnerOnRecord));

    match (state.ownership, state.occupancy, command) {
        (Unowned, Vacant, Command::RegisterOwner { resides }) => Ok(if resides {
            step(owned(OwnerOccupied), None, owner_in, true)
        } else {
            step(owned(Vacant), None, None, true)
        }),
        (Owned, Vacant, Command::TenantMoveIn) => {
            Ok(step(owned(TenantOccupied), None, tenant_in, false))
        }
        (Owned, Vacant, Command::OwnerMoveIn) => {
            Ok(step(owned(OwnerOccupied), None, owner_in, false))
        }
        // A tenant without an owner on record is not allowed (A2) but exists in
        // legacy data; the tenant moving out is the only way out of it.
        (Unowned, TenantOccupied, Command::MoveOut) => Ok(step(
            UnitState::new(Unowned, Vacant),
            Some(SessionRole::Tenant),
            None,
            false,
        )),
        (Owned, occupied @ (TenantOccupied | OwnerOccupied), Command::MoveOut) => {
            Ok(step(owned(Vacant), occupied.session(), None, false))
        }
        (Owned, TenantOccupied, Command::ReplaceTenant) => Ok(step(
            owned(TenantOccupied),
            Some(SessionRole::Tenant),
            tenant_in,
            false,
        )),
        (Owned, OwnerOccupied, Command::OwnerRentsOut) => Ok(step(
            owned(TenantOccupied),
            Some(SessionRole::Owner),
            tenant_in,
            false,
        )),
        (Owned, TenantOccupied, Command::OwnerTakesBack) => Ok(step(
            owned(OwnerOccupied),
            Some(SessionRole::Tenant),
            owner_in,
            false,
        )),
        (
            Owned,
            occupancy,
            Command::TitleTransfer {
                buyer_is_tenant,
                new_owner_moves_in,
            },
        ) => {
            let new_owner_in = Some((SessionRole::Owner, Occupant::NewOwner));
            match occupancy {
                Vacant if new_owner_moves_in => Err(TransitionError::MoveInAtTransferNotAllowed),
                Vacant => Ok(step(owned(Vacant), None, None, true)),
                TenantOccupied if buyer_is_tenant => Ok(step(
                    owned(OwnerOccupied),
                    Some(SessionRole::Tenant),
                    new_owner_in,
                    true,
                )),
                TenantOccupied if new_owner_moves_in => {
                    Err(TransitionError::MoveInAtTransferNotAllowed)
                }
                TenantOccupied => Ok(step(owned(TenantOccupied), None, None, true)),
                OwnerOccupied if new_owner_moves_in => Ok(step(
                    owned(OwnerOccupied),
                    Some(SessionRole::Owner),
                    new_owner_in,
                    true,
                )),
                OwnerOccupied => Ok(step(owned(Vacant), Some(SessionRole::Owner), None, true)),
            }
        }
        _ => Err(illegal(command, state)),
    }
}

/// The commands that are legal in `state`, in menu order (STORY-08-07: the UI
/// shows only these).
pub fn allowed_commands(state: UnitState) -> Vec<CommandKind> {
    CommandKind::ALL
        .into_iter()
        .filter(|kind| plan(state, kind.probe()).is_ok())
        .collect()
}

/// An effective date cannot be in the future. It may precede the recorded start
/// of the session being closed: a resident is often registered after moving in,
/// and the closed session then starts no later than the date it ended.
pub fn validate_effective_date(date: NaiveDate, today: NaiveDate) -> Result<(), TransitionError> {
    if date > today {
        return Err(TransitionError::FutureDate { date });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use Occupancy::{OwnerOccupied, TenantOccupied, Vacant};
    use Ownership::{Owned, Unowned};

    const UNOWNED_VACANT: UnitState = UnitState::new(Unowned, Vacant);
    const VACANT: UnitState = UnitState::new(Owned, Vacant);
    const OWNER_OCC: UnitState = UnitState::new(Owned, OwnerOccupied);
    const TENANT_OCC: UnitState = UnitState::new(Owned, TenantOccupied);

    fn transfer(buyer_is_tenant: bool, new_owner_moves_in: bool) -> Command {
        Command::TitleTransfer {
            buyer_is_tenant,
            new_owner_moves_in,
        }
    }

    fn date(text: &str) -> NaiveDate {
        NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap_or_default()
    }

    #[test]
    fn t1_register_owner_opens_ownership_and_optional_residence() {
        let not_residing = plan(UNOWNED_VACANT, Command::RegisterOwner { resides: false });
        assert_eq!(
            not_residing.map(|p| (p.to, p.opens, p.changes_ownership)),
            Ok((VACANT, None, true))
        );
        let residing = plan(UNOWNED_VACANT, Command::RegisterOwner { resides: true });
        assert_eq!(
            residing.map(|p| (p.to, p.opens)),
            Ok((
                OWNER_OCC,
                Some((SessionRole::Owner, Occupant::OwnerOnRecord))
            ))
        );
    }

    #[test]
    fn t2_tenant_move_in_opens_a_tenant_session_without_ownership_change() {
        let result = plan(VACANT, Command::TenantMoveIn);
        assert_eq!(
            result.map(|p| (p.to, p.closes, p.opens, p.changes_ownership)),
            Ok((
                TENANT_OCC,
                None,
                Some((SessionRole::Tenant, Occupant::IncomingTenant)),
                false
            ))
        );
    }

    #[test]
    fn t3_owner_move_in_uses_the_owner_on_record() {
        let result = plan(VACANT, Command::OwnerMoveIn);
        assert_eq!(
            result.map(|p| (p.to, p.opens, p.changes_ownership)),
            Ok((
                OWNER_OCC,
                Some((SessionRole::Owner, Occupant::OwnerOnRecord)),
                false
            ))
        );
    }

    #[test]
    fn t4_and_t5_move_out_close_the_active_session() {
        assert_eq!(
            plan(TENANT_OCC, Command::MoveOut).map(|p| (p.to, p.closes, p.opens)),
            Ok((VACANT, Some(SessionRole::Tenant), None))
        );
        assert_eq!(
            plan(OWNER_OCC, Command::MoveOut).map(|p| (p.to, p.closes, p.changes_ownership)),
            Ok((VACANT, Some(SessionRole::Owner), false))
        );
    }

    #[test]
    fn compound_transitions_close_then_open() {
        assert_eq!(
            plan(TENANT_OCC, Command::ReplaceTenant).map(|p| (p.to, p.closes, p.opens)),
            Ok((
                TENANT_OCC,
                Some(SessionRole::Tenant),
                Some((SessionRole::Tenant, Occupant::IncomingTenant))
            ))
        );
        assert_eq!(
            plan(OWNER_OCC, Command::OwnerRentsOut).map(|p| (p.to, p.closes, p.opens)),
            Ok((
                TENANT_OCC,
                Some(SessionRole::Owner),
                Some((SessionRole::Tenant, Occupant::IncomingTenant))
            ))
        );
        assert_eq!(
            plan(TENANT_OCC, Command::OwnerTakesBack).map(|p| (p.to, p.closes, p.opens)),
            Ok((
                OWNER_OCC,
                Some(SessionRole::Tenant),
                Some((SessionRole::Owner, Occupant::OwnerOnRecord))
            ))
        );
    }

    #[test]
    fn t6_title_transfer_by_occupancy() {
        let outcome = |state, command| {
            plan(state, command).map(|p| (p.to, p.closes, p.opens, p.changes_ownership))
        };
        assert_eq!(
            outcome(VACANT, transfer(false, false)),
            Ok((VACANT, None, None, true))
        );
        assert_eq!(
            outcome(TENANT_OCC, transfer(false, false)),
            Ok((TENANT_OCC, None, None, true))
        );
        assert_eq!(
            outcome(TENANT_OCC, transfer(true, false)),
            Ok((
                OWNER_OCC,
                Some(SessionRole::Tenant),
                Some((SessionRole::Owner, Occupant::NewOwner)),
                true
            ))
        );
        assert_eq!(
            outcome(OWNER_OCC, transfer(false, false)),
            Ok((VACANT, Some(SessionRole::Owner), None, true))
        );
        assert_eq!(
            outcome(OWNER_OCC, transfer(false, true)),
            Ok((
                OWNER_OCC,
                Some(SessionRole::Owner),
                Some((SessionRole::Owner, Occupant::NewOwner)),
                true
            ))
        );
    }

    #[test]
    fn new_owner_moving_in_at_transfer_needs_an_owner_occupied_unit() {
        assert_eq!(
            plan(VACANT, transfer(false, true)),
            Err(TransitionError::MoveInAtTransferNotAllowed)
        );
        assert_eq!(
            plan(TENANT_OCC, transfer(false, true)),
            Err(TransitionError::MoveInAtTransferNotAllowed)
        );
    }

    #[test]
    fn illegal_commands_from_story_08_07_are_rejected() {
        let cases = [
            (VACANT, Command::MoveOut),
            (OWNER_OCC, Command::TenantMoveIn),
            (OWNER_OCC, Command::OwnerMoveIn),
            (TENANT_OCC, Command::TenantMoveIn),
            (TENANT_OCC, Command::OwnerMoveIn),
            (UNOWNED_VACANT, Command::TenantMoveIn),
            (UNOWNED_VACANT, Command::OwnerMoveIn),
            (UNOWNED_VACANT, Command::MoveOut),
            (UNOWNED_VACANT, transfer(false, false)),
            (VACANT, Command::RegisterOwner { resides: true }),
            (TENANT_OCC, Command::RegisterOwner { resides: false }),
            (VACANT, Command::ReplaceTenant),
            (OWNER_OCC, Command::ReplaceTenant),
            (VACANT, Command::OwnerRentsOut),
            (TENANT_OCC, Command::OwnerRentsOut),
            (VACANT, Command::OwnerTakesBack),
            (OWNER_OCC, Command::OwnerTakesBack),
        ];
        for (state, command) in cases {
            assert!(
                plan(state, command).is_err(),
                "{command:?} must be illegal in {state:?}"
            );
        }
    }

    #[test]
    fn a_tenant_move_in_without_an_owner_names_the_missing_owner() {
        assert_eq!(
            plan(UNOWNED_VACANT, Command::TenantMoveIn),
            Err(TransitionError::OwnerRequired)
        );
        let message = plan(VACANT, Command::MoveOut).err().map(|e| e.to_string());
        assert_eq!(
            message.as_deref(),
            Some("MOVE_OUT is not allowed while the unit is VACANT")
        );
    }

    #[test]
    fn a_legacy_tenant_without_owner_can_only_move_out() {
        let legacy = UnitState::new(Unowned, TenantOccupied);
        assert_eq!(
            plan(legacy, Command::MoveOut).map(|p| (p.to, p.closes)),
            Ok((UNOWNED_VACANT, Some(SessionRole::Tenant)))
        );
        assert_eq!(allowed_commands(legacy), vec![CommandKind::MoveOut]);
    }

    #[test]
    fn allowed_commands_follow_the_transition_table() {
        use CommandKind as K;
        assert_eq!(allowed_commands(UNOWNED_VACANT), vec![K::RegisterOwner]);
        assert_eq!(
            allowed_commands(VACANT),
            vec![K::TenantMoveIn, K::OwnerMoveIn, K::TitleTransfer]
        );
        assert_eq!(
            allowed_commands(OWNER_OCC),
            vec![K::MoveOut, K::OwnerRentsOut, K::TitleTransfer]
        );
        assert_eq!(
            allowed_commands(TENANT_OCC),
            vec![
                K::MoveOut,
                K::ReplaceTenant,
                K::OwnerTakesBack,
                K::TitleTransfer
            ]
        );
    }

    #[test]
    fn occupancy_is_derived_from_the_active_session() {
        assert_eq!(Occupancy::from_session(None), Vacant);
        assert_eq!(
            Occupancy::from_session(Some(SessionRole::Owner)),
            OwnerOccupied
        );
        assert_eq!(
            Occupancy::from_session(Some(SessionRole::Tenant)),
            TenantOccupied
        );
        assert_eq!(SessionRole::from_stored("owner"), SessionRole::Owner);
        assert_eq!(SessionRole::from_stored("TENANT"), SessionRole::Tenant);
    }

    #[test]
    fn effective_date_cannot_be_in_the_future_but_may_precede_the_session() {
        let today = date("2026-11-14");
        assert_eq!(validate_effective_date(today, today), Ok(()));
        assert_eq!(validate_effective_date(date("2026-02-15"), today), Ok(()));
        assert_eq!(
            validate_effective_date(date("2026-11-15"), today),
            Err(TransitionError::FutureDate {
                date: date("2026-11-15")
            })
        );
    }
}
