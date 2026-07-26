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

      final turn = chat.addUserMessage('what is eating the disk?');
      expect(chat.sending, isTrue);
      expect(chat.entries.single.fromUser, isTrue);

      chat.addReply(
        turn,
        const ChatResult(
          reply: 'try du',
          stagedCommands: ['du -sh /var/*'],
          searchQueries: ['du usage'],
        ),
      );
      chat.finishSending(turn);

      expect(chat.sending, isFalse);
      expect(chat.entries.length, 2);
      expect(chat.entries.last.staged, ['du -sh /var/*']);
      expect(chat.entries.last.searches, ['du usage']);
    });

    test('a failed turn records the error and still stops sending', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('hello');
      chat.failed(turn, StateError('provider unreachable'));
      chat.finishSending(turn);
      expect(chat.error, contains('provider unreachable'));
      expect(chat.sending, isFalse);
      // The user's message stays on screen so the retry has context.
      expect(chat.entries.single.text, 'hello');
    });

    test('a new turn clears the previous error', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('one');
      chat.failed(turn, StateError('nope'));
      chat.finishSending(turn);
      chat.addUserMessage('two');
      expect(chat.error, isNull);
    });

    test('notifies listeners on every transition', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      var notifications = 0;
      chat.addListener(() => notifications++);
      final turn = chat.addUserMessage('hi');
      chat.addReply(turn, const ChatResult(reply: 'hello'));
      chat.finishSending(turn);
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
      final turn = chat.addUserMessage('hi');
      chat.failed(turn, StateError('boom'));
      chat.reset();
      expect(chat.isEmpty, isTrue);
      expect(chat.error, isNull);
    });

    test('reset mid-flight clears sending and orphans the turn', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('slow question');
      expect(chat.sending, isTrue);

      chat.reset();
      expect(chat.sending, isFalse, reason: 'the composer must not stay stuck');
      expect(chat.isEmpty, isTrue);

      // The in-flight turn resolves after the reset: its answer belongs to a
      // conversation the user has already ended.
      chat.addReply(turn, const ChatResult(reply: 'too late'));
      chat.failed(turn, StateError('also too late'));
      chat.finishSending(turn);
      expect(chat.isEmpty, isTrue);
      expect(chat.error, isNull);

      // A turn started after the reset still works.
      final next = chat.addUserMessage('new question');
      chat.addReply(next, const ChatResult(reply: 'answer'));
      chat.finishSending(next);
      expect(chat.entries.length, 2);
      expect(chat.sending, isFalse);
    });
  });
}
