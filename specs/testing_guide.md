# Testing Guide — Flutter Client

> A practitioner's manual for the `client/` Flutter app. Read once, refer back when you're writing a new test. For the upstream "what does Flutter actually prescribe" reference, see `specs/flutter_testing_research.md` — this file is the application of that document to *our* code.

---

## 1. TL;DR

We're adopting the standard Flutter pyramid: **many unit tests**, **many widget tests**, **a small number of integration tests**. The widget-test layer is the workhorse — it runs under `flutter test` in a fake-async sandbox with no real network, no real timers, and no real platform channels, so every UI behavioural assertion belongs here unless it specifically needs a real device. Unit tests stay at the bottom for pure-Dart code (domain math, provider derivations, decoders). Integration tests live at the top and stay tiny — three to five flows max — because they're slow, brittle, and only useful for "is the app shaped right end-to-end."

**Two hard rules. Neither is negotiable.**

1. **UI tests never touch real network or disk.** No real `Dio` calls, no real Hive boxes, no real `SharedPreferences`, no real platform channels. Every dependency that does IO sits behind a Riverpod-mediated seam that a test can swap.

2. **Presentation widgets ("leaves") never import Riverpod.** They are pure functions of constructor parameters. A leaf widget test reads `pumpWidget(MyLeaf(data: …, onTap: () {}))` — no `ProviderScope`, no overrides, no setup. Riverpod lives one layer up, in *container* widgets (screens, sheets, dialogs) that read providers and pass plain data + callbacks down to the leaves.

The seams that make rule 1 achievable here: every `Dio` call routes through repositories that accept a `useFixtures: bool` constructor flag for fully in-memory mode, plus a `FakeDioAdapter` (`test/data/fake_dio_adapter.dart`) for wire-shape tests; every Hive box, secure-storage handle, and platform plugin sits behind a `Provider` that **throws** by default and is `overrideWithValue`d in tests. The seam that makes rule 2 achievable: the container/presentation split (§4.4).

If you find yourself reaching for `setMockMethodCallHandler`, constructing a real `Dio` in a widget test, or wrapping a leaf in `ProviderScope` to give it a fake provider, stop: a seam is missing or the leaf is doing too much. The right fix is to add the seam or split the widget, not to plumb around it.

---

## 2. What to test, at what level

