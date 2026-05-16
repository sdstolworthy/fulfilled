import 'package:decimal/decimal.dart';

import 'enums.dart';

/// A weight + macro target scoped to a date range. Mirrors the OpenAPI
/// `Goal` schema, with a derived [direction] (lose / maintain / gain)
/// that screens consume directly.
///
/// The wire is sparse: `weekly_rate_kg` is signed (negative = lose,
/// 0 = maintain, positive = gain) and the calorie/macro targets are
/// optional. Screen 07 and onboarding step 3 need a direction enum, so
/// the repository projects one at the seam.
class Goal {
  const Goal({
    required this.id,
    required this.startedOn,
    required this.createdAt,
    required this.updatedAt,
    required this.isActive,
    this.endedOn,
    this.startWeightKg,
    this.targetWeightKg,
    this.weeklyRateKg,
    this.dailyCalorieTarget,
    this.proteinTargetG,
    this.carbsTargetG,
    this.fatTargetG,
  });

  final String id;
  final DateTime startedOn;
  final DateTime? endedOn;
  final Decimal? startWeightKg;
  final Decimal? targetWeightKg;

  /// Signed kg-per-week. Negative = lose, positive = gain, zero (or null)
  /// = maintain. Use [direction] for the screen-facing enum.
  final Decimal? weeklyRateKg;

  /// Integer kcal target (server stores `int32`). Null means "compute
  /// client-side" — onboarding does this on step 3, the live app uses
  /// the server's stored value.
  final int? dailyCalorieTarget;
  final Decimal? proteinTargetG;
  final Decimal? carbsTargetG;
  final Decimal? fatTargetG;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Presentation-only flag — true when this is the goal active on
  /// "today". Computed by the repository, not on the wire. The wire
  /// version uses `GET /goals/active?on=YYYY-MM-DD`, which returns the
  /// row whose `(starts_on, ends_on)` range covers the date. The mock
  /// repository stamps `isActive` so screen 07 can render the hero card
  /// without a second call.
  final bool isActive;

  GoalDirection get direction {
    final r = weeklyRateKg;
    if (r == null || r == Decimal.zero) return GoalDirection.maintain;
    return r < Decimal.zero ? GoalDirection.lose : GoalDirection.gain;
  }

  /// Convenience alias matching the screen-agent spec naming.
  /// `startedOn` is the wire name; `startsOn` shows up in some briefs.
  DateTime get startsOn => startedOn;

  /// Magnitude of the weekly rate (always non-negative). Use this when
  /// rendering the rate pill — direction is encoded separately in the
  /// pill icon/color.
  Decimal? get rateKgPerWeek {
    final r = weeklyRateKg;
    if (r == null) return null;
    return r.abs();
  }

