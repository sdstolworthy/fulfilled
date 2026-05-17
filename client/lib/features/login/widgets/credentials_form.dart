import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/context_extensions.dart';
import '../login_controller.dart';

/// LOG-006 — username + password inputs.
///
/// Two `TextField`s stacked with `context.space.x4` spacing (architect
/// §5.2 — same density as the log-entry sheet). Autofill hints are wired
/// per the platform conventions (`username` / `password`) so iOS /
/// Android / desktop browsers can pre-fill from the OS-level password
/// manager.
///
/// Autofocus rule (architect §5.8 acceptance + ticket Scope): the
/// password field is autofocused when `state.username` is non-empty (the
/// re-login path — `auth_config.last_username` pre-seeds it); otherwise
/// the username field takes focus.
///
/// T-11 — `state.credentialsError` renders inline under the password
/// field in `context.colors.danger`. The username field gets no error
/// slot of its own: a 401 from `/auth/login` doesn't tell us which
/// field was wrong, so we anchor the message to the more-likely culprit.
class CredentialsForm extends ConsumerStatefulWidget {
  const CredentialsForm({super.key});

  @override
  ConsumerState<CredentialsForm> createState() => _CredentialsFormState();
}

class _CredentialsFormState extends ConsumerState<CredentialsForm> {
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late final FocusNode _usernameFocus;
  late final FocusNode _passwordFocus;
  late final bool _passwordAutofocus;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(loginControllerProvider);
    _usernameCtrl = TextEditingController(text: initial.username);
    _passwordCtrl = TextEditingController(text: initial.password);
    _usernameFocus = FocusNode();
    _passwordFocus = FocusNode();
    // Architect §5.8 — autofocus moves to password if username is
    // already pre-seeded (the re-login path); else to username.
    _passwordAutofocus = initial.username.isNotEmpty;
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
    final state = ref.watch(loginControllerProvider);
    final controller = ref.read(loginControllerProvider.notifier);
    final colors = context.colors;
    final space = context.space;

    final hasCredsError = state.credentialsError != null;
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
              enabled: !state.submitting,
              autofillHints: const <String>[AutofillHints.username],
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              onChanged: controller.setUsername,
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
              enabled: !state.submitting,
              autofillHints: const <String>[AutofillHints.password],
              textInputAction: TextInputAction.done,
              onChanged: controller.setPassword,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText: hasCredsError ? state.credentialsError : null,
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
