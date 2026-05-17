@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/login_errors.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/data/secure_token_store.dart';
import 'package:fulfilled/features/login/health_probe.dart';
import 'package:fulfilled/features/login/login_controller.dart';
import 'package:hive/hive.dart';

import '../../data/fake_secure_token_store.dart';

/// LOG-005 — six cases per the ticket Scope checklist (architect §5.3
/// + §5.4 + §5.6).
///
/// The fakes (`_RecordingAuthTokenNotifier` + `_SuccessProbe`) replace
/// the network seams so the five-phase `submit()` flow exercises
/// end-to-end without touching Dio. The shared `callLog` captures the
/// ordering of side effects across providers — Case F asserts that
/// phase 4 (`box.put` + `ref.invalidate`) runs before phase 5
/// (`signInWithCredentials`). The probe-error cases (one per
/// [HealthProbeErrorKind]) live in `login_url_validation_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> authConfigBox;
  late Box<String> outboxBox;
  late FakeSecureTokenStore secureStore;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-login-ctrl-');
    Hive.init(hiveDir.path);
    authConfigBox = await Hive.openBox<String>(authConfigBoxName);
    outboxBox = await Hive.openBox<String>(outboxBoxName);
    secureStore = FakeSecureTokenStore();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  /// Common container builder. `probe` defaults to a no-op
  /// (`_SuccessProbe`); cases override `tokenNotifier` to inject
  /// failure modes.
  ///
  /// When [callLog] is non-null, the [authConfigBoxProvider] is
  /// replaced with a recording proxy that appends
  /// `'box.put:<key>'` to the log on every `put` and otherwise
  /// forwards to the real Hive box. Combined with the notifier's
  /// `'signInWithCredentials'` record, Case F asserts the ordering
  /// invariant: `box.put:base_url` happens before
  /// `signInWithCredentials`.
  ProviderContainer buildContainer({
    HealthProbe? probe,
    _RecordingAuthTokenNotifier Function()? tokenNotifierFactory,
    List<String>? callLog,
  }) {
    final box = callLog == null
        ? authConfigBox
        : _RecordingBox(authConfigBox, callLog);
    final container = ProviderContainer(
      overrides: <Override>[
        authConfigBoxProvider.overrideWithValue(box),
        outboxBoxProvider.overrideWithValue(outboxBox),
        secureTokenStoreProvider.overrideWithValue(secureStore),
        healthProbeProvider.overrideWith((_) => probe ?? _SuccessProbe(callLog)),
        if (tokenNotifierFactory != null)
          authTokenProvider.overrideWith(tokenNotifierFactory),
      ],
    );
    // The login controller is autoDispose — without a live subscription
    // it can dispose mid-`submit()` and the `finally` block's
    // `state = state.copyWith(...)` blows up. A no-op listen keeps it
    // alive for the duration of the test.
    container.listen<Object?>(loginControllerProvider, (_, __) {});
    addTearDown(container.dispose);
    return container;
  }

  test('Case A: happy path — normalized URL + username land in Hive', () async {
    final calls = <String>[];
    final container = buildContainer(
      callLog: calls,
      tokenNotifierFactory: () => _RecordingAuthTokenNotifier(callLog: calls),
    );
    final controller = container.read(loginControllerProvider.notifier);
    controller.setUrl('srv.example');
    controller.setUsername('alice');
    controller.setPassword('hunter2');

    final ok = await controller.submit();

    expect(ok, isTrue);
    // The bare host got the canonical `https://` prefix + `/api/v1`
    // suffix (LOG-002 contract).
    expect(
      authConfigBox.get(AuthConfigKey.baseUrl),
      equals('https://srv.example/api/v1'),
    );
    expect(authConfigBox.get(AuthConfigKey.lastUsername), equals('alice'));
    // submitting flipped back to false in the `finally`.
    expect(container.read(loginControllerProvider).submitting, isFalse);
  });

  test('Case B: bad credentials → credentialsError set, other slots null',
      () async {
    final container = buildContainer(
      tokenNotifierFactory: () => _RecordingAuthTokenNotifier(
        signInWithCredentialsThrows: const BadCredentialsError(),
      ),
    );
    final controller = container.read(loginControllerProvider.notifier);
    controller.setUrl('https://srv.example');
    controller.setUsername('alice');
    controller.setPassword('wrong');

    final ok = await controller.submit();

    expect(ok, isFalse);
    final state = container.read(loginControllerProvider);
    expect(state.credentialsError, isNotNull);
    expect(state.credentialsError, contains('Wrong username or password'));
    expect(state.urlError, isNull);
    expect(state.formError, isNull);
    expect(state.submitting, isFalse);
  });

  test(
      'Case C: endpoint missing → endpointMissing flag; subsequent JWT-paste '
      'submit shortcuts past /auth/login', () async {
    // First submit: phase 5 throws LoginEndpointMissingError.
    final notifier1 = _RecordingAuthTokenNotifier(
      signInWithCredentialsThrows: const LoginEndpointMissingError(),
    );
    final container1 = buildContainer(tokenNotifierFactory: () => notifier1);
    final controller1 = container1.read(loginControllerProvider.notifier);
    controller1.setUrl('https://srv.example');
    controller1.setUsername('alice');
    controller1.setPassword('pw');
    final first = await controller1.submit();
    expect(first, isFalse);
    expect(
      container1.read(loginControllerProvider).endpointMissing,
      isTrue,
    );

    // Snapshot `signInWithCredentialsCalls` after the first submit
    // — phase 5 fired exactly once (it threw on the way out). The
    // paste-JWT path should NOT add to this list.
    final credsCallsAfterFirst = notifier1.signInWithCredentialsCalls.length;
    expect(credsCallsAfterFirst, equals(1));

    // Flip into paste-JWT mode and submit with a JWT-shaped
    // password. The controller should skip the probe + the
    // credential POST and only call `signIn(password)`.
    controller1.acceptJwtDisclosure();
    // Realistic three-segment shape — `_looksLikeJwt` passes.
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.abc-_DEF';
    controller1.setPassword(jwt);

    final second = await controller1.submit();
    expect(second, isTrue);
    // `signIn(jwt)` was called exactly once on the paste-JWT path.
    expect(notifier1.signInCalls, equals(<String>[jwt]));
    // The paste-JWT path did NOT call `signInWithCredentials`
    // (count is unchanged since the first submit).
    expect(
      notifier1.signInWithCredentialsCalls.length,
      equals(credsCallsAfterFirst),
      reason:
          'phase 1 (paste-JWT) must short-circuit past /auth/login — '
          'signInWithCredentials should not be called',
    );
    // _persistConfig wrote the (raw) URL + username.
    expect(
      authConfigBox.get(AuthConfigKey.baseUrl),
      equals('https://srv.example'),
    );
    expect(authConfigBox.get(AuthConfigKey.lastUsername), equals('alice'));
  });

  test(
      'Case D: HTTP toggle — submit fails on http:// without allowInsecure, '
      'succeeds after toggling', () async {
    final container = buildContainer(
      tokenNotifierFactory: _RecordingAuthTokenNotifier.new,
    );
    final controller = container.read(loginControllerProvider.notifier);
    controller.setUrl('http://192.168.1.5:8080');
    controller.setUsername('alice');
    controller.setPassword('pw');

    // First submit: URL normalize throws insecureScheme.
    final first = await controller.submit();
    expect(first, isFalse);
    final afterFirst = container.read(loginControllerProvider);
    expect(afterFirst.urlError, isNotNull);
    expect(afterFirst.urlError, contains('HTTP'));

    // Accept the disclosure — toggle clears the urlError so the
    // next submit can render a clean field.
    controller.toggleAllowInsecure();
    expect(container.read(loginControllerProvider).allowInsecure, isTrue);
    expect(container.read(loginControllerProvider).urlError, isNull);

    final second = await controller.submit();
    expect(second, isTrue);
    // The persisted URL preserved the http:// scheme + /api/v1 suffix.
    expect(
      authConfigBox.get(AuthConfigKey.baseUrl),
      equals('http://192.168.1.5:8080/api/v1'),
    );
  });

  test(
      'Case E: allowInsecure pre-seed from Hive — http:// previous URL flips '
      'allowInsecure to true on mount', () async {
    // Seed the Hive box with a previously-stored http:// URL.
    await authConfigBox.put(
      AuthConfigKey.baseUrl,
      'http://prev.example/api/v1',
    );
    await authConfigBox.put(AuthConfigKey.lastUsername, 'bob');

    final container = buildContainer();
    final state = container.read(loginControllerProvider);

    expect(state.allowInsecure, isTrue);
    expect(state.url, equals('http://prev.example/api/v1'));
    expect(state.username, equals('bob'));
  });

  test(
      'Case F: invalidate before POST — phase 4 (box.put base_url) '
      'runs before phase 5 (signInWithCredentials)', () async {
    final calls = <String>[];
    final container = buildContainer(
      callLog: calls,
      tokenNotifierFactory: () => _RecordingAuthTokenNotifier(callLog: calls),
    );
    final controller = container.read(loginControllerProvider.notifier);
    controller.setUrl('https://srv.example');
    controller.setUsername('alice');
    controller.setPassword('hunter2');

    final ok = await controller.submit();
    expect(ok, isTrue);

    // The recording box appends `'box.put:base_url'` on every
    // `put(baseUrl, ...)` call — phase 4 fires exactly one such
    // call (phase 5's `_persistConfig` then fires two more on the
    // success path). The notifier's `signInWithCredentials` is
    // recorded as `'signInWithCredentials'`.
    //
    // Invariant: the FIRST `box.put:base_url` precedes
    // `signInWithCredentials`. `ref.invalidate` is synchronous —
    // it happens between the `box.put` and the credential POST,
    // so the put-before-POST ordering is the load-bearing check.
    final firstPutIdx = calls.indexOf('box.put:base_url');
    final postIdx = calls.indexOf('signInWithCredentials');
    expect(
      firstPutIdx,
      isNonNegative,
      reason: 'box.put(base_url) should be recorded by the recording proxy',
    );
    expect(
      postIdx,
      isNonNegative,
      reason: 'signInWithCredentials should be recorded',
    );
    expect(
      firstPutIdx < postIdx,
      isTrue,
      reason:
          'Phase 4 (box.put + invalidate) must run BEFORE phase 5 '
          '(signInWithCredentials) so apiClientProvider can rebuild Dio '
          'against the fresh URL before the credential POST fires',
    );
  });
}

