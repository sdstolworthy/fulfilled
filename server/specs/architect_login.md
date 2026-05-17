# Architect — Self-Hosted Login

Implementation contract for `specs/pm_login.md`. The PM has ruled scope,
direction, competitor framing, user stories, the mobile-vs-web split,
the on-submit validation strategy, the `auth_config` persistence model,
and the §9 anti-recommendations. This doc translates that into
file-level seams, function signatures, provider shapes, the router
redirect rule, and acceptance criteria the technical program manager
can carve into developer tickets without re-asking.

The prior contracts are the tiebreakers above this one:
`specs/flutter_ui_architecture.md` (the 24 tenants — especially T-04
accent only on primary actions, T-08 skeletons not spinners, T-11
inline errors, T-14 routes-vs-sheets, T-15 form-factor-at-root, T-19
no new chart deps),
`specs/architect_ux_pack.md` and
`specs/architect_log_edit_and_units.md` (the prose template — and the
per-axis provider seam pattern this doc reuses for
`apiBaseUrlProvider`), and `specs/pm_login.md` itself. Where this doc
names a behaviour and any prior doc disagrees, the prior doc wins.

I read every file PM inventoried in §1 of their direction doc:
`client/lib/data/api_client.dart` (the compile-time `--dart-define`
seam this doc swaps for a runtime read), `client/lib/data/auth_token.dart`
(the `AuthTokenNotifier` that grows
`signInWithCredentials`), `client/lib/main.dart` (the Hive bootstrap
that opens the new `auth_config` box), `client/lib/routing/routes.dart`
and `client/lib/routing/app_router.dart` (the new `/login` route + the
redirect rule), and `client/lib/features/onboarding/widgets/step_1_welcome.dart`
(the "I already have an account" link the PM reversed Risk 2 on). I
re-read `specs/openapi.yaml` lines 1–100 (servers/security block) and
67–89 (`/health`) and confirm the PM's reading: **`/health` exists and
sits under the `/api/v1` prefix** (line 14 — *"All paths are served
under the `/api/v1` prefix"* applies to it as much as the rest), and
**`/auth/login` does not exist on the spec**. BE-008 (canonical login)
and BE-009 (`/health` clarification + CORS) are the two backend
tickets PM flagged and §11 of this doc adds them to
`backend_tickets_ledger.md`. The plan compiles in my head; I'd expect
the tickets that come out of this to compile on the dev agent's
machine without surprise. Two open questions for the PMgr live in
§10; one of them (whether the dev-bypass token short-circuits the
redirect on debug builds) actually changes the file diff and I make
the call directly in §7.

---

## 1. Architectural overview

**Shape of the change.** Two architectural pieces plus one routing
piece, sitting on top of one model decision PM made for us (no
biometric, no multi-account, no refresh tokens).

**Piece (a) — the runtime API base URL seam.** Today
`apiClientProvider` reads `String.fromEnvironment('API_BASE_URL')`
at compile time and threads it into Dio's `BaseOptions.baseUrl`. The
PM's *"the back-end URL is dynamic, per client for mobile
applications"* makes that compile-time read the wrong shape: each
self-hosted customer's URL is unknown at build time. The fix is a
new `apiBaseUrlProvider` (returns `String?`) that reads from a
`auth_config` Hive box on mobile and from `Uri.base.origin + '/api/v1'`
on web. `apiClientProvider` `ref.watch`es it; when it changes (sign-in
on a fresh device, server switch on re-login) the Dio instance
rebuilds with the new `baseUrl`. The `--dart-define=API_BASE_URL`
mechanism survives **only as a dev override** for `flutter run -d
chrome` against `localhost`, behind a `kDebugMode` gate at the
provider root.

**Piece (b) — the `/login` screen.** A new route at `/login`,
outside the `ShellRoute`, registered in `app_router.dart` alongside
`/onboarding/:step` and `/foods/new`. The screen renders three fields
on mobile (Server URL → Username → Password) and two fields on web
(Username → Password — the URL field is hidden because `Uri.base` is
canonical). Submission validates the URL via `GET <base>/health` with
an 8 s timeout, posts credentials to `POST /auth/login`, handles four
error classes inline per T-11, persists `base_url` + `last_username`
to the Hive box on success, calls `authTokenProvider.signIn(token)`,
and routes to `/today` per T-24 Case 2.

**Piece (c) — the router redirect.** `go_router`'s `redirect` callback
gains one rule: if `authTokenProvider == null && route is not in
{/login, /onboarding/*}`, redirect to `/login`. The dev-bypass token
seed survives — `--dart-define=DEV_AUTH_TOKEN` continues to populate
`authTokenProvider` on app boot in debug, so the local dev loop is
unchanged. Onboarding step 1 regains its "I already have an account"
link (reversing PM Risk 2 from `pm_decisions_flutter_ui.md`); the
login screen's footer carries the symmetric "Don't have an account?
Sign up" link to `/onboarding/1`.

**Model decisions inherited from PM.** No biometric unlock, no
social login, no multi-account, no "Stay signed in" toggle, no
password reset, no 2FA, no mDNS / QR-code server hand-off, no
in-app "switch server" affordance separate from sign-out. The
v1.0 surface is one route, one form, one POST, one token. The
sign-out flow extends today's `signOut()` to additionally clear
the secure-storage token but **leaves `auth_config.base_url` and
`last_username` intact** — PM directive, so re-login is two field
touches instead of three. The bearer token does *not* live in
Hive; it lives in `flutter_secure_storage` (iOS Keychain / Android
EncryptedSharedPrefs / a web `localStorage` shim). The server URL
is not secret; Hive is the right home for it.

**What this doc does NOT propose.** No backend code. BE-008 (POST
/auth/login) and BE-009 (/health canonical mount + CORS) are
proposals to the backend team flagged at the ledger; the client
ships against the v1 workaround until they land (see §3.6). No new
pub deps (`flutter_secure_storage` is the one borderline call —
see §10; if PMgr says no, the bearer survives in Hive with a
documented downgrade). No `@freezed` / `@riverpod` codegen — the
forms are small `StateNotifier`s consistent with the existing
shape. No new tenant. The login screen is well covered by T-04 /
T-08 / T-11 / T-15 / T-24 as written.

---

## 2. Refactor — runtime API base URL

This is the foundational refactor. Everything else in the pack
either reads `apiBaseUrlProvider` or sets the Hive value that
`apiBaseUrlProvider` reads from. It ships **first** as a
behaviour-preserving change (with the dev-define override still
wired, the dev loop is unchanged) and then the login screen
hangs off the provider.

### 2.1 Today — the compile-time seam

`client/lib/data/api_client.dart:29-32`:

```dart
const String _baseUrlFromEnv = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: ApiClient.defaultBaseUrl,
);
```

This top-level `const` is the only read site. `apiClientProvider`
(lines 34–61) constructs `Dio` once with `baseUrl: _baseUrlFromEnv`
and never rebuilds. The interceptor reads
`ref.read(authTokenProvider)` per request, so the bearer is
runtime-driven; the base URL is not. We are flipping the second
half of that asymmetry — `apiClient.baseUrl` becomes runtime, same
shape as the bearer.

### 2.2 After — `apiBaseUrlProvider` + a rebuilt Dio per change

**New provider.** `client/lib/providers/api_base_url_provider.dart`
(new file in `providers/` next to the other infra providers).
Returns `String?` resolved by three rules in order:

1. **Debug-only dev override.** If `kDebugMode` and a non-empty
   `--dart-define=API_BASE_URL=…` was supplied at build time,
   return that. Keeps the local-Rust dev loop alive — `flutter run
   -d chrome` against the Flutter dev port would otherwise pick up
   `http://localhost:<flutter-port>/api/v1` from `Uri.base`, which
   points at the Flutter dev server, not the Rust server.
2. **Web** (any build mode). `Uri.base.origin + '/api/v1'`. The
   customer typed the URL into their browser; `Uri.base` is
   canonical.
3. **Mobile.** Read `base_url` out of the `auth_config` Hive box
   via `ref.watch(authConfigBoxProvider).get(AuthConfigKey.baseUrl)`.
   May be `null` on a fresh install — the only legal post-`null`
   state on mobile is the login screen (the redirect rule
   enforces it).

Watchers: `apiClientProvider` (rebuilds Dio when the URL
changes) + the login screen's URL field controller (seeds from
the current value on mount). Test override:
`apiBaseUrlProvider.overrideWith((_) => 'https://test.example/api/v1')`.

