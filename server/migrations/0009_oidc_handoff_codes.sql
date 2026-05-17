-- One-time handoff codes: the OIDC callback inserts a code keyed by sha256
-- of the random code; the FE swaps it via POST /auth/oidc/exchange. Code
-- is single-use (DELETE on claim). expires_at is the 60s handoff TTL;
-- token_expires_at is the 30-day opaque bearer kill date returned on
-- exchange.
--
-- ON DELETE CASCADE on users(id) so DELETE /me cleans up.

CREATE TABLE IF NOT EXISTS oidc_handoff_codes (
    code_hash         TEXT PRIMARY KEY,
    user_id           UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    raw_token         TEXT NOT NULL,
    token_expires_at  TIMESTAMPTZ NOT NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS oidc_handoff_codes_expires_idx
    ON oidc_handoff_codes(expires_at);