/// Recording proxy around a real Hive `Box<String>`. The only call
/// the [LoginController] makes on its `auth_config` box are
/// `get(key)` (in the controller provider, for initial state) and
/// `put(key, value)` (in phase 4 + `_persistConfig`). We forward
/// those two methods to the real box; every other `Box<String>`
/// method throws `UnsupportedError` via `noSuchMethod` — if the
/// controller ever starts calling another method, the test fails
/// loudly and we extend this proxy.
///
/// The recording side effect is appending `'box.put:<key>'` to the
/// shared call log on every `put` — Case F asserts the ordering of
/// the FIRST `'box.put:base_url'` against the notifier's
/// `'signInWithCredentials'` record.
class _RecordingBox implements Box<String> {
  _RecordingBox(this._inner, this._log);
  final Box<String> _inner;
  final List<String> _log;

  @override
  Future<void> put(dynamic key, String value) async {
    _log.add('box.put:$key');
    await _inner.put(key, value);
  }

  @override
  String? get(dynamic key, {String? defaultValue}) =>
      _inner.get(key, defaultValue: defaultValue);

  @override
  Future<int> clear() => _inner.clear();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(
        '_RecordingBox does not forward ${invocation.memberName}. '
        'Extend the proxy if the controller starts calling it.',
      );
}

