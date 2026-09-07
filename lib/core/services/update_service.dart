import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:socks5_proxy/socks.dart';

enum UpdateChannel { stable, beta }

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final int? totalBytes;
  final String? changelog;
  final String? sha256Digest;

  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.totalBytes,
    this.changelog,
    this.sha256Digest,
  });
}

class DownloadProgress {
  final int downloaded;
  final int total; // -1 if unknown
  final bool done;

  const DownloadProgress({
    required this.downloaded,
    required this.total,
    required this.done,
  });
}

class UpdateService {
  // Fork releases: the Nordic build is signed with its own key, so updates
  // must come from the fork's repository, never from upstream.
  static const _githubApiLatest =
      'https://api.github.com/repos/tigrohvost/teapod-stream-nordic/releases/latest';
  static const _githubApiList =
      'https://api.github.com/repos/tigrohvost/teapod-stream-nordic/releases?per_page=10';

  HttpClient _makeClient({int? socksPort, String? user, String? password}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    if (socksPort != null && socksPort > 0) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(
          InternetAddress.loopbackIPv4,
          socksPort,
          username: (user != null && user.isNotEmpty) ? user : null,
          password: (user != null && user.isNotEmpty) ? password : null,
        ),
      ]);
    }
    return client;
  }

  /// Returns null if already up to date or no matching APK asset found.
  /// Pass [socksPort] to route through the active VPN SOCKS5 proxy.
  /// Pass [force] to skip version comparison (for reinstall).
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion,
    String abi, {
    UpdateChannel channel = UpdateChannel.stable,
    int? socksPort,
    String? socksUser,
    String? socksPassword,
    bool force = false,
  }) async {
    final client = _makeClient(
      socksPort: socksPort,
      user: socksUser,
      password: socksPassword,
    );
    try {
      final releaseJson = await _fetchRelease(client, channel);
      if (releaseJson == null) return null;
      final tagName = (releaseJson['tag_name'] as String? ?? '').replaceFirst(
        RegExp(r'^v'),
        '',
      );
      if (tagName.isEmpty) return null;
      if (!force && compareAppVersions(tagName, currentVersion) <= 0) {
        return null;
      }
      final changelog = releaseJson['body'] as String?;
      final assets = releaseJson['assets'] as List<dynamic>? ?? [];
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name == 'teapod-stream-$abi.apk') {
          final url = asset['browser_download_url'] as String?;
          final size = asset['size'] as int?;
          if (url != null) {
            return UpdateInfo(
              version: tagName,
              downloadUrl: url,
              totalBytes: size,
              sha256Digest: _assetDigest(asset['digest'] as String?),
              changelog: (changelog != null && changelog.trim().isNotEmpty)
                  ? changelog.trim()
                  : null,
            );
          }
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>?> _fetchRelease(
    HttpClient client,
    UpdateChannel channel,
  ) async {
    if (channel == UpdateChannel.stable) {
      final req = await client
          .getUrl(Uri.parse(_githubApiLatest))
          .timeout(const Duration(seconds: 15));
      req.headers.set('User-Agent', 'TeapodStream');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = await resp
          .timeout(const Duration(seconds: 15))
          .transform(utf8.decoder)
          .join();
      return jsonDecode(body) as Map<String, dynamic>;
    } else {
      // beta: pick newest non-draft release (prerelease or stable)
      final req = await client
          .getUrl(Uri.parse(_githubApiList))
          .timeout(const Duration(seconds: 15));
      req.headers.set('User-Agent', 'TeapodStream');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final body = await resp
          .timeout(const Duration(seconds: 15))
          .transform(utf8.decoder)
          .join();
      final releases = jsonDecode(body) as List<dynamic>;
      // GitHub returns releases sorted newest-first; take first non-draft
      for (final r in releases) {
        final release = r as Map<String, dynamic>;
        if (release['draft'] != true) return release;
      }
      return null;
    }
  }

  /// Resumable download. Sends Range header if destPath already has bytes.
  /// Pass [socksPort] to route through the active VPN SOCKS5 proxy.
  Stream<DownloadProgress> downloadApk(
    String url,
    String destPath, {
    int? socksPort,
    String? socksUser,
    String? socksPassword,
    int? expectedBytes,
    String? expectedSha256,
  }) {
    final file = File(destPath);
    final client = _makeClient(
      socksPort: socksPort,
      user: socksUser,
      password: socksPassword,
    );
    final controller = StreamController<DownloadProgress>();
    final finished = Completer<void>();
    var cancelled = false;
    const timeout = Duration(seconds: 30);

    controller.onCancel = () async {
      cancelled = true;
      // Cancel a stalled response immediately; retain flushed bytes for resume.
      client.close(force: true);
      await finished.future;
    };
    controller.onListen = () async {
      IOSink? sink;
      try {
        var existing = await file.exists() ? await file.length() : 0;
        Future<HttpClientResponse> request() async {
          final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
          req.headers.set('User-Agent', 'TeapodStream');
          req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
          if (existing > 0) req.headers.set('Range', 'bytes=$existing-');
          return req.close().timeout(timeout);
        }

        var resp = await request();
        if (resp.statusCode == 416 && existing > 0) {
          // A range rejection says nothing about the local file's integrity.
          await resp.timeout(timeout).drain<void>();
          existing = 0;
          resp = await request();
        }
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw HttpException('HTTP ${resp.statusCode}');
        }
        final isResume = resp.statusCode == 206;
        final contentLength = resp.contentLength;
        var total = contentLength >= 0 ? contentLength : -1;
        if (isResume) {
          final range = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(resp.headers.value('content-range') ?? '');
          if (range == null ||
              int.parse(range[1]!) != existing ||
              int.parse(range[2]!) != int.parse(range[3]!) - 1 ||
              int.parse(range[3]!) <= existing ||
              (contentLength >= 0 &&
                  contentLength != int.parse(range[3]!) - existing)) {
            throw const FormatException('Некорректный диапазон загрузки APK');
          }
          total = int.parse(range[3]!);
        }
        if (expectedBytes != null && total >= 0 && total != expectedBytes) {
          throw const FormatException('Размер APK не совпадает с релизом');
        }
        total = expectedBytes ?? total;
        var downloaded = isResume ? existing : 0;
        sink = file.openWrite(
          mode: isResume ? FileMode.append : FileMode.write,
        );
        final progressClock = Stopwatch()..start();
        await sink.addStream(
          resp.timeout(timeout).map((chunk) {
            downloaded += chunk.length;
            if (!cancelled && progressClock.elapsedMilliseconds >= 100) {
              controller.add(
                DownloadProgress(
                  downloaded: downloaded,
                  total: total,
                  done: false,
                ),
              );
              progressClock.reset();
            }
            return chunk;
          }),
        );
        await sink.close();
        sink = null;
        if (cancelled) return;
        if (downloaded == 0 || (total >= 0 && downloaded != total)) {
          if (total >= 0 && downloaded > total) await file.delete();
          throw const FormatException('APK загружен не полностью');
        }
        if (expectedSha256 != null) {
          final digest = await sha256.bind(file.openRead()).first;
          if (digest.toString() != expectedSha256.toLowerCase()) {
            await file.delete();
            throw const FormatException('Контрольная сумма APK не совпадает');
          }
        }
        if (!cancelled) {
          controller.add(
            DownloadProgress(
              downloaded: downloaded,
              total: downloaded,
              done: true,
            ),
          );
        }
      } catch (error, stack) {
        if (!cancelled) controller.addError(error, stack);
      } finally {
        try {
          await sink?.close();
        } catch (_) {
          // The original write error is already delivered to the listener.
        }
        client.close(force: true);
        finished.complete();
        unawaited(controller.close());
      }
    };
    return controller.stream;
  }

  static String? _assetDigest(String? digest) {
    if (digest == null) return null;
    final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(digest);
    return match?[1]?.toLowerCase();
  }
}

