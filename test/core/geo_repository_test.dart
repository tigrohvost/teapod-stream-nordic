import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teapodstream/core/services/geo_data_repository.dart';
import 'package:teapodstream/core/services/subscription_service.dart';

final geoip = Uint8List.fromList([
  10,
  14,
  10,
  2,
  85,
  83,
  18,
  8,
  10,
  4,
  1,
  2,
  3,
  0,
  16,
  24,
]);
final geosite = Uint8List.fromList([
  10,
  21,
  10,
  2,
  85,
  83,
  18,
  15,
  8,
  2,
  18,
  11,
  ...utf8.encode('example.com'),
]);
void main() {
  test('geodata framing rejects HTML, truncation and empty data', () {
    GeoDataRepository.validateDat(geoip, 'geoip.dat');
    GeoDataRepository.validateDat(geosite, 'geosite.dat');
    for (final invalid in [
      Uint8List(0),
      Uint8List.fromList(utf8.encode('<html>error</html>')),
      geoip.sublist(0, geoip.length - 1),
    ]) {
      expect(
        () => GeoDataRepository.validateDat(invalid, 'geoip.dat'),
        throwsFormatException,
      );
    }
  });
  test(
    'paired activation keeps previous generation when second download fails',
    () async {
      final dir = await Directory.systemTemp.createTemp('geo-test-');
      addTearDown(() => dir.delete(recursive: true));
      var fail = false, requests = 0;
      final repo = GeoDataRepository(
        dir,
        clientFactory: () => MockClient((request) async {
          requests++;
          return http.Response.bytes(
            request.url.path.endsWith('ip')
                ? geoip
                : fail
                ? utf8.encode('<html>bad</html>')
                : geosite,
            200,
          );
        }),
      );
      final first = repo.download(
        'https://geo.test/ip',
        'https://geo.test/site',
      );
      final coalesced = repo.download(
        'https://geo.test/ip',
        'https://geo.test/site',
      );
      expect(identical(first, coalesced), isTrue);
      await first;
      expect(requests, 2);
      final old = await repo.current();
      expect(old, isNotNull);
      fail = true;
      await expectLater(
        repo.download('https://geo.test/ip', 'https://geo.test/site'),
        throwsFormatException,
      );
      expect(await repo.current(), old);
      final generation = old!['generation'];
      await File(
        '${dir.path}/geo/$generation/geoip.dat',
      ).writeAsString('tampered');
      expect(await repo.current(), isNull);
    },
  );
  test('cancelled download cannot switch the active pointer', () async {
    final dir = await Directory.systemTemp.createTemp('geo-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final response = Completer<http.Response>();
    final repo = GeoDataRepository(
      dir,
      clientFactory: () => MockClient((_) => response.future),
    );
    final operation = repo.download(
      'https://geo.test/ip',
      'https://geo.test/site',
    );
    final expectation = expectLater(operation, throwsA(isA<HttpException>()));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    repo.cancel();
    response.complete(http.Response.bytes(geoip, 200));
    await expectation;
    expect(await repo.current(), isNull);
  });
  test(
    'locked bundled geodata passes the same structural validator',
    () async {
      for (final name in ['geoip.dat', 'geosite.dat']) {
        GeoDataRepository.validateDat(
          await File('assets/binaries/$name').readAsBytes(),
          name,
        );
      }
    },
    skip: !File('assets/binaries/geoip.dat').existsSync()
        ? 'Run dependencies.py fetch for real-data integration check'
        : false,
  );
  test(
    'subscription refuses partial invalid document and oversized body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var huge = false;
      server.listen((request) async {
        if (huge) {
          request.response.contentLength = 9 * 1024 * 1024;
          request.response.bufferOutput = false;
          request.response.write('x');
          try {
            await request.response.flush();
          } catch (_) {}
        } else {
          // No usable entry at all: the document is refused as a whole.
          request.response.write('invalid://entry\ntuic://x@example.test:1');
        }
        try {
          await request.response.close();
        } catch (_) {
          /* Deliberately truncated response. */
        }
      });
      final service = SubscriptionService();
      final url = 'http://127.0.0.1:${server.port}/sub';
      await expectLater(service.fetchSubscription(url), throwsFormatException);
      huge = true;
      await expectLater(service.fetchSubscription(url), throwsFormatException);
    },
  );
}
