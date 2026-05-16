import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/widgets/permission_denied.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/primary_button.dart';

/// SC-003 — `PermissionDenied`.
///
/// Two slices of the acceptance criteria:
///
/// 1. The widget renders an [EmptyState] with the exact title and body
///    copy the SC-003 spec named ("Camera access is off" / "Open
///    Settings → Privacy → Camera → Fulfilled to turn it on, then come
///    back here.") plus the `Icons.no_photography_outlined` glyph
///    architect §3.9 specified.
/// 2. The action slot is a [PrimaryButton] labelled "Go back"; tapping
///    it pops the route. We push the widget onto a `Navigator` so
///    `Navigator.pop` is observable as a route disappearance.

Widget _hostedHarness(Widget child) {
  // The "Go back" button calls `Navigator.of(context).pop()`. Mount
  // the widget below an opening route so the pop is observable.
  return MaterialApp(
    theme: buildLightTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(body: child),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders EmptyState with the documented copy and icon',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: PermissionDenied()),
      ),
    );

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Camera access is off'), findsOneWidget);
    // The body copy is asserted verbatim — the SC-003 spec names the
    // exact wording.
    expect(
      find.text(
        'We need camera access to scan barcodes. '
        'Open Settings → Privacy → Camera → Fulfilled '
        'to turn it on, then come back here.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
  });

  testWidgets('action is a "Go back" PrimaryButton', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: PermissionDenied()),
      ),
    );

    expect(find.byType(PrimaryButton), findsOneWidget);
    expect(find.text('Go back'), findsOneWidget);
  });

  testWidgets('"Go back" pops the route', (tester) async {
    await tester.pumpWidget(_hostedHarness(const PermissionDenied()));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionDenied), findsOneWidget);

    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionDenied), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
