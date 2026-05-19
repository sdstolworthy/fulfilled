import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// SC-001 — `SearchField` hint-copy predicate.
///
/// Acceptance:
/// - On native (kIsWeb == false): default hint reads "Search foods or
///   scan barcode…" (the camera-button affordance is visible).
/// - On web (kIsWeb == true): default hint reads "Search foods or
///   paste a barcode…" (the camera button is hidden; T-021 paste path
///   is the canonical entry).
/// - An explicit [hintText] override wins on both targets.
///
/// `kIsWeb` is a compile-time constant, so we cannot flip it from a
/// VM test. The runtime assertions below branch on `kIsWeb` so the
/// suite is correct on whichever target the test runs.
Widget _harness(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('default hint reads "scan barcode" on native mobile',
      (tester) async {
    if (kIsWeb) return; // web target — see other test below.
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _harness(SearchField(controller: controller, onChanged: (_) {})),
    );

    expect(find.text('Search foods or scan barcode…'), findsOneWidget);
    expect(find.text('Search foods or paste a barcode…'), findsNothing);
  });

  testWidgets('default hint reads "paste a barcode" on kIsWeb',
      (tester) async {
    if (!kIsWeb) return; // native target — see other test above.
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _harness(SearchField(controller: controller, onChanged: (_) {})),
    );

    expect(find.text('Search foods or paste a barcode…'), findsOneWidget);
    expect(find.text('Search foods or scan barcode…'), findsNothing);
  });

  testWidgets('explicit hintText override wins on both targets',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _harness(SearchField(
        controller: controller,
        onChanged: (_) {},
        hintText: 'Custom hint',
      ),),
    );

    expect(find.text('Custom hint'), findsOneWidget);
    expect(find.text('Search foods or scan barcode…'), findsNothing);
    expect(find.text('Search foods or paste a barcode…'), findsNothing);
  });
}
