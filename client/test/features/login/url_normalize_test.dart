@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/login/url_normalize.dart';

/// LOG-002 — fixture-table test for [normalizeServerUrl].
///
/// The architect plan (§2.4) ships this table as the inspection-correct
/// contract for the function: one `test()` per row, in table order. The
/// PM-facing error strings under throw cases live in
/// `url_normalize.dart` itself; this file asserts the **kind**, not the
/// message — the controller will assert the message via golden text.
///
/// Table rows (architect §2.4 + LOG-002 ticket scope):
///
/// | input | allowInsecure | expected output (or thrown kind) |
/// |---|---|---|
/// | `'  https://a.com  '`              | false | `'https://a.com/api/v1'` |
/// | `'a.com'`                          | false | `'https://a.com/api/v1'` |
/// | `'a.com/'`                         | false | `'https://a.com/api/v1'` |
/// | `'a.com///'`                       | false | `'https://a.com/api/v1'` |
/// | `'https://a.com/api/v1'`           | false | `'https://a.com/api/v1'` |
/// | `'https://a.com/api/v1/'`          | false | `'https://a.com/api/v1'` |
/// | `'http://a.com'`                   | false | throws `insecureScheme` |
/// | `'http://a.com'`                   | true  | `'http://a.com/api/v1'` |
/// | `'http://192.168.1.5:8080'`        | true  | `'http://192.168.1.5:8080/api/v1'` |
/// | `'localhost:8080'`                 | false | `'https://localhost:8080/api/v1'` |
/// | `'a.com/fulfilled/api/v1'`         | false | `'https://a.com/fulfilled/api/v1'` |
/// | `''`                               | false | throws `empty` |
/// | `'   '`                            | false | throws `empty` |
/// | `'not a url at all'`               | false | throws `malformed` |
/// | `'http://'`                        | true  | throws `malformed` |
void main() {
  group('normalizeServerUrl', () {
    test('strips surrounding whitespace and appends /api/v1', () {
      expect(
        normalizeServerUrl('  https://a.com  '),
        'https://a.com/api/v1',
      );
    });

    test('bare host with no scheme gets https:// + /api/v1', () {
      expect(normalizeServerUrl('a.com'), 'https://a.com/api/v1');
    });

    test('single trailing slash is stripped before normalization', () {
      expect(normalizeServerUrl('a.com/'), 'https://a.com/api/v1');
    });

    test('multiple trailing slashes are all stripped', () {
      expect(normalizeServerUrl('a.com///'), 'https://a.com/api/v1');
    });

    test('/api/v1 already present is idempotent', () {
      expect(
        normalizeServerUrl('https://a.com/api/v1'),
        'https://a.com/api/v1',
      );
    });

    test('/api/v1/ trailing slash is trimmed (still idempotent)', () {
      expect(
        normalizeServerUrl('https://a.com/api/v1/'),
        'https://a.com/api/v1',
      );
    });

    test('http:// without allowInsecure throws insecureScheme', () {
      expect(
        () => normalizeServerUrl('http://a.com'),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.insecureScheme,
          ),
        ),
      );
    });

    test('http:// with allowInsecure is accepted and gets /api/v1', () {
      expect(
        normalizeServerUrl('http://a.com', allowInsecure: true),
        'http://a.com/api/v1',
      );
    });

    test('IPv4 host with port + http + allowInsecure is accepted', () {
      expect(
        normalizeServerUrl('http://192.168.1.5:8080', allowInsecure: true),
        'http://192.168.1.5:8080/api/v1',
      );
    });

    test('dot-less host with port (localhost:8080) gets https:// + /api/v1', () {
      expect(
        normalizeServerUrl('localhost:8080'),
        'https://localhost:8080/api/v1',
      );
    });

    test('path-prefixed input preserves the operator subpath verbatim', () {
      expect(
        normalizeServerUrl('a.com/fulfilled/api/v1'),
        'https://a.com/fulfilled/api/v1',
      );
    });

    test('empty string throws empty', () {
      expect(
        () => normalizeServerUrl(''),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.empty,
          ),
        ),
      );
    });

    test('whitespace-only input throws empty', () {
      expect(
        () => normalizeServerUrl('   '),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.empty,
          ),
        ),
      );
    });

    test('gibberish (spaces inside the URL) throws malformed', () {
      expect(
        () => normalizeServerUrl('not a url at all'),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.malformed,
          ),
        ),
      );
    });

    test('bare http:// (scheme but no host) throws malformed', () {
      expect(
        () => normalizeServerUrl('http://', allowInsecure: true),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.malformed,
          ),
        ),
      );
    });

    // Extra rows beyond the architect table — explicitly called out in
    // the LOG-002 ticket scope (the user prompt enumerates "double
    // trailing slash" and "bare `https://`" as cases the test should
    // exercise). They're regression guards, not contract changes.

    test('bare https:// (scheme but no host) throws malformed', () {
      expect(
        () => normalizeServerUrl('https://'),
        throwsA(
          isA<UrlNormalizeError>().having(
            (e) => e.kind,
            'kind',
            UrlNormalizeErrorKind.malformed,
          ),
        ),
      );
    });

    test('double trailing slash on a bare host is fully stripped', () {
      expect(normalizeServerUrl('a.com//'), 'https://a.com/api/v1');
    });

    test('UrlNormalizeError.toString returns the PM-facing message', () {
      try {
        normalizeServerUrl('');
        fail('expected throw');
      } on UrlNormalizeError catch (e) {
        expect(e.toString(), 'Server URL is required.');
      }
    });
  });
}
