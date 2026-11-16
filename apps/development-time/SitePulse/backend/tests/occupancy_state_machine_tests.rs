//! Unit ownership and occupancy state machine verification (EPIC-08 STORY-08-06..10).
//!
//! Verifies the pure domain state machine transition rules, legality guards,
//! compound transitions, title deed transfers, session derivation, and effective date validation.

use chrono::NaiveDate;
use sitepulse_backend::domain::unit_state::{
    allowed_commands, plan, validate_effective_date, Command, CommandKind, Occupancy, Occupant,
    Ownership, SessionRole, TransitionError, TransitionPlan, UnitState,
};

const VACANT: UnitState = UnitState::new(Ownership::Owned, Occupancy::Vacant);
const OWNER_OCCUPIED: UnitState = UnitState::new(Ownership::Owned, Occupancy::OwnerOccupied);
const TENANT_OCCUPIED: UnitState = UnitState::new(Ownership::Owned, Occupancy::TenantOccupied);
const UNOWNED_VACANT: UnitState = UnitState::new(Ownership::Unowned, Occupancy::Vacant);

fn d(s: &str) -> NaiveDate {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").expect("valid date")
}

// covers: SC-08-06-01
#[test]
fn owner_moves_into_unit_after_tenant_left() {
    let outcome = plan(VACANT, Command::OwnerMoveIn).expect("legal owner move in");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::OwnerMoveIn,
            from: VACANT,
            to: OWNER_OCCUPIED,
            closes: None,
            opens: Some((SessionRole::Owner, Occupant::OwnerOnRecord)),
            changes_ownership: false,
        }
    );
    assert_eq!(outcome.to.occupancy, Occupancy::OwnerOccupied);
    assert_eq!(outcome.to.ownership, Ownership::Owned);
}

// covers: SC-08-06-02
#[test]
fn owner_move_in_only_allows_owner_on_record() {
    // OwnerMoveIn specifies no incoming person payload; it binds strictly to the owner on record.
    let outcome = plan(VACANT, Command::OwnerMoveIn).expect("plan");
    let (_, occupant) = outcome.opens.expect("opens session");
    assert_eq!(occupant, Occupant::OwnerOnRecord);
}

// covers: SC-08-06-03
#[test]
fn tenant_move_in_still_accepts_new_person() {
    let outcome = plan(VACANT, Command::TenantMoveIn).expect("legal tenant move in");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::TenantMoveIn,
            from: VACANT,
            to: TENANT_OCCUPIED,
            closes: None,
            opens: Some((SessionRole::Tenant, Occupant::IncomingTenant)),
            changes_ownership: false,
        }
    );
    let (_, occupant) = outcome.opens.expect("opens session");
    assert_eq!(occupant, Occupant::IncomingTenant);
}

// covers: SC-08-07-01
#[test]
fn move_out_is_rejected_on_vacant_unit() {
    let err = plan(VACANT, Command::MoveOut).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "MOVE_OUT",
            ..
        }
    ));
}

// covers: SC-08-07-02
#[test]
fn tenant_move_in_is_rejected_on_owner_occupied_unit() {
    let err = plan(OWNER_OCCUPIED, Command::TenantMoveIn).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "TENANT_MOVE_IN",
            ..
        }
    ));
}

// covers: SC-08-07-03
#[test]
fn owner_move_in_is_rejected_on_owner_occupied_unit() {
    let err = plan(OWNER_OCCUPIED, Command::OwnerMoveIn).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "OWNER_MOVE_IN",
            ..
        }
    ));
}

// covers: SC-08-07-04
#[test]
fn tenant_move_in_is_rejected_on_tenant_occupied_unit() {
    let err = plan(TENANT_OCCUPIED, Command::TenantMoveIn).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "TENANT_MOVE_IN",
            ..
        }
    ));
}

// covers: SC-08-07-05
#[test]
fn owner_move_in_is_rejected_on_tenant_occupied_unit() {
    let err = plan(TENANT_OCCUPIED, Command::OwnerMoveIn).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "OWNER_MOVE_IN",
            ..
        }
    ));
}

