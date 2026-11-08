//! Connection boundary for security operations. Absence means explicit memory mode;
//! acquisition failures remain errors and never fall back to cached authority.

use crate::{authorization::SecurityError, state::AppState};

/// Acquire an attributed security connection, or select the memory adapter.
///
/// # Errors
/// Returns unavailable when configured persistent storage cannot be reached.
pub async fn security_connection(
    state: &AppState,
) -> Result<Option<deadpool_postgres::Object>, SecurityError> {
    match state.pool.as_ref() {
        Some(database) => database
            .get()
            .await
            .map(Some)
            .map_err(|_| SecurityError::Unavailable),
        None => Ok(None),
    }
}
