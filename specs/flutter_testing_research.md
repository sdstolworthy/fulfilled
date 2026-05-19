# Flutter Testing — Canonical Reference (from docs.flutter.dev)

> Audience: a downstream agent auditing a Flutter + Riverpod + Dio app whose UI tests must never touch real network, disk, or platform channels. This document is the canonical extract of what the official Flutter docs prescribe. Where the docs are vague, that's called out explicitly rather than papered over.

---

## TL;DR

Flutter recognises three test levels — **unit, widget, integration** — and recommends "many unit and widget tests… plus enough integration tests to cover all the important use cases." The widget test is the workhorse: it runs under `flutter test` in a fake-async environment with no real network, no real platform channels, and no real time, and it's where most behavioural coverage should live. For isolation, Flutter's house style is **constructor-inject your dependency, then pass a fake or generated Mockito mock in the test**; mocking platform channels via `TestDefaultBinaryMessenger` is explicitly labelled "last resort." Integration tests use the same APIs but boot the real app on a real device under `IntegrationTestWidgetsFlutterBinding` and should be used sparingly. Golden tests exist, are async (`expectLater(finder, matchesGoldenFile(...))`), and have well-known platform-font portability problems. Async work that genuinely escapes the fake-async zone needs `tester.runAsync`, but the docs prefer you restructure the code to avoid that.

---

## 1. The Pyramid (Flutter's framing)

The overview page introduces three test types and gives this trade-off table verbatim:

| Tradeoff | Unit | Widget | Integration |
|---|---|---|---|
| Confidence | Low | Higher | Highest |
| Maintenance cost | Low | Higher | Highest |
| Dependencies | Few | More | Most |
| Execution speed | Quick | Quick | Slow |

The exact recommendation:

> "Generally speaking, a well-tested app has many unit and widget tests, tracked by code coverage, plus enough integration tests to cover all the important use cases."

There is **no fourth level** in the official docs (no "component" or "snapshot" tier). Golden tests are not their own level — `matchesGoldenFile` is a matcher you use inside a widget or integration test.

What each level is *for*, per the docs:

- **Unit test** — "test a single function, method, or class." No Flutter widget tree; pure Dart. Runs under `package:test` (or `flutter_test`, which re-exports it).
- **Widget test** — "test a single widget" (Flutter calls this a "component test" in some docs). Boots a fake-async, fake-binding Flutter environment, builds a widget tree, simulates input, asserts on rendered output. Runs under `flutter test`.
- **Integration test** — "test a complete app or large part of an app." Runs on a real device or emulator via `flutter test integration_test/…` (or the older `flutter drive`). Real platform code, real plugins.

Sources: `docs.flutter.dev/testing/overview`, `docs.flutter.dev/cookbook/testing/unit/introduction`.

---

## 2. Unit Tests

