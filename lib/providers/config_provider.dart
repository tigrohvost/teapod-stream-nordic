import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/interfaces/vpn_engine.dart';
import '../protocols/xray/xray_engine.dart';
import 'package:uuid/uuid.dart';
import '../core/models/vpn_config.dart';
import '../core/models/pinned_ref.dart';
import '../core/models/connections_bundle.dart';
import '../core/models/config_state.dart';
import '../core/services/config_storage_service.dart';
import '../core/services/config_repository.dart';
import '../core/services/import_service.dart';
import '../core/services/subscription_service.dart';
import '../core/services/device_service.dart';
import '../core/services/log_service.dart';
import '../core/services/settings_service.dart';
import 'settings_provider.dart';
export '../core/models/config_state.dart';
export '../core/services/import_service.dart'
    show ImportPlan, ImportConnectionsResult;

/// Outcome of a subscription add/refresh: usable entries and how many of the
/// document's entries were left out (unsupported, malformed or rejected).
class SubscriptionRefreshResult {
  final int configs;
  final int skipped;
  const SubscriptionRefreshResult({
    required this.configs,
    required this.skipped,
  });
}

final configRepositoryProvider = Provider((ref) => ConfigRepository());

/// Device identity for providers that limit devices (X-Hwid headers).
final hwidInfoProvider = Provider<Future<HwidDeviceInfo?> Function()>(
  (ref) => DeviceService.getHwidInfo,
);
final subscriptionServiceProvider = Provider((ref) => SubscriptionService());
final configValidationProvider = Provider<Future<void> Function(VpnConfig)>(
  (ref) => (config) async {
    if (Platform.isAndroid && config.rawXrayConfig != null) {
      await XrayEngine().validate(
        config,
        const VpnEngineOptions(
          socksPort: 10808,
          httpPort: 0,
          socksUser: '',
          socksPassword: '',
        ),
      );
    }
  },
);

class ConfigNotifier extends AsyncNotifier<ConfigState> {
  final _refreshGeneration = <String, int>{};
  ConfigRepository get _repository => ref.read(configRepositoryProvider);
  ImportService get _validator =>
      ImportService(validateConfig: ref.read(configValidationProvider));
  Future<void> _validate(VpnConfig config) => _validator.validate(config);

  /// Drops invalid entries; fails only when nothing usable remains.
  Future<(List<VpnConfig>, int)> _usable(
    SubscriptionFetchResult fetched,
  ) async {
    final checked = await _validator.validateEach(fetched.configs);
    if (checked.valid.isEmpty) {
      throw SubscriptionService.rejection(
        checked.firstError,
        'Подписка не содержит корректных подключений',
      );
    }
    return (checked.valid, fetched.skippedItems + checked.invalid);
  }

  /// Every subscription download sends the user's HWID and User-Agent
  /// settings, whichever screen or import channel started it.
  Future<SubscriptionFetchResult> Function(String) _fetcher({
    bool allowSelfSigned = false,
  }) {
    Future<(AppSettings, HwidDeviceInfo?)>? identity;
    Future<(AppSettings, HwidDeviceInfo?)> resolve() async {
      final settings = await ref.read(settingsProvider.future);
      final hwid = settings.hwidEnabled
          ? await ref.read(hwidInfoProvider)()
          : null;
      return (settings, hwid);
    }

    return (url) async {
      final (settings, hwid) = await (identity ??= resolve());
      return ref
          .read(subscriptionServiceProvider)
          .fetchSubscription(
            url,
            allowSelfSigned: allowSelfSigned,
            hwid: hwid,
            userAgent: settings.subUserAgent,
          );
    };
  }

  void _logSkipped(String name, int skipped) {
    if (skipped == 0) return;
    ref
        .read(logServiceProvider.notifier)
        .addWarning(
          'Подписка «$name»: пропущено подключений: $skipped '
          '(неподдерживаемые или некорректные)',
          source: 'subscription',
        );
  }

  @override
  Future<ConfigState> build() async {
    final state = await _repository.load();
    _reportRecovery();
    return state;
  }

  /// A recovered snapshot must be visible, not silently replaced.
  void _reportRecovery() {
    final notice = _repository.takeRecoveryNotice();
    if (notice == null) return;
    ref.read(logServiceProvider.notifier).addError(notice, source: 'storage');
  }

