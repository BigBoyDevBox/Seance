import 'dart:async';

typedef CleanupAction = FutureOr<void> Function();

enum CleanupFailureMode { preserveFirst, ignore }

/// Runs teardown in dependency order and still attempts later resources.
Future<void> runSequentialCleanup(
  Iterable<CleanupAction> actions, {
  required Duration actionTimeout,
  CleanupFailureMode failureMode = CleanupFailureMode.preserveFirst,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;

  for (final action in actions) {
    try {
      await Future<void>.sync(action).timeout(actionTimeout);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  if (firstError == null || failureMode == CleanupFailureMode.ignore) return;
  Error.throwWithStackTrace(firstError, firstStackTrace!);
}
