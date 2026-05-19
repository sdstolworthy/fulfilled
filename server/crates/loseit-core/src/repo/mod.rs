//! Repository ports. These traits are the seams between the domain and
//! whatever storage we plug in — `loseit-db` provides the Postgres-backed
//! implementations, tests can provide in-memory fakes.

pub mod batch;
pub mod food;
pub mod goal;
pub mod local_auth;
pub mod log;
pub mod oidc_handoff;
pub mod serving;
pub mod user;
pub mod weight;

pub use batch::BatchRepository;
pub use food::{BatchWriteOutcome, FoodDraftWithServings, FoodRepository, UpsertStats};
pub use goal::GoalRepository;
pub use local_auth::LocalAuthRepository;
pub use log::LogRepository;
pub use oidc_handoff::{HandoffClaim, OidcHandoffRepository};
pub use serving::ServingRepository;
pub use user::UserRepository;
pub use weight::WeightRepository;
