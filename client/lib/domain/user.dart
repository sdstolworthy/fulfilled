import 'package:decimal/decimal.dart';

import 'enums.dart';

/// The authenticated user. Mirrors `User` from the OpenAPI schema, plus
/// a few presentation aliases that screen briefs reference by name.
///
/// `currentWeightKg` is **not** on the wire — it's derived by the
/// repository from the most recent `WeightEntry` so screen 08's identity
/// row and onboarding step 2's pre-fill have a single source.
///
/// `customFoodCount` is **not** on the wire — derived from the user's
/// custom-foods list. Screen 08's "My foods · N" row reads it directly.
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
    this.currentWeightKg,
    this.activityLevel,
    this.customFoodCount = 0,
  });

  final String id;
  final String? displayName;
  final String? email;
  final Sex? sex;
  final DateTime? birthDate;
  final Decimal? heightCm;
  final Decimal? currentWeightKg;
  final ActivityLevel? activityLevel;
  final int customFoodCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  User copyWith({
    String? id,
    String? displayName,
    String? email,
    Sex? sex,
    DateTime? birthDate,
    Decimal? heightCm,
    Decimal? currentWeightKg,
    ActivityLevel? activityLevel,
    int? customFoodCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      User(
        id: id ?? this.id,
        displayName: displayName ?? this.displayName,
        email: email ?? this.email,
        sex: sex ?? this.sex,
        birthDate: birthDate ?? this.birthDate,
        heightCm: heightCm ?? this.heightCm,
        currentWeightKg: currentWeightKg ?? this.currentWeightKg,
        activityLevel: activityLevel ?? this.activityLevel,
        customFoodCount: customFoodCount ?? this.customFoodCount,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
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
      currentWeightKg: dec('current_weight_kg'),
      activityLevel: json['activity_level'] == null
          ? null
          : ActivityLevel.fromWire(json['activity_level'] as String),
      customFoodCount: (json['custom_food_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
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
        if (currentWeightKg != null) 'current_weight_kg': currentWeightKg.toString(),
        if (activityLevel != null) 'activity_level': activityLevel!.wire,
        'custom_food_count': customFoodCount,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
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
          other.currentWeightKg == currentWeightKg &&
          other.activityLevel == activityLevel &&
          other.customFoodCount == customFoodCount &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        displayName,
        email,
        sex,
        birthDate,
        heightCm,
        currentWeightKg,
        activityLevel,
        customFoodCount,
        createdAt,
        updatedAt,
      );
}

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
  });

  final String? displayName;
  final String? email;
  final Sex? sex;
  final DateTime? birthDate;
  final Decimal? heightCm;
  final ActivityLevel? activityLevel;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (displayName != null) 'display_name': displayName,
        if (email != null) 'email': email,
        if (sex != null) 'sex': sex!.wire,
        if (birthDate != null)
          'birth_date':
              '${birthDate!.year.toString().padLeft(4, '0')}-${birthDate!.month.toString().padLeft(2, '0')}-${birthDate!.day.toString().padLeft(2, '0')}',
        if (heightCm != null) 'height_cm': heightCm.toString(),
        if (activityLevel != null) 'activity_level': activityLevel!.wire,
      };
}