| Category | Where it lives | Level | How much | Today's state |
|---|---|---|---|---|
| Pure domain logic | `lib/domain/` (projection model, units, decimal/rounding, calorie estimates, food/serving builders) | Unit | Heavy — one file per logic-bearing module, table tests where the model is approximate (see `weight_projection_sweep_test.dart`) | **Good.** `test/domain/` is the healthiest subtree. Mostly green, no quarantines outside one stray `food_created_at_test.dart`. |
| Repositories | `lib/repositories/` (Dio + Hive seams) | Repo-level | One test file per repo against `FakeDioAdapter`; assertions on **wire shape** (method, path, query, body) and **decoder behaviour** (404 → `FoodNotFoundError`, 409 propagates) | **Mixed.** `_harness.dart` + `goal_repository_test.dart` show the pattern. `food_repository_test.dart` is currently `@Skip`-quarantined post-Ask-10 — the wire shape changed and the tests haven't been rebaselined. `weight_repository`, `goal_repository`, `profile_repository` **do not have** a `useFixtures` flag (food + log do); that's a known gap. |
| Riverpod providers | `lib/providers/` (compute/derive over repos) | Unit | One per derived provider; build a `ProviderContainer`, override deps with `overrideWith` / `overrideWithValue`, read the provider, assert | **Thin.** `test/providers/` has three files. `calories_burned_provider_test.dart` is the canonical shape (overrides upstream `meProvider` + `currentWeightKgProvider`, asserts on the derived value). Many derived providers (`goalProjectionProvider`, the `daySummaryProvider` family, the food list providers) have no provider-level coverage at all — their behaviour is only exercised indirectly through screen tests, which is the wrong level. |
| **Presentation widgets (leaves)** | `lib/features/*/widgets/`, `lib/widgets/` | Widget | One per leaf; mount in `MaterialApp` only; pass data via constructor params; pump, simulate input, assert rendered output. **No `ProviderScope`. No `ConsumerWidget` in leaf source. No `ref.watch`.** | **Currently mixed.** `search_result_row.dart`, `primary_button.dart`, `quantity_stepper.dart` are already presentation-shaped (pure constructor inputs) and their tests are correctly Riverpod-free. ~25 other widgets under `features/*/widgets/` still extend `ConsumerWidget` and must be split (see §4.4). |
| **Container widgets** | `lib/features/*_screen.dart`, sheets, dialogs, top-level views | Widget | One file per screen, covering the happy path + one error/empty branch; provider overrides wired top-down at this layer **only** | **Largely broken.** `today_screen_test.dart`, `onboarding_screen_test.dart`, `food_detail_screen_test.dart`, `search_screen_test.dart`, `weight_screen_test.dart`, `goals_screen_test.dart`, `my_foods_screen_test.dart`, `quick_add_sheet_test.dart`, `log_entry_sheet_test.dart` are all `@Skip`-quarantined. Rebuilding this layer is the biggest open testing investment. |
| Routing | `lib/routing/app_router.dart` | Widget (router-as-system-under-test) | One file per redirect rule + one per `pathFor*` helper | **Healthy.** `auth_redirect_test.dart` is quarantined but the newer `onboarding_redirect_test.dart`, `barcode_resolve_test.dart`, `foods_new_precedence_test.dart`, `path_for_day_test.dart` follow the pattern (override `meProvider` / `authTokenProvider`, build the router, assert on `routerDelegate.currentConfiguration.uri.path`). |
| End-to-end happy paths | (would-be) `integration_test/` | Integration | A handful — `log a food on /today`, `scan a barcode → food detail`, `sign in → onboarding → today`. Real device. | **None.** `client/test/integration/.gitkeep` references "log-a-food, scan-a-barcode" as planned, but no `integration_test/` directory exists. That's a finding, not a silent gap. The team should write the first one alongside the next major UX flow. |

**Honest tally as of today (`grep -l "@Skip" test/ | wc -l`): 64 of 138 test files are quarantined.** That's ~46%. The guide below exists so the rebuild doesn't regenerate the same failure mode (UI tests pinned to fixture strings that drift the moment the wire changes).

---

## 3. The fake-data substrate

### Repositories: the `useFixtures` flag

`FoodRepository` and `LogRepository` accept a `useFixtures: bool` constructor parameter. When true, every method short-circuits an in-memory store seeded from `lib/repositories/_*_fixtures.dart`. Writes mutate the store; reads project from it. There is no `Dio` traffic, no error mapping path, no decoder path.

```dart
// In a test that wants the fixture path:
final repo = FoodRepository(api, useFixtures: true);

// In a test that wants the Dio decoder path:
final repo = FoodRepository(api, useFixtures: false);
```

Production reads `kUseFixtures` (currently `false`); tests **must be explicit** — never rely on the default. The harness helper `buildLiveFoodRepository(api)` and `buildLiveLogRepository(api)` (`test/repositories/_harness.dart`) bake `useFixtures: false` in for you.

**Gap:** `WeightRepository`, `GoalRepository`, `ProfileRepository` do not yet accept this flag — they go straight to Dio. Until that's fixed, any provider/widget test that consumes those repos must either (a) override the **provider** that wraps the repo (`weightRepositoryProvider.overrideWithValue(fake)`) with a hand-written fake or (b) install a `FakeDioAdapter` on the `Dio` instance via `apiClientProvider`. Adding the flag is a small, mechanical change and should happen before the screen-level rebuild kicks off.

### Wire-shape tests: `FakeDioAdapter`

For testing what bytes actually go onto the wire (path, method, query, body, headers, status mapping), use `FakeDioAdapter` (`test/data/fake_dio_adapter.dart`):

```dart
final adapter = FakeDioAdapter((req) => jsonResponse(200, {
  'results': [/* ... */],
  'total': 1, 'limit': 25, 'offset': 0,
}));
final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
  ..httpClientAdapter = adapter;
final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
final repo = FoodRepository(api, useFixtures: false);

await repo.search('yogurt');
expect(adapter.requests.single.path, '/foods/search');
expect(adapter.requests.single.queryParameters['q'], 'yogurt');
```

