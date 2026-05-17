import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'oidc_navigator.dart';

/// Custom URL scheme the backend redirects to when finishing a
/// mobile OIDC flow. Declared on both ends:
///   - **Backend** allowlist: `routes/auth.rs::ALLOWED_MOBILE_SCHEMES`.
///   - **iOS**: `client/ios/Runner/Info.plist` `CFBundleURLSchemes`.
///   - **Android**: `client/android/app/src/main/AndroidManifest.xml`
///     `intent-filter` on `com.linusu.flutter_web_auth_2.CallbackActivity`.
///
/// Changing this value requires updating all four places. The const
/// here is the single FE source of truth — propagated into the
/// backend's `mobile_callback` query param and matched against the
/// `callbackUrlScheme` arg on [FlutterWebAuth2.authenticate].
const String _kCallbackScheme = 'fulfilled';

/// Full `mobile_callback` URL passed to the backend's
/// `/api/v1/auth/oidc/{provider}/start` endpoint. The host segment
/// (`oidc-callback`) is informational — the OS routes any URL with
/// the registered scheme back to the app, and we read query params
/// off the returned URL regardless of the host.
const String _kCallbackUrl = '$_kCallbackScheme://oidc-callback';

/// Mobile / desktop OIDC navigator — system-browser session that
/// bounces the handoff code back through a registered URL scheme.
///
/// The flow:
///   1. [startFlow] composes `<startUrl>&mobile_callback=fulfilled://oidc-callback`
///      and hands it to [FlutterWebAuth2.authenticate].
///   2. The system browser (`ASWebAuthenticationSession` on iOS,
///      Chrome Custom Tab on Android) opens the URL. The user signs
///      in with the IdP there.
///   3. The IdP redirects to the backend's `/callback`; the backend
///      verifies state + mints a handoff code and 302s the browser
///      to `fulfilled://oidc-callback?oidc_code=<handoff>` (or
///      `?oidc_error=<code>` on failure).
///   4. The OS recognizes the registered scheme and dismisses the
///      browser session; `FlutterWebAuth2.authenticate` returns the
///      callback URL.
///   5. We parse `oidc_code` / `oidc_error` off the URL and surface
///      the [OidcFlowResult] to [OidcButton], which runs the
///      exchange.
class _MobileNavigator implements OidcNavigator {
  const _MobileNavigator();

  @override
  Future<OidcFlowResult> startFlow(
    String startUrl, {
    required BuildContext context,
  }) async {
    final urlWithCallback = _appendMobileCallback(startUrl);
    try {
      final returned = await FlutterWebAuth2.authenticate(
        url: urlWithCallback,
        callbackUrlScheme: _kCallbackScheme,
      );
      final uri = Uri.tryParse(returned);
      if (uri == null) {
        return const OidcFlowError('invalid_callback_url');
      }
      final code = uri.queryParameters['oidc_code'];
      if (code != null && code.isNotEmpty) {
        return OidcFlowHandoff(code);
      }
      final err = uri.queryParameters['oidc_error'];
      if (err != null && err.isNotEmpty) {
        return OidcFlowError(err);
      }
      return const OidcFlowError('missing_oidc_code');
    } on PlatformException catch (e) {
      // `FlutterWebAuth2` raises a PlatformException with code
      // `CANCELED` when the user dismisses the system browser. Any
      // other PlatformException is a real error (no scheme handler
      // installed, no network, etc).
      if (e.code == 'CANCELED') {
        return const OidcFlowCancelled();
      }
      return OidcFlowError(e.code);
    }
  }

  @override
  void stripQueryParam(String name) {
    // No-op on mobile — there's no document URL to clean.
  }

  /// Append `mobile_callback=<scheme>://oidc-callback` to the
  /// backend's start URL. Preserves any existing query params (the
  /// caller may have already added `next=` or similar).
  String _appendMobileCallback(String startUrl) {
    final separator = startUrl.contains('?') ? '&' : '?';
    return '$startUrl${separator}mobile_callback='
        '${Uri.encodeQueryComponent(_kCallbackUrl)}';
  }
}

const OidcNavigator navigatorImpl = _MobileNavigator();
