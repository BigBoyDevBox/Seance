import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_settings.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seance-settings-');
    file = File('${dir.path}/settings.json');
  });
  tearDown(() => dir.delete(recursive: true));

  Future<AppSettings> load() => SettingsStore(file).load();

  test('a missing file starts from defaults without claiming a recovery', () async {
    final store = SettingsStore(file);
    final settings = await store.load();
    expect(settings.deviceId, isEmpty);
    expect(store.recoveredFromCorruptFile, isFalse);
    expect(File('${file.path}.corrupt').existsSync(), isFalse);
  });

  test('a good file round-trips and reports no recovery', () async {
    final original = AppSettings(
      deviceId: 'device-1',
      syncBaseUrl: 'https://sync.example.com',
      syncUsername: 'ops',
    );
    await file.writeAsString(jsonEncode(original.toJson()));
    final store = SettingsStore(file);
    final settings = await store.load();
    expect(store.recoveredFromCorruptFile, isFalse);
    expect(settings.deviceId, 'device-1');
    expect(settings.syncBaseUrl, 'https://sync.example.com');
  });

  group('an unreadable file', () {
    test('is moved aside instead of being overwritten', () async {
      await file.writeAsString('{"deviceId": "device-1", trunca');
      final store = SettingsStore(file);
      await store.load();

      expect(store.recoveredFromCorruptFile, isTrue);
      final quarantined = File('${file.path}.corrupt');
      expect(quarantined.existsSync(), isTrue);
      // The original bytes survive for the user to inspect or repair.
      expect(quarantined.readAsStringSync(), '{"deviceId": "device-1", trunca');
    });

    test('keeps the device id, which sync conflict resolution depends on',
        () async {
      await file.writeAsString(
        '{"deviceId":"device-1","syncBaseUrl":"https://sync.example.com",'
        '"syncUsername":"ops","editorRegistry":{ truncated',
      );
      final settings = await load();
      expect(settings.deviceId, 'device-1');
      expect(settings.syncBaseUrl, 'https://sync.example.com');
      expect(settings.syncUsername, 'ops');
    });

    test('the salvage is written back, so it survives the next launch',
        () async {
      await file.writeAsString('{"deviceId":"device-1", truncated');
      await SettingsStore(file).load();

      // A second store, as a fresh launch would build it: the quarantined
      // file is gone, so only a persisted salvage can carry the id across.
      final relaunch = SettingsStore(file);
      final settings = await relaunch.load();
      expect(relaunch.recoveredFromCorruptFile, isFalse);
      expect(settings.deviceId, 'device-1');
    });

    test('salvages nothing it cannot find, and stays on defaults', () async {
      await file.writeAsString('not json at all');
      final settings = await load();
      expect(settings.deviceId, isEmpty);
      expect(settings.syncBaseUrl, isNull);
      expect(settings.redactionEnabled, isTrue);
      expect(settings.autoSync, isTrue);
    });

    test('a JSON document that is not an object is treated as corrupt',
        () async {
      await file.writeAsString('["not", "an", "object"]');
      final store = SettingsStore(file);
      await store.load();
      expect(store.recoveredFromCorruptFile, isTrue);
      expect(File('${file.path}.corrupt').existsSync(), isTrue);
    });
  });

  group('salvageSettings', () {
    test('ignores empty values', () {
      final settings = salvageSettings('{"deviceId":"","syncUsername":""}');
      expect(settings.deviceId, isEmpty);
      expect(settings.syncUsername, isNull);
    });

    test('handles a null body', () {
      expect(salvageSettings(null).deviceId, isEmpty);
    });

    test('does not pick up a different key that ends in the same name', () {
      // "otherDeviceId" must not be mistaken for "deviceId".
      final settings = salvageSettings('{"otherDeviceId":"nope"} truncated');
      expect(settings.deviceId, isEmpty);
    });
  });
}