  Future<void> _commit(ConfigState Function(ConfigState) update) async {
    await future;
    final next = await _repository.commit(update);
    _reportRecovery();
    if (ref.mounted && next.revision >= (state.value?.revision ?? -1)) {
      state = AsyncData(next);
    }
  }

  Future<void> togglePin(VpnConfig c) => _commit((current) {
    final pin = PinnedRef(subscriptionId: c.subscriptionId, name: c.name);
    final pins = [...current.pins];
    if (!pins.remove(pin)) pins.add(pin);
    return current.copyWith(pins: pins);
  });

  Future<void> unpin(PinnedRef pin) =>
      _commit((c) => c.copyWith(pins: c.pins.where((p) => p != pin).toList()));
  Future<void> addConfig(VpnConfig config) => addConfigs([config]);
  Future<void> addConfigs(List<VpnConfig> configs) async {
    for (final config in configs) {
      await _validate(config);
    }
    await _commit((c) {
      final keys = c.configs.map((e) => e.connectionIdentity).toSet();
      return c.copyWith(
        configs: [
          ...c.configs,
          ...configs.where((e) => keys.add(e.connectionIdentity)),
        ],
      );
    });
  }

  Future<void> removeConfig(String id) => _commit(
    (c) => c.copyWith(
      configs: c.configs.where((e) => e.id != id).toList(),
      clearActive: c.activeConfigId == id,
    ),
  );

  Future<void> setActiveConfig(String? id) => _commit((c) {
    if (id != null && !c.configs.any((e) => e.id == id)) return c;
    return c.copyWith(
      activeConfigId: id,
      clearActive: id == null,
      clearActiveSub: true,
    );
  });

  Future<void> setActiveSubscription(String? id) => _commit((c) {
    if (id != null && !c.subscriptions.any((s) => s.id == id)) return c;
    return c.copyWith(activeSubscriptionId: id, clearActiveSub: id == null);
  });

  Future<void> updateConfig(VpnConfig updated) async {
    await _validate(updated);
    await _commit(
      (c) => c.copyWith(
        configs: c.configs
            .map((e) => e.id == updated.id ? updated : e)
            .toList(),
      ),
    );
  }

  Future<SubscriptionRefreshResult> addSubscriptionFromUrl(
    String url, {
    String? name,
    bool allowSelfSigned = false,
  }) async {
    if (!ImportService.validUrl(url)) {
      throw const FormatException('Неверный URL подписки');
    }
    final initial = await future;
    final original = initial.subscriptions
        .where((s) => s.url == url)
        .firstOrNull;
    final generation = (_refreshGeneration[url] ?? 0) + 1;
    _refreshGeneration[url] = generation;
    final fetched = await _fetcher(allowSelfSigned: allowSelfSigned)(url);
    final (usable, skipped) = await _usable(fetched);
    await _commit((current) {
      if (_refreshGeneration[url] != generation) return current;
      final existing = current.subscriptions
          .where((s) => s.url == url)
          .firstOrNull;
      if (original != null && existing?.id != original.id) return current;
      final subId = existing?.id ?? const Uuid().v4();
      final old = {
        for (final c in current.configs.where((c) => c.subscriptionId == subId))
          c.connectionIdentity: c,
      };
      final keys = <String>{};
      final fresh = usable.where((c) => keys.add(c.connectionIdentity)).map((
        c,
      ) {
        final previous = old[c.connectionIdentity];
        return c.copyWith(
          id: previous?.id,
          subscriptionId: subId,
          latencyMs: previous?.latencyMs,
          lastPingedAt: previous?.lastPingedAt,
          probeStatus: previous?.probeStatus ?? ProbeStatus.unknown,
          lastSuccessfulLatencyMs: previous?.lastSuccessfulLatencyMs,
          lastSuccessfulPingAt: previous?.lastSuccessfulPingAt,
        );
      }).toList();
      final sub = Subscription(
        id: subId,
        name:
            name ??
            existing?.name ??
            fetched.profileTitle ??
            Uri.parse(url).host,
        url: url,
        createdAt: existing?.createdAt ?? DateTime.now(),
        lastFetchedAt: DateTime.now(),
        expireAt: fetched.expireAt,
        uploadBytes: fetched.uploadBytes,
        downloadBytes: fetched.downloadBytes,
        totalBytes: fetched.totalBytes,
        announce: fetched.announce,
        announceUrl: fetched.announceUrl,
      );
      final configs = [
        ...current.configs.where((c) => c.subscriptionId != subId),
        ...fresh,
      ];
      final active = current.activeConfig;
      final carried = active?.subscriptionId == subId
          ? matchRefreshedConfig(active!, fresh)?.id
          : current.activeConfigId;
      return current.copyWith(
        configs: configs,
        subscriptions: [
          ...current.subscriptions.where((s) => s.id != subId),
          sub,
        ],
        activeConfigId:
            carried ??
            (active == null && original == null ? fresh.first.id : null),
        clearActive: active != null && carried == null,
      );
    });
    _logSkipped(name ?? original?.name ?? fetched.profileTitle ?? '', skipped);
    return SubscriptionRefreshResult(configs: usable.length, skipped: skipped);
  }

