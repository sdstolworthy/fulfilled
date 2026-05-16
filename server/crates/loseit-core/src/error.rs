use thiserror::Error;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("not found")]
    NotFound,

    #[error("conflict: {0}")]
    Conflict(String),

    #[error("validation: {0}")]
    Validation(String),

    #[error("forbidden")]
    Forbidden,

    #[error("upstream: {0}")]
    Upstream(String),

    #[error(transparent)]
    Internal(#[from] anyhow_compat::Internal),
}

impl CoreError {
    pub fn internal(msg: impl Into<String>) -> Self {
        Self::Internal(anyhow_compat::Internal(msg.into()))
    }
}

// We don't want `loseit-core` to depend on `anyhow` directly, but we still
// want a single `Internal` variant that can carry an opaque error message
// from any backend. This tiny wrapper keeps the API ergonomic without
// pulling anyhow into the domain crate.
mod anyhow_compat {
    use std::fmt;

    #[derive(Debug)]
    pub struct Internal(pub String);

    impl fmt::Display for Internal {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str(&self.0)
        }
    }

    impl std::error::Error for Internal {}
}
