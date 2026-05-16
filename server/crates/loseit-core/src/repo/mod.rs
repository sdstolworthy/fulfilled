//! Repository ports. These traits are the seams between the domain and
//! whatever storage we plug in — `loseit-db` provides the Postgres-backed
//! implementations, tests can provide in-memory fakes.

pub mod batch;
pub mod food;
pub mod goal;
pub mod log;
pub mod serving;
pub mod user;
pub mod weight;

pub use batch::BatchRepository;
pub use food::{FoodRepository, OffFoodUpsert, OffServing, SystemServing, UpsertStats};
pub use goal::GoalRepository;
pub use log::LogRepository;
pub use serving::ServingRepository;
pub use user::UserRepository;
pub use weight::WeightRepository;
