import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Globally addressable [FocusNode] for the search field, used by the
/// `/` keyboard shortcut on `expanded` (T-015).
///
/// The search field on Screen 02 attaches this node to its inner
/// `TextField`. The global shortcuts handler can then call
/// `ref.read(searchFieldFocusNodeProvider).requestFocus()` from any
/// route — when the search field is mounted, focus lands on it; when it
/// isn't mounted, the focus request is a no-op and the handler falls
/// back to pushing `/foods/search`.
///
/// A single shared node is safe because the search field is mounted at
/// most once at a time (either as a route, a dialog body, or not at
/// all). The provider disposes the node when the container is torn down.
final searchFieldFocusNodeProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'searchFieldFocus');
  ref.onDispose(node.dispose);
  return node;
});
