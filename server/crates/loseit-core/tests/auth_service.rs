//! Integration tests for [`AuthService`] exercised against the in-memory
//! repository fakes from `loseit-testing`.  No Postgres required.

use std::sync::Arc;
use std::time::Instant;

use chrono::{Duration, Utc};
use loseit_core::auth::AuthError;
use loseit_core::domain::UserIdentity;
use loseit_core::service::AuthService;
use loseit_testing::{InMemoryLocalAuthRepository, InMemoryUserRepository};
use sha2::{Digest, Sha256};
use uuid::Uuid;

// ── helpers ──────────────────────────────────────────────────────────────────

async fn fresh() -> (
    Arc<InMemoryUserRepository>,
    Arc<InMemoryLocalAuthRepository>,
    Arc<AuthService>,
) {
    let users = Arc::new(InMemoryUserRepository::default());
    let local = Arc::new(InMemoryLocalAuthRepository::default());
    let auth = Arc::new(AuthService::new(users.clone(), local.clone()));
    (users, local, auth)
}

fn alice_identity() -> UserIdentity {
    UserIdentity {
        issuer: "test".into(),
        external_id: "alice".into(),
        email: Some("alice@example.com".into()),
        display_name: Some("Alice".into()),
    }
}

async fn seed_alice(
    users: &Arc<InMemoryUserRepository>,
    auth: &Arc<AuthService>,
) -> Uuid {
    use loseit_core::repo::UserRepository;
    let user = users.create(&alice_identity()).await.unwrap();
    auth.seed_credential(user.id, "alice", "hunter2").await.unwrap();
    user.id
}

fn sha256_hex(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    digest.iter().map(|b| format!("{:02x}", b)).collect()
}

// ── test cases ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn login_returns_token_on_correct_creds() {
    let (users, _local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    let token = auth.login("alice", "hunter2").await.expect("should succeed");

    assert!(!token.raw.is_empty(), "raw token must not be empty");
    // URL-safe base64 of 32 random bytes encodes to 43 chars (no padding).
    assert_eq!(token.raw.len(), 43, "raw token length must be 43");

    let now = Utc::now();
    let lower = now + Duration::days(30) - Duration::seconds(10);
    let upper = now + Duration::days(30) + Duration::seconds(10);
    assert!(
        token.expires_at >= lower && token.expires_at <= upper,
        "expires_at must be ~30 days from now (got {})",
        token.expires_at
    );
}

