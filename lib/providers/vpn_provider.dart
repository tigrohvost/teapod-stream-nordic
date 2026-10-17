import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/interfaces/vpn_engine.dart';
import '../core/models/vpn_config.dart';
import '../core/models/effective_connection_plan.dart';
import '../core/services/probe_scheduler.dart';
import '../core/constants/app_constants.dart';
import '../core/models/vpn_stats.dart';
import '../core/models/connection_fingerprint.dart';
import '../core/models/vpn_log_entry.dart';
import '../core/services/log_service.dart';
import '../core/services/settings_service.dart';
import 'ip_info_provider.dart';
import '../protocols/xray/xray_engine.dart';
import 'settings_provider.dart';
import 'config_provider.dart';

class VpnState2 {
  final VpnState connectionState;
  final VpnStats stats;
  final String? error;
  final String appliedMode;
  final String appliedSource;
  final int appliedRevision;
  final int activeSocksPort;
  final String activeSocksUser;
  final String activeSocksPassword;

  /// Fingerprint настроек, с которыми установлено текущее соединение.
  /// null — соединение не активно или отпечаток неизвестен.
  final String? appliedFingerprint;

  const VpnState2({
    this.connectionState = VpnState.disconnected,
    this.stats = const VpnStats(),
    this.error,
    this.appliedMode = 'unknown',
    this.appliedSource = 'unknown',
    this.appliedRevision = 0,
    this.activeSocksPort = 0,
    this.activeSocksUser = '',
    this.activeSocksPassword = '',
    this.appliedFingerprint,
  });

  bool get isConnected => connectionState == VpnState.connected;
  bool get isConnecting =>
      connectionState == VpnState.connecting ||
      connectionState == VpnState.awaitingPermission ||
      connectionState == VpnState.recovering;
  bool get isDisconnecting => connectionState == VpnState.disconnecting;
  bool get isBlocked =>
      connectionState == VpnState.blocked ||
      connectionState == VpnState.stopBlocked;
  bool get isBusy =>
      isConnecting ||
      isDisconnecting ||
      connectionState == VpnState.stopBlocked;

  static const _keep = Object();

  /// [error] is kept unless passed; pass null to clear it. Stats ticks call
  /// copyWith every second and must not wipe a visible error.
  VpnState2 copyWith({
    VpnState? connectionState,
    VpnStats? stats,
    Object? error = _keep,
    String? appliedMode,
    String? appliedSource,
    int? appliedRevision,
    int? activeSocksPort,
    String? activeSocksUser,
    String? activeSocksPassword,
    String? appliedFingerprint,
  }) {
    return VpnState2(
      connectionState: connectionState ?? this.connectionState,
      stats: stats ?? this.stats,
      error: identical(error, _keep) ? this.error : error as String?,
      appliedMode: appliedMode ?? this.appliedMode,
      appliedSource: appliedSource ?? this.appliedSource,
      appliedRevision: appliedRevision ?? this.appliedRevision,
      activeSocksPort: activeSocksPort ?? this.activeSocksPort,
      activeSocksUser: activeSocksUser ?? this.activeSocksUser,
      activeSocksPassword: activeSocksPassword ?? this.activeSocksPassword,
      appliedFingerprint: appliedFingerprint ?? this.appliedFingerprint,
    );
  }
}

/// The one subscription to the native event channel, shared by every listener.
/// Each receiveBroadcastStream() call installs its own platform handler and
/// replaces the previous one, so a second call (app.dart's deeplink listener)
/// silently took the events away from the other.
final Stream<dynamic> vpnEvents = const EventChannel(
  '${AppConstants.methodChannel}/events',
).receiveBroadcastStream();

final vpnEngineProvider = Provider<XrayEngine>((ref) => XrayEngine());
final vpnEventProvider = Provider<Stream<dynamic>>((ref) => vpnEvents);

class VpnNotifier extends Notifier<VpnState2> {
  late final XrayEngine _engine;

