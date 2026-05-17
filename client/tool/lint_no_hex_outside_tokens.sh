#!/usr/bin/env bash
# lint_no_hex_outside_tokens.sh
#
# Enforces tenant T-01 (see specs/flutter_ui_architecture.md §8):
#   Never write a raw hex in widget code. The only place raw color hex
#   literals are allowed is `lib/theme/tokens/`.
#
# We sweep three forms:
#   1. CSS-style `#RRGGBB` / `#RGB` / `#RRGGBBAA` literals — usually
#      leftover from the HTML mocks pasted into dartdoc comments.
#   2. Dart `Color(0xAARRGGBB)` literals — the canonical Flutter form.
#      Per the architect's hex-literal sweep these belong in
#      `lib/theme/tokens/colors.dart` only.
#   3. `Colors.white` / `Colors.black` (and `.withValues` / `.withOpacity`
#      derivations of either) — Material const references that smuggle
#      raw white/black past the hex sweep. FX-006: the design system's
#      white is `colors.surface`; black is `colors.ink`; alpha-black for
#      shadow/scrim lives in `colors.shadow` / `colors.scrim`. Comments
#      mentioning the constant are tolerated (the inline `# `/`// ` filter
#      drops them); `Colors.transparent` and `Colors.black54` and similar
#      Material-only constants are not flagged.
#
# Exit codes: 0 = clean, 1 = violations found (printed to stderr), 2 = usage error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${CLIENT_DIR}/lib"
TOKENS_DIR="${LIB_DIR}/theme/tokens"

if [ ! -d "${LIB_DIR}" ]; then
  echo "lint_no_hex_outside_tokens: lib dir not found: ${LIB_DIR}" >&2
  exit 2
fi

# `grep -E` patterns:
#   CSS hex: `#` followed by 3-8 hex digits. The pattern is intentionally
#   line-anchored only by the file scan (we don't anchor to start-of-line
#   because the hex can appear anywhere on the line).
CSS_HEX_PATTERN='#[0-9A-Fa-f]{3,8}'
DART_HEX_PATTERN='Color\(0x[0-9A-Fa-f]{6,8}'
# Raw `Colors.white` / `Colors.black` — but match the exact constant only
# so `Colors.white70`, `Colors.black54`, `Colors.transparent` etc. don't
# trip the filter. The `[^A-Za-z0-9_]` lookahead is approximated with a
# trailing-character class because grep -E lacks negative lookahead.
RAW_WHITE_BLACK_PATTERN='Colors\.(white|black)([^A-Za-z0-9_]|$)'

violations=0
matches="$(
  grep -rnE "(${CSS_HEX_PATTERN})|(${DART_HEX_PATTERN})|(${RAW_WHITE_BLACK_PATTERN})" "${LIB_DIR}" 2>/dev/null \
    | grep -v "^${TOKENS_DIR}/" \
    | grep -Ev "^[^:]+:[0-9]+:[[:space:]]*(//|\*|///)" \
    || true
)"

if [ -n "${matches}" ]; then
  echo "${matches}" >&2
  violations="$(printf '%s\n' "${matches}" | wc -l | tr -d ' ')"
  echo "" >&2
  echo "lint_no_hex_outside_tokens: ${violations} violation(s) — see T-01 in specs/flutter_ui_architecture.md §8." >&2
  exit 1
fi

echo "lint_no_hex_outside_tokens: ok"
exit 0
