import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/routing_settings.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/subscription_service.dart';
import 'package:teapodstream/protocols/xray/xray_config_builder.dart';

Map<String, dynamic> _proxy({String? tag, Map<String, dynamic>? tls}) => {
  'tag': ?tag,
  'protocol': 'trojan',
  'settings': {
    'servers': [
      {'address': 'managed.example.test', 'port': 443, 'password': 'p'},
    ],
  },
  'streamSettings': {'security': 'tls', 'tlsSettings': ?tls},
};

VpnConfig _managed(Map<String, dynamic> raw) => VpnConfig(
  id: 'm',
  name: 'managed',
  protocol: VpnProtocol.vless,
  address: 'managed.example.test',
  port: 443,
  uuid: '',
  security: VpnSecurity.none,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
  rawXrayConfig: jsonEncode(raw),
);

VpnEngineOptions _options([
  RoutingSettings routing = const RoutingSettings(),
]) => VpnEngineOptions(
  socksPort: 10808,
  httpPort: 0,
  socksUser: 'u',
  socksPassword: 'p',
  routing: routing,
);

Map<String, dynamic> _merged(VpnConfig config, [VpnEngineOptions? options]) =>
    jsonDecode(XrayConfigBuilder.plan(config, options ?? _options()).xrayJson)
        as Map<String, dynamic>;

void main() {
  test('echSettings is dropped and reported, not fatal', () {
    final config = _managed({
      'outbounds': [
        _proxy(
          tag: 'proxy',
          tls: {
            'serverName': 'managed.example.test',
            'echSettings': {'enable': true},
          },
        ),
        {'tag': 'direct', 'protocol': 'freedom'},
      ],
    });
    final plan = XrayConfigBuilder.plan(config, _options());
    expect(plan.unsupportedSettings, contains('echSettings'));
    expect(plan.xrayJson, isNot(contains('echSettings')));
  });

  test('the old pin key is still refused (pinning must not be lost)', () {
    final config = _managed({
      'outbounds': [
        _proxy(tag: 'proxy', tls: {'pinnedPeerCertificateChainSha256': 'aa'}),
      ],
    });
    expect(
      () => XrayConfigBuilder.plan(config, _options()),
      throwsA(isA<Exception>()),
    );
  });

  test('an untagged default outbound is a valid proxy target', () {
    final cfg = _merged(
      _managed({
        'outbounds': [
          _proxy(),
          {'tag': 'direct', 'protocol': 'freedom'},
          {'protocol': 'blackhole'},
        ],
      }),
    );
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    final first = outbounds.first;
    expect(first['protocol'], 'trojan');
    expect(first['tag'], isA<String>());
    final tags = outbounds.map((o) => o['tag']).toSet();
    for (final rule in ((cfg['routing'] as Map)['rules'] as List).cast<Map>()) {
      if (rule['outboundTag'] != null) {
        expect(tags, contains(rule['outboundTag']));
      }
    }
  });

  test('only-selected keeps the server blocking rules ahead of direct', () {
    final cfg = _merged(
      _managed({
        'outbounds': [
          _proxy(tag: 'proxy'),
          {'tag': 'direct', 'protocol': 'freedom'},
          {'tag': 'block', 'protocol': 'blackhole'},
        ],
        'routing': {
          'rules': [
            {
              'type': 'field',
              'domain': ['domain:tracker.example.test'],
              'outboundTag': 'block',
            },
            {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
          ],
        },
      }),
      _options(
        const RoutingSettings(
          direction: RoutingDirection.onlySelected,
          sitesEnabled: true,
          sites: ['selected.example.test'],
        ),
      ),
    );
    final rules = ((cfg['routing'] as Map)['rules'] as List).cast<Map>();
    final block = rules.indexWhere((r) => r['outboundTag'] == 'block');
    final catchAll = rules.indexWhere(
      (r) =>
          r['outboundTag'] == 'direct' &&
          r['inboundTag'] != null &&
          r['domain'] == null &&
          r['ip'] == null &&
          r['port'] == null,
    );
    expect(block, isNonNegative);
    expect(catchAll, isNonNegative);
    expect(block, lessThan(catchAll));
  });

  test('subscription fetch keeps the typed managed error', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write(
        jsonEncode([
          {
            'remarks': 'old',
            'outbounds': [
              _proxy(
                tag: 'proxy',
                tls: {'pinnedPeerCertificateChainSha256': 'aa'},
              ),
            ],
          },
        ]),
      );
      await request.response.close();
    });
    await expectLater(
      SubscriptionService().fetchSubscription(
        'http://127.0.0.1:${server.port}/s',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('TLS pin'),
        ),
      ),
    );
  });
}
