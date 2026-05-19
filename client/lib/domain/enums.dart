/// Shared enums that don't deserve their own file.
///
/// Mirrors the corresponding OpenAPI schemas (`Sex`, `ActivityLevel`,
/// `FoodSource`, `ServingSource`, `NutriscoreGrade`, goal direction).
/// Every enum's wire string is the lowercase enum name; `fromWire` is
/// strict so a typo round-trip surfaces at boundary, not in a widget.
library;

/// `User.sex` — `male | female | other`. v1 onboarding shows a three-up
/// segmented control; `other` is the inclusive default.
enum Sex {
  male,
  female,
  other;

  String get wire => name;

  static Sex fromWire(String wire) {
    for (final v in Sex.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown Sex');
  }
}

/// `User.activity_level` — Mifflin-St Jeor activity multiplier bands.
/// Screen 09 step 2 picks one via `ActivityOption` rows.
enum ActivityLevel {
  sedentary,
  light,
  moderate,
  active,
  veryActive;

  /// Wire string — note `very_active` uses underscore in OpenAPI.
  String get wire {
    switch (this) {
      case ActivityLevel.veryActive:
        return 'very_active';
      default:
        return name;
    }
  }

  static ActivityLevel fromWire(String wire) {
    switch (wire) {
      case 'sedentary':
        return ActivityLevel.sedentary;
      case 'light':
        return ActivityLevel.light;
      case 'moderate':
        return ActivityLevel.moderate;
      case 'active':
        return ActivityLevel.active;
      case 'very_active':
        return ActivityLevel.veryActive;
      default:
        throw ArgumentError.value(wire, 'wire', 'Unknown ActivityLevel');
    }
  }
}

/// `FoodSource` — provenance of a food row. Drives the OFF/USDA/YOU
/// thumbnails in `SearchResultRow` and the source pill in screen 03.
enum FoodSource {
  off,
  user,
  usda;

  String get wire => name;

  static FoodSource fromWire(String wire) {
    for (final v in FoodSource.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown FoodSource');
  }
}

/// `ServingSource` — `off | user | system`. The `system` value marks the
/// synthetic 100 g serving auto-seeded on every food (T-10).
enum ServingSource {
  off,
  user,
  system;

  String get wire => name;

  static ServingSource fromWire(String wire) {
    for (final v in ServingSource.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown ServingSource');
  }
}

/// `NutriscoreGrade` — only present for OFF-sourced foods. Optional on
/// the wire; widgets that render it must handle null.
enum NutriscoreGrade {
  a,
  b,
  c,
  d,
  e;

  String get wire => name;

  static NutriscoreGrade? fromWire(String? wire) {
    if (wire == null) return null;
    for (final v in NutriscoreGrade.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown NutriscoreGrade');
  }
}

/// User-selected weight display unit. Persists on `User.weight_unit`.
/// Wire string: lowercase enum name (`'kg' | 'lb' | 'st'`).
///
/// The single seam where the kg-only assumption is lifted is
/// `domain/units/weight.dart` — `formatWeight(kg, unit)` and
/// `parseWeightToKg(input, unit)` branch on this enum. Widgets never
/// inspect the unit to multiply / divide; they call the helper.
///
/// `kg` is the on-wire canonical unit (`WeightEntry.weight_kg`,
/// `Goal.start_weight_kg`, etc.) per the Display Units Principle.
/// `lb` and `st` are display-only; the wire never sees them.
enum WeightUnit {
  kg,
  lb,
  st;

  String get wire => name;

  /// User-facing short label rendered in chooser rows + suffixes.
  /// kg → "kg", lb → "lb", st → "st".
  String get shortLabel => name;

  /// Long-form for `Semantics` labels — "kilograms", "pounds",
  /// "stones and pounds". T-20.
  String get longLabel {
    switch (this) {
      case WeightUnit.kg:
        return 'kilograms';
      case WeightUnit.lb:
        return 'pounds';
      case WeightUnit.st:
        return 'stones and pounds';
    }
  }

