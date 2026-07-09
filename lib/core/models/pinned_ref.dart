import 'vpn_config.dart';

/// Закреплённое подключение. Идентифицируется парой (подписка, имя),
/// а не id конфига: при обновлении подписки конфиги пересоздаются,
/// но пин продолжает указывать на одноимённый.
class PinnedRef {
  /// null — standalone-конфиг (группа [local]).
  final String? subscriptionId;
  final String name;

  const PinnedRef({required this.subscriptionId, required this.name});

  bool matches(VpnConfig c) =>
      c.subscriptionId == subscriptionId && c.name == name;

  Map<String, dynamic> toJson() => {
        'subscriptionId': subscriptionId,
        'name': name,
      };

  factory PinnedRef.fromJson(Map<String, dynamic> json) => PinnedRef(
        subscriptionId: json['subscriptionId'] as String?,
        name: json['name'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is PinnedRef &&
      other.subscriptionId == subscriptionId &&
      other.name == name;

  @override
  int get hashCode => Object.hash(subscriptionId, name);
}
