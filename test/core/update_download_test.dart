import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/services/update_service.dart';

void main() {
  late HttpServer server;
  late Directory directory;
  late File apk;
  late String url;
  const bytes = [80, 75, 3, 4, 1, 2, 3, 4];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('teapod-update-test-');
    apk = File('${directory.path}/update.apk');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}/update.apk';
  });
  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('finishes only after size and SHA-256 have been verified', () async {
    server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final progress = await UpdateService()
        .downloadApk(
          url,
          apk.path,
          expectedBytes: bytes.length,
          expectedSha256: sha256.convert(bytes).toString(),
        )
        .toList();
    expect(progress.last.done, isTrue);
    expect(progress.last.downloaded, bytes.length);
    expect(await apk.readAsBytes(), bytes);
  });

  test('resumes at the exact byte offset without duplicating data', () async {
    await apk.writeAsBytes(bytes.take(3).toList());
    server.listen((request) async {
      expect(request.headers.value('range'), 'bytes=3-');
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 3-7/8');
      request.response.contentLength = 5;
      request.response.add(bytes.skip(3).toList());
      await request.response.close();
    });
    await UpdateService()
        .downloadApk(
          url,
          apk.path,
          expectedBytes: 8,
          expectedSha256: sha256.convert(bytes).toString(),
        )
        .drain<void>();
    expect(await apk.readAsBytes(), bytes);
  });

  test('a server ignoring Range replaces the partial file', () async {
    await apk.writeAsBytes([9, 9, 9]);
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    await UpdateService()
        .downloadApk(url, apk.path, expectedBytes: 8)
        .drain<void>();
    expect(await apk.readAsBytes(), bytes);
  });

  test(
    '416 restarts the download instead of accepting a corrupt file',
    () async {
      await apk.writeAsBytes(List.filled(9, 0));
      var requests = 0;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          expect(request.headers.value('range'), 'bytes=9-');
          request.response.statusCode = 416;
        } else {
          expect(request.headers.value('range'), isNull);
          request.response.add(bytes);
        }
        await request.response.close();
      });
      await UpdateService()
          .downloadApk(url, apk.path, expectedBytes: 8)
          .drain<void>();
      expect(requests, 2);
      expect(await apk.readAsBytes(), bytes);
    },
  );

  test('rejects a response with the wrong resume offset', () async {
    await apk.writeAsBytes(bytes.take(3).toList());
    server.listen((request) async {
      request.response.statusCode = 206;
      request.response.headers.set('content-range', 'bytes 2-7/8');
      request.response.add(bytes.skip(2).toList());
      await request.response.close();
    });
    await expectLater(
      UpdateService().downloadApk(url, apk.path).drain<void>(),
      throwsFormatException,
    );
    expect(await apk.length(), 3);
  });

  test('rejects a truncated body and retains it for resume', () async {
    server.listen((request) async {
      request.response.add(bytes.take(3).toList());
      await request.response.close();
    });
    await expectLater(
      UpdateService()
          .downloadApk(url, apk.path, expectedBytes: 8)
          .drain<void>(),
      throwsFormatException,
    );
    expect(await apk.length(), 3);
  });

  test('deletes a complete file with the wrong digest', () async {
    server.listen((request) async {
      request.response.add(List.filled(8, 0));
      await request.response.close();
    });
    await expectLater(
      UpdateService()
          .downloadApk(
            url,
            apk.path,
            expectedBytes: 8,
            expectedSha256: sha256.convert(bytes).toString(),
          )
          .drain<void>(),
      throwsFormatException,
    );
    expect(await apk.exists(), isFalse);
  });

  test('rejects empty downloads', () async {
    server.listen((request) async {
      await request.response.close();
    });
    await expectLater(
      UpdateService().downloadApk(url, apk.path).drain<void>(),
      throwsFormatException,
    );
  });

  test(
    'cancelling a stalled response closes the connection promptly',
    () async {
      final received = Completer<void>();
      server.listen((request) {
        received.complete();
      });
      final subscription = UpdateService()
          .downloadApk(url, apk.path)
          .listen((_) {});
      await received.future;
      await subscription.cancel().timeout(const Duration(seconds: 2));
    },
  );
}
