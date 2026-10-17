import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/config_state.dart';
import 'config_storage_service.dart';
import 'storage_secure_service.dart';

/// Serializes the whole read/modify/write transaction, across repository users.
/// One Keystore-backed value contains configs, subscription metadata and selection.
///
/// Loading never fails: a damaged snapshot is kept aside under a separate key
/// and the app continues from the best recoverable state, so backups can still
/// be imported. [takeRecoveryNotice] tells the user what happened.
class ConfigRepository {
  final StorageSecureService secure;
  final ConfigStorageService legacy;
  static Future<void> _tail = Future.value();
  String? _recoveryNotice;

  /// Set while the v1.6.6 keys could not be read; the next successful read
  /// merges them instead of letting an early snapshot hide them forever.
  bool _legacyPending = false;
  bool _readFailed = false;

  ConfigRepository({StorageSecureService? secure, ConfigStorageService? legacy})
    : secure = secure ?? StorageSecureService(),
      legacy = legacy ?? ConfigStorageService();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return next;
  }

  /// A one-shot, user-facing description of the last recovery, if any.
  String? takeRecoveryNotice() {
    final notice = _recoveryNotice;
    _recoveryNotice = null;
    return notice;
  }

  Future<ConfigState> load() => _serial(_load);

  Future<ConfigState> _load() async {
    String? encoded;
    _readFailed = false;
    try {
      encoded = await secure.readConnectionsSnapshot();
    } catch (e) {
      _readFailed = true;
      // Unreadable storage (e.g. lost Keystore key). Nothing to preserve, and
      // nothing is written here: a transient failure must not wipe good data.
      _recoveryNotice =
          'Не удалось прочитать сохранённые подключения ($e). '
          'Восстановите их из резервной копии.';
      return ConfigState();
    }
    if (encoded == null) return _migrate();
    try {
      final envelope = jsonDecode(encoded) as Map<String, dynamic>;
      final payload = envelope['payload'] as String;
      if (sha256.convert(utf8.encode(payload)).toString() !=
          envelope['sha256']) {
        throw const FormatException('checksum mismatch');
      }
      final (state, dropped) = ConfigState.fromJsonLenient(
        jsonDecode(payload) as Map<String, dynamic>,
      );
      if (dropped > 0) {
        await _keepDamaged(encoded);
        _recoveryNotice =
            'Не удалось прочитать подключений: $dropped; '
            'исходный снимок сохранён отдельно.';
      }
      _legacyPending = envelope['legacyPending'] == true;
      return _legacyPending ? _mergeLegacy(state) : state;
    } catch (_) {
      return _recover(encoded);
    }
  }

  Future<void> _keepDamaged(String raw) async {
    try {
      await secure.writeDamagedConnectionsSnapshot(raw);
    } catch (_) {
      /* Best effort: recovery must not depend on it. */
    }
  }

  Future<ConfigState> _legacyState() async => ConfigState(
    configs: await legacy.loadConfigs(),
    subscriptions: await legacy.loadSubscriptions(),
    activeConfigId: await legacy.loadActiveConfigId(),
    activeSubscriptionId: await legacy.loadActiveSubscriptionId(),
    pins: await legacy.loadPins(),
  );

  /// First start after the upgrade: build the snapshot from the v1.6.6 keys.
  /// The legacy keys are never deleted, so a failure here only postpones it.
  Future<ConfigState> _migrate() async {
    final ConfigState migrated;
    try {
      migrated = await _legacyState();
    } catch (e) {
      _legacyPending = true;
      _recoveryNotice =
          'Подключения предыдущей версии пока не прочитаны ($e); '
          'повторная попытка при следующем запуске.';
      return ConfigState();
    }
    _legacyPending = false;
    try {
      await _write(migrated);
    } catch (_) {
      // Retried on the next load; the in-memory state is complete.
    }
    return migrated;
  }

  /// Adds v1.6.6 entries that a snapshot written during a failed migration
  /// doesn't contain yet. Existing snapshot entries win.
  Future<ConfigState> _mergeLegacy(ConfigState state) async {
    final ConfigState old;
    try {
      old = await _legacyState();
    } catch (_) {
      return state;
    }
    final identities = state.configs.map((c) => c.connectionIdentity).toSet();
    final urls = state.subscriptions.map((s) => s.url).toSet();
    final merged = state.copyWith(
      configs: [
        ...state.configs,
        ...old.configs.where((c) => identities.add(c.connectionIdentity)),
      ],
      subscriptions: [
        ...state.subscriptions,
        ...old.subscriptions.where((s) => urls.add(s.url)),
      ],
      pins: {...state.pins, ...old.pins}.toList(),
      activeConfigId: state.activeConfigId ?? old.activeConfigId,
      activeSubscriptionId:
          state.activeSubscriptionId ?? old.activeSubscriptionId,
    );
    _legacyPending = false;
    try {
      await _write(merged);
    } catch (_) {
      _legacyPending = true;
    }
    return merged;
  }

  /// The snapshot is unreadable: keep it aside, then continue from the v1.6.6
  /// keys if they hold anything, otherwise from an empty but usable state.
  Future<ConfigState> _recover(String damaged) async {
    await _keepDamaged(damaged);
    var recovered = ConfigState();
    try {
      recovered = await _legacyState();
    } catch (_) {
      /* Fall through to an empty state. */
    }
    final fromLegacy =
        recovered.configs.isNotEmpty || recovered.subscriptions.isNotEmpty;
    _recoveryNotice = fromLegacy
        ? 'Снимок подключений повреждён; восстановлены данные, сохранённые '
              'до обновления (удалённые позже подключения могли вернуться).'
        : 'Снимок подключений повреждён; повреждённая копия сохранена. '
              'Восстановите подключения из резервной копии.';
    try {
      await _write(recovered);
    } catch (_) {
      // The damaged copy is preserved; the next commit retries the write.
    }
    return recovered;
  }

  Future<void> _write(ConfigState state) {
    final payload = jsonEncode(state.toJson());
    return secure.writeConnectionsSnapshot(
      jsonEncode({
        'payload': payload,
        'sha256': sha256.convert(utf8.encode(payload)).toString(),
        if (_legacyPending) 'legacyPending': true,
      }),
    );
  }

  Future<ConfigState> commit(ConfigState Function(ConfigState) update) =>
      _serial(() async {
        final current = await _load();
        if (_readFailed) {
          // Writing now could replace data that is only temporarily unreadable.
          throw StateError('Хранилище подключений недоступно');
        }
        final next = update(current);
        if (identical(current, next)) return current;
        final revised = next.copyWith(revision: current.revision + 1);
        await _write(revised);
        return revised;
      });
}