  StreamSubscription<dynamic>? _eventSub;
  Timer? _connectTimeout;
  Timer? _disconnectTimeout;
  bool _appActive = true;
  bool _statsVisible = true;
  bool _statsInFlight = false;
  int _statsGeneration = 0;
  int _sessionId = 0;
  int _attempt = 0;
  int _statsEvents = 0;
  String? _pendingFingerprint;
  final _probes = ProbeScheduler();
  Timer? _subRefreshTimer;
  bool _isPinging = false;
  DateTime? _connectedAt;
  // A "stop not confirmed" error is about the stop itself: once native
  // reports disconnected, the stop did finish and the error is stale.
  bool _stopErrorShown = false;
  String _lastAppliedMode = 'unknown';

  /// The mode of the current session, or of the last one after it ended —
  /// diagnostics are usually exported after a failure or disconnect.
  String get lastAppliedMode =>
      state.appliedMode != 'unknown' ? state.appliedMode : _lastAppliedMode;

  @override
  VpnState2 build() {
    _engine = ref.read(vpnEngineProvider);

    _eventSub = ref
        .read(vpnEventProvider)
        .listen(
          (dynamic event) {
            if (event is Map) {
              _handleEvent(Map<String, dynamic>.from(event));
            }
          },
          onError: (dynamic error) {
            ref
                .read(logServiceProvider.notifier)
                .addError('Event channel error: $error');
          },
        );

    ref.onDispose(() {
      _eventSub?.cancel();
      _connectTimeout?.cancel();
      _disconnectTimeout?.cancel();
      _statsGeneration++;
      _subRefreshTimer?.cancel();
      _probes.cancel();
    });

    // Auto-refresh subscriptions: timer fires hourly, staleness check uses configured interval
    _subRefreshTimer = Timer.periodic(const Duration(hours: 1), (_) async {
      final settings = ref
          .read(settingsProvider)
          .maybeWhen(data: (d) => d, orElse: () => null);
      if (settings?.subAutoRefresh != true) return;
      try {
        await ref
            .read(configProvider.notifier)
            .refreshStaleSubscriptions(
              intervalHours: settings!.subAutoRefreshHours,
            );
      } catch (e) {
        ref
            .read(logServiceProvider.notifier)
            .addError('Subscription refresh failed: $e');
      }
    });

    // Sync state on init (for case when VPN is already running from tile/notification)
    Future.microtask(() async {
      // Auto-refresh stale subscriptions on startup
      final settings = ref
          .read(settingsProvider)
          .maybeWhen(data: (d) => d, orElse: () => null);
      if (settings?.subAutoRefresh == true) {
        // A failed refresh must not skip the state restore below — that left the
        // UI blind to a running session and the reconnect banner dead.
        try {
          await ref
              .read(configProvider.notifier)
              .refreshStaleSubscriptions(
                intervalHours: settings!.subAutoRefreshHours,
              );
        } catch (e) {
          ref
              .read(logServiceProvider.notifier)
              .addError('Subscription refresh failed: $e');
        }
      }

      // Restore log history (previous + current session files) even when
      // disconnected — needed to diagnose failures that ended the last session.
      final logEntries = await _engine.getLogs();
      if (logEntries.isNotEmpty) {
        ref.read(logServiceProvider.notifier).loadFromEntries(logEntries);
      }

      final vpnState = await _engine.getVpnState();
      if (!ref.mounted || vpnState.sessionId < _sessionId) return;
      _sessionId = vpnState.sessionId;
      if (vpnState.state == VpnState.connected && vpnState.socksPort > 0) {
        if (vpnState.connectedAtMs > 0) {
          _connectedAt = DateTime.fromMillisecondsSinceEpoch(
            vpnState.connectedAtMs,
          );
        }
        state = VpnState2(
          connectionState: VpnState.connected,
          appliedMode: vpnState.mode,
          appliedSource: vpnState.plan['source'] as String? ?? 'unknown',
          appliedRevision: vpnState.plan['revision'] as int? ?? 0,
          appliedFingerprint: vpnState.plan['fingerprint'] as String?,
          activeSocksPort: vpnState.socksPort,
          activeSocksUser: vpnState.socksUser,
          activeSocksPassword: vpnState.socksPassword,
        );
        // ipInfoProvider is AsyncNotifier, needs refresh to rebuild
        // ignore: unused_result
        ref.refresh(ipInfoProvider);
        // Also fetch initial stats
        _loadStatsSnapshot();
      }
    });

    return const VpnState2();
  }

