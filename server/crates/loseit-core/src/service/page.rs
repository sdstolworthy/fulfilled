//! Shared pagination types + the unified validator.
//!
//! Every paged endpoint in the API surfaces the same wire envelope
//! (`{results, total, limit, offset}`) and obeys the same default + cap
//! policy. Centralising the resolver here means the contract is one
//! decision: handlers stay dumb forwarders and services pick up the policy
//! by calling [`resolve_page_params`].

use crate::{CoreError, CoreResult};

/// Default page size when the caller omits `limit` (or passes `Some(0)`).
///
/// Applied uniformly across `/foods/search`, `/foods/mine`, `/log`, and
/// `/weights` so the wire contract is one number rather than per-endpoint
/// trivia.
pub const DEFAULT_PAGE_LIMIT: i64 = 100;

/// Hard cap on page size. Requests above this are silently clamped — the
/// response still echoes the clamped value in `limit` so clients see what
/// they got.
pub const MAX_PAGE_LIMIT: i64 = 500;

/// Generic paginated result. `total` is the full match count (independent
/// of `limit`/`offset`); `results` is the current page.
#[derive(Debug, Clone)]
pub struct Paginated<T> {
    pub results: Vec<T>,
    pub total: i64,
    pub limit: i64,
    pub offset: i64,
}

/// Validated + clamped pagination inputs. Produced by [`resolve_page_params`].
#[derive(Debug, Clone, Copy)]
pub struct PageParams {
    pub limit: i64,
    pub offset: i64,
}

/// Apply the unified pagination policy:
///
/// * `None` or `Some(0)` for limit → [`DEFAULT_PAGE_LIMIT`]
/// * `Some(n)` where `n < 0` → `Validation("limit must be non-negative")`
/// * `Some(n)` where `n > MAX_PAGE_LIMIT` → silently clamp to [`MAX_PAGE_LIMIT`]
/// * `None` for offset → 0
/// * `Some(n)` where `n < 0` → `Validation("offset must be non-negative")`
pub fn resolve_page_params(
    limit: Option<i64>,
    offset: Option<i64>,
) -> CoreResult<PageParams> {
    let limit = match limit {
        None | Some(0) => DEFAULT_PAGE_LIMIT,
        Some(n) if n < 0 => {
            return Err(CoreError::Validation("limit must be non-negative".into()));
        }
        Some(n) => n.min(MAX_PAGE_LIMIT),
    };
    let offset = match offset {
        None => 0,
        Some(n) if n < 0 => {
            return Err(CoreError::Validation("offset must be non-negative".into()));
        }
        Some(n) => n,
    };
    Ok(PageParams { limit, offset })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_page_params_applies_default_when_limit_none() {
        let p = resolve_page_params(None, None).unwrap();
        assert_eq!(p.limit, DEFAULT_PAGE_LIMIT);
        assert_eq!(p.limit, 100);
    }

    #[test]
    fn resolve_page_params_applies_default_when_limit_zero() {
        let p = resolve_page_params(Some(0), None).unwrap();
        assert_eq!(p.limit, DEFAULT_PAGE_LIMIT);
        assert_eq!(p.limit, 100);
    }

    #[test]
    fn resolve_page_params_clamps_limit_above_max() {
        let p = resolve_page_params(Some(10_000), None).unwrap();
        assert_eq!(p.limit, MAX_PAGE_LIMIT);
        assert_eq!(p.limit, 500);
    }

    #[test]
    fn resolve_page_params_passes_limit_within_range() {
        let p = resolve_page_params(Some(250), None).unwrap();
        assert_eq!(p.limit, 250);
    }

    #[test]
    fn resolve_page_params_rejects_negative_limit() {
        let err = resolve_page_params(Some(-1), None).unwrap_err();
        match err {
            CoreError::Validation(msg) => assert_eq!(msg, "limit must be non-negative"),
            other => panic!("expected Validation, got {other:?}"),
        }
    }

    #[test]
    fn resolve_page_params_rejects_negative_offset() {
        let err = resolve_page_params(None, Some(-1)).unwrap_err();
        match err {
            CoreError::Validation(msg) => assert_eq!(msg, "offset must be non-negative"),
            other => panic!("expected Validation, got {other:?}"),
        }
    }

    #[test]
    fn resolve_page_params_defaults_offset_to_zero_when_none() {
        let p = resolve_page_params(None, None).unwrap();
        assert_eq!(p.offset, 0);
    }
}
