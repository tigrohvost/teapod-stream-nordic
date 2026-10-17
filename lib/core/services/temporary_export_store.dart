import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class TemporaryExportStore {
  static Future<void> cleanup() async {
    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    await for (final file in dir.list()) {
      final name = file.path.split('/').last;
      if (file is File &&
          (name.startsWith('teapod_export_') ||
              name.startsWith('teapod_report_')) &&
          now.difference((await file.stat()).modified) >
              const Duration(minutes: 10)) {
        await file.delete();
      }
    }
  }

  static Future<File> create(
    String content, {
    String extension = 'json',
  }) async {
    await cleanup();
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/teapod_export_${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await file.writeAsString(content, flush: true);
    Timer(const Duration(minutes: 10), () async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        /* Retry on next startup. */
      }
    });
    return file;
  }
}
