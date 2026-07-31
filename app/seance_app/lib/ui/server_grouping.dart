/// Sectioning for the server list.
///
/// Kept free of Flutter, like [server_filter.dart], so the rules that decide
/// what the list looks like can be unit-tested without pumping a widget.
///
/// The shape of the feature is that grouping costs nothing until it is used:
/// with no server filed anywhere, [groupServers] returns one anonymous section
/// and the pane renders exactly the flat list it always did — no headers, no
/// indentation, nothing to collapse.
library;

import 'package:seance_core/seance_core.dart';

/// The key of the section holding servers with no group.
///
/// Empty is safe as a sentinel because a real group key never is:
/// [normalizeServerGroup] turns a blank or whitespace-only name into null,
/// which is what puts a server in this section in the first place.
const String kUngroupedKey = '';

/// The header shown over the servers that aren't in any group. Only ever
/// rendered when at least one *other* group exists — see [groupServers].
const String kUngroupedLabel = 'Ungrouped';

/// One section of the server list.
class ServerGroupSection {
  /// The group's name as the user spelled it, or null for the ungrouped
  /// remainder. Null is also what a list with no groups at all collapses to,
  /// which is how the pane knows not to draw headers.
  final String? name;

  /// Members, in the order they arrived (the store sorts by label).
  final List<ServerConfig> servers;

  const ServerGroupSection({required this.name, required this.servers});

  /// The identity this section is collapsed and re-found by, stable across a
  /// re-sort and across a member being renamed.
  String get key => name == null ? kUngroupedKey : serverGroupKey(name!);
}

/// [servers] split into sections: one per group, sorted by name, with the
/// ungrouped remainder last.
///
/// Returns a single unnamed section when no server carries a group, so the
/// common case renders as a plain list rather than as one section that happens
/// to hold everything.
///
/// Grouping is case-insensitive ([serverGroupKey]); the spelling shown is the
/// one on the first member in [servers] order, so a group does not rename
/// itself when a member is edited elsewhere in the list.
List<ServerGroupSection> groupServers(List<ServerConfig> servers) {
  final byKey = <String, List<ServerConfig>>{};
  final names = <String, String>{};
  final ungrouped = <ServerConfig>[];

  for (final server in servers) {
    final group = normalizeServerGroup(server.group);
    if (group == null) {
      ungrouped.add(server);
      continue;
    }
    final key = serverGroupKey(group);
    byKey.putIfAbsent(key, () => []).add(server);
    names.putIfAbsent(key, () => group);
  }

  if (byKey.isEmpty) {
    return [ServerGroupSection(name: null, servers: servers)];
  }

  final keys = byKey.keys.toList()..sort();
  return [
    for (final key in keys)
      ServerGroupSection(name: names[key], servers: byKey[key]!),
    if (ungrouped.isNotEmpty)
      ServerGroupSection(name: null, servers: ungrouped),
  ];
}

/// One rendered line of the server list: either a group header or a server.
sealed class ServerListRow {
  const ServerListRow();
}

/// A collapsible section header. Not emitted for a list with no groups.
final class ServerGroupHeaderRow extends ServerListRow {
  /// The name to show — [kUngroupedLabel] for the ungrouped section.
  final String name;
  final String key;

  /// Members in the section, shown beside the name so a collapsed group still
  /// says how much it is hiding.
  final int count;
  final bool collapsed;

  const ServerGroupHeaderRow({
    required this.name,
    required this.key,
    required this.count,
    required this.collapsed,
  });
}

final class ServerRow extends ServerListRow {
  final ServerConfig server;
  const ServerRow(this.server);
}

/// Flatten [sections] into the rows to render, dropping the members of any
/// section whose key is in [collapsedKeys].
///
/// A section that is collapsed still emits its header — that is the only way
/// back. The anonymous section of an ungrouped list emits no header at all,
/// and so can never be collapsed into nothing.
List<ServerListRow> serverListRows({
  required List<ServerGroupSection> sections,
  required Set<String> collapsedKeys,
}) {
  final rows = <ServerListRow>[];
  for (final section in sections) {
    final name = section.name;
    // The one section that is not a group: no header, no collapsing.
    final anonymous = name == null && sections.length == 1;
    var collapsed = false;
    if (!anonymous) {
      collapsed = collapsedKeys.contains(section.key);
      rows.add(ServerGroupHeaderRow(
        name: name ?? kUngroupedLabel,
        key: section.key,
        count: section.servers.length,
        collapsed: collapsed,
      ));
    }
    if (collapsed) continue;
    for (final server in section.servers) {
      rows.add(ServerRow(server));
    }
  }
  return rows;
}

/// The distinct group names in [servers], sorted, for offering existing groups
/// in the editor instead of making the user retype (and misspell) one.
List<String> existingServerGroups(List<ServerConfig> servers) {
  final names = <String, String>{};
  for (final server in servers) {
    final group = normalizeServerGroup(server.group);
    if (group != null) names.putIfAbsent(serverGroupKey(group), () => group);
  }
  final keys = names.keys.toList()..sort();
  return [for (final key in keys) names[key]!];
}
