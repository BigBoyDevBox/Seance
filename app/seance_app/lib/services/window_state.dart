import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'atomic_file.dart';

/// The desktop main-window geometry carried across launches. [bounds] is the
/// last user-arranged *normal* frame (never a maximized or full-screen one) in
/// the desktop's global logical coordinate space — the position doubles as the
/// monitor choice, so restoring it puts the window back on the display it was
/// closed on. The flags say how the window was presented on top of that frame.
class WindowStateSnapshot {
  final Rect? bounds;
  final bool isMaximized;
  final bool isFullScreen;

  const WindowStateSnapshot({
    this.bounds,
    this.isMaximized = false,
    this.isFullScreen = false,
  });

  Map<String, dynamic> toJson() => {
    if (bounds != null) 'x': bounds!.left,
    if (bounds != null) 'y': bounds!.top,
    if (bounds != null) 'width': bounds!.width,
    if (bounds != null) 'height': bounds!.height,
    'isMaximized': isMaximized,
    'isFullScreen': isFullScreen,
  };

  /// Tolerant parse: anything malformed reads as "nothing saved". Window
  /// geometry is cheap to lose, so there is no quarantine ceremony here — the
  /// next save simply overwrites a bad file.
  static WindowStateSnapshot? fromJson(Object? json) {
    if (json is! Map) return null;
    double? dim(Object? value) {
      if (value is! num) return null;
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }

    final x = dim(json['x']);
    final y = dim(json['y']);
    final width = dim(json['width']);
    final height = dim(json['height']);
    Rect? bounds;
    if (x != null &&
        y != null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      bounds = Rect.fromLTWH(x, y, width, height);
    }
    return WindowStateSnapshot(
      bounds: bounds,
      isMaximized: json['isMaximized'] == true,
      isFullScreen: json['isFullScreen'] == true,
    );
  }
}

/// Loads and saves the window state as `window_state.json`. Kept out of
/// settings.json on purpose: geometry changes with every move/resize, and the
/// settings file — which carries the device's sync identity — should not be
/// rewritten that often (and it isn't loaded until after the first frame,
/// which is too late to place the window without a flash).
class WindowStateStore {
  final File file;
  Future<void> _saveTail = Future<void>.value();

  WindowStateStore(this.file);

