import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'labeled_field.dart';

/// "Basics" section of the custom-food form: name (required), brand
/// (optional), barcode (optional). Field state lives on
/// `customFoodDraftProvider`; this widget binds onChanged to the
/// matching notifier method.
class BasicsSection extends ConsumerWidget {
  const BasicsSection({
    super.key,
    this.showNameError = false,
    this.autofocusName = false,
  });

  /// Save was attempted and the name field is invalid. Drives the
  /// "Required" inline error per T-11.
  final bool showNameError;

  /// QL-107 — when true, the name field autofocuses on first paint so
  /// the system keyboard appears with the screen. The screen passes
  /// `true` in create-mode only (edit-mode pre-fills the value, so
  /// autofocus would steal focus from a pre-filled review UI per
  /// architect §7.4).
  final bool autofocusName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(customFoodDraftProvider);
    final notifier = ref.read(customFoodDraftProvider.notifier);
    final space = context.space;

    final nameError =
        showNameError && draft.name.trim().isEmpty ? 'Required' : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(label: 'Basics'),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Name',
          errorText: nameError,
          child: _TextField(
            value: draft.name,
            placeholder: "e.g. Mom's lasagna",
            onChanged: notifier.setName,
            hasError: nameError != null,
            semanticsLabel: 'Food name',
            autofocus: autofocusName,
          ),
        ),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Brand (optional)',
          child: _TextField(
            value: draft.brand ?? '',
            placeholder: 'Homemade',
            onChanged: (v) => notifier.setBrand(v.isEmpty ? null : v),
            semanticsLabel: 'Brand',
          ),
        ),
        SizedBox(height: space.x3),
        LabeledField(
          label: 'Barcode (optional)',
          child: _TextField(
            value: draft.barcode ?? '',
            placeholder: 'Scan or enter',
            onChanged: (v) => notifier.setBarcode(v.isEmpty ? null : v),
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
