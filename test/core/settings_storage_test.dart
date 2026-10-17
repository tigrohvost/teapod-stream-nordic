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
}
