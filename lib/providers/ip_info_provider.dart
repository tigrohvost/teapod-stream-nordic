import 'dart:convert';
import 'dart:async';
import 'settings_provider.dart';
import '../core/services/bounded_download.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socks5_proxy/socks.dart';
import '../core/interfaces/vpn_engine.dart';
import '../protocols/xray/xray_engine.dart';
import 'vpn_provider.dart';

class IpInfo {
  final String ip;
  final String country;
  final String countryCode;

  const IpInfo({
    required this.ip,
    required this.country,
    required this.countryCode,
  });
}

class IpInfoNotifier extends AsyncNotifier<IpInfo?> {
  @override
  Future<IpInfo?> build() async {
    final enabled = ref.watch(settingsProvider).value?.ipLookupEnabled ?? false;
    if (!enabled) return null;
    final connectionState = ref.watch(vpnConnectionStateProvider);
    if (connectionState == VpnState.connected) {
      final vpnState = ref.read(vpnProvider);
      if (vpnState.activeSocksPort > 0) {
        return _fetch(
          socksPort: vpnState.activeSocksPort,
          socksUser: vpnState.activeSocksUser,
          socksPassword: vpnState.activeSocksPassword,
        );
      }
    }
    // Fallback: Quick Tile started VPN — native state may be ahead of Flutter state
    final engine = XrayEngine();
    final nativeState = await engine.getVpnState();
    if (nativeState.state == VpnState.connected && nativeState.socksPort > 0) {
      return _fetch(
        socksPort: nativeState.socksPort,
        socksUser: nativeState.socksUser,
        socksPassword: nativeState.socksPassword,
      );
    }
    return null;
  }

  Future<IpInfo?> _fetch({
    required int socksPort,
    required String socksUser,
    required String socksPassword,
  }) async {
    if (socksPort <= 0) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    ref.onDispose(() => client.close(force: true));
    final deadline = Timer(
      const Duration(seconds: 20),
      () => client.close(force: true),
    );
    if (socksPort > 0) {
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(
          InternetAddress.loopbackIPv4,
          socksPort,
          username: socksUser.isNotEmpty ? socksUser : null,
          password: socksUser.isNotEmpty ? socksPassword : null,
        ),
      ]);
    }
    try {
      final req = await client
          .getUrl(Uri.parse('https://api.country.is/'))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.userAgentHeader, 'TeapodStream');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw const HttpException('Внешний IP недоступен');
      }
      final body = await readBoundedBody(resp, maxBytes: 65536);
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['ip'] is! String || json['country'] is! String) {
        throw const FormatException('Неверный ответ сервиса IP');
      }
      return IpInfo(
        ip: json['ip'] as String,
        country: json['country'] as String,
        countryCode: json['country'] as String,
      );
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
  }
}

final ipInfoProvider = AsyncNotifierProvider<IpInfoNotifier, IpInfo?>(
  IpInfoNotifier.new,
);
