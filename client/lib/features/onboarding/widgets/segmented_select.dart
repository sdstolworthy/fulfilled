import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Three-up (or n-up) segmented control matching the screen-09 step-2
/// sex picker (architecture §3 component inventory — `SegmentedSelect`).
///
/// Visual contract from the mock: 48 px high, equal-flex children,
/// 12 px radius, surface-with-line for unselected, accent fill (white
/// text) for selected. Generic over the option type so callers may
/// pass enums or strings.
class SegmentedSelect<T> extends StatelessWidget {
  const SegmentedSelect({
    required this.options,
    required this.labelBuilder,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<T> options;
  final String Function(T value) labelBuilder;
  final T? selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < options.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: context.space.x2),
          Expanded(
            child: _SegmentTile<T>(
              value: options[i],
              label: labelBuilder(options[i]),
              isSelected: options[i] == selected,
              onTap: () => onChanged(options[i]),
            ),
          ),
        ],
      ],
    );
  }
}

class _SegmentTile<T> extends StatelessWidget {
  const _SegmentTile({
    required this.value,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final T value;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bg = isSelected ? colors.accent : colors.surface;
    // FX-006 / T-01: foreground on the accent fill routes through the
    // `surface` token (the design-system white) rather than `Colors.white`.
    final fg = isSelected ? colors.surface : colors.ink2;
    final border = isSelected ? colors.accent : colors.line;
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radius.r2),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(context.radius.r2),
            border: Border.all(color: border),
          ),
          child: Text(
            label,
            style: context.text.body.copyWith(
              color: fg,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
