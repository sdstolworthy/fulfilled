import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:fulfilled/widgets/button_loading_bar.dart';
import 'package:fulfilled/widgets/weight_stepper.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';

/// Bottom sheet (compact) / dialog (expanded) shaped form for logging a
/// weight entry.
///
/// Inputs:
///   - A `QuantityStepper`-shaped weight input — `−`, value, `+`, plus
///     quick chips at common increments. Per T-07 numeric inputs always
///     have a stepper.
///   - A date row (defaults to today; tap to back-fill via `showDatePicker`).
///   - An optional note `TextField`.
///
/// **On save.**
///   - Calls `weightRepository.create(weightKg, date)` (Decimal-derived
///     double — repository round-trips back to `Decimal.parse` itself).
///   - Invalidates `weightSeriesProvider(currentRange)`, plus the
///     `oneWeek`/`oneMonth`/`threeMonths`/`oneYear`/`all` neighbors so any
///     range the user switches to next is fresh.
///   - Invalidates `weightHistoryProvider` and `meProvider` (the latter
///     because `User.currentWeightKg` derives from the latest entry).
///   - Shows a `SnackBar` success and closes the sheet/dialog.
///
/// Tenants: T-07 stepper, T-11 errors inline (no modal alerts), T-17
/// Decimal math, T-21 weight via `formatWeight` / `formatWeightWithUnit`.
class LogWeightSheet extends ConsumerStatefulWidget {
  const LogWeightSheet({
    required this.currentRange,
    this.asDialog = false,
    super.key,
  });

  /// The range chip currently shown on the parent screen — we invalidate
  /// that one specifically so the chart re-renders immediately. All other
  /// ranges are also invalidated.
  final WeightRange currentRange;

  /// True when hosted in a `Dialog` (expanded). False when hosted in a
  /// `showModalBottomSheet` (compact).
  final bool asDialog;

  @override
  ConsumerState<LogWeightSheet> createState() => _LogWeightSheetState();
}

class _LogWeightSheetState extends ConsumerState<LogWeightSheet> {
  // Internal weight in 0.1-kg units to avoid float drift. Initial value
  // is pulled from `meProvider` if available, otherwise 70.0 kg.
  // The lifted `QuantityStepper` owns its own step semantics (`0.1` for
  // kg passed from the caller); chip taps still mutate this store
  // directly to snap exactly to the chip's value.
  int _tenths = 700;
  DateTime _date = _today();
  final TextEditingController _noteCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Decimal get _weightKg =>
      (Decimal.fromInt(_tenths) / Decimal.fromInt(10))
          .toDecimal(scaleOnInfinitePrecision: 1);

