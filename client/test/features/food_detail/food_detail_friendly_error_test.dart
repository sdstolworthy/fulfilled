import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/food_detail/food_detail_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/snackbar_throttle.dart';

/// F2 — Lock in the FriendlyError mapping for the food-detail SnackBar.
///
/// The leak: pre-F2 the snackbar interpolated `${next.error}` directly,
/// so a `DioException` ended up as the user-facing message
/// (`DioException [bad response]: ... RequestOptions { ... }`). The
/// audit named this the primary error-leakage hotspot. The fix routes
/// the error through `FriendlyError.from(...)` so the snackbar shows a
/// human-readable label and the raw DioException debug string never
/// reaches the UI.
///
/// Two cases:
///
///   1. `DioException(statusCode: 500)` — server-class error → snackbar
///      reads "Something went wrong" and contains no `DioException` or
///      `RequestOptions` substring.
///   2. `FoodNotFoundError` — the existing guard short-circuits the
///      snackbar; the inline `_DetailError` renders "Food not found".

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SnackbarThrottle.resetForTest();
  });

  testWidgets('DioException(500) → snackbar says "Something went wrong" and '
      'leaks no DioException debug string', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final requestOptions = RequestOptions(path: '/foods/f_err_500');
    final err = DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 500,
      ),
      type: DioExceptionType.badResponse,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          foodDetailProvider('f_err_500')
              .overrideWith((_) async => throw err),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const FoodDetailScreen(foodId: 'f_err_500'),
        ),
      ),
    );
    // Settle through the error microtask + ref.listen post-frame.
    await tester.pump();
    await tester.pump();

    // The snackbar paints with the FriendlyError title for 5xx.
    expect(
      find.byType(SnackBar),
      findsOneWidget,
      reason: 'transient transport errors should still get a snackbar',
    );
    expect(
      find.text('Something went wrong'),
      findsOneWidget,
      reason: 'FriendlyError.from(DioException 500) → server-class title',
    );

    // None of the raw DioException debug-string fragments leak.
    expect(
      find.textContaining('DioException'),
      findsNothing,
      reason: 'the raw DioException toString must not reach the UI',
    );
    expect(
      find.textContaining('RequestOptions'),
      findsNothing,
      reason: 'the raw RequestOptions debug string must not reach the UI',
    );
  });

  testWidgets('FoodNotFoundError → no snackbar; inline empty-state shows '
      '"Food not found"', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          foodDetailProvider('f_missing')
              .overrideWith((_) async => throw FoodNotFoundError('f_missing')),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const FoodDetailScreen(foodId: 'f_missing'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Existing guard: not-found never raises a snackbar.
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: 'FoodNotFoundError must not raise a snackbar (guard preserved)',
    );

    // Inline empty-state copy is unchanged.
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Food not found'), findsOneWidget);
  });
}