  static WeightUnit fromWire(String wire) {
    for (final v in WeightUnit.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown WeightUnit');
  }
}

/// User-selected height display unit. Persists on `User.height_unit`
/// (pre-backend window — the Rust migration lands in QL-110; until then
/// `fromJson` tolerates a missing key per architect §3.1, §5.1).
/// Wire string: `'cm'` for centimetres, `'ft_in'` for feet + inches.
///
/// Mirrors the [WeightUnit] shape exactly so the unit-preference seam
/// stays symmetric across axes. The single seam where the cm-only
/// assumption is lifted will live in `domain/units/length.dart`
/// (QL-103) — `formatHeight(cm, unit)` and `parseHeightToCm(input,
/// unit)` branch on this enum. Widgets never inspect the unit to
/// multiply / divide; they call the helper.
///
/// `cm` is the on-wire canonical unit (`User.height_cm`,
/// `WeightEntry.*_cm`, etc.) per the Display Units Principle. `ftIn` is
/// display-only; the wire never sees the feet/inch split.
enum HeightUnit {
  cm,
  ftIn;

  /// Wire string — `cm` for centimetres, `ft_in` for the imperial
  /// feet+inches pairing. Underscore mirrors the OpenAPI convention
  /// (see [ActivityLevel.veryActive] → `'very_active'`).
  String get wire {
    switch (this) {
      case HeightUnit.cm:
        return 'cm';
      case HeightUnit.ftIn:
        return 'ft_in';
    }
  }

  /// User-facing short label rendered in chooser rows + suffixes.
  /// cm → "cm", ftIn → "ft·in".
  String get shortLabel {
    switch (this) {
      case HeightUnit.cm:
        return 'cm';
      case HeightUnit.ftIn:
        return 'ft·in';
    }
  }

  /// Long-form for `Semantics` labels — "centimeters", "feet and
  /// inches". T-20.
  String get longLabel {
    switch (this) {
      case HeightUnit.cm:
        return 'centimeters';
      case HeightUnit.ftIn:
        return 'feet and inches';
    }
  }

  static HeightUnit fromWire(String wire) {
    switch (wire) {
      case 'cm':
        return HeightUnit.cm;
      case 'ft_in':
        return HeightUnit.ftIn;
      default:
        throw ArgumentError.value(wire, 'wire', 'Unknown HeightUnit');
    }
  }
}

/// Goal direction. Not on the wire — the API stores rate as a signed
/// `weekly_rate_kg` and lets the client interpret direction from sign.
/// This client enum is the screen-facing presentation model used by
/// onboarding step 3, screen 07's hero, and the active-goal card.
enum GoalDirection {
  lose,
  maintain,
  gain;

  String get label {
    switch (this) {
      case GoalDirection.lose:
        return 'Lose weight';
      case GoalDirection.maintain:
        return 'Maintain weight';
      case GoalDirection.gain:
        return 'Gain weight';
    }
  }
}

/// Weight-chart ranges for screen 06's segmented selector. The series
/// provider is `family<WeightRange>`-keyed; adding a new range = adding
/// a value here.
enum WeightRange {
  oneWeek,
  oneMonth,
  threeMonths,
  oneYear,
  all;

  /// Number of days the range spans. `all` returns `null` — the
  /// repository interprets `null` as "every entry".
  int? get days {
    switch (this) {
      case WeightRange.oneWeek:
        return 7;
      case WeightRange.oneMonth:
        return 30;
      case WeightRange.threeMonths:
        return 90;
      case WeightRange.oneYear:
        return 365;
      case WeightRange.all:
        return null;
    }
  }

  String get label {
    switch (this) {
      case WeightRange.oneWeek:
        return '1W';
      case WeightRange.oneMonth:
        return '1M';
      case WeightRange.threeMonths:
        return '3M';
      case WeightRange.oneYear:
        return '1Y';
      case WeightRange.all:
        return 'All';
    }
  }
}
