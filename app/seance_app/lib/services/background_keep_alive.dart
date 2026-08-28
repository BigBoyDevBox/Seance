import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// The OS-side half of the background keep-alive. Implemented by the platform
/// channel backend below; tests substitute a recorder.
abstract class BackgroundKeepAliveBackend {
  /// Start anchoring the process. [sessionCount] is how many sessions are
  /// connecting or connected right now.
  Future<void> activate(int sessionCount);

  /// The anchor is up and the live-session count changed.
  Future<void> sessionCountChanged(int sessionCount);

  /// Stop anchoring; no sessions need the process kept alive.
  Future<void> deactivate();
}

/// Talks to the native `seance/keepalive` channel (a foreground service on
/// Android). Android only: desktop apps are never frozen by their OS, and iOS
/// offers no equivalent for a sideloaded app, so every call is a no-op
/// elsewhere. Best-effort by design — a failed anchor degrades to the
/// backgrounding behavior of old (sessions drop) and must never surface as a
/// connect or session error.
class MethodChannelBackgroundKeepAliveBackend
    implements BackgroundKeepAliveBackend {
  const MethodChannelBackgroundKeepAliveBackend();

  static const MethodChannel _channel = MethodChannel('seance/keepalive');

  @override
  Future<void> activate(int sessionCount) =>
      _invoke('activate', sessionCount);

  @override
  Future<void> sessionCountChanged(int sessionCount) =>
      _invoke('sessionCountChanged', sessionCount);

  @override
  Future<void> deactivate() => _invoke('deactivate');

  Future<void> _invoke(String method, [int? sessionCount]) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
        method,
        sessionCount == null ? null : {'sessionCount': sessionCount},
      );
    } on MissingPluginException {
      // Channel not installed (older embedding) — nothing to anchor through.
    } on PlatformException catch (e) {
      debugPrint('background keep-alive "$method" failed: ${e.message}');
    }
  }
}

/// Decides when the app needs an OS-level anchor keeping its process (and with
/// it every live SSH connection) alive while it is backgrounded.
///
/// Without an anchor, Android freezes cached processes soon after they leave
/// the screen; dartssh2's keepalives stop firing, the transport dies, and the
/// remote shells die with it. While any session is connecting or connected,
/// the anchor (an Android foreground service behind [BackgroundKeepAliveBackend])
/// holds the process out of the freezer. The user can opt out via settings.
///
/// Pure state machine over the reported live-session count: it activates
/// once on 0 → n, coalesces repeats into count updates, deactivates once on
/// n → 0, and a disabled keep-alive neither activates nor stays active.
class BackgroundKeepAlive {
  BackgroundKeepAlive({
    BackgroundKeepAliveBackend? backend,
    this._enabled = true,
  }) : _backend = backend ?? const MethodChannelBackgroundKeepAliveBackend();

  final BackgroundKeepAliveBackend _backend;
  bool _enabled;

  /// Count the backend was last told about; only meaningful while [_anchored].
  int _anchoredCount = 0;
  bool _anchored = false;
  int _lastCount = 0;

  /// Apply the user's keep-alive setting. Enabling re-anchors immediately for
  /// the sessions already live; disabling drops an active anchor and keeps
  /// session churn from resurrecting one until re-enabled.
  void setEnabled(bool enabled) {
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) {
      _anchor(_lastCount);
    } else if (_anchored) {
      _anchored = false;
      unawaited(_backend.deactivate());
    }
  }

  /// Report the current number of connecting/connected sessions. Call after
  /// every mutation of a session's connection state.
  void refresh(int sessionCount) {
    _lastCount = sessionCount;
    if (!_enabled) return;
    _anchor(sessionCount);
  }

  void _anchor(int count) {
    if (count <= 0) {
      if (!_anchored) return;
      _anchored = false;
      unawaited(_backend.deactivate());
      return;
    }
    if (_anchored && count == _anchoredCount) return;
    final wasAnchored = _anchored;
    _anchored = true;
    _anchoredCount = count;
    unawaited(
      wasAnchored
          ? _backend.sessionCountChanged(count)
          : _backend.activate(count),
    );
  }
}