  @override
  void initState() {
    super.initState();
    // Seed from current user, if known. `meProvider` is read once; we
    // don't watch it because we don't want the input value to jitter
    // mid-edit if `me` updates.
    final me = ref.read(meProvider).asData?.value;
    final w = me?.currentWeightKg;
    if (w != null) {
      final rounded = w.round(scale: 1);
      _tenths = (rounded * Decimal.fromInt(10)).toBigInt().toInt();
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/weight` is the source — the user opened this sheet from the
  /// Weight tab's FAB and wants to see the chart, summary card, and
  /// history row update beneath them after the write. The pop drops
  /// the sheet; the invalidated `weightSeriesProvider` /
  /// `weightHistoryProvider` / `meProvider` drive the page re-render
  /// (T-18).
  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(weightRepositoryProvider);
      // weightKg is one-decimal — pass the double form. The repository
      // re-parses to `Decimal` with one fraction digit; no float drift.
      await repo.create(_weightKg.toDouble(), _date);

      // Invalidate the listed providers. T-18 — minimal and explicit.
      // The currently-displayed range is invalidated first so the chart
      // re-renders immediately; the other ranges follow so any
      // subsequent switch lands on fresh data instead of a stale cache.
      ref.invalidate(weightSeriesProvider(widget.currentRange));
      for (final r in WeightRange.values) {
        if (r == widget.currentRange) continue;
        ref.invalidate(weightSeriesProvider(r));
      }
      ref.invalidate(weightHistoryProvider);
      ref.invalidate(meProvider);

      if (!mounted) return;
      // Read the active unit at toast time so the message reflects what
      // the user is looking at (T-21). The provider is read once — the
      // sheet is already popping, no need to subscribe.
      final unit = ref.read(weightUnitProvider);
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Logged ${formatWeightWithUnit(_weightKg, unit)} for '
            '${DateFormat('MMM d').format(_date)}',
          ),
          backgroundColor: context.colors.accent,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickDate() async {
    final now = _today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _Body(
      weightKg: _weightKg,
      onWeightChanged: (next) {
        // The lifted `QuantityStepper` is callback-shaped; mirror its
        // value into our int-tenths store so the chips + format stay
        // single-sourced. A `null` clear is rare here (the field has a
        // floor of 20) but defended for safety.
        if (next == null) return;
        HapticFeedback.selectionClick();
        final rounded = next.round(scale: 1);
        final tenths = (rounded * Decimal.fromInt(10)).toBigInt().toInt();
        setState(() => _tenths = tenths.clamp(200, 3000));
      },
      onQuick: (tenths) {
        HapticFeedback.selectionClick();
        setState(() => _tenths = tenths.clamp(200, 3000));
      },
      date: _date,
      onPickDate: () => unawaited(_pickDate()),
      noteCtrl: _noteCtrl,
      saving: _saving,
      error: _error,
      onSave: () => unawaited(_save()),
      onCancel: () => Navigator.of(context).pop(),
    );

    if (widget.asDialog) {
      return Padding(
        padding: EdgeInsets.all(context.space.x5),
        child: body,
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(context.radius.r4),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          context.space.x5,
          context.space.x3,
          context.space.x5,
          context.space.x4,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(height: context.space.x3),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.weightKg,
    required this.onWeightChanged,
    required this.onQuick,
    required this.date,
    required this.onPickDate,
    required this.noteCtrl,
    required this.saving,
    required this.error,
    required this.onSave,
    required this.onCancel,
  });

  final Decimal weightKg;
  final ValueChanged<Decimal?> onWeightChanged;
  final ValueChanged<int> onQuick; // tenths
  final DateTime date;
  final VoidCallback onPickDate;
  final TextEditingController noteCtrl;
  final bool saving;
  final String? error;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Log weight', style: context.text.title)),
            Semantics(
              button: true,
              label: 'Close',
              child: SizedBox(
                width: 36,
                height: 36,
                child: InkResponse(
                  onTap: onCancel,
                  radius: 18,
                  child: Center(
                    child: Icon(Icons.close,
                        size: 18, color: context.colors.ink2),
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: context.space.x3),
        WeightStepper(
          value: weightKg,
          onChanged: (next) => onWeightChanged(next),
          minKg: Decimal.parse('20'),
          maxKg: Decimal.parse('300'),
          semanticsLabel: 'Weight',
          // QL-107 — autofocus the weight input when the sheet opens so
          // the system keyboard appears immediately (single-mode sheet,
          // no create-vs-edit distinction).
          autofocus: true,
        ),
        SizedBox(height: context.space.x3),
        _QuickChips(
          weightKg: weightKg,
          onPick: onQuick,
        ),
        SizedBox(height: context.space.x4),
        _DateRow(date: date, onTap: onPickDate),
        SizedBox(height: context.space.x3),
        TextField(
          controller: noteCtrl,
          style: context.text.body,
          decoration: InputDecoration(
            hintText: 'Note (optional)',
            hintStyle: context.text.body.copyWith(color: context.colors.ink3),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radius.r2),
              borderSide: BorderSide(color: context.colors.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radius.r2),
              borderSide: BorderSide(color: context.colors.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(context.radius.r2),
              borderSide: BorderSide(color: context.colors.accent),
            ),
          ),
        ),
        if (error != null) ...<Widget>[
          SizedBox(height: context.space.x3),
          Text(
            'Couldn\'t save. Check your connection and try again.',
            style: context.text.meta.copyWith(color: context.colors.danger),
          ),
        ],
        SizedBox(height: context.space.x4),
        _SaveButton(saving: saving, onPressed: onSave),
      ],
    );
  }
}

class _QuickChips extends ConsumerWidget {
  const _QuickChips({required this.weightKg, required this.onPick});

  final Decimal weightKg;
  final ValueChanged<int> onPick; // tenths

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unit = ref.watch(weightUnitProvider);
    // Five offsets centered on the current value: -1.0 / -0.5 / cur /
    // +0.5 / +1.0. Tap to snap.
    final cur = (weightKg * Decimal.fromInt(10)).toBigInt().toInt();
    final offsets = <int>[-10, -5, 0, 5, 10];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < offsets.length; i++) ...<Widget>[
          _Chip(
            tenths: cur + offsets[i],
            isCenter: offsets[i] == 0,
            unit: unit,
            onTap: () => onPick(cur + offsets[i]),
          ),
          if (i < offsets.length - 1) SizedBox(width: context.space.x2),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.tenths,
    required this.isCenter,
    required this.unit,
    required this.onTap,
  });

  final int tenths;
  final bool isCenter;
  final WeightUnit unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = (Decimal.fromInt(tenths) / Decimal.fromInt(10))
        .toDecimal(scaleOnInfinitePrecision: 1);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radius.rPill),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x1 + 2,
        ),
        decoration: BoxDecoration(
          color: isCenter
              ? context.colors.accent
              : context.colors.surface,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(context.radius.rPill),
        ),
        child: Text(
          formatWeightWithUnit(v, unit),
          style: context.text.metaNumeric.copyWith(
            color: isCenter ? context.colors.surface : context.colors.ink,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({required this.date, required this.onTap});

  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = now.year == date.year &&
        now.month == date.month &&
        now.day == date.day;
    final fmt = DateFormat('EEEE, MMM d');
    final label = isToday ? 'Today · ${fmt.format(date)}' : fmt.format(date);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radius.r2),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x3,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(context.radius.r2),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.calendar_today_outlined,
                size: 18, color: context.colors.ink2),
            SizedBox(width: context.space.x2),
            Expanded(
              child: Text(
                label,
                style: context.text.bodyNumeric,
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: context.colors.ink3),
          ],
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.saving, required this.onPressed});

  final bool saving;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Material(
        color: context.colors.accent,
        borderRadius: BorderRadius.circular(context.radius.r3),
        child: InkWell(
          onTap: saving ? null : onPressed,
          borderRadius: BorderRadius.circular(context.radius.r3),
          child: Center(
            // QL-106 — `ButtonLoadingBar` replaces the prior
            // `CircularProgressIndicator`. T-08 / T-13: static skeleton,
            // not an indeterminate spinner; the four save-button sites
            // share the lifted widget in `lib/widgets/button_loading_bar.dart`.
            child: saving
                ? const ButtonLoadingBar()
                : Text(
                    'Save weight',
                    style: context.text.bodyStrong.copyWith(
                      color: context.colors.surface,
                      fontSize: 16,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
