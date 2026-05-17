import 'dart:async';
// ignore: deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/widgets.dart';

import 'oidc_navigator.dart';

/// Web implementation — full-page redirect via `window.location.href`.
/// The browser tears down the Flutter view and loads the IdP's
/// authorize URL; control comes back when the IdP redirects to the
/// backend's callback, which in turn redirects to the FE's origin
/// with `?oidc_code=<handoff>#/login`. `LoginScreen.initState` picks
/// the param off `Uri.base.queryParameters` and runs the exchange.
class _WebNavigator implements OidcNavigator {
  const _WebNavigator();

  @override
  Future<OidcFlowResult> startFlow(
    String startUrl, {
    required BuildContext context,
  }) {
    html.window.location.href = startUrl;
    // The page is about to tear down. Return a future that never
    // completes — any awaiter in this isolate is gone before resume.
    return Completer<OidcFlowResult>().future;
  }

  @override
  void stripQueryParam(String name) {
    final loc = html.window.location;
    final uri = Uri.parse(loc.href);
    if (!uri.queryParameters.containsKey(name)) return;

    final newParams = Map<String, String>.from(uri.queryParameters)
      ..remove(name);

    // Build the URL manually rather than use `Uri.replace`. Dart's
    // `Uri.replace(queryParameters: null)` treats `null` as
    // "keep the current query," not "clear it" — so when the param
    // we're removing was the **only** query param the existing
    // `?oidc_code=…` survives untouched. Constructing the URL by
    // hand avoids the null-vs-empty trap.
    final buf = StringBuffer()
      ..write(uri.scheme)
      ..write('://')
      ..write(uri.authority)
      ..write(uri.path);
    if (newParams.isNotEmpty) {
      buf.write('?');
      buf.write(
        newParams.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}='
                  '${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      );
    }
    if (uri.fragment.isNotEmpty) {
      buf.write('#');
      buf.write(uri.fragment);
    }
    html.window.history.replaceState(null, '', buf.toString());
  }
}

const OidcNavigator navigatorImpl = _WebNavigator();
