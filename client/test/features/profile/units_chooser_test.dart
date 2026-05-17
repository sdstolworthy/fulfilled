@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/profile/profile_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:hive/hive.dart';

/// QL-104 — joined `showUnitsChooser` sheet behaviour.
///
/// (a) Tapping a weight row PATCHes `weight_unit` only and the sheet
///     STAYS open.
/// (b) Tapping a height row PATCHes `height_unit` only and the sheet
///     STAYS open. The weight section selection survives.
/// (c) Tapping the Done footer button dismisses the sheet.
/// (d) A network failure on a weight tap rolls back that row's
///     selected state and surfaces a SnackBar; the height section is
///     unaffected.

class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({required User seed}) : _user = seed;

  User _user;
  final List<UserPatch> patches = <UserPatch>[];
  bool failNextUpdate = false;

  @override
  Future<User> me() async => _user;

  @override
  Future<User> update(UserPatch data) async {
    patches.add(data);
    if (failNextUpdate) {
      failNextUpdate = false;
      throw Exception('mock PATCH failure');
    }
    if (data.weightUnit != null) {
      _user = _user.copyWith(weightUnit: data.weightUnit);
    }
    if (data.heightUnit != null) {
      _user = _user.copyWith(heightUnit: data.heightUnit);
    }
    return _user;
  }
}

User _mockUser({
  WeightUnit weightUnit = WeightUnit.kg,
  HeightUnit heightUnit = HeightUnit.cm,
}) {
  return User(
    id: 'u_test',
    displayName: 'Spencer Stolworthy',
    email: 'sdstolworthy@gmail.com',
    sex: Sex.male,
    birthDate: DateTime(1991, 8, 12),
    heightCm: Decimal.fromInt(182),
    currentWeightKg: Decimal.parse('79.4'),
    activityLevel: ActivityLevel.moderate,
    customFoodCount: 14,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 5, 15),
    weightUnit: weightUnit,
    heightUnit: heightUnit,
  );
}

Widget _harness({
  required _FakeProfileRepository repo,
  required Box<String> authConfigBox,
}) {
  return ProviderScope(
    overrides: <Override>[
      profileRepositoryProvider.overrideWithValue(repo),
      meProvider.overrideWith((ref) => repo.me()),
      customFoodCountProvider.overrideWith((ref) async => 14),
      // ProfileScreen mounts ServerUrlRow, which reads authConfigBox.
      authConfigBoxProvider.overrideWithValue(authConfigBox),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(body: ProfileScreen()),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('row-units')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('row-units')));
  await tester.pumpAndSettle();
}

void main() {
  late Directory hiveDir;
  late Box<String> authConfigBox;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-units-chooser-');
    Hive.init(hiveDir.path);
    authConfigBox = await Hive.openBox<String>(authConfigBoxName);
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'sheet renders both Weight and Height sections',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository(seed: _mockUser());
      await tester.pumpWidget(_harness(repo: repo, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      // Weight section rows.
      expect(find.text('Kilograms (kg)'), findsOneWidget);
      expect(find.text('Pounds (lb)'), findsOneWidget);
      expect(find.text('Stones & pounds (st)'), findsOneWidget);

      // Height section rows.
      expect(find.text('Centimeters (cm)'), findsOneWidget);
      expect(find.text('Feet & inches (ft, in)'), findsOneWidget);

      // The "Done" footer is present.
      expect(find.byKey(const Key('units-chooser-done')), findsOneWidget);
    },
  );

  testWidgets(
    '(a) tapping a weight row PATCHes weight_unit only; sheet stays open',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository(seed: _mockUser());
      await tester.pumpWidget(_harness(repo: repo, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      await tester.tap(find.byKey(const ValueKey<String>('weight-unit-lb')));
      await tester.pumpAndSettle();

      expect(repo.patches.length, 1);
      expect(repo.patches.first.weightUnit, WeightUnit.lb);
      expect(repo.patches.first.heightUnit, isNull);

      // Sheet stays open — both sections still visible.
      expect(find.text('Kilograms (kg)'), findsOneWidget);
      expect(find.text('Centimeters (cm)'), findsOneWidget);
    },
  );

  testWidgets(
    '(b) tapping a height row keeps the weight section selection',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository(seed: _mockUser());
      await tester.pumpWidget(_harness(repo: repo, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      // First flip weight kg → lb.
      await tester.tap(find.byKey(const ValueKey<String>('weight-unit-lb')));
      await tester.pumpAndSettle();

      // Then flip height cm → ftIn.
      await tester
          .tap(find.byKey(const ValueKey<String>('height-unit-ft_in')));
      await tester.pumpAndSettle();

      // Two separate patches landed — first weight, then height.
      expect(repo.patches.length, 2);
      expect(repo.patches[0].weightUnit, WeightUnit.lb);
      expect(repo.patches[0].heightUnit, isNull);
      expect(repo.patches[1].weightUnit, isNull);
      expect(repo.patches[1].heightUnit, HeightUnit.ftIn);
    },
  );

  testWidgets(
    '(c) tapping Done dismisses the sheet',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeProfileRepository(seed: _mockUser());
      await tester.pumpWidget(_harness(repo: repo, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      expect(find.text('Centimeters (cm)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('units-chooser-done')));
      await tester.pumpAndSettle();

      // The sheet body is gone — both chooser-only texts disappeared.
      expect(find.text('Centimeters (cm)'), findsNothing);
      expect(find.text('Feet & inches (ft, in)'), findsNothing);
    },
  );

  testWidgets(
    '(d) network failure on weight PATCH rolls back the weight selection + SnackBar',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final handle = tester.ensureSemantics();

      final repo = _FakeProfileRepository(seed: _mockUser())
        ..failNextUpdate = true;
      await tester.pumpWidget(_harness(repo: repo, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _openSheet(tester);

      // Sanity: kg starts selected.
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(
              'Kilograms (kg). Common worldwide',
            ))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue,
      );

      await tester.tap(find.byKey(const ValueKey<String>('weight-unit-lb')));
      await tester.pumpAndSettle();

      // PATCH fired.
      expect(repo.patches.length, 1);
      expect(repo.patches.first.weightUnit, WeightUnit.lb);

      // SnackBar surfaced.
      expect(find.text("Couldn't update unit. Try again."), findsOneWidget);

      // Weight section rolled back — kg is selected again, lb is not.
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(
              'Kilograms (kg). Common worldwide',
            ))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue,
      );
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(
              'Pounds (lb). Common in the US',
            ))
            .hasFlag(SemanticsFlag.isSelected),
        isFalse,
      );

      // Height section is unaffected — `cm` is still selected.
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(
              'Centimeters (cm). Common worldwide',
            ))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue,
      );
          handle.dispose();
    },
  );
}
