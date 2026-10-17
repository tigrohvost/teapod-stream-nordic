import 'dart:convert';

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
        r'''(?:https?|wss?|socks5?|vless|vmess|trojan|ss|hy2|hysteria2?|tuic|wireguard|teapod)://[^\s<>"']+''',
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
    // Authorization schemes put the credential after a space, which the
    // key/value pattern below would stop at.
    result = result.replaceAllMapped(
      RegExp(r'\b(Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]+'),
      (match) => '${match[1]} [REDACTED]',
    );
    // The left boundary keeps bypass=, sessionId=, pid= and valid: readable.
    result = result.replaceAllMapped(
      RegExp(
        r'''((?<![\w-])["']?(?:password|passwd|pass|uuid|private_?key|public_?key|token|access_token|authorization|socksUser|socksPassword|username|user|secret|auth|id|wsPath|wsHost|path|host|serverName|serviceName|grpcServiceName|shortIds?|spiderX|postQuantumKey|obfsPassword|address)["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\[[^\]]*\]|[^\s,;}\]]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}"[REDACTED]"',
    );
    result = result.replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[IP]');
    // Candidates are confirmed by the IPv6 parser, so HH:MM:SS timestamps
    // (which look like hex groups) are left alone.
    result = result.replaceAllMapped(
      RegExp(
        r'(?<![\w:.])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%\w+)?(?![\w:])',
        caseSensitive: false,
      ),
      (match) => _isIPv6(match[0]!) ? '[IP]' : match[0]!,
    );
    return result;
  }

  static bool _isIPv6(String candidate) {
    try {
      Uri.parseIPv6Address(candidate.split('%').first);
      return true;
    } on FormatException {
      return false;
    }
  }

  static const _xraySecretKeys = {
    'address',
    'serverName',
    'host',
    'Host',
    'path',
    'serviceName',
    'id',
    'password',
    'pass',
    'user',
    'publicKey',
    'shortId',
    'shortIds',
    'spiderX',
  };

  /// Server identities and credentials of a managed (raw) xray config, for
  /// the literal secrets list. Only outbounds are walked: routing and DNS
  /// entries are public and useful for diagnosis.
  static List<String> secretsFromXrayJson(String? json) {
    if (json == null || json.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map || decoded['outbounds'] is! List) return const [];
    final found = <String>{};
    void walk(Object? node) {
      if (node is Map) {
        node.forEach((key, value) {
          if (_xraySecretKeys.contains(key)) {
            if (value is String) found.add(value);
            if (value is List) found.addAll(value.whereType<String>());
          }
          walk(value);
        });
      } else if (node is List) {
        node.forEach(walk);
      }
    }

    walk(decoded['outbounds']);
    return found.toList();
  }
}
