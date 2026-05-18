import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/user.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../goals/recompute_active_goal.dart';

/// Birth date editor. Uses Material's built-in `showDatePicker` rather
/// than rolling our own — the system picker is keyboard- and a11y-
/// friendly and matches platform expectations on iOS / Android / web.
///
/// On select: PATCH `/me`, invalidate `meProvider`, dismiss.
///
/// T-24 Case 1 — pop-to-source. The Material date picker already pops
/// itself when the user confirms (via `showDatePicker`'s own
/// `Navigator.pop(picked)`); `/me` is underneath and re-reads
/// `meProvider` to render the updated row. No explicit pop call here —
/// the system dialog owns its own dismissal.
Future<void> showBirthDatePicker(
  BuildContext context,
  WidgetRef ref, {
  required DateTime? initial,
}) async {
  final now = DateTime.now();
  final first = DateTime(now.year - 120);
  final last = DateTime(now.year - 13);

  // Clamp the initial date so the picker opens on a valid year.
  DateTime seed = initial ?? DateTime(now.year - 30);
  if (seed.isBefore(first)) seed = first;
  if (seed.isAfter(last)) seed = last;

  final picked = await showDatePicker(
    context: context,
    initialDate: seed,
    firstDate: first,
    lastDate: last,
    helpText: 'Birth date',
  );
  if (picked == null) return;
  if (initial != null &&
      picked.year == initial.year &&
      picked.month == initial.month &&
      picked.day == initial.day) {
    return;
  }
  try {
    final repo = ref.read(profileRepositoryProvider);
    await repo.update(UserPatch(birthDate: picked));
    ref.invalidate(meProvider);
    await recomputeActiveGoalAfterProfileChange(ref);
  } catch (_) {
    // Surface inline via SnackBar — the picker is gone by now, so a
    // SnackBar is the legal channel (T-11 reserves AlertDialog for
    // destructive confirms).
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save birth date.')),
      );
    }
  }
}
