import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/config_repository.dart';
import 'package:teapodstream/core/services/config_storage_service.dart';
import 'package:teapodstream/core/services/storage_secure_service.dart';
import 'package:teapodstream/providers/config_provider.dart';

class _Secure extends StorageSecureService {
  String raw;
  int writes = 0;
  _Secure(ConfigState initial) : raw = _encode(initial);
  static String _encode(ConfigState state) {
    final payload = jsonEncode(state.toJson());
    return jsonEncode({
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
  }

  @override
  Future<String?> readConnectionsSnapshot() async => raw;
  @override
  Future<void> writeConnectionsSnapshot(String json) async {
    writes++;
    raw = json;
  }
}

VpnConfig _server(String name) => VpnConfig(
  id: name,
  name: name,
  protocol: VpnProtocol.trojan,
  address: '$name.example.test',
  port: 443,
  uuid: '',
  password: 'secret',
  security: VpnSecurity.tls,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
  subscriptionId: 'sub',
);

VpnConfig _measured(VpnConfig c, int ms, DateTime at) => c.copyWith(
  latencyMs: ms,
  lastPingedAt: at,
  probeStatus: ProbeStatus.success,
  lastSuccessfulLatencyMs: ms,
  lastSuccessfulPingAt: at,
);

Future<(ProviderContainer, _Secure)> _start(List<VpnConfig> configs) async {
  final secure = _Secure(
    ConfigState(
      configs: configs,
      activeSubscriptionId: 'sub',
      subscriptions: [
        Subscription(
          id: 'sub',
          name: 'Provider',
          url: 'https://sub.example.test/s',
          createdAt: DateTime(2026),
        ),
      ],
    ),
  );
  final container = ProviderContainer(
    overrides: [
      configRepositoryProvider.overrideWithValue(
        ConfigRepository(secure: secure),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(configProvider.future);
  return (container, secure);
}

void main() {
  test('spec: A at 10 ms then failing, B at 50 ms — B is chosen', () async {
    final now = DateTime.now();
    final a = _measured(_server('a'), 10, now);
    final b = _measured(_server('b'), 50, now);
    final (container, _) = await _start([a, b]);
    expect(container.read(effectiveConfigProvider)?.id, 'a');
    await container.read(configProvider.notifier).batchUpdatePingResults({
      a.connectionIdentity: null,
    }, now.add(const Duration(seconds: 1)));
    expect(container.read(effectiveConfigProvider)?.id, 'b');
  });

  test('while probing, the last known latency decides, not a hash', () async {
    final earlier = DateTime.now().subtract(const Duration(minutes: 1));
    final servers = [_server('x'), _server('y')];
    // Give the higher latency to whichever identity sorts first, so a hash
    // tie-break would pick the slower server.
    servers.sort(
      (p, q) => p.connectionIdentity.compareTo(q.connectionIdentity),
    );
    final slow = _measured(servers[0], 90, earlier);
    final fast = _measured(servers[1], 20, earlier);
    final (container, _) = await _start([slow, fast]);
    await container
        .read(configProvider.notifier)
        .markProbes(
          {slow.connectionIdentity, fast.connectionIdentity},
          ProbeStatus.running,
          DateTime.now(),
        );
    expect(container.read(effectiveConfigProvider)?.id, fast.id);
  });

  test('without any measurement the provider order is kept', () async {
    final (container, _) = await _start([
      _server('first'),
      _server('second'),
      _server('third'),
    ]);
    expect(container.read(effectiveConfigProvider)?.id, 'first');
  });

  test('when every probe failed, connect still has a server', () async {
    final now = DateTime.now();
    final (container, _) = await _start([_server('one'), _server('two')]);
    final state = await container.read(configProvider.future);
    await container.read(configProvider.notifier).batchUpdatePingResults({
      for (final c in state.configs) c.connectionIdentity: null,
    }, now);
    expect(container.read(effectiveConfigProvider)?.id, 'one');
  });

  test('empty probe batches do not rewrite the snapshot', () async {
    final (container, secure) = await _start([_server('m')]);
    final before = secure.writes;
    final notifier = container.read(configProvider.notifier);
    await notifier.markProbes({}, ProbeStatus.running, DateTime.now());
    await notifier.batchUpdatePingResults({}, DateTime.now());
    expect(secure.writes, before);
  });

  test('a probe left running by a killed process is reset on start', () async {
    final stuck = _server(
      's',
    ).copyWith(probeStatus: ProbeStatus.running, lastSuccessfulLatencyMs: 30);
    final (container, _) = await _start([stuck]);
    final state = await container.read(configProvider.future);
    expect(state.configs.single.probeStatus, ProbeStatus.unknown);
    expect(state.configs.single.lastSuccessfulLatencyMs, 30);
  });
}
