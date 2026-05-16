//! Shared wire types for paginated endpoints.
//!
//! Every paged route in this crate (`/foods/search`, `/foods/mine`,
//! `/log`, `/weights`) serialises into [`PaginatedResponse`] and
//! deserialises its pagination query params through [`PageQuery`]. The
//! envelope's field order (`results, total, limit, offset`) is the
//! contract — keep declarations in that order.
//!
//! The `From<Paginated<T>> for PaginatedResponse<R>` impl bridges the
//! service-layer [`loseit_core::service::Paginated`] to the wire DTO via
//! any per-row `From<T>` adapter the route already defines, so handlers
//! only need `Ok(Json(page.into()))`.

use loseit_core::service::Paginated;
use serde::{Deserialize, Serialize};

/// Wire envelope for paginated responses. Field order is the public
/// contract — see module docs.
#[derive(Serialize)]
pub struct PaginatedResponse<T: Serialize> {
    pub results: Vec<T>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

impl<T, R> From<Paginated<T>> for PaginatedResponse<R>
where
    R: Serialize + From<T>,
{
    fn from(p: Paginated<T>) -> Self {
        Self {
            results: p.results.into_iter().map(Into::into).collect(),
            total: p.total,
            limit: p.limit,
            offset: p.offset,
        }
    }
}

/// Shared query-string struct for endpoints whose only pagination inputs
/// are `limit` and `offset`. Routes that add extra params (e.g. `q`,
/// `from`, `to`) define their own struct rather than wrapping this one —
/// flat structs keep axum's `Query` deserialisation predictable.
#[derive(Deserialize)]
pub struct PageQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}
