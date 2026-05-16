import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Canonical 36-px icon button.
///
/// Architecture appendix names this widget; T-20 makes `tooltip`
/// **required** so every icon button announces its purpose to a screen
/// reader and surfaces a hover tooltip on the web. T-06 (touch target
/// floor) is honored by the 44-px `InkResponse` hit slop wrapping the
/// 36-px visual square.
///
/// **Props**
/// - [icon] — the glyph (e.g. `Icons.close`, `Icons.qr_code_2`).
/// - [tooltip] — required. The hover/screen-reader label. Non-null
///   compiler enforcement is intentional: see T-20.
/// - [onPressed] — required. A purely-decorative icon is not an
///   `IconButton36`; use a plain `Icon` instead.
/// - [color] — optional icon color. Defaults to `colors.ink`.
class IconButton36 extends StatelessWidget {
  const IconButton36({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    super.key,
  });

  /// Material icon glyph rendered at 20 px inside the 36-px square.
  final IconData icon;

  /// Hover + screen-reader label. Required (T-20).
  final String tooltip;

  /// Tap handler. Required — decorative icons use plain `Icon`.
  final VoidCallback onPressed;

  /// Optional icon color override. Defaults to `context.colors.ink`.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkResponse(
          onTap: onPressed,
          radius: 22, // 44-px hit slop (T-06)
          containedInkWell: false,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Icon(icon, size: 20, color: color ?? colors.ink),
            ),
          ),
        ),
      ),
    );
  }
}