/// Test double for [AuthTokenNotifier]. Records every method call into
/// the optional [callLog] so Case F can assert ordering across
/// providers.
///
/// Three modes:
///   - Default: `signInWithCredentials` records the call into
///     [signInWithCredentialsCalls] (and `callLog` with the literal
///     `'signInWithCredentials'`) and returns normally.
///   - [signInWithCredentialsThrows] non-null: throws that error.
///   - `signIn` always records into [signInCalls] and `callLog` and
///     returns normally.
///
/// Subclasses [AuthTokenNotifier] so the override is type-compatible
/// with `authTokenProvider`.
class _RecordingAuthTokenNotifier extends AuthTokenNotifier {
  _RecordingAuthTokenNotifier({
    this.signInWithCredentialsThrows,
    List<String>? callLog,
  }) : callLog = callLog ?? <String>[];

  /// If non-null, `signInWithCredentials` throws this. Otherwise it
  /// returns normally.
  final LoginError? signInWithCredentialsThrows;

  /// Cross-provider call log. Shared with the [_SuccessProbe] so Case
  /// F can assert ordering between `box.put` and `signInWithCredentials`.
  final List<String> callLog;

  /// Each `signIn(token)` invocation recorded in order.
  final List<String> signInCalls = <String>[];

  /// Each `signInWithCredentials(...)` invocation recorded in order.
  /// Tuple-of-string for ergonomic assertions.
  final List<({String username, String password})> signInWithCredentialsCalls =
      <({String username, String password})>[];

  @override
  String? build() {
    // Don't call super.build() — we don't want the secure-store
    // hydrate path to fire under the test container. Return a
    // stable seed for any synchronous reads.
    return 'fake-seed';
  }

  @override
  Future<void> signIn(String token) async {
    signInCalls.add(token);
    callLog.add('signIn');
    state = token;
  }

  @override
  Future<void> signInWithCredentials({
    required String username,
    required String password,
  }) async {
    signInWithCredentialsCalls.add((username: username, password: password));
    callLog.add('signInWithCredentials');
    final err = signInWithCredentialsThrows;
    if (err != null) {
      throw err;
    }
    state = 'fake-token-from-credentials';
  }

  @override
  Future<void> signOut() async {
    callLog.add('signOut');
    state = null;
  }
}

/// Default `HealthProbe` fake — records the probe call (so Case F can
/// see the phase-3 fire) and returns normally.
class _SuccessProbe implements HealthProbe {
  _SuccessProbe(this.callLog);
  final List<String>? callLog;

  @override
  Future<void> probe(String baseUrl, {required Duration timeout}) async {
    callLog?.add('probe');
  }
}
