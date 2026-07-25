import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

ServerConfig _config() => ServerConfig(
  id: 'server',
  label: 'server',
  host: 'example.com',
  port: 22,
  username: 'ops',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('connection log notifications stay local to the session', () {
    test('trace lines repaint only the log, never the app', () {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final session = TerminalSession(
        id: 'a',
        serverId: 'server',
        config: _config(),
        engine: engine,
      );
      addTearDown(session.logNotifier.dispose);

      var logRepaints = 0;
      session.logNotifier.addListener(() => logRepaints++);

      // A handshake's worth of dartssh2 trace lines.
      for (var i = 0; i < 250; i++) {
        session.log.add('packet $i');
      }
      expect(logRepaints, 250);
      expect(session.log.lines, isNotEmpty);
    });

    test('a frozen log stops notifying once the session is up', () {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final session = TerminalSession(
        id: 'a',
        serverId: 'server',
        config: _config(),
        engine: engine,
      );
      addTearDown(session.logNotifier.dispose);

      var logRepaints = 0;
      session.logNotifier.addListener(() => logRepaints++);
      session.log.add('connecting');
      session.log.freeze();
      for (var i = 0; i < 100; i++) {
        session.log.add('post-connect packet $i');
      }
      expect(logRepaints, 1);
    });
  });

  group('recentText reads only the tail of the scrollback', () {
    XtermTerminalEngine feed(int lines) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final buffer = StringBuffer();
      for (var i = 0; i < lines; i++) {
        buffer.write('line $i\r\n');
      }
      engine.feed(Uint8List.fromList(utf8.encode(buffer.toString())));
      return engine;
    }

    test('returns the last N lines of a long scrollback', () {
      final engine = feed(2000);
      final text = engine.recentText(maxLines: 10);
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      expect(lines.length, lessThanOrEqualTo(10));
      expect(lines.last, 'line 1999');
      // Nothing from the far past leaks into a bounded read.
      expect(text.contains('line 0\n'), isFalse);
      expect(text.contains('line 500'), isFalse);
    });

    test('reaches into scrollback, not just the visible viewport', () {
      final engine = feed(2000);
      // Buffer.height is lines.length — the whole buffer, scrollback included
      // (Buffer.viewHeight is the viewport). A 200-line request must
      // therefore return far more than one screen.
      final lines = engine
          .recentText(maxLines: 200)
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, greaterThan(engine.terminal.viewHeight));
      expect(lines.length, greaterThan(100));
      expect(lines.last, 'line 1999');
    });

    test('a short session returns everything it has', () {
      final engine = feed(3);
      final text = engine.recentText(maxLines: 200);
      for (final expected in ['line 0', 'line 1', 'line 2']) {
        expect(text, contains(expected));
      }
    });

    test('degenerate bounds are handled', () {
      final engine = feed(5);
      expect(engine.recentText(maxLines: 0), isEmpty);
      expect(engine.recentText(maxLines: -1), isEmpty);
    });
  });
}
