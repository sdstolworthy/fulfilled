import 'package:flutter/material.dart';

/// Per-screen 3-second cooldown helper for `SnackBar.show` calls.
///
/// Modified Theme E from `pm_ux_pack.md` §3 / `architect_ux_pack.md` §8:
/// the broader global debounced-SnackBar refactor is deferred to v1.1;
/// this pack ships an opt-in helper that swallows stacked
/// same-(context, key) SnackBars within a 3-second window. Used by
/// error paths that could stack on a flaky-network burst (e.g.,
/// `CopyDaySheet._save`'s failure block; `LogWeightSheet`'s save error
/// when it adopts the helper).
///
/// Existing `ScaffoldMessenger.of(context).showSnackBar(...)` call
/// sites are unchanged — opt in by replacing the call with
/// `SnackbarThrottle.show(context, snackBar, key: '<error-code>')`.
///
/// Tenants honored: T-11 (errors inline — the throttle keeps SnackBars
/// from stacking and reads as one transient signal per cooldown
/// window).
class SnackbarThrottle {
  /// Window inside which a same-(context, key) call is swallowed.
  static const Duration cooldown = Duration(seconds: 3);

  /// Last-shown timestamp keyed by (BuildContext, key). The context
  /// part scopes the throttle to a screen so two screens firing the
  /// same key don't cross-throttle each other; the key part is the
  /// error code (e.g., `'log-create-failure'`).
  static final Map<_ThrottleKey, DateTime> _lastShown =
      <_ThrottleKey, DateTime>{};

  /// Show a SnackBar, throttling same-(context, key) calls within
  /// [cooldown]. Returns `true` when the SnackBar was shown; `false`
  /// when it was swallowed by the cooldown. The boolean return is
  /// primarily useful for tests; production callers can ignore it.
  ///
  /// `now` is injectable for tests to advance time without spinning
  /// the real clock — see `test/widgets/snackbar_throttle_test.dart`.
  static bool show(
    BuildContext context,
    SnackBar snackBar, {
    required String key,
    DateTime? now,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return false;
    final at = now ?? DateTime.now();
    final pair = _ThrottleKey(context, key);
    final last = _lastShown[pair];
    if (last != null && at.difference(last) < cooldown) {
      return false;
    }
    _lastShown[pair] = at;
    messenger.showSnackBar(snackBar);
    return true;
  }

  /// Reset the throttle state — testing affordance. The static map
  /// would otherwise carry entries across tests in the same process.
  @visibleForTesting
  static void resetForTest() => _lastShown.clear();
}

/// Compound throttle key. `BuildContext` is intentionally compared by
/// identity — two screens get independent cooldowns; tests pump a
/// fresh `BuildContext` per case.
class _ThrottleKey {
  _ThrottleKey(this.context, this.key);
  final BuildContext context;
  final String key;

  @override
  bool operator ==(Object other) =>
      other is _ThrottleKey &&
      identical(other.context, context) &&
      other.key == key;

  @override
  int get hashCode => Object.hash(identityHashCode(context), key);
}
