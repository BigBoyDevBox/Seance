import 'dart:developer' as developer;

import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import '../store/stores.dart';
import 'local_record_store.dart';
import 'sync_engine.dart';

const int _warningLogLevel = 900;
const String _recordKindDelimiter = ':';
const String _syncLoggerName = 'seance.sync';

/// Bridges the app's domain objects (server configs, pinned host keys, and —
/// opt-in — secrets) to the encrypted record layer and back, then drives a
/// [SyncEngine] round. Records are keyed by their domain id and disambiguated
/// by [RecordKind], so applying pulled records routes each to the right store.
///
/// Strategy is deliberately simple for a few dozen rarely-edited records:
/// re-collect everything from local stores, let the engine push/pull, and
/// re-apply. Server-side LWW makes unchanged pushes no-ops, so this converges
/// without precise dirty-tracking.
class SyncCoordinator {
  final ConfigStore configStore;
  final HostKeyStore hostKeyStore;
  final RecordCodec codec;
  final LocalRecordStore local;
  final String deviceId;

  /// Optional snippet store. When present, snippets sync like server configs.
  final SnippetStore? snippetStore;

  /// Opt-in secret syncing. When true, [secretVault] and [secretIds] must be
  /// provided so secrets can be sealed into records.
  final bool syncSecrets;
  final SecretVault? secretVault;

  SyncCoordinator({
    required this.configStore,
    required this.hostKeyStore,
    required this.codec,
    required this.local,
    required this.deviceId,
    this.snippetStore,
    this.syncSecrets = false,
    this.secretVault,
  });

  /// Encode current local state into the record store (as local edits).
  Future<void> collectLocal() async {
    for (final server in await configStore.listServers()) {
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: server.updatedAt,
        deviceId: deviceId,
        data: server.toJson(),
      )));
      if (syncSecrets && server.syncSecret && server.secretRef != null) {
        final secret = await secretVault?.getSecret(server.secretRef!);
        if (secret != null) {
          await local.putLocal(await codec.encrypt(DecryptedRecord(
            id: 'secret:${secret.id}',
            kind: RecordKind.secret,
            updatedAt: server.updatedAt,
            deviceId: deviceId,
            data: secret.toJson(),
          )));
        }
      }
    }
    for (final hk in await hostKeyStore.all()) {
      await local.putLocal(await codec.encrypt(DecryptedRecord(
        id: 'hostkey:${hk.locator}',
        kind: RecordKind.hostKey,
        updatedAt: hk.pinnedAt,
        deviceId: deviceId,
        data: hk.toJson(),
      )));
    }
    final snippets = snippetStore;
    if (snippets != null) {
      for (final s in await snippets.listSnippets()) {
        await local.putLocal(await codec.encrypt(DecryptedRecord(
          id: 'snippet:${s.id}',
          kind: RecordKind.snippet,
          updatedAt: s.updatedAt,
          deviceId: deviceId,
          data: s.toJson(),
        )));
      }
    }
  }

  /// Write every record in the local store back into the domain stores,
  /// honouring tombstones.
  Future<void> applyToStores() async {
    final skippedIds = <String>[];
    Object? firstError;
    StackTrace? firstStackTrace;

    for (final enc in await local.allRecords()) {
      try {
        final dec = await codec.decrypt(enc);

        // Tombstones have no encrypted kind. Preserve legacy bare-id server
        // deletion; prefixed records are owned by stores Séance lacks here.
        if (dec.deleted) {
          if (!dec.id.contains(_recordKindDelimiter)) {
            await configStore.deleteServer(dec.id);
          }
          continue;
        }

        switch (dec.kind) {
          case RecordKind.serverConfig:
            await configStore.putServer(ServerConfig.fromJson(dec.data));
          case RecordKind.hostKey:
            await hostKeyStore.put(HostKey.fromJson(dec.data));
          case RecordKind.secret:
            if (!syncSecrets || secretVault == null) continue;

            await secretVault!.putSecret(Secret.fromJson(dec.data));
          case RecordKind.snippet:
            final store = snippetStore;
            if (store == null) continue;

            await store.putSnippet(Snippet.fromJson(dec.data));
          case RecordKind.bookmark:
          case RecordKind.unknown:
            continue;
        }
      } catch (error, stackTrace) {
        skippedIds.add(enc.id);
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (skippedIds.isEmpty) return;

    developer.log(
      'Skipped synced records: ${skippedIds.join(', ')}',
      name: _syncLoggerName,
      level: _warningLogLevel,
      error: firstError,
      stackTrace: firstStackTrace,
    );
  }

  /// One full synchronization round.
  Future<SyncOutcome> run(SyncApi api) async {
    await collectLocal();
    final outcome = await SyncEngine(local).sync(api);
    await applyToStores();
    return outcome;
  }
}
