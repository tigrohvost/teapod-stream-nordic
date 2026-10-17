import 'dart:convert';
import 'package:crypto/crypto.dart';

enum VpnProtocol { vless, vmess, trojan, shadowsocks, hysteria2 }

enum VpnSecurity { none, tls, reality }

enum VpnTransport { tcp, ws, grpc, http2, quic, xhttp, httpupgrade, splithttp }

enum ProbeStatus { unknown, running, success, failed, cancelled }

const _unchanged = Object();

class VpnConfig {
  final String id;
  final String name;
  final VpnProtocol protocol;
  final String address;
  final int port;
  final String uuid;
  final VpnSecurity security;
  final VpnTransport transport;
  final String? sni;
  final String? wsPath;
  final String? wsHost;
  final String? grpcServiceName;
  final String? fingerprint;
  final String? publicKey; // for Reality
  final String? shortId; // for Reality
  final String? spiderX; // for Reality
  final String? postQuantumKey; // for Reality post-quantum (pqv)
  final String? flow;
  final String? encryption; // for VLESS: "none"
  final String? alterId; // for VMess
  final String? method; // for Shadowsocks
  final String? password; // for Trojan/Shadowsocks
  final DateTime createdAt;
  final String? rawUri;
  final int? latencyMs;
  final DateTime? lastPingedAt;
  final ProbeStatus probeStatus;
  final int? lastSuccessfulLatencyMs;
  final DateTime? lastSuccessfulPingAt;
  final String? subscriptionId; // ID of the subscription this config came from
  final String?
  ssPrefix; // hex-encoded prefix bytes for Outline Shadowsocks (e.g. "160301...")
  final String? obfsPassword; // for Hysteria2 salamander obfuscation
  final bool allowInsecure;
  final String? pinSHA256;
  final String?
  xhttpMode; // for xhttp transport: "auto", "packet-up", "stream-up", "stream-one"
  final Map<String, dynamic>?
  xhttpExtra; // raw extra object passed to xhttpSettings
  final Map<String, dynamic>?
  finalmask; // xray finalmask stream setting (fm param in URL)
  final String? alpn; // comma-separated ALPN list, e.g. "h3" or "h2,http/1.1"
  final String? ech; // base64 ECH ConfigList for TLS Encrypted Client Hello
  final String?
  rawXrayConfig; // pre-built xray JSON config (from managed subscriptions)

  const VpnConfig({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    required this.uuid,
    required this.security,
    required this.transport,
    this.sni,
    this.wsPath,
    this.wsHost,
    this.grpcServiceName,
    this.fingerprint,
    this.publicKey,
    this.shortId,
    this.spiderX,
    this.postQuantumKey,
    this.flow,
    this.encryption,
    this.alterId,
    this.method,
    this.password,
    required this.createdAt,
    this.rawUri,
    this.latencyMs,
    this.lastPingedAt,
    this.probeStatus = ProbeStatus.unknown,
    this.lastSuccessfulLatencyMs,
    this.lastSuccessfulPingAt,
    this.subscriptionId,
    this.ssPrefix,
    this.obfsPassword,
    this.allowInsecure = false,
    this.pinSHA256,
    this.xhttpMode,
    this.xhttpExtra,
    this.finalmask,
    this.alpn,
    this.ech,
    this.rawXrayConfig,
  });

  String? validate() {
    if (rawXrayConfig != null) {
      try {
        final raw = jsonDecode(rawXrayConfig!);
        if (raw is! Map<String, dynamic> ||
            raw['outbounds'] is! List ||
            (raw['outbounds'] as List).isEmpty ||
            (raw['outbounds'] as List).any(
              (o) => o is! Map || o['protocol'] is! String,
            )) {
          return 'Неверная структура управляемой конфигурации';
        }
        return null;
      } catch (_) {
        return 'Неверный JSON управляемой конфигурации';
      }
    }
    if (address.trim().isEmpty || RegExp(r'\s').hasMatch(address)) {
      return 'Пустой адрес сервера';
    }
    if (ssPrefix != null &&
        (ssPrefix!.isEmpty ||
            ssPrefix!.length.isOdd ||
            !RegExp(r'^[0-9a-fA-F]+$').hasMatch(ssPrefix!))) {
      return 'Неверный prefix';
    }
    if (port < 1 || port > 65535) return 'Неверный порт: $port';
    if (protocol == VpnProtocol.vless || protocol == VpnProtocol.vmess) {
      if (uuid.isEmpty) return 'Пустой UUID';
    }
    if ((protocol == VpnProtocol.shadowsocks ||
            protocol == VpnProtocol.trojan ||
            protocol == VpnProtocol.hysteria2) &&
        (password == null || password!.isEmpty)) {
      return 'Пустой пароль';
    }
    return null;
  }

