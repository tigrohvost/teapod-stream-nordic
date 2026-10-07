class XrayDefaults {
  static const socksListen = '127.0.0.1';
  static const bootstrapDns = '8.8.8.8';
  static const adBlockGeosite = 'geosite:category-ads-all';

  // xray policy timeouts (seconds)
  static const handshakeTimeout = 4;
  // xray's own default. 120 s cut idle long-lived connections (push channels,
  // messenger keepalives) every two minutes; HeartbeatMonitor.TUN_STALL_TIMEOUT_MS
  // must stay above this value.
  static const connIdleTimeout = 300;
  static const uplinkOnlyTimeout = 5;
  static const downlinkOnlyTimeout = 30;
}
