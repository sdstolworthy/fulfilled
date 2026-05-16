import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/units/weight.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';
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
  static final Decimal _step = Decimal.parse('0.1');

  late Decimal _kg;
  late TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _kg = (widget.initial ?? Decimal.parse('70')).round(scale: 1);
    if (_kg < _min || _kg > _max) _kg = Decimal.parse('70');
    _controller = TextEditingController(text: _format(_kg));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _format(Decimal v) => formatWeightKg(v);

  void _setKg(Decimal next) {
    final clamped = next.round(scale: 1);
    if (clamped < _min || clamped > _max) return;
    setState(() {
      _kg = clamped;
      _controller.text = _format(clamped);
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _error = null;
    });
  }

  void _onFieldChanged(String raw) {
    final trimmed = raw.trim().replaceAll(',', '.');
    final parsed = Decimal.tryParse(trimmed);
    if (parsed == null) {
      setState(() => _error = 'Enter a number');
      return;
    }
    if (parsed < _min || parsed > _max) {
      setState(() => _error = 'Weight must be 30–300 kg');
      return;
    }
    setState(() {
      _kg = parsed.round(scale: 1);
      _error = null;
    });
  }

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
    final colors = context.colors;
    final space = context.space;
    final canSave = _error == null && !_saving;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: space.x5,
            vertical: space.x3,
          ),
          child: Row(
            children: <Widget>[
              _StepperButton(
                icon: Icons.remove,
                onTap: _kg > _min ? () => _setKg(_kg - _step) : null,
              ),
              SizedBox(width: space.x3),
              Expanded(
                child: TextField(
                  key: const Key('weight-field'),
                  controller: _controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  style: context.text.heroNumeric,
                  decoration: InputDecoration(
                    suffixText: 'kg',
                    suffixStyle: context.text.body.copyWith(color: colors.ink2),
                    errorText: _error,
                  ),
                  onChanged: _onFieldChanged,
                ),
              ),
              SizedBox(width: space.x3),
              _StepperButton(
                icon: Icons.add,
                onTap: _kg < _max ? () => _setKg(_kg + _step) : null,
              ),
            ],
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

class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onTap != null;
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: enabled ? colors.accentSoft : colors.line2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(context.radius.rPill),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(
            icon,
            size: 22,
            color: enabled ? colors.accent : colors.ink3,
          ),
        ),
      ),
    );
  }
}
