import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

/// T-019 — sign-out wiring widget test.
///
/// Mounts the real `appRouterProvider` so `context.go('/onboarding/1')`
/// resolves against the actual route table, then:
///   1. Drives the router to `/me`.
///   2. Taps the Sign-out row, taps the destructive confirm.
///   3. Asserts the router is at `/onboarding/1`.
///   4. Asserts `outboxBoxProvider.clear()` ran (box length == 0).
///   5. Asserts the `authTokenProvider` state is `null`.
User _mockUser() => User(
      id: 'u_test',
      displayName: 'Spencer Stolworthy',
      email: 'sdstolworthy@gmail.com',
      sex: Sex.male,
      birthDate: DateTime(1991, 8, 12),
      heightCm: Decimal.fromInt(182),
      currentWeightKg: Decimal.parse('79.4'),
      activityLevel: ActivityLevel.moderate,
      customFoodCount: 0,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 5, 15),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> outboxBox;
  late ProviderContainer container;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-signout-');
    Hive.init(hiveDir.path);
    outboxBox = await Hive.openBox<String>(outboxBoxName);
    // Seed the box so a successful clear() is observable.
    await outboxBox.put('entry-1', '{"foo":1}');
    await outboxBox.put('entry-2', '{"foo":2}');
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  Widget _harness() {
    container = ProviderContainer(
      overrides: <Override>[
        outboxBoxProvider.overrideWithValue(outboxBox),
        meProvider.overrideWith((ref) async => _mockUser()),
        customFoodCountProvider.overrideWith((ref) async => 0),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          final router = ref.watch(appRouterProvider);
          return MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          );
        },
      ),
    );
  }

  testWidgets(
    'Sign out → confirm clears token + outbox, lands on /onboarding/1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      // Drive the router to /me so the ProfileScreen renders.
      final routerContext = tester.element(find.byType(MaterialApp));
      GoRouter.of(routerContext).go('/me');
      await tester.pumpAndSettle();

      // Token seed is non-null in tests.
      expect(container.read(authTokenProvider), isNotNull);

      // Outbox is seeded.
      expect(outboxBox.length, equals(2));

      // Tap the sign-out row, then the destructive confirm.
      await tester.ensureVisible(find.byKey(const Key('sign-out-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign-out-row')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);

      // Confirm. The 'Sign out' label appears twice (the row + the
      // dialog's destructive button) — target the dialog's TextButton.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Sign out'),
        ),
      );
      await tester.pumpAndSettle();

      // Token cleared.
      expect(container.read(authTokenProvider), isNull);

      // Outbox cleared.
      expect(outboxBox.length, equals(0));

      // Router landed on /onboarding/1.
      final routerCtx = tester.element(find.byType(MaterialApp));
      final uri = GoRouter.of(routerCtx)
          .routerDelegate
          .currentConfiguration
          .uri;
      expect(uri.path, equals('/onboarding/1'));
    },
  );

  testWidgets(
    'Cancel on the destructive dialog leaves token + outbox untouched',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();

      final routerContext = tester.element(find.byType(MaterialApp));
      GoRouter.of(routerContext).go('/me');
      await tester.pumpAndSettle();

      final seedToken = container.read(authTokenProvider);
      expect(seedToken, isNotNull);

      await tester.ensureVisible(find.byKey(const Key('sign-out-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign-out-row')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Cancel'),
        ),
      );
      await tester.pumpAndSettle();

      // No state change.
      expect(container.read(authTokenProvider), equals(seedToken));
      expect(outboxBox.length, equals(2));

      // Still on /me.
      final uri = GoRouter.of(tester.element(find.byType(MaterialApp)))
          .routerDelegate
          .currentConfiguration
          .uri;
      expect(uri.path, equals('/me'));
    },
  );
}