The real `Dio` runs end-to-end: transformers, interceptors, the 401-sweep handler. Only the byte-level `fetch` is replaced. This is the right seam — not mocking `Dio` itself, not mocking the repository.

Helpers in `fake_dio_adapter.dart`:
- `jsonResponse(int status, Map body)` — JSON body with `content-type` set.
- `emptyResponse(int status)` — empty body for 4xx/5xx assertions.
- `adapter.requests` — every `RequestOptions` seen, in order.

### Resetting between tests

Repositories hold module-private state in fixture mode. Call this in `setUp`:

```dart
import 'repositories/_harness.dart';

setUp(resetRepositoriesForTest);   // calls *.resetForTesting() + setMockLatencyForTesting()
tearDown(teardownRepositoriesForTest);
```

`setMockLatencyForTesting()` collapses the 80–250 ms jittered `mockLatency()` to 0–1 ms so `pumpAndSettle` doesn't burn real-clock time. Without this call, the artificial latency makes widget tests around the loading-state surface flaky and slow.

### Hive: wrap in a notifier, not a direct read

Hive boxes are wrapped in providers that **throw** unless overridden. The pattern lives in `lib/data/auth_config.dart`:

```dart
final authConfigBoxProvider = Provider<Box<String>>((ref) {
  throw UnimplementedError('override in main.dart with the open Hive box');
});

final baseUrlProvider = StateNotifierProvider<BaseUrlNotifier, String?>((ref) {
  return BaseUrlNotifier(ref.watch(authConfigBoxProvider));
});
```

In production, `main.dart` opens the box and installs `authConfigBoxProvider.overrideWithValue(openBox)`. In tests, you have two options, in order of preference:

1. **Override `baseUrlProvider` directly** with a notifier or `overrideWith((ref) => /* notifier */)` if you want to control the value the rest of the app sees, without thinking about Hive at all.
2. **Override `authConfigBoxProvider` with a Hive box opened on a temp dir** if you're specifically testing the box-reads-from-disk path (rare; see `test/data/auth_config_test.dart`).

The same pattern applies to `outboxBoxProvider` (`lib/data/outbox/log_outbox_notifier.dart`) and `secureTokenStoreProvider` (`lib/data/secure_token_store.dart`). For the secure token store, `test/data/fake_secure_token_store.dart` already exists — extend `SecureTokenStore` and override the provider with an instance.

**Anti-pattern:** reading a `Hive.box('foo')` static directly from a widget. There used to be one offender (`login_controller.dart:337`); closed in commit `b89524f`. A repo-wide audit (`specs/persistence_audit.md`, `specs/io_deps_audit.md`) confirms zero direct UI → IO dependencies remain. The corollary under rule 2: even *container* widgets should rarely reach into a raw box — they should read a notifier (`baseUrlProvider`, `lastUsernameProvider`) that internally wraps the box. The box is an implementation detail of the `data/` layer; UI consumes the notifier.

---

## 4. Example tests — one per level

Every example below compiles against real types in this repo. Copy, adapt, ship.

### 4.1 Unit test (domain) — pure logic

Template: `test/domain/weight_projection_test.dart`. The shape: a `group` per behavioural cluster, builder functions hoisted above `main`, and assertions on **value ranges or kinds**, not exact floats (the model itself is approximate).

```dart
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/domain/weight_projection.dart';

void main() {
  // Pin "now" so date arithmetic is deterministic.
  final now = DateTime(2026, 5, 18);
  final birth = DateTime(1990, 1, 1);

  WeightEntry we(int daysAgo, String kg) => WeightEntry(
        id: 'w_$daysAgo',
        recordedOn: DateTime(now.year, now.month, now.day - daysAgo),
        weightKg: Decimal.parse(kg),
        createdAt: now,
      );

  group('projectGoal — state machine', () {
    test('target already reached (within ±0.2 kg) → reached', () {
      final p = projectGoal(
        history: <WeightEntry>[
          we(0, '76.1'), we(7, '76.4'), we(14, '76.7'),
          we(21, '77.0'), we(28, '77.3'),
        ],
        targetKg: Decimal.parse('76.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
      );
      expect(p.kind, ProjectionKind.reached);
      expect(p.eta, isNull);
    });
  });
}
```

