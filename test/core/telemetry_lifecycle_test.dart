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

void main() {
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