**Why a `Provider<String?>` not a `FutureProvider<String?>`.** The
Hive box is already open at boot (we extend `main.dart` to await its
open before `runApp`, see §4). The provider returns the current
synchronous value; the only async surface is during the login flow
itself (which uses the `apiClient` directly, not the provider).

**Why `ref.watch` over `ref.read` on `authConfigBoxProvider`.** The
box itself doesn't change identity, but the **`Listenable`**-style
watch makes the future "what if we add a profile-screen 'switch
server' affordance" zero-friction: we'd flip the box's
listener-shape to invalidate the provider on `put`, and
`apiClientProvider` rebuilds. Today it doesn't matter because the
login flow itself replaces the value and then explicitly invalidates
`apiBaseUrlProvider`; using `watch` keeps the seam right for the
future.

### 2.3 Rebuilt `ApiClient` — constructor takes the URL

`ApiClient` loses the `defaultBaseUrl` static and the top-level
`_baseUrlFromEnv` const. `apiClientProvider` becomes:

- `ref.watch(apiBaseUrlProvider)` for the base URL (`String?`).
- Null falls through to a `'about:invalid'` sentinel — Dio
  constructs against it, the first request fails loud with a
  `DioException`, callers see the error. The redirect rule
  prevents this state in practice; the sentinel is the
  fail-loud guardrail equivalent to today's empty-string
  fallback when `String.fromEnvironment` has no default.
- BaseOptions unchanged (10/20/20 s timeouts, JSON headers).
- Interceptor branches unchanged for the bearer; `onError`
  gains the 401-sweep branch (§3.4).
- Rebuilds on every URL change (the `watch` does this for free).

**Test ergonomics.** `apiClientProvider` reads
`apiBaseUrlProvider`; tests override the latter with
`overrideWith((_) => 'https://test.example/api/v1')` and the Dio
mounts against that. The existing test container shape (seen in
`architect_qol.md` §6) doesn't change.

### 2.4 URL normalization — one canonical seam

The PM's "Validation strategy" lists trim, strip-trailing-slash,
prepend-`https://`-if-scheme-less, append-`/api/v1`-if-missing.
We encode these in one pure function so the login controller
and any future "switch server" affordance share the rules.

Signature:

```dart
// client/lib/features/login/url_normalize.dart
String normalizeServerUrl(String raw, {bool allowInsecure = false});

class UrlNormalizeError implements Exception { /* kind + message */ }
enum UrlNormalizeErrorKind { empty, malformed, insecureScheme }
```

Rules, in order: trim → strip trailing slashes → prepend
`https://` if no scheme → reject `http://` unless
`allowInsecure: true` → append `/api/v1` if the path doesn't
already end in it (path-prefixed inputs like
`example.com/fulfilled/api/v1` preserved verbatim) → validate
the result parses as an absolute URI, else
`UrlNormalizeError(malformed)`. The function does NOT validate
reachability — that's the `/health` probe's job.

**Test fixture table** (`url_normalize_test.dart`) covers: bare
host → `https://...`, whitespace-trimmed, trailing slash
stripped, already-canonical preserved, `http://` rejected
without flag and accepted with it, scheme-less host:port
upgraded, empty string and "not a url at all" → throws,
path-prefixed `example.com/fulfilled/api/v1` preserved
verbatim (last row is important — see §10's reverse-proxy
open question).

### 2.5 Migration of existing callers — zero source changes

`ApiClient.defaultBaseUrl` is referenced by exactly two files
today (the api client + one test fixture). The fixture's one-line
override migrates to `apiBaseUrlProvider.overrideWith`. No
repository touches `defaultBaseUrl` directly. `grep -rn
'API_BASE_URL\|defaultBaseUrl' client/lib client/test` returns
two hits. PR is small; behaviour-preserving.

### 2.6 Acceptance criteria — Refactor (the base URL seam)

- `apiBaseUrlProvider` exists at `client/lib/providers/api_base_url_provider.dart`,
  returns `String?`, and honors the three rules in §2.2 in order.
- `apiClientProvider` `ref.watch`es `apiBaseUrlProvider` and rebuilds
  its Dio when the value changes (a widget test that swaps the
  override and asserts the new `dio.options.baseUrl` proves the
  rebuild).
- The compile-time `_baseUrlFromEnv` top-level const is removed.
  `String.fromEnvironment('API_BASE_URL')` survives at exactly one
  call site: inside `apiBaseUrlProvider`'s debug-only branch.
- `ApiClient.defaultBaseUrl` is removed.
- `normalizeServerUrl` exists at `client/lib/features/login/url_normalize.dart`,
  is pure, and the §2.4 table passes.
- `grep -rn 'dart-define.*API_BASE_URL' client/lib` returns exactly
  one hit (the dev-override branch).
- All existing repository tests pass with no source changes other
  than the api-client test fixture override swap.

---

## 3. Refactor — `AuthTokenNotifier.signInWithCredentials`

The second seam. `AuthTokenNotifier` today has `signIn(String token)`
and `signOut()`; we add `signInWithCredentials({required String
username, required String password})` that does the work of trading
credentials for a token. The existing `signIn(String token)` stays
as the **terminal write step**; the new method is a thin orchestrator
that calls `signIn` on success.

### 3.1 Today — the notifier shape

`client/lib/data/auth_token.dart:26-68` is the `AuthTokenNotifier`.
`build()` returns the seed token from `--dart-define=DEV_AUTH_TOKEN`
(falling back to `'dev-bypass'` in debug). `signIn(String token)`
sets the state. `signOut()` nulls the state and clears the outbox
box.

The notifier is intentionally `BuildContext`-free (per its own
dartdoc: "Navigation back to `/onboarding/1` is the **caller's**
job"). We keep that — the login controller (a separate
`StateNotifier`) holds the form state, validates, calls
`signInWithCredentials`, and on success calls `context.go`.

### 3.2 After — the new method

The signature:

```dart
/// Trade username + password for a bearer token by POSTing to
/// `<baseUrl>/auth/login`.
///
/// On success: persists the returned token via `signIn(token)`
/// (existing method). The bearer is stored both in-memory (this
/// notifier's state) and in `flutter_secure_storage` so it
/// survives an app restart.
///
/// Throws (all from `LoginError` sealed hierarchy):
///   - `BadCredentialsError` on 401 — inline "Username or password
///     is incorrect" under the password field.
///   - `LoginNetworkError` on network failure / 5xx / other Dio
///     errors — form-level error row under the submit button.
///   - `LoginEndpointMissingError` on 404 — login controller flips
///     `pastedJwtMode` and renders the BE-008 workaround
///     disclosure (§3.6).
Future<void> signInWithCredentials({
  required String username,
  required String password,
});
```

The implementation:

1. `ref.read(apiClientProvider).dio.post('/auth/login', data:
   {username, password}, options: Options(headers:
   {'Authorization': ''}))`. The header-clear is defensive — the
   interceptor would otherwise attach a stale bearer (e.g.
   re-login after a 401 sweep). `/auth/login` is `security: []`
   so the server ignores it, but we keep the wire clean.
