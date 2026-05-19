# UI → Persistence Direct-Dependency Audit

## 1. TL;DR

**Zero outstanding violations.** The only UI files that ever touched a
concrete persistence API were `features/login/login_controller.dart`
and `features/profile/widgets/server_url_row.dart`, and both have
**already been fixed in the unstaged working tree** (see `git status`:
`auth_config.dart`, `login_controller.dart`, `server_url_row.dart` all
modified). The fix introduces two new notifiers — `baseUrlProvider`
(pre-existing) and a sibling `lastUsernameProvider` (newly added in
`data/auth_config.dart`) — and rewires both UI sites to read/write
through them.

No other UI files under `features/**` or `widgets/**` import
`package:hive*`, `package:shared_preferences`,
`package:flutter_secure_storage`, `package:path_provider`,
`package:sqflite`, or `dart:io` for persistence purposes. The one
`dart:io` import in a `features/**` file (`login/health_probe.dart`) is
only for the `SocketException` exception type, not for file I/O — that
is **not** a persistence concern and falls under the architect's
allowed-list (network errors are network errors). The codebase is
already at the "no UI→storage direct deps" target state once the
working-tree diff lands.

**Shippable in zero additional PRs once the in-flight commit lands.**

## 2. Violations

None.

For context, the two violations that *did* exist before the in-flight
diff are documented below as a reference for future reviewers / new
contributors who want to recognise the anti-pattern:

### 2a. (Historical, already fixed) `features/login/login_controller.dart` — `loginControllerProvider` initial state

- Pre-fix, lines ~327–344 read `Hive`'s `auth_config` box directly:
  `final box = ref.watch(authConfigBoxProvider); final urlFromHive =
  box.get(AuthConfigKey.baseUrl); ... box.get(AuthConfigKey.lastUsername)`.
- Pre-fix `_persistConfig` also wrote `lastUsername` directly via
  `_ref.read(authConfigBoxProvider).put(AuthConfigKey.lastUsername, username)`.
- **Fix (in working tree):** seed initial state from
  `ref.watch(baseUrlProvider)` and `ref.watch(lastUsernameProvider)`;
  write via the corresponding `.notifier.setX(...)` methods. The
  controller now imports nothing from `package:hive`.

### 2b. (Historical, already fixed) `features/profile/widgets/server_url_row.dart`

- Pre-fix, lines 29–30: `final box = ref.watch(authConfigBoxProvider);
  final url = box.get(AuthConfigKey.baseUrl);`.
- **Fix (in working tree):** `final url = ref.watch(baseUrlProvider);`
  on line 29. The widget no longer references `authConfigBoxProvider`
  or `AuthConfigKey`. Widget tests can now exercise it with a single
  `baseUrlProvider.overrideWith(...)` instead of standing up a
  temp-dir Hive box.

## 3. Legitimate persistence seams

The positive-example list — files / providers that legitimately wrap a
concrete store. Pattern-match against these when adding new persisted
state.

| File | Surface | Wraps |
| --- | --- | --- |
| `/workplace/fulfilled/client/lib/data/auth_config.dart` | `authConfigBoxProvider` (raw box, data-layer only); `baseUrlProvider` + `BaseUrlNotifier`; `lastUsernameProvider` + `LastUsernameNotifier`; `resetAuthConfigForTesting` | `Box<String>` (`auth_config` Hive box) |
| `/workplace/fulfilled/client/lib/data/secure_token_store.dart` | `SecureTokenStore` (read/write/clear); `secureTokenStoreProvider` | `FlutterSecureStorage` |
| `/workplace/fulfilled/client/lib/data/outbox/log_outbox_notifier.dart` | `outboxBoxProvider` (raw box, data-layer only); `LogOutboxNotifier` + `logOutboxProvider` (`OutboxState`) | `Box<String>` (`outbox_log` Hive box) |
| `/workplace/fulfilled/client/lib/data/auth_token.dart` | `AuthTokenNotifier` + `authTokenProvider`; `signOut` clears `secureTokenStoreProvider` and `outboxBoxProvider` from the data layer | `secureTokenStoreProvider`, `outboxBoxProvider` |
| `/workplace/fulfilled/client/lib/providers/api_base_url_provider.dart` | `apiBaseUrlProvider`, `debouncedLoginUrlProvider`, `kIsWebProvider`, `uriBaseProvider`, `kDebugModeProvider` | `baseUrlProvider` (mobile rule 3 — does NOT touch `authConfigBoxProvider` directly) |
| `/workplace/fulfilled/client/lib/main.dart` | Boot — opens Hive, the two `Box<String>` boxes, and constructs `SecureTokenStore`; installs the three concrete-store overrides on `ProviderScope` | `Hive.openBox`, `FlutterSecureStorage` |

