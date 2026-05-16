import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/weight/widgets/log_weight_sheet.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// UX-109 — F5 pre-fill tests for `LogWeightSheet`.
///
/// Covers the four branches the architect's seed fall-through chain
/// guarantees (architect_ux_pack.md §5.2):
///
///   (a) `weightHistoryProvider` non-empty → seed from
///       `history.first.weightKg`. Asserted in display unit (`lb`)
///       to also exercise T-21 unit rendering through the seed path.
///   (b) `weightHistoryProvider` empty AND `me.currentWeightKg` non-null
///       → seed from `me.currentWeightKg`.
///   (c) Both null → fall through to `Decimal.parse('70')`.
///   (d) User can override the resolved pre-fill by typing — the
///       seed is read once, not watched, so re-renders cannot
///       silently overwrite the user's input.
///
/// The sheet is hosted inside a `MaterialApp` + `Scaffold` directly
/// rather than via `showModalBottomSheet` so the assertions can target
/// the `LogWeightSheet` subtree without juggling the modal route's
/// pump timing. The widget under test is identical either way — the
/// sheet's body composition is unaffected by its host.

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

WeightEntry _entry(double kg, {int daysAgo = 0}) {
  final date = _today().subtract(Duration(days: daysAgo));
  return WeightEntry(
    id: 'w_$daysAgo',
    recordedOn: date,
    weightKg: Decimal.parse(kg.toStringAsFixed(1)),
    createdAt: date,
  );
}

User _user({Decimal? currentWeightKg, WeightUnit weightUnit = WeightUnit.kg}) {
  final now = _today();
  return User(
    id: 'u_test',
    createdAt: now,
    updatedAt: now,
    currentWeightKg: currentWeightKg,
    weightUnit: weightUnit,
  );
}

Widget _harness({
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(
        body: LogWeightSheet(currentRange: WeightRange.oneMonth),
      ),
    ),
  );
}

void main() {
  // The sheet's `WeightStepper` honours `weightUnitProvider` from the
  // active user. Every test seeds `meProvider` with a deterministic
  // `User` so the displayed unit is pinned for the assertions.

  testWidgets(
      'seed from non-empty history — renders newest entry in user\'s unit',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Architect §5.2 worked example: 79.6 kg history entry with
    // `weightUnit: lb` renders the stepper at `175.5 lb` (half-to-even
    // round of 79.6 / _kgPerLb at one decimal place).
    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          weightHistoryProvider.overrideWith(
            (_) async => <WeightEntry>[
              _entry(79.6, daysAgo: 0),
              _entry(80.0, daysAgo: 2),
            ],
          ),
          meProvider.overrideWith(
            (_) async => _user(
              currentWeightKg: Decimal.parse('80.0'),
              weightUnit: WeightUnit.lb,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The stepper renders the seed in the user's display unit (lb).
    // The chrome puts the numeric in a `TextField` next to a static
    // unit suffix — assert both, since `formatWeightWithUnit` is not
    // what the stepper renders for the active field.
    expect(find.text('175.5'), findsOneWidget);
    expect(find.text('lb'), findsWidgets);
    // Not seeded from `currentWeightKg` (which would have rendered as
    // `176.4 lb` for 80.0 kg) — confirms branch (a) won the chain.
    expect(find.text('176.4'), findsNothing);
  });

  testWidgets(
      'seed from me.currentWeightKg when history is empty',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          weightHistoryProvider.overrideWith(
            (_) async => const <WeightEntry>[],
          ),
          meProvider.overrideWith(
            (_) async => _user(
              currentWeightKg: Decimal.parse('72'),
              weightUnit: WeightUnit.kg,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 72 kg in `kg` mode renders as `72.0 kg`.
    expect(find.text('72.0'), findsOneWidget);
    expect(find.text('kg'), findsWidgets);
  });

  testWidgets(
      'fall-through to 70 kg when neither history nor currentWeightKg is set',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          weightHistoryProvider.overrideWith(
            (_) async => const <WeightEntry>[],
          ),
          meProvider.overrideWith(
            (_) async => _user(weightUnit: WeightUnit.kg),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Paranoid default — same value the pre-F5 code used.
    expect(find.text('70.0'), findsOneWidget);
    expect(find.text('kg'), findsWidgets);
  });

  testWidgets(
      'user can override the pre-fill by typing',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          weightHistoryProvider.overrideWith(
            (_) async => <WeightEntry>[_entry(79.4)],
          ),
          meProvider.overrideWith(
            (_) async => _user(
              currentWeightKg: Decimal.parse('79.4'),
              weightUnit: WeightUnit.kg,
            ),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Pre-fill landed.
    expect(find.text('79.4'), findsOneWidget);

    // The user types over the pre-filled value. The single kg/lb
    // `TextField` lives inside `WeightStepper`; `enterText` targets it
    // by matching on the current displayed text.
    await tester.enterText(find.text('79.4'), '81.2');
    // Commit by submitting — the stepper's focus-loss / submit handler
    // round-trips through `parseWeightToKg` and re-seeds the controller
    // with the canonical glyph. Submitting (vs. blurring) lets us stay
    // independent of focus traversal quirks in the test harness.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // The override stuck — the seed didn't reassert itself.
    expect(find.text('81.2'), findsOneWidget);
    expect(find.text('79.4'), findsNothing);
  });
}
