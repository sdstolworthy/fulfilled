# Fulfilled — Flutter client

The v1 web/mobile client for the LoseIt API. One codebase, three breakpoints
(compact / medium / expanded), Riverpod for state, `go_router` for routing,
Hive for the mobile log outbox, Dio for HTTP.

This directory is the **foundation only** — every screen renders as a
`PlaceholderScreen` until a screen agent replaces its route binding under
`lib/features/<screen>/`.

## Source of truth

These three documents are the contract. When the code disagrees with them,
the documents win.

- `../specs/flutter_ui_architecture.md` — tokens, navigation, state
  management, mobile/web affordances, and the 22 tenants (T-01 … T-22).
- `../specs/pm_decisions_flutter_ui.md` — PM rulings applied 2026-05-15:
  Display Units Principle, outbox scope, Trends removal, Appearance
  removal, onboarding "I have an account" removal.
- `../specs/openapi.yaml` — wire shape. Repositories convert at the seam;
  presentation models do not see the raw wire DTOs.

The mocks in `../specs/ui_mocks/` are the visual contract; the
architecture doc supersedes them on any non-token detail.

## First-time setup

```sh
# 1. Generate platform folders. We don't commit them — they're large,
# noisy, and trivially regenerated. Run this once after cloning.
flutter create . --platforms=web,ios,android

# 2. Pull packages.
flutter pub get

# 3. Boot the placeholder shell.
flutter run -d chrome
```

### Native camera-permission config (barcode scanner)

The `/foods/scan` route uses `mobile_scanner` to drive the device camera.
Both iOS and Android require an explicit permission declaration in the
generated native scaffold. Because `ios/`, `android/`, and `web/` are
gitignored (see `.gitignore`) we cannot commit the snippets here — add
them locally after running `flutter create` and before launching on a
device.

**iOS — `ios/Runner/Info.plist`** (inside the top-level `<dict>`):

```xml
<key>NSCameraUsageDescription</key>
<string>Scan barcodes on packaged foods to log them quickly.</string>
```

Apple rejects builds that request camera access without a concrete,
human-readable description string. See `specs/dev_tickets_barcode.md`
SC-001 and `specs/pm_barcode.md` §6 ("Permission first-run + recovery")
for the copy contract.

**Android — `android/app/src/main/AndroidManifest.xml`** (inside the
top-level `<manifest>` element, alongside any other `<uses-permission>`
entries):

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

The `mobile_scanner` plugin's manifest merger usually adds this entry
on its own; we add it explicitly so the dependency is auditable.

CI builds web-only, so the missing native config does not block deploy.
The barcode-scanner opener (`lib/features/scan/openers.dart`)
short-circuits on `kIsWeb`, which makes web bundles tree-shake the
scanner widget tree. The contract above is the runtime contract for
device builds.

> No `build_runner` step is required. The foundation is intentionally
> codegen-free: providers are hand-written and `OutboxEntry` is a plain
> value class. When the analyzer / freezed / riverpod_generator ecosystem
> finishes its current major-version churn we can reintroduce `@riverpod`
> codegen without affecting screen code.

The shell launches at `/today` and lets you navigate the four (compact) or
five (expanded) tabs. Every leaf is a `PlaceholderScreen` — that's the
deliverable until screen agents replace them.

### Dev environment

| Knob              | Compile-time define                            | Default                            |
|-------------------|------------------------------------------------|------------------------------------|
| API base URL      | `--dart-define=API_BASE_URL=...`               | `http://localhost:8080/api/v1`     |
| Dev bearer token  | `--dart-define=DEV_AUTH_TOKEN=...`             | `dev-bypass` in debug, `null` else |

Example for hitting a non-local backend in the browser:

```sh
flutter run -d chrome \
  --dart-define=API_BASE_URL=https://staging.loseit.invalid/api/v1 \
  --dart-define=DEV_AUTH_TOKEN=...
```

## Bundling Inter

`pubspec.yaml` leaves the Inter font block commented out. To bundle:

1. Drop `Inter-Regular.ttf` / `Inter-Medium.ttf` / `Inter-SemiBold.ttf` /
   `Inter-Bold.ttf` into `assets/fonts/Inter/`.
2. Uncomment the `fonts:` block in `pubspec.yaml`.
3. Run `flutter pub get`.

