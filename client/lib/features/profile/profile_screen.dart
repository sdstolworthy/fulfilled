import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/auth_token.dart';
import '../../domain/enums.dart';
import '../../domain/units/weight.dart';
import '../../domain/user.dart';
import '../../providers/food_providers.dart';
import '../../providers/profile_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/skeleton.dart';
import 'widgets/activity_level_picker.dart';
import 'widgets/birth_date_picker.dart';
import 'widgets/current_weight_sheet.dart';
import 'widgets/height_stepper_sheet.dart';
import 'widgets/settings_card.dart';
import 'widgets/settings_row.dart';
import 'widgets/sex_picker.dart';

/// Local debug flag — flip to `true` to inspect the error/loading
/// branches against the mock provider, then revert before committing.
/// T-013 — compile-time const so the dead branch is tree-shaken.
const bool _kDebugForceError = false;

/// Screen 08 — Profile & settings.
///
/// Layout (mirrors `specs/ui_mocks/screen_08_profile.html`):
/// 1. Identity row: avatar + name + email + Edit.
/// 2. **Body** card: sex, birth date, height (cm), current weight (kg),
///    activity level.
/// 3. **Preferences** card: Units (informational in v1 — PM Risk 4
///    defers the toggle to v2). The **Appearance row is intentionally
///    omitted** — PM Risk 5 removed it entirely from v1. Dark mode
///    ships with v2 alongside the token sweep.
/// 4. **Data** card: "My foods (N)" → `Routes.myFoodsPath`,
///    "Export data" → SnackBar "Coming soon".
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
          orElse: () => user.customFoodCount,
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
              onTap: () => showSexPicker(context, initial: user.sex),
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
                  : '${user.heightCm!.toBigInt()} cm',
              onTap: () => showHeightStepperSheet(
                context,
                initial: user.heightCm,
              ),
            ),
            SettingsRow(
              icon: Icons.monitor_weight_outlined,
              label: 'Current weight',
              value: user.currentWeightKg == null
                  ? 'Set'
                  : '${formatWeightKg(user.currentWeightKg!)} kg',
              onTap: () => showCurrentWeightSheet(
                context,
                initial: user.currentWeightKg,
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
              ),
            ),
          ],
        ),

        // Preferences section. PM Risk 5: Appearance row is **NOT**
        // rendered, not even disabled. v1 ships without the toggle.
        SettingsCard(
          title: 'Preferences',
          rows: <Widget>[
            // Units row is informational in v1 (PM Risk 4 defers the
            // toggle). Pass `onTap: null` so the chevron drops + the
            // row is non-interactive — see `SettingsRow` docstring.
            const SettingsRow(
              key: Key('row-units'),
              icon: Icons.public,
              label: 'Units',
              value: 'kg, cm, kcal, g',
              semanticsLabel:
                  'Units: kilograms, centimeters, kilocalories, grams. '
                  'Unit preferences arrive in a later release.',
            ),
          ],
        ),

        // Data section.
        SettingsCard(
          title: 'Data',
          rows: <Widget>[
            SettingsRow(
              icon: Icons.bookmark_outline,
              label: 'My foods',
              value: '$customFoodCount',
              onTap: () => context.push(Routes.myFoodsPath),
            ),
            SettingsRow(
              icon: Icons.ios_share_outlined,
              label: 'Export data',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Coming soon')),
                );
              },
            ),
          ],
        ),

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
        Center(
          child: Text(
            'Fulfilled · v0.1.0 (dev)',
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
          TextButton(
            onPressed: () {
              // The Edit affordance reuses the identity-tap entry
              // point — opens the same display-name + email editor.
              // v1 doesn't have a dedicated identity editor; the
              // designer didn't mock one. Surface a coming-soon hint
              // rather than ship a half-built form.
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon')),
              );
            },
            style: TextButton.styleFrom(
              foregroundColor: colors.accent,
              textStyle: context.text.bodyStrong,
            ),
            child: const Text('Edit'),
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
        // Identity row — avatar + two text lines + Edit affordance.
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
              SizedBox(width: space.x3),
              const Skeleton(height: 18, width: 36),
            ],
          ),
        ),
        // Three card silhouettes (Body, Preferences, Data).
        for (final cardHeight in const <double>[260, 76, 116]) ...<Widget>[
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
