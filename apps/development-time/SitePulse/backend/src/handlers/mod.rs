//! HTTP route handlers, one module per domain. `app.rs` routes to the
//! re-exported names (`handlers::get_payment_stream`, ...).
//!
//! Every handler that acts on a site takes a `crate::tenancy::TenantScope`
//! and pins its site input through it; handlers whose path carries an object
//! id (capital projects, budgets, receipts) check the object's site. Both are
//! enforced by `scripts/tenant_isolation_lint.py` (gate `tenant-lint`).
//! The imports below are shared with the child modules (`use super::*`).

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::json;

use crate::models::*;
use crate::services::{
    CapitalProjectService, DuesCalculationService, KuveytTurkSandboxService, ReconciliationService,
    SiteBankAccountService, VirtualIbanService,
};
use crate::state::AppState;

mod dashboard;
pub use dashboard::*;

mod reconciliation;
pub use reconciliation::*;

mod dues;
pub use dues::*;

mod payments;
pub use payments::*;

mod system;
pub use system::*;

mod capital;
pub use capital::*;

mod payments_phase2;
pub use payments_phase2::*;

mod payments_phase3;
pub use payments_phase3::*;

mod auth;
pub use auth::*;

mod saas;
pub use saas::*;

mod site_admin;
pub use site_admin::*;

mod registration;
pub use registration::*;

mod residents;
pub use residents::*;

mod openapi;
pub use openapi::*;

pub use crate::services::advance_offset_service::{settle_advances, OffsetScope};
pub use crate::services::ledger_application::apply_advance_payments_offset;
