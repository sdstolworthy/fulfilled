import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/profile/widgets/server_url_row.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// Tests for `ServerUrlRow` (LOG-009).
///
/// Covers the two PM-§10-punt-list-promotion cases the ticket names:
///   - **Case 1** — a real URL passed in: the row renders that URL as
///     subtitle text.
///   - **Case 2** — `null` / empty URL (fresh install, pre-first-login):
///     the row collapses to `SizedBox.shrink()` — no visible chrome.
///
/// Read-only contract (PM §10 anti-recommendation 10): the row has no
/// `onTap`, no trailing chevron, no edit affordance. Case 1 also pins
/// the read-only shape so a future regression that adds a tappable
/// affordance fails loudly.
///
/// Pure presentation leaf under the passive-view rule
/// (`specs/testing_guide.md` §4.4): no `ProviderScope`, no overrides —
/// the resolved URL arrives by constructor param.

Widget _harness({required String? url}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: ServerUrlRow(url: url)),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets(
    'Case 1: a real URL renders as the subtitle text',
    (tester) async {
      const seededUrl = 'https://a.example/api/v1';
      await tester.pumpWidget(_harness(url: seededUrl));
      await tester.pumpAndSettle();

      // The row renders.
      expect(find.byType(ListTile), findsOneWidget);
      // Title is the static "Server" label.
      expect(find.text('Server'), findsOneWidget);
      // Subtitle is the seeded URL verbatim.
      expect(find.text(seededUrl), findsOneWidget);

      // Read-only contract — PM §10 anti-recommendation 10. The row
      // must not surface an edit affordance: no `onTap` handler, no
      // trailing chevron.
      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.onTap, isNull);
      expect(tile.trailing, isNull);
    },
  );

  testWidgets(
    'Case 2: null URL collapses to SizedBox.shrink (no visible chrome)',
    (tester) async {
      await tester.pumpWidget(_harness(url: null));
      await tester.pumpAndSettle();

      // No ListTile chrome rendered on the signed-out path.
      expect(find.byType(ListTile), findsNothing);
      // No labels leak through.
      expect(find.text('Server'), findsNothing);
      // The widget builds a `SizedBox.shrink()` — a zero-sized
      // SizedBox. `findsOneWidget` would over-bind to any incidental
      // SizedBox the harness inserts; use `findsWidgets` and assert
      // at least one has a zero size.
      final shrunk = tester.widgetList<SizedBox>(find.byType(SizedBox)).where(
            (s) => s.width == 0.0 && s.height == 0.0,
          );
      expect(shrunk, isNotEmpty);
    },
  );

  testWidgets(
    'Case 2 (empty-string variant): empty URL also collapses',
    (tester) async {
      // The widget guard is `url == null || url.isEmpty` — pin the
      // empty-string branch alongside the null branch so a regression
      // that drops the `isEmpty` half fails loudly.
      await tester.pumpWidget(_harness(url: ''));
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Server'), findsNothing);
    },
  );
}