2. Validate the response: `body != null && body['token']` is a
   non-empty string. Empty → `LoginNetworkError`.
3. **Persist to secure storage before mutating notifier state.**
   If the write fails we'd rather not flip the in-memory token to
   something that won't survive an app restart.
4. Call the existing `signIn(token)` which writes
   `state = token`.
5. Catch `DioException`: 401 → `BadCredentialsError`; 404 →
   `LoginEndpointMissingError`; otherwise →
   `LoginNetworkError(_describeDioError(e))`.

**Error types.** `client/lib/data/login_errors.dart` (new file):

```dart
sealed class LoginError implements Exception {
  const LoginError(this.message);
  final String message;
  @override
  String toString() => message;
}

class BadCredentialsError extends LoginError {
  const BadCredentialsError(super.message);
}

class LoginNetworkError extends LoginError {
  const LoginNetworkError(super.message);
}

class LoginEndpointMissingError extends LoginError {
  const LoginEndpointMissingError(super.message);
}

class HealthProbeError extends LoginError {
  const HealthProbeError(super.message, this.kind);
  final HealthProbeErrorKind kind;
}

enum HealthProbeErrorKind {
  dns,         // host unresolvable
  tls,         // certificate / handshake failure
  timeout,     // 8 s elapsed
  nonOk,       // 2xx but not `{status: "ok"}`, or non-2xx response
  notFound,    // 404 — the address answered but isn't a Fulfilled server
}
```

The four `HealthProbeErrorKind`s map 1:1 to PM §5.2's four error
classes (DNS / TLS / non-2xx / 404). The login controller renders
the inline error text by switching on the enum (§5 of this doc).

### 3.3 The wire shape — `POST /auth/login`

Verified against `specs/openapi.yaml`: this endpoint does **not
exist** today. The security scheme is bearer-only (lines
761–770); no token-issuing endpoint is declared. BE-008 (§11)
proposes adding it.

The client codes against this shape: `POST /auth/login` with
`security: []`; request body `{username: string, password:
string}`; 200 response `{token: string, expires_at?:
ISO-8601-datetime}`; 401 response `Error` body for bad
credentials.

`expires_at` is **optional** on the response. v1 ships **no
refresh-token rotation**; if `expires_at` is absent the client
treats the token as "valid until 401". On any authenticated
endpoint's 401, `apiClientProvider`'s interceptor gains the
401-sweep branch (§3.4) that signs the user out and routes to
`/login`.

### 3.4 The 401 sweep — the Dio interceptor's new branch

PM said "v1 ships no refresh token — the bearer is the only
credential, and on `401` from any endpoint the client signs the
user out and routes to `/login`." The interceptor today *only*
sets the request `Authorization` header. We add an `onError`
branch: if `response?.statusCode == 401 && requestOptions.path
!= '/auth/login'`, await `authTokenProvider.notifier.signOut()`
and `handler.next(e)` (bubble to caller).

**Why not `handler.reject`.** The caller (`LogRepository.update`,
say) still wants the error so it can surface a SnackBar (T-11).
The sign-out is the sweep side-effect; the user sees the SnackBar
*and* lands on `/login` once the router's refresh listener fires.

**Why exclude `/auth/login`.** That endpoint itself returns 401
on bad credentials — we must not loop.

**`refreshListenable` wiring.** `appRouterProvider` constructs a
`_AuthListenable extends ChangeNotifier` that `ref.listen`s
`authTokenProvider` and calls `notifyListeners()` on every
change. `GoRouter` re-evaluates its `redirect` function on every
listener fire; the redirect function (§7.2) sees the null token
and routes to `/login`.

### 3.5 Secure-storage seam — `SecureTokenStore`

The bearer lives in platform secure storage. The package is the
**one borderline pub-dep call** in this doc:
`flutter_secure_storage` (the canonical, mature package; has the
web shim via `window.localStorage`). The bespoke alternative
(thin platform-channel wrapper + localStorage shim) is two
evenings of work for zero functional gain. **PMgr flag** in §10
if this is the wrong call.

The seam itself is `SecureTokenStore` — an `abstract class` with
`read()` / `write(String)` / `delete()` returning `Future`s,
implemented by `_FssSecureTokenStore` against
`FlutterSecureStorage` with the literal key
`'fulfilled.auth.bearer'`. Exposed via
`secureTokenStoreProvider`. Tests override the provider with an
in-memory fake (ten lines; same pattern as `outboxBoxProvider`).

**Boot-time seed.** `AuthTokenNotifier.build()` today returns the
dart-define seed synchronously. We change it to honour the new
dev-loop trapdoor (§7.3) and fall through to `null` for the
real-token path. `main.dart` then does the secure-storage read
before `runApp` and overrides the provider with the read value
via `AuthTokenNotifier.seeded(bearer)` (see §4.2 for the named
constructor). This keeps `build()` synchronous (Riverpod
constraint) without losing the "survives-app-restart" property
of the bearer.

### 3.6 v1 workaround until BE-008 lands — "paste your JWT as the password"

PM §8 BE-008 named this. If `POST /auth/login` returns 404, the
login controller catches `LoginEndpointMissingError` and shows an
inline disclosure under the form: *"This server doesn't have a
login endpoint yet. You can paste a JWT directly as the password
— it'll be sent as a bearer without going through /auth/login."*
Disclosure-tap flips `state.pastedJwtMode = true`; the next submit
skips `/auth/login`, treats the password as the literal bearer,
persists it via `secureTokenStoreProvider.write` +
`authTokenProvider.signIn(token)`, and routes to `/today`. The
seam is **one boolean on the controller state** plus a single
branch in the submit handler (§5.4 shows the full flow).

`_looksLikeJwt` is `raw.split('.').length == 3 &&
raw.split('.').every((seg) => seg.isNotEmpty)`. We don't actually
parse the JWT — the server validates it; we just guard against
"the user typed their actual password here by mistake and we
shipped it as a bearer."

**The seam flips off cleanly when BE-008 lands.** The
`LoginEndpointMissingError` branch is dead code once /auth/login
exists; the disclosure never renders; `pastedJwtMode` stays
`false`. We don't remove the workaround code in BE-008's PR — it
stays as the **mixed-deployment fallback** for customers who
self-host an older Rust build. Removal trigger: `// TODO BE-008`
on the `pastedJwtMode` field; PMgr can gate behind a kill-switch
in v1.1 if needed.

### 3.7 Acceptance criteria — `signInWithCredentials`

- `AuthTokenNotifier.signInWithCredentials({required String username,
  required String password})` exists, is `Future<void>`, throws the
  four typed `LoginError` subclasses listed in §3.2.
- On 200, the returned `token` is persisted to
  `secureTokenStoreProvider` *before* `signIn(token)` flips the
  in-memory state. A widget test that injects a failing
  `secureTokenStoreProvider` asserts the notifier state remains
  `null` after the failure.
- On 401, throws `BadCredentialsError`; the in-memory state and the
  secure-storage value are untouched.
- On 404, throws `LoginEndpointMissingError`. The login controller's
  catch flips `_pastedJwtMode = true` and renders the disclosure
  (§5.4).
- On network / 5xx / unknown Dio error, throws `LoginNetworkError`
  with a human-readable cause.
- The 401-sweep interceptor branch fires on any authenticated
  request's 401 except `/auth/login` itself; the
  `authTokenProvider` flips to `null` and the router's redirect
  routes the user to `/login`.
- The dev-bypass seed survives — `flutter run --dart-define=DEV_AUTH_TOKEN=dev-bypass`
  continues to seed the notifier at boot; the router does **not**
  redirect to `/login` in that case (token non-null).
- `flutter_secure_storage` is the chosen pub dep. (If PMgr says no
  in §10, the bearer survives in `auth_config` Hive with a
  documented downgrade — same seam, different store.)

---

