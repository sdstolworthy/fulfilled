import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

// TODO BE-008: remove or kill-switch once /auth/login lands. See
// backend_tickets_ledger.md. The disclosure stays in v1 as a mixed-
// deployment fallback (architect §3.6); PMgr can flip it off via a
// `bool kBE008Live` constant in a v1.1 ticket. This file is the
// removal trigger when the backend endpoint is live everywhere.
//
/// LOG-006 — BE-008 paste-JWT disclosure.
///
/// Renders only when `endpointMissing` is `true` (the controller
/// flips its own `state.endpointMissing` on a 404 from
/// `POST /auth/login`, architect §3.6 / §5.4 — the container forwards
/// that flag in). Tapping "Use JWT mode" fires `onPasteJwt`, which the
/// container wires to `controller.acceptJwtDisclosure()`; that sets
/// `pastedJwtMode = true` and the next submit short-circuits past
/// `/auth/login`, treating the password as a literal bearer token
/// (LOG-005 phase 1).
///
/// **Pure presentation widget** — see `specs/testing_guide.md` §4.4.
/// This file imports nothing from `package:flutter_riverpod`.
class PasteJwtDisclosure extends StatelessWidget {
  const PasteJwtDisclosure({
    super.key,
    required this.endpointMissing,
    required this.onPasteJwt,
  });

  final bool endpointMissing;
  final VoidCallback onPasteJwt;

  @override
  Widget build(BuildContext context) {
    if (!endpointMissing) {
      return const SizedBox.shrink();
    }
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
              onPressed: onPasteJwt,
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
