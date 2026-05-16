# v1 Finishup — Frontend Tasks

The server's v1 finishup batch (sixteen tasks on
`worktree-pm-v1-finishup`, ratified in
`server/specs/v1_finishup_design.md`) closes the v1 wire surface. Six
feature areas land: paginated envelopes on `GET /log` and `GET
/weights`, a new `GET /foods/mine`, two new log conveniences (`POST
/log/quick_add`, `POST /log/copy`), a JWKS authenticator replacing
dev-bypass, and `DELETE /me`.

The client at `client/lib/` is **mock-backed.** Every repository in
`client/lib/repositories/` runs against the in-memory fixtures in
`client/lib/repositories/_fixtures.dart`; the `ApiClient` at
`client/lib/data/api_client.dart` is constructed by Riverpod but no
method on it is called. The TODO at `api_client.dart:7-12` notes an
openapi-generator config that hasn't landed; `client/lib/data/dtos/` is
empty. Codegen is the prerequisite for every per-endpoint task below.

**Branch:** `worktree-pm-v1-finishup`.
**Canonical contract:** `server/specs/openapi.yaml` (v0.1.0).
**Architect design:** `server/specs/v1_finishup_design.md`.
**Server task list:** `server/specs/v1_finishup_tasks.md` (T01–T16;
T13–T15 are async export, out of scope here).

---

## Section 0 — Infrastructure prerequisite

### FE-01: Land the openapi-generator config and generate DTOs

**Backend reference:** T16; `server/specs/openapi.yaml`.
**Estimated size:** L.
**Depends on:** none.

**What changes on the wire.** Nothing — client-side codegen pickup.

**What the client does today.** DTOs are hand-rolled per repo
(`Food.fromJson` in `client/lib/domain/food.dart`, `LogEntry.fromJson`
in `client/lib/domain/log_entry.dart`, similarly for `Weight`,
`Serving`, `User`, etc.). `client/lib/data/dtos/` exists and is empty.

**What the client needs to do.**
- [ ] Pick a generator. Recommended: `openapi-generator-cli` with the
      `dart-dio-next` template (the project already depends on `dio`).
- [ ] Add a pinned config + a `dart run` / `make codegen` invocation.
- [ ] Consume `server/specs/openapi.yaml` via a project-relative path.
- [ ] Output to `client/lib/data/dtos/`. Decide: check the generated
      files in or `.gitignore` them — **flag for team lead.**
- [ ] Map `Decimal` to the Dart `Decimal` package, **not** `double`.
      Likely needs a per-field mapping or a custom string reader.
- [ ] Prove it on `WeightRepository` (smallest surface) — swap one
      DTO and run the existing tests in `client/test/repositories/`.
- [ ] Document the regen command somewhere visible.

**Acceptance criteria.**
- Codegen produces DTOs for every `openapi.yaml` schema.
- All decimal fields round-trip via `Decimal`.
- `WeightRepository` compiles + tests pass against generated DTOs.

**Risks / gotchas.**
- Dart-Dio templates render `Decimal` as `num` or `String` by default
  — verify before generating wholesale.
- `oneOf: [Enum, null]` nullable enums and `allOf`-based pagination
  envelopes generate poorly. Hand-roll wrappers where the generator
  fights you. FE-02 hand-rolls the `Paginated<T>` wrapper deliberately.

---

## Section 1 — Pagination contract

### FE-02: Introduce a `Paginated<T>` Dart wrapper

**Backend reference:** T01–T06; new `Paginated` schema family at
`openapi.yaml:1160-1204`.
**Estimated size:** S.
**Depends on:** none.

**What changes on the wire.** Every paginated endpoint now responds
with `{ "results": [...], "total": int, "limit": int, "offset": int }`.
All four fields are required.

**What the client does today.** No `Paginated` type. Repositories
return bare `List<T>` (`FoodRepository.search` → `List<Food>`;
`WeightRepository.history` → `List<WeightEntry>`;
`LogRepository.entriesForDate` → `List<LogEntry>`). No `total` is
exposed anywhere.

