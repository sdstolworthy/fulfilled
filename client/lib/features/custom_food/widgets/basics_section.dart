import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';
import 'labeled_field.dart';

/// "Basics" section of the custom-food form: name (required), brand
/// (optional), barcode (optional).
///
/// Per the §4.4 passive-view rule this is a pure `StatelessWidget` —
/// it knows nothing about Riverpod. The container watches
/// `customFoodDraftProvider` and threads in the three current values
/// plus one `onXxxChanged` callback per field.
class BasicsSection extends StatelessWidget {
  const BasicsSection({
    super.key,
    required this.name,
    required this.brand,
    required this.barcode,
    required this.onNameChanged,
    required this.onBrandChanged,
    required this.onBarcodeChanged,
    this.showNameError = false,
    this.autofocusName = false,
  });

  /// Current draft name. Empty string when nothing has been typed.
  final String name;

  /// Current draft brand. `null` when the user has cleared the field;
  /// the field renders empty in either case.
  final String? brand;

  /// Current draft barcode. Same `null` vs empty semantics as [brand].
  final String? barcode;

  /// Save was attempted and the name field is invalid. Drives the
  /// "Required" inline error per T-11.
  final bool showNameError;

  /// QL-107 — when true, the name field autofocuses on first paint so
  /// the system keyboard appears with the screen. The screen passes
  /// `true` in create-mode only (edit-mode pre-fills the value, so
  /// autofocus would steal focus from a pre-filled review UI per
  /// architect §7.4).
  final bool autofocusName;

  /// Fired when the user edits the name field. Container wires this
  /// to `customFoodDraftProvider.notifier.setName`.
  final ValueChanged<String> onNameChanged;

  /// Fired when the user edits the brand field. The leaf normalises
  /// empty strings to `null` before invoking; container wires this to
  /// `customFoodDraftProvider.notifier.setBrand`.
  final ValueChanged<String?> onBrandChanged;

  /// Fired when the user edits the barcode field. Same `null` vs
  /// empty normalisation as [onBrandChanged]. Container wires this to
  /// `customFoodDraftProvider.notifier.setBarcode`.
  final ValueChanged<String?> onBarcodeChanged;

  @override
  Widget build(BuildContext context) {
    final space = context.space;

    final nameError =
        showNameError && name.trim().isEmpty ? 'Required' : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SectionHeader(label: 'Basics'),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Name',
          errorText: nameError,
          child: _TextField(
            value: name,
            placeholder: "e.g. Mom's lasagna",
            onChanged: onNameChanged,
            hasError: nameError != null,
            semanticsLabel: 'Food name',
            autofocus: autofocusName,
          ),
        ),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Brand (optional)',
          child: _TextField(
            value: brand ?? '',
            placeholder: 'Homemade',
            onChanged: (v) => onBrandChanged(v.isEmpty ? null : v),
            semanticsLabel: 'Brand',
          ),
        ),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Barcode (optional)',
          child: _TextField(
            value: barcode ?? '',
            placeholder: 'Scan or enter',
            onChanged: (v) => onBarcodeChanged(v.isEmpty ? null : v),
            semanticsLabel: 'Barcode',
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: context.text.eyebrow.copyWith(color: context.colors.ink3),
    );
  }
}

class _TextField extends StatefulWidget {
  const _TextField({
    required this.value,
    required this.onChanged,
    this.placeholder,
    this.hasError = false,
    this.semanticsLabel,
    this.autofocus = false,
  });

  final String value;
  final String? placeholder;
  final ValueChanged<String> onChanged;
  final bool hasError;
  final String? semanticsLabel;
  final bool autofocus;

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    _focus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _TextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _ctrl.text != widget.value) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    return Semantics(
      label: widget.semanticsLabel,
      textField: true,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: widget.hasError ? colors.dangerSoft : colors.surface,
          borderRadius: BorderRadius.circular(radius.r2),
          border: Border.all(
            color: widget.hasError ? colors.danger : colors.line,
            width: 1,
          ),
        ),
        padding: EdgeInsets.symmetric(horizontal: space.x3 + 2),
        alignment: Alignment.center,
        child: TextField(
          controller: _ctrl,
          focusNode: _focus,
          autofocus: widget.autofocus,
          onChanged: widget.onChanged,
          style: context.text.bodyStrong,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: widget.placeholder,
            hintStyle: context.text.bodyStrong.copyWith(color: colors.ink3),
          ),
        ),
      ),
    );
  }
}