## 4. The Hive box + bootstrap

### 4.1 `auth_config` box — schema

The box is `Box<String>` keyed by short literal strings. Schema:

```dart
// client/lib/data/auth_config_box.dart
/// The `auth_config` Hive box holds non-secret app-level
/// configuration. The bearer token does NOT live here — see
/// `SecureTokenStore` (§3.5). Hive is local plaintext; tokens
/// belong in the platform keystore.
///
/// Survives sign-out. PM directive: re-login is two field touches
/// (password + tap), not three.
abstract class AuthConfigKey {
  AuthConfigKey._();
  static const baseUrl = 'base_url';
  static const lastUsername = 'last_username';
}

const String authConfigBoxName = 'auth_config';
```

**Why `Box<String>` and not a typed adapter.** Two keys, both
string-valued. A typed adapter is over-scope. If the box grows a
non-string value (e.g. a `bool allowInsecureLastSession`), we
promote it to `Box<dynamic>` or split into a sibling typed box —
the inventory comment in §13 names the trigger.

**Provider surface.** Mirroring `outboxBoxProvider`:

```dart
// client/lib/providers/auth_config_providers.dart
final authConfigBoxProvider = Provider<Box<String>>((ref) {
  throw UnimplementedError(
    'authConfigBoxProvider must be overridden in main.dart with the '
    'open Hive box.',
  );
});
```

The `UnimplementedError` is the same shape `outboxBoxProvider` uses
today. `main.dart` overrides it; tests override it with a temp-dir
box.

### 4.2 `main.dart` — extend the bootstrap

Today `main.dart` opens one box (`outbox_log`) before `runApp`.
After:

1. `WidgetsFlutterBinding.ensureInitialized()` + `Hive.initFlutter()`.
2. **Parallel open** `outbox_log` + `auth_config` via
   `Future.wait` (both small; saves ~10 ms of boot time).
3. Construct `_FssSecureTokenStore` and `await secureStore.read()`
   for the bearer.
4. `runApp(ProviderScope(overrides: [...]))` with four
   overrides: `outboxBoxProvider`, `authConfigBoxProvider`,
   `secureTokenStoreProvider`, and `authTokenProvider.overrideWith(()
   => AuthTokenNotifier.seeded(bearer))`.

`AuthTokenNotifier.seeded(String? bearer)` is a
named-constructor that captures the bearer in a `String? _seed`
field; `build()` returns the seed once (consumes the field to
null), then falls through to the dev-bypass branch on subsequent
rebuilds.

**Why the named-constructor seed and not a plain
overrideWithValue.** A `NotifierProvider`'s `overrideWith`
builds a `Notifier`; we need `build()` to *consume* the seed
synchronously. The `seeded(bearer)` constructor pushes the
read value through without making `build()` async (Riverpod
constraint) and without coupling the notifier to `main.dart`'s
closure.

### 4.3 Acceptance criteria — bootstrap

- `main.dart` opens both `outbox_log` and `auth_config` before
  `runApp`. The `Future.wait` parallel open is the canonical
  shape; tests assert both boxes exist in the override list.
- `secureTokenStoreProvider` is overridden in `main.dart` with the
  real `FlutterSecureStorage`-backed implementation.
- `authTokenProvider` is overridden with `AuthTokenNotifier.seeded(bearer)`
  where `bearer` is the secure-storage read. A test that swaps the
  secure-storage fake to return `'cached-token'` asserts the
  notifier's state is `'cached-token'` after boot.
- `authConfigBoxProvider` reads/writes survive an app restart in a
  manual smoke (test fixture: open box, put `base_url`, close
  Hive, re-open, assert `base_url` is still there).

---

## 5. The login screen — file shape and behaviour

### 5.1 Files

```
client/lib/features/login/
  login_screen.dart              # Route-bound widget; form-factor branches at root
  login_controller.dart          # StateNotifier owning form state + submit
  url_normalize.dart             # Pure function from §2.4
  widgets/
    server_url_field.dart        # URL input, inline errors, "Use HTTP" disclosure
    credentials_form.dart        # Username + Password inputs
    login_button.dart            # Wraps PrimaryButton; button skeleton (T-08)
    sign_up_link.dart            # "Don't have an account? Sign up" link
    paste_jwt_disclosure.dart    # BE-008 workaround disclosure (§3.6)
```

Eight files for the feature folder. Each widget is small (one
input + one inline error); split keeps every file under
~150 lines, same shape as the log-entry sheet's widget folder.
`url_normalize.dart` is the pure function shared with any
future "switch server" affordance (deferred).

### 5.2 `LoginScreen` — form-factor branches at root (T-15)

`LoginScreen.build` reads `MediaQuery.sizeOf(context).width`,
compares against `Breakpoints.mediumMax`, and returns one of
`_LoginExpanded` (centred card, max-width 420) or
`_LoginCompact` (single-column, full-width form). Both share a
private `_LoginBody` (the form column); the wrappers differ
only in their outer constraints. T-15 compliance: the
form-factor pick happens at the screen root.

**Layout — `_LoginBody`** (top to bottom):

1. Logo (same `_Logo` shape `step_1_welcome.dart` uses; not
   hoisted to `lib/widgets/app_logo.dart` in v1 — see §10.5).
2. Headline *"Sign in to your server"* in `context.text.hero`.
3. Spacing `context.space.x6`.
4. `ServerUrlField` (mobile only — `!kIsWeb`; on web omitted
   from the column entirely, not zero-height-hidden).
5. `CredentialsForm`.
6. Spacing `context.space.x6`.
7. `LoginButton` (full-width `PrimaryButton`).
8. `PasteJwtDisclosure` (only when `state.endpointMissing`).
9. `SignUpLink`.

Spacing between fields: `context.space.x4`. Same density as the
log-entry sheet.

### 5.3 `LoginController` — the StateNotifier

`LoginFormState` is an `@immutable` record-shaped class with:

- `url`, `username`, `password` — current input values.
- `allowInsecure: bool` — per-session "I understand this is
  HTTP" toggle. PM §5.3: not persisted across launches.
- `endpointMissing: bool` — set true when /auth/login returns
  404; renders the JWT-paste disclosure under the form.
- `pastedJwtMode: bool` — set true when the user accepts the
  disclosure; the next submit short-circuits past /auth/login
  and treats password as a JWT.
- `submitting: bool` — drives the T-08 button skeleton.
- `urlError`, `credentialsError`, `formError: String?` — the
  three inline error slots (§5.5).

`LoginController extends StateNotifier<LoginFormState>` with:

- A `Ref _ref` (so the controller can read other providers).
- Plain setters: `setUrl`/`setUsername`/`setPassword` clear the
  matching error slot on every keystroke;
  `toggleAllowInsecure()`; `acceptJwtDisclosure()` flips
  `pastedJwtMode = true`, `endpointMissing = false`.
- `Future<bool> submit()` — see §5.4.
- `Future<void> _persistConfig(url, username)` — writes both
  keys to the Hive box.
- `static Future<void> resetForTesting(Ref ref)` — clears the
  Hive box. Test seam (§9.3).

The provider:

```dart
final loginControllerProvider =
    StateNotifierProvider.autoDispose<LoginController, LoginFormState>(
  (ref) {
    final box = ref.watch(authConfigBoxProvider);
    final urlFromHive = box.get(AuthConfigKey.baseUrl);
    return LoginController(
      ref,
      initial: LoginFormState(
        url: kIsWeb ? '' : (urlFromHive ?? ''),
        username: box.get(AuthConfigKey.lastUsername) ?? '',
        allowInsecure: urlFromHive?.startsWith('http://') ?? false,
      ),
    );
  },
);
```

(The `allowInsecure` pre-seed handles the LOG-S6 case where a
previous successful sign-in stored an `http://` URL; see §5.6.)

