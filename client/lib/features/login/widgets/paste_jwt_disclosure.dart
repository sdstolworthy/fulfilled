import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/context_extensions.dart';
import '../login_controller.dart';

// TODO BE-008: remove or kill-switch once /auth/login lands. See
// backend_tickets_ledger.md. The disclosure stays in v1 as a mixed-
// deployment fallback (architect §3.6); PMgr can flip it off via a
// `bool kBE008Live` constant in a v1.1 ticket. This file is the
// removal trigger when the backend endpoint is live everywhere.
//
/// LOG-006 — BE-008 paste-JWT disclosure.
///
/// Renders only when `state.endpointMissing` is `true` (the controller
/// flips it on a 404 from `POST /auth/login`, architect §3.6 / §5.4).
/// Tapping "Use JWT mode" fires `controller.acceptJwtDisclosure()`
/// which sets `pastedJwtMode = true`; the next submit short-circuits
/// past `/auth/login` and treats the password as a literal bearer token
/// (LOG-005 phase 1).
class PasteJwtDisclosure extends ConsumerWidget {
  const PasteJwtDisclosure({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Perf (Flutter doc — "Control build() cost"): the disclosure only
    // reacts to the `endpointMissing` boolean; narrowing via `.select`
    // keeps this widget out of every keystroke's rebuild fan-out.
    final endpointMissing = ref.watch(
      loginControllerProvider.select((s) => s.endpointMissing),
    );
    if (!endpointMissing) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(loginControllerProvider.notifier);
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    return Container(
      margin: EdgeInsets.only(top: space.x4),
      padding: EdgeInsets.all(space.x4),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        border: Border.all(color: colors.accentLine),
        borderRadius: BorderRadius.circular(radius.r2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.info_outline,
                size: 20,
                color: colors.accent,
              ),
              SizedBox(width: space.x2),
              Expanded(
                child: Text(
                  "This server doesn't have a login endpoint yet. You can "
                  'paste a JWT directly as the password — it\'ll be sent as '
                  'a bearer without going through /auth/login.',
                  style: context.text.meta.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
          SizedBox(height: space.x2),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: controller.acceptJwtDisclosure,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                textStyle: context.text.bodyStrong,
              ),
              child: const Text('Use JWT mode'),
            ),
          ),
        ],
      ),
    );
  }
}
