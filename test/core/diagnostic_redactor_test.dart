import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/services/diagnostic_redactor.dart';

void main() {
  group('DiagnosticRedactor', () {
    test('removes transport secrets from realistic xray/native log lines', () {
      const log = '''
2026/10/17 18:49:59.123456 [Warning] [1234567] app/proxyman/outbound: failed to process outbound traffic > proxy/vless/outbound: failed to find an available destination > common/retry: [transport/internet/websocket: failed to dial WebSocket > transport/internet/websocket: failed to dial to (wss://cdn.example.org/s3cr3tPath?ed=2048): 403 Forbidden] > common/retry: all retry attempts failed
18:50:01 I/Teapod: config {"wsSettings": {"path": "/s3cr3tPath", "host": "front.example.org"}, "wsPath": "/s3cr3tPath", "wsHost": "front.example.org", "grpcServiceName": "hiddenGrpc", "realitySettings": {"shortIds": ["abcd1234", "ef56"], "shortId": "abcd1234"}, "postQuantumKey": "pqv-material", "user": "socks-login", "pass": "socks-pass"}
18:50:02 I/Teapod: GET /sub Authorization: Bearer eyJhbGciOi.payload.sig
18:50:03 I/Teapod: ws://plain.example.org/ws-secret upgrade failed
''';
      final result = DiagnosticRedactor.redact(log);
      for (final secret in [
        'cdn.example.org',
        's3cr3tPath',
        'front.example.org',
        'hiddenGrpc',
        'abcd1234',
        'ef56',
        'pqv-material',
        'socks-login',
        'socks-pass',
        'eyJhbGciOi',
        'payload.sig',
        'plain.example.org',
        'ws-secret',
      ]) {
        expect(result, isNot(contains(secret)), reason: secret);
      }
    });

    test('keeps timestamps and harmless keys readable', () {
      const log =
          '2026/10/17 18:49:59.123456 [Info] bypass=true sessionId=42 pid=3170 valid: yes\n'
          '18:50:01 heartbeat ok, next check in 00:00:30';
      final result = DiagnosticRedactor.redact(log);
      expect(result, contains('18:49:59.123456'));
      expect(result, contains('18:50:01'));
      expect(result, contains('00:00:30'));
      expect(result, contains('bypass=true'));
      expect(result, contains('sessionId=42'));
      expect(result, contains('pid=3170'));
      expect(result, contains('valid: yes'));
    });

    test('still redacts real IPv6 addresses', () {
      final result = DiagnosticRedactor.redact(
        'dial [2001:db8::1]:443 and fe80::1%wlan0 and ::1',
      );
      expect(result, isNot(contains('2001:db8')));
      expect(result, isNot(contains('fe80')));
      expect(result, contains('[IP]'));
    });

    test('collects server identities from managed xray JSON', () {
      const json = '''
{"outbounds": [
  {"tag": "proxy", "protocol": "vless",
   "settings": {"vnext": [{"address": "managed.example.net", "port": 443,
     "users": [{"id": "11111111-2222-4333-8444-555555555555"}]}]},
   "streamSettings": {"network": "ws", "security": "tls",
     "tlsSettings": {"serverName": "sni.example.net"},
     "wsSettings": {"path": "/managed-path", "headers": {"Host": "ws.example.net"}}}},
  {"tag": "ss", "protocol": "shadowsocks",
   "settings": {"servers": [{"address": "ss.example.net", "password": "ss-pass"}]}},
  {"tag": "direct", "protocol": "freedom"}
]}''';
      final secrets = DiagnosticRedactor.secretsFromXrayJson(json);
      expect(
        secrets,
        containsAll([
          'managed.example.net',
          'sni.example.net',
          '/managed-path',
          'ws.example.net',
          'ss.example.net',
          'ss-pass',
        ]),
      );
      expect(secrets, isNot(contains('direct')));
      expect(DiagnosticRedactor.secretsFromXrayJson('not json'), isEmpty);
    });
  });
}
