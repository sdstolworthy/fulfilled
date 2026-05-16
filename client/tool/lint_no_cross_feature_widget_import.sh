#!/usr/bin/env bash
# lint_no_cross_feature_widget_import.sh
#
# Enforces tenant T-23 (see specs/flutter_ui_architecture.md §8):
#   Feature folders may not import widgets from sibling feature folders.
#   Shared widgets live at `lib/widgets/<name>.dart` and are imported via
#   `package:fulfilled/widgets/<name>.dart`. A feature MAY import its own
#   `features/<self>/widgets/...` subdir.
#
# Strategy:
#   1. Find every `.dart` file under `client/lib/features/`.
#   2. For each file, derive its owning feature `<F>` from the path
#      (`client/lib/features/<F>/...`).
#   3. Grep that file for any import string referencing
#      `features/<X>/widgets/`. If `<X> != <F>`, that's a violation.
#
# Exit codes: 0 = clean, 1 = violations found (printed to stderr), 2 = usage error.

set -u

# Resolve repo paths relative to this script, so the lint runs the same
# whether invoked from `client/` (CI) or anywhere else (local).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FEATURES_DIR="${CLIENT_DIR}/lib/features"

if [ ! -d "${FEATURES_DIR}" ]; then
  echo "lint_no_cross_feature_widget_import: features dir not found: ${FEATURES_DIR}" >&2
  exit 2
fi

violations=0
# Emit each offending line as `<file>:<lineno>: <line>` to stderr.
while IFS= read -r -d '' file; do
  # Owning feature is the path segment immediately after lib/features/.
  rel="${file#${CLIENT_DIR}/lib/features/}"
  own_feature="${rel%%/*}"

  # Grep for any line that mentions `features/<X>/widgets/`. Capture the
  # `<X>` segment and compare to `own_feature`. We deliberately accept
  # both `package:fulfilled/features/<X>/widgets/...` and relative-path
  # forms like `../../<X>/widgets/...`.
  while IFS= read -r hit; do
    [ -z "${hit}" ] && continue
    lineno="${hit%%:*}"
    line="${hit#*:}"
    # Extract the imported feature name from the matched segment. There
    # may be more than one match per line; iterate over them.
    while read -r imported_feature; do
      [ -z "${imported_feature}" ] && continue
      if [ "${imported_feature}" != "${own_feature}" ]; then
        echo "${file}:${lineno}: ${line}" >&2
        echo "    -> imports widget from sibling feature '${imported_feature}' (own feature: '${own_feature}')" >&2
        violations=$((violations + 1))
      fi
    done < <(printf '%s\n' "${line}" | grep -oE 'features/[^/"'"'"']+/widgets/' | sed -E 's#^features/##; s#/widgets/$##')
  done < <(grep -nE "features/[^/\"']+/widgets/" "${file}" 2>/dev/null || true)
done < <(find "${FEATURES_DIR}" -type f -name '*.dart' -print0)

if [ "${violations}" -gt 0 ]; then
  echo "" >&2
  echo "lint_no_cross_feature_widget_import: ${violations} violation(s) — see T-23 in specs/flutter_ui_architecture.md §8." >&2
  exit 1
fi

echo "lint_no_cross_feature_widget_import: ok"
exit 0
