import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

/// The session-side half of command naming: the engine's `activeCommand` is
/// mirrored into [TerminalSession.metadata] only after
/// [TerminalSession.commandRevealDelay], so quick commands never repaint the
/// tab strip, and it is redacted on the way through.
///
/// `testWidgets` rather than `test` for the fake clock: the reveal timer is
/// driven by `tester.pump(duration)` instead of real waiting.
void main() {
  const integrated =
      '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
      '\x1b]133;A\x07\x1b]133;B\x07';

  ServerConfig config() => ServerConfig(
    id: 'server',
    label: 'Server',
    host: 'example.com',
    port: 22,
    username: 'user',
    authMethod: AuthMethod.password,
    createdAt: 0,
    updatedAt: 0,
  );

  (XtermTerminalEngine, TerminalSession) session() {
    final engine = XtermTerminalEngine();
    final tab = TerminalSession(
      id: 'tab',
      serverId: 'server',
      config: config(),
      engine: engine,
      connecting: false,
    );
    engine.feed(Uint8List.fromList(utf8.encode(integrated)));
    return (engine, tab);
  }

  void type(XtermTerminalEngine engine, String command) {
    engine.injectInput(command);
    engine.sendKey([0x0d]);
  }

  testWidgets('a command becomes the tab name only after the reveal delay', (
    tester,
  ) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    type(engine, 'htop');
    expect(tab.metadata.value.runningCommand, isNull);

    await tester.pump(TerminalSession.commandRevealDelay);
    expect(tab.metadata.value.runningCommand, 'htop');
  });

  testWidgets('a quick command never surfaces', (tester) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    type(engine, 'ls');
    engine.feed(Uint8List.fromList(utf8.encode('\x1b]133;D;0\x07')));

    await tester.pump(TerminalSession.commandRevealDelay * 2);
    expect(tab.metadata.value.runningCommand, isNull);
  });

  testWidgets('finishing clears the name immediately, no delay', (
    tester,
  ) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    type(engine, 'sleep 60');
    await tester.pump(TerminalSession.commandRevealDelay);
    expect(tab.metadata.value.runningCommand, 'sleep 60');

    engine.feed(Uint8List.fromList(utf8.encode('\x1b]133;D;0\x07')));
    expect(tab.metadata.value.runningCommand, isNull);
  });

  testWidgets('a replacement command restarts the delay', (tester) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    type(engine, 'make');
    await tester.pump(TerminalSession.commandRevealDelay ~/ 2);
    // make finishes and a new command starts before the first reveal fired.
    engine.feed(
      Uint8List.fromList(
        utf8.encode('\x1b]133;D;0\x07\x1b]133;A\x07\x1b]133;B\x07'),
      ),
    );
    type(engine, 'make install');

    // The original reveal point passes: the dead command must not surface.
    await tester.pump(TerminalSession.commandRevealDelay ~/ 2);
    expect(tab.metadata.value.runningCommand, isNull);

    await tester.pump(TerminalSession.commandRevealDelay);
    expect(tab.metadata.value.runningCommand, 'make install');
  });

  testWidgets('secrets are redacted before they reach the chrome', (
    tester,
  ) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    type(engine, 'export API_TOKEN=hunter2hunter2');
    await tester.pump(TerminalSession.commandRevealDelay);

    final shown = tab.metadata.value.runningCommand;
    expect(shown, isNotNull);
    expect(shown, isNot(contains('hunter2')));
  });

  testWidgets('the command does not blank the directory or title', (
    tester,
  ) async {
    final (engine, tab) = session();
    addTearDown(tab.dispose);
    addTearDown(engine.dispose);

    engine.feed(
      Uint8List.fromList(utf8.encode('\x1b]7;file://host/srv/app\x07')),
    );
    type(engine, 'htop');
    await tester.pump(TerminalSession.commandRevealDelay);

    expect(tab.metadata.value.runningCommand, 'htop');
    expect(tab.metadata.value.workingDirectory, '/srv/app');

    engine.feed(Uint8List.fromList(utf8.encode('\x1b]133;D;0\x07')));
    expect(tab.metadata.value.runningCommand, isNull);
    expect(tab.metadata.value.workingDirectory, '/srv/app');
  });

  test('a reconnect carries the place but not the command', () {
    const before = SessionMetadata(
      workingDirectory: '/srv/app',
      terminalTitle: 'ops@web: /srv/app',
      runningCommand: 'tail -f app.log',
    );
    final carried = before.withoutRunningCommand;
    expect(carried.workingDirectory, '/srv/app');
    expect(carried.terminalTitle, 'ops@web: /srv/app');
    expect(carried.runningCommand, isNull);
  });

  testWidgets('disposing the session cancels a pending reveal', (tester) async {
    final (engine, tab) = session();
    addTearDown(engine.dispose);

    type(engine, 'htop');
    tab.dispose();
    // The timer was cancelled with the session; advancing time must not
    // write into the disposed metadata notifier.
    await tester.pump(TerminalSession.commandRevealDelay * 2);
    expect(tester.takeException(), isNull);
  });
}
