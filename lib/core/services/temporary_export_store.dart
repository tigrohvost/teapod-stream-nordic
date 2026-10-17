import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Short-lived files handed to the share sheet. Backups contain credentials,
/// so neither our copy nor share_plus's copy may outlive [ttl].
class TemporaryExportStore {
  static const ttl = Duration(minutes: 10);

  /// share_plus copies every shared file into `<cacheDir>/share_plus` and only
  /// clears that folder on the next file share.
  static const shareCacheFolder = 'share_plus';

  static const _prefixes = [
    'teapod_export_',
    'teapod_report_',
    'teapod_backup_',
    'teapod_template_',
  ];

  /// Deletes our exports and share_plus copies older than [olderThan].
  /// [root] overrides the platform temporary directory (tests).
  static Future<void> cleanup({
    Duration olderThan = ttl,
    Directory? root,
  }) async {
    final dir = root ?? await getTemporaryDirectory();
    final now = DateTime.now();
    Future<bool> stale(File file) async =>
        now.difference((await file.stat()).modified) >= olderThan;

    try {
      await for (final file in dir.list()) {
        final name = file.path.split('/').last;
        if (file is File &&
            _prefixes.any(name.startsWith) &&
            await stale(file)) {
          await file.delete();
        }
      }
      final shared = Directory('${dir.path}/$shareCacheFolder');
      if (await shared.exists()) {
        await for (final file in shared.list()) {
          if (file is File && await stale(file)) await file.delete();
        }
      }
    } on FileSystemException {
      // Best effort: retried on the next export and on the next startup.
    }
  }

  /// [prefix] names the content kind: teapod_report_, teapod_backup_ or
  /// teapod_template_.
  static Future<File> create(
    String content, {
    String prefix = 'teapod_export_',
    String extension = 'json',
    Directory? root,
  }) async {
    assert(_prefixes.contains(prefix), 'unknown export prefix $prefix');
    await cleanup(root: root);
    final dir = root ?? await getTemporaryDirectory();
    final file = File(
      '${dir.path}/$prefix${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsString(content, flush: true);
    Timer(ttl, () async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* Retry on next startup. */
      }
      // The share sheet handed the copy over long ago; anything this old in
      // share_plus's folder is a leftover.
      await cleanup(olderThan: const Duration(minutes: 5), root: root);
    });
    return file;
  }
}
