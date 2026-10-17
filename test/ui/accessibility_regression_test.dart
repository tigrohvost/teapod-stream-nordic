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
  for (final samples in <List<double>>[
    [],
    [1],
    [1, 2],
    [double.nan, double.infinity, -1],
  ]) {
    testWidgets('sparkline safely paints $samples', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 200,
            child: LiveSparkline(samples: samples, color: Colors.blue),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
