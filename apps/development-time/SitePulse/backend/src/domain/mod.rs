//! Pure domain primitives with no Axum, PostgreSQL, or `AppState` dependency.
//!
//! Each module owns exactly one rule that was previously implemented in more
//! than one place. They are the intended extraction candidates described in
//! `docs/reusability/rust-backend-reusability-report.md`; keep them free of I/O,
//! environment access, and global state so they stay independently testable.

pub mod accrual_schedule;
pub mod apportionment;
pub mod billing_period;
pub mod email;
pub mod fingerprint;
pub mod household_relationship;
pub mod iban;
pub mod text;

pub use apportionment::{apportion, ApportionmentError};
pub use email::{EmailError, NormalizedEmail};
pub use iban::{IbanError, TrIban};
pub use text::fold_turkish;
// SPEC-009 (payments phase 3) rules.
pub mod assembly_vote;
pub mod collection_metrics;
pub mod double_entry;
pub mod dunning;
pub mod heat_share;
pub mod installments;
pub mod joint_liability;
pub mod kvkk;
pub mod limitation;
pub mod occupancy_proration;
pub mod payer_match;
pub mod sale_clearance;
pub mod tax_id;
// EPIC-08 unit ownership & occupancy state machine.
pub mod unit_state;
