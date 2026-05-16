import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/enums.dart';
import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Activity level editor. Five Mifflin-St Jeor bands, rendered as
/// big-tap rows with a title + subtitle. **Architecturally identical
/// to onboarding step 2's `ActivityOption`** — once that widget lands
/// under `widgets/activity_option.dart`, this picker should switch to
/// import it. See reply notes.
Future<void> showActivityLevelPicker(
  BuildContext context, {
  required ActivityLevel? initial,
}) {
  return showProfileEditor<void>(
    context: context,
    title: 'Activity',
    builder: (sheetContext) => ActivityLevelPicker(initial: initial),
  );
}

class ActivityLevelPicker extends ConsumerStatefulWidget {
  const ActivityLevelPicker({required this.initial, super.key});

  final ActivityLevel? initial;

  @override
  ConsumerState<ActivityLevelPicker> createState() =>
      _ActivityLevelPickerState();
}

class _ActivityLevelPickerState
    extends ConsumerState<ActivityLevelPicker> {
  ActivityLevel? _value;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

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
      await repo.update(UserPatch(activityLevel: _value));
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
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                for (final level in ActivityLevel.values)
                  _ActivityRow(
                    level: level,
                    selected: _value == level,
                    onTap: _saving
                        ? null
                        : () => setState(() => _value = level),
                  ),
              ],
            ),
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

String activityLevelLabel(ActivityLevel level) {
  switch (level) {
    case ActivityLevel.sedentary:
      return 'Sedentary';
    case ActivityLevel.light:
      return 'Lightly active';
    case ActivityLevel.moderate:
      return 'Moderately active';
    case ActivityLevel.active:
      return 'Very active';
    case ActivityLevel.veryActive:
      return 'Extra active';
  }
}

String _subtitle(ActivityLevel level) {
  switch (level) {
    case ActivityLevel.sedentary:
      return 'Little or no exercise';
    case ActivityLevel.light:
      return 'Light exercise 1–3 days / week';
    case ActivityLevel.moderate:
      return 'Moderate exercise 3–5 days / week';
    case ActivityLevel.active:
      return 'Hard exercise 6–7 days / week';
    case ActivityLevel.veryActive:
      return 'Very hard exercise + physical job';
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.level,
    required this.selected,
    required this.onTap,
  });

  final ActivityLevel level;
  final bool selected;
  final VoidCallback? onTap;

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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        activityLevelLabel(level),
                        style: context.text.bodyStrong.copyWith(
                          color: selected ? colors.accent : colors.ink,
                        ),
                      ),
                      SizedBox(height: context.space.x05),
                      Text(
                        _subtitle(level),
                        style: context.text.meta,
                      ),
                    ],
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
