class DiagnosticRedactor {
  static String redact(String text, {Iterable<String> secrets = const []}) {
    var result = text;
    final ordered = secrets.where((s) => s.length >= 3).toSet().toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in ordered) {
      result = result.replaceAll(secret, '[REDACTED]');
    }
    result = result.replaceAll(
      RegExp(
        r'-----BEGIN[^\r\n]*PRIVATE KEY-----[\s\S]*?-----END[^\r\n]*PRIVATE KEY-----',
      ),
      '[PRIVATE KEY]',
    );
    result = result.replaceAll(
      RegExp(
        r'''(?:https?|vless|vmess|trojan|ss|hy2|hysteria2|teapod)://[^\s<>"']+''',
        caseSensitive: false,
      ),
      '[URL]',
    );
    result = result.replaceAll(
      RegExp(
        r'\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b',
        caseSensitive: false,
      ),
      '[UUID]',
    );
    result = result.replaceAllMapped(
      RegExp(
        r'''(["']?(?:password|passwd|pass|uuid|private_?key|public_?key|token|access_token|authorization|socksUser|socksPassword|username|secret|auth|id)["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}"[REDACTED]"',
    );
    result = result.replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[IP]');
    result = result.replaceAll(
      RegExp(
        r'(?<![\w])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*(?:%\w+)?',
        caseSensitive: false,
      ),
      '[IP]',
    );
    return result;
  }
}
