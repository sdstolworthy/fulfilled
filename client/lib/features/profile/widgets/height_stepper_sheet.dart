import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Height editor. T-21: cm-only for v1. T-07: numeric inputs always
/// have a stepper, so the body is a `−`/value/`+` row plus a text
/// field that opens the system numeric keyboard.
///
/// Bounds: 100–250 cm, integer steps. Outside that range the editor
/// shows an inline error and disables Save.
Future<void> showHeightStepperSheet(
  BuildContext context, {
  required Decimal? initial,
}) {
  return showProfileEditor<void>(
    context: context,
    title: 'Height',
    builder: (sheetContext) => HeightStepperSheet(initial: initial),
  );
}

class HeightStepperSheet extends ConsumerStatefulWidget {
  const HeightStepperSheet({required this.initial, super.key});

  final Decimal? initial;

  @override
  ConsumerState<HeightStepperSheet> createState() => _HeightStepperSheetState();
}

class _HeightStepperSheetState extends ConsumerState<HeightStepperSheet> {
  static const int _min = 100;
  static const int _max = 250;

  late int _cm;
  late TextEditingController _controller;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cm = widget.initial?.toBigInt().toInt() ?? 170;
    if (_cm < _min || _cm > _max) _cm = 170;
    _controller = TextEditingController(text: _cm.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(int next) {
    if (next < _min || next > _max) return;
    setState(() {
      _cm = next;
      _controller.text = next.toString();
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _error = null;
    });
  }

  void _onFieldChanged(String raw) {
    final parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      setState(() => _error = 'Enter a whole number');
      return;
    }
    if (parsed < _min || parsed > _max) {
      setState(() => _error = 'Height must be $_min–$_max cm');
      return;
    }
    setState(() {
      _cm = parsed;
      _error = null;
    });
  }

  Future<void> _save() async {
    final initialCm = widget.initial?.toBigInt().toInt();
    if (_error != null) return;
    if (initialCm == _cm) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(profileRepositoryProvider);
      await repo.update(UserPatch(heightCm: Decimal.fromInt(_cm)));
      ref.invalidate(meProvider);
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
                onTap: _cm > _min ? () => _set(_cm - 1) : null,
              ),
              SizedBox(width: space.x3),
              Expanded(
                child: TextField(
                  key: const Key('height-field'),
                  controller: _controller,
                  keyboardType: const TextInputType.numberWithOptions(),
                  textAlign: TextAlign.center,
                  style: context.text.heroNumeric,
                  decoration: InputDecoration(
                    suffixText: 'cm',
                    suffixStyle: context.text.body.copyWith(color: colors.ink2),
                    errorText: _error,
                  ),
                  onChanged: _onFieldChanged,
                ),
              ),
              SizedBox(width: space.x3),
              _StepperButton(
                icon: Icons.add,
                onTap: _cm < _max ? () => _set(_cm + 1) : null,
              ),
            ],
          ),
        ),
        EditorFooter(
          onSave: canSave ? _save : null,
          saving: _saving,
          // The inline error already renders under the field; don't
          // double-render it in the footer.
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