Notes: no `MaterialApp`, no `ProviderContainer`, no async. Pure Dart, fast, deterministic. If you can write your test at this level, *do* — every level above is more expensive.

### 4.2 Unit test (provider) — `ProviderContainer` + overrides

Template: `test/providers/calories_burned_provider_test.dart`. Build a `ProviderContainer`, override the upstream providers the SUT depends on, `read` the SUT, assert.

```dart
import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/calorie_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';

void main() {
  test('caloriesBurnedTodayProvider — male sedentary 80 kg 180 cm lands in [2100, 2200]',
      () async {
    final container = ProviderContainer(overrides: <Override>[
      meProvider.overrideWith((_) async => User(
        id: 'u_test',
        sex: Sex.male,
        birthDate: DateTime(1995, 1, 1),
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      )),
      currentWeightKgProvider.overrideWith((_) async => Decimal.parse('80')),
    ]);
    addTearDown(container.dispose);

    // Read the derived FutureProvider via `.future` to await the resolved value.
    final burned = await container.read(caloriesBurnedTodayProvider.future);
    expect(burned >= Decimal.fromInt(2100), isTrue);
    expect(burned <= Decimal.fromInt(2200), isTrue);
  });
}
```

Use `overrideWith` for async/family providers; use `overrideWithValue` for plain `Provider<T>`. Always `addTearDown(container.dispose)` — leaked containers leak listeners.

### 4.3 Repository test (Dio wire shape) — `_harness` + `FakeDioAdapter`

