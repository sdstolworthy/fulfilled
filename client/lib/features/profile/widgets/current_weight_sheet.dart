import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/units/weight.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/weight_stepper.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Current-weight editor on screen 08. The user's "current weight"
/// derives from the most recent `WeightEntry` (architect §5: profile
/// reads from sibling weight repo), so this editor calls
/// `WeightRepository.create(kg, today)` rather than `profileRepository.update`.
///
/// On save: invalidate `meProvider`, `weightSeriesProvider`,
/// `weightHistoryProvider` — the profile's derived weight and the
/// sparkline both need to refresh.
///
/// T-07 / T-21: stepper + numeric field, kg-only (PM Risk 4).
Future<void> showCurrentWeightSheet(
  BuildContext context, {
  required Decimal? initial,
}) {
  return showProfileEditor<void>(
    context: context,
    title: 'Current weight',
    builder: (sheetContext) => CurrentWeightSheet(initial: initial),
  );
}

class CurrentWeightSheet extends ConsumerStatefulWidget {
  const CurrentWeightSheet({required this.initial, super.key});

  final Decimal? initial;

  @override
  ConsumerState<CurrentWeightSheet> createState() =>
      _CurrentWeightSheetState();
}

class _CurrentWeightSheetState extends ConsumerState<CurrentWeightSheet> {
  static final Decimal _min = Decimal.fromInt(30);
  static final Decimal _max = Decimal.fromInt(300);

  late Decimal _kg;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _kg = (widget.initial ?? Decimal.parse('70')).round(scale: 1);
    if (_kg < _min || _kg > _max) _kg = Decimal.parse('70');
  }

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/me` is the source; the user expects the just-saved weight to
  /// surface on the Body row they tapped from. The repo write fires
  /// before pop and `meProvider` + `weightSeriesProvider` +
  /// `weightHistoryProvider` are invalidated, so the profile row and
  /// any neighbouring weight surfaces re-derive on the next frame (T-18).
  Future<void> _save() async {
    if (_error != null) return;
    setState(() => _saving = true);
    try {
      final weightRepo = ref.read(weightRepositoryProvider);
      // The repository rounds to one decimal; we already round in _kg.
      await weightRepo.create(_kg.toDouble(), DateTime.now());
      ref
        ..invalidate(meProvider)
        ..invalidate(weightSeriesProvider)
        ..invalidate(weightHistoryProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = ref.watch(weightUnitProvider);
    final space = context.space;
    final canSave = _error == null && !_saving;

    // The display label below the stepper mirrors the canonical kg in
    // the active unit. The stepper itself owns the input; this is the
    // "value confirmation" affordance the previous TextField provided
    // for free.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: space.x5,
            vertical: space.x3,
          ),
          child: WeightStepper(
            key: const Key('weight-field'),
            value: _kg,
            minKg: _min,
            maxKg: _max,
            hasError: _error != null,
            semanticsLabel: 'Current weight',
            onChanged: (next) {
              final clamped = next.round(scale: 1);
              if (clamped < _min || clamped > _max) {
                setState(() => _error = 'Weight must be 30–300 kg');
                return;
              }
              setState(() {
                _kg = clamped;
                _error = null;
              });
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: space.x5),
            child: Text(
              _error!,
              style: context.text.meta.copyWith(
                color: context.colors.danger,
              ),
            ),
          )
        else
          Padding(
            padding: EdgeInsets.symmetric(horizontal: space.x5),
            child: Text(
              formatWeightWithUnit(_kg, unit),
              style: context.text.meta.copyWith(color: context.colors.ink2),
            ),
          ),
        EditorFooter(
          onSave: canSave ? _save : null,
          saving: _saving,
        ),
      ],
    );
  }
}
