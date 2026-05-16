import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';
import '../../../widgets/button_loading_bar.dart';

/// Sticky footer for profile editors. Renders an optional inline error
/// (T-11) above a full-width accent "Save" button. The Save button is
/// disabled when [onSave] is null; while [saving] is true it shows a
/// spinner and ignores taps.
class EditorFooter extends StatelessWidget {
  const EditorFooter({
    required this.onSave,
    this.errorText,
    this.saving = false,
    this.saveLabel = 'Save',
    super.key,
  });

  final VoidCallback? onSave;
  final String? errorText;
  final bool saving;
  final String saveLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x3,
        context.space.x5,
        context.space.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (errorText != null) ...<Widget>[
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.space.x3,
                vertical: context.space.x2,
              ),
              decoration: BoxDecoration(
                color: colors.dangerSoft,
                borderRadius: BorderRadius.circular(context.radius.r2),
                border: Border.all(color: colors.danger),
              ),
              child: Text(
                errorText!,
                style: context.text.meta.copyWith(color: colors.danger),
              ),
            ),
            SizedBox(height: context.space.x2),
          ],
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: saving ? null : onSave,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.surface,
                disabledBackgroundColor: colors.accentSoft,
                disabledForegroundColor: colors.ink3,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(context.radius.r2),
                ),
                textStyle: context.text.bodyStrong,
              ),
              // QL-106 — `ButtonLoadingBar` replaces the prior
              // `CircularProgressIndicator`. Static skeleton per T-08 /
              // T-13; visual lifted from `_SaveButtonSkeleton` so the
              // four save-button sites stay in lock-step.
              child: saving ? const ButtonLoadingBar() : Text(saveLabel),
            ),
          ),
        ],
      ),
    );
  }
}
