import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teapodstream/core/services/geo_data_repository.dart';

// Same minimal, structurally valid databases as geo_repository_test.dart.
final geoip = Uint8List.fromList([
  10, 14, 10, 2, 85, 83, 18, 8, 10, 4, 1, 2, 3, 0, 16, 24, //
]);
final geosite = Uint8List.fromList([
  10, 21, 10, 2, 85, 83, 18, 15, 8, 2, 18, 11, //
  ...utf8.encode('example.com'),
]);

Uint8List _body(http.BaseRequest request) =>
    request.url.path.endsWith('ip') ? geoip : geosite;

List<String> _generations(Directory dir) =>
    Directory('${dir.path}/geo')
        .listSync()
        .whereType<Directory>()
        .map((d) => d.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toList()
      ..sort();

void main() {
  test('updates keep only the active generation and its predecessor', () async {
    final dir = await Directory.systemTemp.createTemp('geo-gen-');
    addTearDown(() => dir.delete(recursive: true));
    final repo = GeoDataRepository(
      dir,
      clientFactory: () => MockClient(
        (request) async => http.Response.bytes(_body(request), 200),
      ),
      staleGenerationAge: Duration.zero,
    );
    for (var i = 0; i < 3; i++) {
      await repo.download('https://geo.test/ip', 'https://geo.test/site');
    }
    final active = (await repo.current())!;
    expect(active['previous'], isNotNull);
    expect(
      _generations(dir),
      [active['previous'], active['generation']]..sort(),
    );
  });

  test('a fresh staging directory survives cleanup', () async {
    final dir = await Directory.systemTemp.createTemp('geo-gen-');
    addTearDown(() => dir.delete(recursive: true));
    final repo = GeoDataRepository(
      dir,
      clientFactory: () => MockClient(
        (request) async => http.Response.bytes(_body(request), 200),
      ),
    );
    await repo.download('https://geo.test/ip', 'https://geo.test/site');
    final staging = Directory('${dir.path}/geo/generation-1')..createSync();
    await repo.download('https://geo.test/ip', 'https://geo.test/site');
    await repo.download('https://geo.test/ip', 'https://geo.test/site');
    expect(staging.existsSync(), isTrue);
  });

  http.Client trickling(Duration gap, {bool stall = false}) =>
      MockClient.streaming((request, _) async {
        final body = _body(request);
        final controller = StreamController<List<int>>();
        () async {
          for (var i = 0; i < body.length; i += 4) {
            await Future<void>.delayed(stall && i > 0 ? gap * 10 : gap);
            if (controller.isClosed) return;
            controller.add(body.sublist(i, (i + 4).clamp(0, body.length)));
          }
          await controller.close();
        }();
        return http.StreamedResponse(controller.stream, 200);
      });

  test('a slow download that keeps progressing is not cut off', () async {
    final dir = await Directory.systemTemp.createTemp('geo-slow-');
    addTearDown(() => dir.delete(recursive: true));
    final repo = GeoDataRepository(
      dir,
      clientFactory: () => trickling(const Duration(milliseconds: 20)),
      // Total time per file (~5 chunks x 20 ms) exceeds the idle limit.
      idleTimeout: const Duration(milliseconds: 60),
    );
    await repo.download('https://geo.test/ip', 'https://geo.test/site');
    expect(await repo.current(), isNotNull);
  });

  test('a stalled download times out and keeps the previous pair', () async {
    final dir = await Directory.systemTemp.createTemp('geo-stall-');
    addTearDown(() => dir.delete(recursive: true));
    var stall = false;
    final repo = GeoDataRepository(
      dir,
      clientFactory: () =>
          trickling(const Duration(milliseconds: 10), stall: stall),
      idleTimeout: const Duration(milliseconds: 50),
    );
    await repo.download('https://geo.test/ip', 'https://geo.test/site');
    final before = await repo.current();
    stall = true;
    await expectLater(
      repo.download('https://geo.test/ip', 'https://geo.test/site'),
      throwsA(isA<TimeoutException>()),
    );
    expect(await repo.current(), before);
  });
}