  Future<void> renameSubscription(String id, String name) => _commit(
    (c) => c.copyWith(
      subscriptions: c.subscriptions
          .map((s) => s.id == id ? s.copyWith(name: name) : s)
          .toList(),
    ),
  );

  Future<void> replaceSubscriptionUrl(String id, String url) async {
    if (!ImportService.validUrl(url)) {
      throw const FormatException('Неверный URL подписки');
    }
    final original = (await future).subscriptions
        .where((s) => s.id == id)
        .first;
    final generation = (_refreshGeneration['replace:$id'] ?? 0) + 1;
    _refreshGeneration['replace:$id'] = generation;
    final fetched = await _fetcher()(url);
    final (usable, skipped) = await _usable(fetched);
    await _commit((c) {
      if (_refreshGeneration['replace:$id'] != generation ||
          !c.subscriptions.any((s) => s.id == id && s.url == original.url)) {
        return c;
      }
      _refreshGeneration[original.url] =
          (_refreshGeneration[original.url] ?? 0) + 1;
      final configs = usable
          .map((e) => e.copyWith(subscriptionId: id))
          .toList();
      final selected = c.activeConfig?.subscriptionId == id;
      final active = selected
          ? matchRefreshedConfig(c.activeConfig!, configs)?.id
          : c.activeConfigId;
      return c.copyWith(
        configs: [
          ...c.configs.where((e) => e.subscriptionId != id),
          ...configs,
        ],
        subscriptions: c.subscriptions
            .map(
              (s) => s.id != id
                  ? s
                  : Subscription.fromJson({
                      ...s.toJson(),
                      'url': url,
                      'lastFetchedAt': DateTime.now().toIso8601String(),
                    }),
            )
            .toList(),
        activeConfigId: active,
        clearActive: selected && active == null,
      );
    });
    _logSkipped(original.name, skipped);
  }

  Future<void> removeSubscription(String id) async {
    await _commit((c) {
      _refreshGeneration['replace:$id'] =
          (_refreshGeneration['replace:$id'] ?? 0) + 1;
      final sub = c.subscriptions.where((s) => s.id == id).firstOrNull;
      if (sub != null) {
        _refreshGeneration[sub.url] = (_refreshGeneration[sub.url] ?? 0) + 1;
      }
      return c.copyWith(
        configs: c.configs.where((e) => e.subscriptionId != id).toList(),
        subscriptions: c.subscriptions.where((s) => s.id != id).toList(),
        clearActive: c.activeConfig?.subscriptionId == id,
        clearActiveSub: c.activeSubscriptionId == id,
      );
    });
  }

  Future<void> refreshStaleSubscriptions({int intervalHours = 6}) async {
    final current = await future;
    for (final sub in current.subscriptions) {
      if (sub.lastFetchedAt != null &&
          DateTime.now().difference(sub.lastFetchedAt!) <=
              Duration(hours: intervalHours)) {
        continue;
      }
      if (!(await future).subscriptions.any((s) => s.id == sub.id)) continue;
      try {
        await addSubscriptionFromUrl(sub.url);
      } catch (e) {
        // The working snapshot is kept; the failure must still be visible.
        ref
            .read(logServiceProvider.notifier)
            .addWarning(
              'Не удалось обновить подписку «${sub.name}»: '
              '${e is FormatException ? e.message : e}',
              source: 'subscription',
            );
      }
    }
  }

  static VpnConfig? matchRefreshedConfig(
    VpnConfig old,
    List<VpnConfig> fresh,
  ) =>
      fresh
          .where((c) => c.connectionIdentity == old.connectionIdentity)
          .firstOrNull ??
      fresh
          .where(
            (c) =>
                c.name == old.name &&
                c.address == old.address &&
                c.port == old.port,
          )
          .firstOrNull ??
      fresh.where((c) => c.name == old.name).firstOrNull ??
      fresh
          .where((c) => c.address == old.address && c.port == old.port)
          .firstOrNull;

