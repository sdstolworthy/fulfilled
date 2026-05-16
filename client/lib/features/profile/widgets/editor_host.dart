import 'package:flutter/material.dart';

import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';

/// Picks the correct chrome for a profile editor. Per architecture §9
/// screen 08 ("inline modals on compact, dialog on expanded — per
/// PM-prefers-modals-on-compact note"), `compact` gets a bottom sheet,
/// `medium`/`expanded` get a centered dialog.
///
/// The editor body itself is form-factor-agnostic — same widgets, same
/// state, only the shell differs (T-15).
Future<T?> showProfileEditor<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext) builder,
}) {
  final formFactor = FormFactor.of(context);
  if (formFactor.isCompact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.radius.r4),
        ),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SafeArea(
          top: false,
          child: _EditorShell(
            title: title,
            child: builder(sheetContext),
          ),
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: _EditorShell(
          title: title,
          child: builder(dialogContext),
        ),
      ),
    ),
  );
}

/// The shared header + body layout. A small grabber sits at the top on
/// compact (the modal version); the title row is identical to dialog.
class _EditorShell extends StatelessWidget {
  const _EditorShell({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isCompact = FormFactor.of(context).isCompact;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (isCompact)
          Padding(
            padding: EdgeInsets.only(top: context.space.x2),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colors.line,
                  borderRadius: BorderRadius.circular(context.radius.rPill),
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.x5,
            context.space.x4,
            context.space.x5,
            context.space.x2,
          ),
          child: Text(title, style: context.text.title),
        ),
        Flexible(child: child),
      ],
    );
  }
}
