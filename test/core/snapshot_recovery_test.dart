import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/config_state.dart';
import 'package:teapodstream/core/models/pinned_ref.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/core/services/config_repository.dart';
import 'package:teapodstream/core/services/config_storage_service.dart';
import 'package:teapodstream/core/services/storage_secure_service.dart';

String _envelope(Map<String, dynamic> state, {bool badChecksum = false}) {
  final payload = jsonEncode(state);
  return jsonEncode({
    'payload': payload,
    'sha256': badChecksum
        ? '0' * 64
        : sha256.convert(utf8.encode(payload)).toString(),
  });
}

class _Secure extends StorageSecureService {
  String? raw;
  String? damaged;
  bool failRead = false;
  int writes = 0;
  _Secure(this.raw);
  @override
  Future<String?> readConnectionsSnapshot() async {
    if (failRead) throw StateError('keystore unavailable');
    return raw;
  }

  @override
  Future<void> writeConnectionsSnapshot(String json) async {
    writes++;
    raw = json;
  }

  @override
  Future<void> writeDamagedConnectionsSnapshot(String value) async =>
      damaged = value;
}

class _Legacy extends ConfigStorageService {
  List<VpnConfig> configs;
  bool fail = false;
  _Legacy(this.configs);
  void _check() {
    if (fail) throw StateError('legacy keys unreadable');
  }

  @override
  Future<List<VpnConfig>> loadConfigs() async {
    _check();
    return configs;
  }

  @override
  Future<List<Subscription>> loadSubscriptions() async {
    _check();
    return const [];
  }

  @override
  Future<String?> loadActiveConfigId() async => null;
  @override
  Future<String?> loadActiveSubscriptionId() async => null;
  @override
  Future<List<PinnedRef>> loadPins() async => const [];
}

VpnConfig _config(String name) => VpnConfig(
  id: name,
  name: name,
  protocol: VpnProtocol.trojan,
  address: '$name.example.test',
  port: 443,
  uuid: '',
  password: 'secret',
  security: VpnSecurity.tls,
  transport: VpnTransport.tcp,
  createdAt: DateTime(2026),
);

void main() {
  test('damaged snapshot is kept aside and the v1.6.6 data restored', () async {
    final damaged = _envelope(
      ConfigState(configs: [_config('newer')]).toJson(),
      badChecksum: true,
    );
    final secure = _Secure(damaged);
    final repo = ConfigRepository(
      secure: secure,
      legacy: _Legacy([_config('legacy')]),
    );
    final state = await repo.load();
    expect(state.configs.map((c) => c.name), ['legacy']);
    expect(secure.damaged, damaged);
    expect(repo.takeRecoveryNotice(), contains('повреждён'));
    // The app is usable again: a backup can be imported (committed).
    final next = await repo.commit(
      (c) => c.copyWith(configs: [...c.configs, _config('restored')]),
    );
    expect(next.configs.map((c) => c.name), ['legacy', 'restored']);
  });

  test(
    'damaged snapshot without legacy data yields a usable empty state',
    () async {
      final secure = _Secure('{not json');
      final repo = ConfigRepository(secure: secure, legacy: _Legacy([]));
      expect((await repo.load()).configs, isEmpty);
      expect(secure.damaged, '{not json');
      final next = await repo.commit(
        (c) => c.copyWith(configs: [_config('imported')]),
      );
      expect(next.configs.single.name, 'imported');
    },
  );

  test('one unreadable entry does not hide the other connections', () async {
    final json = ConfigState(configs: [_config('good')]).toJson();
    (json['configs'] as List).add({'id': 'broken'});
    final raw = _envelope(json);
    final secure = _Secure(raw);
    final repo = ConfigRepository(secure: secure, legacy: _Legacy([]));
    final state = await repo.load();
    expect(state.configs.map((c) => c.name), ['good']);
    expect(secure.damaged, raw);
  });

  test(
    'failed first migration never hides the v1.6.6 data behind a new snapshot',
    () async {
      final secure = _Secure(null);
      final legacy = _Legacy([_config('legacy')])..fail = true;
      final repo = ConfigRepository(secure: secure, legacy: legacy);
      expect((await repo.load()).configs, isEmpty);
      expect(secure.writes, 0);
      // The user adds a connection while the old keys are unreadable.
      await repo.commit((c) => c.copyWith(configs: [_config('added')]));
      legacy.fail = false;
      final merged = await repo.load();
      expect(merged.configs.map((c) => c.name), ['added', 'legacy']);
      // Once merged, the marker is gone and the result is persisted.
      expect(
        (jsonDecode(secure.raw!) as Map).containsKey('legacyPending'),
        isFalse,
      );
    },
  );

  test('unreadable storage is never overwritten by a commit', () async {
    final secure = _Secure(_envelope(ConfigState().toJson()))..failRead = true;
    final repo = ConfigRepository(secure: secure, legacy: _Legacy([]));
    expect((await repo.load()).configs, isEmpty);
    await expectLater(
      repo.commit((c) => c.copyWith(configs: [_config('x')])),
      throwsStateError,
    );
    expect(secure.writes, 0);
  });

  test('unknown probe status in a saved config is tolerated', () {
    final json = _config('a').toJson()..['probeStatus'] = 'fromTheFuture';
    expect(VpnConfig.fromJson(json).probeStatus, ProbeStatus.unknown);
  });
}
