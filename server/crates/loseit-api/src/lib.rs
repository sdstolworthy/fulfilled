//! HTTP transport layer for the LoseIt API.
//!
//! This crate is the *only* place that knows about axum. It speaks HTTP at
//! its edges and calls into `loseit_core` services for everything else.
//! The composition root in [`server`] is responsible for instantiating
//! concrete repositories and authenticators and injecting them.

pub mod auth;
pub mod config;
pub mod error;
pub mod routes;
pub mod server;

pub use server::{build_router, build_state, router, AppState};
