import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/connectivity.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/features/log_entry/widgets/log_preview_block.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

import '../../repositories/_harness.dart';

/// A deterministic test food: 100 kcal / 10 g P / 20 g C / 0 g F per 100 g,
/// with one 100 g serving so the preview math collapses to "× quantity".
Food _testFood() {
  return Food(
    id: 'f_test',
    name: 'Test food',
    brand: 'TestBrand',
    barcode: null,
    source: FoodSource.off,
    isCustom: false,
    qualityScore: null,
    nutriscore: null,
    nutritionPer100g: NutritionPer100g(
      energyKcal: Decimal.fromInt(100),
      proteinG: Decimal.fromInt(10),
      carbsG: Decimal.fromInt(20),
      fatG: Decimal.zero,
    ),
    servings: <Serving>[
      Serving(
        id: 'sv_100g',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.user,
        sortOrder: 0,
      ),
    ],
  );
}

Widget _harness({
  required Food food,
  required ValueChanged<LogCreate> onSubmit,
  Meal? defaultMeal,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: food,
          defaultMeal: defaultMeal,
          onSubmit: onSubmit,
          showGrabber: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('initial render shows 100 kcal preview at quantity 1',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    expect(find.byType(LogPreviewBlock), findsOneWidget);
    // Heroes the kcal hero — 100 g × 1 × 100 kcal/100g = 100.
    expect(find.text('100'), findsWidgets);
  });

  testWidgets('typing a quantity updates the preview', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    final field = find.descendant(
      of: find.byKey(const Key('log_entry_quantity_field_host')),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);

    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '2.5');
    await tester.pump();

    // 100 kcal × 2.5 = 250.
    expect(find.text('250'), findsWidgets);
  });

  testWidgets('tapping a chip updates both stepper value and preview',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    // Tap the 2× chip.
    await tester.tap(find.text('2×'));
    await tester.pump();

    // Preview reflects 2× (= 200 kcal).
    expect(find.text('200'), findsWidgets);
    // Stepper field text mirrors the chip value.
    final fieldWidget = tester.widget<TextField>(
      find.descendant(
      of: find.byKey(const Key('log_entry_quantity_field_host')),
      matching: find.byType(TextField),
    ),
    );
    expect(fieldWidget.controller!.text, '2');
  });

  testWidgets('Save invokes onSubmit with a LogCreate carrying the form state',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    LogCreate? captured;
    await tester.pumpWidget(_harness(
      food: _testFood(),
      defaultMeal: Meal.lunch,
      onSubmit: (lc) => captured = lc,
    ));
    await tester.pump();

    // Bump quantity to 1.5 via the chip.
    await tester.tap(find.text('1.5×'));
    await tester.pump();

    // Tap Save.
    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.foodId, 'f_test');
    expect(captured!.servingId, 'sv_100g');
    expect(captured!.meal, Meal.lunch);
    expect(captured!.quantity, Decimal.parse('1.5'));
  });

  testWidgets('default meal falls back to local time of day when null',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    LogCreate? captured;
    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (lc) => captured = lc,
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();

    // Whatever the wall-clock meal is, it should match `mealForLocalTime`.
    expect(captured, isNotNull);
    expect(captured!.meal, mealForLocalTime(DateTime.now()));
  });

  // T-013 — the sheet must never spin a `CircularProgressIndicator` to
  // signal submitting; the button swaps its label for a static skeleton
  // bar (`_SaveButtonSkeleton`). Assert the spinner is absent on the
  // idle path; T-08 keeps the static skeleton stable when submit fires.
  testWidgets('idle sheet renders no CircularProgressIndicator',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Save to log'), findsOneWidget);
  });

  testWidgets('QuickMultiplierChips highlights the chip equal to quantity',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    // Drive via the stepper plus button: 1 → 1.5 (step is 0.5).
    final plus = find.bySemanticsLabel('Increment');
    expect(plus, findsOneWidget);
    await tester.tap(plus);
    await tester.pump();

    // The 1.5× chip should now be the one rendered selected. We can't
    // easily peek at colors, but tapping it should be a no-op and the
    // semantics flag should be `selected`.
    final semantics =
        tester.getSemantics(find.bySemanticsLabel('1.5× multiplier'));
    expect(semantics.hasFlag(SemanticsFlag.isSelected), isTrue);
  });

  // QL-105 — T-24 Case 2 router assertions. After save, the sheet must
  // route the user to `pathForDay(consumedOn)` instead of popping back
  // to the source page. Tested across:
  //   • compact-create (date == today)        → `/today`
  //   • compact-create (date == backdated)    → `/today/YYYY-MM-DD`
  //   • expanded-create (dialog ordering)     → `/today` + dialog gone
  //
  // Edit-mode router behaviour lives in
  // `log_entry_sheet_edit_mode_test.dart`.
  group('QL-105 — save routes to pathForDay(consumedOn)', () {
    late Directory hiveDir;
    late Box<String> outboxBox;
    late _RouterCapturingRepository repo;

    setUp(() async {
      hiveDir =
          await Directory.systemTemp.createTemp('fulfilled-ql105-create-');
      Hive.init(hiveDir.path);
      outboxBox = await Hive.openBox<String>(outboxBoxName);
      resetRepositoriesForTest();
      repo = _RouterCapturingRepository(
        api: buildTestApiClient(),
        foodRepository: FoodRepository(buildTestApiClient()),
        goalRepository: GoalRepository(buildTestApiClient()),
      );
    });

    tearDown(() async {
      teardownRepositoriesForTest();
      await Hive.close();
      if (hiveDir.existsSync()) {
        hiveDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'compact-create (date == today) lands on /today',
      (tester) async {
        // 390 logical px → compact form factor.
        tester.view.physicalSize = const Size(390, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final router = _routerWithSheet(
          sheet: () => LogEntrySheetBody(
            food: _testFood(),
            onSubmit: (_) {},
            showGrabber: false,
          ),
        );
        await tester.pumpWidget(_routerHarness(
          router: router,
          outboxBox: outboxBox,
          repo: repo,
        ));
        await tester.pumpAndSettle();

        // Source page.
        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();
        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals('/foods/f_test'));

        // Save. Compact-create writes to the outbox + invalidates +
        // `context.go(pathForDay(today))`.
        await tester.tap(find.byKey(const Key('log_entry_save_button')));
        // Need a couple of pumps for the awaits inside _onCreatePressed
        // to resolve (outbox enqueue + the post-await `context.go`).
        // We avoid `pumpAndSettle` here because the SnackBar's 4-second
        // dwell timer keeps the binding "settling" longer than the
        // suite's patience budget.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals(Routes.todayPath));
      },
    );

    testWidgets(
      'compact-create with a backdated date lands on /today/YYYY-MM-DD',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Build "yesterday" relative to the wall clock so the
        // `pathForDay` "today" comparison resolves false. Computing the
        // expected path the same way the helper does keeps the test
        // calendar-stable across run times.
        final now = DateTime.now();
        final yesterday =
            DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
        final y = yesterday.year.toString().padLeft(4, '0');
        final m = yesterday.month.toString().padLeft(2, '0');
        final d = yesterday.day.toString().padLeft(2, '0');
        final expectedPath = '/today/$y-$m-$d';

        final router = _routerWithSheet(
          sheet: () => LogEntrySheetBody(
            food: _testFood(),
            onSubmit: (_) {},
            initialDate: yesterday,
            showGrabber: false,
          ),
        );
        await tester.pumpWidget(_routerHarness(
          router: router,
          outboxBox: outboxBox,
          repo: repo,
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('log_entry_save_button')));
        // Same pump dance as the today-path test — explicit pumps,
        // skip `pumpAndSettle` so the SnackBar's 4-second dwell doesn't
        // stall the suite.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals(expectedPath));
      },
    );

    testWidgets(
      'expanded-create — dialog pops before context.go (no orphan frame)',
      (tester) async {
        // 1200 logical px → expanded form factor. `showLogEntrySheet`
        // renders the body inside a `Dialog` via `showDialog` (not a
        // navigator-stack route). The save handler pops the dialog
        // first, then `go`s — and that's what we assert here.
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Configure the repo so the direct `LogRepository.create` path
        // succeeds (expanded uses the repo, not the outbox).
        repo.stubCreateReturn = LogEntry(
          id: 'le_server_0',
          foodId: 'f_test',
          foodName: 'Test food',
          servingId: 'sv_100g',
          servingName: '100 g',
          consumedOn: DateTime.now(),
          meal: Meal.lunch,
          quantity: Decimal.one,
          gramsTotal: Decimal.fromInt(100),
          nutritionSnapshot: NutritionSnapshot(
            caloriesKcal: Decimal.fromInt(100),
          ),
          note: null,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        // Use the production `showLogEntrySheet` here so the dialog
        // overlay is the real one. We can't just pump
        // `LogEntrySheetBody` inside a `Scaffold(body: ...)` for this
        // test, because that pumps the body as a normal route child —
        // meaning `Navigator.pop` would pop the whole route, defeating
        // the dialog-pop-first ordering carveout we're trying to
        // exercise. `showLogEntrySheet` instead pushes a real
        // `showDialog`, which is the layering the production code is
        // written against.
        final router = _routerWithSheetOpener(food: _testFood());

        await tester.pumpWidget(_routerHarness(
          router: router,
          outboxBox: outboxBox,
          repo: repo,
        ));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();

        // The dialog opened on top of `/foods/f_test`. The body is
        // visible; the underlying route hasn't changed.
        expect(find.byType(LogEntrySheetBody), findsOneWidget);
        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals('/foods/f_test'));

        await tester.tap(find.byKey(const Key('log_entry_save_button')));
        // Pumps for the `await LogRepository.create`, then the
        // post-await `pop` + `context.go` chain. Skip `pumpAndSettle`
        // so any residual dialog enter/exit animation doesn't stall
        // the suite.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 300));

        // Two assertions for the dialog-on-expanded ordering carveout:
        //   1. The dialog (and the sheet inside it) is gone — the
        //      explicit `Navigator.pop` ran first.
        //   2. The router landed on `/today` — the subsequent
        //      `context.go(pathForDay(today))` ran next.
        // If `go` had run before `pop`, the framework would have
        // unmounted the dialog asynchronously and the assertion
        // sequence would still pass — so this test isn't a strict
        // order proof. It IS a regression guard: it fails loudly if
        // either step is dropped entirely (regression on the dialog
        // carveout) or if the `context.mounted` defence skips the go.
        expect(find.byType(LogEntrySheetBody), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals(Routes.todayPath));
      },
    );
  });
}

