import 'package:shared_preferences/shared_preferences.dart';
import 'storage_secure_service.dart';

/// One-time migration from plaintext SharedPreferences to EncryptedSharedPreferences.
/// Safe to call on every launch — skips immediately after the first successful run.
class StorageMigrationService {
  static const _flagKey = 'storage_migrated_v2';
  static Future<void>? _pending;

  static Future<void> runIfNeeded({StorageSecureService? secure}) =>
      _pending ??= _migrate(
        secure ?? StorageSecureService(),
      ).whenComplete(() => _pending = null);

  static Future<void> _migrate(StorageSecureService secure) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_flagKey) == true) return;

    try {
      // VPN configs: List<String> (each element is a JSON object) → single JSON array
      final rawConfigs = prefs.getStringList('vpn_configs') ?? [];
      if (rawConfigs.isNotEmpty) {
        await secure.writeConfigsRaw('[${rawConfigs.join(',')}]');
      }

      // Active config ID
      final activeId = prefs.getString('active_config_id');
      if (activeId != null) {
        await secure.writeActiveConfigId(activeId);
      }

      // Subscriptions: same format as configs
      final rawSubs = prefs.getStringList('subscriptions') ?? [];
      if (rawSubs.isNotEmpty) {
        await secure.writeSubscriptionsRaw('[${rawSubs.join(',')}]');
      }

      // SOCKS credentials
      final socksUser = prefs.getString('socks_user') ?? '';
      final socksPass = prefs.getString('socks_password') ?? '';
      if (socksUser.isNotEmpty || socksPass.isNotEmpty) {
        await secure.writeSocksCredentials(socksUser, socksPass);
      }

      // Mark complete and remove plaintext keys
      await prefs.setBool(_flagKey, true);
      for (final key in [
        'vpn_configs',
        'active_config_id',
        'subscriptions',
        'socks_user',
        'socks_password',
      ]) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Never let the caller commit an empty canonical snapshot after a partial
      // migration. Keep plaintext intact and allow retry in this process too.
      rethrow;
    }
  }
}