**What the client needs to do.**
- [ ] Add `client/lib/domain/paginated.dart`: generic immutable
      `Paginated<T>` with `results`, `total`, `limit`, `offset` plus
      `Paginated.fromJson(json, decode)` and a `hasMore` getter.
- [ ] Unit tests at `client/test/domain/paginated_test.dart` covering
      boundary cases for `hasMore`.

**Acceptance criteria.**
- Decodes the OpenAPI envelope.
- `hasMore` correct on the equality boundary
  (`results.length + offset == total` → `false`).
- Consumed by FE-03, FE-04, FE-05.

**Risks / gotchas.**
- Don't generate from the OpenAPI `Paginated` base — `allOf` codegen is
  fragile. Hand-roll the wrapper; let codegen produce the inner items.
- Cursor pagination might land later; keep the wrapper opaque enough
  to swap the next-page mechanism without changing call sites.

### FE-03: Wire `FoodRepository.search` and add `FoodRepository.mine`

**Backend reference:** T01–T02; `GET /foods/search` and new `GET
/foods/mine` at `openapi.yaml:294-361`.
**Estimated size:** M.
**Depends on:** FE-01, FE-02.

**What changes on the wire.**
- `GET /foods/search?q=&limit=&offset=` → 200 `PaginatedFoodSearchHits`.
  Default `limit=100`, max `500`. Blank `q` → 400. Sentinel
  `__quick_add__` foods filtered out server-side.
- `GET /foods/mine?q=&limit=&offset=` (new) → 200
  `PaginatedFoodSearchHits` over the caller's `source=user` foods.
  Optional `q` substring (max 200 chars); empty/whitespace = absent.

**What the client does today.** `FoodRepository.search`
(`client/lib/repositories/food_repository.dart:60-84`) walks the
in-memory `_foods` fixture and returns `List<Food>`.
`FoodRepository.customFoods` (lines 233-239) does the equivalent of
`/foods/mine` client-side. Both return full `Food` records rather than
`FoodSearchHit`s.

**What the client needs to do.**
- [ ] Change `FoodRepository.search` to return
      `Future<Paginated<FoodSearchHit>>` and call `GET /foods/search`.
- [ ] Rename `customFoods` → `mine({String? q, int limit = 100, int
      offset = 0})` returning `Future<Paginated<FoodSearchHit>>`.
- [ ] Drop the local mirror in `customFoodCount` and read `mine().total`
      directly.
- [ ] Update `myFoodsProvider` and `foodSearchProvider` in
      `client/lib/providers/food_providers.dart` to consume `Paginated`
      (unwrap `.results` for callers that want a flat list).
- [ ] Update tests under `client/test/repositories/` and
      `client/test/providers/`.

**Acceptance criteria.**
- Search and My Foods screens render identical hits on the happy path.
- Empty `q` returns empty without hitting the network.
- `customFoodCount == mine().total`.
- Sentinel never appears.

**Risks / gotchas.**
- Server clamps `limit > 500` silently. Verify `hasMore` still tracks
  correctly when the response `limit` differs from the requested one.
- `q.len() > 200` returns 400 on `/foods/mine`; bound the
  My Foods filter input to 200 chars.

### FE-04: Migrate `LogRepository.entriesForDate` to paginated `GET /log`

**Backend reference:** T03–T04; `GET /log` at `openapi.yaml:586-640`.
**Estimated size:** M.
**Depends on:** FE-01, FE-02.

**What changes on the wire.**
- `GET /log?from=&to=&limit=&offset=` → 200 `PaginatedLogEntries`.
  `from`/`to` now **optional** (was required); no params → 100
  most-recent rows across full history. `from > to` → 400. Default
  `limit=100`, max `500`. Wire break for any prior client.

