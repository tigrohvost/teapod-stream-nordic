import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show compute;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class GeoDataRepository {
  static const maxFileBytes = 64 * 1024 * 1024;
  final Directory root;
  final http.Client Function() clientFactory;
  Future<DateTime>? _pending;
  http.Client? _client;
  int _generation = 0;
  GeoDataRepository(this.root, {http.Client Function()? clientFactory})
    : clientFactory = clientFactory ?? http.Client.new;

  void cancel() {
    _generation++;
    _client?.close();
  }

  Future<Map<String, dynamic>?> current() async {
    final pointer = File('${root.path}/geo/active.json');
    if (!await pointer.exists()) return null;
    try {
      final manifest =
          jsonDecode(await pointer.readAsString()) as Map<String, dynamic>;
      if (manifest['schema'] != 1 ||
          !RegExp(
            r'^generation-[0-9]+$',
          ).hasMatch(manifest['generation'] as String)) {
        return null;
      }
      for (final name in ['geoip.dat', 'geosite.dat']) {
        final path = '${root.path}/geo/${manifest['generation']}/$name';
        final meta = (manifest['files'] as Map)[name] as Map;
        if (await File(path).length() != meta['size'] ||
            await compute(_verifyGeoFile, (path, name)) != meta['sha256']) {
          return null;
        }
      }
      return manifest;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime> download(
    String geoipUrl,
    String geositeUrl, {
    void Function(int)? onProgress,
  }) {
    return _pending ??= _download(
      geoipUrl,
      geositeUrl,
      onProgress,
    ).whenComplete(() => _pending = null);
  }

  Future<DateTime> _download(
    String geoipUrl,
    String geositeUrl,
    void Function(int)? progress,
  ) async {
    final generation = ++_generation;
    final client = _client = clientFactory();
    final name = 'generation-${DateTime.now().microsecondsSinceEpoch}';
    final staging = Directory('${root.path}/geo/$name');
    await staging.create(recursive: true);
    var committed = false;
    var bytesTotal = 0;
    final watch = Stopwatch()..start();
    var nextProgress = 0;
    final timeout = Timer(const Duration(minutes: 2), () {
      if (_generation == generation) cancel();
    });
    try {
      final files = <String, Object?>{};
      for (final entry in [
        ('geoip.dat', geoipUrl),
        ('geosite.dat', geositeUrl),
      ]) {
        final uri = Uri.parse(entry.$2);
        if (!const ['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
          throw const FormatException('Неверный URL геобазы');
        }
        final response = await client
            .send(http.Request('GET', uri))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        if ((response.contentLength ?? 0) > maxFileBytes) {
          throw const FormatException('Геобаза слишком велика');
        }
        final file = File('${staging.path}/${entry.$1}');
        final sink = file.openWrite();
        var size = 0;
        try {
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 15),
          )) {
            if (generation != _generation) {
              throw const HttpException('Загрузка отменена');
            }
            size += chunk.length;
            if (size > maxFileBytes) {
              throw const FormatException('Геобаза слишком велика');
            }
            sink.add(chunk);
            bytesTotal += chunk.length;
            if (watch.elapsedMilliseconds >= nextProgress) {
              progress?.call(bytesTotal);
              nextProgress = watch.elapsedMilliseconds + 100;
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (response.contentLength != null && response.contentLength != size) {
          throw const FormatException('Неполная загрузка');
        }
        final path = file.path;
        final kind = entry.$1;
        final digest = await compute(_verifyGeoFile, (path, kind));
        final now = DateTime.now().toUtc().toIso8601String();
        files[entry.$1] = {
          'source': entry.$2,
          'version': response.headers['etag'] ?? now,
          'verifiedAt': now,
          'size': size,
          'sha256': digest,
        };
      }
      if (generation != _generation) {
        throw const HttpException('Загрузка отменена');
      }
      final now = DateTime.now();
      final manifest = jsonEncode({
        'schema': 1,
        'generation': name,
        'verifiedAt': now.toIso8601String(),
        'files': files,
      });
      await File(
        '${staging.path}/manifest.json',
      ).writeAsString(manifest, flush: true);
      final pointer = File('${root.path}/geo/active-$name.tmp');
      await pointer.writeAsString(manifest, flush: true);
      // No asynchronous gap between cancellation check and the atomic commit.
      if (generation != _generation) {
        await pointer.delete();
        throw const HttpException('Загрузка отменена');
      }
      pointer.renameSync('${root.path}/geo/active.json');
      committed = true;
      progress?.call(bytesTotal);
      return now;
    } finally {
      timeout.cancel();
      client.close();
      if (identical(client, _client)) _client = null;
      if (!committed && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  /// Parses the protobuf framing and required GeoIP/GeoSite entries. Rejects HTML,
  /// truncation, empty databases and invalid IP/prefix/domain records.
  static void validateDat(Uint8List bytes, String kind) {
    if (bytes.isEmpty || bytes.length > maxFileBytes) {
      throw const FormatException('Пустая или слишком большая геобаза');
    }
    final root = _Proto(bytes);
    var count = 0;
    while (!root.done) {
      final (field, wire) = root.key();
      if (field != 1 || wire != 2) {
        throw const FormatException('Неверный формат геобазы');
      }
      final item = _Proto(root.data());
      var country = false;
      var records = 0;
      while (!item.done) {
        final (number, type) = item.key();
        if (number == 1 && type == 2) {
          final code = utf8.decode(item.data());
          if (code.isEmpty || code.length > 128) {
            throw const FormatException('Неверная категория');
          }
          country = true;
        } else if (number == 2 && type == 2) {
          final record = _Proto(item.data());
          Uint8List? value;
          int numeric = 0;
          while (!record.done) {
            final (n, w) = record.key();
            if ((kind == 'geoip.dat' ? n == 1 : n == 2) && w == 2) {
              value = record.data();
            } else if ((kind == 'geoip.dat' ? n == 2 : n == 1) && w == 0) {
              numeric = record.varint();
            } else {
              record.skip(w);
            }
          }
          if (value == null || value.isEmpty) {
            throw const FormatException('Пустая запись геобазы');
          }
          if (kind == 'geoip.dat') {
            if (!const [4, 16].contains(value.length) ||
                numeric > value.length * 8) {
              throw const FormatException('Неверный CIDR');
            }
          } else if (numeric > 3 || utf8.decode(value).isEmpty) {
            throw const FormatException('Неверный домен');
          }
          records++;
        } else {
          item.skip(type);
        }
      }
      if (!country || records == 0) {
        throw const FormatException('Неполная категория геобазы');
      }
      count++;
    }
    if (count == 0) throw const FormatException('Геобаза не содержит записей');
  }
}

class _Proto {
  final Uint8List bytes;
  int offset = 0;
  _Proto(this.bytes);
  bool get done => offset == bytes.length;
  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (offset >= bytes.length) {
        throw const FormatException('Оборванная геобаза');
      }
      final byte = bytes[offset++];
      value |= (byte & 127) << shift;
      if (byte < 128) return value;
    }
    throw const FormatException('Неверный varint');
  }

  (int, int) key() {
    final v = varint();
    if (v >> 3 == 0) throw const FormatException('Неверное поле');
    return (v >> 3, v & 7);
  }

  Uint8List data() {
    final length = varint();
    if (length < 0 || length > bytes.length - offset) {
      throw const FormatException('Оборванная геобаза');
    }
    final result = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return result;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        offset += 8;
      case 2:
        data();
      case 5:
        offset += 4;
      default:
        throw const FormatException('Неверный wire type');
    }
    if (offset > bytes.length) {
      throw const FormatException('Оборванная геобаза');
    }
  }
}

// A top-level isolate entry avoids capturing the repository, HTTP client or its
// pending Future in a closure's shared context.
String _verifyGeoFile((String, String) input) {
  final bytes = File(input.$1).readAsBytesSync();
  GeoDataRepository.validateDat(bytes, input.$2);
  return sha256.convert(bytes).toString();
}
