import 'package:dio/dio.dart';

/// User-facing error description. Maps any throwable (Dio, app-domain,
/// generic) into a (title, body, kind) triple. **Never** interpolates
/// raw DioException strings or HTTP bodies into the message.
///
/// F2 introduced this helper to stop the food-detail snackbar from
/// leaking the raw `DioException` debug string
/// (`DioException [bad response]: ... RequestOptions { ... }`) into
/// the UI. Callers map any non-domain error through `FriendlyError.from`
/// and read `.title` / `.body` for presentation.
///
/// `kind` drives presentation:
///   - `notFound`  → screen-specific empty state ("No food", "No goal")
///   - `auth`      → "Session expired, sign in again" (the 401-sweep in
///                   `api_client.dart` already redirects to `/login`;
///                   this is the read-side label that runs in the same
///                   frame)
///   - `server`    → "Something went wrong, retry"
///   - `network`   → "Check your connection"
///   - `other`     → "Couldn't complete that"
///
/// **Domain errors should be mapped by the caller before reaching this
/// helper.** Pass `FoodNotFoundError` etc. through the screen's own
/// branch (e.g. the existing `if (next.error is FoodNotFoundError) return;`
/// guard in `food_detail_screen.dart`) — this function only knows about
/// Dio + generic Object.
class FriendlyError {
  const FriendlyError({
    required this.title,
    required this.body,
    required this.kind,
  });

  final String title;
  final String body;
  final FriendlyErrorKind kind;

  /// Map any throwable to a `FriendlyError`. Pure logic; no Flutter
  /// dependency beyond the `dio` package's error type.
  factory FriendlyError.from(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401) {
        return const FriendlyError(
          title: 'Session expired',
          body: 'Sign in again to continue.',
          kind: FriendlyErrorKind.auth,
        );
      }
      if (status == 404) {
        return const FriendlyError(
          title: 'Not found',
          body: "We couldn't find that.",
          kind: FriendlyErrorKind.notFound,
        );
      }
      if (status != null && status >= 500) {
        return const FriendlyError(
          title: 'Something went wrong',
          body: 'Try again in a moment.',
          kind: FriendlyErrorKind.server,
        );
      }
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return const FriendlyError(
            title: "Couldn't reach the server",
            body: 'Check your connection and retry.',
            kind: FriendlyErrorKind.network,
          );
        case DioExceptionType.badCertificate:
        case DioExceptionType.cancel:
        case DioExceptionType.badResponse:
        case DioExceptionType.unknown:
          break;
      }
    }
    return const FriendlyError(
      title: "Couldn't complete that",
      body: 'Try again in a moment.',
      kind: FriendlyErrorKind.other,
    );
  }
}

/// Presentation hint for [FriendlyError]. Screen agents may branch on
/// this to pick an icon or empty-state shape; the default rendering
/// just shows `title` and (optionally) `body`.
enum FriendlyErrorKind { notFound, auth, server, network, other }
