import 'dart:io';

import 'package:flutter/foundation.dart';

/// What [SandboxMigration.run] did.
enum SandboxMigrationOutcome {
  /// This install already has data where the app now looks. Nothing to do —
  /// the overwhelmingly common case, on every platform and every launch after
  /// the first unsandboxed one.
  notNeeded,

  /// Nothing was left behind by a sandboxed build: a fresh install, or any
  /// platform that never had a container.
  noLegacyData,

  /// A sandboxed build's data was copied out of its container.
  migrated,

  /// The copy was attempted and failed. The app starts empty rather than
  /// half-migrated, and the container is untouched, so the next launch retries.
  failed,
}

/// Moves an install's data out of the macOS App Sandbox container it used to
/// live in.
///
/// Dropping `com.apple.security.app-sandbox` relocates `NSHomeDirectory()`,
/// which relocates everything `getApplicationSupportDirectory()` returns:
///
/// ```text
/// ~/Library/Containers/<bundle id>/Data/Library/Application Support/<bundle id>   (sandboxed)
/// ~/Library/Application Support/<bundle id>                                       (not)
/// ```
///
/// Without this an existing install launches looking like a fresh one — no
/// servers, no snippets, no sync, and a newly minted `deviceId` that re-enters
/// sync as a stranger. Nothing would be lost, but nothing would be reachable
/// either.
///
/// The copy is staged and then moved into place, so an interrupted run leaves
/// the destination empty rather than half-populated: a partial copy that
/// looked "already in use" would strand the rest in the container forever.
/// The container is copied, never moved — if anything here is wrong, the
/// original is still sitting where a sandboxed build would find it.
class SandboxMigration {
  /// Where the app reads its data now.
  final Directory support;

  /// Where a sandboxed build of this app would have kept it.
  final Directory legacySupport;

  /// Scratch space inside [support]; never a destination the app reads.
  final Directory staging;

  SandboxMigration({required this.support, required this.legacySupport})
    : staging = Directory('${support.path}/$stagingName');

  static const String stagingName = '.seance-sandbox-migration';

  /// The migration implied by an application-support directory, or null when
  /// this platform has no container to migrate from.
  ///
  /// The bundle identifier is read off [support]'s own last path segment
  /// rather than a platform channel or a constant: `path_provider` builds that
  /// directory as `…/Application Support/<bundle id>`, so it is already the
  /// answer, and a hard-coded copy could silently drift from the Xcode config.
  static SandboxMigration? forSupportDirectory(
    Directory support, {
    String? home,
    bool? isMacOS,
  }) {
    if (!(isMacOS ?? Platform.isMacOS)) return null;
    final realHome = home ?? Platform.environment['HOME'] ?? '';
    if (realHome.isEmpty) return null;
    final bundleId = support.path.split(Platform.pathSeparator).last;
    if (bundleId.isEmpty) return null;
    return SandboxMigration(
      support: support,
      legacySupport: Directory(
        '$realHome/Library/Containers/$bundleId/Data'
        '/Library/Application Support/$bundleId',
      ),
    );
  }

  /// The error from a [SandboxMigrationOutcome.failed] run, for the notice the
  /// app shows. Null otherwise.
  Object? get error => _error;
  Object? _error;

  Future<SandboxMigrationOutcome> run() async {
    try {
      // A leftover staging directory means a previous run died mid-copy. Its
      // contents are a partial duplicate of the container, so they are dropped
      // rather than merged.
      if (await staging.exists()) await staging.delete(recursive: true);

      if (await _hasData(support)) return SandboxMigrationOutcome.notNeeded;
      if (!await _hasData(legacySupport)) {
        return SandboxMigrationOutcome.noLegacyData;
      }

      await staging.create(recursive: true);
      await _copyInto(legacySupport, staging);
      // Move rather than copy for this half: same volume, so each entry lands
      // whole, and the destination is only ever visibly populated by entries
      // that finished copying.
      await for (final entry in staging.list(followLinks: false)) {
        final name = entry.path.split(Platform.pathSeparator).last;
        await entry.rename('${support.path}/$name');
      }
      await staging.delete(recursive: true);
      return SandboxMigrationOutcome.migrated;
    } catch (error, stackTrace) {
      _error = error;
      debugPrint('Sandbox-container migration failed: $error\n$stackTrace');
      // Leave nothing half-done behind; the container still holds everything.
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {
        // Best effort — a stale staging directory is dropped on the next run.
      }
      return SandboxMigrationOutcome.failed;
    }
  }

  /// Whether [directory] holds anything the app would care about. The staging
  /// directory is this migration's own scratch space, so it never counts.
  static Future<bool> _hasData(Directory directory) async {
    if (!await directory.exists()) return false;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry.path.split(Platform.pathSeparator).last != stagingName) {
        return true;
      }
    }
    return false;
  }

  static Future<void> _copyInto(Directory from, Directory to) async {
    await for (final entry in from.list(followLinks: false)) {
      final name = entry.path.split(Platform.pathSeparator).last;
      final target = '${to.path}/$name';
      if (entry is Directory) {
        await Directory(target).create(recursive: true);
        await _copyInto(entry, Directory(target));
      } else if (entry is File) {
        await entry.copy(target);
      }
      // Links are skipped deliberately: nothing in this tree creates one, and
      // following an unexpected link would copy from outside the container.
    }
  }
}
