import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/constants/app_constants.dart';
import 'package:teapodstream/core/services/update_service.dart';
import 'package:teapodstream/providers/update_provider.dart';

const _info = UpdateInfo(
  version: '1.6.4',
  downloadUrl: 'https://example.com/app.apk',
);

class _ReadyUpdater extends UpdateNotifier {
  @override
  UpdateState build() => UpdateDownloaded(_info, '/test/update.apk');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppConstants.methodChannel);
  late ProviderContainer container;
  setUp(() {
    container = ProviderContainer(
      overrides: [updateProvider.overrideWith(_ReadyUpdater.new)],
    );
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'permission request keeps the verified APK available for installation',
    () async {
      var attempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'installApk');
            attempts++;
            if (attempts == 1) {
              throw PlatformException(code: 'PERMISSION_REQUIRED');
            }
            return null;
          });
      final notifier = container.read(updateProvider.notifier);
      await notifier.installApk('/test/update.apk');
      final ready = container.read(updateProvider) as UpdateDownloaded;
      expect(ready.filePath, '/test/update.apk');
      expect(ready.installMessage, contains('Разрешите установку'));
      await notifier.installApk('/test/update.apk');
      expect(attempts, 2);
      expect(container.read(updateProvider), isA<UpdateDownloaded>());
    },
  );

  test(
    'opening or cancelling the installer does not discard the ready state',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      await container
          .read(updateProvider.notifier)
          .installApk('/test/update.apk');
      expect(container.read(updateProvider), isA<UpdateDownloaded>());
    },
  );

  test('missing APK offers a download retry', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'FILE_NOT_FOUND');
        });
    await container
        .read(updateProvider.notifier)
        .installApk('/test/update.apk');
    expect(
      (container.read(updateProvider) as UpdateError).retryInfo,
      same(_info),
    );
  });
}
