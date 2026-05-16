import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/context_extensions.dart';
import '../log_entry_sheet.dart' show quantityProvider;

/// Quick-multiplier chips (0.5×, 1×, 1.5×, 2×, 3×) shown beneath the
/// log-entry sheet's `QuantityStepper`. Tapping a chip writes the
/// multiplier to [quantityProvider]; the chip whose value equals the
/// current quantity renders selected.
///
/// **Screen-04-specific composition** — intentionally NOT lifted to
/// `lib/widgets/`. The chips are a sibling widget to the canonical
/// `QuantityStepper`; the inventory entry's `quickMultipliers` slot is
/// reserved for a future inline variant. See dev_tickets.md T-002.
class QuickMultiplierChips extends ConsumerWidget {
  const QuickMultiplierChips({super.key});

  static final List<Decimal> _values = <Decimal>[
    Decimal.parse('0.5'),
    Decimal.one,
    Decimal.parse('1.5'),
    Decimal.fromInt(2),
    Decimal.fromInt(3),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(quantityProvider);
    final space = context.space;
    return Row(
      children: <Widget>[
        for (var i = 0; i < _values.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: space.x1 + 2),
          Expanded(
            child: _Chip(
              value: _values[i],
              selected: _values[i] == current,
              onTap: () =>
                  ref.read(quantityProvider.notifier).state = _values[i],
            ),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final Decimal value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final label = '${_displayValue(value)}×';
    return Semantics(
      button: true,
      selected: selected,
      label: '$label multiplier',
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: space.x2 + 2,
            vertical: space.x1 + 2,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface,
            border: Border.all(
              color: selected ? colors.accent : colors.line,
            ),
            borderRadius: BorderRadius.circular(radius.r1),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: context.text.meta.copyWith(
              fontWeight: FontWeight.w500,
              color: selected ? colors.surface : colors.ink2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  String _displayValue(Decimal v) {
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}
