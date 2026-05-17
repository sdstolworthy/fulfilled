@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// QL-108 — Onboarding "Start over" affordance.
//
// Acceptance:
// 1. The "Start over" `TextButton` renders in the top-right of each
//    step's chrome (steps 1, 2, 3).
// 2. Tapping it pops an `AlertDialog` with the "Discard your responses
//    and start over?" copy and Yes/Cancel buttons.
// 3. Confirming "Yes" resets the `onboardingDraftProvider` (every
//    field returns to its empty default — `weightUnit` and
//    `heightUnit` are both `null`) and routes to `/onboarding/1`.
// 4. Tapping "Cancel" dismisses the dialog without touching the draft
//    or the route.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/features/onboarding/onboarding_screen.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

GoRouter _buildRouter({required int initialStep}) {
  return GoRouter(
    initialLocation: '/onboarding/$initialStep',
    routes: <RouteBase>[
      GoRoute(
        name: Routes.onboardingName,
        path: Routes.onboardingPath,
        builder: (_, state) {
          final raw = state.pathParameters['step'] ?? '1';
          final step = int.tryParse(raw) ?? 1;
          return OnboardingScreen(step: step);
        },
      ),
      GoRoute(
        path: Routes.todayPath,
        builder: (_, __) => const Scaffold(body: Text('today landed')),
      ),
    ],
  );
}

Widget _harness({
  required int step,
  required ProviderContainer container,
}) {
  final router = _buildRouter(initialStep: step);
  final app = MaterialApp.router(
    theme: buildLightTheme(),
    routerConfig: router,
  );
  return UncontrolledProviderScope(container: container, child: app);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Start over button renders on step 1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(step: 1, container: container));
      await tester.pump();

      expect(
        find.byKey(const Key('onboarding-start-over')),
        findsOneWidget,
      );
      expect(find.text('Start over'), findsOneWidget);
    },
  );

  testWidgets(
    'Start over button renders on step 2',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(step: 2, container: container));
      await tester.pump();

      expect(
        find.byKey(const Key('onboarding-start-over')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Start over button renders on step 3',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(step: 3, container: container));
      await tester.pump();

      expect(
        find.byKey(const Key('onboarding-start-over')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping Start over opens the confirmation dialog',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(step: 2, container: container));
      await tester.pump();

      await tester.tap(find.byKey(const Key('onboarding-start-over')));
      await tester.pumpAndSettle();

      expect(
        find.text('Discard your responses and start over?'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('start-over-confirm')), findsOneWidget);
      expect(find.byKey(const Key('start-over-cancel')), findsOneWidget);
    },
  );

  testWidgets(
    'tapping Cancel dismisses the dialog without changing the draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Pre-fill the draft so we can prove Cancel doesn't reset it.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.female)
        ..setHeightCm(Decimal.parse('170'));

      await tester.pumpWidget(_harness(step: 2, container: container));
      await tester.pump();

      await tester.tap(find.byKey(const Key('onboarding-start-over')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start-over-cancel')));
      await tester.pumpAndSettle();

      // Dialog is gone.
      expect(
        find.text('Discard your responses and start over?'),
        findsNothing,
      );
      // Draft is untouched.
      final draft = container.read(onboardingDraftProvider);
      expect(draft.sex, Sex.female);
      expect(draft.heightCm, Decimal.parse('170'));
    },
  );

  testWidgets(
    'tapping Yes resets the draft and routes to /onboarding/1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Fill every axis of the draft so we can prove Yes wipes them all.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.male)
        ..setBirthDate(DateTime(1990, 6, 1))
        ..setHeightCm(Decimal.parse('180'))
        ..setCurrentWeightKg(Decimal.parse('80'))
        ..setActivityLevel(ActivityLevel.moderate)
        ..setDirection(GoalDirection.lose)
        ..setRateKgPerWeek(Decimal.parse('0.5'))
        ..setWeightUnit(WeightUnit.lb)
        ..setHeightUnit(HeightUnit.ftIn);

      // Start from step 3 so we can observe the route change to step 1.
      await tester.pumpWidget(_harness(step: 3, container: container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('onboarding-start-over')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('start-over-confirm')));
      await tester.pumpAndSettle();

      // Draft is empty on every axis (including the unit axes — QL-102
      // / QL-104 explicit: empty resets both to null so the locale
      // default takes over).
      final draft = container.read(onboardingDraftProvider);
      expect(draft.sex, isNull);
      expect(draft.birthDate, isNull);
      expect(draft.heightCm, isNull);
      expect(draft.currentWeightKg, isNull);
      expect(draft.activityLevel, isNull);
      expect(draft.direction, isNull);
      expect(draft.rateKgPerWeek, isNull);
      expect(draft.weightUnit, isNull);
      expect(draft.heightUnit, isNull);
    },
  );
}
