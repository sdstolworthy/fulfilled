use loseit_core::CoreError;
use sqlx::Error as SqlxError;

/// Translate a sqlx error into a [`CoreError`]. The goal is for the API
/// layer (and tests) to never see sqlx types — they reason about domain
/// failures, not driver internals.
pub(crate) fn map_sqlx(err: SqlxError) -> CoreError {
    match err {
        SqlxError::RowNotFound => CoreError::NotFound,
        SqlxError::Database(ref db_err) => {
            if let Some(code) = db_err.code() {
                // 23505 = unique_violation, 23503 = foreign_key_violation,
                // 23514 = check_violation. These read most cleanly as
                // conflicts to the caller.
                if matches!(code.as_ref(), "23505" | "23503" | "23514") {
                    return CoreError::Conflict(db_err.message().to_string());
                }
            }
            CoreError::internal(err.to_string())
        }
        other => CoreError::internal(other.to_string()),
    }
}
