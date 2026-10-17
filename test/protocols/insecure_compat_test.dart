import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/protocols/xray/vless_parser.dart';
import 'package:teapodstream/protocols/xray/xray_config_builder.dart';

const _options = VpnEngineOptions(
  socksPort: 10808,
  httpPort: 0,
  socksUser: 'u',
  socksPassword: 'p',
);

Map<String, dynamic> _tls(VpnConfig config) {
  final json =
      jsonDecode(XrayConfigBuilder.plan(config, _options).xrayJson)
          as Map<String, dynamic>;
  final proxy = (json['outbounds'] as List).first as Map<String, dynamic>;
  return (proxy['streamSettings'] as Map<String, dynamic>)['tlsSettings']
      as Map<String, dynamic>;
}

void main() {
  // Saved v1.6.6 configs carry allowInsecure from their share links; they
  // connected with normal verification and must keep doing so.
  for (final uri in [
    'vless://11111111-2222-3333-4444-555555555555@v.example.test:443'
        '?security=tls&sni=v.example.test&allowInsecure=1#v',
    'trojan://secret@t.example.test:443?security=tls&allowInsecure=1#t',
    'hysteria2://secret@h.example.test:443?insecure=1&sni=h.example.test#h',
  ]) {
    test(
      'insecure without pin is ignored, not fatal: ${uri.split(':').first}',
      () {
        final config = VlessParser.parseUri(uri)!;
        expect(config.allowInsecure, isTrue);
        final plan = XrayConfigBuilder.plan(config, _options);
        expect(plan.unsupportedSettings, contains('allowInsecure'));
        final tls = _tls(config);
        expect(tls['allowInsecure'], isFalse);
        expect(tls.containsKey('pinnedPeerCertSha256'), isFalse);
      },
    );
  }

  test('insecure together with a pin keeps the pin and is not reported', () {
    final config = VlessParser.parseUri(
      'trojan://secret@t.example.test:443?security=tls&allowInsecure=1#t',
    )!.copyWith(pinSHA256: 'ab' * 32);
    final plan = XrayConfigBuilder.plan(config, _options);
    expect(plan.unsupportedSettings, isNot(contains('allowInsecure')));
    expect(_tls(config)['pinnedPeerCertSha256'], 'ab' * 32);
  });
}
