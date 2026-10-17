import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/connections_bundle.dart';
import 'package:teapodstream/core/models/routing_settings.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/protocols/xray/vless_parser.dart';
import 'package:teapodstream/protocols/xray/xray_config_builder.dart';

const options = VpnEngineOptions(
  socksPort: 10808,
  httpPort: 0,
  socksUser: 'test',
  socksPassword: 'test',
);

void main() {
  test('copy and export preserve every extended connection field', () {
    final full = VpnConfig(
      id: 'roundtrip',
      name: 'fixture',
      protocol: VpnProtocol.vless,
      address: 'fixture.test',
      port: 443,
      uuid: 'account',
      security: VpnSecurity.tls,
      transport: VpnTransport.xhttp,
      createdAt: DateTime(2026),
      sni: 'fixture.test',
      wsPath: '/path',
      wsHost: 'host.test',
      grpcServiceName: 'service',
      fingerprint: 'chrome',
      publicKey: 'public',
      shortId: '01',
      spiderX: '/',
      postQuantumKey: 'pqv',
      flow: 'xtls-rprx-vision',
      encryption: 'none',
      alterId: '0',
      method: 'aes-128-gcm',
      password: 'fixture-password',
      ssPrefix: '0102',
      obfsPassword: 'fixture-obfs',
      allowInsecure: true,
      pinSHA256: '01' * 32,
      xhttpMode: 'auto',
      xhttpExtra: {
        'headers': {'x-fixture': 'value'},
      },
      finalmask: {
        'fixture': [1, 2],
      },
      alpn: 'h2,http/1.1',
      ech: 'test-config-list',
    );
    final copied = full.copyWith(name: 'renamed');
    expect(copied.toJson(), {...full.toJson(), 'name': 'renamed'});
    final bundle = ConnectionsBundle(
      exportedAt: DateTime(2026),
      configs: [copied],
    );
    expect(
      ConnectionsBundle.fromBase64(
        bundle.toCompactBase64(),
      ).configs.single.toJson(),
      copied.toJson(),
    );
    final out =
        (XrayConfigBuilder.build(copied, options)['outbounds'] as List).first
            as Map;
    final stream = out['streamSettings'] as Map;
    expect((stream['tlsSettings'] as Map)['alpn'], ['h2', 'http/1.1']);
    expect((stream['tlsSettings'] as Map)['echConfigList'], full.ech);
    expect(stream['finalmask'], full.finalmask);
    expect((stream['xhttpSettings'] as Map)['extra'], full.xhttpExtra);
  });

  final config = VlessParser.parseUri(
    'vless://account@example.com:443?security=tls',
  )!;
  for (final direction in RoutingDirection.values) {
    for (var mask = 1; mask < 32; mask++) {
      test('TSN-001 $direction independent routing categories $mask', () {
        final routing = RoutingSettings(
          direction: direction,
          bypassLocal: false,
          sitesEnabled: mask & 1 != 0,
          sites: ['example.com'],
          ruServicesEnabled: mask & 2 != 0,
          geoEnabled: mask & 4 != 0,
          geoCodes: ['RU'],
          domainEnabled: mask & 8 != 0,
          domainZones: ['su'],
          geositeEnabled: mask & 16 != 0,
          geositeCodes: ['test'],
        );
        final built = XrayConfigBuilder.build(
          config,
          VpnEngineOptions(
            socksPort: 10808,
            httpPort: 0,
            socksUser: '',
            socksPassword: '',
            routing: routing,
          ),
        );
        final rules = ((built['routing'] as Map)['rules'] as List).cast<Map>();
        expect(
          (built['routing'] as Map)['domainStrategy'],
          direction != RoutingDirection.global && mask & 4 != 0
              ? 'IPOnDemand'
              : 'IPIfNonMatch',
        );
        for (final (bit, field, value) in [
          (1, 'domain', 'domain:example.com'),
          (2, 'domain', 'domain:gosuslugi.ru'),
          (4, 'ip', 'geoip:ru'),
          (8, 'domain', 'domain:su'),
          (16, 'domain', 'geosite:test'),
        ]) {
          final matches = rules.where(
            (r) => (r[field] as List? ?? []).contains(value),
          );
          if (direction == RoutingDirection.global || mask & bit == 0) {
            expect(matches, isEmpty);
          } else {
            expect(
              matches.single['outboundTag'],
              direction == RoutingDirection.bypass ? 'direct' : 'proxy',
            );
          }
        }
        expect(
          rules.last['outboundTag'],
          direction == RoutingDirection.onlySelected ? 'direct' : 'proxy',
        );
      });
    }
  }

  test('TSN-004 VLESS TLS pin reaches the consumer', () {
    final c = config.copyWith(pinSHA256: '01' * 32, allowInsecure: true);
    final outbound =
        (XrayConfigBuilder.build(c, options)['outbounds'] as List).first as Map;
    final tls = (outbound['streamSettings'] as Map)['tlsSettings'] as Map;
    expect(tls['pinnedPeerCertSha256'], '01' * 32);
    expect(tls.containsKey('pinnedPeerCertificateChainSha256'), isFalse);
    expect(tls['allowInsecure'], isFalse);
  });

  test('TSN-004 compact preserves managed config', () {
    final c = VpnConfig.fromJson({
      ...config.toJson(),
      'rawUri': null,
      'rawXrayConfig': '{"outbounds":[{"protocol":"freedom"}]}',
    });
    final bundle = ConnectionsBundle(exportedAt: DateTime(2026), configs: [c]);
    final roundTrip = ConnectionsBundle.fromBase64(bundle.toCompactBase64());
    expect(roundTrip.configs.single.toJson(), c.toJson());
  });

  test('TSN-007 query parameters are decoded once', () {
    for (final (encoded, expected) in [
      ('%2Ffoo%252Fbar', '/foo%2Fbar'),
      ('%2F100%25', '/100%'),
    ]) {
      final c = VlessParser.parseUri(
        'vless://account@example.com:443?type=ws&path=$encoded',
      );
      expect(c?.wsPath, expected);
    }
    expect(
      VlessParser.parseUri('trojan://p%40ss%2525@example.com:443')?.password,
      'p@ss%25',
    );
  });

  test('TSN-007 rejects unsupported and incomplete URIs', () {
    for (final uri in [
      'vless://@example.com:443',
      'vless://id@example.com:wrong',
      'vless://id@example.com:443?security=unknown',
      'vless://id@example.com:443?type=unknown',
      'trojan://@example.com:443',
    ]) {
      expect(VlessParser.parseUri(uri), isNull, reason: uri);
    }
  });

  test('TSN-011 failed probe clears the old latency', () {
    expect(
      config.copyWith(latencyMs: 10).copyWith(latencyMs: null).latencyMs,
      isNull,
    );
  });
}
