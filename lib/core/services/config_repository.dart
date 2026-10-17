import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/config_state.dart';
import 'config_storage_service.dart';
import 'storage_secure_service.dart';

/// Serializes the whole read/modify/write transaction, across repository users.
/// One Keystore-backed value contains configs, subscription metadata and selection.
class ConfigRepository {
  final StorageSecureService secure;
  final ConfigStorageService legacy;
  static Future<void> _tail = Future.value();

  ConfigRepository({StorageSecureService? secure, ConfigStorageService? legacy})
    : secure = secure ?? StorageSecureService(),
      legacy = legacy ?? ConfigStorageService();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return next;
  }

  Future<ConfigState> load() => _serial(_load);

  Future<ConfigState> _load() async {
    final encoded = await secure.readConnectionsSnapshot();
    if (encoded != null) {
      final envelope = jsonDecode(encoded) as Map<String, dynamic>;
      final payload = envelope['payload'] as String;
      if (sha256.convert(utf8.encode(payload)).toString() !=
          envelope['sha256']) {
        throw const FormatException(
          'Повреждён снимок подключений; восстановите резервную копию',
        );
      }
      return ConfigState.fromJson(jsonDecode(payload) as Map<String, dynamic>);
    }
    final migrated = ConfigState(
      configs: await legacy.loadConfigs(),
      subscriptions: await legacy.loadSubscriptions(),
      activeConfigId: await legacy.loadActiveConfigId(),
      activeSubscriptionId: await legacy.loadActiveSubscriptionId(),
      pins: await legacy.loadPins(),
    );
    // Legacy values remain intact if migration fails. Never fall back to them
    // when an existing snapshot is damaged: that would resurrect deleted data.
    await _write(migrated);
    return migrated;
  }

  Future<void> _write(ConfigState state) {
    final payload = jsonEncode(state.toJson());
    return secure.writeConnectionsSnapshot(
      jsonEncode({
        'payload': payload,
        'sha256': sha256.convert(utf8.encode(payload)).toString(),
      }),
    );
  }

  Future<ConfigState> commit(ConfigState Function(ConfigState) update) =>
      _serial(() async {
        final current = await _load();
        final next = update(current);
        if (identical(current, next)) return current;
        final revised = next.copyWith(revision: current.revision + 1);
        await _write(revised);
        return revised;
      });
}
