import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/terminal_appearance.dart';

void main() {
  group('terminal appearance', () {
    test('defaults keep xterm\'s size but adopt the app font stack', () {
      final appearance = TerminalAppearance.resolve(
        AppSettings(),
        Brightness.dark,
      );
      expect(appearance.style.fontSize, kDefaultTerminalFontSize);
      expect(appearance.style.fontFamilyFallback, SeanceTheme.monoFallback);
      expect(appearance.style.fontFamily, SeanceTheme.monoFallback.first);
    });

    test('a chosen family leads, with the app stack behind it', () {
      final appearance = TerminalAppearance.resolve(
        AppSettings(terminalFontFamily: '  Iosevka  '),
        Brightness.dark,
      );
      expect(appearance.style.fontFamily, 'Iosevka');
      expect(appearance.style.fontFamilyFallback.first, 'Iosevka');
      // The bundled stack still backs it up for glyphs Iosevka lacks.
      expect(
        appearance.style.fontFamilyFallback.sublist(1),
        SeanceTheme.monoFallback,
      );
    });

    test('followApp tracks the ambient brightness', () {
      final settings = AppSettings(terminalPalette: TerminalPalette.followApp);
      expect(
        TerminalAppearance.resolve(settings, Brightness.dark).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        TerminalAppearance.resolve(settings, Brightness.light).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('a pinned palette ignores the ambient brightness', () {
      final dark = AppSettings(terminalPalette: TerminalPalette.alwaysDark);
      final light = AppSettings(terminalPalette: TerminalPalette.alwaysLight);
      expect(
        TerminalAppearance.resolve(dark, Brightness.light).theme.background,
        SeanceTerminalThemes.dark.background,
      );
      expect(
        TerminalAppearance.resolve(light, Brightness.dark).theme.background,
        SeanceTerminalThemes.light.background,
      );
    });

    test('brightness is derived from the resolved background', () {
      final dark = TerminalAppearance.resolve(
        AppSettings(terminalPalette: TerminalPalette.alwaysDark),
        Brightness.light,
      );
      final light = TerminalAppearance.resolve(
        AppSettings(terminalPalette: TerminalPalette.alwaysLight),
        Brightness.dark,
      );
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
    });

    test('font size is clamped when resolving', () {
      expect(
        TerminalAppearance.resolve(
          AppSettings(terminalFontSize: 900),
          Brightness.dark,
        ).style.fontSize,
        kMaxTerminalFontSize,
      );
      expect(
        TerminalAppearance.resolve(
          AppSettings(terminalFontSize: 1),
          Brightness.dark,
        ).style.fontSize,
        kMinTerminalFontSize,
      );
    });
  });

  group('appearance persistence', () {
    test('round-trips through JSON', () {
      final settings = AppSettings(
        terminalFontSize: 17,
        terminalFontFamily: 'Fira Code',
        terminalPalette: TerminalPalette.alwaysLight,
      );
      final restored = AppSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.terminalFontSize, 17);
      expect(restored.terminalFontFamily, 'Fira Code');
      expect(restored.terminalPalette, TerminalPalette.alwaysLight);
    });

    test('an out-of-range or unknown stored value falls back safely', () {
      final restored = AppSettings.fromJson({
        'terminalFontSize': 400,
        'terminalPalette': 'nonsense',
      });
      expect(restored.terminalFontSize, kMaxTerminalFontSize);
      expect(restored.terminalPalette, TerminalPalette.followApp);
    });

    test('a settings file written before this feature keeps the default', () {
      final restored = AppSettings.fromJson({'deviceId': 'abc'});
      expect(restored.terminalFontSize, kDefaultTerminalFontSize);
      expect(restored.terminalFontFamily, isEmpty);
      expect(restored.terminalPalette, TerminalPalette.followApp);
    });
  });
}
