import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/enums.dart';
import '../../form_factor/form_factor.dart';
import '../../theme/context_extensions.dart';
import 'widgets/log_weight_sheet.dart';
import 'widgets/weight_history_list.dart';
import 'widgets/weight_sparkline.dart';
import 'widgets/weight_summary_card.dart';

/// Screen 06 — Weight log. Architecture §9, mock
/// `specs/ui_mocks/screen_06_weight_log.html`.
///
/// Composition (top → bottom on `compact`):
///   - top bar with title + calendar icon + overflow (provided by
///     `AppScaffold` parent — but this screen is inside the ShellRoute,
///     and the shell already renders title-less. We render our own header
///     row inside the body so the calendar/overflow icons match the mock.
///   - `WeightSummaryCard` — current weight + delta pill + start/goal/avg
///     stats.
///   - `WeightSparkline` card — range segmented control + chart + axis
///     labels. Empty state for ranges with zero entries.
///   - `WeightHistoryList` — recent entries (date / weight / delta).
///   - `LogFoodFab`-shaped "Log weight" FAB on `compact`. On `medium /
///     expanded` the equivalent affordance is a primary button at the top.
///
/// **Tenants enforced:**
///   - T-02 tabular figures (every number routes through `bodyNumeric`,
///     `heroNumeric`, etc.).
///   - T-08 skeleton card while the series provider is loading (no
///     spinners).
///   - T-17 `Decimal` math throughout — the moving-avg arrives pre-baked,
///     weight deltas use `Decimal` subtraction in the summary card.
///   - T-19 `CustomPainter` only — no chart deps (see
///     `weight_sparkline.dart`).
///   - T-21 weight rendered via `formatWeight` / `formatWeightWithUnit`
///     from `lib/domain/units/weight.dart`.
///
/// **Active-goal handling.** `activeGoalProvider` throws
/// `GoalNotFoundError` when no goal exists; we catch that in the summary
/// card's `AsyncValue.error` arm and render without goal-derived stats.
class WeightScreen extends ConsumerStatefulWidget {
  const WeightScreen({super.key});

  @override
  ConsumerState<WeightScreen> createState() => _WeightScreenState();
}

class _WeightScreenState extends ConsumerState<WeightScreen> {
  // The active range chip. Defaults to 1M per the mock's selected state.
  WeightRange _range = WeightRange.oneMonth;

  Future<void> _openLogSheet() async {
    final formFactor = FormFactor.of(context);
    if (formFactor.isCompact) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => LogWeightSheet(currentRange: _range),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(context.radius.r4),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: LogWeightSheet(currentRange: _range, asDialog: true),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final formFactor = FormFactor.of(context);
    final isCompact = formFactor.isCompact;

    void openSheet() {
      // Fire-and-forget; the async work cleans up itself via the
      // sheet/dialog's own pop.
      unawaited(_openLogSheet());
    }

    return Scaffold(
      backgroundColor: context.colors.bg,
      floatingActionButton:
          isCompact ? _LogWeightFab(onPressed: openSheet) : null,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _WeightTopBar(
              onLogWeight: isCompact ? null : openSheet,
            ),
          ),
          const SliverToBoxAdapter(child: WeightSummaryCard()),
          SliverToBoxAdapter(
            child: WeightSparklineCard(
              range: _range,
              onRangeChanged: (r) => setState(() => _range = r),
              onLogWeight: openSheet,
            ),
          ),
          const SliverToBoxAdapter(child: _RecentEntriesHeader()),
          const SliverToBoxAdapter(child: WeightHistoryList()),
          SliverToBoxAdapter(
            child: SizedBox(
              height: isCompact ? 96 : context.space.x6,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeightTopBar extends StatelessWidget {
  const _WeightTopBar({this.onLogWeight});

  /// Non-null on `medium`/`expanded` only — T-12 keeps FAB on `compact`.
  final VoidCallback? onLogWeight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x4,
        context.space.x5,
        context.space.x3,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('Weight', style: context.text.pageTitle)),
          if (onLogWeight != null) ...<Widget>[
            _PrimaryLogWeightButton(onPressed: onLogWeight!),
            SizedBox(width: context.space.x2),
          ],
          const _HeaderIconButton(
            icon: Icons.calendar_today_outlined,
            tooltip: 'Pick a date',
            // Not wired in v1 — the date picker for back-filling lives on
            // the log sheet. The icon is preserved for mock parity.
            onPressed: null,
          ),
          const _HeaderIconButton(
            icon: Icons.more_horiz,
            tooltip: 'More options',
            onPressed: null,
          ),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkResponse(
          onTap: onPressed,
          radius: 22,
          child: Center(
            child: Icon(icon, size: 22, color: context.colors.ink2),
          ),
        ),
      ),
    );
  }
}

class _PrimaryLogWeightButton extends StatelessWidget {
  const _PrimaryLogWeightButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Log weight',
      child: Material(
        color: context.colors.accent,
        borderRadius: BorderRadius.circular(context.radius.rPill),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(context.radius.rPill),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x4,
              vertical: context.space.x2,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.add, size: 18, color: context.colors.surface),
                SizedBox(width: context.space.x1),
                Text(
                  'Log weight',
                  style: context.text.bodyStrong
                      .copyWith(color: context.colors.surface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogWeightFab extends StatelessWidget {
  const _LogWeightFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // T-12: FAB is the only floating action. T-06: 52 px tall, hit slop
    // larger than 44.
    return Semantics(
      button: true,
      label: 'Log weight',
      child: Material(
        color: context.colors.accent,
        borderRadius: BorderRadius.circular(context.radius.rPill),
        elevation: 6,
        shadowColor: context.colors.accent.withValues(alpha: 0.35),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(context.radius.rPill),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x5,
              vertical: context.space.x3,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.add, size: 20, color: context.colors.surface),
                SizedBox(width: context.space.x2),
                Text(
                  'Log weight',
                  style: context.text.bodyStrong
                      .copyWith(color: context.colors.surface),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentEntriesHeader extends StatelessWidget {
  const _RecentEntriesHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x4,
        context.space.x5,
        context.space.x2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'RECENT ENTRIES',
              style: context.text.eyebrow.copyWith(color: context.colors.ink3),
            ),
          ),
          Text(
            'See all',
            style: context.text.meta.copyWith(color: context.colors.ink3),
          ),
        ],
      ),
    );
  }
}
