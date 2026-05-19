import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import 'oidc_exchange.dart';

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
///      [runOidcExchange] to swap the handoff for an opaque bearer
///      token (the shared seam in `oidc_exchange.dart` — same code
///      path the inline `LoginScreen.initState` and the mobile
///      `OidcButton` both consume) and navigates to `/today`.
///
/// **Error states** (T-11):
///   - Missing `code` query param → "Sign-in didn't complete. Please
///     try again." inline; "Back to sign in" CTA returns to `/login`.
///   - Exchange failure → render `OidcExchangeError.message` verbatim
///     (the helper already classifies status, network, and timeout
///     branches into render-ready strings).
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
    // Audit-fix from `specs/io_deps_audit.md` §2.1: route through the
    // shared `runOidcExchange` seam rather than poking the Dio client
    // directly. That helper owns the `POST /auth/oidc/exchange` wire,
    // the token persist via `authTokenProvider.signIn`, the
    // `meProvider` invalidate, and the 20s outer-timeout — same code
    // path `LoginScreen._runExchange` and the OIDC-button orchestration
    // in `login_screen.dart`'s `_OidcButtonListState._onTap` both
    // consume.
    final result = await runOidcExchange(ref: ref, handoff: widget.code);
    if (!mounted) return;
    switch (result) {
      case OidcExchangeSuccess():
        context.go(Routes.todayPath);
      case OidcExchangeError(:final message):
        setState(() {
          _running = false;
          _error = message;
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
