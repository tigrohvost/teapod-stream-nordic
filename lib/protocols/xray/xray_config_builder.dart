import 'dart:convert';
import '../../core/models/effective_connection_plan.dart';
import '../../core/interfaces/vpn_engine.dart';
import '../../core/models/vpn_config.dart';
import '../../core/models/dns_config.dart';
import '../../core/models/routing_settings.dart';
import '../../core/constants/xray_defaults.dart';
import '../../core/services/settings_service.dart'
    show DnsQueryStrategy, TlsFingerprint;

class XrayConfigBuilder {
  static const _ruServicesDomains = [
    'domain:2gis.ru',
    'domain:2gis.com',
    'domain:ads.x5.ru',
    'domain:aif.ru',
    'domain:aeroflot.ru',
    'domain:alfabank.ru',
    'domain:api.oneme.ru',
    'domain:avito.ru',
    'domain:beeline.ru',
    'domain:burgerkingrus.ru',
    'domain:dellin.ru',
    'domain:drive2.ru',
    'domain:dzen.ru',
    'domain:fd.oneme.ru',
    'domain:flypobeda.ru',
    'domain:forbes.ru',
    'domain:gazeta.ru',
    'domain:gazprombank.ru',
    'domain:gismeteo.ru',
    'domain:gosuslugi.ru',
    'domain:hh.ru',
    'domain:i.oneme.ru',
    'domain:kontur.ru',
    'domain:kontur.host',
    'domain:kp.ru',
    'domain:kuper.ru',
    'domain:lenta.ru',
    'domain:mail.ru',
    'domain:max.ru',
    'domain:megamarket.ru',
    'domain:megamarket.tech',
    'domain:megafon.ru',
    'domain:miniapps.max.ru',
    'domain:moex.com',
    'domain:motivtelecom.ru',
    'domain:ozon.ru',
    'domain:pervye.ru',
    'domain:psbank.ru',
    'domain:rambler.ru',
    'domain:rambler-co.ru',
    'domain:rbc.ru',
    'domain:reg.ru',
    'domain:reviews.2gis.com',
    'domain:rg.ru',
    'domain:ria.ru',
    'domain:rustore.ru',
    'domain:rutube.ru',
    'domain:ruwiki.ru',
    'domain:rzd.ru',
    'domain:sdk-api.apptracer.ru',
    'domain:sirena-travel.ru',
    'domain:sravni.ru',
    'domain:st.max.ru',
    'domain:t-j.ru',
    'domain:t2.ru',
    'domain:tank-online.com',
    'domain:taximaxim.ru',
    'domain:tbank-online.com',
    'domain:tildaapi.com',
    'domain:tns-counter.ru',
    'domain:tracker-api.vk-analytics.ru',
    'domain:trvl.yandex.net',
    'domain:tutu.ru',
    'domain:vk.com',
    'domain:vk.ru',
    'domain:vkvideo.ru',
    'domain:vtb.ru',
    'domain:x5.ru',
    'domain:xn--90acagbhgpca7c8c7f.xn--p1ai',
    'domain:xn--80ajghhoc2aj1c8b.xn--p1ai',
    'domain:xn--90aivcdt6dxbc.xn--p1ai',
    'domain:xn--b1aew.xn--p1ai',
    'domain:ya.ru',
    'domain:yandex.ru',
    'domain:yandex.net',
    'domain:yandex.com',
    'domain:yandexcloud.net',
    'domain:yastatic.net',
    'full:go.yandex',
    'full:ru.ruwiki.ru',
  ];

