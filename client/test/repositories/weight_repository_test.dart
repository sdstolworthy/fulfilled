// Tests for `WeightRepository` against a `FakeDioAdapter` — verifies
// wire-shape encoding/decoding for `GET/POST /weights` and
// `DELETE /weights/{id}`, plus the derived `series`/`history`/`latest`
// shims.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/repositories/weight_repository.dart';
import 'package:decimal/decimal.dart';

import '../data/fake_dio_adapter.dart';
import '_harness.dart';

Map<String, dynamic> _entryJson({
  required String id,
  required String date,
  required String weightKg,
  String? createdAt,
  String? recordedAtLocal,
  String? note,
}) =>
    <String, dynamic>{
      'id': id,
      'recorded_on': date,
      'weight_kg': weightKg,
      'created_at': createdAt ?? '${date}T07:30:00.000Z',
      if (recordedAtLocal != null) 'recorded_at_local': recordedAtLocal,
      if (note != null) 'note': note,
    };

Map<String, dynamic> _page(List<Map<String, dynamic>> rows, {int? limit}) =>
    <String, dynamic>{
      'results': rows,
      'total': rows.length,
      'limit': limit ?? 100,
      'offset': 0,
    };

({WeightRepository repo, FakeDioAdapter adapter}) _build(
  ResponseBody Function(RequestOptions) handler,
) {
  final adapter = FakeDioAdapter(handler);
  final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
    ..httpClientAdapter = adapter;
  final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
  return (repo: WeightRepository(api), adapter: adapter);
}

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  group('list()', () {
    test('GETs /weights with no params and decodes the envelope', () async {
      final h = _build((req) {
        expect(req.path, equals('/weights'));
        return jsonResponse(
          200,
          _page(<Map<String, dynamic>>[
            _entryJson(id: 'w_a', date: '2026-05-15', weightKg: '79.4'),
            _entryJson(id: 'w_b', date: '2026-05-14', weightKg: '79.6'),
          ]),
        );
      });
      final entries = await h.repo.list();
      expect(entries, hasLength(2));
      expect(entries.first.id, equals('w_a'));
      expect(entries.first.weightKg, equals(Decimal.parse('79.4')));
    });

    test('passes since/until/limit/offset as from/to/limit/offset',
        () async {
      final h = _build((req) {
        return jsonResponse(200, _page(const <Map<String, dynamic>>[]));
      });
      await h.repo.list(
        since: DateTime(2026, 5, 1),
        until: DateTime(2026, 5, 14),
        limit: 25,
        offset: 50,
      );
      final qp = h.adapter.requests.single.queryParameters;
      expect(qp['from'], equals('2026-05-01'));
      expect(qp['to'], equals('2026-05-14'));
      expect(qp['limit'], equals(25));
      expect(qp['offset'], equals(50));
    });
  });

  group('latest()', () {
    test('list(limit:1) and returns the first entry', () async {
      final h = _build((req) {
        expect(req.queryParameters['limit'], equals(1));
        return jsonResponse(
          200,
          _page(
            <Map<String, dynamic>>[
              _entryJson(id: 'w_latest', date: '2026-05-15', weightKg: '79.4'),
            ],
            limit: 1,
          ),
        );
      });
      final entry = await h.repo.latest();
      expect(entry.id, equals('w_latest'));
    });

    test('throws WeightNotFoundError when the page is empty', () async {
      final h = _build((req) => jsonResponse(
            200,
            _page(const <Map<String, dynamic>>[], limit: 1),
          ));
      await expectLater(
        () => h.repo.latest(),
        throwsA(isA<WeightNotFoundError>()),
      );
    });
  });

  group('createEntry()', () {
    test('POSTs /weights with the WeightCreate body shape', () async {
      final h = _build((req) {
        expect(req.method, equalsIgnoringCase('POST'));
        expect(req.path, equals('/weights'));
        return jsonResponse(
          201,
          _entryJson(id: 'w_new', date: '2026-05-15', weightKg: '79.5'),
        );
      });
      final entry = WeightEntry(
        id: '', // server assigns
        recordedOn: DateTime(2026, 5, 15),
        recordedAtLocal: '07:30:00',
        weightKg: Decimal.parse('79.5'),
        note: 'fasted',
        createdAt: DateTime(2026, 5, 15, 7, 31),
      );
      final created = await h.repo.createEntry(entry);
      expect(created.id, equals('w_new'));

      final body = h.adapter.requests.single.data as Map<String, dynamic>;
      expect(body['recorded_on'], equals('2026-05-15'));
      expect(body['recorded_at_local'], equals('07:30:00'));
      expect(body['weight_kg'], equals('79.5'));
      expect(body['note'], equals('fasted'));
      // The server assigns id + created_at; the create body must not
      // carry them — that would let the client forge a future row.
      expect(body.containsKey('id'), isFalse);
      expect(body.containsKey('created_at'), isFalse);
    });
  });

  group('create(double, DateTime)', () {
    test('round-trips weightKg through Decimal.parse with one fraction',
        () async {
      final h = _build((req) => jsonResponse(
            201,
            _entryJson(id: 'w_new', date: '2026-05-15', weightKg: '79.5'),
          ));
      await h.repo.create(79.5, DateTime(2026, 5, 15));
      final body = h.adapter.requests.single.data as Map<String, dynamic>;
      expect(body['weight_kg'], equals('79.5'));
      expect(body['recorded_on'], equals('2026-05-15'));
    });
  });

  group('delete()', () {
    test('DELETEs /weights/{id} and returns void on 204', () async {
      final h = _build((req) {
        expect(req.method, equalsIgnoringCase('DELETE'));
        expect(req.path, equals('/weights/w_x'));
        return emptyResponse(204);
      });
      await h.repo.delete('w_x');
      expect(h.adapter.requests, hasLength(1));
    });

    test('404 → WeightNotFoundError', () async {
      final h = _build((_) => emptyResponse(404));
      await expectLater(
        () => h.repo.delete('w_missing'),
        throwsA(isA<WeightNotFoundError>()),
      );
    });
  });

  group('series() / history()', () {
    test(
      'series(WeightRange.oneMonth) returns up to 30 ascending points '
      'and computes movingAvg7d after the 7th',
      () async {
        // Build 30 days of entries — newest-first on the wire.
        final rows = <Map<String, dynamic>>[];
        for (var i = 29; i >= 0; i--) {
          final d = DateTime(2026, 5, 15).subtract(Duration(days: 29 - i));
          rows.add(
            _entryJson(
              id: 'w_$i',
              date:
                  '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
              weightKg: (80.0 - i * 0.1).toStringAsFixed(1),
            ),
          );
        }
        rows.sort((a, b) =>
            (b['recorded_on'] as String).compareTo(a['recorded_on'] as String));

        final h = _build((_) => jsonResponse(200, _page(rows)));
        final series = await h.repo.series(WeightRange.oneMonth);
        expect(series, hasLength(30));
        for (var i = 0; i < 6; i++) {
          expect(series[i].movingAvg7d, isNull);
        }
        for (var i = 6; i < series.length; i++) {
          expect(series[i].movingAvg7d, isNotNull);
        }
      },
    );

    test('history(limit:5) GETs /weights with limit=5', () async {
      final h = _build((req) {
        expect(req.queryParameters['limit'], equals(5));
        return jsonResponse(200, _page(const <Map<String, dynamic>>[], limit: 5));
      });
      final out = await h.repo.history(limit: 5);
      expect(out, isEmpty);
    });
  });
}
