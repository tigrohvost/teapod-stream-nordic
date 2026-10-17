import 'dart:convert';
import '../interfaces/vpn_engine.dart';
import '../../protocols/xray/xray_config_builder.dart';
import 'package:uuid/uuid.dart';
import '../models/config_state.dart';
import '../models/connections_bundle.dart';
import '../models/vpn_config.dart';
import '../../protocols/xray/vless_parser.dart';
import 'config_storage_service.dart';
import 'subscription_service.dart';

class ImportPlan {
  final List<VpnConfig> configs;
  final List<Subscription> subscriptions;
  final int invalidItems;
  final String? label;
  const ImportPlan({
    required this.configs,
    required this.subscriptions,
    this.invalidItems = 0,
    this.label,
  });
}

class ImportConnectionsResult {
  final int addedConfigs;
  final int addedSubscriptions;
  final int skippedConfigs;
  final int invalidItems;
  const ImportConnectionsResult({
    required this.addedConfigs,
    required this.addedSubscriptions,
    required this.skippedConfigs,
    this.invalidItems = 0,
  });
}

/// All import channels normalize into this plan before touching storage.
class ImportService {
  final Future<SubscriptionFetchResult> Function(String) fetchSubscription;
  final Future<void> Function(VpnConfig)? validateConfig;
  ImportService({
    Future<SubscriptionFetchResult> Function(String)? fetchSubscription,
    this.validateConfig,
  }) : fetchSubscription =
           fetchSubscription ??
           ((url) => SubscriptionService().fetchSubscription(url));

  Future<void> validate(VpnConfig config) async {
    final error = config.validate();
    if (error != null) throw FormatException(error);
    XrayConfigBuilder.plan(
      config,
      const VpnEngineOptions(
        socksPort: 10808,
        httpPort: 0,
        socksUser: '',
        socksPassword: '',
      ),
    );
    await validateConfig?.call(config);
  }

  Future<ImportPlan> prepare(ConnectionsBundle bundle) async {
    // Also validate programmatically-created bundles before the first mutation.
    ConnectionsBundle.fromJson(bundle.toJson());
    final configs = <VpnConfig>[];
    final subscriptions = <Subscription>[];
    var invalid = 0;
    for (final config in [
      ...bundle.configs,
      ...bundle.rawUris.map(VlessParser.parseUri),
    ]) {
      if (config == null || config.validate() != null) {
        invalid++;
      } else {
        try {
          await validate(config);
          configs.add(config);
        } catch (_) {
          invalid++;
        }
      }
    }
    for (final sub in bundle.subscriptions) {
      if (!validUrl(sub.url)) {
        invalid++;
      } else {
        subscriptions.add(sub);
      }
    }
    for (final url in bundle.subscriptionUrls.toSet()) {
      if (!validUrl(url)) {
        invalid++;
        continue;
      }
      if (subscriptions.any((s) => s.url == url)) continue;
      // Failed downloads abort preparation; no partially replaced subscriptions.
      final fetched = await fetchSubscription(url);
      if (fetched.configs.isEmpty ||
          fetched.configs.any((c) => c.validate() != null)) {
        throw const FormatException(
          'Подписка не содержит корректных подключений',
        );
      }
      for (final config in fetched.configs) {
        await validate(config);
      }
      final sub = Subscription(
        id: const Uuid().v4(),
        name: fetched.profileTitle ?? Uri.parse(url).host,
        url: url,
        createdAt: DateTime.now(),
        lastFetchedAt: DateTime.now(),
      );
      subscriptions.add(sub);
      configs.addAll(
        fetched.configs.map((c) => c.copyWith(subscriptionId: sub.id)),
      );
    }
    return ImportPlan(
      configs: configs,
      subscriptions: subscriptions,
      invalidItems: invalid,
      label: bundle.label,
    );
  }

  static bool validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        const ['https', 'http'].contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  static String sourceLabel(String? value) =>
      value == null ? '' : Uri.tryParse(value)?.host ?? 'Источник';

  static ConnectionsBundle fromText(String value) {
    if (utf8.encode(value).length > ConnectionsBundle.maxBytes) {
      throw const FormatException('Слишком большой импорт');
    }
    if (value.trimLeft().startsWith('{')) {
      return ConnectionsBundle.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    }
    return ConnectionsBundle(
      exportedAt: DateTime.now(),
      rawUris: value
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }

  static (ConfigState, ImportConnectionsResult) apply(
    ConfigState current,
    ImportPlan plan,
  ) {
    final subscriptions = [...current.subscriptions];
    final subIds = <String, String>{};
    for (final sub in plan.subscriptions) {
      final existing = subscriptions.where((s) => s.url == sub.url).firstOrNull;
      final id = existing?.id ?? const Uuid().v4();
      subIds[sub.id] = id;
      if (existing == null) {
        subscriptions.add(Subscription.fromJson({...sub.toJson(), 'id': id}));
      }
    }
    final identities = current.configs.map((c) => c.connectionIdentity).toSet();
    final added = <VpnConfig>[];
    for (final config in plan.configs) {
      if (identities.add(config.connectionIdentity)) {
        added.add(
          config.copyWith(
            id: const Uuid().v4(),
            subscriptionId: subIds[config.subscriptionId],
            latencyMs: null,
            lastPingedAt: null,
            probeStatus: ProbeStatus.unknown,
          ),
        );
      }
    }
    return (
      current.copyWith(
        configs: [...current.configs, ...added],
        subscriptions: subscriptions,
        activeConfigId: current.activeConfigId ?? added.firstOrNull?.id,
      ),
      ImportConnectionsResult(
        addedConfigs: added.length,
        addedSubscriptions: subscriptions.length - current.subscriptions.length,
        skippedConfigs: plan.configs.length - added.length,
        invalidItems: plan.invalidItems,
      ),
    );
  }
}