Convention: the raw `xBoxProvider` providers *throw* in their default
factory and are only made callable by the `main.dart` overrides. This
is the enforcement seam that keeps UI code from grabbing them — a
widget that tries to `ref.watch(authConfigBoxProvider)` works in the
running app but blows up in any widget test that doesn't override it,
which is exactly the failure mode you want.

## 4. Near misses

- `/workplace/fulfilled/client/lib/features/login/health_probe.dart:18`
  imports `dart:io` — but only for `SocketException` (line 148). Not a
  persistence dependency; the probe constructs a fresh `Dio` per call,
  no files / directories touched. **Not a violation.**
- `/workplace/fulfilled/client/lib/features/login/widgets/server_url_field.dart:36`
  contains the comment `"Hive-pre-seeded URL"`. Comment only — the file
  imports nothing from `package:hive` and reads only from
  `loginControllerProvider`. **Not a violation.**
- `/workplace/fulfilled/client/lib/features/profile/profile_screen.dart:318`
  contains the comment `"clear the token + the outbox Hive box"`. The
  actual code on line 321 calls `ref.read(authTokenProvider.notifier).signOut()`,
  which is the data-layer seam. **Not a violation.**
- `/workplace/fulfilled/client/lib/features/login/login_controller.dart`
  dartdoc + inline comments still mention Hive (lines 15, 245, 277,
  318, 325). These are accurate documentation of where state
  *eventually* lands — they do not import or touch Hive in the code.
  **Not a violation.**
- Many references to `SizedBox` in `routing/app_router.dart` etc. —
  that's the Flutter widget, unrelated to `Box<T>` (Hive). **Not a
  violation.**

## 5. Open questions

- **Should `authConfigBoxProvider` / `outboxBoxProvider` move out of
  the public top-level namespace?** They're declared at file-top with
  `final` so anything that imports `data/auth_config.dart` or
  `data/outbox/log_outbox_notifier.dart` sees them. Today the
  "throws-if-not-overridden" pattern catches misuse at test time, but a
  fence-it-off-by-naming convention (e.g. `_authConfigBoxProvider`
  library-private, exposed only via the notifier providers in the same
  file) would be a stricter compile-time gate. Out of scope for this
  audit but worth a follow-up if the team wants belt-and-braces.
- **Future per-domain Hive boxes** (recent foods, weights, profile
  cache — `auth_token.dart:192` mentions these) should each ship with
  their own `xNotifier` + `xProvider` wrapper from day one, never a
  raw `xBoxProvider` exposed to UI. The `BaseUrlNotifier` /
  `LastUsernameNotifier` pair in `data/auth_config.dart` is the
  reference shape.
- **`resetAuthConfigForTesting`** (added in the in-flight diff at
  `data/auth_config.dart:106`) is a test-only helper that does call
  `ref.read(authConfigBoxProvider).clear()`. It lives in the data
  layer (good) and is gated by name (`*ForTesting`). Worth a
  `@visibleForTesting` annotation if the team wants the analyzer to
  flag production callers; not a violation today.
