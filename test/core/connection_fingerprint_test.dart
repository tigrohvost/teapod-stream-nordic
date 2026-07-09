import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/connection_fingerprint.dart';
import 'package:teapodstream/core/services/settings_service.dart';

void main() {
  group('connectionFingerprint', () {
    test('идентичен для одинаковых настроек', () {
      expect(connectionFingerprint(const AppSettings()),
          connectionFingerprint(const AppSettings()));
    });

    test('меняется при изменении connection-полей', () {
      const base = AppSettings();
      expect(connectionFingerprint(base.copyWith(mtu: 1400)),
          isNot(connectionFingerprint(base)));
      expect(connectionFingerprint(base.copyWith(killSwitchEnabled: true)),
          isNot(connectionFingerprint(base)));
      expect(connectionFingerprint(base.copyWith(splitTunnelingEnabled: true)),
          isNot(connectionFingerprint(base)));
    });

    test('не меняется от косметических полей', () {
      const base = AppSettings();
      expect(connectionFingerprint(base.copyWith(fontScale: FontScale.large)),
          connectionFingerprint(base));
      expect(connectionFingerprint(base.copyWith(autoConnect: true)),
          connectionFingerprint(base));
      expect(connectionFingerprint(base.copyWith(subUserAgent: 'x')),
          connectionFingerprint(base));
    });

    test('возврат значения восстанавливает fingerprint', () {
      const base = AppSettings();
      final changed = base.copyWith(enableUdp: !base.enableUdp);
      final reverted = changed.copyWith(enableUdp: base.enableUdp);
      expect(connectionFingerprint(reverted), connectionFingerprint(base));
    });

    test('set-поля не зависят от порядка', () {
      final a = const AppSettings().copyWith(excludedPackages: {'b', 'a'});
      final b = const AppSettings().copyWith(excludedPackages: {'a', 'b'});
      expect(connectionFingerprint(a), connectionFingerprint(b));
    });
  });
}
