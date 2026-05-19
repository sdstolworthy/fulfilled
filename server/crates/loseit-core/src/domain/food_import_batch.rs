use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BatchStatus {
    Running,
    Completed,
    Failed,
}

impl BatchStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "running" => Some(Self::Running),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct FoodImportBatch {
    pub id: Uuid,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub source_url: String,
    pub source_etag: Option<String>,
    pub records_seen: i64,
    pub records_upserted: i64,
    /// Phase 4.3: count of UPSERTs that hit `ON CONFLICT DO UPDATE`
    /// rather than inserting a fresh row. Includes cross-source GTIN
    /// dedup (4.1) and same-source re-imports. New column in 0003.
    pub records_merged: i64,
    pub records_skipped: i64,
    pub status: BatchStatus,
    pub error: Option<String>,
}
