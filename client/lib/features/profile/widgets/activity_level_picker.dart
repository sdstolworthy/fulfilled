import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fulfilled/widgets/activity_option.dart';

import '../../../domain/enums.dart';
import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../goals/recompute_active_goal.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Activity level editor. Five Mifflin-St Jeor bands, rendered as
/// big-tap rows with a title + subtitle.
///
/// **Canonical row chrome** comes from `package:fulfilled/widgets/
/// activity_option.dart` — the architect ruled the onboarding rendering
/// (custom radio dot, ink-coloured title) is the design of record; the
/// old `_ActivityRow` in this file rendered a filled radio icon with an
/// accent-tinted title, which was design drift. Both screens now share
/// one widget (T-002).
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

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/me` is the source; the user expects the picked level to render
  /// on the Body row they tapped from. PATCH `/me` fires before pop,
  /// then `meProvider` invalidation drives the profile re-read (T-18).
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
      // Activity level feeds `estimateCalories`; bring the active
      // goal back in sync so the user doesn't silently keep a
      // stale kcal target after switching from "sedentary" to
      // "active" or vice versa.
      await recomputeActiveGoalAfterProfileChange(ref);
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
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.space.x5,
                      vertical: context.space.x1,
                    ),
                    child: ActivityOption(
                      title: activityLevelLabel(level),
                      subtitle: _subtitle(level),
                      selected: _value == level,
                      onTap: _saving
                          ? null
                          : () => setState(() => _value = level),
                    ),
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

