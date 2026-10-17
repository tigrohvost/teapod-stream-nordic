import 'dart:convert';
import 'vpn_config.dart';
import '../services/config_storage_service.dart' show Subscription;

class ConnectionsBundle {
  static const int currentVersion = 1;
  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxItems = 10000;

  final int version;
  final DateTime exportedAt;
  final String? label;
  final List<VpnConfig> configs;
  final List<Subscription> subscriptions;
  // Populated when deserializing compact format (rawUri strings instead of full VpnConfig objects)
  final List<String> rawUris;
  // Populated when deserializing compact format (subscription URLs instead of full Subscription objects)
  final List<String> subscriptionUrls;

  const ConnectionsBundle({
    this.version = currentVersion,
    required this.exportedAt,
    this.label,
    this.configs = const [],
    this.subscriptions = const [],
    this.rawUris = const [],
    this.subscriptionUrls = const [],
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'exportedAt': exportedAt.toIso8601String(),
    if (label != null) 'label': label,
    'configs': [...configs.map((c) => c.toJson()), ...rawUris],
    'subscriptions': [
      ...subscriptions.map((s) => s.toJson()),
      ...subscriptionUrls,
    ],
  };

  Map<String, dynamic> toCompactJson() => {
    'version': version,
    'exportedAt': exportedAt.toIso8601String(),
    if (label != null) 'label': label,
    // Full objects preserve edits (pins, insecure flag, managed JSON) that the
    // original URI cannot represent. Incoming compact strings stay supported.
    'configs': [...configs.map((c) => c.toJson()), ...rawUris],
    'subscriptions': [
      ...subscriptions.map((s) => s.toJson()),
      ...subscriptionUrls,
    ],
  };

  factory ConnectionsBundle.fromJson(Map<String, dynamic> json) {
    if (json['version'] != currentVersion) {
      throw const FormatException('Неподдерживаемая версия набора');
    }
    if (utf8.encode(jsonEncode(json)).length > maxBytes ||
        (json['configs'] as List? ?? []).length +
                (json['subscriptions'] as List? ?? []).length >
            maxItems) {
      throw const FormatException('Слишком большой набор подключений');
    }
    final rawUris = <String>[];
    final fullConfigs = <VpnConfig>[];
    for (final e in (json['configs'] as List<dynamic>? ?? [])) {
      if (e is String) {
        rawUris.add(e);
      } else if (e is Map<String, dynamic>) {
        fullConfigs.add(VpnConfig.fromJson(e));
      } else {
        throw const FormatException('Неверный элемент набора');
      }
    }

    final subUrls = <String>[];
    final fullSubs = <Subscription>[];
    for (final e in (json['subscriptions'] as List<dynamic>? ?? [])) {
      if (e is String) {
        subUrls.add(e);
      } else if (e is Map<String, dynamic>) {
        fullSubs.add(Subscription.fromJson(e));
      } else {
        throw const FormatException('Неверный элемент подписки');
      }
    }

    return ConnectionsBundle(
      version: json['version'] as int? ?? 1,
      exportedAt: DateTime.parse(json['exportedAt'] as String),
      label: json['label'] as String?,
      configs: fullConfigs,
      subscriptions: fullSubs,
      rawUris: rawUris,
      subscriptionUrls: subUrls,
    );
  }

  bool get isCompact => rawUris.isNotEmpty || subscriptionUrls.isNotEmpty;

  String toBase64() {
    final bytes = utf8.encode(jsonEncode(toJson()));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String toCompactBase64() {
    final bytes = utf8.encode(jsonEncode(toCompactJson()));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static ConnectionsBundle fromBase64(String b64) {
    if (b64.length > (maxBytes * 4 ~/ 3) + 4) {
      throw const FormatException('Слишком большой набор подключений');
    }
    final padded = b64.padRight((b64.length + 3) ~/ 4 * 4, '=');
    final json = utf8.decode(base64Url.decode(padded));
    return ConnectionsBundle.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }

  String toDeeplink() => 'teapod://import/connections?data=${toBase64()}';
  String toCompactDeeplink() =>
      'teapod://import/connections?data=${toCompactBase64()}';
}
