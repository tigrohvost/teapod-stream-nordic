import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// The app's large setting is a minimum, preserving Android's nonlinear scale.
class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, {this.minimum = 1.0});

  final TextScaler system;
  final double minimum;

  @override
  double scale(double fontSize) =>
      math.max(system.scale(fontSize), fontSize * minimum);

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is AppTextScaler &&
      other.system == system &&
      other.minimum == minimum;

  @override
  int get hashCode => Object.hash(system, minimum);
}
