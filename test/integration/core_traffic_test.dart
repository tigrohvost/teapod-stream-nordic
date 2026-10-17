import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/dns_config.dart';
import 'package:teapodstream/core/models/routing_settings.dart';
import 'package:teapodstream/protocols/xray/vless_parser.dart';
import 'package:teapodstream/protocols/xray/xray_config_builder.dart';

void main() {
  final binary = Platform.environment['XRAY_TEST_BINARY'];
  test(
    'generated routing and TLS policy controls real loopback traffic',
    () async {
      final dir = await Directory.systemTemp.createTemp('core-traffic-');
      addTearDown(() => dir.delete(recursive: true));
      final config = VlessParser.parseUri(
        'trojan://fixture-secret@127.0.0.1:19001?security=tls&sni=localhost&pinSHA256=${'01' * 32}',
      )!;
      final fixtures = <Map<String, dynamic>>[];
      for (final managed in [false, true]) {
        for (final direction in RoutingDirection.values) {
          for (final category in ['sites', 'ru', 'geoip', 'zone', 'geosite']) {
            final routing = RoutingSettings(
              direction: direction,
              sitesEnabled: category == 'sites',
              sites: ['selected.test'],
              ruServicesEnabled: category == 'ru',
              geoEnabled: category == 'geoip',
              geoCodes: ['test'],
              domainEnabled: category == 'zone',
              domainZones: ['selected.test'],
              geositeEnabled: category == 'geosite',
              geositeCodes: ['test'],
            );
            final options = VpnEngineOptions(
              socksPort: 19002,
              httpPort: 0,
              socksUser: '',
              socksPassword: '',
              dnsMode: DnsMode.direct,
              routing: routing,
              sniffingEnabled: false,
            );
            final base = XrayConfigBuilder.build(config, options);
            if (managed) {
              base['routing'] = {
                'rules': [
                  {
                    'type': 'field',
                    'inboundTag': ['socks-in'],
                    'outboundTag': 'proxy',
                  },
                ],
              };
              // The conflicting name must never acquire blackhole semantics by name alone.
              (base['outbounds'] as List).add({
                'tag': 'teapod-blackhole',
                'protocol': 'freedom',
              });
            }
            final json = managed
                ? jsonDecode(
                    XrayConfigBuilder.mergeWithRaw(jsonEncode(base), options),
                  )
                : base;
            fixtures.add({
              'name':
                  '${managed ? 'managed' : 'ordinary'}-${direction.name}-$category',
              'config': json,
              'selected': category == 'ru' ? 'gosuslugi.ru' : 'selected.test',
              'expectedSelected': direction == RoutingDirection.bypass
                  ? '127.0.0.2'
                  : '127.0.0.3',
              'expectedOther': direction == RoutingDirection.onlySelected
                  ? '127.0.0.2'
                  : '127.0.0.3',
            });
          }
        }
      }
      final path = '${dir.path}/fixtures.json';
      await File(path).writeAsString(jsonEncode(fixtures));
      final result = await Process.run('python3', [
        'tools/test_core_traffic.py',
        '--xray',
        binary!,
        '--fixtures',
        path,
      ]);
      // Contains fixture names/loopback addresses only, never imported user data.
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      // ignore: avoid_print
      print(result.stdout);
    },
    skip: binary == null
        ? 'Set XRAY_TEST_BINARY to test the real core with owned loopback endpoints'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
