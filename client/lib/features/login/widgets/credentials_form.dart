import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// LOG-006 — username + password inputs.
///
/// Two `TextField`s stacked with `context.space.x4` spacing (architect
/// §5.2 — same density as the log-entry sheet). Autofill hints are wired
/// per the platform conventions (`username` / `password`) so iOS /
/// Android / desktop browsers can pre-fill from the OS-level password
/// manager.
///
/// Autofocus rule (architect §5.8 acceptance + ticket Scope): the
/// password field is autofocused when `initialUsername` is non-empty
/// (the re-login path — `auth_config.last_username` pre-seeds it);
/// otherwise the username field takes focus.
///
/// T-11 — `credentialsError` renders inline under the password
/// field in `context.colors.danger`. The username field gets no error
/// slot of its own: a 401 from `/auth/login` doesn't tell us which
/// field was wrong, so we anchor the message to the more-likely culprit.
///
/// **Pure presentation widget** — all inputs arrive via constructor
/// parameters (see `specs/testing_guide.md` §4.4). The container
/// (`LoginScreen`) reads `loginControllerProvider`, extracts the
/// slices, and wires the callbacks (including the password-Enter
/// submit). This file imports nothing from `package:flutter_riverpod`.
///
/// **Inputs.**
/// - `initialUsername` — used to seed the local username
///   `TextEditingController` once in `initState` AND to decide which
///   field gets the autofocus (non-empty → password, empty → username).
/// - `submitting` — disables both fields (T-08).
/// - `credentialsError` — non-null drives the helper-text + border on
///   the password field into the danger style.
/// - `onUsernameChanged`, `onPasswordChanged` — fired on every
///   keystroke.
/// - `onSubmit` — invoked when the user presses Enter on the password
///   field. Container handles the submit + route-to-/today flow so the
///   leaf stays free of router and provider imports.
class CredentialsForm extends StatefulWidget {
  const CredentialsForm({
    super.key,
    required this.initialUsername,
    required this.submitting,
    required this.credentialsError,
    required this.onUsernameChanged,
    required this.onPasswordChanged,
    required this.onSubmit,
  });

  final String initialUsername;
  final bool submitting;
  final String? credentialsError;
  final ValueChanged<String> onUsernameChanged;
  final ValueChanged<String> onPasswordChanged;
  final VoidCallback onSubmit;

  @override
  State<CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends State<CredentialsForm> {
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late final FocusNode _usernameFocus;
  late final FocusNode _passwordFocus;
  late final bool _passwordAutofocus;

  @override
  void initState() {
    super.initState();
    _usernameCtrl = TextEditingController(text: widget.initialUsername);
    _passwordCtrl = TextEditingController();
    _usernameFocus = FocusNode();
    _passwordFocus = FocusNode();
    // Architect §5.8 — autofocus moves to password if username is
    // already pre-seeded (the re-login path); else to username.
    _passwordAutofocus = widget.initialUsername.isNotEmpty;
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final credentialsError = widget.credentialsError;

    final hasCredsError = credentialsError != null;
    final passwordHelperStyle = hasCredsError
        ? context.text.meta.copyWith(color: colors.danger)
        : context.text.meta;

    // Wrap in `AutofillGroup` so the OS sees username + password as a
    // single credential set — the password manager prompts to save the
    // pair after a successful submit.
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            label: 'Username',
            textField: true,
            child: TextField(
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              autofocus: !_passwordAutofocus,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !widget.submitting,
              autofillHints: const <String>[AutofillHints.username],
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              onChanged: widget.onUsernameChanged,
              onSubmitted: (_) => _passwordFocus.requestFocus(),
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(height: space.x4),
          Semantics(
            label: 'Password',
            textField: true,
            child: TextField(
              controller: _passwordCtrl,
              focusNode: _passwordFocus,
              autofocus: _passwordAutofocus,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !widget.submitting,
              autofillHints: const <String>[AutofillHints.password],
              textInputAction: TextInputAction.done,
              onChanged: widget.onPasswordChanged,
              // Enter on the password field submits the form, matching
              // the LoginButton's tap path (controller.submit + go to
              // /today on success). Without this the keyboard's done
              // affordance just dismisses focus and the user has to
              // scroll/tap to actually sign in. `submitting` short-
              // circuits a double-submit if Enter fires twice while
              // the credential POST is already in flight.
              onSubmitted: (_) {
                if (widget.submitting) return;
                widget.onSubmit();
              },
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: hasCredsError ? credentialsError : null,
                helperStyle: passwordHelperStyle,
                border: const OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: hasCredsError ? colors.danger : colors.line,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: hasCredsError ? colors.danger : colors.accent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
