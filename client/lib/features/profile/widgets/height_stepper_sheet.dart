import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fulfilled/widgets/height_stepper.dart';

import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Profile → Body → Height editor (QL-104 simplification).
///
/// Composes the lifted [HeightStepper] widget — the inline `_NumberStepper`,
/// hand-rolled `TextField`, and clamp logic this sheet used to carry
/// have been deleted. [HeightStepper] reads [heightUnitProvider] so the
/// rendered shape (cm-only vs ft+in) follows the active user preference
/// without any additional knob here (architect §5.10).
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

  /// Seed value in canonical centimetres. `null` falls back to an adult
  /// midpoint (170 cm) — the user has not yet set a height, so the
  /// editor opens at a sensible starting point.
  final Decimal? initial;

  @override
  ConsumerState<HeightStepperSheet> createState() => _HeightStepperSheetState();
}

class _HeightStepperSheetState extends ConsumerState<HeightStepperSheet> {
  late Decimal _cm;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cm = widget.initial ?? Decimal.fromInt(170);
  }

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/me` is the source; the user expects to see the new height value
  /// rendered on the row they tapped from. The repo write happens before
  /// the pop; `meProvider` invalidation alone suffices — every downstream
  /// height surface re-derives from `meProvider` (T-18).
  Future<void> _save() async {
    if (_saving) return;
    if (widget.initial == _cm) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      await repo.update(UserPatch(heightCm: _cm));
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x5,
            vertical: context.space.x3,
          ),
          child: HeightStepper(
            key: const Key('height-stepper'),
            value: _cm,
            onChanged: (next) => setState(() => _cm = next),
            semanticsLabel: 'Height',
          ),
        ),
        EditorFooter(
          onSave: _saving ? null : _save,
          saving: _saving,
          errorText: _error,
        ),
      ],
    );
  }
}
