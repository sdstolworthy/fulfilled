// UX-112 Theme D — narrow fix: disable Save when unchanged.
//
// PM UX pack §3 Theme D (MODIFIED): accept the "disable when
// unchanged" rule for [HeightStepperSheet] and [CurrentWeightSheet]
// — the two silent no-op-PATCH cases. Defer the broader audit + lint
// rule to v1.1.
//
// Acceptance:
// 1. HeightStepperSheet's Save button is disabled when the user has
//    not changed the seeded value.
// 2. After bumping the value, Save enables.
// 3. CurrentWeightSheet's Save button is disabled when the user has
//    not changed the seeded value.
// 4. After bumping the value, Save enables.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/profile/widgets/current_weight_sheet.dart';
import 'package:fulfilled/features/profile/widgets/height_stepper_sheet.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/repositories/weight_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';

class _FakeProfileRepository implements ProfileRepository {
  final List<UserPatch> patches = <UserPatch>[];

  @override
  Future<User> me() async => throw UnimplementedError();

  @override
  Future<User> update(UserPatch data) async {
    patches.add(data);
    return User(
      id: 'u_fake',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      heightCm: data.heightCm,
    );
  }
}

Widget _heightHarness({
  required _FakeProfileRepository repo,
  required Decimal initial,
  HeightUnit unit = HeightUnit.cm,
}) {
  return ProviderScope(
    overrides: <Override>[
      profileRepositoryProvider.overrideWithValue(repo),
      localeDefaultHeightUnitProvider.overrideWithValue(unit),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showHeightStepperSheet(ctx, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _weightHarness({required Decimal initial}) {
  // CurrentWeightSheet calls `weightRepositoryProvider` which the
  // default ProviderScope resolves to a real `WeightRepository` over
  // a `Dio` ApiClient. The mock latency + mock create path are fine
  // for the "disable when unchanged" path because we never tap Save
  // in the disabled scenario; the bumped-then-enabled scenario also
  // doesn't need to tap Save — we assert the button's `onPressed`
  // changes, not that the request actually fires.
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showCurrentWeightSheet(ctx, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WeightRepository.resetForTesting();
  });

  group('HeightStepperSheet — disable save when unchanged', () {
    testWidgets('Save is disabled on first paint', (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository();
      await tester.pumpWidget(_heightHarness(
        repo: repo,
        initial: Decimal.fromInt(175),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The save button is rendered but disabled — its `onPressed` is
      // null because `_isDirty()` returns false against the seed.
      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNull,
          reason: 'Save should be disabled when the value equals the seed');
    });

    testWidgets('Save enables after bumping the value', (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository();
      await tester.pumpWidget(_heightHarness(
        repo: repo,
        initial: Decimal.fromInt(175),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Bump by one cm via the stepper's increment affordance.
      await tester.tap(find.bySemanticsLabel('Increment').first);
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNotNull,
          reason: 'Save should enable once the value differs from seed');
    });
  });

  group('CurrentWeightSheet — disable save when unchanged', () {
    testWidgets('Save is disabled on first paint', (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_weightHarness(initial: Decimal.parse('70.0')));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNull,
          reason: 'Save should be disabled when weight equals the seed');
    });

    testWidgets('Save enables after bumping the value', (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_weightHarness(initial: Decimal.parse('70.0')));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Bump via the WeightStepper's Increment affordance.
      await tester.tap(find.bySemanticsLabel('Increment').first);
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNotNull,
          reason: 'Save should enable once weight differs from seed');
    });
  });
}
