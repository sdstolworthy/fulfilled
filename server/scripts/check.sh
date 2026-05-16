#!/usr/bin/env bash
# Verification harness — run every check that a future CI job would run.
# Intentionally fails fast: a clean run here is the bar for "ready to merge".
#
# Usage:
#   ./scripts/check.sh             # full pass: fmt, clippy, tests, coverage
#   ./scripts/check.sh --no-cov    # skip coverage (faster local feedback loop)
#   ./scripts/check.sh --quick     # only fmt + clippy + tests, no coverage
#
# This script is *not* CI itself. It is the thing CI calls. Keeping the
# verification surface in one shell file means dev laptops and the future
# CI runner always agree on what "passing" means.

set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_COV=0
case "${1:-}" in
    --no-cov|--quick)
        SKIP_COV=1
        ;;
    --help|-h)
        sed -n '2,12p' "$0"
        exit 0
        ;;
    "")
        ;;
    *)
        echo "unknown flag: $1" >&2
        exit 2
        ;;
esac

section() {
    printf '\n\033[1;36m== %s ==\033[0m\n' "$1"
}

section "cargo fmt --check"
cargo fmt --all -- --check

section "cargo clippy --workspace --all-targets -- -D warnings"
cargo clippy --workspace --all-targets -- -D warnings

section "cargo test --workspace"
cargo test --workspace

if [[ "$SKIP_COV" -eq 0 ]]; then
    section "cargo llvm-cov (workspace coverage)"
    if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
        echo "cargo-llvm-cov not installed; skipping coverage step." >&2
        echo "Install with: cargo install cargo-llvm-cov" >&2
    else
        # Use the same invocation as ./coverage.sh so both produce comparable
        # numbers. Summary only here — HTML report is on demand via coverage.sh.
        cargo llvm-cov --workspace --summary-only
    fi
fi

section "all checks passed"
