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
import 'package:teapodstream/core/constants/app_constants.dart';
import 'package:teapodstream/core/interfaces/vpn_engine.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/deeplink_router.dart';
import 'package:teapodstream/core/services/settings_service.dart';
import 'package:teapodstream/protocols/xray/vless_parser.dart';
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

  @override
  Future<VpnState?> syncNativeState() async => null;
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
  _Configs(this.items);
  final List<VpnConfig> items;
  @override
  Future<ConfigState> build() async => ConfigState(configs: items);
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

  ProviderScope withOverrides(
    Widget child, {
    VpnState2 vpn = const VpnState2(),
    VpnConfig? selected,
  }) {
    return ProviderScope(
      overrides: [
        vpnProvider.overrideWith(() => _Vpn(vpn)),
        settingsProvider.overrideWith(_Settings.new),
        ipInfoProvider.overrideWith(_IpInfo.new),
        configProvider.overrideWith(() => _Configs([?selected])),
        profileProvider.overrideWith(_Profiles.new),
        effectiveConfigProvider.overrideWith((ref) => null),
        pendingReconnectProvider.overrideWith((ref) => false),
        appVersionProvider.overrideWith((ref) async => 'v1.6.4'),
      ],
      child: child,
    );
  }

  void setPhoneSize(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.dark,
    VpnState2 vpn = const VpnState2(),
    Widget screen = const HomeScreen(),
    double keyboard = 0,
    VpnConfig? selected,
  }) async {
    setPhoneSize(tester);
    await tester.pumpWidget(
      withOverrides(
        MaterialApp(
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
        vpn: vpn,
        selected: selected,
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

  testWidgets(
    'configuration menu copies connection links including managed JSON',
    (tester) async {
      SharedPreferences.setMockInitialValues({'cfg_hide_groups': true});
      const original = 'trojan://fixture@copy.example.test:443#URI-fixture';
      const managedJson =
          '{"outbounds":[{"tag":"proxy","protocol":"trojan",'
          '"settings":{"servers":[{"address":"managed.example.test","port":443,'
          '"password":"fixture"}]}},{"tag":"direct","protocol":"freedom"}]}';
      final ordinary = VlessParser.parseUri(original)!;
      final managed = VpnConfig.fromJson({
        ...ordinary.toJson(),
        'id': 'managed-fixture',
        'name': 'JSON fixture',
        'rawUri': null,
        'rawXrayConfig': managedJson,
      });
      final writes = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      Future<String> copyFromMenu(VpnConfig config) async {
        writes.clear();
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpScreen(
          tester,
          screen: const ConfigsScreen(),
          selected: config,
        );
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Копировать URL'));
        await tester.pumpAndSettle();
        return writes.single;
      }

      expect(await copyFromMenu(ordinary), original);
      final copied = await copyFromMenu(managed);
      final bundle = DeeplinkRouter.parse(copied)!.connectionsBundle!;
      expect(bundle.configs.single.rawXrayConfig, managedJson);
      expect(bundle.subscriptions, isEmpty);
      expect(find.text('Ссылка Teapod скопирована'), findsOneWidget);
    },
  );

  testWidgets('appearance switches mascots and restores the selected palette', (
    tester,
  ) async {
    setPhoneSize(tester);
    final nordAccent = AppColors.accentGreen.toARGB32();
    SharedPreferences.setMockInitialValues({'accent_color': nordAccent});
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final channel in [
      const MethodChannel(AppConstants.methodChannel),
      const MethodChannel('${AppConstants.methodChannel}/events'),
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    Future<void> pumpApp() async {
      await tester.pumpWidget(
        withOverrides(
          const RepaintBoundary(key: Key('capture'), child: TeapodApp()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapLabel(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    Future<void> checkHome(AppPalette palette, Brightness brightness) async {
      final context = tester.element(find.byType(HomeScreen));
      final theme = Theme.of(context);
      expect(theme.brightness, brightness);
      expect(theme.extension<TeapodTokens>()!.palette, palette);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.map((image) => (image.image as AssetImage).assetName), [
        palette.mascotAsset,
      ]);
      await tester.runAsync(
        () => precacheImage(AssetImage(palette.mascotAsset), context),
      );
      await tester.pumpAndSettle();
    }

    await pumpApp();
    await checkHome(AppPalette.nord, Brightness.dark);
    await tapLabel('НАСТРОЙКИ');
    await tapLabel('Розовая');
    await capture(tester, 'settings-pink-dark');
    await tapLabel('VPN');
    await checkHome(AppPalette.pink, Brightness.dark);
    await capture(tester, 'home-pink-dark');

    await tapLabel('НАСТРОЙКИ');
    await tapLabel('СВЕТЛАЯ');
    await tester.pumpWidget(const SizedBox.shrink());
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await pumpApp();
    await checkHome(AppPalette.pink, Brightness.light);
    await capture(tester, 'home-pink-light');

    await tapLabel('НАСТРОЙКИ');
    await tapLabel('Nord');
    await tapLabel('VPN');
    await checkHome(AppPalette.nord, Brightness.light);
    expect(prefs.getInt('accent_color'), nordAccent);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
