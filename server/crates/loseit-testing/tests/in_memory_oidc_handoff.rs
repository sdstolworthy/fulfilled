//! Unit tests for [`InMemoryOidcHandoffRepository`] exercised directly,
//! without going through a handler.

use chrono::{Duration, Utc};
use loseit_core::repo::OidcHandoffRepository;
use loseit_testing::InMemoryOidcHandoffRepository;
use uuid::Uuid;

// ── helpers ───────────────────────────────────────────────────────────────────

fn fresh() -> InMemoryOidcHandoffRepository {
    InMemoryOidcHandoffRepository::default()
}

// ── test cases ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn insert_then_claim_returns_token() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let code_hash = "abc123hash";
    let raw_token = "my-raw-opaque-token";
    let token_expires_at = Utc::now() + Duration::seconds(3600);
    let expires_at = Utc::now() + Duration::seconds(60);

    repo.insert(code_hash, user_id, raw_token, token_expires_at, expires_at)
        .await
        .unwrap();

    let claim = repo.claim(code_hash).await.unwrap();

    assert!(
        claim.is_some(),
        "claim must return Some for a non-expired row"
    );
    let claim = claim.unwrap();
    assert_eq!(claim.user_id, user_id);
    assert_eq!(claim.raw_token, raw_token);
    assert_eq!(
        claim.token_expires_at.timestamp(),
        token_expires_at.timestamp(),
        "token_expires_at must round-trip exactly"
    );
}

#[tokio::test]
async fn claim_deletes_row() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let code_hash = "once-only-hash";
    let token_expires_at = Utc::now() + Duration::seconds(3600);
    let expires_at = Utc::now() + Duration::seconds(60);

    repo.insert(code_hash, user_id, "tok", token_expires_at, expires_at)
        .await
        .unwrap();

    let first = repo.claim(code_hash).await.unwrap();
    assert!(first.is_some(), "first claim must succeed");

    let second = repo.claim(code_hash).await.unwrap();
    assert!(
        second.is_none(),
        "second claim must return None — row was deleted"
    );
}

#[tokio::test]
async fn claim_filters_expired() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let code_hash = "expired-hash";
    let token_expires_at = Utc::now() + Duration::seconds(3600);
    // expires_at is in the past
    let expires_at = Utc::now() - Duration::seconds(1);

    repo.insert(code_hash, user_id, "tok", token_expires_at, expires_at)
        .await
        .unwrap();

    let claim = repo.claim(code_hash).await.unwrap();
    assert!(
        claim.is_none(),
        "claim must return None for an expired handoff code"
    );
}

#[tokio::test]
async fn claim_for_missing_code_returns_none() {
    let repo = fresh();

    let claim = repo.claim("nonexistent-hash").await.unwrap();
    assert!(
        claim.is_none(),
        "claim on a fresh repo must return None for any code"
    );
}
