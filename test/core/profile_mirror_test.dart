import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teapodstream/core/models/profile.dart';
import 'package:teapodstream/core/models/profile_bundle.dart';
import 'package:teapodstream/core/services/profile_storage_service.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/providers/profile_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes HTTP; this test serves the profile on loopback.
  HttpOverrides.global = null;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'auto_start_on_boot': false});
  });

  test(
    'refreshing the active profile updates the boot preference mirror',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final url = 'http://127.0.0.1:${server.port}/profile';
      server.listen((request) async {
        final bundle = ProfileBundle(
          exportedAt: DateTime(2026),
          profile: Profile(
            id: 'remote',
            name: 'Remote',
            settings: const AppSettings(autoStartOnBoot: true),
            createdAt: DateTime(2026),
          ),
        );
        request.response.write(jsonEncode(bundle.toJson()));
        await request.response.close();
      });
      await ProfileStorageService().commit(
        (s) => (
          profiles: [
            Profile(
              id: 'p',
              name: 'Remote',
              isDefault: true,
              settings: const AppSettings(),
              createdAt: DateTime(2026),
              sourceUrl: url,
            ),
          ],
          activeProfileId: 'p',
          revision: s.revision,
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(profileProvider.future);
      expect(
        await container.read(profileProvider.notifier).refreshProfile('p', url),
        'p',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('auto_start_on_boot'), isTrue);
    },
  );
}