  static Map<String, dynamic> build(
    VpnConfig config,
    VpnEngineOptions options,
  ) {
    final dnsBlock = _buildDnsBlock(options);
    final routing = options.routing;
    // routeOnly=true: sniffed domain is used for routing only — xray does NOT replace
    // the connection destination. Without this, xray re-resolves the domain and
    // redirects the connection to a different IP, breaking tun2socks and leaking DNS.
    final routeOnly = options.sniffingEnabled;

    return {
      'log': {'loglevel': options.logLevel.name},
      'dns': dnsBlock,
      'inbounds': [
        {
          'tag': 'socks-in',
          'protocol': 'socks',
          'port': options.socksPort,
          'listen': XrayDefaults.socksListen,
          'settings': {
            'auth': options.socksUser.isNotEmpty ? 'password' : 'noauth',
            if (options.socksUser.isNotEmpty)
              'accounts': [
                {'user': options.socksUser, 'pass': options.socksPassword},
              ],
            'udp': options.enableUdp,
          },
          'sniffing': {
            'enabled': options.sniffingEnabled,
            if (options.sniffingEnabled) ...{
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': routeOnly,
            },
          },
        },
      ],
      'outbounds': [
        _buildOutbound(config, options.tlsFingerprint),
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'dns-out', 'protocol': 'dns'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {
        // A catch-all already matches the domain, so IPIfNonMatch never reaches
        // GeoIP rules for domain requests. Resolve when evaluating an IP rule.
        'domainStrategy': _needsIpResolution(routing)
            ? 'IPOnDemand'
            : 'IPIfNonMatch',
        'rules': [
          if (routing.adBlockEnabled)
            {
              'type': 'field',
              'domain': [XrayDefaults.adBlockGeosite],
              'outboundTag': 'block',
            },
          // QUIC blocking is handled at the TUN level by tun2socks, which replies
          // with an ICMP Port Unreachable so the browser falls back to TCP immediately.
          // No xray routing rule is needed: silently dropping UDP/443 here (blackhole)
          // would force browsers to wait ~55s for QUIC retransmission to time out,
          // and rerouting QUIC to 'direct' would leak the destination outside the tunnel.
          if (options.dnsMode == DnsMode.proxy) ...[
            {
              'type': 'field',
              'inboundTag': ['dns-module'],
              'outboundTag': 'proxy',
            },
            // Intercept DNS queries from user apps and handle them via xray's DNS module.
            {
              'type': 'field',
              'inboundTag': ['socks-in'],
              'port': '53',
              'network': 'udp,tcp',
              'outboundTag': 'dns-out',
            },
          ],
          if (options.dnsMode == DnsMode.direct) ...[
            // Direct mode: DNS queries bypass the VPN tunnel entirely.
            // xray's own process is excluded from the TUN, so 'direct' outbound
            // connects straight to the internet without going through the VPN.
            {
              'type': 'field',
              'port': '53',
              'network': 'udp,tcp',
              'outboundTag': 'direct',
            },
          ],
          ..._buildGeoRules(routing),
          // In ONLY mode the catch-all routes to direct, so diagnostic hosts that aren't
          // in the user's rules would bypass the proxy and may be blocked locally.
          // Force them via proxy so heartbeat and IP-detection always test the tunnel.
          if (routing.direction == RoutingDirection.onlySelected) ...[
            {
              'type': 'field',
              'domain': [
                'full:cp.cloudflare.com',
                'full:connectivitycheck.gstatic.com',
                'full:api.country.is',
              ],
              'outboundTag': 'proxy',
            },
          ],
          {
            'type': 'field',
            'inboundTag': ['socks-in'],
            'outboundTag': routing.direction == RoutingDirection.onlySelected
                ? 'direct'
                : 'proxy',
          },
        ],
      },
      'policy': {
        'levels': {
          '0': {
            'handshake': XrayDefaults.handshakeTimeout,
            'connIdle': XrayDefaults.connIdleTimeout,
            'uplinkOnly': XrayDefaults.uplinkOnlyTimeout,
            'downlinkOnly': XrayDefaults.downlinkOnlyTimeout,
          },
        },
        'system': {'statsInboundUplink': false, 'statsInboundDownlink': false},
      },
    };
  }

  static bool _needsIpResolution(RoutingSettings routing) =>
      routing.isActive &&
      (routing.bypassLocal ||
          (routing.geoEnabled && routing.geoCodes.isNotEmpty));

  static List<Map<String, dynamic>> _buildGeoRules(RoutingSettings routing) {
    if (!routing.isActive) return [];

    final rules = <Map<String, dynamic>>[];

    // Private IPs always bypass regardless of direction
    if (routing.bypassLocal) {
      rules.add({
        'type': 'field',
        'ip': ['geoip:private'],
        'outboundTag': 'direct',
      });
    }

    final selectedOut = routing.direction == RoutingDirection.bypass
        ? 'direct'
        : 'proxy';

    if (routing.domainEnabled && routing.domainZones.isNotEmpty) {
      rules.add({
        'type': 'field',
        'domain': routing.domainZones.map((z) => 'domain:$z').toList(),
        'outboundTag': selectedOut,
      });
    }

    if (routing.geositeEnabled && routing.geositeCodes.isNotEmpty) {
      rules.add({
        'type': 'field',
        'domain': routing.geositeCodes.map((c) => 'geosite:$c').toList(),
        'outboundTag': selectedOut,
      });
    }

    if (routing.geoEnabled && routing.geoCodes.isNotEmpty) {
      rules.add({
        'type': 'field',
        'ip': routing.geoCodes.map((c) => 'geoip:${c.toLowerCase()}').toList(),
        'outboundTag': selectedOut,
      });
    }

    if (routing.sitesEnabled && routing.sites.isNotEmpty) {
      rules.add({
        'type': 'field',
        'domain': routing.sites.map((s) => 'domain:$s').toList(),
        'outboundTag': selectedOut,
      });
    }

    if (routing.ruServicesEnabled) {
      rules.add({
        'type': 'field',
        'domain': _ruServicesDomains,
        'outboundTag': selectedOut,
      });
    }

    return rules;
  }

  static String _queryStrategy(DnsQueryStrategy s) => switch (s) {
    DnsQueryStrategy.ipv4Only => 'UseIPv4',
    DnsQueryStrategy.ipv6Only => 'UseIPv6',
    DnsQueryStrategy.auto => 'UseIP',
  };

  static Map<String, dynamic> buildDnsBlock(VpnEngineOptions options) =>
      _buildDnsBlock(options);

  static Map<String, dynamic> _buildDnsBlock(VpnEngineOptions options) {
    final server = options.dnsServer;
    final routing = options.routing;
    final strategy = _queryStrategy(options.dnsQueryStrategy);
    List<dynamic> servers = [];

    if (options.dnsMode == DnsMode.direct) {
      // Direct mode: DNS queries bypass the VPN via the 'direct' routing rule above.
      // Use system resolver for xray's own domain lookups (e.g. routing decisions).
      return {
        'servers': ['localhost'],
        'queryStrategy': strategy,
        'disableFallback': true,
      };
    }

    // Proxy mode: DNS queries are intercepted and handled by xray's DNS module.
    // Add main DNS server
    switch (server.type) {
      case DnsType.udp:
        servers.add({'address': server.address, 'port': server.port});
        break;
      case DnsType.doh:
        servers.add({'address': server.address});
        break;
      case DnsType.dot:
        // xray-core has no DNS-over-TLS client (no tls:// scheme): such an address
        // was taken for a plain UDP server literally named "tls://…" and every query
        // failed. The DoT providers serve the same resolver over DoH, so use that.
        servers.add({
          'address': 'https://${server.domain ?? server.address}/dns-query',
        });
        break;
    }

    final hosts = <String, String>{};
    // Adblock: answer NXDOMAIN locally. xray only knows "#<rcode>" for this —
    // the former 'rcode://success' server was just an unreachable resolver that
    // delayed ad lookups until the fallback answered them.
    if (routing.adBlockEnabled) {
      hosts[XrayDefaults.adBlockGeosite] = '#3';
    }
    if (server.domain != null && server.fallbackIp != null) {
      hosts[server.domain!] = server.fallbackIp!;
    } else if (server.type == DnsType.doh || server.type == DnsType.dot) {
      // Bootstrap for domain-based custom DoH/DoT: without a static hosts entry,
      // xray can't resolve the server hostname (circular dependency).
      final host = server.type == DnsType.doh
          ? (Uri.tryParse(server.address)?.host ?? '')
          : server.address;
      if (host.isNotEmpty && !_isIpAddress(host)) {
        servers.insert(servers.length - 1, {
          'address': XrayDefaults.bootstrapDns,
          'port': 53,
          'domains': [host],
        });
      }
    }

    return {
      'tag': 'dns-module',
      'hosts': hosts,
      'servers': servers,
      'queryStrategy': strategy,
    };
  }

  static Map<String, dynamic> _buildOutbound(
    VpnConfig config,
    TlsFingerprint fp,
  ) {
    if (config.protocol == VpnProtocol.hysteria2) {
      return {
        'tag': 'proxy',
        'protocol': 'hysteria',
        'settings': _buildOutboundSettings(config),
        'streamSettings': _buildStreamSettings(config, fp),
      };
    }
    return {
      'tag': 'proxy',
      'protocol': config.protocol.name,
      'settings': _buildOutboundSettings(config),
      'streamSettings': _buildStreamSettings(config, fp),
    };
  }

  static Map<String, dynamic> _buildOutboundSettings(VpnConfig config) {
    switch (config.protocol) {
      case VpnProtocol.vless:
        return {
          'vnext': [
            {
              'address': config.address,
              'port': config.port,
              'users': [
                {
                  'id': config.uuid,
                  'encryption': config.encryption ?? 'none',
                  'flow': config.flow ?? '',
                },
              ],
            },
          ],
        };
      case VpnProtocol.vmess:
        return {
          'vnext': [
            {
              'address': config.address,
              'port': config.port,
              'users': [
                {'id': config.uuid, 'security': 'auto'},
              ],
            },
          ],
        };
      case VpnProtocol.trojan:
        return {
          'servers': [
            {
              'address': config.address,
              'port': config.port,
              'password': config.password ?? '',
            },
          ],
        };
      case VpnProtocol.shadowsocks:
        return {
          'servers': [
            {
              'address': config.address,
              'port': config.port,
              'method': config.method ?? 'chacha20-ietf-poly1305',
              'password': config.password ?? '',
            },
          ],
        };
      case VpnProtocol.hysteria2:
        return {'version': 2, 'address': config.address, 'port': config.port};
    }
  }

  // xray uses "h2" for HTTP/2, not the enum name "http2".
  static String _networkName(VpnTransport t) =>
      t == VpnTransport.http2 ? 'h2' : t.name;

  static String _formatPinSHA256(String pin) {
    try {
      return pin
          .split(',')
          .map((value) {
            final hex = value.trim().replaceAll(':', '');
            if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
              return hex.toLowerCase();
            }
            final bytes = base64Decode(base64.normalize(value.trim()));
            if (bytes.length != 32) {
              throw const FormatException('SHA-256 length');
            }
            return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          })
          .join(',');
    } catch (_) {
      throw const ConnectionPlanException(
        'INVALID_TLS_PIN',
        'TLS pin должен содержать SHA-256 сертификата',
      );
    }
  }