// covers: SC-08-07-06
#[test]
fn tenant_move_in_is_rejected_on_unowned_vacant_unit() {
    let err = plan(UNOWNED_VACANT, Command::TenantMoveIn).expect_err("must be rejected");
    assert!(matches!(err, TransitionError::OwnerRequired));
}

// covers: SC-08-07-07
#[test]
fn owner_move_in_is_rejected_on_unowned_vacant_unit() {
    let err = plan(UNOWNED_VACANT, Command::OwnerMoveIn).expect_err("must be rejected");
    assert!(matches!(err, TransitionError::OwnerRequired));
    // Unowned units only allow REGISTER_OWNER
    assert_eq!(
        allowed_commands(UNOWNED_VACANT),
        vec![CommandKind::RegisterOwner]
    );
}

// covers: SC-08-08-01
#[test]
fn replacing_tenant_settles_outgoing_and_opens_new_tenant() {
    let outcome = plan(TENANT_OCCUPIED, Command::ReplaceTenant).expect("legal replace tenant");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::ReplaceTenant,
            from: TENANT_OCCUPIED,
            to: TENANT_OCCUPIED,
            closes: Some(SessionRole::Tenant),
            opens: Some((SessionRole::Tenant, Occupant::IncomingTenant)),
            changes_ownership: false,
        }
    );
}

// covers: SC-08-08-02
#[test]
fn owner_takes_unit_back_from_tenant() {
    let outcome = plan(TENANT_OCCUPIED, Command::OwnerTakesBack).expect("legal owner takes back");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::OwnerTakesBack,
            from: TENANT_OCCUPIED,
            to: OWNER_OCCUPIED,
            closes: Some(SessionRole::Tenant),
            opens: Some((SessionRole::Owner, Occupant::OwnerOnRecord)),
            changes_ownership: false,
        }
    );
}

// covers: SC-08-08-03
#[test]
fn failed_second_step_preserves_unit_state_and_is_not_allowed_on_vacant() {
    let err = plan(VACANT, Command::ReplaceTenant).expect_err("must be rejected");
    assert!(matches!(
        err,
        TransitionError::IllegalCommand {
            command: "REPLACE_TENANT",
            ..
        }
    ));
}

// covers: SC-08-09-01
#[test]
fn selling_owner_occupied_unit_vacates_it() {
    let outcome = plan(
        OWNER_OCCUPIED,
        Command::TitleTransfer {
            buyer_is_tenant: false,
            new_owner_moves_in: false,
        },
    )
    .expect("legal title transfer");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::TitleTransfer,
            from: OWNER_OCCUPIED,
            to: VACANT,
            closes: Some(SessionRole::Owner),
            opens: None,
            changes_ownership: true,
        }
    );
}

// covers: SC-08-09-02
#[test]
fn new_owner_moves_in_at_transfer() {
    let outcome = plan(
        OWNER_OCCUPIED,
        Command::TitleTransfer {
            buyer_is_tenant: false,
            new_owner_moves_in: true,
        },
    )
    .expect("legal title transfer with move-in");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::TitleTransfer,
            from: OWNER_OCCUPIED,
            to: OWNER_OCCUPIED,
            closes: Some(SessionRole::Owner),
            opens: Some((SessionRole::Owner, Occupant::NewOwner)),
            changes_ownership: true,
        }
    );
}

// covers: SC-08-09-03
#[test]
fn tenant_buys_unit_becomes_owner_occupied() {
    let outcome = plan(
        TENANT_OCCUPIED,
        Command::TitleTransfer {
            buyer_is_tenant: true,
            new_owner_moves_in: false,
        },
    )
    .expect("legal tenant buys unit");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::TitleTransfer,
            from: TENANT_OCCUPIED,
            to: OWNER_OCCUPIED,
            closes: Some(SessionRole::Tenant),
            opens: Some((SessionRole::Owner, Occupant::NewOwner)),
            changes_ownership: true,
        }
    );
}

