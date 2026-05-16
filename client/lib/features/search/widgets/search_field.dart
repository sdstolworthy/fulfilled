import 'package:flutter/material.dart';

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
class SearchField extends StatelessWidget {
  const SearchField({
    required this.controller,
    required this.onChanged,
    this.autofocus = false,
    this.hintText = 'Search foods',
    super.key,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final bool autofocus;
  final String hintText;

  @override
  Widget build(BuildContext context) {
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
              onChanged: onChanged,
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
                hintText: hintText,
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
