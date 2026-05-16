import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'breakpoints.dart';

/// The three form-factor buckets the v1 client targets. Architecture §1.
///
/// Layout branches happen at the screen root (T-15); leaf widgets never read
/// this enum. If you find yourself sprinkling `isCompact` inside a row or
/// chip, restructure — the screen file owns both variants.
enum FormFactor {
  /// `< 600` logical px. Phones, narrow web. Bottom tab bar + FAB.
  compact,

  /// `600 – 1023`. Tablets, split-view, narrow desktop. Left rail.
  medium,

  /// `>= 1024`. Desktop web, iPad landscape. Persistent sidebar + right rail.
  expanded;

  /// Resolve the form factor for a given context. Reads from `MediaQuery`,
  /// which is itself how `AppScaffold` switches nav chrome.
  static FormFactor of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width < Breakpoints.compactMax) return FormFactor.compact;
    if (width < Breakpoints.mediumMax) return FormFactor.medium;
    return FormFactor.expanded;
  }

  bool get isCompact => this == FormFactor.compact;
  bool get isMedium => this == FormFactor.medium;
  bool get isExpanded => this == FormFactor.expanded;

  /// True on Flutter web of any width. Use this to gate features that depend
  /// on platform capability (e.g. native barcode scanning, haptics, app
  /// lifecycle) rather than on layout. `isCompact` already handles layout.
  static bool get isWeb => kIsWeb;
}

/// Convenience `BuildContext` extensions so callers can write
/// `context.formFactor.isCompact` without importing the enum statically.
extension FormFactorContext on BuildContext {
  FormFactor get formFactor => FormFactor.of(this);
}
