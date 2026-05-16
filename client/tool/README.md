# `client/tool/` — Lint scripts

Standalone bash scripts that enforce architecture tenants. They are pure
`grep` — no pub deps, no Dart analyzer plugin — so they run in
milliseconds and are safe to wire into CI (see
`.github/workflows/pages.yml`, the Flutter job) and to run locally
before pushing.

Each script exits `0` when the tree is clean, `1` when it finds a
violation (offending lines on `stderr`), and `2` on usage errors.

## `lint_no_cross_feature_widget_import.sh`

Enforces **T-23** (`specs/flutter_ui_architecture.md` §8): shared widgets
live at `lib/widgets/<name>.dart` and are imported via
`package:fulfilled/widgets/<name>.dart`. A feature folder may never
import a widget from a *sibling* feature folder.

The script walks every `.dart` file under `client/lib/features/`,
derives the file's owning feature from its path, and flags any line that
references `features/<X>/widgets/` where `<X>` is some *other* feature.
Imports of a feature's own `widgets/` subdir are fine.

Run locally:

```sh
bash client/tool/lint_no_cross_feature_widget_import.sh
```

## `lint_no_hex_outside_tokens.sh`

Enforces **T-01** (`specs/flutter_ui_architecture.md` §8): raw color
hex literals belong in `lib/theme/tokens/` only. Widget code reads from
`context.tokens`.

The script greps `client/lib/**` for both the CSS-style form
(`#RRGGBB`, `#RGB`, `#RRGGBBAA`) and the Dart `Color(0xAARRGGBB)` form,
then strips matches under `lib/theme/tokens/`. Anything that survives
is a violation.

Run locally:

```sh
bash client/tool/lint_no_hex_outside_tokens.sh
```
