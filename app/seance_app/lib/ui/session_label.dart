/// Naming for one terminal session, derived from what the remote shell tells
/// us: the OSC 7 working directory and the OSC 0/2 terminal title.
///
/// Kept free of Flutter so the rules can be unit-tested directly. Everything
/// here treats remote metadata as untrusted display text: control and
/// invisible formatting characters are stripped, whitespace is collapsed, and
/// truncation walks extended grapheme clusters so a multi-byte glyph is never
/// split in half.
library;

import 'package:characters/characters.dart' as characters;

const String _ellipsis = '…';

/// C0/C1 control characters, plus the invisible formatting characters a
/// hostile title could use to reorder or hide text: the zero-width space, the
/// left/right-to-left marks, the line and paragraph separators, the bidi
/// overrides and isolates, and the byte-order mark.
///
/// Deliberately keeps U+200C/U+200D (the zero-width non-joiner and joiner):
/// they cannot reorder or conceal anything on their own, and dropping them
/// would break Persian and Arabic text and shatter ZWJ emoji into their parts.
final RegExp _invisible = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200b\u200e\u200f\u2028\u2029'
  r'\u202a-\u202e\u2066-\u2069\ufeff]',
);

/// Make remote-supplied text safe to show in one line of chrome.
String sanitizeRemoteLabel(String value) => value
    .replaceAll(_invisible, ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Shorten [value] to [maxLength] grapheme clusters, ellipsising the *front*
/// so the distinguishing tail survives — the useful half of a path, or of a
/// title like `user@host: /very/long/path`, is at the end.
String shortenLabelHead(String value, int maxLength) {
  final graphemes = characters.Characters(value).toList(growable: false);
  if (graphemes.length <= maxLength) return value;
  final keep = maxLength - 1;
  if (keep <= 0) return _ellipsis;
  return '$_ellipsis${graphemes.skip(graphemes.length - keep).join()}';
}

/// The last segment of an absolute POSIX [path], or `/` for the root itself.
/// Returns null when [path] doesn't look like an absolute path.
String? posixBasename(String path) {
  if (!path.startsWith('/')) return null;
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '/' : segments.last;
}

/// The label shown on a session's tab chip.
///
/// Preference order, most to least informative:
/// 1. the working directory's last segment (OSC 7) — the server is already
///    identified by the selected row, so *where* on it is the useful part,
/// 2. the terminal title (OSC 0/2), which many Bash setups carry even when
///    they do not emit OSC 7,
/// 3. `Session N` — the previous behavior, when the shell reports nothing.
String sessionTabLabel({
  required int ordinal,
  String? workingDirectory,
  String? terminalTitle,
  int maxLength = 18,
}) {
  final cwd = workingDirectory == null
      ? null
      : posixBasename(sanitizeRemoteLabel(workingDirectory));
  if (cwd != null && cwd.isNotEmpty) return shortenLabelHead(cwd, maxLength);
  final title = terminalTitle == null ? '' : sanitizeRemoteLabel(terminalTitle);
  if (title.isNotEmpty) return shortenLabelHead(title, maxLength);
  return 'Session $ordinal';
}

/// The tooltip for a session's tab chip: everything the label had to drop.
String sessionTabTooltip({
  required int ordinal,
  required String target,
  String? workingDirectory,
  String? terminalTitle,
}) {
  final lines = <String>['Session $ordinal · $target'];
  final cwd = workingDirectory == null
      ? ''
      : sanitizeRemoteLabel(workingDirectory);
  if (cwd.isNotEmpty) lines.add(cwd);
  final title = terminalTitle == null ? '' : sanitizeRemoteLabel(terminalTitle);
  if (title.isNotEmpty && title != cwd) lines.add(title);
  return lines.join('\n');
}