  Future<WindowStateSnapshot?> load() async {
    try {
      if (!await file.exists()) return null;
      return WindowStateSnapshot.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(WindowStateSnapshot snapshot) {
    final contents = jsonEncode(snapshot.toJson());
    final result = Completer<void>();
    _saveTail = _saveTail.then((_) async {
      try {
        await writeStringAtomically(file, contents);
        result.complete();
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}

/// Decide whether a saved frame can be restored onto the currently connected
/// displays (their visible areas, in the same global logical space). Returns
/// the frame to restore, or null to fall back to the platform's default
/// placement — when the monitor the window lived on is gone, or the saved
/// values are degenerate. "Restorable" means enough of the frame lands on some
/// display to grab the title bar and drag the window back by hand.
Rect? resolveWindowBounds(Rect? saved, Iterable<Rect> displayAreas) {
  if (saved == null) return null;
  const minimumWindowSize = 100.0;
  if (!saved.left.isFinite ||
      !saved.top.isFinite ||
      !saved.width.isFinite ||
      !saved.height.isFinite) {
    return null;
  }
  if (saved.width < minimumWindowSize || saved.height < minimumWindowSize) {
    return null;
  }
  for (final area in displayAreas) {
    final overlap = saved.intersect(area);
    if (overlap.width >= 100 && overlap.height >= 50) return saved;
  }
  return null;
}

/// Restores the persisted window state at launch and keeps it current while
/// the app runs. Desktop only — a no-op on mobile.
///
/// Wiring contract (macOS): `MainFlutterWindow` hides the window at launch
/// (`hiddenWindowAtLaunch()` in its `order` override) so the saved frame can
/// be applied off-screen. [restoreAndTrack] is what makes the window visible
/// again — it always reaches `show()` on macOS, even when restoring fails —
/// so it must run in `main()` before `runApp`.
class WindowStateService with WindowListener {
  WindowStateService._(this._store, this._current);

  /// Keeps the listener alive for the process lifetime; also the reentry
  /// guard, since the window can only be restored once per launch.
  static WindowStateService? _instance;

  final WindowStateStore _store;
  WindowStateSnapshot _current;
  Timer? _debounce;

  static bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  static Future<void> restoreAndTrack() async {
    if (!_isDesktop || _instance != null) return;
    try {
      await windowManager.ensureInitialized();
      final dir = await getApplicationSupportDirectory();
      final store = WindowStateStore(File('${dir.path}/window_state.json'));
      final saved = await store.load();
      final service = WindowStateService._(
        store,
        saved ?? const WindowStateSnapshot(),
      );
      _instance = service;
      await service._applyAtLaunch(saved);
      windowManager.addListener(service);
    } catch (error) {
      debugPrint('Window state restore failed: $error');
      if (Platform.isMacOS) {
        // The macOS runner keeps the window hidden until we show it; a restore
        // failure must not leave the app invisible.
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
    }
  }

  Future<void> _applyAtLaunch(WindowStateSnapshot? saved) async {
    final bounds = resolveWindowBounds(saved?.bounds, await _displayAreas());
    final maximized = saved?.isMaximized ?? false;
    final fullScreen = saved?.isFullScreen ?? false;
    if (Platform.isMacOS) {
      // The window is hidden (see MainFlutterWindow.order), so the saved frame
      // applies without a flash of the storyboard default. Full-screen needs a
      // visible window — toggleFullScreen does nothing to a hidden one — so it
      // is entered after show().
      await windowManager.waitUntilReadyToShow(null, () async {
        if (bounds != null) await windowManager.setBounds(bounds);
        if (maximized && !fullScreen) await windowManager.maximize();
        await windowManager.show();
        await windowManager.focus();
        if (fullScreen) await windowManager.setFullScreen(true);
      });
    } else if (Platform.isWindows) {
      // The runner shows the window on the first Flutter frame with
      // SW_SHOWNORMAL, which cancels any earlier maximize (and maximizing a
      // hidden window would show it early). Geometry applies while hidden;
      // the presentation flags wait until the runner has shown the window.
      if (bounds != null) await windowManager.setBounds(bounds);
      if (maximized || fullScreen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 200), () async {
              try {
                if (fullScreen) {
                  await windowManager.setFullScreen(true);
                } else {
                  await windowManager.maximize();
                }
              } catch (error) {
                debugPrint('Deferred window state restore failed: $error');
              }
            }),
          );
        });
      }
    } else {
      // Linux: the runner shows the window on the first frame, and GTK applies
      // move/resize/maximize/fullscreen requests made while hidden when the
      // window maps. (On Wayland the compositor ignores positioning — size,
      // maximize and full-screen still restore.)
      if (bounds != null) await windowManager.setBounds(bounds);
      if (fullScreen) {
        await windowManager.setFullScreen(true);
      } else if (maximized) {
        await windowManager.maximize();
      }
    }
    _current = WindowStateSnapshot(
      bounds: bounds ?? saved?.bounds,
      isMaximized: maximized,
      isFullScreen: fullScreen,
    );
  }

  /// The visible working area of every connected display, for
  /// [resolveWindowBounds]'s "is the saved frame still reachable" check.
  Future<List<Rect>> _displayAreas() async {
    final displays = await ScreenRetriever.instance.getAllDisplays();
    return [
      for (final display in displays)
        (display.visiblePosition ?? Offset.zero) &
            (display.visibleSize ?? display.size),
    ];
  }

  // Geometry events arrive continuously during a drag; the debounce means one
  // write per interaction, not one per pixel. The *ed variants fire only on
  // some platforms, so both are wired.
  @override
  void onWindowResize() => _scheduleCapture();
  @override
  void onWindowResized() => _scheduleCapture();
  @override
  void onWindowMove() => _scheduleCapture();
  @override
  void onWindowMoved() => _scheduleCapture();
  @override
  void onWindowMaximize() => _scheduleCapture();
  @override
  void onWindowUnmaximize() => _scheduleCapture();
  @override
  void onWindowEnterFullScreen() => _scheduleCapture();
  @override
  void onWindowLeaveFullScreen() => _scheduleCapture();
  @override
  void onWindowRestore() => _scheduleCapture();

  @override
  void onWindowClose() {
    // Last chance to persist a change still inside the debounce window. Best
    // effort — if the process dies before the write lands, the previous save
    // still holds.
    _debounce?.cancel();
    unawaited(_captureAndSave());
  }

  void _scheduleCapture() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_captureAndSave()),
    );
  }

  Future<void> _captureAndSave() async {
    try {
      // A minimized window reports junk geometry; whatever was saved before
      // minimizing is still the truth.
      if (await windowManager.isMinimized()) return;
      final isFullScreen = await windowManager.isFullScreen();
      final isMaximized = await windowManager.isMaximized();
      var bounds = _current.bounds;
      // Only a normal frame is worth remembering — maximized/full-screen
      // bounds are derived from the display, and restoring them as the
      // "normal" frame would make un-maximizing a no-op.
      if (!isFullScreen && !isMaximized) bounds = await windowManager.getBounds();
      _current = WindowStateSnapshot(
        bounds: bounds,
        isMaximized: isMaximized,
        isFullScreen: isFullScreen,
      );
      await _store.save(_current);
    } catch (error) {
      debugPrint('Window state save failed: $error');
    }
  }
}
