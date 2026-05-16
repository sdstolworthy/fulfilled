import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Label + child + optional inline error row (T-11). All numeric and
/// text fields in the custom-food form wear this jacket.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.errorText,
  });

  final String label;
  final Widget child;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final hasError = errorText != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: context.text.meta.copyWith(
            color: colors.ink2,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: space.x1 + 2),
        child,
        if (hasError) ...<Widget>[
          SizedBox(height: space.x1 + 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, size: 12, color: colors.danger),
              SizedBox(width: space.x1 + 2),
              Text(
                errorText!,
                style: context.text.meta.copyWith(color: colors.danger),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
