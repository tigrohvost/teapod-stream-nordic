import 'vpn_config.dart';
import 'pinned_ref.dart';
import '../services/config_storage_service.dart' show Subscription;

class ConfigState {
  final int revision;
  final List<VpnConfig> configs;
  final String? activeConfigId;
  final String? activeSubscriptionId;
  final List<Subscription> subscriptions;
  final List<PinnedRef> pins;

  ConfigState({
    this.revision = 0,
    this.configs = const [],
    this.activeConfigId,
    this.activeSubscriptionId,
    this.subscriptions = const [],
    this.pins = const [],
  });

  VpnConfig? get activeConfig => activeConfigId == null
      ? null
      : configs.where((c) => c.id == activeConfigId).firstOrNull;

  late final List<VpnConfig> standaloneConfigs = configs
      .where((c) => c.subscriptionId == null)
      .toList();

  late final Map<String, List<VpnConfig>> configsBySubscription = () {
    final result = <String, List<VpnConfig>>{};
    for (final config in configs.where((c) => c.subscriptionId != null)) {
      result.putIfAbsent(config.subscriptionId!, () => []).add(config);
    }
    return result;
  }();

  /// Пины в порядке закрепления; null — конфиг с таким именем
  /// в подписке отсутствует (пин «потерян», но не удаляется).
  late final List<(PinnedRef, VpnConfig?)> resolvedPins = pins
      .map((p) => (p, configs.where(p.matches).firstOrNull))
      .toList();

  bool isPinned(VpnConfig c) => pins.any((p) => p.matches(c));

  ConfigState copyWith({
    int? revision,
    List<VpnConfig>? configs,
    String? activeConfigId,
    bool clearActive = false,
    String? activeSubscriptionId,
    bool clearActiveSub = false,
    List<Subscription>? subscriptions,
    List<PinnedRef>? pins,
  }) {
    return ConfigState(
      revision: revision ?? this.revision,
      configs: configs ?? this.configs,
      activeConfigId: clearActive
          ? null
          : (activeConfigId ?? this.activeConfigId),
      activeSubscriptionId: clearActiveSub
          ? null
          : (activeSubscriptionId ?? this.activeSubscriptionId),
      subscriptions: subscriptions ?? this.subscriptions,
      pins: pins ?? this.pins,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'revision': revision,
    'configs': configs.map((c) => c.toJson()).toList(),
    'subscriptions': subscriptions.map((s) => s.toJson()).toList(),
    'pins': pins.map((p) => p.toJson()).toList(),
    'activeConfigId': activeConfigId,
    'activeSubscriptionId': activeSubscriptionId,
  };

  /// Like [ConfigState.fromJson], but an entry that fails to parse is dropped
  /// instead of making the whole snapshot unreadable. Returns how many were
  /// dropped so the caller can keep the raw snapshot aside.
  static (ConfigState, int) fromJsonLenient(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported connection snapshot');
    }
    var dropped = 0;
    List<T> each<T>(Object? list, T Function(Map<String, dynamic>) parse) {
      final result = <T>[];
      for (final item in list is List ? list : const []) {
        try {
          result.add(parse(item as Map<String, dynamic>));
        } catch (_) {
          dropped++;
        }
      }
      return result;
    }

    final state = ConfigState(
      revision: json['revision'] as int? ?? 0,
      configs: each(json['configs'], VpnConfig.fromJson),
      subscriptions: each(json['subscriptions'], Subscription.fromJson),
      pins: each(json['pins'], PinnedRef.fromJson),
      activeConfigId: json['activeConfigId'] as String?,
      activeSubscriptionId: json['activeSubscriptionId'] as String?,
    );
    return (state, dropped);
  }

  factory ConfigState.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported connection snapshot');
    }
    return ConfigState(
      revision: json['revision'] as int,
      configs: (json['configs'] as List)
          .map((c) => VpnConfig.fromJson(c as Map<String, dynamic>))
          .toList(),
      subscriptions: (json['subscriptions'] as List)
          .map((s) => Subscription.fromJson(s as Map<String, dynamic>))
          .toList(),
      pins: (json['pins'] as List)
          .map((p) => PinnedRef.fromJson(p as Map<String, dynamic>))
          .toList(),
      activeConfigId: json['activeConfigId'] as String?,
      activeSubscriptionId: json['activeSubscriptionId'] as String?,
    );
  }
}
