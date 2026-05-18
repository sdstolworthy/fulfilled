import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/context_extensions.dart';
import '../login_controller.dart';

/// LOG-006 — the server-URL input.
///
/// The PM-named helper-text-not-placeholder pattern (PM §5.4): the
/// example URL renders **under** the field via `decoration.helperText`,
/// never inside the `TextField` as a placeholder. On a URL error the
/// helper-text slot swaps to the typed error string (still under the
/// field) in `context.colors.danger` — that's the T-11 inline error.
///
/// On an `insecureScheme` error we render a `TextButton.icon` under
/// the field for the per-session "Allow HTTP" disclosure (architect
/// §5.6 — flag clears on next launch, the disclosure re-prompts).
///
/// Wrapped in `Semantics(label: 'Server URL')` per T-20 so screen
/// readers announce the field's purpose regardless of label/helper
/// rendering.
class ServerUrlField extends ConsumerStatefulWidget {
  const ServerUrlField({super.key});

  @override
  ConsumerState<ServerUrlField> createState() => _ServerUrlFieldState();
}

class _ServerUrlFieldState extends ConsumerState<ServerUrlField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    // Seed from the current login form state — when the controller is
    // first read, `state.url` already carries the Hive-pre-seeded URL
    // (or empty). On subsequent rebuilds we don't reset the text from
    // state — that would fight the user's keystrokes.
    final initial = ref.read(loginControllerProvider).url;
    _controller = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Perf (Flutter doc — "Control build() cost"): the URL field's
    // visible value is owned by `_controller`, so we only need to
    // react to two state slices — `submitting` (disables the field)
    // and `urlError` (drives the helper text + border color + HTTP
    // disclosure). Watching the whole state would rebuild on every
    // keystroke (the controller calls `setUrl(v)` → `state.url = v`),
    // even though the `TextField` already mirrors the keystroke
    // locally.
    final submitting = ref.watch(
      loginControllerProvider.select((s) => s.submitting),
    );
    final urlError = ref.watch(
      loginControllerProvider.select((s) => s.urlError),
    );
    final controller = ref.read(loginControllerProvider.notifier);
    final colors = context.colors;
    final space = context.space;

    final hasError = urlError != null;
    // PM §5.4 — helper text under the field by default; replaced with the
    // typed error string in danger on a URL error.
    final helperStyle = hasError
        ? context.text.meta.copyWith(color: colors.danger)
        : context.text.meta;
    final helperText = hasError
        ? urlError
        : 'e.g. https://fulfilled.mydomain.com';

    // Architect §5.6 — only render the per-session disclosure when the
    // current error is the HTTP-insecure variant. The URL error message
    // contains the literal word "HTTP" (see `url_normalize.dart`'s
    // `insecureScheme` message); we match on it rather than threading a
    // separate `kind` field through state.
    final showHttpDisclosure = hasError && urlError.contains('HTTP');

    return Semantics(
      label: 'Server URL',
      textField: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            // Re-login pre-seed: when the form already has a URL the
            // focus moves to the password (CredentialsForm handles its
            // own autofocus); the URL field is not autofocused here.
            enabled: !submitting,
            onChanged: controller.setUrl,
            decoration: InputDecoration(
              labelText: 'Server URL',
              helperText: helperText,
              helperStyle: helperStyle,
              // T-11 — render error inline via helperText (one slot,
              // styled-in-danger), not via Material's `errorText` which
              // would render a *second* row below.
              border: const OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: hasError ? colors.danger : colors.line,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: hasError ? colors.danger : colors.accent,
                ),
              ),
            ),
          ),
          if (showHttpDisclosure) ...<Widget>[
            SizedBox(height: space.x2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: controller.toggleAllowInsecure,
                icon: const Icon(Icons.lock_open_outlined, size: 18),
                label: const Text('Allow HTTP for this session'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  textStyle: context.text.bodyStrong,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
