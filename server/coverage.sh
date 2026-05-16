#!/usr/bin/env bash
# Generate workspace code coverage using cargo-llvm-cov.
#
# Usage:
#   ./coverage.sh              # HTML report at target/llvm-cov/html/index.html
#   ./coverage.sh --summary    # text summary only (fast — used in CI/check.sh)
#   ./coverage.sh --lcov       # also emit lcov.info (for editor integrations)
#   ./coverage.sh --open       # generate then xdg-open the report
#
# Requires `cargo-llvm-cov`. Install with `cargo install cargo-llvm-cov`.
# We intentionally vendor this as a script rather than a Makefile so the
# invocation is identical on any developer machine.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
    echo "error: cargo-llvm-cov not installed." >&2
    echo "       install it with: cargo install cargo-llvm-cov" >&2
    exit 1
fi

MODE="html"
OPEN=0

for arg in "$@"; do
    case "$arg" in
        --summary)
            MODE="summary"
            ;;
        --lcov)
            MODE="lcov"
            ;;
        --open)
            OPEN=1
            ;;
        --help|-h)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# Always clean previous instrumented artifacts — stale .profraw files
# from a different test order will skew the report.
cargo llvm-cov clean --workspace >/dev/null

case "$MODE" in
    summary)
        cargo llvm-cov --workspace --summary-only
        ;;
    lcov)
        cargo llvm-cov --workspace --lcov --output-path lcov.info
        cargo llvm-cov --workspace --html --no-run
        echo
        echo "lcov:  $(pwd)/lcov.info"
        echo "html:  $(pwd)/target/llvm-cov/html/index.html"
        ;;
    html)
        cargo llvm-cov --workspace --html
        echo
        echo "report: $(pwd)/target/llvm-cov/html/index.html"
        ;;
esac

if [[ "$OPEN" -eq 1 && "$MODE" != "summary" ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$(pwd)/target/llvm-cov/html/index.html" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then
        open "$(pwd)/target/llvm-cov/html/index.html"
    fi
fi
