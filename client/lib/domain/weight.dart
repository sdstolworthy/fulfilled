import 'package:decimal/decimal.dart';

/// One row in the weight history. Mirrors `Weight` in the OpenAPI schema.
///
/// `weightKg` stays a `Decimal` end-to-end (T-17). Formatting to one
/// decimal happens at the leaf via `formatWeightKg` from
/// `lib/domain/units/`.
class WeightEntry {
  const WeightEntry({
    required this.id,
    required this.recordedOn,
    required this.weightKg,
    required this.createdAt,
    this.note,
    this.recordedAtLocal,
  });

  final String id;

  /// Local calendar date. `YYYY-MM-DD` on the wire (T-16).
  final DateTime recordedOn;

  /// Local time-of-day, if known. Wire is `HH:MM:SS` — kept as a string
  /// here because there's no calendar-date to attach it to and Dart's
  /// `TimeOfDay` is lossy on seconds.
  final String? recordedAtLocal;

  final Decimal weightKg;
  final String? note;
  final DateTime createdAt;

  WeightEntry copyWith({
    String? id,
    DateTime? recordedOn,
    String? recordedAtLocal,
    Decimal? weightKg,
    String? note,
    DateTime? createdAt,
  }) =>
      WeightEntry(
        id: id ?? this.id,
        recordedOn: recordedOn ?? this.recordedOn,
        recordedAtLocal: recordedAtLocal ?? this.recordedAtLocal,
        weightKg: weightKg ?? this.weightKg,
        note: note ?? this.note,
        createdAt: createdAt ?? this.createdAt,
      );

  factory WeightEntry.fromJson(Map<String, dynamic> json) => WeightEntry(
        id: json['id'] as String,
        recordedOn: DateTime.parse(json['recorded_on'] as String),
        recordedAtLocal: json['recorded_at_local'] as String?,
        weightKg: Decimal.parse((json['weight_kg'] as Object).toString()),
        note: json['note'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'recorded_on':
            '${recordedOn.year.toString().padLeft(4, '0')}-${recordedOn.month.toString().padLeft(2, '0')}-${recordedOn.day.toString().padLeft(2, '0')}',
        if (recordedAtLocal != null) 'recorded_at_local': recordedAtLocal,
        'weight_kg': weightKg.toString(),
        if (note != null) 'note': note,
        'created_at': createdAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeightEntry &&
          other.id == id &&
          other.recordedOn == recordedOn &&
          other.recordedAtLocal == recordedAtLocal &&
          other.weightKg == weightKg &&
          other.note == note &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
        id,
        recordedOn,
        recordedAtLocal,
        weightKg,
        note,
        createdAt,
      );
}

/// One point on the sparkline. The repository computes `movingAvg7d`
/// client-side (architect gotcha for screen 06) — the server only ever
/// returns raw weight entries.
class WeightSeriesPoint {
  const WeightSeriesPoint({
    required this.date,
    required this.weightKg,
    this.movingAvg7d,
  });

  final DateTime date;
  final Decimal weightKg;

  /// 7-day moving average over the preceding 7 entries (inclusive of the
  /// current point). Null for the first six entries in a series — there
  /// aren't enough data points to average.
  final Decimal? movingAvg7d;

  WeightSeriesPoint copyWith({
    DateTime? date,
    Decimal? weightKg,
    Decimal? movingAvg7d,
  }) =>
      WeightSeriesPoint(
        date: date ?? this.date,
        weightKg: weightKg ?? this.weightKg,
        movingAvg7d: movingAvg7d ?? this.movingAvg7d,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date':
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'weight_kg': weightKg.toString(),
        if (movingAvg7d != null) 'moving_avg_7d': movingAvg7d.toString(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeightSeriesPoint &&
          other.date == date &&
          other.weightKg == weightKg &&
          other.movingAvg7d == movingAvg7d;

  @override
  int get hashCode => Object.hash(date, weightKg, movingAvg7d);
}