Template: `test/repositories/goal_repository_test.dart` (food repo's equivalent is currently quarantined, but the shape is identical and lives in `food_repository_test.dart` for reference once unblocked).

```dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/repositories/food_repository.dart';

import '../data/fake_dio_adapter.dart';
import '_harness.dart';

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  test('search() — GET /foods/search with q + limit + offset', () async {
    final adapter = FakeDioAdapter((req) => jsonResponse(200, <String, dynamic>{
      'results': <Map<String, dynamic>>[],
      'total': 0, 'limit': 25, 'offset': 0,
    }));
    final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
      ..httpClientAdapter = adapter;
    final repo = FoodRepository(
      ApiClient(dio, baseUrl: 'https://test.example/api/v1'),
      useFixtures: false,
    );

    await repo.search('yog', limit: 25, offset: 0);

    expect(adapter.requests, hasLength(1));
    final req = adapter.requests.single;
    expect(req.method, equalsIgnoringCase('GET'));
    expect(req.path, equals('/foods/search'));
    expect(req.queryParameters['q'], equals('yog'));
    expect(req.queryParameters['limit'], equals(25));
  });
}
```

This is the only place we exercise the Dio path. Everything above it (providers, widgets) sees the repo through `repositoryProviders` — they get a fake repo, not a fake adapter.

### 4.4 Widget test (leaf) — no providers, pure render

**The principle.** A leaf is a `StatelessWidget` (or `StatefulWidget` for purely-local state like a `TextEditingController`) whose only inputs are constructor parameters: plain data + callbacks. It imports nothing from `package:flutter_riverpod`. Its build method does not call `ref.watch` or `ref.read`. Its test sets up a `MaterialApp` for theme + directionality and passes the data in directly:

```dart
await tester.pumpWidget(MaterialApp(home: MyLeaf(data: …, onTap: () {})));
```

**If the leaf you're about to test extends `ConsumerWidget`, split it first.** The split is mechanical. Before:

```dart
class _ProjectionRow extends ConsumerWidget {
  const _ProjectionRow({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projection = ref.watch(goalProjectionProvider);
    if (projection == null) return const SizedBox.shrink();
    return Text(_copyFor(projection));
  }
}
```

After — a pure presentation widget that knows nothing about Riverpod:

```dart
class ProjectionRow extends StatelessWidget {
  const ProjectionRow({super.key, required this.projection});
  final GoalProjection? projection;
  @override
  Widget build(BuildContext context) {
    if (projection == null) return const SizedBox.shrink();
    return Text(_copyFor(projection!));
  }
}
```

…and a thin `Consumer` lifted into the parent container that reads the provider and passes the value down:

```dart
class WeightSummaryCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projection = ref.watch(goalProjectionProvider);
    return Column(children: <Widget>[
      // ...other rows...
      ProjectionRow(projection: projection),
    ]);
  }
}
```

The screen / sheet / dialog at the top of the feature is the container. Every leaf below it consumes data via constructor params. Riverpod stops at the container boundary; nothing past that line knows the framework exists.

**Why this pays off.** The leaf test below uses no `ProviderScope`, no `overrideWithValue`, no provider scaffolding. It can't accidentally hit network or disk because it never sees the seam that could.

Template: `test/features/search/search_result_row_test.dart`. The leaf reads its inputs as constructor arguments, so we don't need a `ProviderScope` — only `MaterialApp` for theme + directionality.

```dart
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/theme/theme_data.dart';

Widget _harness(Widget child) => MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('never-logged row renders "brand · serving" sub-line',
      (tester) async {
    final food = Food(
      id: 'h1',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      source: FoodSource.off,
      isCustom: false,
      servings: <Serving>[Serving(
        id: 'h1_s1', label: '1 cup',
        amount: Decimal.fromInt(245), unit: Unit.g,
        kcal: Decimal.fromInt(130),
        isDefault: true, source: ServingSource.off,
      )],
    );

    await tester.pumpWidget(_harness(SearchResultRow(food: food, query: 'greek')));
    await tester.pump();   // one frame is enough — no animations, no async.

    expect(find.text('Chobani · 1 cup'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('Logged '),
      ),
      findsNothing,
    );
  });
}
```

Notes: one `pump()` — no animation, no `Future.delayed`. If you use `pumpAndSettle` here it works, but it's louder than needed. Save `pumpAndSettle` for transitions and snackbars.

### 4.5 Widget test (container/screen) — `ProviderScope` overrides, top-down

Containers — screens, sheets, dialogs — are the **only** place `ProviderScope` and provider overrides appear in widget tests. The container's job is to read providers, transform `AsyncValue<T>` into renderable state, and pass plain data + callbacks down to its child leaves. The test asserts on the container's branching behaviour (loading → skeleton, error → message, data → real render) by overriding the provider it reads.

Template: the pattern from `test/routing/onboarding_redirect_test.dart`, adapted for a screen with overridden Future-shaped providers. Below is the shape we want the rebuilt `food_detail_screen_test.dart` to follow.

```dart
import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/food_detail/food_detail_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/skeleton.dart';

Food _yogurt() => Food(
      id: 'f_test',
      name: 'Greek yogurt, plain',
      brand: 'Fage',
      source: FoodSource.off,
      isCustom: false,
      servings: <Serving>[Serving(
        id: 'sv_1', label: '1 cup',
        amount: Decimal.fromInt(245), unit: Unit.g,
        kcal: Decimal.fromInt(150),
        isDefault: true, source: ServingSource.off,
      )],
    );

Widget _harness({required List<Override> overrides, required Widget child}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(theme: buildLightTheme(), home: child),
  );
}

void main() {
  testWidgets('loading branch renders Skeleton, never CircularProgressIndicator',
      (tester) async {
    final completer = Completer<Food>();
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(_yogurt());
    });

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        foodDetailProvider('f_test').overrideWith((_) => completer.future),
      ],
      child: const FoodDetailScreen(foodId: 'f_test'),
    ));
    await tester.pump();   // first frame only — the future never completes.

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Skeleton), findsWidgets);
  });

  testWidgets('happy path: pumps a real Food, asserts visible kcal', (tester) async {
    await tester.pumpWidget(_harness(
      overrides: <Override>[
        foodDetailProvider('f_test').overrideWith((_) async => _yogurt()),
      ],
      child: const FoodDetailScreen(foodId: 'f_test'),
    ));
    await tester.pumpAndSettle();   // FutureProvider resolves; the screen rebuilds.

    expect(find.text('Greek yogurt, plain'), findsOneWidget);
  });
}
```

Key moves: `Completer` to park a `FutureProvider` in `AsyncLoading`, `overrideWith((_) async => …)` for the happy-path data, never touch `foodRepositoryProvider` directly — the screen reads the derived provider and that's where we substitute.

For screens that need go_router routing assertions, follow `today_pill_test.dart` (build a real `GoRouter` with the routes the screen pushes to, mount under `MaterialApp.router`, assert on `routerDelegate.currentConfiguration.uri.path` after the tap).

### 4.6 Integration test — recommended starter (none exist yet)

The repo has `client/test/integration/.gitkeep` referencing log-a-food and scan-a-barcode, but no `integration_test/` directory. **This is a future addition.** When we write the first one, structure it like this:

```dart
// integration_test/log_a_food_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:fulfilled/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log a food: open today → search → tap result → log', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // Real device, real Hive, real platform channels, real Dio.
    // Point at a staging API via --dart-define=API_BASE_URL=... at run time.
    await tester.tap(find.byKey(const Key('log-food-fab')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('search-field')), 'yogurt');
    await tester.pumpAndSettle(const Duration(seconds: 1));   // debounce + real network.

    await tester.tap(find.byKey(const Key('search-result-row-0')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('log-entry-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('logged'), findsOneWidget);
  });
}
```

Run: `flutter test integration_test/log_a_food_test.dart`. Three to five of these is the target; resist the urge to grow this to dozens.

---

## 5. Naming, file organization, when to write a test

The Flutter docs don't take a position here. We do:

- **File location mirrors `lib/`.** `lib/features/search/widgets/search_result_row.dart` → `test/features/search/search_result_row_test.dart`. No exceptions.
- **One test file per source file**, except for cross-cutting concerns (e.g. the redirect rules under `test/routing/`) where one file per *behavioural rule* reads better.
- **Test names describe the behaviour asserted, not the method called.** Good: `"projects on-track when trajectory is sustained"`, `"loading branch renders Skeleton, never CircularProgressIndicator"`. Bad: `"projectGoal_returns_onTrack"`, `"build_renders_correctly"`. The reader of a CI failure should be able to tell what's broken from the description alone.
- **Use `find.byKey` whenever a test asserts on tap targets or specific widget instances.** Text and type finders break when copy changes or a second instance of the same widget shows up. The widget should expose a stable `Key` deliberately.
- **Write the test before merging the code.** The recent projection rewrite and the F5/F6 work both shipped with their tests in the same PR — keep that. PRs that add behaviour without tests are the failure mode the F3 audit caught us in.
- **Test-difficulty is a code smell.** If you can't write a test for a widget without mocking five providers or pumping seven times, the widget is doing too much. Split it, lift state, narrow the seam — don't add a sixth mock.

---

## 6. The pre-commit hook

`.githooks/pre-commit` (at the repo root, not `client/`) runs `flutter analyze --fatal-infos --fatal-warnings` against `client/` on every commit. **Info-level lints are fatal.** `require_trailing_commas`, unused imports, dead code — any of these blocks the commit. If your test trips a lint, the commit fails and the test never lands.

`flutter test` is **not** in the pre-commit hook. This is intentional: it keeps the inner loop fast (analyze runs in ~3 s; the full test suite is multiple minutes). The contract is that the engineer runs `flutter test` themselves before pushing, and CI catches anything they missed. If you're rebuilding the quarantined screen tests, run `flutter test test/features/whatever/your_screen_test.dart` locally to confirm green before pushing.

To install the hook: `git config core.hooksPath .githooks`. (One-time, repo-local.)

---

## 7. Anti-patterns to avoid

Each item below has been seen in this repo or is a known failure mode of Flutter widget tests:

- **Don't make a leaf widget a `ConsumerWidget`.** Leaves under `lib/features/*/widgets/` and `lib/widgets/` must be `StatelessWidget` / `StatefulWidget` and take all their inputs as constructor parameters. If you find yourself wanting `ref.watch` inside a leaf, lift that read into the parent container and pass the value down. A leaf importing `package:flutter_riverpod` is the failure mode the §4.4 split exists to prevent.
- **Don't wrap a leaf widget in `ProviderScope` in its test.** If the leaf needs `ProviderScope` to render, the leaf is doing too much. Split it (§4.4). The test should look like `pumpWidget(MaterialApp(home: MyLeaf(data: ..., onTap: () {})))` — nothing more.
- **Don't `await tester.pumpAndSettle()` on a screen with an infinite animation.** `pumpAndSettle` waits until no frames are scheduled; an `AnimationController.repeat()` or a `Lottie` loop will hang it until the 10-minute timeout. Use `pump(Duration(milliseconds: N))` with a known duration instead.
- **Don't construct a repository in a widget test without `useFixtures: true` or a `FakeDioAdapter`.** A `FoodRepository(api)` with the production default hits whatever URL `apiBaseUrlProvider` resolves to — non-deterministic, almost always wrong in tests. Use the provider override; never `new FoodRepository(...)` from a widget test.
- **Don't read Hive, `SharedPreferences`, `FlutterSecureStorage`, or any other concrete persistence API directly from any UI file** — screen *or* leaf. Go through a notifier provider in a container; the leaf takes the resolved value. Audit baseline: `specs/persistence_audit.md` + `specs/io_deps_audit.md` (zero direct UI→IO deps as of `b89524f`).
- **Don't reach into private state via `#__internal__` or reflection.** If you need a hook for tests, add a deliberate public seam. `setMockLatencyForTesting()` and `@visibleForTesting List<TextSpan> highlightSpansForTest(...)` are the right patterns.
- **Don't un-skip the `@Skip('Quarantined post Ask 10 …')` tests.** They were testing implementation details (rendered kcal strings, fixture-mode counts) pinned to a wire shape that no longer holds. Un-skipping them as-is will produce green tests that lie about the code. Replace them — write a fresh test that asserts a behaviour the code under test actually upholds today.
- **Don't mock `Dio` itself.** The interceptor stack (auth header, 401-sweep, error mapping) is part of the system under test for repo tests. Swap `dio.httpClientAdapter` instead.
- **Don't use `await for` over a stream inside `testWidgets`.** Fake async deadlocks. Use `expectLater(stream, emitsInOrder([...]))`.
- **Don't put `Image.network` in a widget under test without an `ImageProvider` seam.** It hangs forever (no real network). Either swap to `Image.asset` in production, or accept an `ImageProvider` parameter and inject a fake.
- **Don't read `DateTime.now()` from a leaf** if the rendered output depends on it ("logged 3 minutes ago"). The container computes "now" and passes it in as a parameter, or passes the already-formatted string. The leaf is pure.

---

## 8. Open questions for the team

These need a decision and a written-down answer (in this file, in `AGENTS.md`, or in an ADR — wherever the rest of the team is most likely to find it):

1. **Golden tests — yes or no?** We have none. Flutter's golden support is bit-exact and platform-fragile; community packages (`alchemist`, `golden_toolkit`) layer tolerance on top. If we want them, we need to (a) pin them to one CI platform (Linux), (b) load real fonts via `flutter_test_config.dart`, and (c) decide which components are stable enough to be worth pinning visually (probably: design-system buttons, the calorie ring, the macro bar — almost certainly not full screens).
2. **`mocktail` vs hand-written fakes.** We're 100 % hand-written fakes today (see `_FakeProfileRepository`, `_FakeGoalRepository`, `FakeSecureTokenStore`). Mocktail adds null-safe stubbing without codegen, which is useful for repos with wide interfaces. Pick one, write it into the guide, don't mix.
3. **Integration tests — do we want any?** The directory's empty and the `.gitkeep` lists candidate flows. Cost: a real device or emulator in CI. Benefit: catches platform-channel regressions widget tests can't. Recommendation: start with one (sign-in → onboarding → today on Android), see if it pays for itself.
4. **The 64 quarantined files — rebuild plan?** Today they sit as dead weight. Two options: (a) bulk-delete and rewrite from scratch as we touch each feature; (b) keep them as a TODO list and convert one per PR. Option (a) is honest; option (b) leaves a misleading test directory. PM call needed.
5. **`useFixtures` on weight/goal/profile repos.** Adding the flag is mechanical (~30 min per repo) and unblocks clean provider/widget tests for the screens that consume them. Schedule it before the screen-level rebuild, or accept that the rebuild will use Dio adapters everywhere.