  void _loadStatsSnapshot() {
    // A single snapshot on attach/resume. Subsequent points arrive as events.
    if (!_appActive ||
        !_statsVisible ||
        _statsInFlight ||
        state.appliedMode == 'proxyOnly') {
      return;
    }
    _statsInFlight = true;
    final generation = _statsGeneration;
    final events = _statsEvents;
    Future<void>(() async {
      try {
        final history = await _engine.getStatsHistory();
        if (ref.mounted &&
            _appActive &&
            _statsVisible &&
            generation == _statsGeneration &&
            events == _statsEvents) {
          _handleStatsHistory({'history': history});
        }
      } finally {
        _statsInFlight = false;
      }
    });
  }

  void setStatsVisible(bool visible) {
    if (_statsVisible == visible) return;
    _statsVisible = visible;
    _statsGeneration++;
    if (visible && state.isConnected) {
      _dropStaleHistory();
      _loadStatsSnapshot();
    }
  }

  /// Points from before a pause/hidden period must not be joined to new
  /// ones as if no time had passed. The native snapshot normally refills the
  /// chart; if it loses the race with a live event, the chart restarts.
  void _dropStaleHistory() {
    if (state.stats.speedHistory.isEmpty) return;
    state = state.copyWith(stats: state.stats.copyWith(speedHistory: const []));
  }

  void _handleEvent(Map<String, dynamic> event) {
    final incoming = (event['sessionId'] as num?)?.toInt();
    if (incoming != null && incoming < _sessionId) return;
    if (incoming != null && incoming > _sessionId) {
      _sessionId = incoming;
      _statsGeneration++;
    }
    final type = event['type'] as String?;
    switch (type) {
      case 'state':
        final rawValue = event['value'] as String?;
        final isReconnect = rawValue == 'reconnecting';
        final newState = _parseState(rawValue);
        if (newState == VpnState.connected) {
          final plan =
              jsonDecode(event['planInfo'] as String? ?? '{}')
                  as Map<String, dynamic>;
          final port = event['socksPort'] as int?;
          if (port != null && port > 0) {
            final user = event['socksUser'] as String? ?? '';
            final pass = event['socksPassword'] as String? ?? '';
            final connectedAtMs =
                (event['connectedAtMs'] as num?)?.toInt() ?? 0;
            if (connectedAtMs > 0) {
              _connectedAt ??= DateTime.fromMillisecondsSinceEpoch(
                connectedAtMs,
              );
            }
            state = state.copyWith(
              appliedMode: event['mode'] as String?,
              appliedSource: plan['source'] as String? ?? 'unknown',
              appliedRevision: plan['revision'] as int? ?? 0,
              appliedFingerprint: plan['fingerprint'] as String?,
              activeSocksPort: port,
              activeSocksUser: user,
              activeSocksPassword: pass,
            );
          }
        }
        _onNativeState(newState, isReconnect: isReconnect);
      case 'log':
        final level = event['level'] as String? ?? 'info';
        final msg = event['message'] as String? ?? '';
        ref
            .read(logServiceProvider.notifier)
            .add(
              VpnLogEntry(
                timestamp: DateTime.now(),
                level: LogLevel.values.firstWhere(
                  (e) => e.name == level,
                  orElse: () => LogLevel.info,
                ),
                message: msg,
                source: 'xray',
              ),
            );
      case 'connectionError':
        final code = event['code'] as String?;
        state = state.copyWith(
          error: switch (code) {
            'VPN_PERMISSION_REQUIRED' =>
              'Нажмите подключить и разрешите VPN в диалоге Android',
            'EMPTY_ALLOWED_APPS' => 'Выберите хотя бы одно приложение',
            'PREFIX_REQUIRES_TUN' =>
              'Prefix transport доступен только в режиме VPN',
            'GEODATA_UNAVAILABLE' =>
              'Геобазы повреждены или недоступны. Обновите их в настройках маршрутизации.',
            'NATIVE_STOP_TIMEOUT' || 'NATIVE_STOP_FAILED' =>
              'Остановка ядра не завершена. Новое подключение пока недоступно.',
            _ => 'Не удалось применить конфигурацию ($code)',
          },
        );
        _stopErrorShown =
            code == 'NATIVE_STOP_TIMEOUT' || code == 'NATIVE_STOP_FAILED';
      case 'stats':
        if (_appActive && _statsVisible && state.isConnected) {
          _handleStats(event);
        }
      case 'statsHistory':
        if (_appActive &&
            _statsVisible &&
            state.isConnected &&
            state.appliedMode != 'proxyOnly') {
          _handleStatsHistory(event);
        }
    }
  }

