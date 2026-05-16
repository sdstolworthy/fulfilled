use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportStatus {
    Pending,
    Ready,
    Failed,
}

impl ExportStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            ExportStatus::Pending => "pending",
            ExportStatus::Ready => "ready",
            ExportStatus::Failed => "failed",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(ExportStatus::Pending),
            "ready" => Some(ExportStatus::Ready),
            "failed" => Some(ExportStatus::Failed),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ExportJob {
    pub id: Uuid,
    pub user_id: Uuid,
    pub status: ExportStatus,
    pub storage_key: Option<String>,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
}
