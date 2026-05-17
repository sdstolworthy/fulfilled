import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/features/profile/widgets/server_url_row.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:hive/hive.dart';

/// Tests for `ServerUrlRow` (LOG-009).
///
/// Covers the two PM-§10-punt-list-promotion cases the ticket names:
///   - **Case 1** — Hive `baseUrl` seeded with a real URL: the row
///     renders that URL as subtitle text.
///   - **Case 2** — empty Hive box (fresh install, pre-first-login):
///     the row collapses to `SizedBox.shrink()` — no visible chrome.
///
/// Read-only contract (PM §10 anti-recommendation 10): the row has no
/// `onTap`, no trailing chevron, no edit affordance. Case 1 also pins
/// the read-only shape so a future regression that adds a tappable
/// affordance fails loudly.
///
/// Mirrors the `_FakeBox` pattern from
/// `test/data/api_base_url_provider_test.dart` — implements just
/// enough of `Box<String>` for `box.get(key)`.

class _FakeBox implements Box<String> {
  _FakeBox(this._values);
  final Map<String, String?> _values;

  @override
  String? get(dynamic key, {String? defaultValue}) {
    if (_values.containsKey(key)) return _values[key];
    return defaultValue;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _harness({required Box<String> box}) {
  return ProviderScope(
    overrides: <Override>[
      authConfigBoxProvider.overrideWithValue(box),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(body: ServerUrlRow()),
    ),
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets(
    'Case 1: seeded baseUrl renders as the subtitle text',
    (tester) async {
      const seededUrl = 'https://a.example/api/v1';
      await tester.pumpWidget(
        _harness(
          box: _FakeBox(<String, String?>{
            AuthConfigKey.baseUrl: seededUrl,
          }),
        ),
      );
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
    'Case 2: empty Hive box collapses to SizedBox.shrink (no visible chrome)',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          box: _FakeBox(<String, String?>{}),
        ),
      );
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
    'Case 2 (empty-string variant): empty string baseUrl also collapses',
    (tester) async {
      // The widget guard is `url == null || url.isEmpty` — pin the
      // empty-string branch alongside the missing-key branch so a
      // regression that drops the `isEmpty` half fails loudly.
      await tester.pumpWidget(
        _harness(
          box: _FakeBox(<String, String?>{
            AuthConfigKey.baseUrl: '',
          }),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      expect(find.text('Server'), findsNothing);
    },
  );
}
