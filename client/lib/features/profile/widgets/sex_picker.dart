import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/enums.dart';
import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../goals/recompute_active_goal.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Pick `Sex` for the authenticated user. Three options, rendered as
/// large radio rows so the touch target clears T-06.
///
/// On save: PATCH `/me` via `profileRepository.update(UserPatch)`,
/// invalidate `meProvider`, dismiss the editor.
Future<void> showSexPicker(BuildContext context, {required Sex? initial}) {
  return showProfileEditor<void>(
    context: context,
    title: 'Sex',
    builder: (sheetContext) => SexPicker(initial: initial),
  );
}

class SexPicker extends ConsumerStatefulWidget {
  const SexPicker({required this.initial, super.key});

  final Sex? initial;

  @override
  ConsumerState<SexPicker> createState() => _SexPickerState();
}

class _SexPickerState extends ConsumerState<SexPicker> {
  Sex? _value;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/me` is the source; the user expects the picked sex to render on
  /// the Body row they tapped from. PATCH `/me` fires before pop, then
  /// `meProvider` invalidation drives the profile re-read (T-18).
  Future<void> _save() async {
    if (_value == null || _value == widget.initial) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      await repo.update(UserPatch(sex: _value));
      ref.invalidate(meProvider);
      await recomputeActiveGoalAfterProfileChange(ref);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
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
        for (final sex in Sex.values)
          _SexOption(
            sex: sex,
            selected: _value == sex,
            onTap: _saving ? null : () => setState(() => _value = sex),
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

class _SexOption extends StatelessWidget {
  const _SexOption({
    required this.sex,
    required this.selected,
    required this.onTap,
  });

  final Sex sex;
  final bool selected;
  final VoidCallback? onTap;

  String get _label {
    switch (sex) {
      case Sex.male:
        return 'Male';
      case Sex.female:
        return 'Female';
      case Sex.other:
        return 'Other';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x5,
        vertical: context.space.x1,
      ),
      child: Material(
        color: selected ? colors.accentSoft : colors.surface,
        borderRadius: BorderRadius.circular(context.radius.r2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.radius.r2),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x4,
              vertical: context.space.x3,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(context.radius.r2),
              border: Border.all(
                color: selected ? colors.accent : colors.line,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? colors.accent : colors.ink3,
                ),
                SizedBox(width: context.space.x3),
                Text(
                  _label,
                  style: context.text.body.copyWith(
                    color: selected ? colors.accent : colors.ink,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