Until then, Flutter falls back through the platform default. The fallback
is acceptable for the placeholder shell — not for screen-handoff review.

## Screen-agent contract

Each user-facing screen has exactly one agent. Read this before opening a PR.

1. **Replace one route binding.** Locate the `PlaceholderScreen` for your
   screen in `lib/routing/app_router.dart`. Point it at your real widget
   under `lib/features/<screen>/`. Do not register new top-level routes
   without coordinating — the route table is foundation territory.
2. **Follow the tenants T-01 … T-22.** Reviewers cite by ID. Tokens via
   `context.tokens`, numbers via `NumberText` (tabular figures), macro
   colors data-only, accent for primary actions only, units rendered via
   `lib/domain/units/`. The full list is `specs/flutter_ui_architecture.md`
   §8.
3. **Do not modify foundation modules** without an architecture-level
   discussion:
   - `lib/theme/` (tokens, theme data, context extensions)
   - `lib/routing/` (router config, route constants)
   - `lib/form_factor/` (breakpoints, enum)
   - `lib/domain/units/` (Display Units Principle — T-21)
   - `lib/widgets/app_scaffold.dart` (the responsive shell)
4. **Use the right layer.**
   - Screens consume Riverpod providers; they never call `Dio`.
   - View models transform DTOs into presentation models.
   - Repositories own the API surface and cache policy.
   - DTOs live in `lib/data/dtos/` (currently empty; see note in that
     directory).
5. **Mobile `POST /log` writes go through the outbox** (T-22). Wire your
   repository's log POST through `logOutboxProvider`, gating the outbox
   path on `FormFactor.isCompact`. Other writes (weights, goals, custom
   food, profile edits) stay online-only on every form factor.
6. **Decimals stay `Decimal` until the leaf.** Never `double.parse` a wire
   value. Format with `lib/domain/units/`.

## Layout (matches `specs/flutter_ui_architecture.md` appendix)

```
lib/
  main.dart                       Entry: Hive init, ProviderScope, runApp.
  app.dart                        MaterialApp.router + theme + router.
  theme/                          T-01 source of truth.
    tokens/{colors,text,space,radius}.dart
    tokens.dart                   AppTokens ThemeExtension.
    theme_data.dart
    context_extensions.dart       context.tokens / colors / text / ...
  form_factor/                    Three breakpoints, one enum.
  routing/
    routes.dart                   Name + path constants (no Trends).
    app_router.dart               go_router config with ShellRoute.
  data/
    api_client.dart               Dio + auth interceptor.
    auth_token.dart               authTokenProvider.
    connectivity.dart             connectivityProvider.
    outbox/                       Mobile-only POST /log queue. T-22.
      outbox_entry.dart           Freezed model.
      log_outbox_notifier.dart    Enqueue / drain / retry / discard.
    dtos/                         (empty — generator config TBD)
  domain/
    units/                        Display Units Principle. T-21.
      units.dart                  re-exports
      sodium.dart                 gramsToMilligrams, formatSodiumMg
      weight.dart                 formatWeightKg (lb deferred)
      energy.dart                 formatKcal
      macros.dart                 formatGrams
  widgets/
    app_scaffold.dart             Responsive shell.
    placeholder_screen.dart       Stub renderer (screen agents replace).
  features/                       One folder per screen. Empty for now.
test/
  domain/units/                   Real unit tests.
  widget/                         AppScaffold golden stubs (TODO(golden)).
```

## Tests

```sh
flutter test
```

`test/domain/units/` covers sodium, weight, energy, and macros formatters.
`test/widget/app_scaffold_test.dart` smoke-tests the three breakpoints;
goldens are stubbed (`TODO(golden)`) — the first agent who runs them in CI
generates the images with `flutter test --update-goldens`.

## Where this differs from the architecture doc

- The doc names `lib/domain/decimal_format.dart`. The Display Units
  Principle supersedes it for now — formatting lives in
  `lib/domain/units/` and the per-quantity files are the API. A future
  `decimal_format.dart` for non-unit cases (percentages, BMI) can sit
  alongside.
- The doc lists a `components inventory` of 30+ widgets. The foundation
  ships only `AppScaffold`, `PlaceholderScreen`, and the units module —
  screen agents build the rest as their screens need them, in the
  feature folders.
