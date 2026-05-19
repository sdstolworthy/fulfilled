import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/activity_option.dart';

/// T-002 — `ActivityOption` canonical widget.
///
/// Acceptance criteria:
/// - Renders title + subtitle.
/// - Selected vs unselected differ in container background.
/// - Tap emits `onTap()`.
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders title and subtitle', (tester) async {
    await tester.pumpWidget(
      _harness(
        ActivityOption(
          title: 'Sedentary',
          subtitle: 'Mostly sitting, little exercise',
          selected: false,
          onTap: () {},
        ),
      ),
    );

    expect(find.text('Sedentary'), findsOneWidget);
    expect(find.text('Mostly sitting, little exercise'), findsOneWidget);
  });

  testWidgets('selected vs unselected use distinct backgrounds',
      (tester) async {
    Color? surface;
    Color? accentSoft;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          surface = context.colors.surface;
          accentSoft = context.colors.accentSoft;
          return Column(
            children: <Widget>[
              ActivityOption(
                key: const Key('unsel'),
                title: 'A',
                subtitle: 'a',
                selected: false,
                onTap: () {},
              ),
              ActivityOption(
                key: const Key('sel'),
                title: 'B',
                subtitle: 'b',
                selected: true,
                onTap: () {},
              ),
            ],
          );
        },),
      ),
    );

    BoxDecoration decorationOf(Key key) {
      // The outer card is the first Container in the subtree that has a
      // BoxDecoration with a non-null `color`. The `_RadioDot`'s inner
      // Container uses a `BoxShape.circle` decoration with no `color` so
      // it's skipped automatically.
      final container = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(Container),
            ),
          )
          .firstWhere(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).color != null,
          );
      return container.decoration! as BoxDecoration;
    }

    expect(decorationOf(const Key('unsel')).color, equals(surface));
    expect(decorationOf(const Key('sel')).color, equals(accentSoft));
  });

  testWidgets('tap emits onTap()', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        ActivityOption(
          title: 'Light',
          subtitle: 'Walks',
          selected: false,
          onTap: () => taps += 1,
        ),
      ),
    );

    await tester.tap(find.text('Light'));
    await tester.pump();
    expect(taps, equals(1));
  });

  testWidgets('null onTap disables the row (no taps register)',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const ActivityOption(
          title: 'Disabled',
          subtitle: 'while saving',
          selected: false,
          onTap: null,
        ),
      ),
    );

    // No exception when tapped, but nothing fires.
    await tester.tap(find.text('Disabled'));
    await tester.pump();
  });
}
