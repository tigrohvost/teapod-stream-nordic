import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/services/update_service.dart';

void main() {
  group('compareAppVersions', () {
    test('orders release versions numerically', () {
      expect(compareAppVersions('1.6.2', '1.6.1'), greaterThan(0));
      expect(compareAppVersions('1.6.1', '1.6.2'), lessThan(0));
      expect(compareAppVersions('1.6.1', '1.6.1'), 0);
      expect(compareAppVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareAppVersions('2.0.0', '1.99.99'), greaterThan(0));
    });

    test('ignores a leading v and build metadata', () {
      expect(compareAppVersions('v1.6.2', '1.6.1'), greaterThan(0));
      expect(compareAppVersions('1.6.1+10601', '1.6.1'), 0);
      expect(compareAppVersions('v1.6.1', 'v1.6.1'), 0);
    });

    test('places a pre-release between the previous and the final release', () {
      expect(compareAppVersions('1.6.2-beta1', '1.6.1'), greaterThan(0));
      expect(compareAppVersions('1.6.2-beta1', '1.6.2'), lessThan(0));
      expect(compareAppVersions('1.7.0-rc1', '1.6.1'), greaterThan(0));
    });

    test('orders pre-releases of the same version', () {
      expect(compareAppVersions('1.6.1-beta2', '1.6.1-beta1'), greaterThan(0));
      expect(compareAppVersions('1.6.1-beta.2', '1.6.1-beta.10'), lessThan(0));
      expect(compareAppVersions('1.6.1-beta.1', '1.6.1-beta'), greaterThan(0));
      expect(compareAppVersions('1.6.1-1', '1.6.1-beta'), lessThan(0));
      expect(compareAppVersions('1.6.1-beta1', '1.6.1-beta1'), 0);
    });

    test('treats missing and unparsable parts as zero', () {
      expect(compareAppVersions('1.6', '1.6.0'), 0);
      expect(compareAppVersions('1', '1.0.0'), 0);
      expect(compareAppVersions('1.6.x', '1.6.0'), 0);
    });
  });
}
