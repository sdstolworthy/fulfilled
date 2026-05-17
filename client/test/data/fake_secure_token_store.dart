import 'package:fulfilled/data/secure_token_store.dart';

/// In-memory test double for [SecureTokenStore]. One `String?` field
/// stands in for the platform keystore — no Hive, no plugin channel,
/// no `Future.delayed` to simulate latency. Shared by LOG-003,
/// LOG-005, and LOG-007 tests (the file path is stable so downstream
/// tickets don't relocate it).
///
/// Implements [SecureTokenStore] by subclassing it (rather than
/// `implements`) so test code interacting with the real `_storage`
/// field never reaches it — every method override returns a value
/// derived from [_value] alone. The parent class's [FlutterSecureStorage]
/// is never invoked because every public method is overridden.
class FakeSecureTokenStore extends SecureTokenStore {
  /// The single in-memory slot. `null` represents "no token persisted".
  String? _value;

  /// Test-only accessor. Production [SecureTokenStore] does not expose
  /// a synchronous view of its contents; this is a convenience for
  /// `expect(fakeStore.value, equals(...))` assertions where the
  /// async-await ceremony adds nothing.
  String? get value => _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String token) async {
    _value = token;
  }

  @override
  Future<void> clear() async {
    _value = null;
  }
}