  static Map<String, dynamic> _buildStreamSettings(
    VpnConfig config,
    TlsFingerprint fp,
  ) {
    // Глобальный override из настроек приложения; defaultFp — значение из конфига.
    final fingerprint = fp.xrayValue ?? config.fingerprint;
    if (config.protocol == VpnProtocol.hysteria2) {
      return {
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': _buildTlsSettings(config, fingerprint),
        'hysteriaSettings': {'version': 2, 'auth': config.password ?? ''},
        if (config.obfsPassword != null && config.obfsPassword!.isNotEmpty)
          'finalmask': {
            'udp': [
              {
                'type': 'salamander',
                'settings': {'password': config.obfsPassword},
              },
            ],
          },
      };
    }
    return {
      'network': _networkName(config.transport),
      'security': config.security.name,
      if (config.security == VpnSecurity.reality)
        'realitySettings': {
          'serverName': config.sni ?? '',
          'fingerprint': fingerprint ?? 'chrome',
          'publicKey': config.publicKey ?? '',
          'shortId': config.shortId ?? '',
          'spiderX': config.spiderX ?? '',
          if (config.postQuantumKey != null &&
              config.postQuantumKey!.isNotEmpty)
            'mldsa65Verify': config.postQuantumKey,
        },
      if (config.security == VpnSecurity.tls)
        'tlsSettings': _buildTlsSettings(config, fingerprint),
      if (config.transport == VpnTransport.ws)
        'wsSettings': {
          'path': config.wsPath ?? '/',
          'headers': {'Host': config.wsHost ?? ''},
        },
      if (config.transport == VpnTransport.grpc)
        'grpcSettings': {'serviceName': config.grpcServiceName ?? ''},
      if (config.transport == VpnTransport.xhttp)
        'xhttpSettings': {
          'path': config.wsPath ?? '/',
          if (config.wsHost != null && config.wsHost!.isNotEmpty)
            'host': config.wsHost,
          if (config.xhttpMode != null && config.xhttpMode!.isNotEmpty)
            'mode': config.xhttpMode,
          if (config.xhttpExtra != null && config.xhttpExtra!.isNotEmpty)
            'extra': config.xhttpExtra,
        },
      if (config.transport == VpnTransport.splithttp)
        'splithttpSettings': {
          'path': config.wsPath ?? '/',
          if (config.wsHost != null && config.wsHost!.isNotEmpty)
            'host': config.wsHost,
        },
      if (config.transport == VpnTransport.httpupgrade)
        'httpupgradeSettings': {
          'path': config.wsPath ?? '/',
          if (config.wsHost != null && config.wsHost!.isNotEmpty)
            'host': config.wsHost,
        },
      if (config.finalmask != null && config.finalmask!.isNotEmpty)
        'finalmask': config.finalmask,
    };
  }

