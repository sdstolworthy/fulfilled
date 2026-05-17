//! Postgres-backed implementations of the [`loseit_core`] repository
//! ports. Nothing in here is exposed to the API layer beyond the concrete
//! repository types and a thin pool-construction helper — the API layer
//! consumes them through the trait objects defined in core.
//!
//! NOTE: SQL strings in this crate must NOT contain inline `--` comments
//! when built with Rust `\` line-continuation. The comment marker causes
//! Postgres to treat everything from `--` to end-of-input as a comment,
//! causing syntax errors. Use SQL `/* ... */` block-comments instead, or
//! split SQL across `"..."` boundaries joined with `\n`.

mod batch_repo;
mod error;
mod food_repo;
mod goal_repo;
mod local_auth_repo;
mod log_repo;
mod oidc_handoff_repo;
mod pool;
mod serving_repo;
mod user_repo;
mod weight_repo;

pub use batch_repo::PgBatchRepository;
pub use food_repo::PgFoodRepository;
pub use goal_repo::PgGoalRepository;
pub use local_auth_repo::PgLocalAuthRepository;
pub use log_repo::PgLogRepository;
pub use oidc_handoff_repo::PgOidcHandoffRepository;
pub use pool::{build_pool, run_migrations, PoolConfig};
pub use serving_repo::PgServingRepository;
pub use user_repo::PgUserRepository;
pub use weight_repo::PgWeightRepository;

pub use sqlx::PgPool;