  Goal copyWith({
    String? id,
    DateTime? startedOn,
    DateTime? endedOn,
    Decimal? startWeightKg,
    Decimal? targetWeightKg,
    Decimal? weeklyRateKg,
    int? dailyCalorieTarget,
    Decimal? proteinTargetG,
    Decimal? carbsTargetG,
    Decimal? fatTargetG,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Goal(
        id: id ?? this.id,
        startedOn: startedOn ?? this.startedOn,
        endedOn: endedOn ?? this.endedOn,
        startWeightKg: startWeightKg ?? this.startWeightKg,
        targetWeightKg: targetWeightKg ?? this.targetWeightKg,
        weeklyRateKg: weeklyRateKg ?? this.weeklyRateKg,
        dailyCalorieTarget: dailyCalorieTarget ?? this.dailyCalorieTarget,
        proteinTargetG: proteinTargetG ?? this.proteinTargetG,
        carbsTargetG: carbsTargetG ?? this.carbsTargetG,
        fatTargetG: fatTargetG ?? this.fatTargetG,
        isActive: isActive ?? this.isActive,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory Goal.fromJson(Map<String, dynamic> json) {
    Decimal? dec(String key) {
      final v = json[key];
      return v == null ? null : Decimal.parse(v.toString());
    }

    return Goal(
      id: json['id'] as String,
      startedOn: DateTime.parse(json['starts_on'] as String),
      endedOn: json['ends_on'] == null
          ? null
          : DateTime.parse(json['ends_on'] as String),
      startWeightKg: dec('start_weight_kg'),
      targetWeightKg: dec('target_weight_kg'),
      weeklyRateKg: dec('weekly_rate_kg'),
      dailyCalorieTarget: (json['daily_calorie_target'] as num?)?.toInt(),
      proteinTargetG: dec('protein_g_target'),
      carbsTargetG: dec('carbs_g_target'),
      fatTargetG: dec('fat_g_target'),
      // Not on the wire. The mock repository stamps this; real responses
      // get it from `GET /goals/active`, which by definition returns the
      // active goal.
      isActive: (json['is_active'] as bool?) ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'starts_on':
            '${startedOn.year.toString().padLeft(4, '0')}-${startedOn.month.toString().padLeft(2, '0')}-${startedOn.day.toString().padLeft(2, '0')}',
        if (endedOn != null)
          'ends_on':
              '${endedOn!.year.toString().padLeft(4, '0')}-${endedOn!.month.toString().padLeft(2, '0')}-${endedOn!.day.toString().padLeft(2, '0')}',
        if (startWeightKg != null) 'start_weight_kg': startWeightKg.toString(),
        if (targetWeightKg != null) 'target_weight_kg': targetWeightKg.toString(),
        if (weeklyRateKg != null) 'weekly_rate_kg': weeklyRateKg.toString(),
        if (dailyCalorieTarget != null) 'daily_calorie_target': dailyCalorieTarget,
        if (proteinTargetG != null) 'protein_g_target': proteinTargetG.toString(),
        if (carbsTargetG != null) 'carbs_g_target': carbsTargetG.toString(),
        if (fatTargetG != null) 'fat_g_target': fatTargetG.toString(),
        'is_active': isActive,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Goal &&
          other.id == id &&
          other.startedOn == startedOn &&
          other.endedOn == endedOn &&
          other.startWeightKg == startWeightKg &&
          other.targetWeightKg == targetWeightKg &&
          other.weeklyRateKg == weeklyRateKg &&
          other.dailyCalorieTarget == dailyCalorieTarget &&
          other.proteinTargetG == proteinTargetG &&
          other.carbsTargetG == carbsTargetG &&
          other.fatTargetG == fatTargetG &&
          other.isActive == isActive &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        startedOn,
        endedOn,
        startWeightKg,
        targetWeightKg,
        weeklyRateKg,
        dailyCalorieTarget,
        proteinTargetG,
        carbsTargetG,
        fatTargetG,
        isActive,
        createdAt,
        updatedAt,
      );
}

/// Outgoing `POST /goals` payload. Built by onboarding step 3 / the new
/// goal dialog and POSTed by `goal_repository.create`.
class GoalCreate {
  const GoalCreate({
    required this.startsOn,
    this.endsOn,
    this.startWeightKg,
    this.targetWeightKg,
    this.weeklyRateKg,
    this.dailyCalorieTarget,
    this.proteinTargetG,
    this.carbsTargetG,
    this.fatTargetG,
  });

  final DateTime startsOn;
  final DateTime? endsOn;
  final Decimal? startWeightKg;
  final Decimal? targetWeightKg;
  final Decimal? weeklyRateKg;
  final int? dailyCalorieTarget;
  final Decimal? proteinTargetG;
  final Decimal? carbsTargetG;
  final Decimal? fatTargetG;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'starts_on':
            '${startsOn.year.toString().padLeft(4, '0')}-${startsOn.month.toString().padLeft(2, '0')}-${startsOn.day.toString().padLeft(2, '0')}',
        if (endsOn != null)
          'ends_on':
              '${endsOn!.year.toString().padLeft(4, '0')}-${endsOn!.month.toString().padLeft(2, '0')}-${endsOn!.day.toString().padLeft(2, '0')}',
        if (startWeightKg != null) 'start_weight_kg': startWeightKg.toString(),
        if (targetWeightKg != null) 'target_weight_kg': targetWeightKg.toString(),
        if (weeklyRateKg != null) 'weekly_rate_kg': weeklyRateKg.toString(),
        if (dailyCalorieTarget != null) 'daily_calorie_target': dailyCalorieTarget,
        if (proteinTargetG != null) 'protein_g_target': proteinTargetG.toString(),
        if (carbsTargetG != null) 'carbs_g_target': carbsTargetG.toString(),
        if (fatTargetG != null) 'fat_g_target': fatTargetG.toString(),
      };
}
