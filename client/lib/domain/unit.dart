import 'package:decimal/decimal.dart';

/// Family a [Unit] belongs to. Conversions are offered within a family
/// (cup → ml) but never across (cup → g). The "no cross-family"
/// invariant is enforced both at write time (the log-entry sheet won't
/// surface a g picker on a cup-anchored serving) and at the wire
/// boundary (server returns 400 on mismatched families per Ask 10).
enum UnitFamily {
  mass,
  volume,
  count,
}

/// Measurement unit a [Serving.amount] or [LogEntry.enteredAmount] is
/// expressed in. Mirrors the `Unit` enum from the OpenAPI schema
/// declared in Ask 10. Wire string is the lowercase enum name; multi-
/// word units use snake_case (`fl_oz`).
///
/// Conversion within a family routes through [ratioToCanonical] — every
/// unit declares how many of the family's canonical unit it represents
/// (g for mass, ml for volume, 1 for count). Cross-family conversions
/// are intentionally unsupported.
enum Unit {
  // --- mass --------------------------------------------------------
  g,
  kg,
  oz,
  lb,
  // --- volume ------------------------------------------------------
  ml,
  l,
  cup,
  flOz,
  tbsp,
  tsp,
  // --- count -------------------------------------------------------
  serving,
  piece;

  /// Wire string. Snake-cases the multi-word `flOz` enum to match the
  /// OpenAPI `fl_oz` token.
  String get wire {
    switch (this) {
      case Unit.flOz:
        return 'fl_oz';
      default:
        return name;
    }
  }

  /// Short label rendered in pickers and on serving rows. Mostly the
  /// wire string, but `flOz` reads better as "fl oz" with a space.
  String get shortLabel {
    switch (this) {
      case Unit.flOz:
        return 'fl oz';
      default:
        return wire;
    }
  }

  /// Long-form label for `Semantics` and the unit dropdown's
  /// descriptive line. Singular form — callers handle pluralization at
  /// the format site if they care.
  String get longLabel {
    switch (this) {
      case Unit.g:
        return 'gram';
      case Unit.kg:
        return 'kilogram';
      case Unit.oz:
        return 'ounce';
      case Unit.lb:
        return 'pound';
      case Unit.ml:
        return 'millilitre';
      case Unit.l:
        return 'litre';
      case Unit.cup:
        return 'cup';
      case Unit.flOz:
        return 'fluid ounce';
      case Unit.tbsp:
        return 'tablespoon';
      case Unit.tsp:
        return 'teaspoon';
      case Unit.serving:
        return 'serving';
      case Unit.piece:
        return 'piece';
    }
  }

  UnitFamily get family {
    switch (this) {
      case Unit.g:
      case Unit.kg:
      case Unit.oz:
      case Unit.lb:
        return UnitFamily.mass;
      case Unit.ml:
      case Unit.l:
      case Unit.cup:
      case Unit.flOz:
      case Unit.tbsp:
      case Unit.tsp:
        return UnitFamily.volume;
      case Unit.serving:
      case Unit.piece:
        return UnitFamily.count;
    }
  }

  /// How many canonical units of this unit's family one of this unit
  /// represents. Canonical:
  ///
  /// - mass → grams
  /// - volume → millilitres
  /// - count → itself (each count unit reports 1; cross-conversion
  ///   inside `count` is never offered)
  ///
  /// Ratios match the Rust-side constants in Ask 10 byte-for-byte.
  Decimal get ratioToCanonical {
    switch (this) {
      case Unit.g:
        return Decimal.one;
      case Unit.kg:
        return Decimal.fromInt(1000);
      case Unit.oz:
        return Decimal.parse('28.349523125');
      case Unit.lb:
        return Decimal.parse('453.59237');
      case Unit.ml:
        return Decimal.one;
      case Unit.l:
        return Decimal.fromInt(1000);
      case Unit.cup:
        return Decimal.parse('236.5882365');
      case Unit.flOz:
        return Decimal.parse('29.5735295625');
      case Unit.tbsp:
        return Decimal.parse('14.78676478125');
      case Unit.tsp:
        return Decimal.parse('4.92892159375');
      case Unit.serving:
      case Unit.piece:
        return Decimal.one;
    }
  }

