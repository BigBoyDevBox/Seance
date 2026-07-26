/// Filtering for the server list.
///
/// Kept free of Flutter so the matching rules can be unit-tested directly.
/// A query is split on whitespace and **every** term must match somewhere in
/// the server — so `web eu` finds `prod-web-01.eu-west` without the user
/// having to remember which order the parts appear in, and `root 2222` finds
/// the one host reached as root on a non-standard port.
library;

import 'package:seance_core/seance_core.dart';

/// The searchable text of one server: label, user, host, and port.
String serverSearchHaystack(ServerConfig server) =>
    '${server.label} ${server.username}@${server.host}:${server.port}'
        .toLowerCase();

/// Whether [server] matches [query]. An empty or whitespace-only query matches
/// everything, so the list is never mysteriously empty.
bool serverMatchesQuery(ServerConfig server, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((t) => t.isEmpty);
  if (terms.isEmpty) return true;
  final haystack = serverSearchHaystack(server);
  return terms.every(haystack.contains);
}

/// [servers] filtered by [query], preserving the configured order.
List<ServerConfig> filterServers(List<ServerConfig> servers, String query) => [
  for (final server in servers)
    if (serverMatchesQuery(server, query)) server,
];
