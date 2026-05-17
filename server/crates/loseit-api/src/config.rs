use std::env;
use std::net::SocketAddr;

use anyhow::{anyhow, bail, Context, Result};
use base64::prelude::{Engine as _, BASE64_STANDARD as STANDARD};

// ── Public types ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default)]
pub struct AuthConfig {
    /// `Some(_)` when `DEV_AUTH_BYPASS=true`. Refused in production.
    pub dev_bypass: Option<DevBypassConfig>,
    /// `Some(LocalConfig)` when the local-creds path is on. Default: on.
    pub local: Option<LocalConfig>,
    /// One entry per OIDC provider. Empty when `OIDC_PROVIDERS` is unset.
    pub oidc: Vec<OidcProviderConfig>,
}

#[derive(Debug, Clone)]
pub struct DevBypassConfig {
    pub token: String,
    pub issuer: String,
    pub external_id: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
}

/// Marker today — the presence of this variant enables `/auth/login` +
/// the local-auth seed.  Field-bag for future tuning.
#[derive(Debug, Clone)]
pub struct LocalConfig {}

#[derive(Debug, Clone)]
pub struct OidcProviderConfig {
    /// URL-safe slug e.g. `"authentik"`. `[a-z0-9_-]{1,32}` enforced at
    /// load time so it never contains path metacharacters.
    pub id: String,
    pub display_name: String,
    /// Issuer URL (also the `iss` claim we validate on ID tokens).
    pub issuer: String,
    pub client_id: String,
    pub client_secret: String,
    /// Provider JWKS URL. Defaults to `<issuer>/jwks/` (Authentik shape)
    /// when `OIDC_<ID>_JWKS_URL` is unset.
    pub jwks_url: String,
    /// Our callback URL — must match the redirect URI registered in the
    /// provider exactly.
    pub redirect_uri: String,
    pub icon_url: Option<String>,
    pub scopes: Vec<String>,
}

/// Required when `!auth.oidc.is_empty()`. Refuse boot otherwise.
#[derive(Debug, Clone)]
pub struct OidcCommonConfig {
    /// HMAC-SHA256 key (32+ bytes after decode) for the
    /// `loseit_oidc_state` cookie signature.
    pub state_secret: SecretBytes,
    /// Origin we redirect the browser back to after a successful callback.
    /// The `next` query parameter on `/start` is validated against this.
    pub fe_origin: String,
    /// Outgoing HTTP timeout (IdP `/token` + JWKS endpoints). Default 10 s.
    pub http_timeout_secs: u64,
}

/// Newtype for secret bytes — `Debug` never prints the contents.
#[derive(Clone)]
pub struct SecretBytes(pub Vec<u8>);

impl std::fmt::Debug for SecretBytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SecretBytes(<redacted, {} bytes>)", self.0.len())
    }
}

// ── AppConfig ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub bind: SocketAddr,
    pub database_url: String,
    pub run_migrations: bool,
    pub auth: AuthConfig,
    pub oidc_common: Option<OidcCommonConfig>, // Some(_) iff !auth.oidc.is_empty()
    pub env_name: String,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let bind: SocketAddr = env::var("LOSEIT_BIND")
            .unwrap_or_else(|_| "0.0.0.0:8080".to_string())
            .parse()
            .context("LOSEIT_BIND must be a host:port")?;

        let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;

        let run_migrations = env_bool("LOSEIT_RUN_MIGRATIONS", true);
        let env_name = env::var("RUST_ENV").unwrap_or_else(|_| "development".to_string());

        let (auth, oidc_common) = load_auth(&env_name)?;

        Ok(Self {
            bind,
            database_url,
            run_migrations,
            auth,
            oidc_common,
            env_name,
        })
    }
}

// ── load_auth ────────────────────────────────────────────────────────────────