**What the client does today.**
`LogRepository.entriesForDate(date)`
(`client/lib/repositories/log_repository.dart:66-76`) filters the
in-memory `_state` and returns `List<LogEntry>` sorted newest-first.
`daySummary` (lines 84-92) composes off this.

**What the client needs to do.**
- [ ] Change `entriesForDate` to issue `GET /log?from=date&to=date&limit=500`,
      unwrap to `List<LogEntry>`, log a warning if `hasMore`.
- [ ] Add `LogRepository.list({from?, to?, limit, offset})` returning
      `Paginated<LogEntry>` for the open-ended history case + FE-09's
      copy-day pre-read.
- [ ] Preserve `createdAt DESC` post-sort for parity with the day view.
- [ ] Update tests in `client/test/repositories/log_repository_test.dart`.

**Acceptance criteria.**
- Day view renders identical entries on the happy path.
- Empty days render the empty state without erroring.
- `from > to` on `list()` surfaces 400 cleanly.

**Risks / gotchas.**
- Wire `LogEntry` flattens the nutrition snapshot; existing
  `LogEntry.fromJson` (`client/lib/domain/log_entry.dart:85-107`)
  already handles this — verify with the generated DTO.
- `food_name` / `serving_name` are **not** on the wire. Today's mock
  fills them from the same fixture; the live client needs a hydration
  strategy (foods cache via a future LRU, or accept null at render
  time and lazy-fetch). **Flag for design.**
- The outbox path (`client/lib/data/outbox/`) and `adoptOptimistic`
  (`log_repository.dart:234-237`) inject optimistic rows into `_state`;
  that path must still work when source-of-truth becomes the server.

### FE-05: Migrate `WeightRepository.history` to paginated `GET /weights`

**Backend reference:** T05–T06; `GET /weights` at `openapi.yaml:138-191`.
**Estimated size:** M.
**Depends on:** FE-01, FE-02.

**What changes on the wire.** Same envelope as FE-04. `from > to` now
returns 400 (new for `/weights`).

**What the client does today.**
`WeightRepository.history({limit})`
(`client/lib/repositories/weight_repository.dart:56-62`) returns the
top-`limit` newest entries from `_state` as `List<WeightEntry>`.
`series(range)` (lines 45-52) computes the chart series client-side
from the full history. `mostRecentKg()` (lines 108-113) is
**synchronous** and read by `ProfileRepository.me`.

**What the client needs to do.**
- [ ] Change `history` to issue `GET /weights?limit=$limit` and
      unwrap `.results`.
- [ ] Add `list({from?, to?, limit, offset})` returning
      `Paginated<WeightEntry>` for the chart's full-history pull.
- [ ] Make `mostRecentKg()` async (`list(limit: 1)`); update
      `ProfileRepository.me` to `await` it.
- [ ] Update tests in `client/test/repositories/weight_repository_test.dart`.

**Acceptance criteria.**
- Screen 06 (chart + history) paints identical data.
- 7-day moving avg draws for every point with 6 predecessors in the
  fetched window.
- `from > to` surfaces 400.

**Risks / gotchas.**
- Heavy users may exceed the 500-row cap on the chart's full-history
  pull. Auto-paging or "show last N years only" is a v2 problem;
  document the risk.
- `mostRecentKg` going async ripples through `ProfileRepository.me` —
  watch any sync-derived UI state.

### FE-06: Pagination UX — infinite scroll vs explicit pagination

**Backend reference:** N/A — UX policy.
**Estimated size:** S (policy); M (implementation).
**Depends on:** FE-03, FE-04, FE-05 (any one).

**What changes on the wire.** Nothing.

**What the client does today.** No pagination affordance anywhere;
fixtures fit on one page.

**What the client needs to do.**
- [ ] **Flag for design.** Recommendation: infinite scroll for `My
      foods`, `Search results`, future `Log history` / `Weight history`.
- [ ] Build a reusable `PagedListView<T>` in `client/lib/widgets/`
      backed by `AsyncNotifier`. Takes a "load next page" callback
      returning `Future<Paginated<T>>`.
