import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/auth_providers.dart';
import '../../form_factor/breakpoints.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import 'login_controller.dart';
import 'oidc_exchange.dart';
import 'widgets/credentials_form.dart';
import 'widgets/login_button.dart';
import 'widgets/oidc_button.dart';
import 'widgets/oidc_navigator.dart';
import 'widgets/paste_jwt_disclosure.dart';
import 'widgets/server_url_field.dart';
import 'widgets/sign_up_link.dart';

/// LOG-006 — the self-hosted login screen.
///
/// Form-factor branches at the screen root (T-15): compact widths
/// (< `Breakpoints.mediumMax`) get a single-column, full-width form;
/// medium/expanded widths get a centred `ConstrainedBox(maxWidth: 420)`
/// card. Both wrap a shared `_LoginBody` so the layout column lives in
/// one place.
///
/// The screen is registered at `/login` **outside** the `ShellRoute` so
/// it has no nav chrome (no bottom tabs, no sidebar — architect §1
/// piece (b)). The redirect rule that pins unauthenticated users here
/// is owned by LOG-007.
///
/// `_LoginBody` (top to bottom, per ticket Scope checklist):
///
///   1. `_Logo` — the same accent-on-surface square favourite-heart
///      shape `step_1_welcome.dart` uses. Inline per architect §10.5
///      PMgr-accept (two-logo drift is acceptable for v1; v1.1 hoists
///      to `lib/widgets/app_logo.dart`).
///   2. `SizedBox(height: context.space.x6)`.
///   3. Headline "Sign in to your server" in `context.text.hero`.
///   4. `SizedBox(height: context.space.x6)`.
///   5. `ServerUrlField` (mobile only — `!kIsWeb`; on web omitted from
///      the column entirely, not zero-height-hidden — architect §6).
///   6. `SizedBox(height: context.space.x4)` (mobile only).
///   7. `CredentialsForm` (username + password stacked).
///   8. `SizedBox(height: context.space.x6)`.
///   9. `LoginButton` (full-width "Sign in" primary).
///   10. `PasteJwtDisclosure` (only when `state.endpointMissing`).
///   11. Form-error row (only when `state.formError != null`).
///   12. `SizedBox(height: context.space.x4)`.
///   13. `SignUpLink`.
///
/// Tenants honoured: T-04 (accent on the single primary "Sign in"
/// button), T-08 (skeleton during submit, no spinner), T-11 (inline
/// errors — no SnackBar), T-14 (deep-linkable route), T-15
/// (form-factor at root), T-20 (Semantics on every field), T-24 Case 2
/// (`context.go` on success).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  /// Set when the backend redirected us back from the OIDC callback
  /// with `?oidc_code=<handoff>` on the document URL (Ask 8). When
  /// non-null we render the "Completing sign-in…" body instead of the
  /// credentials form; on success [signIn] flips
  /// `authTokenProvider` and the router redirect rule moves us to
  /// `/today`. On error we render an inline retry CTA and the user
  /// can either retry the IdP click or fall back to local creds.
  String? _exchangeError;
  bool _exchanging = false;

  @override
  void initState() {
    super.initState();
    // `Uri.base` on Flutter web returns the document URL including
    // page-level query params (the part before `#`). The backend's
    // redirect target is
    // `<LOSEIT_FE_ORIGIN>/?oidc_code=<handoff>#/login`, so we read
    // the param off `Uri.base.queryParameters` even though the
    // hash-routed location is `/login`.
    final oidcCode = Uri.base.queryParameters['oidc_code'];
    if (oidcCode != null && oidcCode.isNotEmpty) {
      _exchanging = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runExchange(oidcCode);
      });
    }
  }

  Future<void> _runExchange(String handoff) async {
    // Strip `oidc_code` off the document URL **before** the exchange
    // fires so a browser refresh during the round-trip doesn't double-
    // submit a code the server has already redeemed (single-use, 60s
    // TTL). The fragment route survives the replace.
    OidcNavigator.instance.stripQueryParam('oidc_code');
    final result = await runOidcExchange(ref: ref, handoff: handoff);
    if (!mounted) return;
    switch (result) {
      case OidcExchangeSuccess():
        // Belt-and-suspenders: strip the handoff code again right
        // before navigating. Guarantees the URL is clean before
        // GoRouter writes the `/today` location.
        OidcNavigator.instance.stripQueryParam('oidc_code');
        context.go(Routes.todayPath);
      case OidcExchangeError(:final message):
        setState(() {
          _exchanging = false;
          _exchangeError = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isExpanded = width >= Breakpoints.mediumMax;
    final Widget body;
    if (_exchanging) {
      body = const _OidcExchangingBody();
    } else if (_exchangeError != null) {
      body = _OidcErrorBody(
        message: _exchangeError!,
        onRetry: () => setState(() => _exchangeError = null),
      );
    } else {
      body = const _LoginBody();
    }
    // T-15 — form-factor branch at the screen root. Both arms share
    // the body so the column structure lives in one place.
    if (isExpanded) {
      return _LoginExpanded(child: body);
    }
    return _LoginCompact(child: body);
  }
}

/// Compact (mobile / iPad-portrait) layout: full-width single-column
/// form, vertically centred inside a `SafeArea`. No `AppBar` — the
/// login screen has no nav chrome.
class _LoginCompact extends StatelessWidget {
  const _LoginCompact({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: space.x5,
              vertical: space.x6,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Expanded (desktop web / tablet landscape) layout: a centred
/// `ConstrainedBox(maxWidth: 420)` card. Visually a tighter mobile
/// (architect §6 — "the expanded card-layout is identical in shape to
/// mobile's iPad-class medium breakpoint").
class _LoginExpanded extends StatelessWidget {
  const _LoginExpanded({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(vertical: space.x6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: space.x5),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared form column. Identical on compact and expanded — the
/// only difference between the two layouts is the outer
/// `ConstrainedBox(maxWidth: 420)` that the expanded variant supplies.
///
/// Architect §6 + ticket Scope: the URL field is **omitted entirely**
/// on web, not rendered with zero height. The Column's children list is
/// built conditionally on `kIsWeb` so `find.byType(ServerUrlField)`
/// returns `findsNothing` in the web test.
class _LoginBody extends ConsumerWidget {
  const _LoginBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Perf (Flutter doc — "Control build() cost"): the body re-renders
    // on every keystroke if it watches the full `LoginState`. Each
    // keystroke flips `state.url` / `state.username` / `state.password`,
    // and the body only reads `state.formError`. Narrowing via
    // `.select` keeps the body's `build` keystroke-stable; the
    // individual `TextField`s, the submit button, and the inline
    // disclosure each watch their own slice (see the consumers
    // below).
    final formError = ref.watch(
      loginControllerProvider.select((s) => s.formError),
    );
    final space = context.space;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 1. Logo. Inline shape — do NOT hoist (architect §10.5).
        const Center(child: _Logo()),
        // 2. Spacer above headline.
        SizedBox(height: space.x6),
        // 3. Headline.
        Text(
          'Sign in to your server',
          style: context.text.hero,
          textAlign: TextAlign.center,
        ),
        // 4. Spacer above first field.
        SizedBox(height: space.x6),
        // 4.5. OIDC provider buttons (Ask 8). Rendered above the
        // credentials form when the discovery endpoint advertises any
        // OIDC providers. The list is fetched once on mount via
        // `authProvidersProvider` (autoDispose); on network failure
        // or older-server-without-the-endpoint the provider returns
        // `AuthProviders.empty` so the column collapses to the
        // credentials-only form.
        const _OidcButtonList(),
        // 5 + 6. URL field (mobile only — architect §6: omitted on web,
        // not zero-height-hidden). The `!kIsWeb` gate compiles to a
        // constant at build time; the web bundle never includes the
        // ServerUrlField subtree.
        if (!kIsWeb) ...<Widget>[
          const ServerUrlField(),
          SizedBox(height: space.x4),
        ],
        // 7. Credentials.
        const CredentialsForm(),
        // 8. Spacer above submit.
        SizedBox(height: space.x6),
        // 9. Submit button.
        const LoginButton(),
        // 10. JWT-paste disclosure — visible only when
        // `state.endpointMissing` (the widget guards itself).
        const PasteJwtDisclosure(),
        // 11. Form-level error row (T-11 — inline, no SnackBar).
        if (formError != null) ...<Widget>[
          SizedBox(height: space.x3),
          _FormErrorRow(message: formError),
        ],
        // 12. Spacer above sign-up link.
        SizedBox(height: space.x4),
        // 13. Sign-up link.
        const Center(child: SignUpLink()),
      ],
    );
  }
}

/// T-11 inline form-error row — non-modal warning below the submit
/// button. Architect §5.5: the login screen has inline space for this,
/// so we don't fall back to a SnackBar.
class _FormErrorRow extends StatelessWidget {
  const _FormErrorRow({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.warning_amber_rounded,
          color: colors.danger,
          size: 20,
        ),
        SizedBox(width: space.x2),
        Expanded(
          child: Text(
            message,
            style: context.text.meta.copyWith(color: colors.danger),
          ),
        ),
      ],
    );
  }
}

// TODO v1.1: hoist _Logo to lib/widgets/app_logo.dart per architect
// §10.5. Two-logo drift (this widget + the identical shape in
// `step_1_welcome.dart`) is acceptable for v1 — PMgr accept-with-defer
// from the architect plan. v1.1 lifts both call sites to a shared
// `AppLogo` widget. Until then this marker is the receipt.
/// The accent-on-surface 84-px square favourite-heart logo. Inline
/// Renders one [OidcButton] per provider returned by the discovery
/// endpoint, with a "or" divider tying the OIDC stack to the
/// credentials form below. Empty + invisible when no OIDC providers
/// are configured on the server (the architect-approved degraded
/// state — login still works via local creds).
class _OidcButtonList extends ConsumerWidget {
  const _OidcButtonList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(authProvidersProvider);
    return async.when(
      // While loading we render nothing — the layout reflows the
      // moment providers resolve, which is cheaper than reserving
      // skeleton space for a list that's often empty.
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (providers) {
        if (providers.oidc.isEmpty) {
          return const SizedBox.shrink();
        }
        final space = context.space;
        final colors = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final p in providers.oidc) ...<Widget>[
              OidcButton(provider: p),
              SizedBox(height: space.x3),
            ],
            // "or" divider between the OIDC stack and the local form.
            // Only renders when local auth is also enabled — if local
            // is off and OIDC is the only option, no divider needed.
            if (providers.local)
              Padding(
                padding: EdgeInsets.symmetric(vertical: space.x2),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Divider(color: colors.line2, height: 1)),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: space.x3),
                      child: Text(
                        'or',
                        style: context.text.meta.copyWith(color: colors.ink3),
                      ),
                    ),
                    Expanded(child: Divider(color: colors.line2, height: 1)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// shape duplicated from `step_1_welcome.dart`. See the `// TODO v1.1`
/// marker above for the hoist plan.
class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(
        Icons.favorite_border_rounded,
        size: 40,
        // FX-006 / T-01 — glyph on the accent logo routes through the
        // `surface` token, not `Colors.white`.
        color: colors.surface,
      ),
    );
  }
}

/// "Completing sign-in…" body rendered while the OIDC handoff code is
/// being exchanged for an opaque bearer token. T-08 — no spinner; a
/// static skeleton + text. The exchange settles in <1s in practice
/// (single round-trip to the api).
class _OidcExchangingBody extends StatelessWidget {
  const _OidcExchangingBody();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Center(child: _Logo()),
        SizedBox(height: space.x6),
        Text(
          'Completing sign-in…',
          style: context.text.hero,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: space.x3),
        Text(
          'Exchanging your handoff code for a session token.',
          style: context.text.meta,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// Inline error body for an OIDC exchange that failed (bad handoff,
/// server 5xx, network blip). T-11 — non-modal warning + "Try again"
/// CTA that re-enters the credentials form so the user can either
/// retry the IdP click or fall back to local creds.
class _OidcErrorBody extends StatelessWidget {
  const _OidcErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Center(
          child: Icon(
            Icons.warning_amber_rounded,
            size: 40,
            color: colors.danger,
          ),
        ),
        SizedBox(height: space.x3),
        Text(
          "Sign-in didn't complete",
          style: context.text.hero,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: space.x3),
        Text(
          message,
          style: context.text.body,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: space.x5),
        SizedBox(
          height: 54,
          child: FilledButton(
            onPressed: onRetry,
            child: const Text('Back to sign in'),
          ),
        ),
      ],
    );
  }
}

/// Pull a human-readable error message off a typical `Error` response
/// body. The server emits `{code, message?}` on errors; we surface
/// `message` verbatim when present.
