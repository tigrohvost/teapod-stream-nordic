import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/services/update_service.dart';

void main() {
  test('only supported 64-bit ABIs pass compatibility check', () {
    for (final abi in ['arm64-v8a', 'x86_64']) {
      expect(() => UpdateService.requireSupportedAbi(abi), returnsNormally);
    }
    for (final abi in ['armeabi-v7a', 'x86', 'unknown']) {
      expect(
        () => UpdateService.requireSupportedAbi(abi),
        throwsA(isA<UnsupportedUpdateAbi>()),
      );
    }
  });

  test('unknown device ABI never defaults to an arm64 APK', () {
    for (final abi in [null, '', ' ']) {
      expect(
        () => UpdateService.requireSupportedAbi(abi),
        throwsFormatException,
      );
    }
  });

  test(
    '32-bit check and forced reinstall stop before requesting a release',
    () async {
      for (final force in [false, true]) {
        await expectLater(
          UpdateService().checkForUpdate('1.6.6', 'armeabi-v7a', force: force),
          throwsA(isA<UnsupportedUpdateAbi>()),
        );
      }
    },
  );
}
