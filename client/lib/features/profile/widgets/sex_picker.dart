import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../theme/context_extensions.dart';
import 'editor_footer.dart';
import 'editor_host.dart';

/// Pick `Sex` for the authenticated user. Three options, rendered as
/// large radio rows so the touch target clears T-06.
///
/// **Pure presentation leaf** — see `specs/testing_guide.md` §4.4. The
/// widget owns purely-local "selected / saving / error" state but
/// imports no providers. The `onSave` callback is supplied by the
/// container (`ProfileScreen` / `GoalEditorBody`) and performs the
/// repo write + `meProvider` invalidation; if it throws, the leaf
/// renders an inline error and keeps the sheet open.
///
/// [showSexPicker] is a thin shell helper — it mounts the leaf inside
/// the profile editor sheet/dialog. The caller (which has `ref` in
/// scope) supplies [onSave].
Future<void> showSexPicker(
  BuildContext context, {
  required Sex? initial,
  required Future<void> Function(Sex value) onSave,
}) {
  return showProfileEditor<void>(
    context: context,
    title: 'Sex',
    builder: (sheetContext) => SexPicker(initial: initial, onSave: onSave),
  );
}

/// Stateful presentation leaf for the Sex picker. Holds the user's
/// in-progress selection plus the `_saving` / `_error` UI flags. The
/// actual repo write + provider invalidation are owned by the
/// container — passed in via [onSave]. A throw from [onSave] flips
/// the leaf into the inline-error branch; success pops the editor.
class SexPicker extends StatefulWidget {
  const SexPicker({required this.initial, required this.onSave, super.key});

  /// Initial selection (from the user record). `null` means "no
  /// selection yet" — the user can pick any value and Save.
  final Sex? initial;

  /// Container-supplied save handler. Throws on failure; the leaf
  /// catches and renders an inline error.
  final Future<void> Function(Sex value) onSave;

  @override
  State<SexPicker> createState() => _SexPickerState();
}

class _SexPickerState extends State<SexPicker> {
  Sex? _value;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _value = widget.initial;
  }

  /// T-24 Case 1 — pop-to-source. `/me` is the source; the user
  /// expects the picked sex to render on the Body row they tapped
  /// from. The container's `onSave` callback does the PATCH +
  /// `meProvider` invalidation; on success we pop so the source row
  /// re-renders against the new value (T-18).
  Future<void> _save() async {
    final picked = _value;
    if (picked == null || picked == widget.initial) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(picked);
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
