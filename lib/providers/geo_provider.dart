import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/services/geo_data_repository.dart';
import '../core/constants/app_constants.dart';
import 'settings_provider.dart';

sealed class GeoState {}

class GeoMissing extends GeoState {}

class GeoReady extends GeoState {
  final DateTime? lastUpdated;
  final String? updateError;
  GeoReady({this.lastUpdated, this.updateError});
}

class GeoDownloading extends GeoState {
  final int downloaded;
  final int total;
  GeoDownloading({required this.downloaded, required this.total});
}

class GeoError extends GeoState {
  final String message;
  GeoError(this.message);
}

class GeoNotifier extends Notifier<GeoState> {
  static const _channel = MethodChannel(AppConstants.methodChannel);
  GeoDataRepository? _repository;
  Future<void>? _download;

  @override
  GeoState build() {
    ref.onDispose(() => _repository?.cancel());
    Future.microtask(check);
    return GeoMissing();
  }

  Future<GeoDataRepository> _repo() async {
    if (_repository != null) return _repository!;
    final dir = await _channel.invokeMethod<String>('getFilesDir');
    if (dir == null || dir.isEmpty) {
      throw const FileSystemException('Хранилище недоступно');
    }
    return _repository = GeoDataRepository(Directory(dir));
  }

  Future<void> check() async {
    if (_download != null) return;
    try {
      await _channel.invokeMethod('prepareBinaries');
      final manifest = await (await _repo()).current();
      if (!ref.mounted || _download != null) return;
      state = manifest == null
          ? GeoMissing()
          : GeoReady(
              lastUpdated: DateTime.tryParse(
                manifest['verifiedAt'] as String? ?? '',
              ),
              // Set by the native store when it replaced a damaged active pair.
              updateError: manifest['restoredFrom'] == null
                  ? null
                  : 'Геобаза была повреждена и заменена последней проверенной '
                        'копией. Обновите геобазы.',
            );
    } catch (_) {
      if (ref.mounted) state = GeoMissing();
    }
  }

  Future<void> download() =>
      _download ??= _downloadPair().whenComplete(() => _download = null);
  void cancel() => _repository?.cancel();

  Future<void> _downloadPair() async {
    try {
      final settings = await ref.read(settingsProvider.future);
      final repository = await _repo();
      state = GeoDownloading(downloaded: 0, total: -1);
      final now = await repository.download(
        settings.geoipUrl,
        settings.geositeUrl,
        onProgress: (count) {
          if (ref.mounted) state = GeoDownloading(downloaded: count, total: -1);
        },
      );
      if (ref.mounted) state = GeoReady(lastUpdated: now);
    } catch (_) {
      if (!ref.mounted) return;
      final previous = await _repository?.current();
      state = previous == null
          ? GeoError('Не удалось проверить геобазы. Повторите загрузку.')
          : GeoReady(
              lastUpdated: DateTime.tryParse(
                previous['verifiedAt'] as String? ?? '',
              ),
              updateError:
                  'Обновление не прошло проверку; сохранена предыдущая версия',
            );
    }
  }
}

final geoProvider = NotifierProvider<GeoNotifier, GeoState>(GeoNotifier.new);
