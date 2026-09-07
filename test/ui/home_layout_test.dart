import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teapodstream/app.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/providers/app_info_provider.dart';
import 'package:teapodstream/providers/config_provider.dart';
import 'package:teapodstream/providers/ip_info_provider.dart';
import 'package:teapodstream/providers/profile_provider.dart';
import 'package:teapodstream/providers/settings_provider.dart';
import 'package:teapodstream/providers/vpn_provider.dart';
import 'package:teapodstream/ui/screens/home_screen.dart';
import 'package:teapodstream/ui/screens/add_config_screen.dart';
import 'package:teapodstream/ui/screens/configs_screen.dart';
import 'package:teapodstream/ui/screens/routing_screen.dart';
import 'package:teapodstream/ui/screens/settings_screen.dart';
import 'package:teapodstream/ui/theme/app_colors.dart';
import 'package:teapodstream/ui/theme/app_theme.dart';
import 'package:teapodstream/ui/theme/app_text_scaler.dart';

class _Vpn extends VpnNotifier {
  _Vpn(this.initial);
  final VpnState2 initial;
  @override
  VpnState2 build() => initial;
}

class _Settings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings();
}

class _IpInfo extends IpInfoNotifier {
  @override
  Future<IpInfo?> build() async => null;
}

class _Configs extends ConfigNotifier {
  @override
  Future<ConfigState> build() async => ConfigState();
}

class _Profiles extends ProfileNotifier {
  @override
  Future<ProfileState> build() async =>
      const ProfileState(profiles: [], activeProfileId: '');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    // Use the real bundled typography, including Cyrillic, in layout checks.
    for (final weight in [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ]) {
      AppTheme.mono(weight: weight);
      AppTheme.sans(weight: weight);
    }
    await GoogleFonts.pendingFonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.dark,
    VpnState2 vpn = const VpnState2(),
    Widget screen = const HomeScreen(),
    double keyboard = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vpnProvider.overrideWith(() => _Vpn(vpn)),
          settingsProvider.overrideWith(_Settings.new),
          ipInfoProvider.overrideWith(_IpInfo.new),
          configProvider.overrideWith(_Configs.new),
          profileProvider.overrideWith(_Profiles.new),
          effectiveConfigProvider.overrideWith((ref) => null),
          pendingReconnectProvider.overrideWith((ref) => false),
          appVersionProvider.overrideWith((ref) async => 'v1.6.4'),
        ],
        child: MaterialApp(
          theme: AppTheme.build(brightness, AppColors.accentCyan),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              viewInsets: EdgeInsets.only(bottom: keyboard),
            ),
            child: child!,
          ),
          home: RepaintBoundary(key: const Key('capture'), child: screen),
        ),
      ),
    );
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/brave_opossum.png'),
        tester.element(find.byKey(const Key('capture'))),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    const path = String.fromEnvironment('REVIEW_SCREENSHOTS');
    if (path.isEmpty) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture')),
    );
    await tester.runAsync(() async {
      final rendered = await boundary.toImage(pixelRatio: 2);
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      await Directory(path).create(recursive: true);
      await File('$path/$name.png').writeAsBytes(data!.buffer.asUint8List());
      rendered.dispose();
    });
  }

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('home fits 360px at scale $scale in ${brightness.name}', (
        tester,
      ) async {
        await pumpScreen(tester, brightness: brightness, scale: scale);
        expect(tester.takeException(), isNull);
        await capture(tester, 'home-${brightness.name}-$scale');
      });
    }
  }

  testWidgets('empty home leads to configuration import', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.bySemanticsLabel('добавить конфигурацию'));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    expect(container.read(tabIndexProvider), 1);
  });

  testWidgets('connection errors are visible with a route to the log', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      vpn: const VpnState2(
        connectionState: VpnState.error,
        error: 'Connection timeout',
      ),
    );
    expect(find.text('ОШИБКА'), findsOneWidget);
    expect(find.byTooltip('Журнал подключения'), findsOneWidget);
    await capture(tester, 'home-connection-error');
  });

  testWidgets('import remains usable with a keyboard and large text', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      scale: 1.5,
      keyboard: 340,
      screen: const AddConfigScreen(),
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('ДОБАВИТЬ'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await capture(tester, 'import-keyboard-large');
  });

  for (final entry in {
    'configs': const ConfigsScreen(),
    'routing': const RoutingScreen(),
    'settings': const SettingsScreen(),
  }.entries) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('${entry.key} fits at text scale $scale', (tester) async {
        await pumpScreen(tester, screen: entry.value, scale: scale);
        expect(tester.takeException(), isNull);
        await capture(tester, '${entry.key}-$scale');
      });
    }
  }

  test('the large preference never reduces the system text size', () {
    expect(
      const AppTextScaler(TextScaler.linear(1.8), minimum: 1.2).scale(20),
      36,
    );
    expect(
      const AppTextScaler(TextScaler.noScaling, minimum: 1.2).scale(20),
      24,
    );
  });
}