  VpnState _parseState(String? s) => switch (s) {
    'awaitingPermission' => VpnState.awaitingPermission,
    'stopBlocked' => VpnState.stopBlocked,
    'connecting' => VpnState.connecting,
    'reconnecting' => VpnState.recovering,
    'connected' => VpnState.connected,
    'disconnecting' => VpnState.disconnecting,
    'disconnected' => VpnState.disconnected,
    'error' => VpnState.error,
    'blocked' => VpnState.blocked,
    _ => VpnState.disconnected,
  };

  void _onNativeState(VpnState nativeState, {bool isReconnect = false}) {
    if (nativeState == VpnState.connected) {
      // A fresh connection clears errors of the attempt; re-adopting a live
      // session (resume, replay) keeps e.g. a rejected-config notice.
      state = state.copyWith(
        appliedFingerprint: _pendingFingerprint,
        error: state.connectionState == VpnState.connected ? state.error : null,
      );
      _pendingFingerprint = null;
      _connectedAt ??= DateTime.now();
      _connectTimeout?.cancel();
      _connectTimeout = null;
      // Load bounded native history once on attachment.
      _loadStatsSnapshot();
    } else if (nativeState == VpnState.disconnected ||
        nativeState == VpnState.error ||
        nativeState == VpnState.blocked ||
        nativeState == VpnState.stopBlocked) {
      _connectedAt = null;
      _connectTimeout?.cancel();
      _connectTimeout = null;
      _disconnectTimeout?.cancel();
      _disconnectTimeout = null;
    } else if (nativeState == VpnState.connecting ||
        nativeState == VpnState.recovering) {
      if (isReconnect) {
        // Native-triggered reconnect: cancel Flutter-side timeout so it doesn't
        // force error while the service is mid-reconnect (cycle can exceed 45s).
        _connectTimeout?.cancel();
        _connectTimeout = null;
      } else {
        _connectTimeout ??= Timer(const Duration(seconds: 45), () {
          if (state.connectionState == VpnState.connecting) {
            state = state.copyWith(
              connectionState: VpnState.error,
              error: 'Connection timeout',
            );
            _connectTimeout = null;
            _engine.disconnect().ignore();
          }
        });
      }
    } else if (nativeState == VpnState.disconnecting) {
      _disconnectTimeout ??= Timer(const Duration(seconds: 10), () {
        if (state.connectionState == VpnState.disconnecting) {
          state = state.copyWith(
            connectionState: VpnState.stopBlocked,
            error: 'Остановка ядра не подтверждена. Дождитесь завершения.',
          );
          _stopErrorShown = true;
          _disconnectTimeout = null;
        }
      });
    }

    if (state.connectionState == nativeState) return;

    if (nativeState == VpnState.disconnected ||
        nativeState == VpnState.error ||
        nativeState == VpnState.blocked ||
        nativeState == VpnState.stopBlocked) {
      _pendingFingerprint = null;
      if (state.appliedMode != 'unknown') _lastAppliedMode = state.appliedMode;
      final stopFinished =
          nativeState == VpnState.disconnected && _stopErrorShown;
      if (nativeState != VpnState.stopBlocked) _stopErrorShown = false;
      // Reset stats on disconnect/error/blocked
      _statsGeneration++;
      state = VpnState2(
        connectionState: nativeState,
        // Reset stats including speedHistory
        stats: const VpnStats(),
        error: stopFinished
            ? null
            : state.error ??
                  (nativeState == VpnState.error ? 'Ошибка подключения' : null),
      );
    } else {
      // A new phase starts without the previous phase's error.
      state = state.copyWith(connectionState: nativeState, error: null);
    }
  }