/// Open `showLogEntrySheet` so the body is layered inside a real
/// `Dialog` overlay on expanded form factors. The expanded-create
/// dialog-ordering test needs this because pumping the body directly
/// inside a Scaffold would route-pop the whole `/foods/:id` page on
/// save, hiding the carveout we're trying to exercise.
///
/// The host route shows an "open sheet" button. On tap it pushes to
/// `/foods/:id`, whose builder kicks off `showLogEntrySheet` on the
/// first post-frame callback. The test taps "open sheet" once and the
/// dialog overlay appears.
GoRouter _routerWithSheetOpener({required Food food}) {
  return GoRouter(
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ctx.push('/foods/${food.id}'),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/:foodId',
        builder: (_, __) => _AutoOpenSheetScaffold(food: food),
      ),
      GoRoute(
        path: Routes.todayPath,
        routes: <RouteBase>[
          GoRoute(
            path: ':date',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('day ${state.pathParameters['date']}')),
            ),
          ),
        ],
        builder: (_, __) => const Scaffold(body: Center(child: Text('today'))),
      ),
    ],
  );
}

/// Renders a Scaffold and, on first frame, calls `showLogEntrySheet`
/// against the same context. Used by the expanded-create dialog
/// ordering test so the body is layered inside a real `Dialog` (the
/// production code path) rather than mounted as a normal route child.
class _AutoOpenSheetScaffold extends StatefulWidget {
  const _AutoOpenSheetScaffold({required this.food});
  final Food food;

