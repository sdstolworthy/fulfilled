import 'dart:async';

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
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/height_stepper.dart';
import 'package:fulfilled/widgets/skeleton.dart';

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

    // Data section. QL-106 cut the Export data row entirely (PM audit
    // QL-007 / architect §7.3 — the no-op "Coming soon" stub was a
    // trust eroder; real Export is a v1.1 surface).
    expect(find.text('My foods'), findsOneWidget);
    expect(find.text('14'), findsOneWidget);
    expect(find.text('Export data'), findsNothing);

    // Sign-out row.
    expect(find.text('Sign out'), findsOneWidget);

    // Version footnote.
    expect(find.text('Fulfilled · v0.1.0 (dev)'), findsOneWidget);
  });

  // QL-106 regression — the trailing "Edit" affordance on the identity
  // row used to surface a "Coming soon" SnackBar (no real identity
  // editor in v1). PM audit QL-007 ruled the stub eroded trust; the row
  // is cut entirely until the editor lands. The avatar + name + email
  // remain as informational identity chrome.
  testWidgets('Identity row does NOT render an Edit affordance',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    // The avatar's initials + name + email remain.
    expect(find.text('Spencer Stolworthy'), findsOneWidget);
    expect(find.text('sdstolworthy@gmail.com'), findsOneWidget);

    // The trailing TextButton labeled "Edit" is gone.
    expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
  });

  // QL-106 regression — no "Coming soon" SnackBar should ever surface
  // from this screen because the two rows that triggered it are gone.
  testWidgets('Coming-soon copy never appears in the Profile screen',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(user: _mockUser()));
    await tester.pumpAndSettle();

    expect(find.text('Coming soon'), findsNothing);
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

    // The bottom-sheet editor shell now composes the lifted
    // `HeightStepper` (QL-104 rewrote the inline `height-field`
    // TextField + clamp logic away).
    expect(find.byType(HeightStepper), findsOneWidget);
    // Title is rendered in the editor shell.
    expect(find.widgetWithText(Padding, 'Height'), findsWidgets);
    // The HeightStepper is seeded from the current user height
    // (182 cm) — the visible number under the cm unit overrides.
    expect(find.text('182'), findsOneWidget);
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

  // T-013 — `_ProfileSkeleton` used to render a `CircularProgressIndicator`;
  // it now lives on the lifted `Skeleton` primitive. Pin both halves so a
  // regression that pulls the spinner back in fails loudly.
  testWidgets('loading state renders Skeleton, never CircularProgressIndicator',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final completer = Completer<User>();
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(_mockUser());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          meProvider.overrideWith((ref) => completer.future),
          customFoodCountProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Skeleton), findsWidgets);
  });

  testWidgets(
      'error branch renders the lifted EmptyState with a retry CTA',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          meProvider.overrideWith((_) async => throw Exception('boom')),
          customFoodCountProvider.overrideWith((_) async => 0),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const Scaffold(body: ProfileScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text("Couldn't load profile"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
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
