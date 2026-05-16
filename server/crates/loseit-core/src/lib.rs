//! Domain layer for the LoseIt re-implementation.
//!
//! This crate owns the business types, repository ports (traits), and
//! services that orchestrate them. It deliberately does not depend on any
//! HTTP framework or database driver — those live in `loseit-api` and
//! `loseit-db` respectively, and are injected through the traits defined
//! here.

pub mod auth;
pub mod domain;
pub mod error;
pub mod repo;
pub mod service;

pub use error::{CoreError, CoreResult};
