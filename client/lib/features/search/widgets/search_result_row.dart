import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../domain/enums.dart';
import '../../../domain/food.dart';
import '../../../domain/serving.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';

/// Single result row in the search list.
///
/// Layout per `screen_02_search.html`:
/// - 36 px square thumb on the left (OFF / YOU / USDA badge)
/// - name (with `<mark>` highlight) over a meta line "Brand · serving"
/// - right column: kcal number + "per serving" label
///
/// **Highlight rule (architect brief gotcha).** Multi-word queries split
/// on whitespace; each non-empty word is matched case-insensitively
/// against the name, and each match gets a `highlight` background via a
/// `RichText` build. Overlapping matches are merged so we never produce
/// nested highlight spans.
///
/// T-21: kcal renders through `formatKcal` — no inline rounding.
/// T-02 numeric text uses the tabular-figures variant.
/// T-06: full row is wrapped in an `InkWell` for ≥ 44 × 44 hit slop.
class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    required this.food,
    required this.query,
    this.onTap,
    super.key,
  });

  final Food food;
  final String query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final defaultServing = _defaultServing(food);
    final kcal = food.caloriesPerDefaultServing;
    final per = defaultServing == null
        ? 'per serving'
        : 'per ${_perLabel(defaultServing.name)}';

    // T-20: composed row label — `name, serving, N kilocalories`. Children
    // are excluded so a screen reader announces the row once with the
    // rendered number rather than reading each visual leaf in turn.
    //
    // F5-T4: previously-logged rows get a "Previously logged. " prepend so
    // the section header context isn't lost in a flat a11y traversal.
    final semanticLabel = _composeSemanticLabel(
      name: food.name,
      servingName: defaultServing?.name,
      kcal: kcal,
      wasLoggedByCaller: food.wasLoggedByCaller,
    );

    return Semantics(
      container: true,
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap ?? () => context.push('/foods/${food.id}'),
        // T-018 / §7 — search-result rows tint to `line2` on hover. The
        // accent stays reserved for selection (T-04).
        hoverColor: context.colors.line2,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x5,
              vertical: context.space.x3 + 2,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                _Thumb(source: food.source),
                SizedBox(width: context.space.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _HighlightedName(name: food.name, query: query),
                      const SizedBox(height: 2),
                      // F5-T4: on previously-logged rows we swap the catalog
                      // brand sub-line for a personal "Logged Tue · 4×" sub-
                      // line. Accent-tinted + w600 so the cluster pops within
                      // its "YOUR FOODS" section without becoming a screaming
                      // pill. Falls through to the existing brand sub-line
                      // when the row was never logged (or when log fields
                      // aren't on the wire — defensive).
                      Text(
                        food.wasLoggedByCaller
                            ? formatLoggedSubline(
                                food.lastLoggedAt!,
                                food.logCount,
                              )
                            : _metaLine(food, defaultServing),
                        style: context.text.metaNumeric.copyWith(
                          color: food.wasLoggedByCaller
                              ? context.colors.accent
                              : context.colors.ink2,
                          fontSize: 12,
                          fontWeight: food.wasLoggedByCaller
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.space.x3),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      kcal == null ? '—' : formatKcal(kcal),
                      style: context.text.bodyNumeric.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      per,
                      style: context.text.meta.copyWith(
                        color: context.colors.ink2,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _composeSemanticLabel({
  required String name,
  required String? servingName,
  required Decimal? kcal,
  bool wasLoggedByCaller = false,
}) {
  final parts = <String>[name];
  if (servingName != null && servingName.trim().isNotEmpty) {
    parts.add(servingName);
  }
  if (kcal != null) {
    parts.add('${formatKcal(kcal)} kilocalories');
  } else {
    parts.add('kilocalories unknown');
  }
  final body = parts.join(', ');
  return wasLoggedByCaller ? 'Previously logged. $body' : body;
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.source});

  final FoodSource source;

  @override
  Widget build(BuildContext context) {
    final isUser = source == FoodSource.user;
    final label = switch (source) {
      FoodSource.user => 'YOU',
      FoodSource.off => 'OFF',
      FoodSource.usda => 'USDA',
    };
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isUser ? context.colors.userThumbBg : context.colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radius.r1 + 2),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.04 * 11,
          color: isUser ? context.colors.userThumbInk : context.colors.accent,
        ),
      ),
    );
  }
}

class _HighlightedName extends StatelessWidget {
  const _HighlightedName({required this.name, required this.query});

  final String name;
  final String query;

  @override
  Widget build(BuildContext context) {
    final spans = _highlightSpans(
      text: name,
      query: query,
      base: context.text.body.copyWith(fontSize: 14),
      highlightBg: context.colors.highlight,
    );
    return RichText(
      text: TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers — exported as top-level so the highlight algorithm is testable.
// ---------------------------------------------------------------------------

/// Build `TextSpan`s for [text] with every match of every whitespace-split
/// word in [query] painted with [highlightBg]. Matching is
/// case-insensitive. Overlapping ranges are merged so the highlight is
/// never nested (which would render double-thick on some platforms).
///
/// Empty / whitespace-only queries → a single plain span.
List<TextSpan> _highlightSpans({
  required String text,
  required String query,
  required TextStyle base,
  required Color highlightBg,
}) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }

  final words = trimmed
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }

  // Collect every (start, end) match across every word, then merge.
  final lower = text.toLowerCase();
  final ranges = <_Range>[];
  for (final w in words) {
    final needle = w.toLowerCase();
    if (needle.isEmpty) continue;
    var i = 0;
    while (true) {
      final idx = lower.indexOf(needle, i);
      if (idx < 0) break;
      ranges.add(_Range(idx, idx + needle.length));
      i = idx + needle.length;
    }
  }
  if (ranges.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }

  // Merge overlapping / touching ranges.
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final merged = <_Range>[ranges.first];
  for (var k = 1; k < ranges.length; k++) {
    final last = merged.last;
    final cur = ranges[k];
    if (cur.start <= last.end) {
      merged[merged.length - 1] =
          _Range(last.start, cur.end > last.end ? cur.end : last.end);
    } else {
      merged.add(cur);
    }
  }

  final highlightStyle = base.copyWith(backgroundColor: highlightBg);
  final spans = <TextSpan>[];
  var cursor = 0;
  for (final r in merged) {
    if (r.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, r.start), style: base));
    }
    spans.add(TextSpan(
      text: text.substring(r.start, r.end),
      style: highlightStyle,
    ));
    cursor = r.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: base));
  }
  return spans;
}

/// Test-only re-export of the highlight builder. Keeps the algorithm
/// private to the library but reachable for unit tests that don't want
/// to pump a widget tree just to assert the span shape.
@visibleForTesting
List<TextSpan> highlightSpansForTest({
  required String text,
  required String query,
  required TextStyle base,
  required Color highlightBg,
}) =>
    _highlightSpans(
      text: text,
      query: query,
      base: base,
      highlightBg: highlightBg,
    );

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}

Serving? _defaultServing(Food food) {
  for (final s in food.servings) {
    if (s.isDefault) return s;
  }
  return food.servings.isEmpty ? null : food.servings.first;
}

String _metaLine(Food food, Serving? serving) {
  final parts = <String>[];
  if (food.brand != null && food.brand!.trim().isNotEmpty) {
    parts.add(food.brand!.trim());
  } else if (food.source == FoodSource.user) {
    parts.add('Custom');
  }
  if (serving != null) {
    parts.add(serving.name);
  }
  return parts.join(' · ');
}

String _perLabel(String servingName) {
  // The mock shows "per serving" / "per container" / "per bottle" / "per
  // bowl". Strip a leading "1 " and grab the first head noun; fall back
  // to "serving". This is a cosmetic improvement only — the underlying
  // computation is always per-default-serving.
  final n = servingName.toLowerCase();
  if (n.contains('container')) return 'container';
  if (n.contains('bottle')) return 'bottle';
  if (n.contains('bowl')) return 'bowl';
  if (n.contains('slice')) return 'slice';
  if (n.contains('piece')) return 'piece';
  if (n.contains('cup')) return 'serving';
  return 'serving';
}

// ---------------------------------------------------------------------------
// F5-T4: "Logged Tue · 4×" sub-line copy.
//
// Top-level helpers so widget tests can hit the formatter directly without
// pumping the row widget. The `now` parameter is exposed so the table tests
// can pin a deterministic clock — production callers omit it and we read
// `DateTime.now()`.
// ---------------------------------------------------------------------------

/// Build the sub-line for a previously-logged search-result row.
///
/// Format: `"Logged <when>"` with an optional `" · N×"` count suffix where
/// the multiplication glyph is U+00D7 (`×`), *not* the letter `x`. The
/// suffix is dropped when [logCount] is `null` or `<= 1` ("Logged Tue · 1×"
/// reads identically to "Logged Tue"). Counts of 1000 or more render as
/// `"999+"` so the row width stays bounded; precise counts at that scale
/// no longer inform a decision.
///
/// [now] defaults to `DateTime.now()` and is parameterised for tests.
String formatLoggedSubline(
  DateTime lastLogged,
  int? logCount, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final whenText = _formatLoggedWhen(lastLogged, clock);
  final count = logCount ?? 0;
  if (count <= 1) return 'Logged $whenText';
  // Cap at 999+ — `math.min` keeps the rendered count bounded even if a
  // caller passes a huge number; the >= 1000 branch produces the "999+"
  // string and the < 1000 branch falls through to the raw int.
  final capped = math.min(count, 1000);
  final countText = capped >= 1000 ? '999+' : '$capped';
  return 'Logged $whenText · $countText×';
}

/// Render the recency portion of the sub-line:
///   - same local-calendar day → `"Today"`
///   - prior local-calendar day → `"Yesterday"`
///   - within last 7 calendar days → short weekday (`"Tue"`)
///   - within current calendar year → `"MMM d"` (`"May 3"`)
///   - older → `"MMM d, y"` (`"May 3, 2024"`)
///
/// All date math runs against the *local-calendar* `DateTime(y, m, d)`
/// constructor, so DST transitions don't shift the calendar-day comparison
/// (an instant 22:00 on a spring-forward day still resolves to the same
/// `DateTime(y, m, d)` it would on a non-DST day).
String _formatLoggedWhen(DateTime lastLogged, DateTime now) {
  final atLocal = lastLogged.toLocal();
  final nowLocal = now.toLocal();
  final today = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final atDay = DateTime(atLocal.year, atLocal.month, atLocal.day);

  if (atDay == today) return 'Today';
  if (atDay == yesterday) return 'Yesterday';

  final deltaDays = today.difference(atDay).inDays;
  if (deltaDays > 0 && deltaDays < 7) {
    return DateFormat.E().format(atLocal); // "Tue"
  }
  if (atLocal.year == nowLocal.year) {
    return DateFormat('MMM d').format(atLocal); // "May 3"
  }
  return DateFormat('MMM d, y').format(atLocal); // "May 3, 2024"
}