  @override
  State<_AutoOpenSheetScaffold> createState() => _AutoOpenSheetScaffoldState();
}

class _AutoOpenSheetScaffoldState extends State<_AutoOpenSheetScaffold> {
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    if (!_opened) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Fire-and-forget: the test asserts on the post-save route, not
        // on the returned future. `mounted` guards against the
        // unlikely race where the route is torn down between the
        // first build and the post-frame tick.
        if (!mounted) return;
        showLogEntrySheet(context, food: widget.food);
      });
    }
    return const Scaffold(body: SizedBox.expand());
  }
}

/// Build a GoRouter for the QL-105 router-assertion tests. The host
/// route holds an "open sheet" button that pushes the sheet route; the
/// sheet route renders whatever the test passes via [sheet]. The two
/// destination routes (`/today`, `/today/:date`) render a sentinel
/// `Scaffold` so `context.go(pathForDay(...))` resolves to a valid page.
GoRouter _routerWithSheet({required Widget Function() sheet}) {
  return GoRouter(
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ctx.push('/foods/f_test'),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/:foodId',
        builder: (_, __) => Scaffold(body: sheet()),
      ),
      GoRoute(
        path: Routes.todayPath,
        routes: <RouteBase>[
          GoRoute(
            path: ':date',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('day ${state.pathParameters['date']}')),
            ),
          ),
        ],
        builder: (_, __) => const Scaffold(body: Center(child: Text('today'))),
      ),
    ],
  );
}

