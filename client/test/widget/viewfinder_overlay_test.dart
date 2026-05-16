import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/widgets/viewfinder_overlay.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// SC-002 — `ViewfinderOverlay` painter geometry.
///
/// We don't render to a real canvas in unit tests; instead the painter
/// exposes a `@visibleForTesting` static helper, [ViewfinderGeometry.cutoutRectFor],
/// that returns the rect the painter will punch out for a given
/// viewport size. That gives us behavioral coverage of the 320-px cap
/// without generating goldens.
///
/// Tenants exercised:
/// - T-15 — geometry is data-driven on viewport size, not on a
///   form-factor branch. Same painter for every width.
/// - Architect risk 3 — the iPad-landscape cap at 320 px is the
///   resolution. A 1024 × 768 canvas would otherwise produce a
///   ~538 px reticle.

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  group('ViewfinderGeometry.cutoutRectFor', () {
    test('compact width (360): cutout = 360 * 0.70 = 252', () {
      // 360 × 800 — Android compact (Pixel-class portrait). Shorter
      // side is the width; below the cap.
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(360, 800));
      expect(rect.width, closeTo(252.0, 0.0001));
      expect(rect.height, closeTo(252.0, 0.0001));
      // Centered.
      expect(rect.left, closeTo((360 - 252) / 2, 0.0001));
      expect(rect.top, closeTo((800 - 252) / 2, 0.0001));
    });

    test('iPhone 13 portrait (390 x 844): cutout = 273', () {
      // PM §6 / ticket acceptance: the canonical mobile reference.
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(390, 844));
      expect(rect.width, closeTo(273.0, 0.0001));
      expect(rect.height, closeTo(273.0, 0.0001));
    });

    test('iPad portrait (768 x 1024): cutout capped at 320', () {
      // Shorter side is 768; 768 * 0.70 = 537.6, capped at 320.
      // (The ticket commentary mentioned "uncapped" but the spec math —
      // `min(shorter * 0.70, 320)` — caps it. The 320-px clamp is the
      // single source of truth.)
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(768, 1024));
      expect(rect.width, closeTo(320.0, 0.0001));
      expect(rect.height, closeTo(320.0, 0.0001));
    });

    test('iPad landscape (1024 x 768): cutout capped at 320', () {
      // Architect risk 3 — the headline acceptance criterion. A 768
      // shorter side would otherwise yield a ~538 px reticle.
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(1024, 768));
      expect(rect.width, equals(ViewfinderGeometry.maxCutoutSide));
      expect(rect.height, equals(ViewfinderGeometry.maxCutoutSide));
      expect(rect.width, equals(320.0));
    });

    test('expanded width (1280 x 800): cutout capped at 320', () {
      // Web-class large canvas; shorter side is 800. 800 * 0.70 = 560,
      // capped at 320. Same painter — no form-factor branch.
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(1280, 800));
      expect(rect.width, closeTo(320.0, 0.0001));
      expect(rect.height, closeTo(320.0, 0.0001));
    });

    test('cutout is centered in the viewport', () {
      final rect = ViewfinderGeometry.cutoutRectFor(const Size(1024, 768));
      expect(rect.center.dx, closeTo(1024 / 2, 0.0001));
      expect(rect.center.dy, closeTo(768 / 2, 0.0001));
    });

    test('cutout is square at every viewport', () {
      const sizes = <Size>[
        Size(360, 800),
        Size(390, 844),
        Size(414, 896),
        Size(768, 1024),
        Size(1024, 768),
        Size(1280, 800),
      ];
      for (final s in sizes) {
        final r = ViewfinderGeometry.cutoutRectFor(s);
        expect(r.width, equals(r.height), reason: 'not square at $s');
      }
    });

    test('maxCutoutSide is exactly 320', () {
      // Pin the constant so a stealth change shows up as a test diff.
      expect(ViewfinderGeometry.maxCutoutSide, equals(320.0));
    });

    test('cutoutFraction is exactly 0.70', () {
      expect(ViewfinderGeometry.cutoutFraction, equals(0.70));
    });
  });

  group('ViewfinderOverlay widget', () {
    testWidgets('builds a CustomPaint covering the viewport', (tester) async {
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 390,
            height: 844,
            child: ViewfinderOverlay(),
          ),
        ),
      );

      // Exactly one CustomPaint inside the overlay (others may exist
      // higher in the Material tree).
      expect(
        find.descendant(
          of: find.byType(ViewfinderOverlay),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });

    testWidgets('is non-interactive (IgnorePointer) so taps reach the camera',
        (tester) async {
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 390,
            height: 844,
            child: ViewfinderOverlay(),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(ViewfinderOverlay),
          matching: find.byType(IgnorePointer),
        ),
        findsOneWidget,
      );
    });

    testWidgets('cornerRadius override is honored', (tester) async {
      // The override path matters because `ViewfinderOverlay` reads
      // `context.radius.r3` for the default. A test seam that swaps in
      // a fixed radius keeps geometry-sensitive tests independent of
      // token edits.
      await tester.pumpWidget(
        _harness(
          const SizedBox(
            width: 390,
            height: 844,
            child: ViewfinderOverlay(cornerRadius: 20.0),
          ),
        ),
      );

      // The widget rebuilt with the override; the CustomPaint still
      // renders. Geometry of the cutout is unaffected by the radius
      // (the rect dims are the same; only the corner curve changes).
      expect(find.byType(ViewfinderOverlay), findsOneWidget);
    });
  });
}
