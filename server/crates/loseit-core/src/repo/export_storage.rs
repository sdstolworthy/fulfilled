//! Storage port for export blobs.
//!
//! The export runner (T15) writes the assembled gzip to whatever
//! implementation is plugged in here and stores the returned key on the
//! `export_jobs` row. The trait stays deliberately small (put / signed_url
//! / delete) so that swapping the local-filesystem impl for an S3/GCS
//! presigned-URL backend is mechanical.
//!
//! Signed-URL semantics:
//! * `signed_url` returns an absolute URL good for `ttl` from now.
//! * For the local-FS impl the URL is a path on this server protected by
//!   an HMAC token; for bucket backends it'd be a presigned URL.
//! * Callers do not need to know which kind they're getting.

use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;

use crate::CoreResult;

#[async_trait]
pub trait ExportStorage: Send + Sync + 'static {
    /// Store `body` under a backend-chosen key derived from `key_hint`.
    /// Returns the canonical key the backend actually stored it under
    /// (which may differ from `key_hint` after sanitization). The service
    /// is responsible for persisting the returned key on the job row.
    async fn put(&self, key_hint: &str, body: Bytes, content_type: &str) -> CoreResult<String>;

    /// Issue a time-limited URL that serves the object. For the local-FS
    /// impl this is a `/api/v1/me/export/file/:token` URL with an HMAC
    /// token; for future bucket backends it would be a presigned URL.
    async fn signed_url(&self, key: &str, ttl: Duration) -> CoreResult<String>;

    /// Best-effort delete. Implementations log on error but do not
    /// propagate the failure — the service moves on and an out-of-band
    /// sweep handles orphans.
    async fn delete(&self, key: &str) -> CoreResult<()>;
}
