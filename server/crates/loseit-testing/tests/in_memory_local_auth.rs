//! Unit tests for [`InMemoryLocalAuthRepository`] exercised directly,
//! without going through [`AuthService`].

use chrono::{Duration, Utc};
use loseit_core::repo::LocalAuthRepository;
use loseit_testing::InMemoryLocalAuthRepository;
use uuid::Uuid;

// ── helpers ───────────────────────────────────────────────────────────────────

fn fresh() -> InMemoryLocalAuthRepository {
    InMemoryLocalAuthRepository::default()
}

// ── test cases ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn find_by_username_returns_none_for_unknown() {
    let repo = fresh();
    let username = loseit_core::domain::Username::parse("ghost").unwrap();

    let result = repo.find_by_username(&username).await.unwrap();

    assert!(
        result.is_none(),
        "empty repo must return None for any username"
    );
}

#[tokio::test]
async fn upsert_credential_inserts_then_updates() {
    let repo = fresh();
    let user_id = Uuid::new_v4();

    let username_a = loseit_core::domain::Username::parse("a").unwrap();
    let username_b = loseit_core::domain::Username::parse("b").unwrap();
    let hash_v1 = "hash-version-1";
    let hash_v2 = "hash-version-2";

    // Insert under username "a".
    repo.upsert_credential(user_id, &username_a, hash_v1)
        .await
        .unwrap();
    let found = repo.find_by_username(&username_a).await.unwrap();
    assert!(found.is_some(), "credential must exist after first upsert");
    assert_eq!(found.unwrap().password_hash, hash_v1);

    // Update the same user_id with a different username "b" and new hash.
    repo.upsert_credential(user_id, &username_b, hash_v2)
        .await
        .unwrap();

    // "a" must be gone.
    let old = repo.find_by_username(&username_a).await.unwrap();
    assert!(
        old.is_none(),
        "old username must be removed after upsert with new username"
    );

    // "b" must have the new hash.
    let new = repo.find_by_username(&username_b).await.unwrap();
    assert!(new.is_some(), "new username must exist after upsert");
    assert_eq!(new.unwrap().password_hash, hash_v2);
}

#[tokio::test]
async fn touch_token_returns_none_for_unknown() {
    let repo = fresh();
    let new_expires = Utc::now() + Duration::days(30);

    let result = repo.touch_token("no-such-hash", new_expires).await.unwrap();

    assert!(result.is_none(), "unknown token hash must return None");
}

#[tokio::test]
async fn touch_token_refreshes_expires_at() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let token_hash = "test-token-hash";
    let initial_expires = Utc::now() + Duration::seconds(5);
    let new_expires = Utc::now() + Duration::days(30);

    repo.insert_token(token_hash, user_id, initial_expires)
        .await
        .unwrap();

    let returned_user_id = repo.touch_token(token_hash, new_expires).await.unwrap();
    assert_eq!(
        returned_user_id,
        Some(user_id),
        "touch must return the user_id"
    );

    let stored = repo
        .peek_expires_at(token_hash)
        .expect("token must still exist");
    assert_eq!(
        stored, new_expires,
        "expires_at must be updated to new_expires"
    );
}

#[tokio::test]
async fn touch_token_returns_none_after_expiry() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let token_hash = "expired-token-hash";
    // Insert an already-expired token.
    let past = Utc::now() - Duration::seconds(5);

    repo.insert_token(token_hash, user_id, past).await.unwrap();

    let new_expires = Utc::now() + Duration::days(30);
    let result = repo.touch_token(token_hash, new_expires).await.unwrap();

    assert!(
        result.is_none(),
        "expired token must return None from touch_token"
    );
}

#[tokio::test]
async fn delete_token_is_idempotent() {
    let repo = fresh();
    let user_id = Uuid::new_v4();
    let token_hash = "some-token-hash";

    repo.insert_token(token_hash, user_id, Utc::now() + Duration::days(1))
        .await
        .unwrap();

    // First delete.
    repo.delete_token(token_hash).await.unwrap();
    // Second delete on an already-absent key must also succeed.
    repo.delete_token(token_hash).await.unwrap();
}