  void _handleStats(Map<String, dynamic> event) {
    if (state.appliedMode == 'proxyOnly') return;
    _statsEvents++;
    // Handle both int and Long (from Kotlin)
    final upload = (event['upload'] as num?)?.toInt() ?? 0;
    final download = (event['download'] as num?)?.toInt() ?? 0;
    final uploadSpeed = (event['uploadSpeed'] as num?)?.toInt() ?? 0;
    final downloadSpeed = (event['downloadSpeed'] as num?)?.toInt() ?? 0;

    // Always update speed, even if bytes haven't changed (for re-connect)
    state = state.copyWith(
      stats: state.stats.copyWith(
        uploadBytes: upload,
        downloadBytes: download,
        uploadSpeedBps: uploadSpeed,
        downloadSpeedBps: downloadSpeed,
        speedHistory: [
          ...state.stats.speedHistory.skip(
            state.stats.speedHistory.length >= 300 ? 1 : 0,
          ),
          SpeedPoint(uploadSpeed: uploadSpeed, downloadSpeed: downloadSpeed),
        ],
        connectedDuration: _connectedAt != null
            ? DateTime.now().difference(_connectedAt!)
            : Duration.zero,
      ),
    );
  }

  void _handleStatsHistory(Map<String, dynamic> event) {
    final historyRaw = event['history'];
    if (historyRaw is! List) return;

    final history = historyRaw
        .whereType<Map<Object?, Object?>>()
        .map((m) => SpeedPoint.fromMap(Map<String, dynamic>.from(m)))
        .toList();

    if (history.isEmpty) return;

    // Native history is the source of truth
    state = state.copyWith(
      stats: state.stats.copyWith(
        speedHistory: history
            .skip(history.length > 300 ? history.length - 300 : 0)
            .toList(),
      ),
    );
  }

  Future<void> connect() async {
    if (state.isBusy || state.isConnected) return;

    final attempt = ++_attempt;
    _stopErrorShown = false;
    state = state.copyWith(
      connectionState: VpnState.awaitingPermission,
      error: null,
    );
    _connectTimeout?.cancel();
    _connectTimeout = null;

    // Notification permission for foreground service (Android 13+) — best-effort
    await Permission.notification.request();

    // Cancelled meanwhile, or the EventChannel replay delivered the real state.
    if (!ref.mounted || attempt != _attempt || state.isConnected) return;
    // A UI started over a live session (tile, boot, always-on, recreated
    // activity) must adopt it: the service ignores a second connect, and the
    // fresh SOCKS credentials generated below would describe nothing.
    final native = await _engine.queryVpnState();
    if (!ref.mounted || attempt != _attempt || state.isConnected) return;
    if (native != null &&
        native.state == VpnState.connected &&
        native.socksPort > 0) {
      _connectTimeout?.cancel();
      _connectTimeout = null;
      _adoptConnected(native);
      return;
    }

    final configState = await ref.read(configProvider.future);
    final config = _resolveEffectiveConfig(configState);
    if (config == null) {
      ref
          .read(logServiceProvider.notifier)
          .addError('No configuration selected');
      state = state.copyWith(
        connectionState: VpnState.error,
        error: 'No configuration selected',
      );
      _connectTimeout?.cancel();
      _connectTimeout = null;
      return;
    }

    final validationError = config.validate();
    if (validationError != null) {
      ref
          .read(logServiceProvider.notifier)
          .addError('Invalid config: $validationError');
      state = state.copyWith(
        connectionState: VpnState.error,
        error: validationError,
      );
      _connectTimeout?.cancel();
      _connectTimeout = null;
      return;
    }

    final settings = await ref.read(settingsProvider.future);
    if (!ref.mounted || attempt != _attempt) return;
    if (!settings.proxyOnly &&
        settings.splitTunnelingEnabled &&
        settings.vpnMode == VpnMode.onlySelected &&
        settings.includedPackages.isEmpty) {
      state = state.copyWith(
        connectionState: VpnState.error,
        error: 'Выберите хотя бы одно приложение',
      );
      return;
    }

    final socksCredentials = settings.randomCredentials
        ? XrayEngine.generateSocksCredentials()
        : (user: settings.socksUser, password: settings.socksPassword);

    final actualSocksPort = settings.randomPort
        ? (10000 + Random().nextInt(50000))
        : settings.socksPort;

    final options = _options(
      config,
      settings,
      socksCredentials,
      actualSocksPort,
    );
    state = state.copyWith(
      activeSocksPort: actualSocksPort,
      activeSocksUser: socksCredentials.user,
      activeSocksPassword: socksCredentials.password,
    );

    _pendingFingerprint = connectionFingerprint(settings);
    try {
      await _engine.connect(
        config,
        options,
        revision: configState.revision,
        fingerprint: _pendingFingerprint,
      );
      // Polling is now started in _onNativeState when connected
    } on PlatformException catch (e) {
      if (!ref.mounted || attempt != _attempt) return;
      ref
          .read(logServiceProvider.notifier)
          .addError('Connection failed: ${e.message}');
      state = state.copyWith(connectionState: VpnState.error, error: e.message);
      _connectTimeout?.cancel();
      _connectTimeout = null;
    } on ConnectionPlanException catch (e) {
      if (ref.mounted && attempt == _attempt) {
        state = state.copyWith(
          connectionState: VpnState.error,
          error: e.message,
        );
      }
    }
  }

