-- Local-credentials authentication tables. Lives alongside `users`
-- rather than augmenting it so that OIDC users (future) don't carry
-- nullable username/password_hash columns. Both tables hang off
-- users(id) with ON DELETE CASCADE so DELETE /me cleans them up.
--
-- Tokens are stored as a SHA-256 hash of the random 32-byte opaque
-- bearer, *never* the raw token. Compromised DB still can't replay
-- bearers — the hash is one-way. The bearer is 256 bits of entropy
-- (43 base64url chars after stripping padding); brute-force is not a
-- threat at any reasonable wall-clock horizon.

CREATE TABLE IF NOT EXISTS users_local_auth (
    user_id         UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    username        TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE users_local_auth
    DROP CONSTRAINT IF EXISTS users_local_auth_username_lower_check;
ALTER TABLE users_local_auth
    ADD CONSTRAINT users_local_auth_username_lower_check
        CHECK (username = lower(username));

CREATE UNIQUE INDEX IF NOT EXISTS users_local_auth_username_unique
    ON users_local_auth(username);

CREATE TRIGGER users_local_auth_set_updated_at
    BEFORE UPDATE ON users_local_auth
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Opaque bearer tokens. token_hash is `sha256(raw_token)` hex-encoded;
-- raw_token is never persisted. expires_at is the absolute kill date;
-- the sliding-window refresh on each authed request is implemented as
-- an UPDATE … SET expires_at = greatest(expires_at, now() + interval
-- '30 days') in the lookup path.

CREATE TABLE IF NOT EXISTS local_auth_tokens (
    token_hash      TEXT PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS local_auth_tokens_user_idx
    ON local_auth_tokens(user_id);
CREATE INDEX IF NOT EXISTS local_auth_tokens_expires_idx
    ON local_auth_tokens(expires_at);