#[tokio::test]
async fn login_returns_invalid_on_wrong_password() {
    let (users, _local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    let err = auth.login("alice", "wrongpassword").await.expect_err("should fail");

    assert!(matches!(err, AuthError::Invalid), "got {err:?}");
}

#[tokio::test]
async fn login_returns_invalid_on_unknown_username() {
    let (_users, _local, auth) = fresh().await;

    let err = auth.login("ghost", "anything").await.expect_err("should fail");

    assert!(matches!(err, AuthError::Invalid), "got {err:?}");
}

#[tokio::test]
async fn login_returns_invalid_on_malformed_username() {
    let (users, _local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    for bad in ["", "   ", &"a".repeat(65)] {
        let err = auth
            .login(bad, "hunter2")
            .await
            .expect_err("malformed username should fail");
        assert!(
            matches!(err, AuthError::Invalid),
            "expected Invalid for {:?}, got {err:?}",
            bad
        );
    }
}

#[tokio::test]
#[ignore = "timing smoke-test: flaky on heavily loaded CI; run manually"]
async fn login_timing_parity_with_unknown_user() {
    let (users, _local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    const ITERS: usize = 10;

    let mut unknown_total_ns: u128 = 0;
    for _ in 0..ITERS {
        let t = Instant::now();
        let _ = auth.login("ghost", "x").await;
        unknown_total_ns += t.elapsed().as_nanos();
    }

    let mut wrong_total_ns: u128 = 0;
    for _ in 0..ITERS {
        let t = Instant::now();
        let _ = auth.login("alice", "wrong").await;
        wrong_total_ns += t.elapsed().as_nanos();
    }

    let unknown_mean = unknown_total_ns as f64 / ITERS as f64;
    let wrong_mean = wrong_total_ns as f64 / ITERS as f64;
    let ratio = unknown_mean / wrong_mean;

    assert!(
        (0.5..2.0).contains(&ratio),
        "timing ratio (unknown/wrong) out of [0.5, 2.0): ratio={ratio:.2}, \
         unknown_mean={unknown_mean:.0}ns, wrong_mean={wrong_mean:.0}ns"
    );
}

#[tokio::test]
async fn verify_token_returns_user_on_active_token() {
    let (users, _local, auth) = fresh().await;
    let user_id = seed_alice(&users, &auth).await;

    let token = auth.login("alice", "hunter2").await.expect("login");
    let user = auth.verify_token(&token.raw).await.expect("verify");

    assert_eq!(user.id, user_id);
}

#[tokio::test]
async fn verify_token_returns_invalid_on_unknown_token() {
    let (_users, _local, auth) = fresh().await;

    let err = auth.verify_token("not-a-real-token").await.expect_err("should fail");

    assert!(matches!(err, AuthError::Invalid), "got {err:?}");
}

#[tokio::test]
async fn verify_token_returns_invalid_on_expired_token() {
    let (users, local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    let token = auth.login("alice", "hunter2").await.expect("login");
    let token_hash = sha256_hex(&token.raw);
    local.force_expire(&token_hash);

    let err = auth.verify_token(&token.raw).await.expect_err("should fail");
    assert!(matches!(err, AuthError::Invalid), "got {err:?}");
}

#[tokio::test]
async fn verify_token_refreshes_sliding_window() {
    let (users, local, auth) = fresh().await;
    seed_alice(&users, &auth).await;

    let token = auth.login("alice", "hunter2").await.expect("login");
    let token_hash = sha256_hex(&token.raw);

    let before = local
        .peek_expires_at(&token_hash)
        .expect("token should exist after login");

    // Ensure at least 1ms passes so the updated timestamp is strictly greater.
    tokio::time::sleep(tokio::time::Duration::from_millis(2)).await;

    auth.verify_token(&token.raw).await.expect("verify");

    let after = local
        .peek_expires_at(&token_hash)
        .expect("token should still exist after verify");

    assert!(
        after > before,
        "expires_at must advance after verify_token (sliding window); \
         before={before}, after={after}"
    );
}

#[tokio::test]
async fn seed_credential_is_idempotent() {
    let (users, _local, auth) = fresh().await;
    let user_id = seed_alice(&users, &auth).await;

    // Second seed with same args must succeed.
    auth.seed_credential(user_id, "alice", "hunter2").await.expect("second seed");

    // Login still works after the second upsert.
    let token = auth.login("alice", "hunter2").await.expect("login after re-seed");
    assert!(!token.raw.is_empty());
}

#[tokio::test]
async fn seed_credential_rejects_invalid_username() {
    let (users, _local, auth) = fresh().await;
    let user_id = seed_alice(&users, &auth).await;

    auth.seed_credential(user_id, "", "x")
        .await
        .expect_err("empty username must be rejected");

    auth.seed_credential(user_id, &"a".repeat(65), "x")
        .await
        .expect_err("too-long username must be rejected");
}

#[tokio::test]
async fn mint_session_for_returns_opaque_token() {
    let (users, _local, auth) = fresh().await;
    let user_id = seed_alice(&users, &auth).await;
    let tok = auth.mint_session_for(user_id).await.unwrap();
    assert_eq!(tok.user_id, user_id);
    assert!(!tok.raw.is_empty());
    assert!(tok.raw.len() >= 32); // base64url-no-pad of 32 bytes is 43 chars
    // expires_at ~30 days out (allow ±10s drift)
    let now = chrono::Utc::now();
    let drift = (tok.expires_at - (now + chrono::Duration::days(30))).num_seconds().abs();
    assert!(drift < 10, "expires_at drift: {drift}s");
}

#[tokio::test]
async fn mint_session_for_then_verify_round_trips() {
    let (users, _local, auth) = fresh().await;
    let user_id = seed_alice(&users, &auth).await;
    let tok = auth.mint_session_for(user_id).await.unwrap();
    let user = auth.verify_token(&tok.raw).await.unwrap();
    assert_eq!(user.id, user_id);
}

#[tokio::test]
async fn login_still_works_after_extraction() {
    let (users, _local, auth) = fresh().await;
    seed_alice(&users, &auth).await;
    let tok = auth.login("alice", "hunter2").await.unwrap();
    assert!(!tok.raw.is_empty());
}
