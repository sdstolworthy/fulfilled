// QL-109 — dismiss-without-save regression tests.
//
// Three surfaces, one architectural promise: drafts survive a dismiss
// that isn't an explicit Save. Per `draft_providers.dart` file docstring:
//
//   Cancelling without an explicit discard does *not* reset — that's by
//   design so a user who taps Back and reopens the form continues where
//   they left off.
//
// These tests pin that promise against a future refactor that "improves"
// the cancel handler to clear the draft.
//
//   1. `customFoodDraftProvider` survives a Cancel tap on the
//      `CustomFoodScreen` top bar (when the draft is empty enough that
//      the discard dialog doesn't fire) — and survives a Discard-cancel
//      when the user picks "Keep editing".
//   2. `onboardingDraftProvider` survives back-navigation from step 2.
//   3. `LogEntrySheet` save handler is **not** invoked on a swipe-down
//      dismiss (Navigator.pop) — the only legal save path is the
//      explicit footer button.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

Food _testFood() {
  return Food(
    id: 'f_test',
    name: 'Test food',
    source: FoodSource.off,
    isCustom: false,
    servings: <Serving>[
      Serving(
        id: 'sv_100g',
        label: '100 g',
        amount: Decimal.fromInt(100),
        unit: Unit.g,
        kcal: Decimal.fromInt(100),
        proteinG: Decimal.fromInt(10),
        carbsG: Decimal.fromInt(20),
        fatG: Decimal.zero,
        isDefault: true,
        source: ServingSource.user,
      ),
    ],
  );
}

// ─── Custom food draft survives Cancel ───────────────────────────────────

GoRouter _customFoodRouter(GlobalKey<NavigatorState> navKey) {
  return GoRouter(
    navigatorKey: navKey,
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ctx.push('/foods/new'),
                child: const Text('open form'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/new',
        builder: (_, __) => const CustomFoodScreen(),
      ),
    ],
  );
}

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  testWidgets(
    'customFoodDraftProvider survives Cancel-then-Keep-editing on a dirty '
    'draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final navKey = GlobalKey<NavigatorState>();
      final repo = FoodRepository(buildTestApiClient());
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            foodRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: _customFoodRouter(navKey),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open form'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setName('Stash this');
      notifier.setServings(<DraftServing>[
        DraftServing(
          label: '100 g',
          amount: Decimal.fromInt(100),
          unit: Unit.g,
          kcal: Decimal.fromInt(123),
          isDefault: true,
        ),
      ]);
      await tester.pump();

      // Tap Cancel — a dirty draft triggers the destructive confirm
      // dialog. Choose "Keep editing" so the cancel does NOT discard.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Keep editing'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      // Draft survives — name + servings still present.
      final after = container.read(customFoodDraftProvider);
      expect(after.name, equals('Stash this'));
      expect(after.servings, hasLength(1));
      expect(after.servings.first.kcal, equals(Decimal.fromInt(123)));
    },
  );

  testWidgets(
    'customFoodDraftProvider survives a re-open after a dirty Cancel + '
    'Keep-editing: the next mount sees the same draft',
    (tester) async {
      // After a Keep-editing decision the screen stays mounted. Pop
      // back to the host explicitly, then re-open — the draft must
      // still carry the user's typing because the cancel path never
      // called `notifier.reset()`. This guards the "provider lifetime
      // outlives the route" promise in draft_providers.dart.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final navKey = GlobalKey<NavigatorState>();
      final repo = FoodRepository(buildTestApiClient());
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            foodRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: _customFoodRouter(navKey),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open form'));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      container
          .read(customFoodDraftProvider.notifier)
          .setName('Persist me');
      await tester.pump();

      // Dirty cancel → confirm dialog → Keep editing. The screen stays
      // mounted; the draft is untouched.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();

      expect(
        container.read(customFoodDraftProvider).name,
        equals('Persist me'),
      );
    },
  );

  // ─── Onboarding draft survives back-nav from step 2 ────────────────────

  testWidgets(
    'onboardingDraftProvider survives a back-navigation from step 2',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(onboardingDraftProvider.notifier);
      // Simulate the user landing on step 2, filling in profile bits.
      notifier.goToStep(2);
      notifier.setSex(Sex.female);
      notifier.setHeightCm(Decimal.fromInt(168));
      notifier.setCurrentWeightKg(Decimal.fromInt(65));
      notifier.setActivityLevel(ActivityLevel.moderate);

      // Back-navigation == `previous()`. The notifier's contract is
      // that step changes never reset accumulated fields.
      notifier.previous();

      final after = container.read(onboardingDraftProvider);
      expect(after.currentStep, equals(1));
      expect(after.sex, equals(Sex.female));
      expect(after.heightCm, equals(Decimal.fromInt(168)));
      expect(after.currentWeightKg, equals(Decimal.fromInt(65)));
      expect(after.activityLevel, equals(ActivityLevel.moderate));

      // Forward again to step 2 — nothing was reseeded; the values
      // pre-fill the controls on re-render.
      notifier.next();
      final back = container.read(onboardingDraftProvider);
      expect(back.currentStep, equals(2));
      expect(back.sex, equals(Sex.female));
      expect(back.heightCm, equals(Decimal.fromInt(168)));
      expect(back.currentWeightKg, equals(Decimal.fromInt(65)));
      expect(back.activityLevel, equals(ActivityLevel.moderate));
    },
  );

  // ─── LogEntrySheet save handler not invoked on dismiss ─────────────────

  testWidgets(
    'LogEntrySheet onSubmit is NOT invoked when the body is removed from '
    'the tree without tapping Save (swipe-down dismiss analogue)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var submitCount = 0;
      LogCreate? lastSubmit;

      // Switchable child lets us "dismiss" the sheet by swapping the
      // body out of the tree — equivalent to a `Navigator.pop` on a
      // real swipe-down. We never tap the footer Save button.
      Widget body = LogEntrySheetBody(
        food: _testFood(),
        showGrabber: false,
        onSubmit: (logCreate) {
          submitCount++;
          lastSubmit = logCreate;
        },
      );
      final builder = StatefulBuilder(builder: (ctx, setState) {
        return ProviderScope(
          child: MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  Expanded(child: body),
                  TextButton(
                    onPressed: () => setState(() {
                      body = const SizedBox.shrink();
                    }),
                    child: const Text('dismiss'),
                  ),
                ],
              ),
            ),
          ),
        );
      },);

      await tester.pumpWidget(builder);
      await tester.pumpAndSettle();

      // Mutate the form (a quantity change) so we'd KNOW if a sneaky
      // dispose-time save-on-close handler fired.
      final field = find.descendant(
        of: find.byKey(const Key('log_entry_quantity_field_host')),
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, '3');
      await tester.pump();

      // Tap the "dismiss" affordance — body is replaced by SizedBox,
      // simulating a swipe-down dismiss without going through Save.
      await tester.tap(find.text('dismiss'));
      await tester.pumpAndSettle();

      expect(
        submitCount,
        equals(0),
        reason: 'Dismiss-without-save must never fire `onSubmit` — that '
            'is the contract Save is the only commit path',
      );
      expect(lastSubmit, isNull);
    },
  );
}
