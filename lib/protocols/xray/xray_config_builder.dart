import 'dart:convert';
import '../../core/interfaces/vpn_engine.dart';
import '../../core/models/vpn_config.dart';
import '../../core/models/dns_config.dart';
import '../../core/models/routing_settings.dart';
import '../../core/constants/xray_defaults.dart';
import '../../core/services/settings_service.dart' show DnsQueryStrategy;

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
        _buildOutbound(config),
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'dns-out', 'protocol': 'dns'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          if (options.blockQuic) ...[
            // Only block QUIC for user traffic (socks-in), not for xray's internal DNS module connections.
            {
              'type': 'field',
              'inboundTag': ['socks-in'],
              'port': '443',
              'network': 'udp',
              'outboundTag': 'block',
            },
          ],
          if (options.dnsMode == DnsMode.proxy) ...[
            // DoH/DoT connections from the DNS module go direct (not through VLESS proxy).
            // xray protects these sockets via VpnService.protect(), so they bypass the TUN
            // and reach the DNS server without going through the VPN tunnel.
            // Going through VLESS causes unreliable HTTP/2 — each query opens a new
            // VLESS connection and responses timeout because Google closes them quickly.
            // DoH/DoT encrypt DNS independently of VPN, so direct is still private.
            // UDP DNS continues to go through proxy to preserve VPN-side DNS resolution.
            {
              'type': 'field',
              'inboundTag': ['dns-module'],
              'outboundTag': options.dnsServer.type == DnsType.udp
                  ? 'proxy'
                  : 'direct',
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
              'domain': ['full:cp.cloudflare.com', 'full:ip-api.com'],
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

    if (!routing.geoEnabled &&
        !routing.domainEnabled &&
        !routing.geositeEnabled)
      return rules;

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
    // Add adblock first - returns empty response for matched domains
    if (routing.adBlockEnabled) {
      servers.add({
        'address': 'rcode://success',
        'domains': [XrayDefaults.adBlockGeosite, 'geosite:win-spy'],
      });
    }

    // Add main DNS server
    switch (server.type) {
      case DnsType.udp:
        servers.add({'address': server.address, 'port': server.port});
        break;
      case DnsType.doh:
        servers.add({'address': server.address});
        break;
      case DnsType.dot:
        // Use domain as TLS address (SNI) when available; fall back to IP.
        servers.add({
          'address': 'tls://${server.domain ?? server.address}',
          'port': server.port,
        });
        break;
    }

    final hosts = <String, String>{};
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

  static Map<String, dynamic> _buildOutbound(VpnConfig config) {
    if (config.protocol == VpnProtocol.hysteria2) {
      return {
        'tag': 'proxy',
        'protocol': 'hysteria',
        'settings': _buildOutboundSettings(config),
        'streamSettings': _buildStreamSettings(config),
      };
    }
    return {
      'tag': 'proxy',
      'protocol': config.protocol.name,
      'settings': _buildOutboundSettings(config),
      'streamSettings': _buildStreamSettings(config),
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

  static List<String>? _formatPinSHA256(String? pin) {
    if (pin == null || pin.isEmpty) return null;
    try {
      if (pin.contains(':')) {
        final bytes = pin
            .split(':')
            .map((e) => int.parse(e, radix: 16))
            .toList();
        return [base64Encode(bytes)];
      }
      if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(pin)) {
        final bytes = <int>[];
        for (var i = 0; i < pin.length; i += 2) {
          bytes.add(int.parse(pin.substring(i, i + 2), radix: 16));
        }
        return [base64Encode(bytes)];
      }
      return [pin];
    } catch (_) {
      return [pin];
    }
  }

  static Map<String, dynamic> _buildStreamSettings(VpnConfig config) {
    if (config.protocol == VpnProtocol.hysteria2) {
      return {
        'network': 'hysteria',
        'security': 'tls',
        'tlsSettings': {
          'serverName': config.sni ?? '',
          'allowInsecure': config.allowInsecure,
          if (config.pinSHA256 != null && config.pinSHA256!.isNotEmpty)
            'pinnedPeerCertificateChainSha256': _formatPinSHA256(
              config.pinSHA256,
            ),
        },
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
          'fingerprint': config.fingerprint ?? 'chrome',
          'publicKey': config.publicKey ?? '',
          'shortId': config.shortId ?? '',
          'spiderX': config.spiderX ?? '',
          if (config.postQuantumKey != null &&
              config.postQuantumKey!.isNotEmpty)
            'mldsa65Verify': config.postQuantumKey,
        },
      if (config.security == VpnSecurity.tls)
        'tlsSettings': {
          'serverName': config.sni ?? '',
          'allowInsecure': false,
          if (config.fingerprint != null && config.fingerprint!.isNotEmpty)
            'fingerprint': config.fingerprint,
          if (config.alpn != null && config.alpn!.isNotEmpty)
            'alpn': config.alpn!.split(',').map((s) => s.trim()).toList(),
          if (config.ech != null && config.ech!.isNotEmpty)
            'echSettings': {
              'enable': true,
              'config': [config.ech],
            },
        },
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

  static bool _isIpAddress(String host) {
    if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host)) return true;
    if (host.contains(':')) return true; // IPv6
    return false;
  }

  /// Merge app settings into a pre-built raw xray config from a managed subscription.
  /// App settings take priority: inbounds, dns, log are replaced; app routing rules
  /// are prepended (with higher priority than server rules).
  static String mergeWithRaw(String rawConfig, VpnEngineOptions options) {
    try {
      final cfg = jsonDecode(rawConfig) as Map<String, dynamic>;

      // Replace inbounds with app's (port, credentials, sniffing)
      cfg['inbounds'] = [
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
              'routeOnly': true,
            },
          },
        },
      ];

      // Replace dns with app's (adblock, DNS server, DNS mode)
      cfg['dns'] = _buildDnsBlock(options);

      // Replace log level
      cfg['log'] = {'loglevel': options.logLevel.name};

      // Ensure dns-out outbound exists (needed for DNS proxy mode rule)
      if (options.dnsMode == DnsMode.proxy) {
        final outbounds = List<dynamic>.from(cfg['outbounds'] as List? ?? []);
        if (!outbounds.any((o) => (o as Map?)?['tag'] == 'dns-out')) {
          outbounds.add({'tag': 'dns-out', 'protocol': 'dns'});
          cfg['outbounds'] = outbounds;
        }
      }

      // Build app routing rules to prepend (app has priority over server rules)
      final appRules = <Map<String, dynamic>>[];

      if (options.blockQuic) {
        appRules.add({
          'type': 'field',
          'inboundTag': ['socks-in'],
          'port': '443',
          'network': 'udp',
          'outboundTag': 'block',
        });
      }

      if (options.dnsMode == DnsMode.proxy) {
        appRules.add({
          'type': 'field',
          'inboundTag': ['dns-module'],
          'outboundTag': options.dnsServer.type == DnsType.udp
              ? 'proxy'
              : 'direct',
        });
        appRules.add({
          'type': 'field',
          'inboundTag': ['socks-in'],
          'port': '53',
          'network': 'udp,tcp',
          'outboundTag': 'dns-out',
        });
      } else if (options.dnsMode == DnsMode.direct) {
        appRules.add({
          'type': 'field',
          'port': '53',
          'network': 'udp,tcp',
          'outboundTag': 'direct',
        });
      }

      // Bypass/only rules from app settings — only safe if direction is not global
      final routing = options.routing;
      if (routing.isActive) {
        appRules.addAll(_buildGeoRules(routing));
      }

      // Prepend app rules to the server's existing rules
      if (appRules.isNotEmpty) {
        final serverRouting = cfg['routing'] as Map<String, dynamic>? ?? {};
        final serverRules = List<dynamic>.from(
          serverRouting['rules'] as List? ?? [],
        );
        cfg['routing'] = {
          ...serverRouting,
          'rules': [...appRules, ...serverRules],
        };
      }

      return jsonEncode(cfg);
    } catch (_) {
      return rawConfig;
    }
  }
}
