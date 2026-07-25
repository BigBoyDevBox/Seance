import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/chat_session.dart';
import 'package:seance_core/seance_core.dart';

class _EchoProvider implements LlmProvider {
  @override
  String get model => 'test';

  @override
  Future<List<String>> listModels() async => const [];

  @override
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  }) async => const CommandSuggestion(command: 'ls', explanation: '');

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async => const ChatTurn(text: 'ok');

  @override
  Stream<String> streamChat({required List<LlmMessage> messages}) async* {
    yield 'ok';
  }
}

void main() {
  group('ChatSession survives the widget that shows it', () {
    test('holds the transcript across turns', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      expect(chat.isEmpty, isTrue);

      chat.addUserMessage('what is eating the disk?');
      expect(chat.sending, isTrue);
      expect(chat.entries.single.fromUser, isTrue);

      chat.addReply(
        const ChatResult(
          reply: 'try du',
          stagedCommands: ['du -sh /var/*'],
          searchQueries: ['du usage'],
        ),
      );
      chat.finishSending();

      expect(chat.sending, isFalse);
      expect(chat.entries.length, 2);
      expect(chat.entries.last.staged, ['du -sh /var/*']);
      expect(chat.entries.last.searches, ['du usage']);
    });

    test('a failed turn records the error and still stops sending', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.addUserMessage('hello');
      chat.failed(StateError('provider unreachable'));
      chat.finishSending();
      expect(chat.error, contains('provider unreachable'));
      expect(chat.sending, isFalse);
      // The user's message stays on screen so the retry has context.
      expect(chat.entries.single.text, 'hello');
    });

    test('a new turn clears the previous error', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.addUserMessage('one');
      chat.failed(StateError('nope'));
      chat.finishSending();
      chat.addUserMessage('two');
      expect(chat.error, isNull);
    });

    test('notifies listeners on every transition', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      var notifications = 0;
      chat.addListener(() => notifications++);
      chat.addUserMessage('hi');
      chat.addReply(const ChatResult(reply: 'hello'));
      chat.finishSending();
      expect(notifications, 3);
    });

    test('entries are not mutable through the getter', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.addUserMessage('hi');
      expect(
        () => chat.entries.add(const ChatEntry(fromUser: false, text: 'x')),
        throwsUnsupportedError,
      );
    });
  });

  group('controller caching follows the provider settings', () {
    ChatController controller() =>
        ChatController(provider: _EchoProvider(), onPaste: (_) {});

    test('a controller is reused only for its own config version', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      expect(chat.controllerFor(0), isNull);

      final first = controller();
      chat.adoptController(first, 0);
      expect(chat.controllerFor(0), same(first));
      // Settings changed: the stale controller (old key/model) is not offered.
      expect(chat.controllerFor(1), isNull);

      final second = controller();
      chat.adoptController(second, 1);
      expect(chat.controllerFor(1), same(second));
    });

    test('reset clears the transcript and the error', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.adoptController(controller(), 0);
      chat.addUserMessage('hi');
      chat.failed(StateError('boom'));
      chat.reset();
      expect(chat.isEmpty, isTrue);
      expect(chat.error, isNull);
    });
  });
}
