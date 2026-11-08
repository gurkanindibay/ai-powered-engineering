//! Pure domain primitives with no Axum, PostgreSQL, or `AppState` dependency.
//!
//! Each module owns exactly one rule that was previously implemented in more
//! than one place. They are the intended extraction candidates described in
//! `docs/reports/rust-backend-reusability-report.md`; keep them free of I/O,
//! environment access, and global state so they stay independently testable.

pub mod apportionment;
pub mod email;
pub mod fingerprint;
pub mod iban;
pub mod text;

pub use apportionment::{apportion, ApportionmentError};
pub use email::{EmailError, NormalizedEmail};
pub use iban::{IbanError, TrIban};
pub use text::fold_turkish;
