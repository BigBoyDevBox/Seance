import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A prober that records how many probes are in flight at once, and holds each
/// one open until the test releases it.
class _CountingProber implements Prober {
  final List<String> probed = [];
  int inFlight = 0;
  int peakInFlight = 0;
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    probed.add(host);
    inFlight++;
    if (inFlight > peakInFlight) peakInFlight = inFlight;
    await _gate.future;
    inFlight--;
    return ProbeStatus.online;
  }
}

/// Throws for the named hosts, mimicking a prober that does not swallow its
/// own errors the way [TcpBannerProber] does.
class _ThrowingProber implements Prober {
  final Set<String> failing;
  _ThrowingProber(this.failing);

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (failing.contains(host)) throw StateError('probe exploded');
    return ProbeStatus.online;
  }
}

ServerConfig _server(String id) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: 'u',
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('probe fan-out is bounded', () {
    test('never exceeds maxConcurrentProbes', () async {
      final prober = _CountingProber();
      final service = ProbeService(prober: prober, maxConcurrentProbes: 3);
      addTearDown(service.dispose);

      final servers = [for (var i = 0; i < 20; i++) _server('s$i')];
      final pending = service.probeAll(servers);
      // Workers run synchronously up to `await _gate.future` inside the
      // prober, so by the next event-loop turn the whole first wave is
      // blocked and peakInFlight reflects the real fan-out. A future change
      // that inserts an await before the probe call would need a real gate
      // here instead.
      await Future<void>.delayed(Duration.zero);
      expect(prober.peakInFlight, lessThanOrEqualTo(3));

      prober.release();
      final result = await pending;
      expect(result.length, 20);
      expect(prober.peakInFlight, lessThanOrEqualTo(3));
      expect(prober.probed.length, 20);
    });

    test('a short list does not spin up idle workers', () async {
      final prober = _CountingProber()..release();
      final service = ProbeService(prober: prober, maxConcurrentProbes: 8);
      addTearDown(service.dispose);
      final result = await service.probeAll([_server('a'), _server('b')]);
      expect(result.keys, unorderedEquals(['a', 'b']));
      expect(prober.peakInFlight, lessThanOrEqualTo(2));
    });
  });

  group('one bad host does not take the sweep with it', () {
    test('a throwing probe yields unknown, and the rest still complete', () async {
      final service = ProbeService(prober: _ThrowingProber({'b.example.com'}));
      addTearDown(service.dispose);
      final result = await service.probeAll([
        _server('a'),
        _server('b'),
        _server('c'),
      ]);
      expect(result.length, 3);
      // Not `offline`: an unexpected error is not evidence the host is down.
      expect(result['b'], ProbeStatus.unknown);
      expect(result['a'], ProbeStatus.online);
      expect(result['c'], ProbeStatus.online);
    });
  });

  group('a disposed service stops for good', () {
    test('a sweep in flight when dispose lands does not re-arm', () async {
      final prober = _CountingProber();
      final service = ProbeService(
        prober: prober,
        interval: const Duration(milliseconds: 10),
      );
      service.start([_server('a')]);

      // Wait until the first sweep is actually inside the prober, so the
      // timer has already fired and `dispose` has nothing left to cancel.
      while (prober.probed.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await service.dispose();
      // Completing the sweep after dispose must be uneventful: the result is
      // dropped rather than pushed into a closed controller.
      prober.release();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final afterDispose = prober.probed.length;
      // Several intervals' worth of quiet.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        prober.probed.length,
        afterDispose,
        reason: 'a disposed service must not keep waking up to probe',
      );
    });
  });

  group('servers with a live session are not probed', () {
    test('they are reported online without touching the network', () async {
      final prober = _CountingProber()..release();
      final service = ProbeService(prober: prober);
      addTearDown(service.dispose);

      final result = await service.probeAll(
        [_server('live'), _server('idle')],
        alreadyConnected: {'live'},
      );
      expect(result['live'], ProbeStatus.online);
      expect(result['idle'], ProbeStatus.online);
      expect(prober.probed, ['idle.example.com']);
    });

    test('every server still gets a status when all are connected', () async {
      final prober = _CountingProber()..release();
      final service = ProbeService(prober: prober);
      addTearDown(service.dispose);

      final result = await service.probeAll(
        [_server('a'), _server('b')],
        alreadyConnected: {'a', 'b'},
      );
      expect(result, {'a': ProbeStatus.online, 'b': ProbeStatus.online});
      expect(prober.probed, isEmpty);
    });

    test('the periodic sweep consults connectedServerIds', () async {
      final prober = _CountingProber()..release();
      final service = ProbeService(
        prober: prober,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(service.dispose);
      service.connectedServerIds = () => {'live'};

      final sweep = service.statuses.first;
      service.start([_server('live'), _server('idle')]);
      final statuses = await sweep;

      expect(statuses['live'], ProbeStatus.online);
      expect(prober.probed, ['idle.example.com']);
    });
  });
}
