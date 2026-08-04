import 'dart:async';

import 'package:flutter/material.dart';

/// Transient notices anchored to the TOP of the window. Séance never uses
/// bottom SnackBars: the thing the user is watching — the shell prompt — sits
/// at the bottom of the screen, and a bottom banner would cover it.
///
/// Concurrent toasts stack downward instead of overlapping. Tap a toast (or
/// its action button) to dismiss it; each auto-dismisses after [duration].
///
/// Pass the root [OverlayState] (capture it with `Overlay.of(context,
/// rootOverlay: true)` before closing any dialog) so the toast outlives the
/// widget that triggered it.
void showTopToast(
  OverlayState overlay, {
  required String message,
  Color? background,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _ToastStack.of(overlay).add(
    _ToastData(
      message: message,
      background: background,
      duration: duration,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

/// Convenience wrapper for call sites that have a [BuildContext]: resolves the
/// root overlay so the toast survives the closing of dialogs and routes.
void showTopToastIn(
  BuildContext context, {
  required String message,
  Color? background,
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
}) => showTopToast(
  Overlay.of(context, rootOverlay: true),
  message: message,
  background: background,
  duration: duration,
  actionLabel: actionLabel,
  onAction: onAction,
);

class _ToastData {
  final String message;
  final Color? background;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ToastData({
    required this.message,
    this.background,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });
}

/// One overlay entry per [OverlayState] holding a column of active toasts, so
/// simultaneous notices never paint on top of each other.
class _ToastStack {
  static final Expando<_ToastStack> _stacks = Expando<_ToastStack>();

  static _ToastStack of(OverlayState overlay) =>
      _stacks[overlay] ??= _ToastStack(overlay);

  final OverlayState overlay;
  final List<_ToastData> toasts = [];
  OverlayEntry? _entry;

  _ToastStack(this.overlay);

  void add(_ToastData toast) {
    toasts.add(toast);
    if (overlay.mounted && _entry == null) {
      final entry = OverlayEntry(
        builder: (context) => _ToastColumn(
          toasts: List.of(toasts),
          onDismiss: remove,
        ),
      );
      _entry = entry;
      overlay.insert(entry);
    } else {
      _entry?.markNeedsBuild();
    }
  }

  void remove(_ToastData toast) {
    if (!toasts.remove(toast)) return;
    if (toasts.isEmpty) {
      final entry = _entry;
      _entry = null;
      if (entry != null) {
        if (entry.mounted) entry.remove();
        entry.dispose();
      }
    } else {
      _entry?.markNeedsBuild();
    }
  }
}

class _ToastColumn extends StatelessWidget {
  final List<_ToastData> toasts;
  final void Function(_ToastData) onDismiss;

  const _ToastColumn({required this.toasts, required this.onDismiss});

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    // Only the cards themselves intercept taps; the surrounding strip is
    // transparent, so the terminal below stays interactive.
    child: SafeArea(
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final toast in toasts)
            _TopToast(
              key: ObjectKey(toast),
              toast: toast,
              onDismiss: () => onDismiss(toast),
            ),
        ],
      ),
    ),
  );
}

class _TopToast extends StatefulWidget {
  final _ToastData toast;
  final VoidCallback onDismiss;
  const _TopToast({super.key, required this.toast, required this.onDismiss});

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..forward();

  // Owned by the widget state so tree teardown cancels it; a bare
  // Future.delayed would trip widget tests over a pending timer.
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _dismissTimer = Timer(widget.toast.duration, widget.onDismiss);
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toast = widget.toast;
    final scheme = Theme.of(context).colorScheme;
    final bg = toast.background ?? scheme.inverseSurface;
    final fg = toast.background != null ? Colors.white : scheme.onInverseSurface;
    final accent = toast.background != null
        ? Colors.white
        : scheme.inversePrimary;
    return FadeTransition(
      opacity: _anim,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, -0.25), end: Offset.zero)
            .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut)),
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Material(
              color: bg,
              elevation: 6,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onDismiss,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            toast.message,
                            style: TextStyle(color: fg),
                          ),
                        ),
                        if (toast.actionLabel != null) ...[
                          const SizedBox(width: 16),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: accent,
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () {
                              widget.onDismiss();
                              toast.onAction?.call();
                            },
                            child: Text(toast.actionLabel!),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
