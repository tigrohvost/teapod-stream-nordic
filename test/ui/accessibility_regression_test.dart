import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:teapodstream/ui/theme/app_colors.dart';
import 'package:teapodstream/ui/theme/app_theme.dart';
import 'package:teapodstream/ui/widgets/settings_shared.dart';
import 'package:teapodstream/ui/widgets/live_sparkline.dart';
import 'package:teapodstream/ui/widgets/pressable.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    GoogleFonts.config.allowRuntimeFetching = false;
    AppTheme.mono();
    AppTheme.sans();
    await GoogleFonts.pendingFonts();
  });
  test('all preset text accents have 4.5 contrast on every surface', () {
    for (final accent in AppColors.accentPresets) {
      for (final t in [TeapodTokens.dark(accent), TeapodTokens.light(accent)]) {
        for (final bg in [
          t.bg,
          t.bgElev,
          t.bgSunken,
          Color.alphaBlend(t.accentSoft, t.bg),
          Color.alphaBlend(t.accentSoft, t.bgElev),
          Color.alphaBlend(t.accentSoft, t.bgSunken),
        ]) {
          final a = t.accentText.computeLuminance(), b = bg.computeLuminance();
          final contrast = ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05);
          expect(contrast, greaterThanOrEqualTo(4.5), reason: '$accent on $bg');
        }
      }
    }
  });
  testWidgets(
    'switch has one actionable semantic node and activates by keyboard',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var toggles = 0;
      final t = TeapodTokens.dark(AppColors.accentCyan);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Brightness.dark, AppColors.accentCyan),
          home: Scaffold(
            body: SetRowToggle(
              t: t,
              title: 'Переключатель',
              value: true,
              onChange: (_) => toggles++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final node = tester.getSemantics(find.byType(SetRowToggle));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        node,
        matchesSemantics(
          label: 'Переключатель',
          hasEnabledState: true,
          isEnabled: true,
          hasToggledState: true,
          isToggled: true,
          hasTapAction: true,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(toggles, 1);
      semantics.dispose();
    },
  );
  testWidgets('inline settings fit narrow width with large labels', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final t = TeapodTokens.dark(AppColors.accentCyan);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Brightness.dark, AppColors.accentCyan),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SetInlineField(
              t: t,
              label: 'Observatory мин. интервал, сек',
              child: const SizedBox(width: 140, child: TextField()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('a round button reacts only inside its circle', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(Brightness.dark, AppColors.accentCyan),
        home: Center(
          child: Pressable(
            shape: BoxShape.circle,
            onTap: () => taps++,
            child: const SizedBox(width: 200, height: 200),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(Pressable));
    await tester.tapAt(box.topLeft + const Offset(8, 8));
    expect(taps, 0, reason: 'corner of the square box');
    await tester.tapAt(box.center);
    expect(taps, 1);
  });
  test('sparkline points stay finite and inside the chart', () {
    const size = Size(200, 42);
    expect(LiveSparkline.pointsFor([], size), isEmpty);
    expect(LiveSparkline.pointsFor([1], size), [const Offset(100, 21)]);

    final two = LiveSparkline.pointsFor([1, 2], size);
    expect(two.map((p) => p.dx), [0, 200]);
    expect(two.last.dy, lessThan(two.first.dy), reason: 'higher is faster');
    expect(two.last.dy, 2, reason: 'peak touches the top padding');

    final garbage = LiveSparkline.pointsFor([
      double.nan,
      double.infinity,
      -1,
    ], size);
    expect(garbage, hasLength(3));
    for (final p in garbage) {
      expect(p.dx.isFinite && p.dy.isFinite, isTrue);
      expect(p.dy, 40, reason: 'invalid samples sit on the baseline');
    }
    expect(
      LiveSparkline.pointsFor([1, 2], const Size(double.infinity, 42)),
      isEmpty,
    );
  });
  testWidgets('sparkline paints invalid samples without errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          child: LiveSparkline(
            samples: const [double.nan, double.infinity, -1],
            color: Colors.blue,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
