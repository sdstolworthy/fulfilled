import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/auth_config.dart';
import '../../data/auth_token.dart';
import '../../domain/enums.dart';
import '../../domain/goal.dart';
import '../../domain/units/length.dart';
import '../../domain/units/weight.dart';
import '../../domain/user.dart';
import '../../providers/food_providers.dart';
import '../../providers/goal_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/repository_providers.dart';
import '../../providers/weight_providers.dart';
import '../../repositories/goal_repository.dart';
import '../../routing/routes.dart';
import '../goals/widgets/edit_goal_sheet.dart';
import '../goals/widgets/new_goal_dialog.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/skeleton.dart';
import 'widgets/activity_level_picker.dart';
import 'widgets/birth_date_picker.dart';
import 'widgets/current_weight_sheet.dart';
import 'widgets/height_stepper_sheet.dart';
import 'widgets/server_url_row.dart';
import 'widgets/settings_card.dart';
import 'widgets/settings_row.dart';
import 'widgets/sex_picker.dart';
import 'widgets/units_chooser.dart';

/// Local debug flag — flip to `true` to inspect the error/loading
/// branches against the mock provider, then revert before committing.
/// T-013 — compile-time const so the dead branch is tree-shaken.
const bool _kDebugForceError = false;

/// Screen 08 — Profile & settings.
///
/// Layout (mirrors `specs/ui_mocks/screen_08_profile.html`):
/// 1. Identity row: avatar + name + email. (The trailing "Edit"
///    affordance was cut in QL-106 — PM audit QL-007 ruled the no-op
///    "Coming soon" stub erodes trust; the row returns when a real
///    identity editor lands.)
/// 2. **Body** card: sex, birth date, height (cm), current weight (kg),
///    activity level.
/// 3. **Preferences** card: Units (informational in v1 — PM Risk 4
///    defers the toggle to v2). The **Appearance row is intentionally
///    omitted** — PM Risk 5 removed it entirely from v1. Dark mode
///    ships with v2 alongside the token sweep.
/// 4. **Data** card: "My foods (N)" → `Routes.myFoodsPath`. The
///    "Export data" row was cut in QL-106 (PM audit QL-007 / architect
///    §7.3 — real Export is a v1.1 surface; the no-op stub eroded
///    trust). Card collapses to a single row in v1.
/// 5. Sign-out outlined row in danger color → `AlertDialog` confirm.
/// 6. Version footnote.
///
/// **Sign-out wiring** — T-019. `authTokenProvider` is an
/// `AuthTokenNotifier` with `signOut()`. The confirmation callback below
/// invokes it, then `router.go('/onboarding/1')` so the back button
/// doesn't return to a signed-in screen.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meAsync = ref.watch(meProvider);
    final countAsync = ref.watch(customFoodCountProvider);

    // T-11 — transient profile fetch errors raise a SnackBar in addition
    // to the inline EmptyState. The listen fires once on transition into
    // the error state.
    ref.listen<AsyncValue<User>>(meProvider, (prev, next) {
      if (next.hasError && (prev == null || !prev.hasError)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text("Couldn't load profile: ${next.error}"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    if (_kDebugForceError) {
      return _ProfileError(
        message: 'forced',
        onRetry: () => ref.invalidate(meProvider),
      );
    }

    return meAsync.when(
      loading: () => const _ProfileSkeleton(),
      error: (err, _) => _ProfileError(
        message: err.toString(),
        onRetry: () => ref.invalidate(meProvider),
      ),
      data: (user) => _ProfileBody(
        user: user,
        customFoodCount: countAsync.maybeWhen(
          data: (n) => n,
          orElse: () => 0,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.user, required this.customFoodCount});

  final User user;
  final int customFoodCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final space = context.space;
    // Current weight is derived from the weight feed, not the user
    // record. Read it through the dedicated provider so weight
    // writes propagate without a `meProvider` invalidate.
    final currentKg = ref.watch(currentWeightKgProvider).valueOrNull;
    // The server-URL row is a pure leaf; resolve the URL here so it
    // takes a `url: String?` constructor param (§4.4).
    final serverUrl = ref.watch(baseUrlProvider);

    // Shared "PATCH /me + invalidate meProvider" handler, parameterised
    // over the `UserPatch` shape each picker emits. The pickers are
    // pure presentation; the container owns the repo write +
    // invalidation. Rethrows on failure so the leaf can render its
    // inline error / SnackBar.
    Future<void> patchMe(UserPatch patch) async {
      final repo = ref.read(profileRepositoryProvider);
      await repo.update(patch);
      ref.invalidate(meProvider);
    }

    return ListView(
      padding: EdgeInsets.only(
        top: space.x2,
        bottom: space.x6,
      ),
      children: <Widget>[
        // Page title — the architect brief renders "Me" as a top-bar h1
        // (mock line 52). AppScaffold's `title` slot is reserved for
        // shell-level chrome; we render the title inline so the
        // compact/medium/expanded layout is consistent without forking
        // an `AppScaffold(title: 'Me')` (T-15).
        Padding(
          padding: EdgeInsets.fromLTRB(
            space.x5,
            space.x2,
            space.x5,
            space.x3,
          ),
          child: Text('Me', style: context.text.pageTitle),
        ),

        // Identity row.
        _IdentityRow(user: user),

        // Body section.
        SettingsCard(
          title: 'Body',
          rows: <Widget>[
            SettingsRow(
              icon: Icons.person_outline,
              label: 'Sex',
              value: _sexLabel(user.sex),
              onTap: () => showSexPicker(
                context,
                initial: user.sex,
                onSave: (picked) => patchMe(UserPatch(sex: picked)),
              ),
            ),
            SettingsRow(
              icon: Icons.calendar_today_outlined,
              label: 'Birth date',
              value: _birthDateLabel(user.birthDate),
              onTap: () => showBirthDatePicker(
                context,
                ref,
                initial: user.birthDate,
              ),
            ),
            SettingsRow(
              key: const Key('row-height'),
              icon: Icons.height,
              label: 'Height',
              value: user.heightCm == null
                  ? 'Set'
                  : formatHeightWithUnit(user.heightCm!, user.heightUnit),
              semanticsLabel: user.heightCm == null
                  ? 'Height. Tap to set.'
                  : 'Height ${formatHeight(user.heightCm!, user.heightUnit)} '
                      '${user.heightUnit.longLabel}. Tap to change.',
              onTap: () => showHeightStepperSheet(
                context,
                initial: user.heightCm,
              ),
            ),
            SettingsRow(
              icon: Icons.monitor_weight_outlined,
              label: 'Current weight',
              value: currentKg == null
                  ? 'Set'
                  : formatWeightWithUnit(currentKg, user.weightUnit),
              onTap: () => showCurrentWeightSheet(
                context,
                initial: currentKg,
              ),
            ),
            SettingsRow(
              icon: Icons.directions_run,
              label: 'Activity',
              value: user.activityLevel == null
                  ? 'Set'
                  : activityLevelLabel(user.activityLevel!),
              onTap: () => showActivityLevelPicker(
                context,
                initial: user.activityLevel,
                onSave: (picked) =>
                    patchMe(UserPatch(activityLevel: picked)),
              ),
            ),
          ],
        ),

        // Goal card. Single row routes to the Goals screen, where the
        // user can review the active goal, edit it, or start a new
        // one. Without this surface, compact users have no way to
        // change their kcal/macro targets from the profile page
        // (sidebar entry exists only on expanded widths).
        SettingsCard(
          title: 'Goal',
          rows: <Widget>[
            _GoalRow(),
          ],
        ),

        // Preferences section. PM Risk 5: Appearance row is **NOT**
        // rendered, not even disabled. v1 ships without the toggle.
        SettingsCard(
          title: 'Preferences',
          rows: <Widget>[
            // Units row — interactive (QL-104). Tap opens the joined
            // `showUnitsChooser` (bottom sheet on compact, anchored
            // popup on medium/expanded). The trailing value reflects
            // both active short labels; the other quantities (kcal, g)
            // are locked in v1 per architect §3.12.
            SettingsRow(
              key: const Key('row-units'),
              icon: Icons.public,
              label: 'Units',
              value: '${user.weightUnit.shortLabel}, '
                  '${user.heightUnit.shortLabel}, kcal, g',
              semanticsLabel:
                  'Weight ${user.weightUnit.longLabel}, '
                  'height ${user.heightUnit.longLabel}. Tap to change.',
              onTap: () => showUnitsChooser(
                context,
                initialWeight: user.weightUnit,
                initialHeight: user.heightUnit,
                onWeightSave: (picked) =>
                    patchMe(UserPatch(weightUnit: picked)),
                onHeightSave: (picked) =>
                    patchMe(UserPatch(heightUnit: picked)),
              ),
            ),
          ],
        ),

        // Data section. QL-106 — the "Export data" row used to surface
        // a "Coming soon" SnackBar; PM audit QL-007 + architect §7.3
        // cut it in v1 since real Export is a v1.1 product surface. The
        // card collapses to just "My foods" until Export ships; the
        // architect's call is to keep the card header so the section
        // shape is stable when Export returns.
        SettingsCard(
          title: 'Data',
          rows: <Widget>[
            SettingsRow(
              icon: Icons.bookmark_outline,
              label: 'My foods',
              value: '$customFoodCount',
              onTap: () => context.push(Routes.myFoodsPath),
            ),
          ],
        ),

        // LOG-009 / PM §10 punt-list-promotion — read-only "Server"
        // row. Mounted as a sibling of the Data card (not inside) so
        // the signed-out `SizedBox.shrink()` path doesn't leave a
        // stray `SettingsCard` divider with no row below it.
        // Informational only; the user changes server via sign-out
        // → sign-in on the login screen (PM §10 anti-recommendation 10).
        ServerUrlRow(url: serverUrl),

        SizedBox(height: space.x4),

        // Sign-out outlined-row in danger color. Tap → AlertDialog
        // confirm. T-04: danger, not accent. T-11: AlertDialog is the
        // legal home for destructive confirmation.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: space.x5),
          child: _SignOutRow(
            onConfirmed: () => _onSignOutConfirmed(context, ref),
          ),
        ),

        SizedBox(height: space.x4),

        // Version footnote.
        //
        // UX-112 / PM UX pack §4 (Profile "(dev)" version tag):
        // the "(dev)" suffix is conditional on [kDebugMode]. Release
        // builds drop the suffix entirely so the footnote reads as a
        // clean version line; dev builds keep the tag so contributors
        // running a debug or profile build see the channel they're
        // looking at. `kDebugMode` is a `const` in release, so the
        // dead `' (dev)'` branch is tree-shaken at compile time.
        Center(
          key: const ValueKey('profile.version_footnote'),
          child: Text(
            'Fulfilled · v0.1.0${kDebugMode ? ' (dev)' : ''}',
            style: context.text.meta.copyWith(color: colors.ink3),
          ),
        ),
      ],
    );
  }

  Future<void> _onSignOutConfirmed(BuildContext context, WidgetRef ref) async {
    // T-019 — clear the token + the outbox Hive box, then push the user
    // back to the onboarding entry point. `router.go` (not `push`) so
    // the back button doesn't return to a signed-in screen.
    await ref.read(authTokenProvider.notifier).signOut();
    if (!context.mounted) return;
    context.go('/onboarding/1');
  }
}

// ---------------------------------------------------------------------------
// Identity row
// ---------------------------------------------------------------------------

/// Goal row inside the Profile "Goal" card. The trailing value
/// summarises the active goal (daily kcal target) so the user sees
/// at a glance what's in effect; tap opens the editor directly
/// (`openEditGoal` when an active goal exists, `openNewGoal`
/// otherwise) so the profile flow doesn't bounce the user through
/// the bare Goals screen first. Loading shows an em-dash and
/// disables the tap; errors other than `GoalNotFoundError` route
/// to `/goals` where the dedicated error surface lives.
class _GoalRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(activeGoalProvider);
    // Prefer the live derived target — it tracks profile edits
    // without waiting for the user to re-save the goal. Fall back
    // to the stored snapshot only when the derived value can't be
    // computed yet (e.g., profile still hydrating).
    final effective = ref.watch(effectiveActiveGoalTargetsProvider);
    final value = async.when(
      data: (g) {
        final kcal = effective?.dailyTargetKcal ?? g.dailyCalorieTarget;
        return kcal == null ? 'Set' : '$kcal kcal / day';
      },
      error: (e, _) => e is GoalNotFoundError ? 'Set' : '—',
      loading: () => '—',
    );
    return SettingsRow(
      icon: Icons.flag_outlined,
      label: 'Daily calorie target',
      value: value,
      semanticsLabel: 'Daily calorie target $value. Tap to edit.',
      onTap: () => _openEditor(context, ref, async),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<Goal> async,
  ) async {
    final active = async.valueOrNull;
    if (active != null) {
      await openEditGoal(context, active: active);
      return;
    }
    if (async.error is GoalNotFoundError) {
      await openNewGoal(context);
      return;
    }
    // Loading or unexpected error — fall through to the dedicated
    // screen so it can render its own loading skeleton / error body.
    if (context.mounted) unawaited(context.push(Routes.goalsPath));
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.user});

  final User user;

  String _initials(String? displayName, String? email) {
    final source = (displayName == null || displayName.isEmpty)
        ? (email ?? '?')
        : displayName;
    final parts = source.trim().split(RegExp(r'[\s@.]+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      final s = parts.first;
      return s.isEmpty ? '?' : s.substring(0, 1).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        space.x5,
        space.x1,
        space.x5,
        space.x4,
      ),
      // QL-106 — the trailing "Edit" `TextButton` used to surface a
      // "Coming soon" SnackBar (v1 has no dedicated identity editor).
      // PM audit QL-007: hide the row entirely until auth ships, so
      // we don't ship a broken affordance. The avatar + name + email
      // remain as informational identity chrome.
      child: Row(
        children: <Widget>[
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: colors.accentSoft,
              borderRadius: BorderRadius.circular(32),
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(user.displayName, user.email),
              style: context.text.title.copyWith(color: colors.accent),
            ),
          ),
          SizedBox(width: space.x3 + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  user.displayName?.isNotEmpty == true
                      ? user.displayName!
                      : 'Set a name',
                  style: context.text.title,
                ),
                SizedBox(height: space.x05),
                if (user.email != null)
                  Text(user.email!, style: context.text.meta),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sign-out row
// ---------------------------------------------------------------------------

class _SignOutRow extends StatelessWidget {
  const _SignOutRow({required this.onConfirmed});

  final VoidCallback onConfirmed;

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Sign out?'),
          content: const Text(
            'You can sign back in from the welcome screen.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(
                foregroundColor: context.colors.danger,
              ),
              child: const Text('Sign out'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) onConfirmed();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(context.radius.r3),
      child: InkWell(
        key: const Key('sign-out-row'),
        onTap: () => _confirm(context),
        borderRadius: BorderRadius.circular(context.radius.r3),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x4,
            vertical: context.space.x3 + 2,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radius.r3),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.logout, size: 18, color: colors.danger),
              SizedBox(width: context.space.x2),
              Text(
                'Sign out',
                style: context.text.bodyStrong.copyWith(color: colors.danger),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading + error
// ---------------------------------------------------------------------------

/// Loading state — T-08: blocks mirror the identity row + body /
/// preferences / data cards rhythm so when the data resolves the layout
/// shifts as little as possible. Built from the lifted [Skeleton]
/// primitive.
class _ProfileSkeleton extends StatelessWidget {
  const _ProfileSkeleton();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final radius = context.radius;
    return ListView(
      padding: EdgeInsets.only(top: space.x2, bottom: space.x6),
      children: <Widget>[
        // Page title.
        Padding(
          padding: EdgeInsets.fromLTRB(space.x5, space.x2, space.x5, space.x3),
          child: const Skeleton(height: 28, width: 64),
        ),
        // Identity row — avatar + two text lines. The trailing "Edit"
        // skeleton was cut in QL-106 alongside the live row.
        Padding(
          padding: EdgeInsets.fromLTRB(space.x5, space.x1, space.x5, space.x4),
          child: Row(
            children: <Widget>[
              Skeleton(
                height: 64,
                width: 64,
                borderRadius: BorderRadius.circular(32),
              ),
              SizedBox(width: space.x3 + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Skeleton(height: 18, width: 160),
                    SizedBox(height: space.x1 + 2),
                    const Skeleton(height: 12, width: 200),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Three card silhouettes (Body, Preferences, Data). The Data
        // card collapses to ~76 px after QL-106 cut the Export row.
        for (final cardHeight in const <double>[260, 76, 76]) ...<Widget>[
          Padding(
            padding: EdgeInsets.fromLTRB(
              space.x5,
              0,
              space.x5,
              space.x3,
            ),
            child: Skeleton(
              height: cardHeight,
              borderRadius: BorderRadius.circular(radius.r3),
            ),
          ),
        ],
        SizedBox(height: space.x4),
        // Sign-out row silhouette.
        Padding(
          padding: EdgeInsets.symmetric(horizontal: space.x5),
          child: Skeleton(
            height: 52,
            borderRadius: BorderRadius.circular(radius.r3),
          ),
        ),
      ],
    );
  }
}

/// Error state — lifted [EmptyState] with a retry CTA that re-invalidates
/// `meProvider`. T-11 (errors inline, not modal) + T-13 (no spinner; the
/// empty-state composition is the legal home for the failure surface).
class _ProfileError extends StatelessWidget {
  const _ProfileError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: Icons.cloud_off,
        title: "Couldn't load profile",
        body: 'Pull to refresh or tap retry.',
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            label: 'Retry',
            onPressed: onRetry,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

String _sexLabel(Sex? sex) {
  switch (sex) {
    case Sex.male:
      return 'Male';
    case Sex.female:
      return 'Female';
    case Sex.other:
      return 'Other';
    case null:
      return 'Set';
  }
}

String _birthDateLabel(DateTime? date) {
  if (date == null) return 'Set';
  return DateFormat('MMM d, y').format(date);
}
