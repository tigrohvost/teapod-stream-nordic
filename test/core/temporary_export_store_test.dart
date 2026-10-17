import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/profile.dart';
import 'package:teapodstream/core/models/profile_bundle.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/core/services/temporary_export_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('teapod_export_test');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File touch(String path, Duration age) {
    final file = File('${root.path}/$path')..createSync(recursive: true);
    file.writeAsStringSync('secret');
    file.setLastModifiedSync(DateTime.now().subtract(age));
    return file;
  }

  test(
    'cleanup removes stale exports and share_plus copies, keeps the rest',
    () async {
      final oldBackup = touch('teapod_backup_1.json', const Duration(hours: 1));
      final oldReport = touch('teapod_report_1.txt', const Duration(hours: 1));
      final sharedCopy = touch(
        'share_plus/teapod_backup_1.json',
        const Duration(hours: 1),
      );
      final freshBackup = touch('teapod_backup_2.json', Duration.zero);
      final unrelated = touch('other_app_cache.bin', const Duration(days: 1));

      await TemporaryExportStore.cleanup(root: root);

      expect(oldBackup.existsSync(), isFalse);
      expect(oldReport.existsSync(), isFalse);
      expect(sharedCopy.existsSync(), isFalse);
      expect(freshBackup.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
    },
  );

  test('startup cleanup drops every leftover export', () async {
    final fresh = touch('share_plus/teapod_backup_9.json', Duration.zero);
    await TemporaryExportStore.cleanup(olderThan: Duration.zero, root: root);
    expect(fresh.existsSync(), isFalse);
  });

  test('exports are named by kind', () async {
    final file = await TemporaryExportStore.create(
      '{}',
      prefix: 'teapod_template_',
      root: root,
    );
    expect(file.path.split('/').last, startsWith('teapod_template_'));
  });

  test('the kind marker does not break profile import', () {
    final bundle = ProfileBundle(
      exportedAt: DateTime(2026, 10, 17),
      profile: Profile(
        id: 'p',
        name: 'Home',
        settings: const AppSettings(),
        createdAt: DateTime(2026, 10, 17),
      ),
    );
    final json = jsonDecode(jsonEncode({...bundle.toJson(), 'kind': 'backup'}));
    expect(ProfileBundle.fromJson(json).profile.name, 'Home');
  });
}
