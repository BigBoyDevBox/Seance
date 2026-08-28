import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/background_keep_alive.dart';

/// Records backend calls so the state machine's exact activation protocol can
/// be asserted without a platform.
class RecordingBackend implements BackgroundKeepAliveBackend {
  final calls = <String>[];

  @override
  Future<void> activate(int sessionCount) async =>
      calls.add('activate $sessionCount');

  @override
  Future<void> sessionCountChanged(int sessionCount) async =>
      calls.add('count $sessionCount');

  @override
  Future<void> deactivate() async => calls.add('deactivate');
}

void main() {
  test('activates on the first live session and deactivates on the last', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(1);
    keepAlive.refresh(0);

    expect(backend.calls, ['activate 1', 'deactivate']);
  });

  test('updates the count while anchored instead of re-activating', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(1);
    keepAlive.refresh(3);
    keepAlive.refresh(2);

    expect(backend.calls, ['activate 1', 'count 3', 'count 2']);
  });

  test('coalesces repeated counts into a single call', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.refresh(2);
    keepAlive.refresh(0);
    keepAlive.refresh(0);

    expect(backend.calls, ['activate 2', 'deactivate']);
  });

  test('a disabled keep-alive never activates and drops an active anchor', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend, enabled: false);

    keepAlive.refresh(2);
    expect(backend.calls, isEmpty);

    keepAlive.setEnabled(true);
    keepAlive.refresh(2);
    keepAlive.refresh(1);
    expect(backend.calls, ['activate 2', 'count 1']);

    keepAlive.setEnabled(false);
    // Further session churn while disabled must not resurrect the anchor.
    keepAlive.refresh(3);
    expect(backend.calls, ['activate 2', 'count 1', 'deactivate']);
  });

  test('re-enabling re-anchors with the last reported count', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend);

    keepAlive.refresh(2);
    keepAlive.setEnabled(false);
    keepAlive.setEnabled(true);

    expect(backend.calls, ['activate 2', 'deactivate', 'activate 2']);
  });

  test('enablement state changes that change nothing call nothing', () {
    final backend = RecordingBackend();
    final keepAlive = BackgroundKeepAlive(backend: backend, enabled: true);

    keepAlive.setEnabled(true);
    keepAlive.setEnabled(false);
    keepAlive.setEnabled(false);

    expect(backend.calls, isEmpty);
  });
}