- [ ] Apply to `My foods` first (`client/lib/features/my_foods/`).
- [ ] Defer porting search + weight history until the widget is proven.

**Acceptance criteria.**
- My Foods auto-loads page 2 on scroll near the bottom.
- Mid-scroll network failure surfaces a retry affordance.
- Widget reusable across ≥3 call sites without modification.

**Risks / gotchas.**
- Riverpod `family` providers don't compose well with infinite-scroll
  state. Centralise in an `AsyncNotifier` rather than per-page family
  keys.

---

## Section 2 — `POST /log/quick_add`

### FE-07: Add quick-add repository method and reserved-name guard

**Backend reference:** T07–T08; `POST /log/quick_add` at
`openapi.yaml:642-666`; `QuickAddBody` at `openapi.yaml:1095-1107`;
reserved-name guard at
`server/crates/loseit-core/src/service/food.rs:157-167`.
**Estimated size:** M.
**Depends on:** FE-01.

**What changes on the wire.** New endpoint.
- `POST /log/quick_add` body `{ calories_kcal: Decimal (>0, <9999),
  meal: Meal, consumed_on: date, note?: string }` → 201 `LogEntry`.
- Macros are **null** on the snapshot; only `calories_kcal` carries a
  value. The entry references an auto-provisioned per-user sentinel
  food (`__quick_add__`) and its synthetic 100g serving.
- Server hides the sentinel from `/foods/search`, `/foods/mine`,
  `/foods/recent`, `/foods/frequent` — no client filter needed.
- `POST /foods` with `name == "__quick_add__"` returns 400 `"name is
  reserved"`.

**What the client does today.** No quick-add. `LogRepository.create`
(`log_repository.dart:110-134`) requires `foodId` + `servingId`.

**What the client needs to do.**
- [ ] Add a `QuickAddCreate` value class
      (`client/lib/domain/log_entry.dart` or sibling) with `caloriesKcal`,
      `meal`, `consumedOn`, optional `note`, plus `toJson()`.
- [ ] Add `LogRepository.quickAdd(QuickAddCreate) → Future<LogEntry>`
      issuing the POST. On success, invalidate
      `daySummaryProvider(consumedOn)` and `logEntriesProvider(consumedOn)`.
- [ ] Client-side validate `caloriesKcal > 0 && < 9999` before posting
      so the round-trip is avoided on obvious bad input.
- [ ] In the custom-food form (`client/lib/features/custom_food/`),
      reject `name == "__quick_add__"` inline before posting.

**Acceptance criteria.**
- POST body correct; returned snapshot has null macros.
- Custom-food form blocks the reserved name with an inline error.

**Risks / gotchas.**
- The cap is strict less-than `9999`. The OpenAPI schema says
  `maximum: 9998`. Use `< Decimal.fromInt(9999)`.
- `NutritionSnapshot.fromJson` (`client/lib/domain/nutrition.dart`)
  must tolerate null macros — verify.

### FE-08: Quick-add UI affordance and screen wiring

**Backend reference:** Same as FE-07.
**Estimated size:** M.
**Depends on:** FE-07.

**What changes on the wire.** Nothing.

**What the client does today.** `quick_add_chips.dart` in
`client/lib/features/today/widgets/` binds to frequently-logged *foods*,
not raw kcal. The FAB (`log_food_fab.dart`) opens the
food-search/log-entry sheet. No raw-kcal path.

**What the client needs to do.**
- [ ] Decide placement — FAB sub-menu, second FAB, or a toggle inside
      the log-entry sheet. **Flag for design.**
- [ ] Build the quick-add sheet (probably reusing
      `client/lib/features/log_entry/log_entry_sheet.dart`). Fields:
      calorie input, meal, consumed-on date, optional note.
- [ ] On submit call `LogRepository.quickAdd`, invalidate the day
      providers, pop the sheet, toast.
