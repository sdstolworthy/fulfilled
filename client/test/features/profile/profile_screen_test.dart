import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/profile/profile_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';

User _mockUser({
  String? displayName = 'Spencer Stolworthy',
  String? email = 'sdstolworthy@gmail.com',
  Sex? sex = Sex.male,
  ActivityLevel? activityLevel = ActivityLevel.moderate,
}) {
  return User(
    id: 'u_test',
    displayName: displayName,
    email: email,
    sex: sex,
    birthDate: DateTime(1991, 8, 12),
    heightCm: Decimal.fromInt(182),
    currentWeightKg: Decimal.parse('79.4'),
    activityLevel: activityLevel,
    customFoodCount: 14,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 5, 15),
  );
}

Widget _harness({
  required User user,
  int customFoodCount = 14,
}) {
  return ProviderScope(
    overrides: <Override>[
      meProvider.overrideWith((ref) async => user),
      customFoodCountProvider.overrideWith((ref) async => customFoodCount),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(body: ProfileScreen()),
    ),
  );
}

void main() {
  // Compact (390×844) phone viewport — the canonical mock width. The
  // foundation's expanded layout reads the same provider state; the
  // compact build is the one the mock pins.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('renders identity, body, preferences, data sections',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    // Identity row.
    expect(find.text('Me'), findsOneWidget);
    expect(find.text('Spencer Stolworthy'), findsOneWidget);
    expect(find.text('sdstolworthy@gmail.com'), findsOneWidget);

    // Body section labels — all five rows present.
    expect(find.text('Sex'), findsOneWidget);
    expect(find.text('Birth date'), findsOneWidget);
    expect(find.text('Height'), findsOneWidget);
    expect(find.text('Current weight'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);

    // Data section.
    expect(find.text('My foods'), findsOneWidget);
    expect(find.text('14'), findsOneWidget);
    expect(find.text('Export data'), findsOneWidget);

    // Sign-out row.
    expect(find.text('Sign out'), findsOneWidget);

    // Version footnote.
    expect(find.text('Fulfilled · v0.1.0 (dev)'), findsOneWidget);
  });

  testWidgets('does NOT render the Appearance row (PM Risk 5 regression)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    // PM Risk 5: the Appearance row is removed entirely from v1.
    // Dark mode + the toggle ship together in v2 alongside the dark
    // token sweep. Any reintroduction of this row must come with
    // working dark tokens — that's why this regression test exists.
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('System'), findsNothing); // mock's default value
    expect(find.text('Dark'), findsNothing);
    expect(find.text('Light'), findsNothing);
  });

  testWidgets('tapping the Height row opens the stepper sheet',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    // Ensure the Height row is on-screen.
    await tester.ensureVisible(find.byKey(const Key('row-height')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('row-height')));
    await tester.pumpAndSettle();

    // The bottom-sheet editor shell renders the title "Height" and
    // exposes the numeric field keyed `height-field`.
    expect(find.byKey(const Key('height-field')), findsOneWidget);
    // The text field is seeded with the user's current height.
    final field = tester.widget<TextField>(
      find.byKey(const Key('height-field')),
    );
    expect(field.controller?.text, equals('182'));
    // Title is rendered in the editor shell.
    expect(find.widgetWithText(Padding, 'Height'), findsWidgets);
  });

  testWidgets('Units row exists and is non-interactive (informational)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    // Units row is present (PM Risk 4 — kg/cm/kcal/g is informational
    // in v1; unit prefs surface in v2).
    expect(find.text('Units'), findsOneWidget);
    expect(find.byKey(const Key('row-units')), findsOneWidget);
  });

  testWidgets('Sign out row opens AlertDialog confirm', (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('sign-out-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sign-out-row')));
    await tester.pumpAndSettle();

    // T-11: destructive confirm uses AlertDialog.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Sign out?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });
}
