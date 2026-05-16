import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../form_factor/form_factor.dart';
import '../../../providers/search_focus_provider.dart';
import '../../../theme/context_extensions.dart';

/// The top-bar search input. Styled per `screen_02_search.html`:
///
/// - 44 px tall, white surface, 1 px `line` border, 14 px radius
/// - leading magnifying-glass icon
/// - trailing pill-shaped clear button when the text is non-empty
///
/// The widget is intentionally controller-driven: the screen owns the
/// `TextEditingController` (so it can be cleared from elsewhere and
/// observed for the query → provider mapping). T-21/T-17 don't apply
/// here — this widget only handles plain text.
///
/// T-06 — the visible height is 44 px, hit target ≥ 44 px on mobile.
///
/// T-015 — the inner `TextField` attaches to the global
/// [searchFieldFocusNodeProvider] so the `/` keyboard shortcut can
/// focus it from anywhere.
///
/// T-021 — placeholder copy swaps by form factor when the caller
/// doesn't override [hintText]:
///
/// - compact (phone / narrow web): "Search foods or scan barcode…" —
///   the mobile camera scanner button is visible next to the field.
/// - expanded (desktop web): "Search foods or paste a barcode…" —
///   there is no camera scanner on web; the user types or pastes the
///   digits and the screen surfaces a "Look up barcode …" affordance.
///
/// Medium falls back to the compact variant; only `expanded` swaps.
class SearchField extends ConsumerWidget {
  const SearchField({
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.hintText,
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  /// Fired when the user presses Enter while the field has focus. The
  /// screen uses this for the T-021 barcode shortcut: Enter on a
  /// matched `^\d{8,14}$` value routes to `/foods/barcode/$value`.
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  /// Explicit override. When null, the widget picks between the compact
  /// and expanded variants documented above.
  final String? hintText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focusNode = ref.watch(searchFieldFocusNodeProvider);
    final resolvedHint = hintText ??
        (context.formFactor.isExpanded
            ? 'Search foods or paste a barcode…'
            : 'Search foods or scan barcode…');
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      padding: EdgeInsets.symmetric(horizontal: context.space.x3),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 18, color: context.colors.ink2),
          SizedBox(width: context.space.x2),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              autofocus: autofocus,
              textInputAction: TextInputAction.search,
              style: context.text.body.copyWith(
                color: context.colors.ink,
                fontSize: 15,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
                hintText: resolvedHint,
                hintStyle: context.text.body.copyWith(color: context.colors.ink3),
              ),
            ),
          ),
          // Listenable rebuild for the clear-button-only — avoid rebuilding
          // the parent on every keystroke.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return Semantics(
                button: true,
                label: 'Clear search',
                child: InkResponse(
                  onTap: () {
                    controller.clear();
                    onChanged('');
                  },
                  radius: 22,
                  containedInkWell: false,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: context.colors.line,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: context.colors.ink2,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