- [ ] Add a presentational override for quick-add entries in the
      day-view's `FoodRow` — display "Quick add · 350 kcal" instead of
      the literal sentinel name. Add `LogEntry.isQuickAdd` getter.
      **Copy / icon flag for design.**

**Acceptance criteria.**
- ≤5 taps from FAB to a logged entry.
- Day-summary kcal updates immediately; macro bars don't shift (macros
  null).
- Out-of-range input rejected client-side with inline error.

**Risks / gotchas.**
- The day-view's `FoodRow` assumes every entry has a real food name;
  branch on `isQuickAdd` rather than parsing the sentinel name in
  multiple places.

---

## Section 3 — `POST /log/copy`

### FE-09: Add `LogRepository.copyDay` and `CopyDayCreate` types

**Backend reference:** T09–T10; `POST /log/copy` at
`openapi.yaml:668-700`; `CopyDayBody` at `1109-1119`; response at
`1121-1127`.
**Estimated size:** S.
**Depends on:** FE-01.

**What changes on the wire.** New endpoint.
- `POST /log/copy` body `{ from_date, to_date, meal? }` → 201
  `{ copied: LogEntry[] }`. Same-day and backward (`from > to`) copies
  both legal.
- Server re-snapshots from the **current** food, not the source-day's
  frozen snapshot. Custom-food edits between dates are reflected.
- Server **silently skips** entries whose food / serving was deleted;
  `copied.length` may be less than source-day count.
- Response is **wrapped** (`{ copied: ... }`), not a bare array.

**What the client does today.** No copy-day support.

**What the client needs to do.**
- [ ] Add `CopyDayCreate` value class with `fromDate`, `toDate`,
      optional `meal`, plus `toJson()`.
- [ ] Add `LogRepository.copyDay(CopyDayCreate) → Future<List<LogEntry>>`
      issuing the POST; unwrap `response['copied']`.
- [ ] On success invalidate `daySummaryProvider(toDate)` and
      `logEntriesProvider(toDate)`.
- [ ] Return enough info that the UI can show "Copied N of M" when
      skipped > 0 (either pre-read source-day count via
      `entriesForDate(fromDate)` or pass it through from the caller).

**Acceptance criteria.**
- `copyDay(from: yesterday, to: today)` creates today entries mirroring
  yesterday's current-nutrition state.
- Same-day copy duplicates entries.
- Skipped entries reduce `copied.length` without erroring.

**Risks / gotchas.**
- `from > to` is **legal** — don't reject it client-side.
- Decode `data['copied']`, not `data` — wrapped response.

### FE-10: Copy-day UI affordance and confirmation flow

**Backend reference:** Same as FE-09.
**Estimated size:** M.
**Depends on:** FE-09.

**What changes on the wire.** Nothing.

**What the client does today.** No copy-day affordance.

