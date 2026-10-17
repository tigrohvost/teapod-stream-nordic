import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/connections_bundle.dart';
import 'package:teapodstream/core/models/profile.dart';
import 'package:teapodstream/core/models/profile_bundle.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/config_repository.dart';
import 'package:teapodstream/core/services/config_storage_service.dart';
import 'package:teapodstream/core/services/diagnostic_redactor.dart';
import 'package:teapodstream/core/services/import_service.dart';
import 'package:teapodstream/core/services/probe_scheduler.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/core/services/storage_secure_service.dart';
import 'package:teapodstream/core/services/subscription_service.dart';
import 'package:teapodstream/providers/config_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';

VpnConfig config(String id, {String? sub}) => VpnConfig(
  id: id,
  name: id,
  protocol: VpnProtocol.trojan,
  address: '$id.example.test',
  port: 443,
  uuid: '',
  password: 'password-$id',
  security: VpnSecurity.tls,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
  subscriptionId: sub,
  alpn: 'h2,http/1.1',
  pinSHA256: '01' * 32,
  allowInsecure: true,
);

class MemorySecure extends StorageSecureService {
  late String raw;
  bool fail = false;
  MemorySecure(ConfigState initial) {
    seed(initial);
  }
  void seed(ConfigState value) {
    final payload = jsonEncode(value.toJson());
    raw = jsonEncode({
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
  }

  @override
  Future<String?> readConnectionsSnapshot() async => raw;
  @override
  Future<void> writeConnectionsSnapshot(String json) async {
    await Future<void>.delayed(Duration.zero);
    if (fail) throw StateError('simulated write failure');
    raw = json;
  }
}

class Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

class Subscriptions extends SubscriptionService {
  final requests = <Completer<SubscriptionFetchResult>>[];
  @override
  Future<SubscriptionFetchResult> fetchSubscription(
    String url, {
    bool allowSelfSigned = false,
    HwidDeviceInfo? hwid,
    String? userAgent,
  }) {
    final request = Completer<SubscriptionFetchResult>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  test(
    'core validation failure leaves subscription snapshot unchanged',
    () async {
      final initial = ConfigState(
        configs: [config('working', sub: 'sub')],
        subscriptions: [
          Subscription(
            id: 'sub',
            name: 'saved',
            url: 'https://sub.test',
            createdAt: DateTime(2026),
          ),
        ],
      );
      final secure = MemorySecure(initial);
      final remote = Subscriptions();
      final container = ProviderContainer(
        overrides: [
          configRepositoryProvider.overrideWithValue(
            ConfigRepository(secure: secure),
          ),
          subscriptionServiceProvider.overrideWithValue(remote),
          settingsProvider.overrideWith(Settings.new),
          configValidationProvider.overrideWithValue(
            (_) async => throw const FormatException('core rejected'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(configProvider.future);
      final before = secure.raw;
      final refresh = container
          .read(configProvider.notifier)
          .addSubscriptionFromUrl('https://sub.test');
      final rejected = expectLater(refresh, throwsFormatException);
      while (remote.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      remote.requests.single.complete(
        SubscriptionFetchResult(configs: [config('invalid')]),
      );
      await rejected;
      expect(secure.raw, before);
      expect(
        (await container.read(configProvider.future)).configs.single.id,
        'working',
      );
    },
  );

  test(
    'concurrent transactions preserve selection, content and revision',
    () async {
      final secure = MemorySecure(
        ConfigState(configs: [config('one')], activeConfigId: 'one'),
      );
      final first = ConfigRepository(secure: secure),
          second = ConfigRepository(secure: secure);
      await Future.wait([
        first.commit((s) => s.copyWith(configs: [...s.configs, config('two')])),
        second.commit((s) => s.copyWith(activeConfigId: 'two')),
        first.commit(
          (s) => s.copyWith(
            configs: s.configs
                .map((c) => c.id == 'one' ? c.copyWith(name: 'renamed') : c)
                .toList(),
          ),
        ),
      ]);
      final result = await second.load();
      expect(result.revision, 3);
      expect(result.activeConfigId, 'two');
      expect(result.configs.map((c) => c.name), ['renamed', 'two']);
      secure.fail = true;
      await expectLater(
        first.commit((s) => s.copyWith(configs: [])),
        throwsStateError,
      );
      expect((await second.load()).configs.length, 2);
      secure.raw = secure.raw.replaceFirst('renamed', 'tampered');
      await expectLater(second.load(), throwsFormatException);
    },
  );

  test(
    'mixed compact/full import is lossless and identity-idempotent',
    () async {
      final managed = VpnConfig.fromJson({
        ...config('managed').toJson(),
        'rawXrayConfig': jsonEncode({
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'trojan',
              'settings': {
                'servers': [
                  {
                    'address': 'managed.test',
                    'port': 443,
                    'password': 'secret',
                  },
                ],
              },
            },
          ],
        }),
      });
      final original = config('one');
      final sub = Subscription(
        id: 'sub',
        name: 'remote',
        url: 'https://sub.test/token',
        createdAt: DateTime(2026),
      );
      final bundle = ConnectionsBundle(
        exportedAt: DateTime(2026),
        configs: [original, managed],
        subscriptions: [sub],
        rawUris: ['trojan://hello@different.test:443'],
        subscriptionUrls: ['https://other.test/token'],
      );
      final roundTrip = ConnectionsBundle.fromBase64(bundle.toCompactBase64());
      expect(
        roundTrip.configs.map((c) => c.toJson()).toList(),
        bundle.configs.map((c) => c.toJson()).toList(),
      );
      final importer = ImportService(
        fetchSubscription: (_) async =>
            SubscriptionFetchResult(configs: [config('fetched')]),
      );
      final plan = await importer.prepare(roundTrip);
      final (state, report) = ImportService.apply(ConfigState(), plan);
      expect(report.addedConfigs, 4);
      expect(report.addedSubscriptions, 2);
      final (again, duplicate) = ImportService.apply(state, plan);
      expect(again.configs.length, 4);
      expect(duplicate.addedConfigs, 0);
      expect(duplicate.addedSubscriptions, 0);
      expect(
        original.copyWith(name: 'different', id: 'changed').connectionIdentity,
        original.connectionIdentity,
      );
      expect(
        original.copyWith(pinSHA256: 'other').connectionIdentity,
        isNot(original.connectionIdentity),
      );
      expect(
        original.copyWith(allowInsecure: false).connectionIdentity,
        isNot(original.connectionIdentity),
      );
    },
  );

  test('unsupported bundle versions fail before import', () {
    final bundle = ConnectionsBundle(exportedAt: DateTime(2026));
    expect(
      () => ConnectionsBundle.fromJson({...bundle.toJson(), 'version': 99}),
      throwsFormatException,
    );
    final profile = ProfileBundle(
      exportedAt: DateTime(2026),
      profile: Profile(
        id: 'id',
        name: 'name',
        settings: const AppSettings(),
        createdAt: DateTime(2026),
      ),
    );
    expect(
      () => ProfileBundle.fromJson({...profile.toJson(), 'version': 99}),
      throwsFormatException,
    );
    expect(
      () => AppSettings.fromJson({'vpnMode': 'unknown'}),
      throwsFormatException,
    );
  });

  test(
    'late subscription fetch cannot resurrect deletion or beat newer refresh',
    () async {
      final secure = MemorySecure(
        ConfigState(
          configs: [config('old', sub: 'sub')],
          subscriptions: [
            Subscription(
              id: 'sub',
              name: 'local name',
              url: 'https://sub.test',
              createdAt: DateTime(2026),
            ),
          ],
        ),
      );
      final remote = Subscriptions();
      final container = ProviderContainer(
        overrides: [
          configRepositoryProvider.overrideWithValue(
            ConfigRepository(secure: secure),
          ),
          subscriptionServiceProvider.overrideWithValue(remote),
          settingsProvider.overrideWith(Settings.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(configProvider.future);
      final notifier = container.read(configProvider.notifier);
      final older = notifier.addSubscriptionFromUrl('https://sub.test');
      final newer = notifier.addSubscriptionFromUrl('https://sub.test');
      while (remote.requests.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      remote.requests[1].complete(
        SubscriptionFetchResult(
          configs: [config('new')],
          profileTitle: 'server title',
        ),
      );
      await newer;
      remote.requests[0].complete(
        SubscriptionFetchResult(configs: [config('stale')]),
      );
      await older;
      expect(
        (await container.read(configProvider.future)).configs.single.name,
        'new',
      );
      expect(
        (await container.read(configProvider.future)).subscriptions.single.name,
        'local name',
      );
      final delayed = notifier.addSubscriptionFromUrl('https://sub.test');
      while (remote.requests.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      await notifier.removeSubscription('sub');
      remote.requests[2].complete(
        SubscriptionFetchResult(configs: [config('resurrected')]),
      );
      await delayed;
      expect((await container.read(configProvider.future)).configs, isEmpty);
      expect(
        (await container.read(configProvider.future)).subscriptions,
        isEmpty,
      );
    },
  );

  test(
    'failed probe clears current latency and preserves last success',
    () async {
      final now = DateTime.now();
      final c = config('one').copyWith(
        latencyMs: 42,
        lastPingedAt: now,
        probeStatus: ProbeStatus.success,
        lastSuccessfulLatencyMs: 42,
        lastSuccessfulPingAt: now,
      );
      final container = ProviderContainer(
        overrides: [
          configRepositoryProvider.overrideWithValue(
            ConfigRepository(
              secure: MemorySecure(
                ConfigState(configs: [c], activeConfigId: c.id),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(configProvider.future);
      await container.read(configProvider.notifier).batchUpdatePingResults({
        c.connectionIdentity: null,
      }, now.add(const Duration(seconds: 1)));
      final result = (await container.read(
        configProvider.future,
      )).configs.single;
      expect(result.latencyMs, isNull);
      expect(result.probeStatus, ProbeStatus.failed);
      expect(result.lastSuccessfulLatencyMs, 42);
      expect(result.hasFreshProbe(now), isFalse);
      expect(
        container.read(effectiveConfigProvider)?.id,
        c.id,
      ); // Manual choice remains.
    },
  );

  test(
    'probe work is bounded and cancellation discards late completions',
    () async {
      final scheduler = ProbeScheduler(concurrency: 3);
      var active = 0, peak = 0, scheduled = 0;
      final gate = Completer<void>();
      final batch = scheduler.run({for (var i = 0; i < 40; i++) '$i': i}, (
        int _,
      ) async {
        active++;
        scheduled++;
        if (active > peak) peak = active;
        await gate.future;
        active--;
        return 30;
      });
      expect(peak, 3);
      scheduler.cancel();
      gate.complete();
      expect(await batch, isNull);
      expect(scheduled, 3);
      expect(active, 0);
    },
  );

  test('diagnostics strip URLs, credentials, key material, IPs and UUIDs', () {
    const input =
        'https://host.test/sub/secret?token=query vless://uuid@host:443 '
        'password="password with spaces" socksUser: login token=tokenvalue '
        '127.0.0.1 [2001:db8::1] 00000000-0000-4000-8000-000000000001 '
        '-----BEGIN PRIVATE KEY-----\nPRIVATE-MATERIAL\n-----END PRIVATE KEY-----\nknown-domain.test';
    final result = DiagnosticRedactor.redact(
      input,
      secrets: ['known-domain.test'],
    );
    for (final secret in [
      'host.test',
      'password with spaces',
      'login',
      'tokenvalue',
      '127.0.0.1',
      '2001:db8',
      '00000000-',
      'PRIVATE-MATERIAL',
      'known-domain.test',
    ]) {
      expect(result, isNot(contains(secret)), reason: secret);
    }
  });
}
