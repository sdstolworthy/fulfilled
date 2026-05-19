import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/auth_token.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';

/// `/login/callback` — the FE landing page after the backend completes
/// the OIDC code exchange against the IdP.
///
/// The flow:
///   1. User taps "Sign in with Authentik" on `LoginScreen`.
///   2. FE redirects browser to `<api>/auth/oidc/authentik/start`.
///   3. Backend redirects to Authentik's authorize URL with PKCE.
///   4. User authenticates at Authentik.
///   5. Authentik redirects back to `<api>/auth/oidc/authentik/callback`.
///   6. Backend exchanges the code with Authentik for an ID token,
///      verifies via JWKS, ensures a local `users` row exists, mints a
///      single-use **handoff code** (60s TTL), and 302s the browser
///      to `<LOSEIT_FE_ORIGIN>/login/callback?code=<handoff>`.
///   7. This screen reads the `code` query param, calls
///      `POST /auth/oidc/exchange` to swap the handoff for an opaque
///      bearer token, stores it via `AuthTokenNotifier.signIn`, then
///      navigates to `/today`.
///
/// **Error states** (T-11):
///   - Missing `code` query param → "Sign-in didn't complete. Please
///     try again." inline; "Back to sign in" CTA returns to `/login`.
///   - `POST /auth/oidc/exchange` returns 4xx/5xx → same shape, with
///     the server's `Error.message` (if present) surfaced verbatim.
///   - Network error → "Couldn't reach the server. Check your
///     connection and try again." with a Retry CTA.
class OidcCallbackScreen extends ConsumerStatefulWidget {
  const OidcCallbackScreen({super.key, required this.code});

  /// The one-time handoff code the backend handed off in the redirect.
  /// Empty when the URL didn't carry `?code=` — the screen renders the
  /// "didn't complete" error in that case.
  final String code;

  @override
  ConsumerState<OidcCallbackScreen> createState() =>
      _OidcCallbackScreenState();
}

class _OidcCallbackScreenState extends ConsumerState<OidcCallbackScreen> {
  String? _error;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    // Kick the exchange off after the first frame so `context` is
    // mounted for the post-success `context.go`.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runExchange());
  }

  Future<void> _runExchange() async {
    if (_running) return;
    if (widget.code.isEmpty) {
      setState(() => _error =
          "Sign-in didn't complete (no handoff code in the URL). "
          'Please try again.',);
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final dio = ref.read(apiClientProvider).dio;
      final res = await dio.post<dynamic>(
        '/auth/oidc/exchange',
        data: <String, String>{'code': widget.code},
      );
      final body = res.data;
      if (body is! Map ||
          body['token'] is! String ||
          (body['token'] as String).isEmpty) {
        setState(() {
          _running = false;
          _error = 'Sign-in completed but the server returned no token. '
              'Please try again.';
        });
        return;
      }
      final token = body['token'] as String;
      await ref.read(authTokenProvider.notifier).signIn(token);
      if (!mounted) return;
      context.go(Routes.todayPath);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = _extractServerMessage(e.response?.data) ??
          (status == null
              ? "Couldn't reach the server. Check your connection and "
                  'try again.'
              : 'Sign-in failed (server returned $status).');
      setState(() {
        _running = false;
        _error = message;
      });
    } catch (_) {
      setState(() {
        _running = false;
        _error = 'An unexpected error occurred. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Scaffold(
      backgroundColor: colors.surface,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: EdgeInsets.all(space.x4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_error == null) ...<Widget>[
                    Text(
                      'Completing sign-in…',
                      style: context.text.hero,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: space.x4),
                    Text(
                      'Exchanging the handoff code for your session token.',
                      style: context.text.meta,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...<Widget>[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 40,
                      color: colors.danger,
                    ),
                    SizedBox(height: space.x3),
                    Text(
                      "Sign-in didn't complete",
                      style: context.text.hero,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: space.x3),
                    Text(
                      _error!,
                      style: context.text.body,
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: space.x5),
                    SizedBox(
                      height: 54,
                      child: FilledButton(
                        onPressed: () => context.go(Routes.loginPath),
                        child: const Text('Back to sign in'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pull a human-readable error message off a typical `Error` response
/// body. The server emits `{code, message?}` on errors; we surface
/// `message` verbatim when present.
String? _extractServerMessage(Object? data) {
  if (data is Map && data['message'] is String) {
    return data['message'] as String;
  }
  return null;
}
