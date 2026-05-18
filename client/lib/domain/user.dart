import 'package:decimal/decimal.dart';

import 'enums.dart';

/// The authenticated user. Mirrors `User` from the OpenAPI schema.
///
/// **Derived fields live in providers, not here.** "Current weight"
/// (latest `WeightEntry.weightKg`) and "custom food count" used to
/// hang off this record so screens could read them as one shape.
/// That meant every weight write or food write had to invalidate
/// `meProvider` to keep the snapshot fresh — a cross-tier
/// dependency that exists only to refill values that are pure
/// derivations of other providers. They now live in
/// `currentWeightKgProvider` (lib/providers/weight_providers.dart)
/// and `customFoodCountProvider` (lib/providers/food_providers.dart)
/// respectively; widgets `ref.watch` them directly.
class User {
  const User({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.displayName,
    this.email,
    this.sex,
    this.birthDate,
    this.heightCm,
    this.activityLevel,
    this.weightUnit = WeightUnit.kg,
    this.heightUnit = HeightUnit.cm,
  });

  final String id;
  final String? displayName;
  final String? email;
  final Sex? sex;
  final DateTime? birthDate;
  final Decimal? heightCm;
  final ActivityLevel? activityLevel;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The user's preferred display unit for weights. Server default is
  /// `kg`; pre-backend window `fromJson` falls back to `kg` when the wire
  /// omits the field (architect §3.1, §3.3, §4.2).
  final WeightUnit weightUnit;

  final HeightUnit heightUnit;

  User copyWith({
    String? id,
    String? displayName,
    String? email,
    Sex? sex,
    DateTime? birthDate,
    Decimal? heightCm,
    ActivityLevel? activityLevel,
    DateTime? createdAt,
    DateTime? updatedAt,
    WeightUnit? weightUnit,
    HeightUnit? heightUnit,
  }) =>
      User(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        email: email ?? this.email,
        sex: sex ?? this.sex,
        birthDate: birthDate ?? this.birthDate,
        heightCm: heightCm ?? this.heightCm,
        activityLevel: activityLevel ?? this.activityLevel,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        weightUnit: weightUnit ?? this.weightUnit,
        heightUnit: heightUnit ?? this.heightUnit,
      );

  factory User.fromJson(Map<String, dynamic> json) {
    Decimal? dec(String key) {
      final v = json[key];
      return v == null ? null : Decimal.parse(v.toString());
    }

    return User(
      id: json['id'] as String,
      displayName: json['display_name'] as String?,
      email: json['email'] as String?,
      sex: json['sex'] == null ? null : Sex.fromWire(json['sex'] as String),
      birthDate: json['birth_date'] == null
          ? null
          : DateTime.parse(json['birth_date'] as String),
      heightCm: dec('height_cm'),
      activityLevel: json['activity_level'] == null
          ? null
          : ActivityLevel.fromWire(json['activity_level'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      // Pre-backend window: tolerate a missing `weight_unit` key and
      // default to `kg`. Once the Rust migration lands the server emits
      // the field for every user (architect §3.1, §4.2).
      weightUnit: json['weight_unit'] == null
          ? WeightUnit.kg
          : WeightUnit.fromWire(json['weight_unit'] as String),
      // Pre-backend window: tolerate a missing `height_unit` key and
      // default to `cm`. The Rust migration (QL-110) is the flip point;
      // until then `cm` is the canonical fallback.
      heightUnit: json['height_unit'] == null
          ? HeightUnit.cm
          : HeightUnit.fromWire(json['height_unit'] as String),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (displayName != null) 'display_name': displayName,
        if (email != null) 'email': email,
        if (sex != null) 'sex': sex!.wire,
        if (birthDate != null)
          'birth_date':
              '${birthDate!.year.toString().padLeft(4, '0')}-${birthDate!.month.toString().padLeft(2, '0')}-${birthDate!.day.toString().padLeft(2, '0')}',
        if (heightCm != null) 'height_cm': heightCm.toString(),
        if (activityLevel != null) 'activity_level': activityLevel!.wire,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'weight_unit': weightUnit.wire,
        'height_unit': heightUnit.wire,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User &&
          other.id == id &&
          other.displayName == displayName &&
          other.email == email &&
          other.sex == sex &&
          other.birthDate == birthDate &&
          other.heightCm == heightCm &&
          other.activityLevel == activityLevel &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.weightUnit == weightUnit &&
          other.heightUnit == heightUnit;

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        email,
        sex,
        birthDate,
        heightCm,
        activityLevel,
        createdAt,
        updatedAt,
        weightUnit,
        heightUnit,
      );
}

/// True when [me] has not finished onboarding — at least one of the four
/// nullable profile fields (`sex`, `birthDate`, `heightCm`,
/// `activityLevel`) is still null.
///
/// Used by the F3 router redirect to gate brand-new authenticated users
/// into `/onboarding/1`. All four fields are checked (not just one)
/// because a user may bail mid-onboarding — `PATCH /me` from step 2 of
/// a previous session may have populated sex+birth but not the others,
/// and we want every re-entry to bounce them back until all four are
/// non-null. The first goal isn't part of the predicate because step 3
/// commits profile + goal in a single user-visible transaction.
bool needsOnboarding(User me) =>
    me.sex == null ||
    me.birthDate == null ||
    me.heightCm == null ||
    me.activityLevel == null;

/// Outgoing `PATCH /me` payload. Sparse on purpose — only the fields the
/// caller sets are emitted to JSON.
class UserPatch {
  const UserPatch({
    this.displayName,
    this.email,
    this.sex,
    this.birthDate,
    this.heightCm,
    this.activityLevel,
    this.weightUnit,
    this.heightUnit,
  });

  final String? displayName;
  final String? email;
  final Sex? sex;
  final DateTime? birthDate;
  final Decimal? heightCm;
  final ActivityLevel? activityLevel;

  /// Sparse update to `User.weight_unit`. Emits the wire key only when
  /// non-null so the patch stays minimal (architect §3.3).
  final WeightUnit? weightUnit;

  /// Sparse update to `User.height_unit`. Mirror of [weightUnit] — emits
  /// the wire key only when non-null so the patch stays minimal. The
  /// backend column lands in QL-110; until then the Rust API ignores
  /// unknown keys on PATCH /me (architect §3.3, §10.3).
  final HeightUnit? heightUnit;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (displayName != null) 'display_name': displayName,
        if (email != null) 'email': email,
        if (sex != null) 'sex': sex!.wire,
        if (birthDate != null)
          'birth_date':
              '${birthDate!.year.toString().padLeft(4, '0')}-${birthDate!.month.toString().padLeft(2, '0')}-${birthDate!.day.toString().padLeft(2, '0')}',
        if (heightCm != null) 'height_cm': heightCm.toString(),
        if (activityLevel != null) 'activity_level': activityLevel!.wire,
        if (weightUnit != null) 'weight_unit': weightUnit!.wire,
        if (heightUnit != null) 'height_unit': heightUnit!.wire,
      };
}
