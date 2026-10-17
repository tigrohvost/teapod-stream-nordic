class ConnectionPlanException implements Exception {
  final String code;
  final String message;
  const ConnectionPlanException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

/// Internal plan; xrayJson contains credentials and must never be shared as diagnostics.
class EffectiveConnectionPlan {
  final String xrayJson;
  final String mode;
  final String source;
  final int revision;
  final Map<String, Object?> appliedSettings;
  final List<String> unsupportedSettings;
  const EffectiveConnectionPlan({
    required this.xrayJson,
    required this.mode,
    required this.source,
    required this.revision,
    required this.appliedSettings,
    this.unsupportedSettings = const [],
  });
}
