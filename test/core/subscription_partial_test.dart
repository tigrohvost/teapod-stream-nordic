import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/config_repository.dart';
import 'package:teapodstream/core/services/config_storage_service.dart';
import 'package:teapodstream/core/services/log_service.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/core/services/storage_secure_service.dart';
import 'package:teapodstream/core/services/subscription_service.dart';
import 'package:teapodstream/providers/config_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';

class _Secure extends StorageSecureService {
  String? raw;
  _Secure(ConfigState initial) {
    final payload = jsonEncode(initial.toJson());
    raw = jsonEncode({
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
    });
  }
  @override
  Future<String?> readConnectionsSnapshot() async => raw;
  @override
  Future<void> writeConnectionsSnapshot(String json) async => raw = json;
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

class _Remote extends SubscriptionService {
  Object Function() next;
  _Remote(this.next);
  @override
  Future<SubscriptionFetchResult> fetchSubscription(
    String url, {
    bool allowSelfSigned = false,
    HwidDeviceInfo? hwid,
    String? userAgent,
  }) async {
    final value = next();
    if (value is SubscriptionFetchResult) return value;
    throw value;
  }
}

VpnConfig _trojan(String name) => VpnConfig(
  id: name,
  name: name,
  protocol: VpnProtocol.trojan,
  address: '$name.example.test',
  port: 443,
  uuid: '',
  password: 'secret-$name',
  security: VpnSecurity.tls,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
);

Future<String> _serve(String body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    request.response.write(body);
    await request.response.close();
  });
  return 'http://127.0.0.1:${server.port}/sub';
}

void main() {
  test(
    'unsupported and malformed lines are skipped, comments ignored',
    () async {
      final url = await _serve(
        [
          '#profile-title: Provider',
          'trojan://secret@good.example.test:443',
          'tuic://uuid:pass@other.example.test:443',
          'invalid://entry',
          'vless://@empty-uuid.example.test:443',
        ].join('\n'),
      );
      final result = await SubscriptionService().fetchSubscription(url);
      expect(result.configs.map((c) => c.address), ['good.example.test']);
      expect(result.skippedItems, 3);
    },
  );

  test('a document without any usable entry is still rejected', () async {
    final url = await _serve('tuic://uuid:pass@x.example.test:443\nnope');
    await expectLater(
      SubscriptionService().fetchSubscription(url),
      throwsFormatException,
    );
  });

  test('one bad managed item does not discard the others', () async {
    final good = {
      'remarks': 'good',
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'trojan',
          'settings': {
            'servers': [
              {'address': 'managed.example.test', 'port': 443, 'password': 'p'},
            ],
          },
        },
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    };
    final url = await _serve(
      jsonEncode([
        good,
        'not an object',
        {'remarks': 'empty', 'outbounds': []},
      ]),
    );
    final result = await SubscriptionService().fetchSubscription(url);
    expect(result.configs.single.name, 'good');
    expect(result.skippedItems, 2);
  });

  test(
    'refresh keeps entries the core accepts and reports the rejected ones',
    () async {
      final secure = _Secure(ConfigState());
      final container = ProviderContainer(
        overrides: [
          configRepositoryProvider.overrideWithValue(
            ConfigRepository(secure: secure),
          ),
          subscriptionServiceProvider.overrideWithValue(
            _Remote(
              () => SubscriptionFetchResult(
                configs: [_trojan('accepted'), _trojan('rejected')],
                skippedItems: 1,
              ),
            ),
          ),
          settingsProvider.overrideWith(_Settings.new),
          configValidationProvider.overrideWithValue((config) async {
            if (config.name == 'rejected') {
              throw const FormatException('core rejected');
            }
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(configProvider.future);
      final result = await container
          .read(configProvider.notifier)
          .addSubscriptionFromUrl('https://sub.example.test/s');
      expect(result.configs, 1);
      expect(result.skipped, 2);
      final state = await container.read(configProvider.future);
      expect(state.configs.map((c) => c.name), ['accepted']);
    },
  );

  test('a failed background refresh is logged and keeps old data', () async {
    final initial = ConfigState(
      configs: [_trojan('working').copyWith(subscriptionId: 'sub')],
      subscriptions: [
        Subscription(
          id: 'sub',
          name: 'Provider',
          url: 'https://sub.example.test/s',
          createdAt: DateTime(2026),
        ),
      ],
    );
    final secure = _Secure(initial);
    final container = ProviderContainer(
      overrides: [
        configRepositoryProvider.overrideWithValue(
          ConfigRepository(secure: secure),
        ),
        subscriptionServiceProvider.overrideWithValue(
          _Remote(() => const SocketException('unreachable')),
        ),
        settingsProvider.overrideWith(_Settings.new),
        configValidationProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    container.listen(logServiceProvider, (_, _) {});
    await container.read(configProvider.future);
    await container.read(configProvider.notifier).refreshStaleSubscriptions();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final logs = container.read(logServiceProvider);
    expect(
      logs.map((e) => e.message),
      contains(contains('Не удалось обновить подписку «Provider»')),
    );
    final state = await container.read(configProvider.future);
    expect(state.configs.single.name, 'working');
  });
}
