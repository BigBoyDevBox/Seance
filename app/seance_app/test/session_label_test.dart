import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/session_label.dart';

void main() {
  group('sessionTabLabel', () {
    test('falls back to the ordinal when the shell reports nothing', () {
      expect(sessionTabLabel(ordinal: 2), 'Session 2');
      expect(
        sessionTabLabel(ordinal: 1, workingDirectory: '', terminalTitle: ''),
        'Session 1',
      );
    });

    test('prefers the working directory basename', () {
      expect(
        sessionTabLabel(
          ordinal: 1,
          workingDirectory: '/var/log/nginx',
          terminalTitle: 'ops@web-01: /var/log/nginx',
        ),
        'nginx',
      );
    });

    test('names the root directory', () {
      expect(sessionTabLabel(ordinal: 1, workingDirectory: '/'), '/');
    });

    test('ignores a relative or malformed directory and uses the title', () {
      expect(
        sessionTabLabel(
          ordinal: 3,
          workingDirectory: 'var/log',
          terminalTitle: 'building',
        ),
        'building',
      );
    });

    test('uses the terminal title when there is no OSC 7 directory', () {
      expect(sessionTabLabel(ordinal: 1, terminalTitle: 'htop'), 'htop');
    });

    test('keeps the distinguishing tail when shortening', () {
      final label = sessionTabLabel(
        ordinal: 1,
        terminalTitle: 'deploy staging eu-west-1',
        maxLength: 10,
      );
      expect(label.length, 10);
      expect(label.startsWith('…'), isTrue);
      expect(label.endsWith('eu-west-1'), isTrue);
    });

    test('never splits a grapheme cluster', () {
      // Family emoji is a multi-codepoint ZWJ sequence.
      final label = sessionTabLabel(
        ordinal: 1,
        terminalTitle: 'aaaa👩‍👩‍👧‍👦',
        maxLength: 3,
      );
      // Two grapheme clusters kept plus the ellipsis — and the family emoji
      // survives whole rather than being cut mid-sequence.
      expect(label, '…a👩‍👩‍👧‍👦');
    });
  });

  group('remote text is untrusted', () {
    test('control characters and newlines cannot escape the label', () {
      expect(
        sanitizeRemoteLabel('onetwo\nthree\r\n  four'),
        'one two three four',
      );
    });

    test('bidi overrides and zero-width characters are stripped', () {
      expect(
        sanitizeRemoteLabel('safe\u202Egnahc\u200B\uFEFF'),
        'safe gnahc',
      );
    });

    test('a hostile title is sanitized before it reaches the tab', () {
      expect(
        sessionTabLabel(ordinal: 1, terminalTitle: 'ok\nrm -rf /'),
        'ok rm -rf /',
      );
    });
  });

  group('sessionTabTooltip', () {
    test('names the session, its target, and its reported location', () {
      expect(
        sessionTabTooltip(
          ordinal: 2,
          target: 'ops@web-01:22',
          workingDirectory: '/srv/app',
          terminalTitle: 'ops@web-01: /srv/app',
        ),
        'Session 2 · ops@web-01:22\n/srv/app\nops@web-01: /srv/app',
      );
    });

    test('omits what the shell has not reported', () {
      expect(
        sessionTabTooltip(ordinal: 1, target: 'root@db:2222'),
        'Session 1 · root@db:2222',
      );
    });

    test('does not repeat a title identical to the directory', () {
      expect(
        sessionTabTooltip(
          ordinal: 1,
          target: 'a@b:22',
          workingDirectory: '/srv',
          terminalTitle: '/srv',
        ),
        'Session 1 · a@b:22\n/srv',
      );
    });
  });
}
