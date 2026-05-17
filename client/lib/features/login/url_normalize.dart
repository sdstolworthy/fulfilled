/// LOG-002 — Pure URL normalization for the login server URL field.
///
/// `normalizeServerUrl` takes a raw user-typed URL and an `allowInsecure`
/// flag and returns a canonical API base URL ending in `/api/v1` (unless
/// the user already supplied a path containing `/api/v1`, which is
/// preserved verbatim).
///
/// The function is pure: no I/O, no async, no Riverpod reads, no Dio.
/// Just string manipulation + `Uri.tryParse`. The architect plan (§2.4)
/// keeps this seam pure so a future "switch server" affordance can reuse
/// it without dragging in controller state.
///
/// On any failure the function throws a typed [UrlNormalizeError]; the
/// `kind` field is the discriminant the login controller (LOG-005) uses
/// to decide whether to surface the HTTP-allow disclosure or a generic
/// "malformed" error.
library;

/// The kind of normalization failure. The login controller switches on
/// this enum to decide which UI affordance to render (e.g. the
/// "Allow HTTP for this session" disclosure is gated on
/// [UrlNormalizeErrorKind.insecureScheme]).
enum UrlNormalizeErrorKind {
  /// The trimmed input was empty.
  empty,

  /// The input could not be parsed as an absolute URL with a host, or
  /// contained characters that broke [Uri.tryParse].
  malformed,

  /// The user supplied an `http://` URL but `allowInsecure` is `false`.
  insecureScheme,
}

/// Thrown by [normalizeServerUrl] on any failure. The [message] field is
/// the canonical PM-facing error string (PM §5.5 + LOG-S5 + LOG-S6) and
/// is rendered as-is under the URL field by the login controller.
class UrlNormalizeError implements Exception {
  const UrlNormalizeError(this.kind, this.message);

  /// The discriminant the login controller switches on.
  final UrlNormalizeErrorKind kind;

  /// The canonical PM-facing error string.
  final String message;

  @override
  String toString() => message;
}

/// Normalize a raw user-typed server URL into a canonical API base URL.
///
/// Rules (applied in this exact order per architect §2.4):
///
/// 1. Trim whitespace.
/// 2. Empty → throw [UrlNormalizeError] with [UrlNormalizeErrorKind.empty].
/// 3. Strip *all* trailing slashes.
/// 4. If no scheme (`http://` / `https://`), prepend `https://`.
/// 5. If `http://` and `!allowInsecure` → throw
///    [UrlNormalizeError] with [UrlNormalizeErrorKind.insecureScheme].
/// 6. Parse via [Uri.tryParse]. If null, not absolute, or host is empty
///    → throw [UrlNormalizeError] with [UrlNormalizeErrorKind.malformed].
/// 7. If the URL's path does not contain `/api/v1`, append it.
/// 8. Return the normalized string.
///
/// Dot-less hosts with ports (`localhost:8080`, `192.168.1.5:8080`,
/// `myserver:9000`) are explicitly supported — they're valid LAN URLs
/// (architect §10.4). Path-prefixed inputs like
/// `a.com/fulfilled/api/v1` are preserved verbatim (architect §10.2).
String normalizeServerUrl(String raw, {bool allowInsecure = false}) {
  // 1. Trim.
  var trimmed = raw.trim();

  // 2. Empty guard.
  if (trimmed.isEmpty) {
    throw const UrlNormalizeError(
      UrlNormalizeErrorKind.empty,
      'Server URL is required.',
    );
  }

  // 3. Strip *all* trailing slashes.
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }

  // After stripping trailing slashes, the input could be empty again
  // (e.g. the user typed just `/` or `///`). Treat that as malformed —
  // not "empty" — because the user did type something.
  if (trimmed.isEmpty) {
    throw const UrlNormalizeError(
      UrlNormalizeErrorKind.malformed,
      'Server URL is malformed.',
    );
  }

  // 4. Prepend `https://` if no scheme.
  if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
    trimmed = 'https://$trimmed';
  }

  // 5. Reject `http://` unless explicitly allowed.
  if (trimmed.startsWith('http://') && !allowInsecure) {
    throw const UrlNormalizeError(
      UrlNormalizeErrorKind.insecureScheme,
      'HTTPS required. Tap Allow HTTP for this session to use plain HTTP.',
    );
  }

  // 6. Parse + validate.
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || !parsed.isAbsolute || parsed.host.isEmpty) {
    throw const UrlNormalizeError(
      UrlNormalizeErrorKind.malformed,
      'Server URL is malformed.',
    );
  }

  // 7. Append `/api/v1` if the path doesn't already contain it.
  //
  // `contains('/api/v1')` rather than `endsWith` so a path like
  // `/api/v1/extra` (rare but possible if an operator reverse-proxies
  // deeper) is also treated as already-suffixed.
  if (parsed.path.contains('/api/v1')) {
    // Preserve the path verbatim, but strip any trailing slash on the
    // path itself (we already stripped them off `trimmed`, but the
    // parser could have re-emitted one for a path-only `/`).
    return trimmed;
  }

  return '$trimmed/api/v1';
}