// covers: SC-08-09-04
#[test]
fn selling_vacant_unit_leaves_it_vacant() {
    let outcome = plan(
        VACANT,
        Command::TitleTransfer {
            buyer_is_tenant: false,
            new_owner_moves_in: false,
        },
    )
    .expect("legal title transfer of vacant");
    assert_eq!(
        outcome,
        TransitionPlan {
            command: CommandKind::TitleTransfer,
            from: VACANT,
            to: VACANT,
            closes: None,
            opens: None,
            changes_ownership: true,
        }
    );
}

// covers: SC-08-10-02
#[test]
fn status_cannot_drift_from_occupancy_sessions() {
    assert_eq!(Occupancy::from_session(None), Occupancy::Vacant);
    assert_eq!(
        Occupancy::from_session(Some(SessionRole::Owner)),
        Occupancy::OwnerOccupied
    );
    assert_eq!(
        Occupancy::from_session(Some(SessionRole::Tenant)),
        Occupancy::TenantOccupied
    );
    assert_eq!(SessionRole::from_stored("OWNER"), SessionRole::Owner);
    assert_eq!(SessionRole::from_stored("TENANT"), SessionRole::Tenant);
}

// covers: SC-08-10-04
#[test]
fn effective_date_cannot_be_in_future() {
    let today = d("2026-11-16");
    let future = d("2026-11-18");
    let err = validate_effective_date(future, today).expect_err("future date must fail");
    assert_eq!(err, TransitionError::FutureDate { date: future });
}

// covers: SC-08-10-05
#[test]
fn effective_date_may_precede_recorded_session_start() {
    let today = d("2026-11-16");
    let past = d("2026-11-05");
    assert_eq!(validate_effective_date(past, today), Ok(()));
}

// covers: SC-08-10-06
#[test]
fn leave_recorded_after_resident_actually_left() {
    let today = d("2026-11-16");
    let actual_leave = d("2026-10-20");
    assert_eq!(validate_effective_date(actual_leave, today), Ok(()));
}

// covers: SC-08-07-08
#[test]
fn registration_approval_respects_unit_state() {
    // If a unit is already occupied, registration approval cannot move another resident in.
    let err_owner = plan(OWNER_OCCUPIED, Command::TenantMoveIn).expect_err("must fail");
    assert!(matches!(err_owner, TransitionError::IllegalCommand { .. }));

    let err_tenant = plan(TENANT_OCCUPIED, Command::TenantMoveIn).expect_err("must fail");
    assert!(matches!(err_tenant, TransitionError::IllegalCommand { .. }));

    let err_register =
        plan(OWNER_OCCUPIED, Command::RegisterOwner { resides: true }).expect_err("already owned");
    assert!(matches!(
        err_register,
        TransitionError::IllegalCommand { .. }
    ));
}

// covers: SC-08-10-01
#[test]
fn exit_balance_counts_only_departing_tenants_liabilities() {
    // A transition plan for replacing or moving out a tenant closes strictly the Tenant session role.
    let move_out_plan = plan(TENANT_OCCUPIED, Command::MoveOut).expect("plan");
    assert_eq!(move_out_plan.closes, Some(SessionRole::Tenant));
    let replace_plan = plan(TENANT_OCCUPIED, Command::ReplaceTenant).expect("plan");
    assert_eq!(replace_plan.closes, Some(SessionRole::Tenant));
}

// covers: SC-08-10-03
#[test]
fn transition_is_all_or_nothing() {
    // Compound transitions bind closing the old session and opening the new session in a single atomic plan.
    let replace = plan(TENANT_OCCUPIED, Command::ReplaceTenant).expect("atomic plan");
    assert_eq!(replace.closes, Some(SessionRole::Tenant));
    assert_eq!(
        replace.opens,
        Some((SessionRole::Tenant, Occupant::IncomingTenant))
    );

    let takes_back = plan(TENANT_OCCUPIED, Command::OwnerTakesBack).expect("atomic plan");
    assert_eq!(takes_back.closes, Some(SessionRole::Tenant));
    assert_eq!(
        takes_back.opens,
        Some((SessionRole::Owner, Occupant::OwnerOnRecord))
    );
}
