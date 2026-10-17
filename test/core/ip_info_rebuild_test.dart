import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/providers/ip_info_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      const AppSettings(ipLookupEnabled: false);

  void set(AppSettings settings) => state = AsyncData(settings);
}

class _CountingIp extends IpInfoNotifier {
  static int builds = 0;
  @override
  Future<IpInfo?> build() {
    builds++;
    return super.build();
  }
}

void main() {
  test('unrelated settings changes do not re-run the IP lookup', () async {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        ipInfoProvider.overrideWith(_CountingIp.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(ipInfoProvider, (_, _) {});
    final settings = await container.read(settingsProvider.future);
    await container.read(ipInfoProvider.future);
    final before = _CountingIp.builds;

    final notifier = container.read(settingsProvider.notifier) as _Settings;
    notifier.set(settings.copyWith(socksPort: settings.socksPort + 1));
    await Future<void>.delayed(Duration.zero);
    expect(_CountingIp.builds, before);

    notifier.set(settings.copyWith(ipLookupEnabled: false, socksPort: 1081));
    await Future<void>.delayed(Duration.zero);
    expect(_CountingIp.builds, before);
  });
}
