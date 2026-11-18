//! STORY-07-10: the caller's site reads and changes its accrual schedule. The site comes from
//! the token, never from the request.

use axum::{extract::State, Json};

use crate::authorization::AuthzContext;
use crate::domain::accrual_schedule::AccrualSchedule;
use crate::error::AppError;
use crate::state::AppState;

pub async fn get_accrual_schedule(
    State(state): State<AppState>,
    ctx: AuthzContext,
) -> Json<AccrualSchedule> {
    let inner = state.inner.read().await;
    Json(
        inner
            .site_accrual_schedules
            .get(&ctx.claims.site_id)
            .copied()
            .unwrap_or_default(),
    )
}

/// Changes the schedule. It applies to periods accrued afterwards; liabilities already
/// accrued keep their due date and grace period.
pub async fn update_accrual_schedule(
    State(state): State<AppState>,
    ctx: AuthzContext,
    Json(schedule): Json<AccrualSchedule>,
) -> Result<Json<AccrualSchedule>, AppError> {
    schedule.validate().map_err(AppError::validation)?;
    let site_id = ctx.claims.site_id.clone();
    if let Some(ref pool) = state.pool {
        crate::db::save_site_accrual_schedule(pool, &site_id, &schedule)
            .await
            .map_err(|e| {
                tracing::error!(error = %e, site_id = %site_id, "Accrual schedule could not be saved");
                AppError::internal("Accrual schedule could not be saved")
            })?;
    }
    state
        .inner
        .write()
        .await
        .site_accrual_schedules
        .insert(site_id, schedule);
    Ok(Json(schedule))
}