  Future<void> disconnect() async {
    _attempt++;
    _pendingFingerprint = null;
    _statsGeneration++;
    if (state.connectionState == VpnState.disconnected ||
        state.connectionState == VpnState.disconnecting) {
      return;
    }

    // Update state synchronously
    state = state.copyWith(
      connectionState: VpnState.disconnecting,
      error: null,
    );

    // A missed native completion is uncertain; keep new starts blocked.
    _disconnectTimeout?.cancel();
    _disconnectTimeout = Timer(const Duration(seconds: 10), () {
      if (state.connectionState == VpnState.disconnecting) {
        state = state.copyWith(
          connectionState: VpnState.stopBlocked,
          error: 'Остановка ядра не подтверждена. Дождитесь завершения.',
        );
        _stopErrorShown = true;
        _disconnectTimeout = null;
      }
    });

    try {
      await _engine.disconnect();
    } on PlatformException catch (e) {
      ref
          .read(logServiceProvider.notifier)
          .addError('Disconnect error: ${e.message}');
      // Force disconnected so the UI doesn't get stuck
      state = state.copyWith(
        connectionState: VpnState.stopBlocked,
        error: 'Остановка ядра не подтверждена. Дождитесь завершения.',
      );
      _stopErrorShown = true;
      _disconnectTimeout?.cancel();
      _disconnectTimeout = null;
    }
  }

  /// Stops UI-driven polling while the app is backgrounded: the numbers are
  /// invisible, but each tick costs two MethodChannel round-trips (one of them
  /// serialising the whole 300-point history on the platform thread).
  void onAppPaused() {
    _appActive = false;
    _statsGeneration++;
  }

  /// Resumes polling (and resyncs state) when the app returns to foreground.
  Future<void> onAppResumed() async {
    final wasPaused = !_appActive;
    _appActive = true;
    await syncNativeState();
    if (state.isConnected) {
      if (wasPaused) _dropStaleHistory();
      _loadStatsSnapshot();
    }
  }

  /// Syncs Flutter state from the native service: on app start and resume, and
  /// before auto-connect. EventChannel replay on `onListen` handles most cases;
  /// this also catches a session that died without an event (the native
  /// phantom-connection check in getNativeState). Returns the native state, or
  /// null when it couldn't be read.
  Future<VpnState?> syncNativeState() async {
    final native = await _engine.queryVpnState();
    if (native == null || native.sessionId < _sessionId) return null;
    _sessionId = native.sessionId;
    if (native.state == VpnState.connected && native.socksPort > 0) {
      _adoptConnected(native);
    } else {
      _onNativeState(
        native.state,
        isReconnect: native.rawState == 'reconnecting',
      );
    }
    return native.state;
  }