/// Wrap the router under a `ProviderScope` that overrides
/// `outboxBoxProvider` (so the compact-create path can write to a real
/// Hive box) and `logRepositoryProvider` (so the expanded-create path
/// hits the test-recording repo). `MaterialApp.router` plus the
/// `_LogEntrySheetBodyState` mounted inside a real route stack is what
/// makes `context.go` actually work.
Widget _routerHarness({
  required GoRouter router,
  required Box<String> outboxBox,
  required _RouterCapturingRepository repo,
}) {
  return ProviderScope(
    overrides: <Override>[
      outboxBoxProvider.overrideWithValue(outboxBox),
      logRepositoryProvider.overrideWithValue(repo),
      // The default `logPostFnProvider` throws `UnimplementedError`,
      // which the outbox catches but then schedules a retry timer.
      // Override with a synchronous success so `pumpAndSettle` doesn't
      // race the retry backoff.
      logPostFnProvider.overrideWithValue(
        (Map<String, dynamic> payload) async => 'le_server_async',
      ),
      // Pin connectivity to "online" so the outbox notifier's listener
      // doesn't try to consult the real platform channel under test.
      connectivityProvider.overrideWith((ref) => Stream<bool>.value(true)),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

/// Test double for `LogRepository`. Captures `create`/`update` calls
/// and returns a configurable stub entry. We sidestep the real mock
/// catalog (which trips on `f_test` not being in the seed) by
/// overriding `create` and `update` directly.
class _RouterCapturingRepository extends LogRepository {
  _RouterCapturingRepository({
    required super.api,
    required super.foodRepository,
    required super.goalRepository,
  });

  LogEntry? stubCreateReturn;
  LogCreate? lastCreatePayload;

  @override
  Future<LogEntry> create(LogCreate data) async {
    lastCreatePayload = data;
    final stub = stubCreateReturn;
    if (stub != null) return stub;
    throw StateError('no stubCreateReturn configured for this test');
  }

  @override
  bool isPendingSync(String entryId) => false;
}