**Why `StateNotifier` and not codegen.** No codegen per pack
constraints. `StateNotifier` matches every other form controller
in the codebase. **Why `autoDispose`.** Login is one-shot;
popping the route should clear the form state so the next visit
doesn't inherit a stale password buffer.

### 5.4 Submit flow — the step-through

The whole point of this pack is the submit handler. The five
phases, each owning its own inline-error path:

1. **BE-008 workaround branch (early return).** If
   `state.pastedJwtMode`: trim password, validate `_looksLikeJwt`
   (else `credentialsError`), write to secure-storage, call
   `authTokenProvider.signIn(raw)`, persist URL + username,
   return `true`. The screen routes to `/today`.
2. **URL normalize.** On mobile, call `normalizeServerUrl(state.url,
   allowInsecure: state.allowInsecure)`. On
   `UrlNormalizeError(insecureScheme)` set the per-session toggle
   prompt as the `urlError`. On `(empty|malformed)` set a
   plain-language `urlError`. On `kIsWeb` skip — read
   `apiBaseUrlProvider` directly; null means "couldn't determine
   the server URL from this page" → `formError`.
3. **Health probe.** Call `healthProbeProvider.probe(normalized,
   timeout: 8s)`. On `HealthProbeError` map the
   `HealthProbeErrorKind` to `urlError` text per §3.2's four
   classes. (Map: `dns` → *"Couldn't find a server at that
   address..."*; `tls` → *"Couldn't establish a secure
   connection..."*; `timeout` → *"...timed out after 8
   seconds..."*; `nonOk` → *"Server responded with <code>..."*;
   `notFound` → *"That address answered, but doesn't look like a
   Fulfilled server."*).
4. **Persist + invalidate.** `box.put(baseUrl, normalized)` then
   `ref.invalidate(apiBaseUrlProvider)`. `apiClientProvider`
   rebuilds Dio against the new URL **before** the credential
   POST fires.
5. **Credential POST.** `authTokenProvider.signInWithCredentials(...)`.
   `BadCredentialsError` → `credentialsError` under password
   field. `LoginEndpointMissingError` → `endpointMissing = true`,
   render JWT-paste disclosure. `LoginNetworkError` → `formError`
   under the submit button. On success, persist `last_username`
   and return `true`.

The screen's submit handler awaits `controller.submit()` and on
`true` calls `context.go(Routes.todayPath)` (T-24 Case 2 —
route-to-effect). The screen does not duplicate the validation
logic; the controller owns it.

**The `_probeHealth` helper.** Constructs a fresh `Dio` against
the candidate base URL (not `apiClientProvider` — see below);
GETs `/health` with the 8 s timeout on all three Dio timeout
slots; maps the response: 200 + `{status: "ok"}` → ok; 200 +
missing/wrong status JSON → `notFound`; 404 → `notFound`;
5xx/non-2xx → `nonOk` (with status code in message);
`DioExceptionType.{connectionTimeout|receiveTimeout|sendTimeout}`
→ `timeout`; `DioExceptionType.badCertificate` → `tls`;
`SocketException` → `dns`; otherwise → `nonOk`.

**Why a fresh `Dio` inside the probe.** The probe runs against
an unpersisted URL — the user might be typing a candidate while
`auth_config.base_url` still holds a previously-good URL.
Persisting + invalidating before the probe would flip the app's
wiring against a URL we don't know is good yet.

### 5.5 Field-level error rendering — T-11 inline

The three error slots map to the three state fields:

- `urlError` → under `ServerUrlField`'s `helperText` slot
  (replaces the *"e.g. https://fulfilled.mydomain.com"*
  example). Red `context.text.meta` in `context.colors.danger`.
- `credentialsError` → under the password field, same shape.
  The username field doesn't get its own error slot — bad
  credentials don't tell us which field was wrong.
- `formError` → non-modal row below the submit button:
  `Icon(Icons.warning_amber_rounded, color: danger)` + the
  message in `context.text.meta`. No SnackBar — T-11's "save
  failures show a SnackBar" is for sheet-style surfaces; the
  login screen is a full route with inline space for it.

### 5.6 The "Use HTTP" disclosure — per-session toggle

PM §5.3 ruled HTTPS-default,
HTTP-allowed-only-after-explicit-per-session-toggle. Flow: user
types `http://192.168.1.5:8080` → `normalizeServerUrl(raw,
allowInsecure: false)` throws
`UrlNormalizeError(insecureScheme)` → `urlError` renders "HTTPS
required. If this is a local server without HTTPS, tap 'Allow
HTTP for this session'." The disclosure renders below the
inline error as a `TextButton.icon` with
`Icons.lock_open_outlined`; tap fires
`controller.toggleAllowInsecure()` which clears `urlError`.
Next submit normalizes with `allowInsecure: true`. The flag
does NOT persist across launches; the disclosure re-prompts.

PM §5.3 also said successful HTTP sign-in causes subsequent
re-logins to re-use the scheme without re-prompting. Handled
by the controller's initial-state pre-seed (§5.3 provider): if
the Hive-stored URL starts with `http://`, `allowInsecure` is
pre-set to `true` on mount. One condition, no UI flicker.

### 5.7 Skeleton button — T-08 compliance

While `submit()` is in flight (`state.submitting == true`), the
`LoginButton` renders a button-sized skeleton in place of the
label — same shape as `_SaveButtonSkeleton` in
`log_entry_sheet.dart:722`. No `CircularProgressIndicator`. The
username + password fields go read-only during submit.

### 5.8 Acceptance criteria — login screen

- `client/lib/features/login/login_screen.dart` exists, registers
  at `/login` outside the `ShellRoute`. The screen renders three
  fields on mobile, two on web (`!kIsWeb` gate on
  `ServerUrlField`).
- The URL field's initial value is the `auth_config.base_url` Hive
  value (or empty). Helper text reads `e.g.
  https://fulfilled.mydomain.com` — never a placeholder *inside*
  the field (PM §5.4).
- The username field's initial value is the
  `auth_config.last_username` Hive value (or empty). The password
  field is always empty.
- Submit runs in this order: URL normalize → `/health` probe (8 s
  timeout) → persist + invalidate `apiBaseUrlProvider` → POST
  `/auth/login` → persist last_username → route to
  `Routes.todayPath`.
- Each of the four PM-named URL error classes (DNS / TLS / timeout
  / 404 on health) renders as a distinct inline message under the
  URL field with `context.colors.danger`.
- 401 from `/auth/login` renders *"Username or password is
  incorrect"* under the password field, leaves URL + username +
  password values intact (the user can fix and retry).
- 404 from `/auth/login` renders the JWT-paste disclosure
  (workaround §3.6) below the form. Accepting the disclosure flips
  `_pastedJwtMode = true`; the next submit shortcuts past the POST
  and treats the password as a literal JWT.
- The submit button shows a button-skeleton (T-08) while in flight,
  not a `CircularProgressIndicator`.
- On successful login the screen calls `context.go('/today')`
  (T-24 Case 2). Hive holds `base_url` + `last_username`. Secure
  storage holds the bearer.
- On dismiss / pop (Android back, browser back on web), the form
  state clears (autoDispose StateNotifier).
- `kIsWeb` → URL field is not rendered, `apiBaseUrlProvider` reads
  `Uri.base.origin + '/api/v1'`, the controller skips URL
  normalize and goes straight to the health probe.

---

## 6. The web login flow

**Field hiding.** On `kIsWeb`, `_LoginBody` omits
`ServerUrlField` entirely. The expanded card-layout (max-width
420) is identical in shape to mobile's iPad-class medium
breakpoint; visually the web login is a tighter mobile-expanded.

**`apiBaseUrlProvider` short-circuit.** Web branch returns
`Uri.base.origin + '/api/v1'`. Hive is never read on web. Tests
that simulate web must override `apiBaseUrlProvider` directly
because `Uri.base` inside `flutter_test` is `about:blank`.

**The reverse-proxy assumption.** `Uri.base.origin` strips the
path, so an operator who reverse-proxies under `/fulfilled/`
gets the wrong base URL on web. The alternative — strip the
current route from `Uri.base.path` — is fragile (any future
route the user happens to be on when they cold-load gives a
different stripped path). **Architect rule: v1 ships
`Uri.base.origin` only and documents the limitation as a known
v1 constraint.** Customers behind a subpath must mount
Fulfilled at the origin's root. §10.2 flags this for PMgr.

**Acceptance**: `_LoginBody` on `kIsWeb` does not render the URL
field; `apiBaseUrlProvider` returns `Uri.base.origin + '/api/v1'`
ignoring Hive; the screen submits with username + password
only. A widget test overrides `apiBaseUrlProvider` to a fixed
test URL and asserts no URL field renders.

---

## 7. Routing

### 7.1 New constants

`client/lib/routing/routes.dart` gains:

```dart
static const String loginName = 'login';
static const String loginPath = '/login';
```

Alphabetical-by-name placement in the existing constants block.

### 7.2 Route registration + redirect rule

`appRouterProvider` gains a `refreshListenable: _AuthListenable(ref)`
+ a synchronous `redirect: (context, state)` callback. The
`/login` route lands inside `routes:` outside the `ShellRoute`,
alongside `/onboarding/:step`, with
`builder: (_, __) => const LoginScreen()`.

**Redirect ordering** (PM directive — document explicitly):

1. **No token + non-auth route** → `/login`. Dominant path for
   first-time launches and post-401 sweeps.
2. **No token + onboarding route** (`loc.startsWith('/onboarding/')`)
   → allow. Onboarding's end state is signing the user up
   (out-of-band in v1).
3. **No token + login route** → allow.
4. **Has token + login route** → `/today`. Prevents a signed-in
   user from accidentally landing on the login screen via deep
   link.
5. **Has token + any other route** → allow.

The redirect is **synchronous** (no `async` inside go_router's
`redirect`). The token read is via `ref.read`, not `ref.watch`,
but the `refreshListenable` notifies on token change so
go_router re-evaluates when the token flips.

### 7.3 The dev-bypass token short-circuit

**Architect rule: dev-bypass survives on debug builds only.**
`_seedToken()` keeps `'dev-bypass'` in debug behind a new
`--dart-define=DEV_AUTH_BYPASS_DISABLE=1` opt-out (call this
the **dev-loop trapdoor**) so a dev can exercise the login flow
without recompiling. The order: compile-time `DEV_AUTH_TOKEN`
wins if set; else if `kDebugMode && !DEV_AUTH_BYPASS_DISABLE`
return `'dev-bypass'`; else `null`. Default remains "dev-bypass
in debug, null in release"; release builds route to `/login`.

### 7.4 Onboarding step 1 — re-add "I already have an account"

`step_1_welcome.dart` gains one `TextButton` at the bottom of
the body column wired to `context.go(Routes.loginPath)`, styled
with `foregroundColor: context.colors.accent` and
`textStyle: context.text.bodyStrong`. The widget's dartdoc
header (currently asserts "No 'I already have an account'
affordance — PM Risk 2 removed it") is amended with a History
note pointing at `pm_login.md` and the Risk 2 reversal. Total
shipping change: ~16 lines + one widget test asserting the tap
routes to `/login`.

### 7.5 Login screen — symmetric "Don't have an account? Sign up"

`SignUpLink` widget routes the other direction: a `TextButton`
with `onPressed: () => context.go('/onboarding/1')`, same
styling. Renders below the submit button + below any inline
form error. On web the same link surfaces (onboarding works on
web — verified at `app_router.dart:175-182`).

### 7.6 Acceptance criteria — routing

- `Routes.loginPath = '/login'` and `Routes.loginName = 'login'`
  constants exist.
- `GoRoute(path: '/login', ...)` registers outside the `ShellRoute`.
- The router's `redirect` enforces the five rules in §7.2.
- `refreshListenable` is a `_AuthListenable` that observes
  `authTokenProvider`; a widget test that flips the token from
  non-null to null (via the notifier's `signOut`) asserts the
  router re-evaluates and lands on `/login`.
- Onboarding step 1 renders the "I already have an account"
  TextButton routing to `/login`. The widget's dartdoc is amended;
  `pm_decisions_flutter_ui.md` Risk 2 carries the addendum.
- Login screen renders "Don't have an account? Sign up" routing to
  `/onboarding/1`.
- The dev-bypass seed survives — `flutter run` against
  `DEV_AUTH_BYPASS` lands on `/today` directly. Opting out via
  `--dart-define=DEV_AUTH_BYPASS_DISABLE=1` shows the login
  screen.

---

## 8. Sign-out flow

### 8.1 Today

`AuthTokenNotifier.signOut()` (auth_token.dart:60-67) clears the
in-memory state and the outbox Hive box.

### 8.2 After — extend, don't restructure

PM directive: *"Hive box persists across sign-outs so re-login
is fast."* So `signOut()` becomes: `state = null` → parallel
`Future.wait` on `outboxBoxProvider.clear()` and
`secureTokenStoreProvider.delete()`. The `auth_config` box is
**intentionally not cleared**. The redirect rule (§7.2) sees
the null token via the `refreshListenable` and routes to
`/login`; the login screen seeds URL + last_username from Hive;
the user types password and signs back in.

### 8.3 The "switch server" flow falls out for free

PM §3 LOG-S4 ("user signs out and changes the server URL on
re-login"): no special-case code. The user edits the URL field
(seeded with the old value), submits, the health probe runs
against the new URL, and on success the new URL replaces the
old one in Hive. The outbox is already cleared by sign-out;
pending writes against the old server have no meaning against
the new one.

### 8.4 Acceptance criteria — sign-out

- `AuthTokenNotifier.signOut()` clears in-memory token, outbox
  box, and secure-storage bearer. Does **not** clear `auth_config`.
- After sign-out, the `/login` screen seeds the URL + username
  fields from Hive (per §5.3).
- After signing in to a different server URL, the new URL replaces
  the old in `auth_config.base_url`; the outbox box is empty.
- A widget test exercises the round-trip: sign in →
  `auth_config.base_url == 'https://a/api/v1'` → sign out →
  `auth_config.base_url == 'https://a/api/v1'` still →
  sign in to `https://b` → `auth_config.base_url == 'https://b/api/v1'`.

---

## 9. Test seams

The pack's verification commands are listed in PM §12. The seams
that make those tests possible:

### 9.1 `apiBaseUrlProvider` — fixed override

`apiBaseUrlProvider.overrideWith((_) => 'https://test.example/api/v1')`
in the ProviderScope. The mock test fixtures use this everywhere
`ApiClient` is exercised against a real wire shape. Existing
tests that today read `String.fromEnvironment` via the const
fall through to the default; we audit those tests in the
refactor PR and migrate each to the override.

### 9.2 `LoginController` — `ApiClient` injection via overrides

The controller reads `apiClientProvider`, which reads
`apiBaseUrlProvider`. Tests override `apiClientProvider`
directly with a fake `Dio` (the existing `MockAdapter` from
`package:dio_test` pattern, already used by
`client/test/repositories/log_repository_test.dart`).

For the health-probe test specifically, the probe constructs a
**fresh** Dio (§5.4). To make that injectable we promote the
probe out of `LoginController` and into a small `HealthProbe`
abstract class with one `probe(String baseUrl, {required
Duration timeout})` method, exposed via `healthProbeProvider`.
Tests override the provider with a fake that throws the desired
`HealthProbeError` per case.

### 9.3 `authConfigBoxProvider` — temp-dir override

Test helper `openTestBox()` creates a temp directory via
`Directory.systemTemp.createTemp`, calls `Hive.init(dir.path)`,
and returns a `Hive.openBox<String>('test_auth_config_<rand>')`.
`LoginController.resetForTesting(ref)` calls `clear()` on the
box for in-test cleanup between cases.

### 9.4 `secureTokenStoreProvider` — in-memory fake

`FakeSecureTokenStore implements SecureTokenStore` with a single
`String? _value` field; `read`/`write`/`delete` mutate it. Tests
`overrideWithValue(FakeSecureTokenStore())`. Round-trip tests
(sign-in → restart-simulate → assert bearer survives) wire the
same fake instance into both pre- and post-restart
ProviderScopes.

### 9.5 The widget tests PM named (§12 verification commands)

The seven test files PM listed:

- `test/features/login/login_screen_compact_test.dart` — mounts
  `LoginScreen` at iPhone width, asserts three fields render,
  exercises submit through a fake `apiClient` that returns
  `{token: 'x'}`, asserts `context.go('/today')` runs.
- `test/features/login/login_screen_web_test.dart` — same as
  compact but with `kIsWeb` simulated and the URL field asserted
  absent.
- `test/features/login/login_url_validation_test.dart` — drives
  `LoginController.submit` with a fake `healthProbeProvider`
  returning each of the four `HealthProbeErrorKind`s, asserts the
  resulting `urlError` text per the four error classes.
- `test/routing/auth_redirect_test.dart` — mounts the full
  `appRouterProvider`, flips the auth token from non-null to null
  via the notifier, asserts the redirect fires and lands on
  `/login`. Also covers the inverse (token → `/today`).
- `test/data/auth_config_box_test.dart` — round-trips `base_url`
  + `last_username` through a real Hive temp-dir box; asserts
  values survive a close-then-reopen.
- `test/data/server_config_provider_test.dart` (renamed by us to
  `api_base_url_provider_test.dart` to match the actual provider
  name) — exercises the three resolution rules: dev override, web
  origin, mobile Hive read.
- `test/features/onboarding/step_1_welcome_link_test.dart` —
  mounts step 1, taps the "I already have an account" link,
  asserts the router goes to `/login`.

I read PM §12 and the test list is right. The seventh-file name
PM used (`server_config_provider_test.dart`) doesn't match the
provider name in this doc — architect rename to `api_base_url_provider_test.dart`,
called out in §10. PMgr can ratify.

### 9.6 Acceptance criteria — test seams

- `apiBaseUrlProvider` is overridable; the override winsdown
  through `apiClientProvider`'s rebuild.
- `healthProbeProvider` is overridable; the controller depends on
  it via `ref.read`.
- `secureTokenStoreProvider` is overridable; in-memory fake
  exists in `test/data/fake_secure_token_store.dart`.
- `authConfigBoxProvider` is overridable; temp-dir helper in
  `test/data/test_hive.dart`.
- `LoginController.resetForTesting(ref)` exists and clears the
  Hive box.
- The seven tests PM listed in §12 exist and pass.

---

## 10. Risks / open questions

Seven items. Two are architect rulings absorbed into the
implementation (10.1, 10.7); five are flagged for PMgr.

### 10.1 Does the dev-bypass token path stay alive in v1?

**Architect answer: yes, on debug builds only.** Per §7.3 the
`'dev-bypass'` seed survives in `_seedToken()` behind a
`kDebugMode` gate. A new `--dart-define=DEV_AUTH_BYPASS_DISABLE=1`
opt-out lets a dev exercise the login flow without recompiling.
Release builds get `null` and route to `/login`. **No PMgr
ratification needed**; flagging so dev tickets don't re-ask.

### 10.2 The web reverse-proxy subpath case — flagged

`Uri.base.origin + '/api/v1'` strips path prefixes. Operators
who reverse-proxy Fulfilled under `example.com/fulfilled/` get
the wrong base URL on web. Per §6.3 architect ships v1 with
`Uri.base.origin` only and documents the limitation. **PMgr: is
this acceptable for v1?** My read: yes — the cohort is a
minority; revisit in v1.1 if a customer reports it.

### 10.3 `flutter_secure_storage` as the chosen pub dep

One pub dep added. **PMgr: confirm.** Architect read: necessary
— the alternative (bearer in Hive plaintext) is a downgrade. If
PMgr says no, fallback is `auth_config` Hive storage with a
documented "bearer on disk in plaintext" downgrade.

### 10.4 The dotted-host normalization rule

`normalizeServerUrl` should accept `localhost:8080` /
`192.168.1.5:8080` (no dot, but a port disambiguates) — the
health probe is the final arbiter of reachability. **PMgr
ratification: accept dot-less hosts** as input. Reject only the
truly malformed (no scheme, no dot, no port, no slash).

### 10.5 `Logo` widget hoist

Both `step_1_welcome.dart` and `_LoginBody` render the same
logo. Architect ruled (§5.2) **do not hoist** — v1.1 cleanup.
**PMgr: confirm two-logo drift is acceptable for v1.** Risk: a
future brand update changes one and forgets the other.

### 10.6 The test-file rename

PM §12 named `server_config_provider_test.dart`; architect
renamed the provider to `apiBaseUrlProvider` (per-axis pattern
from `architect_qol.md` §2.1). Test file follows. **PMgr
ratification + update the verification command in `pm_login.md`
§12 to match.**

### 10.7 The `expires_at` field — what if it's present?

**Architect ruling: ignore `expires_at` in v1.** Proactive
expiry-tracking is the gateway drug to refresh-token rotation,
which PM punted. The 401-sweep handles stale tokens. PMgr:
confirm.

---

## 11. Backend ticket ledger updates

This doc adds **BE-008** and **BE-009** to
`specs/backend_tickets_ledger.md` per PM §8. The text below is
the canonical version to drop into the ledger in the same PR as
the client work (the architect-ledger pattern from
`architect_log_edit_and_units.md` and `architect_barcode.md`).

### BE-008 — Canonical login endpoint `POST /auth/login`

**Status**: pending. **Source**: `pm_login.md` §8 BE-008;
`architect_login.md` §3. **Goal**: add `POST /auth/login`
(security: []) that takes `{username, password}` and returns
`{token, expires_at?}` on success or 401 on credential failure.
**Open question**: JWKS-backed IdP pass-through vs. local
`users.password_hash` (argon2id)? Client behaviour is unchanged
either way. **Client workaround**: in place — the login screen
ships a "paste a JWT as the password" disclosure that activates
on 404 from `/auth/login` and flips off when the endpoint
exists. **Blocking impact**: customer-facing self-hosted UX —
without BE-008 the operator mints a JWT out-of-band.
**Acceptance**: 200 returns a bearer that authenticates
subsequent requests; wrong password / unknown username both
return 401 (do not leak existence); endpoint declared in
`openapi.yaml` with `security: []`.

### BE-009 — `/health` canonical mount + CORS confirmation

**Status**: pending. **Source**: `pm_login.md` §8 BE-009;
`architect_login.md` §5.4. **Goal**: confirm `/health` is
mounted under `/api/v1` (so the client probes
`<base>/api/v1/health`) and CORS allows the probe from
arbitrary origins for the web tier. **Verification against
current spec**: `openapi.yaml` line 14 ("All paths are served
under the `/api/v1` prefix") + lines 67–89 read consistently —
`/health` lives under `/api/v1`. The ticket is now
**documentation-only**: confirm runtime matches spec. If
drifted, update either the runtime or the spec to align.
**Client workaround**: none needed if the spec reading is
correct; if not, the probe one-lines to `<originBase>/health`.
**Acceptance**: `GET /api/v1/health` from an arbitrary browser
origin returns 200 + `{status: "ok"}` + permissive
`Access-Control-Allow-Origin`.

---

## 12. Tenant updates

**None.** The login screen fits the existing 24 tenants: T-04
(accent only on "Sign in"), T-08 (button-skeleton during
submit), T-11 (inline errors for all four URL error classes
and credentials), T-14 (`/login` is a route, deep-linkable),
T-15 (form-factor pick at `LoginScreen` root), T-19 (no chart
deps), T-20 (every field has a `Semantics` label; submit reads
"Sign in to <hostname>" if URL present), T-24 Case 2
(`context.go('/today')` post-submit).

The `flutter_ui_architecture.md` `>Addendum applied
2026-05-16` block gains one entry the architect writes in the
same PR as the login screen lands:

> **Addendum applied 2026-05-16 (login pack)** — see
> `specs/architect_login.md`. No new tenant. T-15 form-factor-at-root
> covers the LoginScreen's compact / expanded branch. T-24 Case 2
> covers the post-login `context.go('/today')` navigation; the
> existing wording stands. The base-URL refactor relocates the
> compile-time `--dart-define=API_BASE_URL` read to a runtime
> provider (`apiBaseUrlProvider`); the dev-define survives as a
> debug-only override. Risk 2 in `pm_decisions_flutter_ui.md` is
> superseded — the "I already have an account" link returns on
> onboarding step 1; the architect amends Risk 2 in the same
> change. Backend tickets BE-008 and BE-009 are pending; the
> client ships a workaround for the absence of BE-008 (paste-a-JWT
> disclosure) that flips off cleanly when the endpoint lands.

---

## 13. Files this pack touches

**Net new files — 13** (13 source + 8 tests).

Source:

```
client/lib/providers/api_base_url_provider.dart
client/lib/providers/auth_config_providers.dart
client/lib/data/auth_config_box.dart
client/lib/data/secure_token_store.dart
client/lib/data/login_errors.dart
client/lib/features/login/url_normalize.dart
client/lib/features/login/login_screen.dart
client/lib/features/login/login_controller.dart
client/lib/features/login/widgets/server_url_field.dart
client/lib/features/login/widgets/credentials_form.dart
client/lib/features/login/widgets/login_button.dart
client/lib/features/login/widgets/sign_up_link.dart
client/lib/features/login/widgets/paste_jwt_disclosure.dart
```

Tests:

```
client/test/features/login/login_screen_compact_test.dart
client/test/features/login/login_screen_web_test.dart
client/test/features/login/login_url_validation_test.dart
client/test/features/login/url_normalize_test.dart      (architect-added — §2.4 table)
client/test/routing/auth_redirect_test.dart
client/test/data/auth_config_box_test.dart
client/test/data/api_base_url_provider_test.dart        (renamed from PM §12's server_config_provider)
client/test/features/onboarding/step_1_welcome_link_test.dart
```

Source edits (6):

```
client/lib/data/api_client.dart                              (-_baseUrlFromEnv; +ref.watch; +401-sweep)
client/lib/data/auth_token.dart                              (+signInWithCredentials, +seeded ctor, signOut clears secure store)
client/lib/main.dart                                         (+auth_config + secure-token bootstrap)
client/lib/routing/routes.dart                               (+loginName/loginPath)
client/lib/routing/app_router.dart                           (+/login GoRoute, +redirect, +refreshListenable)
client/lib/features/onboarding/widgets/step_1_welcome.dart   (+"I already have an account" TextButton)
```

Doc edits (3):

```
specs/backend_tickets_ledger.md                  (+BE-008, +BE-009 sections per §11)
specs/pm_decisions_flutter_ui.md                 (Risk 2 addendum reversing the link-removal)
specs/flutter_ui_architecture.md                 (Addendum applied 2026-05-16 (login pack) block)
```

The `url_normalize_test.dart` test is the architect-added pure
function table the §2.4 fixture describes. `grep -rn
'dart-define.*API_BASE_URL' client/` after the pack returns
exactly one hit — the dev-override branch in
`apiBaseUrlProvider`.

---

## 14. Sequencing recommendation

The pack splits cleanly into four PRs. The true dependency
chain is A → B → C → D, with A and B file-disjoint (parallel
from day one) and E (web) absorbed into A + C.

**A. Runtime API base URL refactor (PR 1).** Pure refactor; no
user-visible change. Lands `apiBaseUrlProvider`,
`api_client.dart` rewrite (drop the compile-time const), the
`url_normalize.dart` pure function, and the test-fixture
overrides. The dev-define stays wired so `flutter run
--dart-define=API_BASE_URL=...` still works. Blocker for every
other PR. Risk: low.

**B. `auth_config` Hive box + secure-token store + bootstrap
(PR 2).** Lands the `auth_config_box.dart` schema, the
`secure_token_store.dart` seam, `main.dart`'s parallel-open
extension, the `AuthTokenNotifier.seeded` named ctor + the new
dev-loop trapdoor. Blocker for C and D. Parallelisable with A
(disjoint files). Risk: low.

**C. `LoginScreen` widget + `LoginController` + route
registration (PR 3).** Largest PR. Lands the eight feature
files (screen + controller + six widgets), the `/login` route
(no redirect yet), `signInWithCredentials` + the `LoginError`
hierarchy, the `HealthProbe` seam. Blocker for D. Depends on
both A and B. Risk: medium.

**D. Routing redirect + onboarding link + sign-out extension
(PR 4).** Lands the `redirect` rule + `_AuthListenable`, the
onboarding step 1 link, the `signOut()` extension, the Risk 2
addendum in `pm_decisions_flutter_ui.md`, and the
`flutter_ui_architecture.md` addendum block. Depends on C.
Risk: low.

**E. Web auto-detect** is the `kIsWeb` branch in A's provider
and the `!kIsWeb` field-hide in C's `_LoginBody`. No separate
PR; covered by `login_screen_web_test.dart` inside PR 3.

The realistic shape:

```
PR 1 (A)  --|
            |--> PR 3 (C)  --> PR 4 (D)
PR 2 (B)  --|
```

Three serial-ish phases. PMgr can split PR 1 and PR 2 to two
agents in parallel; merge order doesn't matter. PR 3 waits for
both. PR 4 is the small follow-up.

**Backend ticket sequencing.** BE-008 (POST /auth/login) is
the only wire-blocker. The client ships against the workaround
(§3.6); BE-008 follow-on flips the code path from "paste JWT"
to "type credentials" — the client PR doesn't have to
re-touch any file when BE-008 lands. BE-009 is
documentation-only; no client dependency.

**Total PR count: four** for client work, plus two backend
tickets the backend team picks up async. Two weeks of focused
agent work, give or take.

---

## 15. Acceptance for the entire pack

"The login pack is shipped" means a fresh-install Flutter app
on a brand-new phone, pointed at `https://fulfilled.mydomain.com`
by a customer who runs `docker run fulfilled-server`, opens to
a three-field form, accepts URL + username + password, runs an
8-second `/health` probe, POSTs `/auth/login`, persists the URL
+ last-username in Hive and the bearer in secure storage, and
lands on the Today view — all without any compile-time
`--dart-define`, without any pasted JWT (BE-008 having
shipped), and without any "the URL isn't right" error that
doesn't *name* which class of failure occurred. The web tier
runs the same flow without the URL field. Sign-out clears the
bearer and the outbox; the URL persists; re-login is two
field touches.

The bar for the pack: PM §12's verification commands all pass
(eight `flutter test` invocations on the test files listed in
§13 plus the `grep` for `--dart-define=API_BASE_URL` returning
exactly one hit). Plus the addenda land in
`flutter_ui_architecture.md`, `pm_decisions_flutter_ui.md`, and
`backend_tickets_ledger.md` in the same PRs that ship the
client work. Everything in this doc serves the thirty-second
self-hosted login experience PM scoped.
