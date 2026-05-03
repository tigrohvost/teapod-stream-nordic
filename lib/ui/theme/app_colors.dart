import 'package:flutter/material.dart';

class AppColors {
  // ── Nord reference palette ────────────────────────────────────
  static const nord0 = Color(0xFF2E3440);
  static const nord1 = Color(0xFF3B4252);
  static const nord2 = Color(0xFF434C5E);
  static const nord3 = Color(0xFF4C566A);
  static const nord4 = Color(0xFFD8DEE9);
  static const nord5 = Color(0xFFE5E9F0);
  static const nord6 = Color(0xFFECEFF4);
  static const nord7 = Color(0xFF8FBCBB);
  static const nord8 = Color(0xFF88C0D0);
  static const nord9 = Color(0xFF81A1C1);
  static const nord10 = Color(0xFF5E81AC);
  static const nord11 = Color(0xFFBF616A);
  static const nord12 = Color(0xFFD08770);
  static const nord13 = Color(0xFFEBCB8B);
  static const nord14 = Color(0xFFA3BE8C);
  static const nord15 = Color(0xFFB48EAD);

  // ── Dark palette ──────────────────────────────────────────────
  static const bgDark = nord0;
  static const bgElevDark = nord1;
  static const bgSunkenDark = nord2;
  static const lineDark = nord3;
  static const lineSoftDark = nord2;
  static const textDark = nord6;
  static const textDimDark = nord5;
  static const textMutedDark = nord3;

  // ── Light palette ─────────────────────────────────────────────
  static const bgLight = nord6;
  static const bgElevLight = nord5;
  static const bgSunkenLight = nord4;
  static const lineLight = nord4;
  static const lineSoftLight = nord5;
  static const textLight = nord0;
  static const textDimLight = nord1;
  static const textMutedLight = nord3;

  static const danger = nord11;

  // ── Accent presets ────────────────────────────────────────────
  static const accentTeal = nord7;
  static const accentCyan = nord8;
  static const accentBlue = nord9;
  static const accentNavy = nord10;
  static const accentRed = nord11;
  static const accentOrange = nord12;
  static const accentGold = nord13;
  static const accentGreen = nord14;
  static const accentPurple = nord15;
  static const accentSnow = nord4;
  static const accentFrost = nord5;

  static const List<Color> accentPresets = [
    accentTeal,
    accentCyan,
    accentBlue,
    accentNavy,
    accentGreen,
    accentGold,
    accentOrange,
    accentRed,
    accentPurple,
    accentSnow,
    accentFrost,
  ];

  // ── Legacy aliases (used by un-migrated screens) ───────────────
  static const bg = bgDark;
  static const surface = bgElevDark;
  static const surfaceElevated = nord2;
  static const surfaceHighlight = nord3;
  static const primary = nord8;
  static const primaryDim = nord10;
  static const connected = nord14;
  static const connectedDim = Color(0xFF6E8B63);
  static const disconnected = nord3;
  static const connecting = nord13;
  static const error = nord11;
  static const textPrimary = textDark;
  static const textSecondary = textDimDark;
  static const textDisabled = nord3;
  static const border = nord3;
  static const borderAccent = nord9;
  static const logDebug = nord3;
  static const logInfo = nord8;
  static const logWarning = nord13;
  static const logError = nord11;
  static const chartUpload = nord8;
  static const chartDownload = nord14;
  static const protoVless = nord8;
  static const protoVmess = nord15;
  static const protoTrojan = nord11;
  static const protoShadowsocks = nord13;
  static const protoHysteria2 = nord7;
}

// ── Design token extension ────────────────────────────────────────

@immutable
class TeapodTokens extends ThemeExtension<TeapodTokens> {
  final Color bg;
  final Color bgElev;
  final Color bgSunken;
  final Color line;
  final Color lineSoft;
  final Color text;
  final Color textDim;
  final Color textMuted;
  final Color accent;
  final Color accentSoft;
  final Color accentFade;
  final Color danger;

  const TeapodTokens({
    required this.bg,
    required this.bgElev,
    required this.bgSunken,
    required this.line,
    required this.lineSoft,
    required this.text,
    required this.textDim,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.accentFade,
    required this.danger,
  });

