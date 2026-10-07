import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/providers/config_provider.dart';

VpnConfig _cfg(String id, String name, String address, {int port = 443}) => VpnConfig(
      id: id,
      name: name,
      protocol: VpnProtocol.vless,
      address: address,
      port: port,
      uuid: 'uuid',
      security: VpnSecurity.tls,
      transport: VpnTransport.tcp,
      createdAt: DateTime(2026),
      subscriptionId: 'sub',
    );

void main() {
  group('matchRefreshedConfig', () {
    final selected = _cfg('old-id', 'Frankfurt', 'de.example.com');

    test('finds the same server under its new id', () {
      final fresh = [
        _cfg('n1', 'Amsterdam', 'nl.example.com'),
        _cfg('n2', 'Frankfurt', 'de.example.com'),
      ];
      expect(ConfigNotifier.matchRefreshedConfig(selected, fresh)?.id, 'n2');
    });

    test('falls back to the name when the endpoint moved', () {
      final fresh = [
        _cfg('n1', 'Amsterdam', 'nl.example.com'),
        _cfg('n2', 'Frankfurt', 'de2.example.com'),
      ];
      expect(ConfigNotifier.matchRefreshedConfig(selected, fresh)?.id, 'n2');
    });

    test('falls back to the endpoint when the server was renamed', () {
      final fresh = [
        _cfg('n1', 'Amsterdam', 'nl.example.com'),
        _cfg('n2', 'DE-1', 'de.example.com'),
      ];
      expect(ConfigNotifier.matchRefreshedConfig(selected, fresh)?.id, 'n2');
    });

    test('returns null when the server is gone', () {
      final fresh = [_cfg('n1', 'Amsterdam', 'nl.example.com')];
      expect(ConfigNotifier.matchRefreshedConfig(selected, fresh), isNull);
    });
  });
}