/// Compares release versions the way the tags are shaped: `1.6.2`, with an
/// optional pre-release suffix (`1.6.2-beta1`) and an optional leading `v`.
///
/// The suffix has to be split off before the numbers are parsed: `2-beta1`
/// parses as 0, which would place every beta below the release it leads to and
/// hide it from the updater. Semver ordering applies — a pre-release sits below
/// its release, so `1.6.1 < 1.6.2-beta1 < 1.6.2`.
///
/// Returns positive if [a] is newer than [b], negative if older, 0 if equal.
int compareAppVersions(String a, String b) {
  final av = _Version.parse(a);
  final bv = _Version.parse(b);

  for (int i = 0; i < 3; i++) {
    final x = i < av.core.length ? av.core[i] : 0;
    final y = i < bv.core.length ? bv.core[i] : 0;
    if (x != y) return x - y;
  }

  // A release outranks any pre-release of the same core version.
  if (av.pre.isEmpty && bv.pre.isEmpty) return 0;
  if (av.pre.isEmpty) return 1;
  if (bv.pre.isEmpty) return -1;

  for (int i = 0; i < av.pre.length && i < bv.pre.length; i++) {
    final result = _compareIdentifiers(av.pre[i], bv.pre[i]);
    if (result != 0) return result;
  }
  return av.pre.length - bv.pre.length;
}

/// Numeric identifiers rank below alphanumeric ones, otherwise compare in
/// order. `beta10` and `beta9` are single identifiers and compare as text —
/// write `beta.10` to get numeric ordering.
int _compareIdentifiers(String a, String b) {
  final an = int.tryParse(a);
  final bn = int.tryParse(b);
  if (an != null && bn != null) return an - bn;
  if (an != null) return -1;
  if (bn != null) return 1;
  return a.compareTo(b);
}

class _Version {
  final List<int> core;
  final List<String> pre;

  const _Version(this.core, this.pre);

  static _Version parse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);

    // Build metadata (`+10602`) carries no ordering.
    final plus = text.indexOf('+');
    if (plus != -1) text = text.substring(0, plus);

    final dash = text.indexOf('-');
    final core = dash == -1 ? text : text.substring(0, dash);
    final pre = dash == -1 ? '' : text.substring(dash + 1);

    return _Version(
      core.split('.').map((s) => int.tryParse(s) ?? 0).toList(),
      pre.isEmpty ? const [] : pre.split('.'),
    );
  }
}
