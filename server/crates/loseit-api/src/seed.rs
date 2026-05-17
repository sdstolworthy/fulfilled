use std::sync::Arc;

use anyhow::{Context, Result};
use loseit_core::domain::UserIdentity;
use loseit_core::repo::{LocalAuthRepository, UserRepository};
use loseit_core::service::{AuthService, UserService};
use loseit_db::{PgLocalAuthRepository, PgPool, PgUserRepository};

/// Idempotent seed of the dev/dev local-auth credential, bound to the
/// existing dev-bypass identity (`issuer="dev"`, `external_id="dev-user"`).
/// Re-running on an already-seeded database is a no-op apart from
/// updated_at ticking.
pub async fn seed_dev_local_auth(pool: &PgPool) -> Result<()> {
    let users: Arc<dyn UserRepository> = Arc::new(PgUserRepository::new(pool.clone()));
    let local: Arc<dyn LocalAuthRepository> = Arc::new(PgLocalAuthRepository::new(pool.clone()));
    let user_service = UserService::new(users.clone());
    let auth_service = AuthService::new(users, local);

    let identity = UserIdentity {
        issuer: "dev".into(),
        external_id: "dev-user".into(),
        email: Some("dev@example.com".into()),
        display_name: Some("Dev User".into()),
    };
    let user = user_service
        .ensure_user(&identity)
        .await
        .context("seed: ensure dev user")?;
    auth_service
        .seed_credential(user.id, "dev", "dev")
        .await
        .context("seed: dev credential")?;
    Ok(())
}