  factory TeapodTokens.dark(Color accent) => TeapodTokens(
    bg: AppColors.bgDark,
    bgElev: AppColors.bgElevDark,
    bgSunken: AppColors.bgSunkenDark,
    line: AppColors.lineDark,
    lineSoft: AppColors.lineSoftDark,
    text: AppColors.textDark,
    textDim: AppColors.textDimDark,
    textMuted: AppColors.textMutedDark,
    accent: accent,
    accentSoft: accent.withAlpha(0x22),
    accentFade: accent.withAlpha(0x0F),
    danger: AppColors.danger,
  );

  factory TeapodTokens.light(Color accent) {
    // Preset accents are tuned for dark backgrounds (high lightness, low contrast on white).
    // Darken them to maintain readability on light surfaces.
    final a = _darkenAccentForLight(accent);
    return TeapodTokens(
      bg: AppColors.bgLight,
      bgElev: AppColors.bgElevLight,
      bgSunken: AppColors.bgSunkenLight,
      line: AppColors.lineLight,
      lineSoft: AppColors.lineSoftLight,
      text: AppColors.textLight,
      textDim: AppColors.textDimLight,
      textMuted: AppColors.textMutedLight,
      accent: a,
      accentSoft: a.withAlpha(0x28),
      accentFade: a.withAlpha(0x14),
      danger: AppColors.danger,
    );
  }

  /// Forces accent into a readable range for light backgrounds.
  /// Preserves hue; targets lightness ~0.40–0.48 (softer darkening).
  static Color _darkenAccentForLight(Color c) {
    final hsl = HSLColor.fromColor(c);
    final l = hsl.lightness;

    // Увеличили порог: если цвет уже темнее 0.48, не трогаем его (было 0.40)
    if (l <= 0.48) return c;

    // Near-gray / mono — keep low saturation, but make it less intensely dark
    // Подняли светлоту серого с очень темного 0.28 до более мягкого 0.38
    if (hsl.saturation < 0.18) {
      return hsl
          .withLightness(0.38)
          .withSaturation((hsl.saturation * 0.6).clamp(0.0, 1.0))
          .toColor();
    }

    // Chromatic: target lightness 0.40 + small bonus for high-saturation colours
    // Подняли базовую светлоту с 0.32 до 0.40, и сместили верхнюю границу до 0.48
    final target = (0.40 + hsl.saturation * 0.08).clamp(0.0, 0.48);
    return hsl.withLightness(target).toColor();
  }

  @override
  TeapodTokens copyWith({
    Color? bg,
    Color? bgElev,
    Color? bgSunken,
    Color? line,
    Color? lineSoft,
    Color? text,
    Color? textDim,
    Color? textMuted,
    Color? accent,
    Color? accentSoft,
    Color? accentFade,
    Color? danger,
  }) => TeapodTokens(
    bg: bg ?? this.bg,
    bgElev: bgElev ?? this.bgElev,
    bgSunken: bgSunken ?? this.bgSunken,
    line: line ?? this.line,
    lineSoft: lineSoft ?? this.lineSoft,
    text: text ?? this.text,
    textDim: textDim ?? this.textDim,
    textMuted: textMuted ?? this.textMuted,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    accentFade: accentFade ?? this.accentFade,
    danger: danger ?? this.danger,
  );

  @override
  TeapodTokens lerp(TeapodTokens? other, double t) {
    if (other == null) return this;
    return TeapodTokens(
      bg: Color.lerp(bg, other.bg, t)!,
      bgElev: Color.lerp(bgElev, other.bgElev, t)!,
      bgSunken: Color.lerp(bgSunken, other.bgSunken, t)!,
      line: Color.lerp(line, other.line, t)!,
      lineSoft: Color.lerp(lineSoft, other.lineSoft, t)!,
      text: Color.lerp(text, other.text, t)!,
      textDim: Color.lerp(textDim, other.textDim, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentFade: Color.lerp(accentFade, other.accentFade, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

// Convenience accessor
extension TeapodTokensContext on BuildContext {
  TeapodTokens get t => Theme.of(this).extension<TeapodTokens>()!;
}