  static String buildJson(VpnConfig config, VpnEngineOptions options) {
    return const JsonEncoder().convert(build(config, options));
  }

  static Map<String, dynamic> _buildTlsSettings(
    VpnConfig config,
    String? fingerprint,
  ) {
    if (config.allowInsecure &&
        (config.pinSHA256 == null || config.pinSHA256!.isEmpty)) {
      throw const ConnectionPlanException(
        'UNSUPPORTED_TLS_INSECURE',
        'Закреплённое ядро требует проверку TLS: добавьте pin сертификата или отключите insecure',
      );
    }
    return {
      'serverName': config.sni ?? '',
      'allowInsecure': false,
      if (fingerprint != null && fingerprint.isNotEmpty)
        'fingerprint': fingerprint,
      if (config.pinSHA256 != null && config.pinSHA256!.isNotEmpty)
        'pinnedPeerCertSha256': _formatPinSHA256(config.pinSHA256!),
      if (config.alpn != null && config.alpn!.isNotEmpty)
        'alpn': config.alpn!.split(',').map((s) => s.trim()).toList(),
      if (config.ech != null && config.ech!.isNotEmpty)
        'echConfigList': config.ech,
    };
  }

  static bool _isIpAddress(String host) {
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) return true;
    if (host.contains(':')) return true; // IPv6
    return false;
  }

  /// Merge app settings into a pre-built raw xray config from a managed subscription.
  ///
  /// Unlike [build], we preserve the server's outbound topology (load balancers,
  /// observatory, custom outbound tags). Only port/credentials, DNS, log and
  /// safe bypass rules (→ direct) are overlaid.
  static String mergeWithRaw(String rawConfig, VpnEngineOptions options) {
    try {
      final cfg = jsonDecode(rawConfig) as Map<String, dynamic>;
      for (final outbound
          in (cfg['outbounds'] as List? ?? []).whereType<Map>()) {
        final stream = outbound['streamSettings'];
        final tls = stream is Map ? stream['tlsSettings'] : null;
        if (tls is Map &&
            (tls.containsKey('pinnedPeerCertificateChainSha256') ||
                tls.containsKey('echSettings'))) {
          throw const ConnectionPlanException(
            'UNSUPPORTED_TLS_FIELDS',
            'Подписка использует устаревшие поля TLS pin/ECH; обновите её у поставщика',
          );
        }
      }

      // Preserve the original socks inbound tag so server routing rules
      // (inboundTag: ["socks", "http"]) keep matching after we replace the inbound.
      final originalInbounds = List<dynamic>.from(
        cfg['inbounds'] as List? ?? [],
      );
      final socksTag =
          originalInbounds
              .whereType<Map<String, dynamic>>()
              .where((i) => i['protocol'] == 'socks')
              .map((i) => i['tag'] as String?)
              .firstWhere(
                (t) => t != null && t.isNotEmpty,
                orElse: () => null,
              ) ??
          'socks';

      cfg['inbounds'] = [
        {
          'tag': socksTag,
          'protocol': 'socks',
          'port': options.socksPort,
          'listen': XrayDefaults.socksListen,
          'settings': {
            'auth': options.socksUser.isNotEmpty ? 'password' : 'noauth',
            if (options.socksUser.isNotEmpty)
              'accounts': [
                {'user': options.socksUser, 'pass': options.socksPassword},
              ],
            'udp': options.enableUdp,
          },
          'sniffing': {
            'enabled': options.sniffingEnabled,
            if (options.sniffingEnabled) ...{
              'destOverride': ['http', 'tls', 'quic'],
              'routeOnly': true,
            },
          },
        },
      ];

      cfg['log'] = {'loglevel': options.logLevel.name};
      _clampObservatoryInterval(cfg, options.obsProbeIntervalSec);
      _neutralizeDirectFallback(cfg);
      final target = _managedProxyTarget(cfg, socksTag);
      final directTag = _ensureOutbound(cfg, 'direct', 'freedom');
      final dnsTag = _ensureOutbound(cfg, 'teapod-dns-out', 'dns');
      final dnsInbound = _uniqueTag(cfg, 'teapod-dns-module');
      final dns = _buildDnsBlock(options);
      dns['hosts'] = {
        ...((cfg['dns'] as Map?)?['hosts'] as Map? ?? {}),
        ...(dns['hosts'] as Map? ?? {}),
      };
      if (options.dnsMode == DnsMode.proxy) dns['tag'] = dnsInbound;
      cfg['dns'] = dns;
      final appRules = <Map<String, dynamic>>[
        if (options.routing.adBlockEnabled)
          {
            'type': 'field',
            'domain': [XrayDefaults.adBlockGeosite],
            'outboundTag': _ensureBlackholeOutbound(cfg),
          },
        if (options.dnsMode == DnsMode.proxy) ...[
          {
            'type': 'field',
            'inboundTag': [dnsInbound],
            ...target,
          },
          {
            'type': 'field',
            'inboundTag': [socksTag],
            'port': '53',
            'network': 'udp,tcp',
            'outboundTag': dnsTag,
          },
        ] else
          {
            'type': 'field',
            'port': '53',
            'network': 'udp,tcp',
            'outboundTag': directTag,
          },
        ..._buildGeoRules(options.routing).map((rule) {
          final result = Map<String, dynamic>.from(rule);
          final out = result.remove('outboundTag');
          result.addAll(out == 'direct' ? {'outboundTag': directTag} : target);
          return result;
        }),
        if (options.routing.direction == RoutingDirection.onlySelected) ...[
          {
            'type': 'field',
            'domain': [
              'full:cp.cloudflare.com',
              'full:connectivitycheck.gstatic.com',
              'full:api.ipify.org',
              'full:api.country.is',
            ],
            ...target,
          },
          {
            'type': 'field',
            'inboundTag': [socksTag],
            'outboundTag': directTag,
          },
        ],
      ];
      final serverRouting = cfg['routing'] as Map<String, dynamic>? ?? {};
      cfg['routing'] = {
        ...serverRouting,
        if (_needsIpResolution(options.routing)) 'domainStrategy': 'IPOnDemand',
        'rules': [...appRules, ...(serverRouting['rules'] as List? ?? [])],
      };
      validateReferences(cfg);

      return jsonEncode(cfg);
    } on ConnectionPlanException {
      rethrow;
    } catch (_) {
      throw const ConnectionPlanException(
        'INVALID_MANAGED_CONFIG',
        'Не удалось применить настройки управляемой конфигурации',
      );
    }
  }

  /// Tag of the blackhole outbound injected into managed configs (fallback
  /// neutralization, adblock). Injected once by [_ensureBlackholeOutbound].
  static const blackholeTag = 'teapod-blackhole';

  /// Balancers in managed configs may declare `fallbackTag: "direct"` — when the
  /// leastLoad strategy has no qualified nodes (all marked dead, or the first
  /// seconds after start before observatory produced any probe results), xray
  /// would silently route user traffic OUTSIDE the VPN via the freedom outbound.
  /// That is a security leak: rewrite such fallbacks to the first proxy outbound
  /// matching the balancer's selector (fails via the VPN, works instantly on
  /// startup), or to a blackhole when no such outbound exists.
  static void _neutralizeDirectFallback(Map<String, dynamic> cfg) {
    final routing = cfg['routing'];
    if (routing is! Map<String, dynamic>) return;
    final balancers = routing['balancers'];
    if (balancers is! List) return;

    final outbounds = (cfg['outbounds'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final freedomTags = outbounds
        .where((o) => o['protocol'] == 'freedom')
        .map((o) => o['tag'] as String?)
        .whereType<String>()
        .toSet();

    for (final b in balancers.whereType<Map<String, dynamic>>()) {
      final fb = b['fallbackTag'];
      if (fb is! String || !freedomTags.contains(fb)) continue;
      final proxy = _firstSelectorOutbound(outbounds, b['selector']);
      if (proxy != null) {
        b['fallbackTag'] = proxy;
      } else {
        b['fallbackTag'] = _ensureBlackholeOutbound(cfg);
      }
    }
  }

  /// First outbound tag matching a balancer selector (xray selectors are tag
  /// prefixes), skipping non-proxy protocols.
  static String? _firstSelectorOutbound(
    List<Map<String, dynamic>> outbounds,
    dynamic selector,
  ) {
    if (selector is! List) return null;
    const nonProxy = {'freedom', 'blackhole', 'dns', 'loopback'};
    final prefixes = selector.whereType<String>().toList();
    for (final o in outbounds) {
      final tag = o['tag'];
      if (tag is! String || nonProxy.contains(o['protocol'])) continue;
      if (prefixes.any(tag.startsWith)) return tag;
    }
    return null;
  }

  static String _ensureBlackholeOutbound(Map<String, dynamic> cfg) =>
      _ensureOutbound(cfg, blackholeTag, 'blackhole');

  static String _uniqueTag(Map<String, dynamic> cfg, String preferred) {
    final tags = <Object?>{
      for (final key in ['inbounds', 'outbounds'])
        ...((cfg[key] as List?) ?? []).whereType<Map>().map((o) => o['tag']),
      (cfg['dns'] as Map?)?['tag'],
    };
    var tag = preferred;
    for (var n = 1; tags.contains(tag); n++) {
      tag = '$preferred-$n';
    }
    return tag;
  }

  static String _ensureOutbound(
    Map<String, dynamic> cfg,
    String preferred,
    String protocol,
  ) {
    final outbounds = cfg['outbounds'] as List<dynamic>;
    if (outbounds.whereType<Map>().any(
      (o) =>
          o['tag'] == preferred &&
          o['protocol'] == protocol &&
          (o['settings'] == null ||
              (o['settings'] is Map && (o['settings'] as Map).isEmpty)) &&
          o.keys.every((k) => ['tag', 'protocol', 'settings'].contains(k)),
    )) {
      return preferred;
    }
    final tag = _uniqueTag(cfg, preferred);
    outbounds.add({
      'tag': tag,
      'protocol': protocol,
      'settings': <String, dynamic>{},
    });
    return tag;
  }

  static Map<String, dynamic> _managedProxyTarget(
    Map<String, dynamic> cfg,
    String socksTag,
  ) {
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    if (outbounds.isEmpty) {
      throw const ConnectionPlanException(
        'NO_PROXY_TARGET',
        'В конфигурации нет исходящих подключений',
      );
    }
    bool proxy(String tag) => outbounds.any(
      (o) =>
          o['tag'] == tag &&
          !const [
            'freedom',
            'blackhole',
            'dns',
            'loopback',
          ].contains(o['protocol']),
    );
    final routing = cfg['routing'] as Map? ?? {};
    for (final rule in (routing['rules'] as List? ?? []).whereType<Map>()) {
      if (rule.keys.any(
        (k) => !const [
          'type',
          'network',
          'inboundTag',
          'outboundTag',
          'balancerTag',
        ].contains(k),
      )) {
        continue;
      }
      final inbounds = rule['inboundTag'] as List?;
      if (inbounds != null && !inbounds.contains(socksTag)) continue;
      final network = rule['network'];
      if (network != null && network != 'tcp,udp' && network != 'udp,tcp') {
        continue;
      }
      if (rule['balancerTag'] is String) {
        final balancers = (routing['balancers'] as List? ?? [])
            .whereType<Map>();
        final balancer = balancers
            .where((b) => b['tag'] == rule['balancerTag'])
            .firstOrNull;
        if (balancer == null) {
          throw const ConnectionPlanException(
            'MISSING_BALANCER',
            'Балансировщик отсутствует',
          );
        }
        final prefixes = (balancer['selector'] as List? ?? []).cast<String>();
        final matches = outbounds
            .where(
              (o) => prefixes.any((s) => (o['tag'] as String).startsWith(s)),
            )
            .toList();
        if (matches.any((o) => !proxy(o['tag'] as String))) {
          throw const ConnectionPlanException(
            'UNSAFE_BALANCER',
            'Балансировщик включает прямой или служебный маршрут',
          );
        }
        if (matches.isEmpty && balancer['fallbackTag'] == null) {
          throw const ConnectionPlanException(
            'EMPTY_BALANCER',
            'Балансировщик не содержит подключений',
          );
        }
        return {'balancerTag': rule['balancerTag']};
      }
      if (rule['outboundTag'] is String &&
          proxy(rule['outboundTag'] as String)) {
        return {'outboundTag': rule['outboundTag']};
      }
    }
    final first = outbounds.first;
    if (first['tag'] is String && proxy(first['tag'] as String)) {
      return {'outboundTag': first['tag']};
    }
    throw const ConnectionPlanException(
      'AMBIGUOUS_PROXY_TARGET',
      'Подписка не задаёт однозначный маршрут через прокси',
    );
  }

  static void validateReferences(Map<String, dynamic> cfg) {
    final outbounds = (cfg['outbounds'] as List).cast<Map>();
    final tags = outbounds.map((o) => o['tag']).toSet();
    if (tags.contains(null) || tags.length != outbounds.length) {
      throw const ConnectionPlanException(
        'INVALID_OUTBOUND_TAGS',
        'Теги подключений отсутствуют или повторяются',
      );
    }
    final routing = cfg['routing'] as Map? ?? {};
    final balancers = (routing['balancers'] as List? ?? []).cast<Map>();
    final balancerTags = balancers.map((b) => b['tag']).toSet();
    if (balancerTags.contains(null) ||
        balancerTags.length != balancers.length) {
      throw const ConnectionPlanException(
        'INVALID_BALANCER_TAGS',
        'Неверные теги балансировщиков',
      );
    }
    for (final rule in [
      ...(routing['rules'] as List? ?? []).cast<Map>(),
      ...balancers,
    ]) {
      for (final key in ['outboundTag', 'fallbackTag']) {
        if (rule[key] != null && !tags.contains(rule[key])) {
          throw const ConnectionPlanException(
            'MISSING_OUTBOUND',
            'Маршрут ссылается на отсутствующее подключение',
          );
        }
      }
      if (rule['balancerTag'] != null &&
          !balancerTags.contains(rule['balancerTag'])) {
        throw const ConnectionPlanException(
          'MISSING_BALANCER',
          'Маршрут ссылается на отсутствующий балансировщик',
        );
      }
    }
  }

  static EffectiveConnectionPlan plan(
    VpnConfig config,
    VpnEngineOptions options, {
    int revision = 0,
  }) {
    final error = config.validate();
    if (error != null) throw ConnectionPlanException('INVALID_CONFIG', error);
    final managed = config.rawXrayConfig != null;
    return EffectiveConnectionPlan(
      xrayJson: managed
          ? mergeWithRaw(config.rawXrayConfig!, options)
          : buildJson(config, options),
      mode: options.proxyOnly
          ? 'proxyOnly'
          : options.vpnMode.name == 'allExcept' &&
                options.excludedPackages.isEmpty
          ? 'all'
          : options.vpnMode.name,
      source: managed ? 'managed' : 'config',
      revision: revision,
      appliedSettings: {
        'routing': options.routing.toJson(),
        'dnsMode': options.dnsMode.name,
        'proxyOnly': options.proxyOnly,
        'vpnMode': options.vpnMode.name,
        'includedPackages': options.includedPackages.toList(),
        'excludedPackages': options.excludedPackages.toList(),
      },
      unsupportedSettings: managed ? ['tlsFingerprint'] : [],
    );
  }

  /// Managed configs often ship aggressive observatory settings (e.g. probeInterval
  /// 30s with 20+ outbounds). On mobile that means a burst of concurrent TLS probes
  /// every interval: it saturates the LTE radio, drains battery and triggers
  /// server-side rate limiting that resets in-flight user connections. Clamp the
  /// probe interval to at least [minSec] (0 = keep the server's value).
  static void _clampObservatoryInterval(Map<String, dynamic> cfg, int minSec) {
    if (minSec <= 0) return;
    for (final key in ['observatory', 'burstObservatory']) {
      final obs = cfg[key];
      if (obs is! Map<String, dynamic>) continue;
      final raw = obs['probeInterval'];
      if (raw is String && _intervalToSeconds(raw) < minSec) {
        obs['probeInterval'] = '${minSec}s';
      }
    }
  }

  /// Parses xray duration strings ("30s", "5m", "1h"). Unknown formats → max int
  /// so we never touch values we cannot read.
  static int _intervalToSeconds(String v) {
    final m = RegExp(r'^(\d+)(s|m|h)?$').firstMatch(v.trim());
    if (m == null) return 1 << 30;
    final n = int.parse(m.group(1)!);
    switch (m.group(2)) {
      case 'h':
        return n * 3600;
      case 'm':
        return n * 60;
      default:
        return n;
    }
  }
}
