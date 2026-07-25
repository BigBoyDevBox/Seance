import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

/// One turn in the assistant transcript, as the sidebar renders it.
@immutable
class ChatEntry {
  final bool fromUser;
  final String text;

  /// Commands the assistant placed in the prompt this turn.
  final List<String> staged;

  /// Web searches it ran this turn.
  final List<String> searches;

  const ChatEntry({
    required this.fromUser,
    required this.text,
    this.staged = const [],
    this.searches = const [],
  });
}

/// The assistant conversation, held outside the widget tree.
///
/// The sidebar used to own both the transcript and the [ChatController] (which
/// carries the provider-side history). On narrow layouts the sidebar lives in a
/// `Drawer`, so **closing the drawer destroyed the conversation** — and on a
/// phone the drawer is the only way to reach the assistant, which made it
/// effectively single-turn there. Crossing the wide/narrow breakpoint on the
/// desktop did the same thing.
///
/// Holding it here means the drawer is a view onto state that outlives it. The
/// conversation is deliberately in memory only: terminal context and assistant
/// replies are exactly the kind of thing that should not silently accumulate on
/// disk, so a relaunch still starts clean.
class ChatSession extends ChangeNotifier {
  final List<ChatEntry> _entries = [];
  ChatController? _controller;

  /// The `llmConfigVersion` [_controller] was built with, so a provider change
  /// in Settings rebuilds it instead of reusing a stale key or model.
  int? _controllerVersion;

  bool _sending = false;
  String? _error;

  List<ChatEntry> get entries => List.unmodifiable(_entries);
  bool get sending => _sending;
  String? get error => _error;
  bool get isEmpty => _entries.isEmpty;

  /// The live controller, or null when one has not been built yet or the
  /// provider settings have changed since it was.
  ChatController? controllerFor(int configVersion) =>
      _controllerVersion == configVersion ? _controller : null;

  /// Adopt a freshly built controller for [configVersion], replaying the
  /// transcript so a provider change mid-conversation does not lose context.
  void adoptController(ChatController controller, int configVersion) {
    _controller = controller;
    _controllerVersion = configVersion;
  }

  void addUserMessage(String text) {
    _entries.add(ChatEntry(fromUser: true, text: text));
    _error = null;
    _sending = true;
    notifyListeners();
  }

  void addReply(ChatResult result) {
    _entries.add(
      ChatEntry(
        fromUser: false,
        text: result.reply,
        staged: result.stagedCommands,
        searches: result.searchQueries,
      ),
    );
    notifyListeners();
  }

  void failed(Object error) {
    _error = error.toString();
    notifyListeners();
  }

  void finishSending() {
    _sending = false;
    notifyListeners();
  }

  /// Start a new conversation: clears the transcript and the provider history.
  void reset() {
    _entries.clear();
    _error = null;
    _controller?.reset();
    notifyListeners();
  }
}
