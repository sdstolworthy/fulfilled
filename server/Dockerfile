# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the loseit-api binary.
#
#   builder  — compiles the workspace with cached deps
#   runtime  — minimal Debian slim image that runs the binary
#
# Migrations are baked into the image at /app/migrations so the binary
# can apply them on boot via sqlx::migrate!.

# Base image pinned to the channel declared in rust-toolchain.toml. If
# you bump that file, bump this tag too — copying the toolchain file in
# below means rustup will install the newer channel on the fly when the
# tags drift, but matching them up front avoids the extra download.
FROM rust:1.95-slim-bookworm AS builder

WORKDIR /build

# System deps for sqlx + tokio + rustls
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Copy the toolchain file first so rustup respects the pinned channel
# regardless of what the base image ships with.
COPY rust-toolchain.toml ./

# Copy manifests first so dep compilation is cached across source changes.
COPY Cargo.toml ./
COPY crates/loseit-core/Cargo.toml      crates/loseit-core/Cargo.toml
COPY crates/loseit-db/Cargo.toml        crates/loseit-db/Cargo.toml
COPY crates/loseit-api/Cargo.toml       crates/loseit-api/Cargo.toml
COPY crates/loseit-ingest/Cargo.toml    crates/loseit-ingest/Cargo.toml
COPY crates/loseit-testing/Cargo.toml   crates/loseit-testing/Cargo.toml

# Stub out the lib/main entry points so we can compile dependencies
# without the real source. Replaced at the real build step below.
# `loseit-api` and `loseit-ingest` are hybrid bin+lib crates (both
# `main.rs` and `lib.rs` exist in tree), so they need both stubs.
RUN set -eux; \
    for crate in loseit-core loseit-db loseit-api loseit-ingest loseit-testing; do \
        mkdir -p "crates/$crate/src"; \
        echo '' > "crates/$crate/src/lib.rs"; \
    done; \
    echo 'fn main() {}' > crates/loseit-api/src/main.rs; \
    echo 'fn main() {}' > crates/loseit-ingest/src/main.rs

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release -p loseit-api -p loseit-ingest

# Now copy the real source and rebuild.
COPY crates ./crates
COPY migrations ./migrations

# `COPY` preserves host file mtimes, which can be older than the stub
# artifacts cargo just produced — that fools cargo's fingerprint check
# into thinking nothing changed, leaving the stub binary in target/.
# Force-touch every workspace `.rs` file so cargo sees them as newer
# than the stub build.
RUN find crates -name '*.rs' -exec touch {} +

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release -p loseit-api -p loseit-ingest && \
    mkdir -p /out && \
    cp target/release/loseit-api    /out/loseit-api && \
    cp target/release/loseit-ingest /out/loseit-ingest

# ---------------------------------------------------------------------------

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini wget \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 1000 --home /app --shell /usr/sbin/nologin loseit

WORKDIR /app

COPY --from=builder /out/loseit-api    /usr/local/bin/loseit-api
COPY --from=builder /out/loseit-ingest /usr/local/bin/loseit-ingest
COPY migrations /app/migrations

USER loseit
ENV LOSEIT_BIND=0.0.0.0:8080 \
    LOSEIT_RUN_MIGRATIONS=true \
    RUST_LOG=info,tower_http=info,sqlx=warn

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/loseit-api"]
