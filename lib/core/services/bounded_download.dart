import 'dart:convert';
import 'dart:io';

/// Read a finite response. The caller owns and closes the HTTP client.
Future<String> readBoundedBody(
  HttpClientResponse response, {
  int maxBytes = 8 * 1024 * 1024,
}) async {
  if (response.contentLength > maxBytes) {
    throw const FormatException('Документ слишком большой');
  }
  final bytes = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 15))) {
    if (bytes.length + chunk.length > maxBytes) {
      throw const FormatException('Документ слишком большой');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

Uri documentUri(String value) {
  final uri = Uri.parse(value);
  if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
    throw const FormatException('Нужна HTTP(S) ссылка');
  }
  return uri;
}
