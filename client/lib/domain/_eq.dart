/// Equality helpers shared across the domain value types.
///
/// Audit finding #4. Several domain types (Food, Serving, LogEntry,
/// Goal, …) hand-write `==`/`hashCode` that include list-valued
/// fields. Each used a private `_listEq` helper to walk the list
/// element-by-element instead of `identical`-comparing references.
///
/// Lifting the helper here keeps the per-class operators short and
/// avoids the same helper drifting between files (the audit caught at
/// least one type — Food — declaring its own copy). A subsequent
/// sweep can move other classes onto the same helper as they're
/// touched.
library;

/// Element-by-element equality for two lists. Returns true when the
/// lists are identical, have the same length, and every paired
/// element is `==`. Stable on null elements (null == null).
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
