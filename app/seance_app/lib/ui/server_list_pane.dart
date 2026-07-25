import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../main.dart';
import '../theme.dart';
import 'app_menus.dart';
import 'middle_ellipsis_text.dart';
import 'server_editor.dart';
import 'server_filter.dart';
import 'settings_screen.dart';

/// Left pane / first screen: the configured servers with a reachability dot.
/// Tapping one opens a terminal (via [onOpen]).
class ServerListPane extends StatefulWidget {
  final void Function(ServerConfig server) onOpen;
  const ServerListPane({super.key, required this.onOpen});

  /// Below this many servers the list is short enough to read at a glance and
  /// the filter would just be chrome. Matches the Snippets pane's threshold.
  static const int filterThreshold = 5;

  @override
  State<ServerListPane> createState() => _ServerListPaneState();
}

class _ServerListPaneState extends State<ServerListPane> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _setQuery(String value) => setState(() => _query = value);

  void _clearQuery() {
    _search.clear();
    _setQuery('');
  }

  /// Enter opens the only remaining match — the fast path for "type three
  /// letters, hit return, you're on the box".
  void _openFirstMatch(List<ServerConfig> matches) {
    if (matches.isEmpty) return;
    _searchFocus.unfocus();
    widget.onOpen(matches.first);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Séance'),
        actions: [
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => _SyncIndicator(
              state: state,
              onTap: () => _openSettings(context, SettingsTab.sync),
            ),
          ),
          IconButton(
            tooltip: 'Import ~/.ssh/config',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _importConfig(context, state),
          ),
          IconButton(
            tooltip: 'Sync & settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _openSettings(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final matches = filterServers(state.servers, _query);
          // Keep the field once a query is active even if the match count
          // drops below the threshold, or filtering would strand an
          // uneditable filter with no way to clear it.
          final showFilter =
              state.servers.length >= ServerListPane.filterThreshold ||
              _query.isNotEmpty;
          final Widget list;
          if (state.servers.isEmpty) {
            list = const _EmptyState();
          } else if (matches.isEmpty) {
            list = _NoMatches(onClear: _clearQuery);
          } else {
            list = _serverList(context, state, matches);
          }
          final update = state.updateInfo;
          return Column(
            children: [
              // A newer release exists: a dismissible banner above the list.
              if (update != null)
                _UpdateBanner(
                  info: update,
                  onDismiss: state.dismissUpdateNotice,
                ),
              if (showFilter) _filterField(matches),
              Expanded(child: list),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editServer(context, state, null),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
    );
  }

  Widget _filterField(List<ServerConfig> matches) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Shortcuts(
        // Escape clears rather than propagating; there is nothing else in this
        // pane for it to dismiss.
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _clearQuery();
                return null;
              },
            ),
          },
          child: TextField(
            controller: _search,
            focusNode: _searchFocus,
            onChanged: _setQuery,
            onSubmitted: (_) => _openFirstMatch(matches),
            textInputAction: TextInputAction.go,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              hintText: 'Filter servers…',
              helperText: _query.isEmpty
                  ? null
                  : '${matches.length} of ${_serverCount()} · ↵ opens the first',
              border: const OutlineInputBorder(),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear filter',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: _clearQuery,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  int _serverCount() => AppScope.of(context).servers.length;

  Widget _serverList(
    BuildContext context,
    AppState state,
    List<ServerConfig> servers,
  ) {
    return ListView.separated(
      itemCount: servers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final server = servers[i];
        final reachability = state.statuses[server.id] ?? ProbeStatus.unknown;
        final tabs = state.sessionsForServer(server.id);
        return _ServerTile(
          // Stable identity so a background sync replacing the list
          // reconciles each tile to its server instead of by position.
          key: ValueKey(server.id),
          server: server,
          connection: _aggregateStatus(tabs),
          tabCount: tabs.length,
          reachability: reachability,
          selected: server.id == state.activeServerId,
          onTap: () => widget.onOpen(server),
          onNewTab: () => state.newTab(server),
          onEdit: () => _editServer(context, state, server),
          onDelete: () => _deleteServer(context, state, server),
          // Disconnect every live tab; reconnect the lone dead tab.
          onDisconnect: () {
            for (final t in tabs) {
              if (t.status == TerminalStatus.connected) {
                state.disconnect(t.id);
              }
            }
          },
          onReconnect: tabs.length == 1
              ? () => state.reconnect(tabs.first.id)
              : null,
        );
      },
    );
  }

  static void _openSettings(
    BuildContext context, [
    SettingsTab tab = SettingsTab.general,
  ]) => openSettings(tab);

  Future<void> _editServer(
    BuildContext context,
    AppState state,
    ServerConfig? server,
  ) async {
    await showServerEditor(context, state, server);
  }

  Future<void> _deleteServer(
    BuildContext context,
    AppState state,
    ServerConfig server,
  ) async {
    final localCopyCount = state
        .sessionsForServer(server.id)
        .fold<int>(
          0,
          (count, session) =>
              count +
              (session.files?.localCopies.length ?? 0) +
              session.retainedLocalCopies.length,
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${server.label}"?'),
        content: Text(
          localCopyCount == 0
              ? 'This removes the server and any stored secret.'
              : 'This removes the server, its stored secret, and '
                    '$localCopyCount managed local '
                    '${localCopyCount == 1 ? 'edit' : 'edits'}. Any changes not '
                    'uploaded to the server will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteServer(server.id);
  }

  Future<void> _importConfig(BuildContext context, AppState state) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import SSH config'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'Paste the contents of ~/.ssh/config …',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      final n = await state.importSshConfig(text);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Imported $n host(s)')));
      }
    }
  }
}

