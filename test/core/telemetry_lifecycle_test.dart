import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/vpn_log_entry.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/protocols/xray/xray_engine.dart';
import 'package:teapodstream/providers/ip_info_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';
import 'package:teapodstream/providers/vpn_provider.dart';

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(ipLookupEnabled: false);
}

class _Ip extends IpInfoNotifier {
  @override
  Future<IpInfo?> build() async => null;
}

class _Engine extends XrayEngine {
  final snapshot = Completer<List<Map<String, int>>>();
  int calls = 0;
  NativeVpnState native = (
    state: VpnState.connected,
    rawState: 'connected',
    socksPort: 10808,
    socksUser: '',
    socksPassword: '',
    connectedAtMs: 0,
    sessionId: 1,
    mode: 'allExcept',
    plan: {},
  );
  @override
  Future<List<VpnLogEntry>> getLogs() async => [];
  @override
  Future<NativeVpnState> getVpnState() async => native;
  @override
  Future<NativeVpnState?> queryVpnState() async => native;
  @override
  Future<List<Map<String, int>>> getStatsHistory() {
    calls++;
    return snapshot.future;
  }
}

/// Each snapshot request gets its own completer, so a test can resolve them
/// one by one.
class _QueueEngine extends _Engine {
  final requests = <Completer<List<Map<String, int>>>>[];
  @override
  Future<List<Map<String, int>>> getStatsHistory() {
    calls++;
    final request = Completer<List<Map<String, int>>>();
    requests.add(request);
    return request.future;
  }
}

Future<(ProviderContainer, StreamController<dynamic>)> _start(
  _Engine engine,
) async {
  final events = StreamController<dynamic>(sync: true);
  final container = ProviderContainer(
    overrides: [
      vpnEngineProvider.overrideWithValue(engine),
      vpnEventProvider.overrideWithValue(events.stream),
      settingsProvider.overrideWith(_Settings.new),
      ipInfoProvider.overrideWith(_Ip.new),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await events.close();
  });
  container.read(vpnProvider.notifier);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  return (container, events);
}

void main() {
  test('an error shown while connected survives stats ticks', () async {
    final (container, events) = await _start(_Engine());
    expect(container.read(vpnProvider).isConnected, isTrue);
    events.add({
      'type': 'connectionError',
      'sessionId': 1,
      'code': 'CORE_REJECTED',
    });
    for (var i = 0; i < 3; i++) {
      events.add({'type': 'stats', 'sessionId': 1, 'downloadSpeed': i});
    }
    expect(container.read(vpnProvider).error, contains('CORE_REJECTED'));
  });

  test('a stop error clears once the native stop really finishes', () async {
    final (container, events) = await _start(_Engine());
    events.add({'type': 'state', 'sessionId': 1, 'value': 'disconnecting'});
    events.add({
      'type': 'connectionError',
      'sessionId': 1,
      'code': 'NATIVE_STOP_TIMEOUT',
    });
    events.add({'type': 'state', 'sessionId': 1, 'value': 'stopBlocked'});
    expect(container.read(vpnProvider).error, isNotNull);
    events.add({'type': 'state', 'sessionId': 1, 'value': 'disconnected'});
    expect(container.read(vpnProvider).connectionState, VpnState.disconnected);
    expect(container.read(vpnProvider).error, isNull);
  });

  test('a rejection that ends the session stays visible', () async {
    final (container, events) = await _start(_Engine());
    events.add({
      'type': 'connectionError',
      'sessionId': 1,
      'code': 'EMPTY_ALLOWED_APPS',
    });
    events.add({'type': 'state', 'sessionId': 1, 'value': 'disconnected'});
    expect(container.read(vpnProvider).error, contains('приложение'));
  });

  test('diagnostics keep the mode of the session that just ended', () async {
    final (container, events) = await _start(_Engine());
    expect(container.read(vpnProvider.notifier).lastAppliedMode, 'allExcept');
    events.add({'type': 'state', 'sessionId': 1, 'value': 'disconnected'});
    expect(container.read(vpnProvider).appliedMode, 'unknown');
    expect(container.read(vpnProvider.notifier).lastAppliedMode, 'allExcept');
  });

  test('points from before a pause are not joined to new ones', () async {
    final engine = _QueueEngine();
    final (container, events) = await _start(engine);
    final notifier = container.read(vpnProvider.notifier);
    engine.requests.single.complete([
      {'downloadSpeed': 1},
    ]);
    await Future<void>.delayed(Duration.zero);
    events.add({'type': 'stats', 'sessionId': 1, 'downloadSpeed': 2});
    expect(container.read(vpnProvider).stats.speedHistory.length, 2);

    notifier.onAppPaused();
    await notifier.onAppResumed();
    await Future<void>.delayed(Duration.zero);
    expect(engine.requests.length, 2);
    expect(container.read(vpnProvider).stats.speedHistory, isEmpty);
    // A live point beats the snapshot, which is then discarded as stale.
    events.add({'type': 'stats', 'sessionId': 1, 'downloadSpeed': 3});
    engine.requests.last.complete([
      {'downloadSpeed': 1},
      {'downloadSpeed': 2},
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(
      container
          .read(vpnProvider)
          .stats
          .speedHistory
          .map((p) => p.downloadSpeed),
      [3],
    );
  });

  test(
    'one snapshot, bounded event history, hidden screen and stale session guards',
    () async {
      final events = StreamController<dynamic>(sync: true);
      final engine = _Engine();
      final container = ProviderContainer(
        overrides: [
          vpnEngineProvider.overrideWithValue(engine),
          vpnEventProvider.overrideWithValue(events.stream),
          settingsProvider.overrideWith(_Settings.new),
          ipInfoProvider.overrideWith(_Ip.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await events.close();
      });
      final notifier = container.read(vpnProvider.notifier);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, 1);
      await notifier
          .onAppResumed(); // Slow outstanding request is not duplicated.
      expect(engine.calls, 1);
      for (var i = 0; i < 320; i++) {
        events.add({'type': 'stats', 'sessionId': 1, 'downloadSpeed': i});
      }
      expect(container.read(vpnProvider).stats.speedHistory.length, 300);
      engine.snapshot.complete([
        {'downloadSpeed': 999},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(vpnProvider).stats.speedHistory.last.downloadSpeed,
        319,
      );
      notifier.setStatsVisible(false);
      events.add({'type': 'stats', 'sessionId': 1, 'downloadSpeed': 777});
      expect(
        container.read(vpnProvider).stats.speedHistory.last.downloadSpeed,
        319,
      );
      events.add({'type': 'state', 'sessionId': 2, 'value': 'disconnected'});
      events.add({
        'type': 'state',
        'sessionId': 1,
        'value': 'connected',
        'socksPort': 10808,
      });
      expect(
        container.read(vpnProvider).connectionState,
        VpnState.disconnected,
      );
      expect(container.read(vpnProvider).stats.speedHistory, isEmpty);
    },
  );
}
