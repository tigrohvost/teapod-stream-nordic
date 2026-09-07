import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../core/services/update_service.dart';
import '../core/constants/app_constants.dart';
import 'vpn_provider.dart';
import 'settings_provider.dart';

sealed class UpdateState {}

class UpdateIdle extends UpdateState {}

class UpdateChecking extends UpdateState {}

class UpdateUpToDate extends UpdateState {
  final UpdateInfo info;
  UpdateUpToDate(this.info);
}

class UpdateAvailable extends UpdateState {
  final UpdateInfo info;
  final int resumableBytes;
  UpdateAvailable(this.info, {this.resumableBytes = 0});
}

class UpdateDownloading extends UpdateState {
  final UpdateInfo info;
  final int downloaded;
  final int total;
  UpdateDownloading(this.info, {required this.downloaded, required this.total});
}

class UpdateDownloaded extends UpdateState {
  final UpdateInfo info;
  final String filePath;
  final String? installMessage;
  UpdateDownloaded(this.info, this.filePath, {this.installMessage});
}

class UpdateError extends UpdateState {
  final String message;
  final UpdateInfo? retryInfo;
  UpdateError(this.message, {this.retryInfo});
}

class UpdateNotifier extends Notifier<UpdateState> {
  UpdateNotifier({UpdateService? service})
    : _service = service ?? UpdateService();

  final UpdateService _service;
  StreamSubscription<DownloadProgress>? _dlSub;
  String? _currentApkPath;
  int _checkId = 0;
  int _downloadId = 0;

  static const _channel = MethodChannel(AppConstants.methodChannel);

  @override
  UpdateState build() {
    ref.onDispose(() => _dlSub?.cancel());
    return UpdateIdle();
  }

  Future<void> checkForUpdate() async {
    if (state is UpdateDownloading) return;
    final checkId = ++_checkId;
    state = UpdateChecking();
    try {
      final pkgInfo = await PackageInfo.fromPlatform();
      final currentVersion = pkgInfo.version;
      final abi = await _channel.invokeMethod<String>('getAbi') ?? 'arm64-v8a';
      if (!ref.mounted || checkId != _checkId) return;
      final vpn = ref.read(vpnProvider);
      final settings = ref
          .read(settingsProvider)
          .maybeWhen(data: (d) => d, orElse: () => null);
      final channel = settings?.updateChannel ?? UpdateChannel.stable;
      final update = await _service.checkForUpdate(
        currentVersion,
        abi,
        channel: channel,
        socksPort: vpn.isConnected ? vpn.activeSocksPort : null,
        socksUser: vpn.activeSocksUser,
        socksPassword: vpn.activeSocksPassword,
        force: true,
      );
      if (!ref.mounted || checkId != _checkId) return;
      if (update == null) {
        state = UpdateError('Не удалось получить данные о релизе');
        return;
      }
      final path = await _apkPath(update.version, abi);
      if (!ref.mounted || checkId != _checkId) return;
      await _cleanOldApks(keepPath: path);
      if (!ref.mounted || checkId != _checkId) return;
      if (compareAppVersions(update.version, currentVersion) > 0) {
        final resumable = File(path).existsSync() ? File(path).lengthSync() : 0;
        state = UpdateAvailable(update, resumableBytes: resumable);
      } else {
        state = UpdateUpToDate(update);
      }
    } catch (e) {
      if (ref.mounted && checkId == _checkId) {
        state = UpdateError('Ошибка проверки: $e');
      }
    }
  }

  Future<void> reinstall(UpdateInfo info) async {
    await startDownload(info, restart: true);
  }

  Future<void> startDownload(UpdateInfo info, {bool restart = false}) async {
    if (state is UpdateDownloading) return;
    ++_checkId;
    final downloadId = ++_downloadId;
    state = UpdateDownloading(
      info,
      downloaded: 0,
      total: info.totalBytes ?? -1,
    );
    _currentApkPath = null;
    try {
      final abi = await _channel.invokeMethod<String>('getAbi') ?? 'arm64-v8a';
      final path = await _apkPath(info.version, abi);
      if (!ref.mounted || downloadId != _downloadId) return;
      _currentApkPath = path;
      if (restart && await File(path).exists()) await File(path).delete();
      if (!ref.mounted || downloadId != _downloadId) return;
      final vpn = ref.read(vpnProvider);
      _dlSub = _service
          .downloadApk(
            info.downloadUrl,
            path,
            socksPort: vpn.isConnected ? vpn.activeSocksPort : null,
            socksUser: vpn.activeSocksUser,
            socksPassword: vpn.activeSocksPassword,
            expectedBytes: info.totalBytes,
            expectedSha256: info.sha256Digest,
          )
          .listen(
            (progress) {
              if (!ref.mounted || downloadId != _downloadId) return;
              if (progress.done) {
                state = UpdateDownloaded(info, path);
                _dlSub = null;
              } else {
                state = UpdateDownloading(
                  info,
                  downloaded: progress.downloaded,
                  total: progress.total,
                );
              }
            },
            onError: (e) {
              if (!ref.mounted || downloadId != _downloadId) return;
              state = UpdateError('Ошибка загрузки: $e', retryInfo: info);
              _dlSub = null;
            },
          );
    } catch (e) {
      if (ref.mounted && downloadId == _downloadId) {
        state = UpdateError('Ошибка загрузки: $e', retryInfo: info);
      }
    }
  }

  Future<void> cancelDownload() async {
    ++_downloadId;
    await _dlSub?.cancel();
    _dlSub = null;
    if (!ref.mounted) return;
    final cur = state;
    if (cur is UpdateDownloading) {
      final path = _currentApkPath;
      final resumable = path != null && File(path).existsSync()
          ? File(path).lengthSync()
          : 0;
      state = UpdateAvailable(cur.info, resumableBytes: resumable);
    }
  }

  Future<void> installApk(String filePath) async {
    final ready = state;
    if (ready is! UpdateDownloaded || ready.filePath != filePath) return;
    try {
      await _channel.invokeMethod<void>('installApk', {'filePath': filePath});
      // Opening the installer is not confirmation of installation. Keep the
      // verified file available if the user cancels or returns from settings.
      if (ref.mounted) state = UpdateDownloaded(ready.info, filePath);
    } on PlatformException catch (e) {
      if (!ref.mounted) return;
      if (e.code == 'FILE_NOT_FOUND') {
        state = UpdateError(
          'APK не найден. Скачайте обновление снова.',
          retryInfo: ready.info,
        );
      } else {
        state = UpdateDownloaded(
          ready.info,
          filePath,
          installMessage: e.code == 'PERMISSION_REQUIRED'
              ? 'Разрешите установку из этого источника, вернитесь и нажмите «Установить».'
              : (e.message ??
                    'Не удалось открыть установщик. Повторите попытку.'),
        );
      }
    }
  }

  Future<String> _apkPath(String version, String abi) async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/teapod-update-$abi-$version.apk';
  }

  Future<void> _cleanOldApks({String? keepPath}) async {
    final dir = await getApplicationSupportDirectory();
    for (final f in dir.listSync().whereType<File>()) {
      if (f.uri.pathSegments.last.startsWith('teapod-update-') &&
          f.path.endsWith('.apk')) {
        if (keepPath == null || f.path != keepPath) {
          await f.delete();
        }
      }
    }
  }
}

final updateProvider = NotifierProvider<UpdateNotifier, UpdateState>(
  UpdateNotifier.new,
);