  /// Takes over a session the service already runs, with its real credentials.
  void _adoptConnected(NativeVpnState native) {
    if (native.connectedAtMs > 0) {
      _connectedAt ??= DateTime.fromMillisecondsSinceEpoch(
        native.connectedAtMs,
      );
    }
    state = state.copyWith(
      appliedMode: native.mode,
      appliedSource: native.plan['source'] as String? ?? 'unknown',
      appliedRevision: native.plan['revision'] as int? ?? 0,
      appliedFingerprint: native.plan['fingerprint'] as String?,
      activeSocksPort: native.socksPort,
      activeSocksUser: native.socksUser,
      activeSocksPassword: native.socksPassword,
    );
    _onNativeState(VpnState.connected);
  }

  Future<void> toggle() async {
    if (state.isBusy) return;
    if (state.isConnected) {
      await disconnect();
    } else {
      await connect();
    }
  }

  Future<void> reconnectWithNewConfig() async {
    final settings = await ref.read(settingsProvider.future);
    final config = ref.read(effectiveConfigProvider);
    if (config == null) return;
    try {
      await _engine.validate(
        config,
        _options(config, settings, (
          user: settings.socksUser,
          password: settings.socksPassword,
        ), settings.socksPort),
      );
    } catch (_) {
      state = state.copyWith(
        error: 'Новая конфигурация отклонена; текущее соединение сохранено',
      );
      return;
    }
    if (state.isConnected || state.isConnecting) {
      await disconnect();
      // _disconnectTimeout is 10s; wait up to 12s so the forced-disconnect fires first.
      for (int i = 0; i < 120; i++) {
        if (!state.isBusy && !state.isConnected) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await connect();
  }

  VpnConfig? _resolveEffectiveConfig(ConfigState? cs) =>
      cs == null ? null : ref.read(effectiveConfigProvider);

  /// True when the config's outbound(s) use xtls-rprx-vision — such outbounds
  /// reject UDP/443, so QUIC must be fast-failed on the TUN side.
  static bool _usesVisionFlow(VpnConfig config) {
    if (config.flow?.contains('vision') ?? false) return true;
    final raw = config.rawXrayConfig;
    if (raw == null) return false;
    try {
      final cfg = jsonDecode(raw) as Map<String, dynamic>;
      final outbounds = cfg['outbounds'] as List<dynamic>? ?? [];
      for (final o in outbounds.whereType<Map<String, dynamic>>()) {
        if (o['protocol'] != 'vless') continue;
        final vnext =
            (o['settings'] as Map<String, dynamic>?)?['vnext']
                as List<dynamic>? ??
            [];
        for (final v in vnext.whereType<Map<String, dynamic>>()) {
          final users = v['users'] as List<dynamic>? ?? [];
          for (final u in users.whereType<Map<String, dynamic>>()) {
            if ((u['flow'] as String?)?.contains('vision') ?? false) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  void cancelProbes() => _probes.cancel();

  Future<void> pingAllConfigs() async {
    if (_isPinging) return;
    final configState = ref
        .read(configProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    if (configState == null) return;
    _isPinging = true;
    try {
      await _pingEndpoints(configState.configs);
    } finally {
      _isPinging = false;
    }
  }

  Future<void> pingStaleConfigs() async {
    if (_isPinging) return;
    final configState = ref
        .read(configProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    if (configState == null) return;
    final now = DateTime.now();
    final stale = configState.configs.where((c) {
      if (c.lastPingedAt == null) return true;
      return now.difference(c.lastPingedAt!) > const Duration(minutes: 10);
    }).toList();
    if (stale.isEmpty) return;
    _isPinging = true;
    try {
      await _pingEndpoints(stale);
    } finally {
      _isPinging = false;
    }
  }

  Future<void> _pingEndpoints(List<VpnConfig> configs) async {
    final now = DateTime.now();
    final jobs = {
      for (final c in configs)
        if (c.rawXrayConfig == null &&
            c.protocol != VpnProtocol.hysteria2 &&
            c.transport != VpnTransport.quic)
          c.connectionIdentity: c,
    };
    await ref
        .read(configProvider.notifier)
        .markProbes(jobs.keys.toSet(), ProbeStatus.running, now);
    final results = await _probes.run(jobs, _engine.pingConfig);
    if (results != null && ref.mounted) {
      await ref
          .read(configProvider.notifier)
          .batchUpdatePingResults(results, now);
    } else if (ref.mounted) {
      await ref
          .read(configProvider.notifier)
          .markProbes(jobs.keys.toSet(), ProbeStatus.cancelled, now);
    }
  }

  VpnEngineOptions _options(
    VpnConfig config,
    AppSettings settings,
    ({String user, String password}) socksCredentials,
    int actualSocksPort,
  ) {
    return VpnEngineOptions(
      socksPort: actualSocksPort,
      httpPort: 0,
      socksUser: socksCredentials.user,
      socksPassword: socksCredentials.password,
      excludedPackages: settings.splitTunnelingEnabled
          ? (settings.vpnMode == VpnMode.allExcept
                ? settings.excludedPackages
                : <String>{})
          : {},
      includedPackages: settings.splitTunnelingEnabled
          ? (settings.vpnMode == VpnMode.onlySelected
                ? settings.includedPackages
                : <String>{})
          : {},
      logLevel: settings.logLevel,
      enableUdp: settings.enableUdp,
      allowIcmp: settings.allowIcmp,
      dnsMode: settings.dnsMode,
      dnsServer: settings.dnsServer,
      vpnMode: settings.splitTunnelingEnabled
          ? settings.vpnMode
          : VpnMode.allExcept,
      proxyOnly: settings.proxyOnly,
      showNotification: settings.showNotification,
      killSwitch: settings.killSwitchEnabled,
      routing: settings.routing,
      sniffingEnabled: settings.sniffingEnabled,
      mtu: settings.mtu,
      dnsQueryStrategy: settings.dnsQueryStrategy,
      // XTLS Vision rejects UDP/443 by design: QUIC can never pass, but browsers
      // keep retrying it (each retry costs a full outbound handshake) and stall
      // for ~30s before falling back to TCP. Force the ICMP fast-fail.
      blockQuic: settings.blockQuic || _usesVisionFlow(config),
      ipv6Enabled: settings.ipv6Enabled,
      obsProbeIntervalSec: settings.obsProbeIntervalSec,
      tlsFingerprint: settings.tlsFingerprint,
    );
  }

  Future<String?> getLogFilePath() => _engine.getLogFilePath();

  /// Dumps a tun2socks diagnostics snapshot into the app log.
  Future<void> dumpTunnelDiag() async {
    final diag = await _engine.getTunnelDiag();
    ref
        .read(logServiceProvider.notifier)
        .addInfo(
          diag.isEmpty ? 'tunnel diag: not running' : 'tunnel diag: $diag',
          source: 'diag',
        );
  }

  Future<void> clearNativeLogs() => _engine.clearLogs();

  VpnState get connectionState => state.connectionState;
}

final vpnProvider = NotifierProvider<VpnNotifier, VpnState2>(VpnNotifier.new);

// Convenience selector for connection state
final vpnConnectionStateProvider = Provider<VpnState>((ref) {
  return ref.watch(vpnProvider.select((s) => s.connectionState));
});

// Convenience selector for stats
final vpnStatsProvider = Provider<VpnStats>((ref) {
  return ref.watch(vpnProvider.select((s) => s.stats));
});

/// true — настройки соединения изменены после подключения,
/// для применения нужен reconnect.
final pendingReconnectProvider = Provider<bool>((ref) {
  final vpn = ref.watch(vpnProvider);
  if (!vpn.isConnected || vpn.appliedFingerprint == null) return false;
  final s = ref
      .watch(settingsProvider)
      .maybeWhen(data: (d) => d, orElse: () => null);
  if (s == null) return false;
  return connectionFingerprint(s) != vpn.appliedFingerprint;
});
