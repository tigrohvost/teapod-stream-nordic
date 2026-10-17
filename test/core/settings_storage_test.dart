import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teapodstream/core/models/profile.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/core/services/profile_storage_service.dart';
import 'package:teapodstream/core/services/storage_secure_service.dart';
import 'package:teapodstream/core/services/storage_migration_service.dart';

class _FailingMigration extends StorageSecureService {
  @override
  Future<void> writeConfigsRaw(String json) async =>
      throw StateError('storage unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'real settings save/load keeps custom geo sources and private credentials in atomic profile',
    () async {
      const settings = AppSettings(
        geoipUrl: 'https://owned.test/ip?token=secret',
        geositeUrl: 'https://owned.test/site?token=secret',
        socksUser: 'test-user',
        socksPassword: 'test-pass',
        ipLookupEnabled: false,
      );
      await SettingsService().save(settings);
      expect((await SettingsService().load()).toJson(), settings.toJson());
      // Legacy preferences cannot override a successfully committed profile.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('geoip_url', 'https://stale.test/ip');
      expect((await SettingsService().load()).geoipUrl, settings.geoipUrl);
      expect(
        (await ProfileStorageService().load()).profiles.single.settings
            .toJson(),
        settings.toJson(),
      );
    },
  );

  test(
    'concurrent field edits and profile switch preserve both profiles',
    () async {
      const base = AppSettings();
      final storage = ProfileStorageService();
      await storage.commit(
        (s) => (
          profiles: [
            for (final id in ['a', 'b'])
              Profile(
                id: id,
                name: id,
                settings: base,
                createdAt: DateTime(2026),
              ),
          ],
          activeProfileId: 'a',
          revision: s.revision,
        ),
      );
      await Future.wait([
        SettingsService().save(
          base.copyWith(geoipUrl: 'https://owned.test/ip'),
          profileId: 'a',
          base: base,
        ),
        storage.commit(
          (s) => (
            profiles: s.profiles,
            activeProfileId: 'b',
            revision: s.revision,
          ),
        ),
        SettingsService().save(
          base.copyWith(geositeUrl: 'https://owned.test/site'),
          profileId: 'a',
          base: base,
        ),
      ]);
      final snapshot = await storage.load();
      final a = snapshot.profiles.first.settings;
      expect(a.geoipUrl, 'https://owned.test/ip');
      expect(a.geositeUrl, 'https://owned.test/site');
      expect(snapshot.activeProfileId, 'b');
      expect((await SettingsService().load()).toJson(), base.toJson());
    },
  );

  test(
    'failed migration keeps legacy data and can retry without process restart',
    () async {
      SharedPreferences.setMockInitialValues({
        'vpn_configs': ['{"id":"fixture"}'],
      });
      await expectLater(
        StorageMigrationService.runIfNeeded(secure: _FailingMigration()),
        throwsStateError,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('vpn_configs'), isNotEmpty);
      expect(prefs.getBool('storage_migrated_v2'), isNull);
      await StorageMigrationService.runIfNeeded();
      expect(
        await StorageSecureService().readConfigsRaw(),
        '[{"id":"fixture"}]',
      );
      expect(prefs.getStringList('vpn_configs'), isNull);
    },
  );

  test(
    'v1.6.6 profile with unknown and out-of-range values still loads',
    () async {
      // v1.6.6 imported profile bundles without range checks.
      FlutterSecureStorage.setMockInitialValues({
        'profiles_v1': jsonEncode([
          {
            'id': 'default',
            'name': 'Main',
            'isDefault': true,
            'createdAt': '2026-01-01T00:00:00.000',
            'settings': {
              'vpnMode': 'everythingButBanks',
              'mtu': 100000,
              'socksPort': 0,
              'subAutoRefreshHours': '6',
              'geoipUrl': 'https://owned.test/geoip.dat',
              'killSwitchEnabled': true,
            },
          },
        ]),
      });
      final settings = await SettingsService().load();
      expect(settings.vpnMode, const AppSettings().vpnMode);
      expect(settings.mtu, 9000);
      expect(settings.socksPort, 1);
      expect(settings.subAutoRefreshHours, 6);
      // Valid values next to the bad ones are kept.
      expect(settings.geoipUrl, 'https://owned.test/geoip.dat');
      expect(settings.killSwitchEnabled, isTrue);
      expect(
        ProfileStorageService.takeLoadIssues(),
        contains(contains('vpnMode')),
      );
    },
  );
}
