/// Display Units utilities — T-21, PM Display Units Principle.
///
/// **The only place a unit transform may live.** Widgets never multiply by
/// 1000, never call `.toFixed`, never compare numbers against thresholds for
/// "should I drop the decimal here". They call a function in this module and
/// render the resulting `String`.
///
/// Imports: every formatter takes `Decimal` (T-17). Every formatter returns
/// `String`. Conversion math (sodium grams → milligrams) returns `Decimal`
/// so it can be passed to a formatter or summed without precision loss.
library;

export 'energy.dart';
export 'macros.dart';
export 'sodium.dart';
export 'weight.dart';
