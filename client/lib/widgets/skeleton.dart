import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Canonical loading-skeleton primitives.
///
/// **T-08**: loading states are skeletons whose `rowHeight` equals the
/// final widget's height — never a centered `CircularProgressIndicator`
/// over a list. This file exports the two atoms screens need:
///
/// - [Skeleton] — a single shimmer block (configurable `height`, `width`,
///   `borderRadius`). Use as a building block when a feature composes its
///   own list-skeleton with feature-specific row chrome.
/// - [SkeletonRow] — the canonical row composition matching `FoodRow`
///   / `SearchResultRow` heights (thumb + two text lines + trailing
///   value column). Use this directly when the loading skeleton is for
///   a list of food/serving rows.
///
/// Source: extracted from `features/search/search_screen.dart`'s
/// `_SkeletonRow`. The shimmer animation is intentionally **not** added
/// in this ticket — the existing widget used a static `line2` block.
/// T-016 will add motion to ring/macro components; if a shimmer lands
/// later it goes here in one place.

/// Row height for the canonical [SkeletonRow]. Matches the
/// `SearchResultRow` minimum height (56 px from
/// `features/search/widgets/search_result_row.dart`) plus the vertical
/// padding so a four-row skeleton block lines up with the eventual data.
///
/// Exposed as a const so tests can pin the contract: T-08 is enforced by
/// "skeleton row height == final row height", and the static equality
/// check in `skeleton_test.dart` keeps drift loud.
const double kSkeletonRowHeight = 60;

/// A single shimmer block.
///
/// Renders a token-colored rectangle of the requested size. `width:
/// double.infinity` is the default so callers can drop a `Skeleton`
/// inside an `Expanded` / `Column` and have it span horizontally —
/// override with a specific width for inline placeholders (e.g. the
/// `width: 36` trailing-value block inside [SkeletonRow]).
///
/// `borderRadius` defaults to `0`; set it to `radius.r1 + 2` for
/// thumb-shaped placeholders so they match the production `_Thumb`
/// rounding without leaking the literal `10` into widget code.
class Skeleton extends StatelessWidget {
  const Skeleton({
    required this.height,
    this.width = double.infinity,
    this.borderRadius,
    super.key,
  });

  /// Block height. Required because every caller has a row-height
  /// contract to honor (T-08) — no sensible default exists.
  final double height;

  /// Block width. `double.infinity` so a [Skeleton] dropped into a
  /// `Column` spans horizontally; pin to a specific value for inline
  /// trailing placeholders.
  final double width;

  /// Optional rounded corners. `null` => square (the common case for
  /// text-line placeholders); set for thumb-shaped blocks.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: context.colors.line2,
        borderRadius: borderRadius,
      ),
    );
  }
}

/// A search-result-shaped skeleton row.
///
/// Layout matches `SearchResultRow` exactly: 36 px square thumb, two
/// stacked text-line placeholders, trailing 36 px kcal-value
/// placeholder. Drop this into a `Column` between dividers when a list
/// of food/serving rows is loading.
///
/// Height = [kSkeletonRowHeight] — pinned via the test so the
/// "skeleton height matches final row height" tenant cannot regress
/// silently.
class SkeletonRow extends StatelessWidget {
  const SkeletonRow({super.key});

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final radius = context.radius;
    return SizedBox(
      height: kSkeletonRowHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: space.x5,
          vertical: space.x3 + 2,
        ),
        child: Row(
          children: <Widget>[
            Skeleton(
              height: 36,
              width: 36,
              borderRadius: BorderRadius.circular(radius.r1 + 2),
            ),
            SizedBox(width: space.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Skeleton(height: 12),
                  SizedBox(height: space.x1 + 2),
                  const Skeleton(height: 10, width: 140),
                ],
              ),
            ),
            SizedBox(width: space.x3),
            const Skeleton(height: 14, width: 36),
          ],
        ),
      ),
    );
  }
}