  static Unit fromWire(String wire) {
    for (final v in Unit.values) {
      if (v.wire == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown Unit');
  }
}

/// Convert [amount] from [from] to [to]. Both units must share a
/// family. Cross-family conversions throw — callers gate at the UI
/// layer (the unit dropdown only surfaces same-family options).
///
/// `count` units don't auto-convert between each other (one piece is
/// not one serving in general); attempting a `piece → serving` or
/// `serving → piece` conversion throws even though both are count.
Decimal convertUnit(Decimal amount, Unit from, Unit to) {
  if (from == to) return amount;
  if (from.family != to.family) {
    throw ArgumentError(
      'Cannot convert ${from.wire} → ${to.wire}: '
      'different unit families (${from.family.name} vs ${to.family.name}).',
    );
  }
  if (from.family == UnitFamily.count) {
    throw ArgumentError(
      'Cannot auto-convert between count units (${from.wire} vs ${to.wire}). '
      'Add a separate serving in the target unit instead.',
    );
  }
  // amount * (canonical-per-from) / (canonical-per-to)
  final canonical = amount * from.ratioToCanonical;
  return (canonical / to.ratioToCanonical)
      .toDecimal(scaleOnInfinitePrecision: 9);
}

/// Best-effort parse of a free-text serving label like "1 cup",
/// "30 g", "100 ml", "1 tbsp". Returns null when the label doesn't
/// match the simple `<number> <unit>` shape. Used by the OFF importer
/// (server-side) and by the FE's stopgap classifier when we're handed
/// a legacy serving label without an explicit unit on the wire.
///
/// Examples that parse: `"30 g"`, `"100 ml"`, `"1 cup"`, `"½ tbsp"`,
/// `"1 fl oz"`, `"2.5 oz"`. Examples that don't: `"1 scoop"`,
/// `"1 medium apple"`, `"1 cup (240 ml)"` (the trailing parenthetical
/// confuses the parser — callers should strip parens first).
({Decimal amount, Unit unit})? tryParseAmountUnit(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return null;

  // Match: optional fraction or decimal, whitespace, unit token.
  final m = RegExp(
    r'^(\d+(?:[.,]\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞])\s+([A-Za-z][A-Za-z ]*)$',
  ).firstMatch(trimmed);
  if (m == null) return null;

  final amountStr = m.group(1)!;
  final unitStr = m.group(2)!.trim().toLowerCase();

  final amount = _parseAmount(amountStr);
  if (amount == null) return null;

  final unit = _parseUnitToken(unitStr);
  if (unit == null) return null;

  return (amount: amount, unit: unit);
}

Decimal? _parseAmount(String s) {
  switch (s) {
    case '¼':
      return Decimal.parse('0.25');
    case '½':
      return Decimal.parse('0.5');
    case '¾':
      return Decimal.parse('0.75');
    case '⅓':
      return Decimal.parse('0.333');
    case '⅔':
      return Decimal.parse('0.667');
    case '⅛':
      return Decimal.parse('0.125');
    case '⅜':
      return Decimal.parse('0.375');
    case '⅝':
      return Decimal.parse('0.625');
    case '⅞':
      return Decimal.parse('0.875');
  }
  try {
    return Decimal.parse(s.replaceAll(',', '.'));
  } on FormatException {
    return null;
  }
}

Unit? _parseUnitToken(String token) {
  switch (token) {
    case 'g':
    case 'gram':
    case 'grams':
      return Unit.g;
    case 'kg':
    case 'kilogram':
    case 'kilograms':
      return Unit.kg;
    case 'oz':
    case 'ounce':
    case 'ounces':
      return Unit.oz;
    case 'lb':
    case 'lbs':
    case 'pound':
    case 'pounds':
      return Unit.lb;
    case 'ml':
    case 'millilitre':
    case 'millilitres':
    case 'milliliter':
    case 'milliliters':
      return Unit.ml;
    case 'l':
    case 'litre':
    case 'litres':
    case 'liter':
    case 'liters':
      return Unit.l;
    case 'cup':
    case 'cups':
      return Unit.cup;
    case 'fl oz':
    case 'floz':
    case 'fluid ounce':
    case 'fluid ounces':
      return Unit.flOz;
    case 'tbsp':
    case 'tablespoon':
    case 'tablespoons':
      return Unit.tbsp;
    case 'tsp':
    case 'teaspoon':
    case 'teaspoons':
      return Unit.tsp;
    case 'serving':
    case 'servings':
      return Unit.serving;
    case 'piece':
    case 'pieces':
      return Unit.piece;
    default:
      return null;
  }
}

/// Format an amount + unit for display. Trims trailing zeros and the
/// trailing decimal point so "1.0 cup" reads as "1 cup" and "0.50 g"
/// as "0.5 g". Count units pluralize naively (suffix "s" when amount
/// != 1) since the only count units in the enum have regular plurals.
String formatAmountUnit(Decimal amount, Unit unit) {
  final s = amount.toString();
  // Trim trailing zeros + trailing dot in one pass.
  final trimmed = s.contains('.')
      ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : s;

  switch (unit.family) {
    case UnitFamily.mass:
    case UnitFamily.volume:
      return '$trimmed ${unit.shortLabel}';
    case UnitFamily.count:
      final plural = amount == Decimal.one ? unit.shortLabel : '${unit.shortLabel}s';
      return '$trimmed $plural';
  }
}
