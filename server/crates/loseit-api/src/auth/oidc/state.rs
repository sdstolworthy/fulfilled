use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use thiserror::Error;

use crate::config::SecretBytes;

type HmacSha256 = Hmac<Sha256>;

pub const STATE_TTL_SECS: i64 = 600;
pub const STATE_COOKIE_NAME: &str = "loseit_oidc_state";

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct StatePayload {
    pub provider_id: String,
    pub state: String,         // CSRF token (32 random bytes, b64url-no-pad)
    pub pkce_verifier: String, // 43-char b64url-no-pad
    pub nonce: String,         // OIDC nonce (32 random bytes b64url)
    pub next: String,          // validated FE URL
    pub exp: i64,              // epoch seconds
}

#[derive(Debug, Error)]
pub enum StateError {
    #[error("malformed signed payload")]
    Malformed,
    #[error("signature mismatch")]
    BadSignature,
    #[error("state expired")]
    Expired,
}

pub struct StateSigner {
    key: Vec<u8>,
}

impl StateSigner {
    pub fn new(secret: SecretBytes) -> Self {
        Self { key: secret.0 }
    }

    /// Returns `"<b64url(payload_json)>.<b64url(hmac)>"`.
    pub fn sign(&self, payload: &StatePayload) -> String {
        let json = serde_json::to_vec(payload).expect("StatePayload serializes");
        let payload_b64 = URL_SAFE_NO_PAD.encode(&json);
        let mut mac = HmacSha256::new_from_slice(&self.key).expect("HMAC accepts any key length");
        mac.update(payload_b64.as_bytes());
        let tag = mac.finalize().into_bytes();
        let tag_b64 = URL_SAFE_NO_PAD.encode(tag);
        format!("{payload_b64}.{tag_b64}")
    }

    /// Constant-time HMAC verify + JSON parse + `exp > now` check.
    pub fn verify(&self, signed: &str) -> Result<StatePayload, StateError> {
        let (payload_b64, tag_b64) = signed.split_once('.').ok_or(StateError::Malformed)?;
        let supplied_tag = URL_SAFE_NO_PAD
            .decode(tag_b64)
            .map_err(|_| StateError::Malformed)?;
        let mut mac = HmacSha256::new_from_slice(&self.key).expect("HMAC accepts any key length");
        mac.update(payload_b64.as_bytes());
        let expected = mac.finalize().into_bytes();
        if expected.ct_eq(&supplied_tag).unwrap_u8() == 0 {
            return Err(StateError::BadSignature);
        }
        let json = URL_SAFE_NO_PAD
            .decode(payload_b64)
            .map_err(|_| StateError::Malformed)?;
        let payload: StatePayload =
            serde_json::from_slice(&json).map_err(|_| StateError::Malformed)?;
        if payload.exp <= Utc::now().timestamp() {
            return Err(StateError::Expired);
        }
        Ok(payload)
    }
}

pub fn state_payload_with_exp(
    provider_id: impl Into<String>,
    state: impl Into<String>,
    pkce_verifier: impl Into<String>,
    nonce: impl Into<String>,
    next: impl Into<String>,
    now: DateTime<Utc>,
) -> StatePayload {
    StatePayload {
        provider_id: provider_id.into(),
        state: state.into(),
        pkce_verifier: pkce_verifier.into(),
        nonce: nonce.into(),
        next: next.into(),
        exp: (now + Duration::seconds(STATE_TTL_SECS)).timestamp(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::SecretBytes;

    fn signer() -> StateSigner {
        StateSigner::new(SecretBytes(vec![42u8; 32]))
    }
    fn fresh_payload() -> StatePayload {
        state_payload_with_exp("authentik", "s", "v", "n", "/today", Utc::now())
    }

    #[test]
    fn sign_then_verify_round_trips() {
        let s = signer();
        let signed = s.sign(&fresh_payload());
        let got = s.verify(&signed).unwrap();
        assert_eq!(got.provider_id, "authentik");
        assert_eq!(got.next, "/today");
    }

    #[test]
    fn verify_rejects_truncated_signature() {
        let s = signer();
        let signed = s.sign(&fresh_payload());
        // Drop last 4 chars of the HMAC tag
        let bad = &signed[..signed.len() - 4];
        assert!(matches!(
            s.verify(bad),
            Err(StateError::BadSignature) | Err(StateError::Malformed)
        ));
    }

    #[test]
    fn verify_rejects_truncated_payload() {
        let s = signer();
        let signed = s.sign(&fresh_payload());
        let dot = signed.find('.').unwrap();
        let bad = format!("{}{}", &signed[..dot - 2], &signed[dot..]);
        assert!(matches!(
            s.verify(&bad),
            Err(StateError::Malformed) | Err(StateError::BadSignature)
        ));
    }

    #[test]
    fn verify_rejects_expired() {
        let s = signer();
        let mut payload = fresh_payload();
        payload.exp = Utc::now().timestamp() - 1;
        let signed = s.sign(&payload);
        assert!(matches!(s.verify(&signed), Err(StateError::Expired)));
    }

    #[test]
    fn sign_is_url_safe() {
        let s = signer();
        let signed = s.sign(&fresh_payload());
        // No padding, no '+' or '/' from base64
        assert!(!signed.contains('='));
        assert!(!signed.contains('+'));
        assert!(!signed.contains('/'));
    }
}
