import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/search/widgets/barcode_scan_button.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// SC-001 — `BarcodeScanButton` rewrite.
///
/// Acceptance criteria covered:
/// - Hides on `kIsWeb` regardless of width (compact / medium / expanded).
/// - Renders on native mobile compact + medium + expanded.
/// - `onPressedOverride` is honored when set.
/// - No `HapticFeedback.selectionClick()` fires on tap (per PM §6;
///   haptics are a success signal, not a tap confirmation).
///
/// `kIsWeb` is a compile-time constant — the assertions below branch on
/// it so the suite is correct on either target (`flutter test` /
/// `flutter test --platform chrome`).
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('hide rule', () {
    testWidgets('hides on web at all widths (compact / medium / expanded)',
        (tester) async {
      // We can't flip `kIsWeb` at runtime. On the web test target we
      // assert the SizedBox.shrink() shape; on the VM target we skip
      // this test since the rule only kicks in on web.
      if (!kIsWeb) return;

      for (final size in <Size>[
        const Size(390, 844), // compact
        const Size(800, 1024), // medium
        const Size(1280, 800), // expanded
      ]) {
        _setViewport(tester, size);
        await tester.pumpWidget(_harness(const BarcodeScanButton()));
        await tester.pump();

        // SizedBox.shrink() collapses to zero size; the visible 44×44
        // container is gone.
        expect(find.byType(InkResponse), findsNothing);
        expect(find.byTooltip('Scan barcode'), findsNothing);
      }
    });

    testWidgets('renders on native compact (390 × 844)', (tester) async {
      if (kIsWeb) return; // web target — see hide rule test above.
      _setViewport(tester, const Size(390, 844));

      await tester.pumpWidget(_harness(const BarcodeScanButton()));
      await tester.pump();

      expect(find.byTooltip('Scan barcode'), findsOneWidget);
    });

    testWidgets('renders on native medium (800 × 1024)', (tester) async {
      if (kIsWeb) return;
      _setViewport(tester, const Size(800, 1024));

      await tester.pumpWidget(_harness(const BarcodeScanButton()));
      await tester.pump();

      expect(find.byTooltip('Scan barcode'), findsOneWidget);
    });

    testWidgets('renders on native expanded (1280 × 800)', (tester) async {
      if (kIsWeb) return;
      _setViewport(tester, const Size(1280, 800));

      await tester.pumpWidget(_harness(const BarcodeScanButton()));
      await tester.pump();

      expect(find.byTooltip('Scan barcode'), findsOneWidget);
    });
  });

  group('tap behaviour', () {
    testWidgets('onPressedOverride is invoked on tap (native target)',
        (tester) async {
      if (kIsWeb) return; // hide rule covers web — see group above.
      _setViewport(tester, const Size(390, 844));

      var calls = 0;
      await tester.pumpWidget(
        _harness(
          BarcodeScanButton(
            onPressedOverride: (_) async {
              calls++;
            },
          ),
        ),
      );

      await tester.tap(find.byTooltip('Scan barcode'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets('does NOT fire HapticFeedback.selectionClick on tap',
        (tester) async {
      if (kIsWeb) return;
      _setViewport(tester, const Size(390, 844));

      final methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        methodCalls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(
        _harness(
          BarcodeScanButton(
            onPressedOverride: (_) async {},
          ),
        ),
      );

      await tester.tap(find.byTooltip('Scan barcode'));
      await tester.pumpAndSettle();

      final hapticCalls = methodCalls.where(
        (c) => c.method == 'HapticFeedback.vibrate' &&
            (c.arguments == 'HapticFeedbackType.selectionClick'),
      );
      expect(hapticCalls, isEmpty);
    });
  });
}