  VpnConfig copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    Object? latencyMs = _unchanged,
    Object? lastPingedAt = _unchanged,
    Object? subscriptionId = _unchanged,
    ProbeStatus? probeStatus,
    int? lastSuccessfulLatencyMs,
    DateTime? lastSuccessfulPingAt,
    bool? allowInsecure,
    String? pinSHA256,
    String? rawUri,
  }) {
    return VpnConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol,
      address: address,
      port: port,
      uuid: uuid,
      security: security,
      transport: transport,
      sni: sni,
      wsPath: wsPath,
      wsHost: wsHost,
      grpcServiceName: grpcServiceName,
      fingerprint: fingerprint,
      publicKey: publicKey,
      shortId: shortId,
      spiderX: spiderX,
      postQuantumKey: postQuantumKey,
      flow: flow,
      encryption: encryption,
      alterId: alterId,
      method: method,
      password: password,
      createdAt: createdAt ?? this.createdAt,
      rawUri: rawUri ?? this.rawUri,
      latencyMs: identical(latencyMs, _unchanged)
          ? this.latencyMs
          : latencyMs as int?,
      lastPingedAt: identical(lastPingedAt, _unchanged)
          ? this.lastPingedAt
          : lastPingedAt as DateTime?,
      subscriptionId: identical(subscriptionId, _unchanged)
          ? this.subscriptionId
          : subscriptionId as String?,
      probeStatus: probeStatus ?? this.probeStatus,
      lastSuccessfulLatencyMs:
          lastSuccessfulLatencyMs ?? this.lastSuccessfulLatencyMs,
      lastSuccessfulPingAt: lastSuccessfulPingAt ?? this.lastSuccessfulPingAt,
      ssPrefix: ssPrefix,
      obfsPassword: obfsPassword,
      allowInsecure: allowInsecure ?? this.allowInsecure,
      pinSHA256: pinSHA256 ?? this.pinSHA256,
      xhttpMode: xhttpMode,
      xhttpExtra: xhttpExtra,
      finalmask: finalmask,
      alpn: alpn,
      ech: ech,
      rawXrayConfig: rawXrayConfig,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'address': address,
    'port': port,
    'uuid': uuid,
    'security': security.name,
    'transport': transport.name,
    'sni': sni,
    'wsPath': wsPath,
    'wsHost': wsHost,
    'grpcServiceName': grpcServiceName,
    'fingerprint': fingerprint,
    'publicKey': publicKey,
    'shortId': shortId,
    'spiderX': spiderX,
    'postQuantumKey': postQuantumKey,
    'flow': flow,
    'encryption': encryption,
    'alterId': alterId,
    'method': method,
    'password': password,
    'createdAt': createdAt.toIso8601String(),
    'rawUri': rawUri,
    'latencyMs': latencyMs,
    'lastPingedAt': lastPingedAt?.toIso8601String(),
    'probeStatus': probeStatus.name,
    'lastSuccessfulLatencyMs': lastSuccessfulLatencyMs,
    'lastSuccessfulPingAt': lastSuccessfulPingAt?.toIso8601String(),
    'subscriptionId': subscriptionId,
    'ssPrefix': ssPrefix,
    'obfsPassword': obfsPassword,
    'allowInsecure': allowInsecure,
    'pinSHA256': pinSHA256,
    'xhttpMode': xhttpMode,
    'xhttpExtra': xhttpExtra,
    'finalmask': finalmask,
    'alpn': alpn,
    'ech': ech,
    'rawXrayConfig': rawXrayConfig,
  };

  factory VpnConfig.fromJson(Map<String, dynamic> json) => VpnConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    protocol: VpnProtocol.values.firstWhere((e) => e.name == json['protocol']),
    address: json['address'] as String,
    port: json['port'] as int,
    uuid: json['uuid'] as String? ?? '',
    security: VpnSecurity.values.firstWhere((e) => e.name == json['security']),
    transport: VpnTransport.values.firstWhere(
      (e) => e.name == json['transport'],
    ),
    sni: json['sni'] as String?,
    wsPath: json['wsPath'] as String?,
    wsHost: json['wsHost'] as String?,
    grpcServiceName: json['grpcServiceName'] as String?,
    fingerprint: json['fingerprint'] as String?,
    publicKey: json['publicKey'] as String?,
    shortId: json['shortId'] as String?,
    spiderX: json['spiderX'] as String?,
    postQuantumKey: json['postQuantumKey'] as String?,
    flow: json['flow'] as String?,
    encryption: json['encryption'] as String?,
    alterId: json['alterId'] as String?,
    method: json['method'] as String?,
    password: json['password'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    rawUri: json['rawUri'] as String?,
    latencyMs: json['latencyMs'] as int?,
    probeStatus: ProbeStatus.values.byName(
      json['probeStatus'] as String? ??
          (json['latencyMs'] != null ? 'success' : 'unknown'),
    ),
    lastSuccessfulLatencyMs:
        json['lastSuccessfulLatencyMs'] as int? ?? json['latencyMs'] as int?,
    lastSuccessfulPingAt: DateTime.tryParse(
      json['lastSuccessfulPingAt'] as String? ?? '',
    ),
    lastPingedAt: json['lastPingedAt'] != null
        ? DateTime.parse(json['lastPingedAt'] as String)
        : null,
    subscriptionId: json['subscriptionId'] as String?,
    ssPrefix: json['ssPrefix'] as String?,
    obfsPassword: json['obfsPassword'] as String?,
    allowInsecure: json['allowInsecure'] as bool? ?? false,
    pinSHA256: json['pinSHA256'] as String?,
    xhttpMode: json['xhttpMode'] as String?,
    xhttpExtra: json['xhttpExtra'] as Map<String, dynamic>?,
    finalmask: json['finalmask'] as Map<String, dynamic>?,
    alpn: json['alpn'] as String?,
    ech: json['ech'] as String?,
    rawXrayConfig: json['rawXrayConfig'] as String?,
  );

  String toJsonString() => jsonEncode(toJson());
  factory VpnConfig.fromJsonString(String s) =>
      VpnConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// Local-only identity. Never include this secret-derived hash in diagnostics.
  String get connectionIdentity {
    final data = toJson()
      ..removeWhere(
        (key, _) => const {
          'id',
          'name',
          'createdAt',
          'rawUri',
          'subscriptionId',
          'latencyMs',
          'lastPingedAt',
          'probeStatus',
          'lastSuccessfulLatencyMs',
          'lastSuccessfulPingAt',
        }.contains(key),
      );
    if (rawXrayConfig != null) {
      return sha256
          .convert(
            utf8.encode(jsonEncode(_canonical(jsonDecode(rawXrayConfig!)))),
          )
          .toString();
    }
    data['address'] = address.toLowerCase();
    return sha256.convert(utf8.encode(jsonEncode(_canonical(data)))).toString();
  }

  bool hasFreshProbe(
    DateTime now, {
    Duration ttl = const Duration(minutes: 10),
  }) =>
      probeStatus == ProbeStatus.success &&
      latencyMs != null &&
      lastPingedAt != null &&
      now.difference(lastPingedAt!) >= Duration.zero &&
      now.difference(lastPingedAt!) <= ttl;

  static Object? _canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      return {
        for (final key in value.keys.toList()..sort())
          key: _canonical(value[key]),
      };
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