### API surface
- `test('description', () { … })` — single test.
- `group('description', () { … })` — nests tests; the description is prepended to children in output.
- `expect(actual, matcher)` — assertion built on `package:matcher`.
- `setUp` / `tearDown` — run before/after **each** test in scope. `setUpAll` / `tearDownAll` run once per group. (The Flutter cookbook doesn't show these; they come from `package:test`.)
- Async: `await`-ing inside a `test` body is supported; uncaught async errors fail the test even after it returns. `expectLater(future, completion(equals(…)))` and `expectLater(future, throwsA(isA<MyError>()))` are the canonical patterns for futures. `completes` matcher just asserts the future resolves without error.

### Runner & file layout
- File location: `test/` at the package root.
- File name: must end in `_test.dart`. Quote from the cookbook:
  > "Test files should always end with `_test.dart`, this is the convention used by the test runner when searching for tests."
- Invocation:
  - `flutter test` — all tests under `test/`.
  - `flutter test test/foo_test.dart` — single file.
  - `flutter test --plain-name "group or test name"` — name filter.
  - `flutter test --coverage` — emits `coverage/lcov.info`.

### Isolation pattern
The Flutter unit-test cookbook is **emphatic** about one thing: **don't call statics, take the dependency as a parameter.** The mocking page literally rewrites a function from `fetchAlbum()` to `fetchAlbum(http.Client client)` for exactly this reason. This is constructor/parameter injection in disguise and it is the basis of every other isolation pattern in the docs.

### Example shape

```dart
import 'package:test/test.dart';

void main() {
  group('Counter', () {
    late Counter counter;
    setUp(() => counter = Counter());

    test('starts at 0', () {
      expect(counter.value, 0);
    });

    test('increment bumps value', () {
      counter.increment();
      expect(counter.value, 1);
    });

    test('loadInitial resolves with seeded value', () {
      expect(counter.loadInitial(), completion(7));
    });
  });
}
```

### If you only follow one rule
**Inject every external dependency through a constructor or function parameter.** Static singletons and global state are the single biggest reason unit tests turn into integration tests by accident.

Source: `docs.flutter.dev/cookbook/testing/unit/introduction`, `pub.dev/packages/test`.

---

## 3. Widget Tests

### API surface

Provided by `package:flutter_test`:

- `testWidgets('description', (WidgetTester tester) async { … })` — the widget-test analogue of `test`. Gives you a `WidgetTester` that drives a hidden test binding under fake async.
- `WidgetTester` methods you will actually use:
  - `pumpWidget(widget)` — install the root widget.
  - `pump([duration])` — schedule one frame; with a duration, advance the fake clock.
  - `pumpAndSettle([duration])` — repeatedly pump until no frames are scheduled. Use after animations.
  - `tap(finder)`, `longPress(finder)`, `drag(finder, Offset)`, `fling(finder, Offset, speed)`, `enterText(finder, 'text')`, `sendKeyEvent(LogicalKeyboardKey.x)`.
  - `scrollUntilVisible(finder, delta, scrollable: …)`, `dragUntilVisible`, `ensureVisible`.
  - `runAsync(() async { … })` — escape the fake-async zone to do *real* async work (see §7).
  - `tester.view.physicalSize = Size(w, h); tester.view.devicePixelRatio = …` (with `addTearDown(() => tester.view.resetPhysicalSize())`) for screen-size/orientation tests.
- `Finder`s on the `find` constant:
  - `find.text('hello')`, `find.byKey(const Key('submit'))`, `find.byType(MyWidget)`, `find.byIcon(Icons.add)`, `find.byWidget(instance)`, `find.byElementType(SomeElement)`, `find.bySemanticsLabel('label')`, `find.descendant(of: …, matching: …)`, `find.ancestor(of: …, matching: …)`.
- Matchers:
  - `findsOneWidget`, `findsNothing`, `findsWidgets` (≥1), `findsNWidgets(n)`, `findsAtLeastNWidgets(n)` (newer).

### Runner
`flutter test`. Same runner as unit tests; the test binding (`AutomatedTestWidgetsFlutterBinding`) detects `testWidgets` and provides the fake env.

### Isolation — what UI tests must NOT do

The widget-test binding is already isolated by default:

- **No real network.** There is no live HTTP stack; `dart:io` HttpClient is overridden to return 400 for everything by default.
- **No real time.** It runs inside a fake-async zone (see `FakeAsync`). `Future.delayed(...)` only completes when you `pump(duration)`. `Timer`s, animations, debouncers — all driven by `pump`.
- **No real platform channels.** Calling into a method channel without a registered mock handler throws `MissingPluginException`.
- **No image network loads.** `Image.network` will hang the test unless wrapped in `tester.runAsync` or its loader is faked.

The audited app's hard constraint ("UI tests must never touch network/disk") is therefore the default state of `testWidgets` — the audit is really about whether the code under test ever **escapes** that sandbox (e.g. by holding a real `Dio`, a real Hive box, or a real `SharedPreferences`).

### Isolation patterns the Flutter docs endorse

1. **Constructor injection of fakes/mocks** (the canonical pattern; see §2 and the Mockito cookbook). For Dio specifically, the community pattern is `Dio(BaseOptions(...))..httpClientAdapter = MockAdapter()` from `package:http_mock_adapter` — the Flutter docs themselves only demonstrate `http.Client` + Mockito's generated `MockClient`, but the principle is identical.
2. **Mock the dependency, not the plugin.** The plugins page is unambiguous:
   > "In most cases, the best approach is to wrap plugin calls in your own API, and provide a way of mocking your own API in tests."
   Translation: don't `setMockMethodCallHandler` on `path_provider`; wrap `path_provider` in a `PathProviderGateway` interface and inject a fake.
3. **`TestDefaultBinaryMessenger.setMockMethodCallHandler`** as last resort for true platform-channel work. Docs explicitly say this is for plugin-author tests, not app tests:
   > "`TestDefaultBinaryMessenger` is mainly useful in the internal tests of plugin implementations, rather than tests of code using plugins."
4. **In-memory plugin substitutes.** The docs don't mandate any specific package, but the well-known ones — `SharedPreferences.setMockInitialValues({...})` (built into the plugin), `hive_test` / `Hive.init(tempDir)` for Hive, `path_provider_platform_interface` with a test implementation — all work by replacing the platform channel handler at startup. For UI tests under the project's constraint, the cleaner path is still "wrap behind an interface, inject a fake."
5. **Riverpod overrides.** The official Flutter docs do **not** cover Riverpod. Riverpod's own docs prescribe `ProviderScope(overrides: [repoProvider.overrideWithValue(FakeRepo()), dioProvider.overrideWith((ref) => fakeDio)], child: widgetUnderTest)`. This is the Riverpod-native expression of "constructor inject the dependency" and is what the audited app should be using as its primary seam.

### Always wrap under test in an app shell

Widgets that use `Theme.of`, `MediaQuery.of`, `Navigator.of`, `Directionality.of`, or any localized text **need a `MaterialApp`** (or `CupertinoApp`, or at minimum `Directionality` + `MediaQuery` + `Localizations`). The cookbook's examples bake `MaterialApp` into the widget itself; in a real codebase the test usually wraps:

```dart
await tester.pumpWidget(
  ProviderScope(
    overrides: [todosRepoProvider.overrideWithValue(FakeTodosRepo())],
    child: const MaterialApp(home: TodosScreen()),
  ),
);
```

### `pump` vs `pumpAndSettle`

The cookbook's tap-drag page is the clearest source:

- After a `tap` or `enterText` that triggers a synchronous `setState`, **one `pump()`** is enough.
- After anything that starts an animation, route transition, `AnimatedSwitcher`, `Hero`, dismiss-swipe — use **`pumpAndSettle()`**.
- If something never settles (a `RepaintBoundary` repainting forever, an animation controller on `repeat()`, a periodic timer), `pumpAndSettle` will time out. The fix is `pump(duration)` with a known duration, not `pumpAndSettle`.

### Handling the usual "test hangs" cases

- **`Image.network` hangs.** It needs a real HTTP fetch. Either swap the widget for `Image.asset` / a fake provider in tests, or wrap the build in `await tester.runAsync(() async { await tester.pumpWidget(...); await precacheImage(...); });`. The cleanest fix is an `ImageProvider` abstraction injected into the widget.
- **Timers / Future.delayed.** Advance them with `pump(duration)`.
- **Streams.** Pump once to let the subscription register, emit on the stream, pump again to let the subscriber rebuild.

### Example shape

```dart
testWidgets('submits when form is valid', (tester) async {
  final fakeRepo = FakeTodosRepo();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [todosRepoProvider.overrideWithValue(fakeRepo)],
      child: const MaterialApp(home: NewTodoScreen()),
    ),
  );

  await tester.enterText(find.byKey(const Key('title-field')), 'Buy milk');
  await tester.tap(find.byKey(const Key('submit')));
  await tester.pump();           // setState after submit
  await tester.pumpAndSettle();  // snackbar / nav animation

  expect(fakeRepo.created, hasLength(1));
  expect(find.text('Saved'), findsOneWidget);
});
```

### If you only follow one rule
**Find by `Key`, not by text or type.** Text breaks under i18n and copy changes; type breaks when you add a second instance. Keys are the only stable contract.

Sources: `docs.flutter.dev/cookbook/testing/widget/introduction`, `.../widget/finders`, `.../widget/tap-drag`, `.../widget/scrolling`, `.../widget/orientation`, `docs.flutter.dev/testing/plugins-in-tests`, `api.flutter.dev/flutter/flutter_test/WidgetTester-class.html`.

---

## 4. Integration Tests

### API surface
- `IntegrationTestWidgetsFlutterBinding.ensureInitialized();` at the top of `main()` in every integration test file.
- The rest of the API is **`flutter_test` again**: `testWidgets`, `WidgetTester`, the same `find.*` and matchers.
- Files live in `integration_test/` (not `test/`).
- Optional: `binding.traceAction(() async { … }, reportKey: 'scroll')` for performance timelines.

### Runner
- Modern: `flutter test integration_test/app_test.dart` (runs on the connected device/emulator/desktop target).
- Legacy / required for headless web: `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/app_test.dart`.
- Profile-mode benchmarking: add `--profile`.

### What runs
The **real app** on the **real device**, with **real plugins**, **real platform channels**, **real network**. This is the level where you intentionally remove fakes.

### Fakes/mocks here?
The docs allow them but discourage over-use:
> "Use real services for true end-to-end testing. Mock external APIs (network calls, Firebase) if needed. Avoid mocking core app logic to maintain realistic test conditions."

Practical translation: integration tests are where you point a *real* Dio at a *staging* backend (or a local fake server / `mockoon`-style stub), not where you wire in `MockAdapter`. Mocking inside an integration test usually means you should have written a widget test instead.

### Limitations the docs flag
- `integration_test` **cannot** interact with native UI (permission dialogs, system notifications, native pickers). The docs point to `patrol` for that — Patrol is not first-party but is the Flutter team's official recommendation for native UI.
- Performance recording (`traceAction`) is **not supported on web**.

### Example shape

```dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('happy path: log in and see dashboard', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('email')), 'a@b.co');
    await tester.enterText(find.byKey(const Key('pw')), 'hunter2');
    await tester.tap(find.byKey(const Key('login')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard')), findsOneWidget);
  });
}
```

### If you only follow one rule
**Keep integration tests few and decisive.** Cover the handful of flows whose failure would constitute "the app is broken." Everything else should live in widget tests.

Source: `docs.flutter.dev/testing/integration-tests`, `docs.flutter.dev/cookbook/testing/integration/introduction`, `docs.flutter.dev/cookbook/testing/integration/profiling`.

---

## 5. Fakes vs Mocks

The Flutter docs use these terms loosely, but the cookbook is consistent on which package does which:

- **Mockito with `@GenerateMocks`** — the documented default. Annotate the test's `main`, run `dart run build_runner build`, import the generated `*.mocks.dart`. Stub with `when(client.get(...)).thenAnswer((_) async => …)`. The docs explicitly favour generated mocks over hand-written, citing null safety and type safety.
- **Mocktail** — not mentioned in the Flutter docs. It's pub.dev's null-safe, no-codegen alternative, widely used in the community (Felix Angelov / `bloc` ecosystem). Same conceptual model, closure-wrapped stubs: `when(() => mock.x()).thenReturn(...)`. The audited team should pick one and stick to it; mixing both in the same suite is the worst outcome.
- **Hand-written fakes** — implementing the interface as a real Dart class with in-memory state. The docs don't formalise this as a pattern, but the *whole* plugins page implicitly recommends it: "wrap plugin calls in your own API, and provide a way of mocking your own API in tests." A `FakeTodosRepository implements TodosRepository` with a `final List<Todo> _todos = []` is almost always more readable than the equivalent Mockito setup for repository-style dependencies.

**Rule of thumb (extracted, not verbatim):** Mock at the *edge* (HTTP client, platform channel) where the surface is narrow and request/response-shaped. Fake at the *seam* (repository, gateway, controller) where the surface is wider and you want to call real methods many times. The Flutter cookbook only shows the first; the second is implied by the plugins page.

Source: `docs.flutter.dev/cookbook/testing/unit/mocking`, `docs.flutter.dev/testing/plugins-in-tests`, `pub.dev/packages/mocktail`.

---

## 6. Platform Channels and Plugins

The plugins page ranks isolation strategies, in order of preference:

1. **Wrap the plugin in your own API**, mock the wrapper.
2. **Mock the plugin's public Dart API** (if it exposes instance methods).
3. **Mock the platform interface** (only for federated plugins).
4. **Mock the platform channel** via `TestDefaultBinaryMessenger.setMockMethodCallHandler` — last resort, "mainly useful in the internal tests of plugin implementations, rather than tests of code using plugins."

For the audited app, this means:

- `path_provider`, `shared_preferences`, `hive_flutter`, `connectivity_plus`, `package_info_plus` etc. should each sit behind a thin gateway interface that the rest of the app depends on. The widget test injects a fake gateway; the unit test stubs the gateway with Mockito; nobody ever calls `setMockMethodCallHandler` from a UI test.
- `shared_preferences` is a partial exception because the plugin ships `SharedPreferences.setMockInitialValues({...})` officially. That counts as "the plugin's public Dart API" (option 2). It's fine to call directly from `setUp`.
- Hive has no first-party in-memory mode; the community pattern is `Hive.init(Directory.systemTemp.createTempSync().path)` followed by manual cleanup. Under the project's "no disk" rule this fails — the right answer is option 1: hide Hive behind a `KeyValueStore` interface and pass a `FakeKeyValueStore` in tests.

### Faking a platform channel directly (when you must)

```dart
final messenger = tester.binding.defaultBinaryMessenger;
messenger.setMockMethodCallHandler(
  const MethodChannel('plugins.flutter.io/path_provider'),
  (call) async {
    if (call.method == 'getApplicationDocumentsDirectory') return '/tmp/test';
    return null;
  },
);
addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
```

The teardown matters — leaked handlers leak across tests.

Source: `docs.flutter.dev/testing/plugins-in-tests`, `docs.flutter.dev/testing/testing-plugins`, `api.flutter.dev/flutter/flutter_test/TestDefaultBinaryMessenger-class.html`.

---

## 7. Async Testing

The fake-async zone is the most under-documented piece of Flutter testing, but the rules are concrete:

- **Inside `testWidgets`, the clock is fake.** `await tester.pump(Duration(seconds: 1))` advances it 1 s. `Future.delayed(Duration(seconds: 1))` does **not** resolve until you pump that duration.
- **`pumpAndSettle`** repeatedly pumps until no frame is scheduled. It will time out (default 10 minutes — but in practice `pumpAndSettle(Duration(seconds: 10))` is the right defensive cap) if anything keeps scheduling frames (e.g. `AnimationController.repeat`).
- **`tester.runAsync(() async { … })`** drops you out of the fake zone for the duration of the callback. Use it when:
  - You need a real `Image.network` to load (or `precacheImage`).
  - You're integrating with code that uses isolates or OS threads.
  - You need a *real* `Timer` or `Future.delayed`.
- The docs are explicit that `runAsync` is an escape hatch, not a default:
  > "Widget tests are designed to run in fake async environment." Restructure to avoid it where possible.
- **Re-entrancy:** you must `await` the `runAsync` future before calling it again. Nested `runAsync` calls deadlock.
- **`expectLater(future, completes)`**, **`expectLater(future, completion(predicate))`**, **`expectLater(future, throwsA(isA<MyError>()))`** are the future matchers. Use `expectLater` (not `expect`) whenever the matcher returns a `Future`. `matchesGoldenFile` is also async, so always `expectLater` it.
- For Streams: `expectLater(stream, emitsInOrder([1, 2, 3, emitsDone]))`. Use this pattern instead of `await for` in tests — it deadlocks under fake async.

### If you only follow one rule for async
**Default to fake async + `pump(duration)`. Only reach for `tester.runAsync` when the code under test fundamentally needs real I/O, and treat that as a code smell.**

Source: `api.flutter.dev/flutter/flutter_test/WidgetTester/runAsync.html`, `docs.flutter.dev/cookbook/testing/widget/tap-drag`.

---

## 8. Golden / Image Tests

What the docs do cover:

- `expectLater(find.byType(MyWidget), matchesGoldenFile('save.png'));` — async matcher; always `expectLater`.
- Regenerate with `flutter test --update-goldens`.
- Default font is **Ahem** — characters render as filled squares — to avoid platform font drift. To golden real-looking UI, load real fonts via `FontLoader` in `flutter_test_config.dart`:
  ```dart
  Future<void> testExecutable(FutureOr<void> Function() testMain) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final loader = FontLoader('Roboto')..addFont(rootBundle.load('assets/Roboto.ttf'));
    await loader.load();
    await testMain();
  }
  ```
- **Platform rendering drift is real.** Goldens generated on macOS will diff against goldens generated on Linux CI. The Flutter team's own answer is to run golden tests only on a single canonical platform (typically `--platform vm` on Linux CI) and tag/skip elsewhere.

What the docs **don't** cover well:
- No prescriptive guidance on *when* to use goldens vs widget assertions. Community wisdom: goldens are good for catching unintended visual regressions in design-system components (a custom button, a chart) and bad for full-screen layouts that change often.
- No first-party tolerance-based comparator (e.g. for sub-pixel diffs). `matchesGoldenFile` is bit-exact unless you swap in a custom `goldenFileComparator`. Community packages (`alchemist`, `golden_toolkit`) layer this on.

### If you only follow one rule for goldens
**Pin them to one CI platform, load real fonts via `flutter_test_config.dart`, and don't golden anything bigger than a component.**

Source: `api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html`.

---

## 9. What the Docs Imply but Don't Spell Out

These are positions you can extract from the docs by reading between the lines. I've noted where they're explicit vs inferred.

- **Test behaviour, not implementation.** *Implicit.* Every cookbook example asserts on rendered output or returned values; none ever inspect internal state.
- **Prefer widget tests over integration tests.** *Explicit-ish.* The "many… plus enough" wording is a clear hierarchy.
- **Use Keys for findability.** *Implicit.* The integration-tests page goes out of its way to use `ValueKey('increment')` instead of `find.text('+')`, and the finders page lists `find.byKey` as the most-reliable option.
- **Wrap plugins behind your own interfaces.** *Explicit.* Quoted twice on the plugins page.
- **Don't mock what you don't own.** *Implicit but consistent.* The docs only mock things the developer controls (HTTP client, plugin wrapper). Mocking `Future`, `Stream`, `BuildContext`, etc. is never demonstrated.
- **Test naming and organisation.** *The Flutter docs do not take a position.* They only mandate `*_test.dart` filenames and the `test/` directory. There's no official guidance on test descriptions, BDD-style names, or one-file-per-widget. The downstream agent should pick a convention and enforce it via lint, not by appeal to authority.
- **`setUp` / `tearDown` vs `late` fields.** *The docs don't take a position.* Both work. `setUp` resets per-test cleanly; `late` plus a factory function is more compact. Either is fine — consistency matters more than the choice.
- **TDD.** *The docs don't take a position.* The unit-testing intro explicitly notes the tutorial "doesn't follow Test Driven Development."

---

## 10. Cross-Cutting Cheat-Sheet (the one-rule lines)

| Level | The one rule |
|---|---|
| Unit | Inject every dependency; never call statics. |
| Widget | Find by Key; pump the right number of times; never let real I/O escape the fake-async zone. |
| Integration | Few, decisive, real. If you're mocking inside one, you wanted a widget test. |
| Plugin/IO | Wrap behind your own interface. `setMockMethodCallHandler` is the last resort. |
| Async | Stay in fake async. `tester.runAsync` is an escape hatch, not a strategy. |
| Goldens | One platform, real fonts, component-sized. |

---

## Citations

| Section | URL |
|---|---|
| Pyramid, trade-offs | https://docs.flutter.dev/testing/overview |
| Unit-test mechanics, file naming | https://docs.flutter.dev/cookbook/testing/unit/introduction |
| Mockito, generated mocks, DI rewrite | https://docs.flutter.dev/cookbook/testing/unit/mocking |
| `testWidgets`, `WidgetTester`, `pump*`, matchers | https://docs.flutter.dev/cookbook/testing/widget/introduction |
| Finder catalogue, preference order | https://docs.flutter.dev/cookbook/testing/widget/finders |
| `tap` / `enterText` / `drag`, when to pump | https://docs.flutter.dev/cookbook/testing/widget/tap-drag |
| `scrollUntilVisible` and friends | https://docs.flutter.dev/cookbook/testing/widget/scrolling |
| `tester.view.physicalSize`, orientation | https://docs.flutter.dev/cookbook/testing/widget/orientation |
| Integration-test concepts | https://docs.flutter.dev/cookbook/testing/integration/introduction |
| Integration-test how-to, `IntegrationTestWidgetsFlutterBinding` | https://docs.flutter.dev/testing/integration-tests |
| Performance profiling with `traceAction` | https://docs.flutter.dev/cookbook/testing/integration/profiling |
| Plugin mocking hierarchy, `TestDefaultBinaryMessenger` quote | https://docs.flutter.dev/testing/plugins-in-tests |
| Plugin testing strategy | https://docs.flutter.dev/testing/testing-plugins |
| `WidgetTester` API (runAsync, pump, gestures) | https://api.flutter.dev/flutter/flutter_test/WidgetTester-class.html |
| `runAsync` semantics & warnings | https://api.flutter.dev/flutter/flutter_test/WidgetTester/runAsync.html |
| `TestDefaultBinaryMessenger.setMockMethodCallHandler` | https://api.flutter.dev/flutter/flutter_test/TestDefaultBinaryMessenger-class.html |
| `matchesGoldenFile`, `--update-goldens`, fonts | https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html |
| `package:test` conventions (`group`, `setUp`, etc.) | https://pub.dev/packages/test |
| Mocktail (community, for context only) | https://pub.dev/packages/mocktail |
