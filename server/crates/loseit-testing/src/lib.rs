//! Test doubles for the LoseIt domain ports.
//!
//! Each repository trait in [`loseit_core::repo`] has an in-memory
//! counterpart here. They are intentionally simple — a `Mutex`-wrapped
//! `Vec` or `HashMap` — and aimed at exercising service and handler
//! behaviour without needing a Postgres instance.
//!
//! A [`FakeAuthenticator`] is also provided so HTTP-level tests can
//! mint identities deterministically.

mod auth;
mod batches;
mod foods;
mod goals;
mod local_auth;
mod logs;
mod servings;
mod users;
mod weights;

pub use auth::FakeAuthenticator;
pub use batches::InMemoryBatchRepository;
pub use foods::InMemoryFoodRepository;
pub use goals::InMemoryGoalRepository;
pub use local_auth::InMemoryLocalAuthRepository;
pub use logs::InMemoryLogRepository;
pub use servings::InMemoryServingRepository;
pub use users::InMemoryUserRepository;
pub use weights::InMemoryWeightRepository;
