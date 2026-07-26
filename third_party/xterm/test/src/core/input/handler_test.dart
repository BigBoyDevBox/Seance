import 'package:test/test.dart';
import 'package:xterm/src/core/input/keytab/keytab.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('defaultInputHandler', () {
    test('supports numpad enter', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      terminal.keyInput(TerminalKey.numpadEnter);
      expect(output, ['\r']);
    });
  });

  group('KeytabInputHandler', () {
    test('can insert modifier code', () {
      final handler = KeytabInputHandler(
        Keytab.parse(r'key Home +AnyMod : "\E[1;*H"'),
      );

      final terminal = Terminal(inputHandler: handler);

      late String output;

      terminal.onOutput = (data) {
        output = data;
      };

      terminal.keyInput(TerminalKey.home, ctrl: true);

      expect(output, '\x1b[1;5H');

      terminal.keyInput(TerminalKey.home, shift: true);

      expect(output, '\x1b[1;2H');
    });
  });

  group('AltInputHandler', () {
    // Regression: the terminal's platform decides whether Option/Alt is a
    // Meta key. On macOS it must NOT be — Option chords are how macOS
    // international layouts compose characters (~ is Option-N on Swiss
    // layouts), so the key event has to fall through unhandled for the IME
    // to see it. Consuming it sent ESC+letter to the remote instead, and
    // readline's meta bindings made the fallout visible (M-n opens the
    // non-incremental history search, whose prompt renders as ':').

    test('alt+letter is Meta on Linux, lowercase like xterm', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );
      final consumed = terminal.keyInput(TerminalKey.keyN, alt: true);
      expect(consumed, isTrue);
      expect(output, ['\x1bn']);
    });

    test('alt+letter falls through on macOS so the IME can compose', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.macos,
      );
      final consumed = terminal.keyInput(TerminalKey.keyN, alt: true);
      expect(consumed, isFalse);
      expect(output, isEmpty);
    });

    test('charInput mirrors the same platform gate', () {
      final output = <String>[];
      final linux = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );
      expect(linux.charInput(0x6e, alt: true), isTrue);
      expect(output, ['\x1bn']);

      final mac = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.macos,
      );
      expect(mac.charInput(0x6e, alt: true), isFalse);
      expect(output, hasLength(1));
    });
  });

  group('platform-gated keytab records', () {
    // Passing a real platform activates the keytab's Mac-gated records:
    // Option-Arrow becomes the native-Mac word jump (ESC f / ESC b, what
    // Terminal.app and iTerm2 send) instead of the ctrl-arrow encoding.
    // A deliberate behavior change, recorded in PATCHES.md patch 22.
    test('Option-Arrow word-jumps on macOS and iPadOS', () {
      for (final platform in [
        TerminalTargetPlatform.macos,
        TerminalTargetPlatform.ios,
      ]) {
        final output = <String>[];
        final terminal = Terminal(onOutput: output.add, platform: platform);
        terminal.keyInput(TerminalKey.arrowRight, alt: true);
        terminal.keyInput(TerminalKey.arrowLeft, alt: true);
        expect(output, ['\x1bf', '\x1bb'], reason: '$platform');
      }
    });

    test('Option-Arrow keeps the ctrl-arrow encoding elsewhere', () {
      final output = <String>[];
      final terminal = Terminal(
        onOutput: output.add,
        platform: TerminalTargetPlatform.linux,
      );
      terminal.keyInput(TerminalKey.arrowRight, alt: true);
      expect(output, ['\x1b[1;5C']);
    });
  });
}
