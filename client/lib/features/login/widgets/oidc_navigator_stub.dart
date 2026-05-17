import 'oidc_navigator.dart';

/// Non-web fallback. Mobile OIDC sign-in is v1.1 work — the
/// architect's review intentionally deferred it. Calling [redirect]
/// on mobile today throws so the FE surfaces "this isn't ready yet"
/// during dev rather than silently failing.
class _StubNavigator implements OidcNavigator {
  const _StubNavigator();

  @override
  void redirect(String url) {
    throw UnsupportedError(
      'OIDC redirect is web-only in v1. Mobile sign-in via OIDC is '
      'tracked for v1.1. Tried to navigate to: $url',
    );
  }
}

const OidcNavigator navigatorImpl = _StubNavigator();
