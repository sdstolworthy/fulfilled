// QL-109 — goals weight-sweep verification.
//
// QL-009 swept `formatWeightKg(...)` call sites to the unit-aware
// `formatWeight(kg, unit)`. This test pins that sweep against the goals
// feature: any future contributor who re-introduces a `formatWeightKg(`
// call in the goals editor/active-card/history-list files will trip a
// loud assertion at CI rather than silently regress unit display.
//
// The test reads the source files at runtime via `dart:io` and grep-
// asserts the absence of the pattern. Comments / dartdoc are allowed
// to mention the symbol — the regex requires an open paren immediately
// after the identifier to catch the call-site shape and ignore
// references like "see `formatWeightKg`".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _goalsFiles = <String>[
  'lib/features/goals/widgets/goal_active_card.dart',
  'lib/features/goals/widgets/goal_editor_body.dart',
  'lib/features/goals/widgets/goal_history_list.dart',
  'lib/features/goals/widgets/new_goal_dialog.dart',
  'lib/features/goals/widgets/edit_goal_sheet.dart',
  'lib/features/goals/goals_screen.dart',
];

/// Match `formatWeightKg(` only outside comments. Strips line and
/// trailing-comment text first so a dartdoc mention doesn't trip the
/// check.
bool _hasFormatWeightKgCall(String source) {
  final lines = source.split('\n');
  for (var raw in lines) {
    var line = raw;
    // Strip line-comments (// …) — naive, but accurate enough: the
    // goals files do not use `//` inside string literals.
    final slashIdx = line.indexOf('//');
    if (slashIdx >= 0) line = line.substring(0, slashIdx);
    // Strip /// dartdoc — already handled by the // strip above (since
    // a dartdoc line starts with `///`, the substring at index 0
    // produces an empty line).
    if (RegExp(r'\bformatWeightKg\(').hasMatch(line)) {
      return true;
    }
  }
  return false;
}

void main() {
  for (final relativePath in _goalsFiles) {
    test('$relativePath has no formatWeightKg( call', () {
      final file = File(relativePath);
      if (!file.existsSync()) {
        fail('Source file missing: $relativePath');
      }
      final source = file.readAsStringSync();
      expect(
        _hasFormatWeightKgCall(source),
        isFalse,
        reason: '$relativePath must use `formatWeight(kg, unit)` instead of '
            '`formatWeightKg(...)`. QL-009 swept these; do not regress.',
      );
    });
  }
}