  Future<ImportPlan> prepareImport(
    ConnectionsBundle bundle, {
    bool allowSelfSigned = false,
    bool activateSingle = false,
  }) => ImportService(
    validateConfig: ref.read(configValidationProvider),
    fetchSubscription: _fetcher(allowSelfSigned: allowSelfSigned),
  ).prepare(bundle, activateSingle: activateSingle);

  Future<ImportConnectionsResult> applyImport(ImportPlan plan) async {
    late ImportConnectionsResult result;
    await _commit((c) {
      final applied = ImportService.apply(c, plan);
      result = applied.$2;
      return applied.$1;
    });
    return result;
  }

  Future<ImportConnectionsResult> importBundle(ConnectionsBundle bundle) async {
    final plan = await prepareImport(bundle);
    if (plan.invalidItems > 0) {
      throw const FormatException('Набор содержит некорректные подключения');
    }
    return applyImport(plan);
  }

  Future<void> markProbes(
    Set<String> identities,
    ProbeStatus status,
    DateTime started,
  ) => _commit(
    (c) => c.copyWith(
      configs: c.configs
          .map(
            (config) =>
                identities.contains(config.connectionIdentity) &&
                    !(config.lastPingedAt?.isAfter(started) ?? false)
                ? config.copyWith(
                    probeStatus: status,
                    latencyMs: null,
                    lastPingedAt: started,
                  )
                : config,
          )
          .toList(),
    ),
  );

  Future<void> batchUpdatePingResults(
    Map<String, int?> results,
    DateTime pingedAt,
  ) => _commit(
    (c) => c.copyWith(
      configs: c.configs.map((config) {
        final key = config.connectionIdentity;
        if (!results.containsKey(key) ||
            (config.lastPingedAt?.isAfter(pingedAt) ?? false)) {
          return config;
        }
        final ms = results[key];
        return config.copyWith(
          latencyMs: ms,
          lastPingedAt: pingedAt,
          probeStatus: ms == null ? ProbeStatus.failed : ProbeStatus.success,
          lastSuccessfulLatencyMs: ms,
          lastSuccessfulPingAt: ms == null ? null : pingedAt,
        );
      }).toList(),
    ),
  );

  Future<void> reorderSubscriptions(int oldIndex, int newIndex) => _commit((c) {
    final subs = [...c.subscriptions];
    if (oldIndex < newIndex) newIndex--;
    subs.insert(newIndex, subs.removeAt(oldIndex));
    return c.copyWith(subscriptions: subs);
  });

  Future<void> reorderGroupConfigs(String? subId, int oldIndex, int newIndex) =>
      _commit((c) {
        final group = c.configs
            .where((e) => e.subscriptionId == subId)
            .toList();
        if (oldIndex < newIndex) newIndex--;
        group.insert(newIndex, group.removeAt(oldIndex));
        final all = [...c.configs];
        final first = all.indexWhere((e) => e.subscriptionId == subId);
        all.removeWhere((e) => e.subscriptionId == subId);
        all.insertAll(first < 0 ? all.length : first, group);
        return c.copyWith(configs: all);
      });
}

final configProvider = AsyncNotifierProvider<ConfigNotifier, ConfigState>(
  ConfigNotifier.new,
);

int compareProbeResults(VpnConfig a, VpnConfig b, DateTime now) {
  final aFresh = a.hasFreshProbe(now), bFresh = b.hasFreshProbe(now);
  if (aFresh != bFresh) return aFresh ? -1 : 1;
  if (aFresh) {
    final latency = a.latencyMs!.compareTo(b.latencyMs!);
    if (latency != 0) return latency;
  }
  return a.connectionIdentity.compareTo(b.connectionIdentity);
}

final effectiveConfigProvider = Provider<VpnConfig?>((ref) {
  final cs = ref.watch(configProvider).value;
  if (cs == null) return null;
  if (cs.activeSubscriptionId != null) {
    final now = DateTime.now();
    final candidates =
        cs.configs
            .where(
              (c) =>
                  c.subscriptionId == cs.activeSubscriptionId &&
                  c.probeStatus != ProbeStatus.failed,
            )
            .toList()
          ..sort((a, b) => compareProbeResults(a, b, now));
    return candidates.firstOrNull;
  }
  return cs.activeConfig;
});