**What the client needs to do.**
- [ ] Pick a surface. Candidates: meal-section header ("Copy meal from
      another day", per-meal scoping), day-view overflow ("Copy entire
      day from..."), history-screen long-press. **Flag for design —
      pick one or two for v1.**
- [ ] Build a "pick source date" picker. Reuse the history screen if
      it exists; a simple date picker filtered to dates with entries
      will do otherwise.
- [ ] On submit call `LogRepository.copyDay`. Surface a confirmation:
      - "Copied N entries" when `copied.length == expectedCount`.
      - "Copied N of M — M-N skipped (deleted food / serving)"
        otherwise. **Copy flag for content.**
- [ ] Document re-snapshot semantics ("uses the food's current
      nutrition") in help text or the confirm dialog. **Design call —
      may not need to surface.**
- [ ] In the confirm dialog, show destination day's existing entry
      count so the user knows the copy *adds*, not replaces.

**Acceptance criteria.**
- ≤5 taps from day view to a copied day.
- Skip-silent surfaced when applicable.
- Destination totals refresh immediately.

**Risks / gotchas.**
- Quick-add entries copy fine (sentinel food is stable); the FE-08
  presentational override handles their display in the destination day.
- Copying onto a day with existing entries adds, doesn't replace —
  surface the existing-entry count or users will accidentally
  double-log meals.

---

## Section 4 — JWKS authenticator

### FE-11: OIDC sign-in flow and token acquisition

**Backend reference:** T11;
`server/crates/loseit-api/src/auth/jwks.rs`; PM decision is
**provider-agnostic** (`v1_finishup_design.md:11`). Server env vars:
`OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`,
`OIDC_JWKS_CACHE_TTL_SECS`.
**Estimated size:** L.
**Depends on:** none (parallel-safe with FE-01).

**What changes on the wire.** No endpoint changes. The server validates
`Authorization: Bearer <jwt>` against a configured JWKS. The token
must:
- Be `RS256/RS384/RS512/ES256/ES384` — never `HS*` or `none`.
- `iss` matches `OIDC_ISSUER` exactly.
- `aud` contains `OIDC_AUDIENCE` (string or array).
- Valid `exp`, `nbf`, `iat` (60s leeway).
- Optional `email`, `name` pre-fill the user row on first sight.

**What the client does today.** Dev-bypass. Token comes from
`--dart-define=DEV_AUTH_TOKEN` (defaults to `dev-bypass` in debug),
stored in `AuthTokenNotifier`
(`client/lib/data/auth_token.dart:26-75`), attached as `Bearer ...` by
the Dio interceptor (`client/lib/data/api_client.dart:48-58`). No
sign-in screen, no refresh, no storage.

**What the client needs to do.**
- [ ] **Pick an OIDC provider.** Auth0 / AWS Cognito / Firebase Auth /
      Keycloak all work server-side. **Flag for product.**
- [ ] Add `flutter_appauth` (or a provider-specific SDK) for the
      authorization-code + PKCE flow.
- [ ] Build the sign-in screen replacing / augmenting
      `client/lib/features/onboarding/`. Single "Sign in" button →
      system browser → redirect back with `(id_token, access_token,
      refresh_token)`.
- [ ] Persist tokens in `flutter_secure_storage` (Keychain /
      EncryptedSharedPreferences). Never plaintext shared prefs.
- [ ] Replace `AuthTokenNotifier._seedToken`
      (`auth_token.dart:35-40`) to read from secure storage on boot.
      Keep `--dart-define=DEV_AUTH_TOKEN` as a debug-build escape hatch.
- [ ] Implement refresh: on 401, check `exp`, exchange refresh token,
      retry the original request. On refresh failure, drop to sign-in.
- [ ] Wire `AuthTokenNotifier.signOut` (`auth_token.dart:60-67`) to
      also clear secure storage + call provider revocation if
      available.

**Acceptance criteria.**
- User signs in; bearer token attaches to every API request.
- 401 mid-session triggers refresh; refresh failure routes to sign-in.
- Sign-out clears token, outbox, and secure storage.
- Debug builds still support dev-bypass via `--dart-define`.

**Risks / gotchas.**
- `iss` must match byte-for-byte; Auth0 issuers end with `/`, some
  configs don't — verify against a real token.
- Algorithm whitelist excludes `HS*` / `none`; most public providers
  default to `RS256` but verify.
- Token-refresh races are easy to get wrong. Queue concurrent requests
  behind a single in-flight refresh `Future`.
- Dev-bypass and JWKS coexist server-side; the client picks via
  `--dart-define`, not a runtime toggle.

### FE-12: 401 vs 503 routing in the API client interceptor

**Backend reference:** T11; error mapping in
`server/crates/loseit-api/src/error.rs`.
**Estimated size:** S.
**Depends on:** FE-11 partially (can land defensively earlier).

**What changes on the wire.** 401 means "token rejected" (real
semantics now). 503 means "JWKS upstream failure" — retryable, not a
sign-out signal.

**What the client does today.** The Dio interceptor attaches the
bearer token but has no error handler. No central 401 routing.

**What the client needs to do.**
- [ ] Add an error interceptor. On 401: attempt refresh; on failure
      `signOut()` + route to sign-in. On 503: surface a global
      "service unavailable" banner via a Riverpod provider; do not
      sign out.
- [ ] Other 4xx/5xx pass through as `DioException` for repository
      handlers; introduce an `ApiError` umbrella for everything not
      already typed (`FoodNotFoundError`, `LogEntryNotFoundError`).

**Acceptance criteria.**
- A 401 triggers exactly one sign-out + redirect regardless of how
  many requests were in flight.
- A 503 surfaces a single global banner.
- Repos still see typed `*NotFoundError` on 404s.

**Risks / gotchas.**
- Dio interceptors can re-trigger themselves on retry; guard against
  infinite refresh loops.
- `client/lib/data/connectivity.dart` likely already shows a
  network-down banner; merge with the 503 banner so the user sees one
  message.

---

## Section 5 — `DELETE /me`

### FE-13: Add `ProfileRepository.deleteAccount` method

**Backend reference:** T12; `DELETE /me` at `openapi.yaml:124-136`.
**Estimated size:** S.
**Depends on:** FE-01.

**What changes on the wire.** New verb.
- `DELETE /me` → 204. Cascades across log entries, weights, goals,
  custom foods, export jobs.
- **Subtle:** subsequent `GET /me` with the *same* token returns a
  freshly-provisioned user row (auth middleware re-resolves on every
  request and auto-provisions). "Deleted" does not mean "future
  requests 401".

**What the client does today.** `ProfileRepository`
(`client/lib/repositories/profile_repository.dart`) only exposes
`me()` and `update(UserPatch)`.

**What the client needs to do.**
- [ ] Add `ProfileRepository.deleteAccount() → Future<void>` issuing
      `DELETE /me`. Complete on 204; surface 401/500 as typed errors.
- [ ] Keep the method narrow — no sign-out, no navigation. That's
      FE-14's job.
- [ ] Test in `client/test/repositories/profile_repository_test.dart`.

**Acceptance criteria.**
- Returns successfully on 204.
- Typed surfaces on 401 / 500.

**Risks / gotchas.**
- Don't auto-sign-out inside the repo — layering violation.

### FE-14: "Delete my account" affordance and post-delete flow

**Backend reference:** Same as FE-13.
**Estimated size:** M.
**Depends on:** FE-11, FE-13.

**What changes on the wire.** Nothing.

**What the client does today.** Profile screen
(`client/lib/features/profile/profile_screen.dart`) has a sign-out row
but no delete affordance.

**What the client needs to do.**
- [ ] Add a destructive "Delete my account" settings row, ideally in
      a "Danger zone" section under the existing settings card.
      **Flag for design.**
- [ ] Destructive `AlertDialog` confirmation with unambiguous copy
      ("permanently deletes all your logs, weights, custom foods, and
      goals"). Consider requiring typed "DELETE" confirmation.
      **Flag for design.**
- [ ] On confirm: `ProfileRepository.deleteAccount` → on success
      `AuthTokenNotifier.signOut` → invalidate every Riverpod provider
      caching user state → route to welcome/onboarding.
- [ ] On failure: surface inline; do not sign out.

**Acceptance criteria.**
- ≤3 taps from profile to deletion, with one explicit destructive
  confirmation.
- Post-delete: welcome screen, all caches empty, outbox cleared.
- Delete failure leaves the user signed in with data intact.

**Risks / gotchas.**
- Pending outbox entries get dropped on the floor by the sign-out.
  Acceptable (the user wanted everything gone); don't try to flush
  the outbox first (would 401 because the server already deleted the
  user).
- A user who deletes-then-re-signs-in with the same OIDC identity
  gets a fresh empty row. Verify the app handles "I just signed in
  and have zero data" gracefully — onboarding should re-run.

---

## Summary

### Task inventory (14 total: 3 S, 8 M, 3 L)

| ID | Title | Size | Section |
|---|---|---|---|
| FE-01 | Land openapi-generator config + DTOs | L | Prerequisite |
| FE-02 | `Paginated<T>` Dart wrapper | S | Pagination |
| FE-03 | `FoodRepository.search` + `.mine` | M | Pagination |
| FE-04 | Paginate `LogRepository.entriesForDate` | M | Pagination |
| FE-05 | Paginate `WeightRepository.history` | M | Pagination |
| FE-06 | Infinite-scroll widget | M | Pagination |
| FE-07 | Quick-add repo + reserved-name guard | M | Quick-add |
| FE-08 | Quick-add UI | M | Quick-add |
| FE-09 | `LogRepository.copyDay` | S | Copy-day |
| FE-10 | Copy-day UI | M | Copy-day |
| FE-11 | OIDC sign-in flow | L | JWKS auth |
| FE-12 | 401 vs 503 interceptor | S | JWKS auth |
| FE-13 | `ProfileRepository.deleteAccount` | S | Account delete |
| FE-14 | Delete-account UI | M | Account delete |

### Dependency graph

```
FE-01 (codegen) ─┬─> FE-03 ─┐
                 ├─> FE-04 ─┤
                 ├─> FE-05 ─┼─> FE-06 (paged list widget)
                 ├─> FE-07 ──> FE-08
                 ├─> FE-09 ──> FE-10
                 └─> FE-13 ──┐
                             │
FE-02 (Paginated<T>) ────────┘ (consumed by FE-03/04/05)

FE-11 (sign-in) ──> FE-12 (401/503 routing)
                └─> FE-14 (needs sign-out wired)
FE-13 ────────────> FE-14
```

Critical-path length: **3 tasks** (e.g. FE-01 → FE-07 → FE-08, or
FE-11 → FE-13/FE-14).

### Recommended execution order

1. **FE-01 first.** Every per-endpoint task depends on it; don't
   parallelise wiring before codegen settles.
2. **FE-02 in parallel with FE-01.** Independent, small.
3. **FE-11 starts in parallel with FE-01.** Sign-in is a long spike
   on a separate code path; pick the OIDC provider first.
4. **After FE-01 + FE-02**, fan out FE-03 / FE-04 / FE-05 in parallel.
5. **FE-06** gates on any one of FE-03/04/05; land widget against My
   Foods first.
6. **FE-07 → FE-08, FE-09 → FE-10, FE-13 → FE-14** are independent
   pairs and can interleave with the pagination wave.
7. **FE-12** can land any time after FE-11's sign-in shape is decided.

Reasonable two-week shape: week 1 lands FE-01, FE-02, sign-in spike;
week 2 fans out pagination + new endpoints; sign-in + FE-14 close out
end of week 2.

### Open questions

1. **OIDC provider (FE-11).** Auth0, Cognito, Firebase, Keycloak —
   server is agnostic but the client must pick one. Affects cost, ops
   burden, DX. **Biggest decision in the batch.**
2. **Quick-add UI placement (FE-08).** FAB sub-menu, second FAB, or
   toggle inside the log-entry sheet?
3. **Copy-day UI placement (FE-10).** Meal-section header, day-view
   overflow, history long-press? Pick one or two surfaces.
4. **Skip-silent surfacing (FE-10).** When `copied.length <
   source.length`, how forcefully do we tell the user?
5. **Re-snapshot semantics (FE-10).** Worth a one-liner in the
   confirm dialog, or assumed?
6. **Delete-account confirmation (FE-14).** Single tap, double tap,
   or typed "DELETE"?
7. **Foods cache / `food_name` hydration (FE-04).** Wire `LogEntry`
   has no food name. Resolve via per-row `FoodRepository.get` (N
   round-trips), client-side LRU, or server-side denormalisation (out
   of scope)? Cleanest is the LRU.
8. **Pagination policy (FE-06).** Infinite scroll (recommended) vs
   explicit page buttons.

End of hand-off. Pick up at FE-01.