fn load_auth(env_name: &str) -> Result<(AuthConfig, Option<OidcCommonConfig>)> {
    let mut cfg = AuthConfig::default();

    // 1. Dev-bypass — highest precedence.
    if env_bool("DEV_AUTH_BYPASS", false) {
        if env_name == "production" {
            return Err(anyhow!(
                "refusing to start: DEV_AUTH_BYPASS is set with RUST_ENV=production"
            ));
        }
        cfg.dev_bypass = Some(DevBypassConfig {
            token: env::var("DEV_AUTH_TOKEN").unwrap_or_else(|_| "dev-token".into()),
            issuer: env::var("DEV_AUTH_ISSUER").unwrap_or_else(|_| "dev".into()),
            external_id: env::var("DEV_AUTH_USER_ID").unwrap_or_else(|_| "dev-user".into()),
            email: env::var("DEV_AUTH_EMAIL").ok(),
            display_name: env::var("DEV_AUTH_DISPLAY_NAME").ok(),
        });
    }

    // 2. Local-creds — controlled by LOSEIT_AUTH_LOCAL=true (default true).
    if env_bool("LOSEIT_AUTH_LOCAL", true) {
        cfg.local = Some(LocalConfig {});
    }

    // 3. OIDC providers — comma-separated ids in OIDC_PROVIDERS.
    let raw = env::var("OIDC_PROVIDERS").unwrap_or_default();
    for id in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        cfg.oidc.push(load_oidc_provider(id)?);
    }
    // ID shape + uniqueness.
    for p in &cfg.oidc {
        if !id_is_url_safe(&p.id) {
            return Err(anyhow!(
                "OIDC_PROVIDERS id `{}` must match [a-z0-9_-]{{1,32}}",
                p.id
            ));
        }
    }
    if has_duplicate_ids(&cfg.oidc) {
        return Err(anyhow!("OIDC_PROVIDERS contains duplicates"));
    }

    // 4. At least one method must be active.
    if cfg.dev_bypass.is_none() && cfg.local.is_none() && cfg.oidc.is_empty() {
        return Err(anyhow!(
            "no auth method configured \
             (set LOSEIT_AUTH_LOCAL=true, DEV_AUTH_BYPASS=true, or OIDC_PROVIDERS=…)"
        ));
    }

    // 5. OIDC common config — required when OIDC is non-empty.
    let common = if cfg.oidc.is_empty() {
        None
    } else {
        Some(OidcCommonConfig {
            state_secret: load_state_secret()?,
            fe_origin: env::var("LOSEIT_FE_ORIGIN")
                .context("LOSEIT_FE_ORIGIN required when OIDC_PROVIDERS is non-empty")?,
            http_timeout_secs: env::var("LOSEIT_OIDC_HTTP_TIMEOUT_SECS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(10),
        })
    };

    Ok((cfg, common))
}

fn load_oidc_provider(id: &str) -> Result<OidcProviderConfig> {
    let key = |suffix: &str| format!("OIDC_{}_{}", id.to_ascii_uppercase(), suffix);
    let issuer = env::var(key("ISSUER"))
        .with_context(|| format!("{} required", key("ISSUER")))?;
    let client_id = env::var(key("CLIENT_ID"))
        .with_context(|| format!("{} required", key("CLIENT_ID")))?;
    let client_secret = env::var(key("CLIENT_SECRET"))
        .with_context(|| format!("{} required", key("CLIENT_SECRET")))?;
    let redirect_uri = env::var(key("REDIRECT_URI"))
        .with_context(|| format!("{} required", key("REDIRECT_URI")))?;

    let jwks_url = env::var(key("JWKS_URL")).unwrap_or_else(|_| {
        format!(
            "{}jwks/",
            issuer.trim_end_matches('/').to_owned() + "/"
        )
    });
    let display_name = env::var(key("DISPLAY_NAME")).unwrap_or_else(|_| capitalize(id));
    let icon_url = env::var(key("ICON_URL")).ok();
    let scopes = env::var(key("SCOPES"))
        .ok()
        .map(|raw| {
            raw.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_else(|| vec!["openid".into(), "profile".into(), "email".into()]);

    Ok(OidcProviderConfig {
        id: id.to_string(),
        display_name,
        issuer,
        client_id,
        client_secret,
        jwks_url,
        redirect_uri,
        icon_url,
        scopes,
    })
}

fn load_state_secret() -> Result<SecretBytes> {
    let raw = env::var("LOSEIT_AUTH_STATE_SECRET")
        .context("LOSEIT_AUTH_STATE_SECRET required when OIDC providers configured")?;
    // Accept either raw bytes (≥32 chars) or base64-encoded bytes.
    let decoded = STANDARD
        .decode(&raw)
        .unwrap_or_else(|_| raw.as_bytes().to_vec());
    if decoded.len() < 32 {
        bail!("LOSEIT_AUTH_STATE_SECRET must decode to >= 32 bytes");
    }
    Ok(SecretBytes(decoded))
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn id_is_url_safe(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 32
        && id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn has_duplicate_ids(providers: &[OidcProviderConfig]) -> bool {
    let mut seen = std::collections::HashSet::new();
    providers.iter().any(|p| !seen.insert(p.id.as_str()))
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + c.as_str(),
    }
}

pub fn env_bool(key: &str, default: bool) -> bool {
    env::var(key)
        .ok()
        .map(|v| matches!(v.to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(default)
}
