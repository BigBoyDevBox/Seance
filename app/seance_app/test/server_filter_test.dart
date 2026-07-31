import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_filter.dart';
import 'package:seance_core/seance_core.dart';

ServerConfig _server({
  required String label,
  String host = 'example.com',
  String username = 'ops',
  int port = 22,
  String? group,
}) => ServerConfig(
  id: label,
  label: label,
  host: host,
  port: port,
  username: username,
  authMethod: AuthMethod.privateKey,
  group: group,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  final servers = [
    _server(label: 'prod web', host: 'prod-web-01.eu-west.example.com'),
    _server(label: 'prod db', host: 'prod-db-01.us-east.example.com'),
    _server(
      label: 'lab',
      host: '10.0.0.5',
      username: 'root',
      port: 2222,
      group: 'Home lab',
    ),
  ];

  group('filterServers', () {
    test('an empty or whitespace query matches everything', () {
      for (final query in ['', '   ', '\t']) {
        expect(filterServers(servers, query).length, servers.length);
      }
    });

    test('matches the label, host, user, and port', () {
      expect(filterServers(servers, 'lab').single.label, 'lab');
      expect(filterServers(servers, 'us-east').single.label, 'prod db');
      expect(filterServers(servers, 'root').single.label, 'lab');
      expect(filterServers(servers, '2222').single.label, 'lab');
    });

    test('matches the group, so a section name narrows to that section', () {
      expect(filterServers(servers, 'home lab').single.label, 'lab');
      // And composes with the other terms like anything else in the haystack.
      expect(filterServers(servers, 'home root').single.label, 'lab');
    });

    test('a server with no group is unaffected by group matching', () {
      // "home" belongs to one server's group only; the ungrouped two must not
      // pick it up from an empty group reading as a wildcard.
      expect(filterServers(servers, 'home'), hasLength(1));
    });

    test('is case-insensitive', () {
      expect(filterServers(servers, 'PROD DB').single.label, 'prod db');
    });

    test('every term must match, in any order', () {
      expect(filterServers(servers, 'web eu').single.label, 'prod web');
      expect(filterServers(servers, 'eu web').single.label, 'prod web');
      // "prod" matches two hosts; adding a term that only one carries narrows.
      expect(filterServers(servers, 'prod').length, 2);
      expect(filterServers(servers, 'prod us-east').single.label, 'prod db');
      // A term no server carries excludes everything.
      expect(filterServers(servers, 'prod nonexistent'), isEmpty);
    });

    test('preserves the configured order', () {
      expect(
        filterServers(servers, 'example.com').map((s) => s.label).toList(),
        ['prod web', 'prod db'],
      );
    });
  });
}