/// A compact header affordance that shows background-sync activity: a spinner
/// while a round runs, an error badge if the last one failed. Hidden when idle
/// and healthy (the gear icon already leads to sync). Tapping opens settings.
class _SyncIndicator extends StatelessWidget {
  final AppState state;
  final VoidCallback onTap;
  const _SyncIndicator({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (state.syncing) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (state.lastSyncError != null) {
      return IconButton(
        tooltip: 'Last sync failed — open settings',
        icon: Icon(
          Icons.cloud_off_outlined,
          color: Theme.of(context).colorScheme.error,
        ),
        onPressed: onTap,
      );
    }
    return const SizedBox.shrink();
  }
}

/// A dismissible banner shown above the server list when a newer release
/// exists on GitHub. It only offers a link to the releases page — Séance never
/// downloads or installs an update; the user decides.
class _UpdateBanner extends StatelessWidget {
  final UpdateInfo info;
  final VoidCallback onDismiss;
  const _UpdateBanner({required this.info, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update_outlined,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Séance ${info.latestVersion} is available.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => launchUrl(
                info.releasesUrl,
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('View release'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// Aggregate a server's tab statuses into the single dot shown on its row:
/// any connecting wins (spinner), else any connected (green), else any error
/// (red), else disconnected/none (grey).
TerminalStatus _aggregateStatus(List<TerminalSession> tabs) {
  if (tabs.any((t) => t.status == TerminalStatus.connecting)) {
    return TerminalStatus.connecting;
  }
  if (tabs.any((t) => t.status == TerminalStatus.connected)) {
    return TerminalStatus.connected;
  }
  if (tabs.any((t) => t.status == TerminalStatus.error)) {
    return TerminalStatus.error;
  }
  return TerminalStatus.disconnected;
}

class _ServerTile extends StatelessWidget {
  final ServerConfig server;
  final TerminalStatus connection;

  /// Number of open sessions (tabs) for this server; a small "×N" appears
  /// beside the dot when >1.
  final int tabCount;
  final ProbeStatus reachability;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onNewTab;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onDisconnect;

  /// Only offered when the server has exactly one (dead) tab; per-tab
  /// reconnect otherwise lives in the pane.
  final VoidCallback? onReconnect;

  const _ServerTile({
    super.key,
    required this.server,
    required this.connection,
    required this.tabCount,
    required this.reachability,
    required this.selected,
    required this.onTap,
    required this.onNewTab,
    required this.onEdit,
    required this.onDelete,
    required this.onDisconnect,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final connected = connection == TerminalStatus.connected;
    final hasSession = tabCount > 0;
    return ListTile(
      selected: selected,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ConnectionDot(status: connection),
          if (tabCount > 1)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '×$tabCount',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
      title: MiddleEllipsisText(server.label),
      subtitle: Text(
        '${server.username}@${server.host}:${server.port}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReachabilityDot(status: reachability),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'newTab':
                  onNewTab();
                case 'edit':
                  onEdit();
                case 'delete':
                  onDelete();
                case 'disconnect':
                  onDisconnect();
                case 'reconnect':
                  onReconnect?.call();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'newTab', child: Text('New tab')),
              if (connected)
                PopupMenuItem(
                  value: 'disconnect',
                  child: Text(tabCount > 1 ? 'Disconnect all' : 'Disconnect'),
                ),
              if (hasSession && !connected && onReconnect != null)
                const PopupMenuItem(
                  value: 'reconnect',
                  child: Text('Reconnect'),
                ),
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The prominent leading dot: the state of this server's terminal session.
class _ConnectionDot extends StatelessWidget {
  final TerminalStatus status;
  const _ConnectionDot({required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == TerminalStatus.connecting) {
      return const Tooltip(
        message: 'connecting',
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final (color, label) = switch (status) {
      TerminalStatus.connected => (StatusColors.online(context), 'connected'),
      TerminalStatus.error => (
        StatusColors.offline(context),
        'connection error',
      ),
      TerminalStatus.disconnected => (
        StatusColors.unknown(context),
        'disconnected',
      ),
      TerminalStatus.connecting => (
        StatusColors.unknown(context),
        'connecting',
      ),
    };
    return Tooltip(
      message: label,
      child: Icon(Icons.circle, size: 12, color: color),
    );
  }
}

/// A subtle secondary dot: whether the host is reachable on the network (the
/// background probe), independent of whether we have a session open.
class _ReachabilityDot extends StatelessWidget {
  final ProbeStatus status;
  const _ReachabilityDot({required this.status});

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      ProbeStatus.online => (StatusColors.online(context), 'reachable'),
      ProbeStatus.offline => (StatusColors.offline(context), 'unreachable'),
      ProbeStatus.unknown => (
        StatusColors.unknown(context),
        'reachability unknown',
      ),
    };
    return Tooltip(
      message: 'Host $label',
      child: Icon(Icons.circle_outlined, size: 10, color: color),
    );
  }
}

/// Shown when a filter excludes every server — distinct from having no
/// servers at all, which needs the onboarding empty state instead.
class _NoMatches extends StatelessWidget {
  final VoidCallback onClear;
  const _NoMatches({required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 40),
            const SizedBox(height: 12),
            Text(
              'No servers match',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: onClear, child: const Text('Clear filter')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 48),
            const SizedBox(height: 12),
            Text(
              'No servers yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'Add one, or import your ~/.ssh/config.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // The tooltip-only gear above is invisible on touch; a fresh
            // install (especially on a phone) needs a visible path to the
            // sync-server setup.
            OutlinedButton.icon(
              onPressed: () => openSettings(),
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Sync & settings'),
            ),
          ],
        ),
      ),
    );
  }
}
