import 'package:decimal/decimal.dart';

import 'enums.dart';

/// One serving on a food. Mirrors `Serving` in the OpenAPI schema, plus
/// a presentation-only `isSynthetic` flag (T-10): the synthetic 100 g
/// serving is `source == ServingSource.system` and `label == '100 g'`.
///
/// `isDefault` is what the OpenAPI `is_default` field stores. Toggling
/// the default belongs to a separate endpoint (`POST /servings/{id}/default`)
/// — never set `is_default` via a `Serving` patch.
class Serving {
  const Serving({
    required this.id,
    required this.name,
    required this.grams,
    required this.isDefault,
    required this.source,
    this.sortOrder = 0,
  });

  /// Stable id (UUID on the wire).
  final String id;

  /// Display label — e.g. "1 container (170 g)", "100 g", "1 cup".
  /// Maps to the OpenAPI `label` field; "name" is the presentation alias
  /// because the screen agents asked for it.
  final String name;
  final Decimal grams;
  final bool isDefault;
  final ServingSource source;
  final int sortOrder;

  /// True for the synthetic 100 g serving auto-seeded by the server. The
  /// UI shows a `Synthetic` badge per T-10. Derived, not on the wire —
  /// the server signals "synthetic" via `source == system` + the 100 g
  /// label.
  bool get isSynthetic => source == ServingSource.system && grams == Decimal.fromInt(100);

  Serving copyWith({
    String? id,
    String? name,
    Decimal? grams,
    bool? isDefault,
    ServingSource? source,
    int? sortOrder,
  }) =>
      Serving(
        id: id ?? this.id,
        name: name ?? this.name,
        grams: grams ?? this.grams,
        isDefault: isDefault ?? this.isDefault,
        source: source ?? this.source,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  factory Serving.fromJson(Map<String, dynamic> json) => Serving(
        id: json['id'] as String,
        name: json['label'] as String,
        grams: Decimal.parse((json['grams'] as Object).toString()),
        isDefault: json['is_default'] as bool,
        source: ServingSource.fromWire(json['source'] as String),
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': name,
        'grams': grams.toString(),
        'is_default': isDefault,
        'source': source.wire,
        'sort_order': sortOrder,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Serving &&
          other.id == id &&
          other.name == name &&
          other.grams == grams &&
          other.isDefault == isDefault &&
          other.source == source &&
          other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(id, name, grams, isDefault, source, sortOrder);
}
