import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/app_info_provider.dart';
import '../../providers/update_provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/dns_config.dart';
import '../../core/services/update_service.dart' show UpdateChannel, UpdateInfo;
import '../../core/services/settings_service.dart';
import 'routing_screen.dart';
import 'profiles_screen.dart';
import 'dns_settings_screen.dart';
import '../../providers/settings_provider.dart';
import '../../providers/vpn_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/profile_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/settings_shared.dart';
import 'split_tunnel_screen.dart';

// ── Screen ────────────────────────────────────────────────────────

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _xrayVersion = '';

  @override
  void initState() {
    super.initState();
    _loadBinaryVersions();
  }

  Future<void> _loadBinaryVersions() async {
    try {
      const channel = MethodChannel(AppConstants.methodChannel);
      final result = await channel.invokeMethod<Map>('getBinaryVersions');
      if (result != null && mounted) {
        setState(() {
          _xrayVersion = result['xray'] ?? '—';
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _xrayVersion = '—';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final vpnState = ref.watch(vpnProvider);
    final profileState = ref
        .watch(profileProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    final version = ref
        .watch(appVersionProvider)
        .maybeWhen(data: (v) => v, orElse: () => 'v?');
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final vpnLocked = vpnState.isConnected || vpnState.isConnecting;
    final profileReadonly = profileState?.isReadonly ?? false;
    final locked = vpnLocked || profileReadonly;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _SetHeaderStrip(t: t, locked: locked),
            _SetHeroPanel(
              t: t,
              locked: locked,
              profileName: profileState?.activeProfile?.name ?? 'default',
              profileReadonly: profileReadonly,
            ),
            Expanded(
              child: settingsAsync.when(
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: t.accent,
                    strokeWidth: 1.5,
                  ),
                ),
                error: (e, _) => Center(
                  child: Text(
                    'Ошибка: $e',
                    style: AppTheme.mono(size: 12, color: t.danger),
                  ),
                ),
                data: (settings) => _SettingsBody(
                  settings: settings,
                  isConnected: vpnLocked,
                  isProfileReadonly: profileReadonly,
                  version: version,
                  xrayVersion: _xrayVersion,
                  onUpdate: (s) => ref.read(settingsProvider.notifier).save(s),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Console header strip ──────────────────────────────────────────

class _SetHeaderStrip extends StatelessWidget {
  final TeapodTokens t;
  final bool locked;
  const _SetHeaderStrip({required this.t, required this.locked});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'teapod.stream // config',
            style: AppTheme.mono(
              size: 10,
              color: t.textMuted,
              letterSpacing: 1,
            ),
          ),
          Text(
            'sys.state [${locked ? 'locked' : 'open'}]',
            style: AppTheme.mono(
              size: 10,
              color: t.textMuted,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Hero panel ────────────────────────────────────────────────────

class _SetHeroPanel extends StatelessWidget {
  final TeapodTokens t;
  final bool locked;
  final String profileName;
  final bool profileReadonly;
  const _SetHeroPanel({
    required this.t,
    required this.locked,
    required this.profileName,
    required this.profileReadonly,
  });

  static const Color _gold = AppColors.accentGold;

  @override
  Widget build(BuildContext context) {
    final wordColor = locked ? _gold : t.text;
    final lockColor = locked ? _gold : t.textDim;
    final borderColor = locked ? _gold : t.line;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.line)),
      ),
      child: Stack(
        children: [
          SetCornerTicks(t: t, color: locked ? _gold : t.textMuted),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ПАРАМЕТРЫ · ЛОКАЛЬНЫЙ ПРОФИЛЬ',
                        style: AppTheme.mono(
                          size: 10,
                          color: t.textMuted,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        locked ? 'LOCKED' : 'CONFIG',
                        style: AppTheme.sans(
                          size: 30,
                          weight: FontWeight.w500,
                          color: wordColor,
                          letterSpacing: -1,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        locked
                            ? (profileReadonly
                                  ? 'профиль заблокирован · только чтение'
                                  : 'отключите VPN чтобы изменить параметры')
                            : 'профиль: $profileName · автосохранение',
                        style: AppTheme.mono(
                          size: 11,
                          color: t.textDim,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Lock indicator
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    border: Border.all(color: borderColor),
                  ),
                  child: Stack(
                    children: [
                      if (locked) ...[
                        Positioned(
                          top: -1,
                          left: -1,
                          child: _LockCorner(color: _gold, isTop: true),
                        ),
                        Positioned(
                          bottom: -1,
                          right: -1,
                          child: _LockCorner(color: _gold, isTop: false),
                        ),
                      ],
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _LockIcon(color: lockColor, open: !locked),
                            const SizedBox(height: 2),
                            Text(
                              locked ? 'ro' : 'rw',
                              style: AppTheme.mono(
                                size: 8,
                                color: lockColor,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LockCorner extends StatelessWidget {
  final Color color;
  final bool isTop;
  const _LockCorner({required this.color, required this.isTop});

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(5, 5),
    painter: _LockCornerPainter(color: color, isTop: isTop),
  );
}

class _LockCornerPainter extends CustomPainter {
  final Color color;
  final bool isTop;
  const _LockCornerPainter({required this.color, required this.isTop});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    if (isTop) {
      canvas.drawLine(Offset.zero, Offset(size.width, 0), p);
      canvas.drawLine(Offset.zero, Offset(0, size.height), p);
    } else {
      canvas.drawLine(
        Offset(0, size.height),
        Offset(size.width, size.height),
        p,
      );
      canvas.drawLine(
        Offset(size.width, 0),
        Offset(size.width, size.height),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_LockCornerPainter old) => old.color != color;
}

class _LockIcon extends StatelessWidget {
  final Color color;
  final bool open;
  const _LockIcon({required this.color, required this.open});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(20, 20), painter: _LockPainter(color, open));
}

class _LockPainter extends CustomPainter {
  final Color color;
  final bool open;
  const _LockPainter(this.color, this.open);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final s = size.width / 24.0;
    canvas.scale(s, s);
    // Body
    final body = RRect.fromLTRBR(4, 11, 20, 21, const Radius.circular(1));
    canvas.drawRRect(body, p);
    // Shackle
    if (open) {
      final path = Path()
        ..moveTo(8, 11)
        ..lineTo(8, 7)
        ..arcToPoint(const Offset(16, 7), radius: const Radius.circular(4))
        ..lineTo(16, 11);
      canvas.drawPath(path, p);
    } else {
      final path = Path()
        ..moveTo(8, 11)
        ..lineTo(8, 7)
        ..arcToPoint(const Offset(16, 7), radius: const Radius.circular(4))
        ..lineTo(16, 11);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_LockPainter old) =>
      old.color != color || old.open != open;
}

// ── Settings body ─────────────────────────────────────────────────

class _SettingsBody extends StatefulWidget {
  final AppSettings settings;
  final bool isConnected;
  final bool isProfileReadonly;
  final String version;
  final String xrayVersion;
  final void Function(AppSettings) onUpdate;

  const _SettingsBody({
    required this.settings,
    required this.isConnected,
    required this.isProfileReadonly,
    required this.version,
    required this.xrayVersion,
    required this.onUpdate,
  });

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  late final TextEditingController _socksPortCtrl;
  late final TextEditingController _socksUserCtrl;
  late final TextEditingController _socksPasswordCtrl;
  late final TextEditingController _mtuCtrl;

  @override
  void initState() {
    super.initState();
    _socksPortCtrl = TextEditingController(
      text: widget.settings.socksPort.toString(),
    );
    _socksUserCtrl = TextEditingController(text: widget.settings.socksUser);
    _socksPasswordCtrl = TextEditingController(
      text: widget.settings.socksPassword,
    );
    _mtuCtrl = TextEditingController(text: widget.settings.mtu.toString());
  }

  @override
  void dispose() {
    _socksPortCtrl.dispose();
    _socksUserCtrl.dispose();
    _socksPasswordCtrl.dispose();
    _mtuCtrl.dispose();
    super.dispose();
  }

  void _updatePorts() {
    final socks = int.tryParse(_socksPortCtrl.text);
    if (socks != null) {
      widget.onUpdate(
        widget.settings.copyWith(socksPort: socks.clamp(1024, 65535)),
      );
    }
  }

  void _updateCredentials() {
    widget.onUpdate(
      widget.settings.copyWith(
        socksUser: _socksUserCtrl.text,
        socksPassword: _socksPasswordCtrl.text,
      ),
    );
  }

  void _updateMtu() {
    final mtu = int.tryParse(_mtuCtrl.text);
    if (mtu != null) {
      widget.onUpdate(widget.settings.copyWith(mtu: mtu.clamp(576, 9000)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final s = widget.settings;
    final locked = widget.isConnected || widget.isProfileReadonly;

    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.zero,
          children: [
            // ── 0x10 APPEARANCE ───────────────────────────────────
            SetSectionHeader(t: t, addr: '0x10', label: 'appearance'),
            _AppearanceRows(t: t),

            // ── 0x15 PROFILES ─────────────────────────────────────
            SetSectionHeader(t: t, addr: '0x15', label: 'profiles'),
            _ProfilesRow(t: t),

            // ── 0x20 CONNECTION ───────────────────────────────────
            SetSectionHeader(t: t, addr: '0x20', label: 'connection'),
            _RowToggle(
              t: t,
              title: 'Автоподключение',
              hint: 'Подключаться при запуске приложения',
              value: s.autoConnect,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(autoConnect: v)),
            ),
            _RowToggle(
              t: t,
              title: 'Уведомление',
              hint: 'Скорость и кнопка отключения в шторке',
              value: s.showNotification,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(showNotification: v)),
            ),
            _RowToggle(
              t: t,
              title: 'Kill Switch',
              hint: 'Блокировать трафик при обрыве VPN',
              value: s.killSwitchEnabled,
              locked: locked,
              onChange: (v) =>
                  widget.onUpdate(s.copyWith(killSwitchEnabled: v)),
            ),
            _RowToggle(
              t: t,
              title: 'HWID',
              hint: 'Отправлять ID устройства для привязки подписки',
              value: s.hwidEnabled,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(hwidEnabled: v)),
            ),
            _RowToggle(
              t: t,
              title: 'Автообновление подписок',
              hint: 'Обновлять подписки по расписанию',
              value: s.subAutoRefresh,
              locked: locked,
              last: !s.subAutoRefresh,
              onChange: (v) => widget.onUpdate(s.copyWith(subAutoRefresh: v)),
            ),
            if (s.subAutoRefresh)
              _InlineField(
                t: t,
                label: 'Интервал',
                child: _SegSquare(
                  t: t,
                  value: s.subAutoRefreshHours.toString(),
                  opts: const [
                    ('1', '1ч'),
                    ('3', '3ч'),
                    ('6', '6ч'),
                    ('12', '12ч'),
                    ('24', '24ч'),
                  ],
                  locked: locked,
                  onChanged: (v) => widget.onUpdate(
                    s.copyWith(subAutoRefreshHours: int.parse(v)),
                  ),
                ),
              ),

            // ── 0x30 XRAY ─────────────────────────────────────────
            SetSectionHeader(t: t, addr: '0x30', label: 'xray'),
            _RowToggle(
              t: t,
              title: 'Случайный порт',
              hint: 'Случайный SOCKS порт при каждом подключении',
              value: s.randomPort,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(randomPort: v)),
            ),
            if (!s.randomPort)
              _InlineField(
                t: t,
                label: 'SOCKS5 порт',
                child: SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _socksPortCtrl,
                    enabled: !locked,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => _updatePorts(),
                    onEditingComplete: () => FocusScope.of(context).unfocus(),
                    style: AppTheme.mono(size: 13, color: t.text),
                    decoration: InputDecoration(
                      hintText: '10808',
                      hintStyle: AppTheme.mono(size: 12, color: t.textMuted),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      isDense: true,
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.line),
                        borderRadius: BorderRadius.zero,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.accent),
                        borderRadius: BorderRadius.zero,
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.lineSoft),
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                  ),
                ),
              ),
            _RowToggle(
              t: t,
              title: 'Случайные учётные данные',
              hint: 'Генерировать случайный логин/пароль SOCKS',
              value: s.randomCredentials,
              locked: locked,
              onChange: (v) =>
                  widget.onUpdate(s.copyWith(randomCredentials: v)),
            ),
            if (!s.randomCredentials) ...[
              _InlineField(
                t: t,
                label: 'Логин SOCKS',
                child: _CredField(
                  controller: _socksUserCtrl,
                  enabled: !locked,
                  hint: 'без пароля',
                  onChanged: (_) => _updateCredentials(),
                  t: t,
                ),
              ),
              _InlineField(
                t: t,
                label: 'Пароль SOCKS',
                child: _CredField(
                  controller: _socksPasswordCtrl,
                  enabled: !locked,
                  hint: 'без пароля',
                  obscureText: true,
                  onChanged: (_) => _updateCredentials(),
                  t: t,
                ),
              ),
            ],
            _RowToggle(
              t: t,
              title: 'Только прокси',
              hint: 'Запустить SOCKS прокси без VPN-туннеля',
              value: s.proxyOnly,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(proxyOnly: v)),
            ),
            _RowToggle(
              t: t,
              title: 'UDP',
              hint: 'Разрешить UDP-трафик через SOCKS',
              value: s.enableUdp,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(enableUdp: v)),
            ),
            _RowToggle(
              t: t,
              title: 'ICMP (ping)',
              hint: 'Разрешить ping-запросы через туннель',
              value: s.allowIcmp,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(allowIcmp: v)),
            ),
            _RowToggle(
              t: t,
              title: 'Блокировать QUIC',
              hint:
                  'Блокирует UDP 443, чтобы браузер использовал TCP вместо HTTP/3. Устраняет зависания Google после простоя.',
              value: s.blockQuic,
              locked: locked,
              onChange: (v) => widget.onUpdate(s.copyWith(blockQuic: v)),
            ),
            if (!s.proxyOnly)
              _InlineField(
                t: t,
                label: 'MTU',
                child: SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _mtuCtrl,
                    enabled: !locked,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => _updateMtu(),
                    onEditingComplete: () => FocusScope.of(context).unfocus(),
                    style: AppTheme.mono(size: 13, color: t.text),
                    decoration: InputDecoration(
                      hintText: '1500',
                      hintStyle: AppTheme.mono(size: 12, color: t.textMuted),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      isDense: true,
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.line),
                        borderRadius: BorderRadius.zero,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.accent),
                        borderRadius: BorderRadius.zero,
                      ),
                      disabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: t.lineSoft),
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                  ),
                ),
              ),
            // DNS mode inline selector
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.lineSoft)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Режим DNS',
                        style: AppTheme.sans(size: 14, color: t.text),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        s.dnsMode == DnsMode.proxy
                            ? 'через VPN-туннель'
                            : 'напрямую',
                        style: AppTheme.mono(
                          size: 10,
                          color: t.textMuted,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  _SegSquare(
                    t: t,
                    value: s.dnsMode == DnsMode.proxy ? 'proxy' : 'direct',
                    opts: const [('proxy', 'VPN'), ('direct', 'DIRECT')],
                    locked: locked,
                    onChanged: (v) => widget.onUpdate(
                      s.copyWith(
                        dnsMode: v == 'proxy' ? DnsMode.proxy : DnsMode.direct,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // DNS query strategy (IPv4 / IPv6 / Auto)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.lineSoft)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DNS стратегия',
                        style: AppTheme.sans(size: 14, color: t.text),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'IP-версия для DNS-запросов',
                        style: AppTheme.mono(
                          size: 10,
                          color: t.textMuted,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                  _SegSquare(
                    t: t,
                    value: s.dnsQueryStrategy.name,
                    opts: const [
                      ('ipv4Only', 'IPv4'),
                      ('ipv6Only', 'IPv6'),
                      ('auto', 'AUTO'),
                    ],
                    locked: locked,
                    onChanged: (v) => widget.onUpdate(
                      s.copyWith(
                        dnsQueryStrategy: DnsQueryStrategy.values.firstWhere(
                          (e) => e.name == v,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _RowChev(
              t: t,
              title: 'DNS сервер',
              hint: _dnsLabel(s),
              locked: locked,
              last: true,
              onTap: locked
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DnsSettingsScreen(),
                      ),
                    ),
            ),

            // ── 0x40 ROUTING ──────────────────────────────────────
            SetSectionHeader(t: t, addr: '0x40', label: 'routing'),
            _RowChev(
              t: t,
              title: 'Маршрутизация трафика',
              hint: s.routing.summary,
              locked: locked,
              onTap: locked
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const RoutingScreen()),
                    ),
            ),
            _RowToggle(
              t: t,
              title: 'Сплит-туннелирование',
              hint: s.vpnMode == VpnMode.onlySelected
                  ? 'Только выбранные приложения через VPN'
                  : 'Выбранные приложения исключены из VPN',
              value: s.splitTunnelingEnabled,
              locked: locked,
              onChange: (v) =>
                  widget.onUpdate(s.copyWith(splitTunnelingEnabled: v)),
            ),
            if (s.splitTunnelingEnabled)
              _RowChev(
                t: t,
                title: 'Выбрать приложения',
                hint: s.vpnMode == VpnMode.onlySelected
                    ? '${s.includedPackages.length} выбрано'
                    : '${s.excludedPackages.length} исключено',
                locked: locked,
                last: true,
                onTap: locked
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SplitTunnelScreen(),
                        ),
                      ),
              )
            else
              SizedBox(height: 1, child: Container(color: t.line)),

            // ── 0x50 ABOUT ────────────────────────────────────────
            SetSectionHeader(t: t, addr: '0x50', label: 'about'),
            _KVRow(
              t: t,
              k: 'version',
              v: widget.version.isEmpty ? '...' : widget.version,
            ),
            _KVRow(
              t: t,
              k: 'xray.core',
              v: widget.xrayVersion.isEmpty ? '...' : widget.xrayVersion,
            ),
            _KVRowTap(
              t: t,
              k: 'source',
              v: 'github.com/Wendor/teapod-stream',
              onTap: () async {
                final uri = Uri.parse(
                  'https://github.com/Wendor/teapod-stream',
                );
                if (await canLaunchUrl(uri))
                  launchUrl(uri, mode: LaunchMode.externalApplication);
              },
            ),
            // Update channel
            _InlineField(
              t: t,
              label: 'Канал обновлений',
              child: const _UpdateChannelSegment(),
            ),
            // Update tile (complex)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.line)),
              ),
              child: const _UpdateTile(),
            ),
            const SizedBox(height: 32),
          ],
        ),
        if (locked)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(color: t.bg.withValues(alpha: 0)),
            ),
          ),
      ],
    );
  }
}

// ── Row: toggle ───────────────────────────────────────────────────

class _RowToggle extends StatelessWidget {
  final TeapodTokens t;
  final String title;
  final String? hint;
  final bool value;
  final bool locked;
  final bool last;
  final void Function(bool) onChange;

  const _RowToggle({
    required this.t,
    required this.title,
    required this.value,
    required this.locked,
    required this.onChange,
    this.hint,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: last ? t.line : t.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTheme.sans(size: 14, color: t.text)),
                if (hint != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    hint!,
                    style: AppTheme.mono(
                      size: 10,
                      color: t.textMuted,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 14),
          _SquareSwitch(
            t: t,
            value: value,
            onChanged: locked ? null : (v) => onChange(v),
          ),
        ],
      ),
    );
  }
}

// ── Square switch ─────────────────────────────────────────────────

class _SquareSwitch extends StatelessWidget {
  final TeapodTokens t;
  final bool value;
  final void Function(bool)? onChanged;

  const _SquareSwitch({required this.t, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 44,
        height: 22,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(color: value ? t.accent : t.line),
          color: value ? t.accentSoft : Colors.transparent,
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 14,
            height: 14,
            color: value ? t.accent : t.textMuted,
          ),
        ),
      ),
    );
  }
}

// ── Row: chevron ──────────────────────────────────────────────────

class _RowChev extends StatelessWidget {
  final TeapodTokens t;
  final String title;
  final String? hint;
  final bool locked;
  final bool last;
  final VoidCallback? onTap;

  const _RowChev({
    required this.t,
    required this.title,
    required this.locked,
    this.hint,
    this.last = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: last ? t.line : t.lineSoft)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTheme.sans(size: 14, color: t.text)),
                  if (hint != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      hint!,
                      style: AppTheme.mono(
                        size: 10,
                        color: t.textMuted,
                        letterSpacing: 0.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('›', style: AppTheme.mono(size: 16, color: t.textMuted)),
          ],
        ),
      ),
    );
  }
}

// ── Row: inline field ─────────────────────────────────────────────

class _InlineField extends StatelessWidget {
  final TeapodTokens t;
  final String label;
  final Widget child;
  const _InlineField({
    required this.t,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTheme.sans(size: 14, color: t.text)),
          child,
        ],
      ),
    );
  }
}

// ── Cred text field ───────────────────────────────────────────────

class _CredField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final bool obscureText;
  final void Function(String) onChanged;
  final TeapodTokens t;

  const _CredField({
    required this.controller,
    required this.enabled,
    required this.hint,
    required this.onChanged,
    required this.t,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: obscureText,
        textAlign: TextAlign.end,
        onChanged: onChanged,
        onEditingComplete: () => FocusScope.of(context).unfocus(),
        style: AppTheme.mono(size: 12, color: t.text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AppTheme.mono(size: 11, color: t.textMuted),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 6,
          ),
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: t.line),
            borderRadius: BorderRadius.zero,
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: t.accent),
            borderRadius: BorderRadius.zero,
          ),
          disabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: t.lineSoft),
            borderRadius: BorderRadius.zero,
          ),
        ),
      ),
    );
  }
}

// ── Row: KV ───────────────────────────────────────────────────────

class _KVRow extends StatelessWidget {
  final TeapodTokens t;
  final String k;
  final String v;
  const _KVRow({required this.t, required this.k, required this.v});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k.toUpperCase(),
            style: AppTheme.mono(
              size: 10,
              color: t.textMuted,
              letterSpacing: 1,
            ),
          ),
          Text(v, style: AppTheme.mono(size: 11, color: t.text)),
        ],
      ),
    );
  }
}

class _KVRowTap extends StatelessWidget {
  final TeapodTokens t;
  final String k;
  final String v;
  final VoidCallback? onTap;
  const _KVRowTap({
    required this.t,
    required this.k,
    required this.v,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.lineSoft)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              k.toUpperCase(),
              style: AppTheme.mono(
                size: 10,
                color: t.textMuted,
                letterSpacing: 1,
              ),
            ),
            Row(
              children: [
                Text(v, style: AppTheme.mono(size: 11, color: t.accent)),
                const SizedBox(width: 6),
                Text('›', style: AppTheme.mono(size: 14, color: t.textMuted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Segmented square selector ─────────────────────────────────────

class _SegSquare extends StatelessWidget {
  final TeapodTokens t;
  final String value;
  final List<(String, String)> opts;
  final bool locked;
  final void Function(String) onChanged;

  const _SegSquare({
    required this.t,
    required this.value,
    required this.opts,
    required this.locked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: t.line)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: opts.asMap().entries.map((e) {
          final idx = e.key;
          final (val, lab) = e.value;
          final active = value == val;
          return GestureDetector(
            onTap: locked ? null : () => onChanged(val),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: active ? t.accentSoft : Colors.transparent,
                border: Border(
                  right: idx < opts.length - 1
                      ? BorderSide(color: t.line)
                      : BorderSide.none,
                ),
              ),
              child: Text(
                lab,
                style: AppTheme.mono(
                  size: 11,
                  color: active ? t.accent : t.textDim,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Update channel segment ────────────────────────────────────────

class _UpdateChannelSegment extends ConsumerWidget {
  const _UpdateChannelSegment();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final settings = ref
        .watch(settingsProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    if (settings == null) return const SizedBox.shrink();
    return _SegSquare(
      t: t,
      value: settings.updateChannel == UpdateChannel.stable ? 'stable' : 'beta',
      opts: const [('stable', 'STABLE'), ('beta', 'BETA')],
      locked: false,
      onChanged: (v) async {
        final ch = v == 'stable' ? UpdateChannel.stable : UpdateChannel.beta;
        await ref
            .read(settingsProvider.notifier)
            .save(settings.copyWith(updateChannel: ch));
        ref.read(updateProvider.notifier).checkForUpdate();
      },
    );
  }
}

// ── Appearance rows ───────────────────────────────────────────────

class _AppearanceRows extends ConsumerWidget {
  final TeapodTokens t;
  const _AppearanceRows({required this.t});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final accent = ref.watch(accentProvider);
    final settings = ref
        .watch(settingsProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);

    return Column(
      children: [
        // Theme
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.lineSoft)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Тема', style: AppTheme.sans(size: 14, color: t.text)),
              _SegSquare(
                t: t,
                value: themeMode == ThemeMode.dark
                    ? 'dark'
                    : themeMode == ThemeMode.light
                    ? 'light'
                    : 'system',
                opts: const [
                  ('dark', 'ТЁМНАЯ'),
                  ('light', 'СВЕТЛАЯ'),
                  ('system', 'СИСТЕМА'),
                ],
                locked: false,
                onChanged: (v) {
                  final m = v == 'dark'
                      ? ThemeMode.dark
                      : v == 'light'
                      ? ThemeMode.light
                      : ThemeMode.system;
                  ref.read(themeModeProvider.notifier).set(m);
                },
              ),
            ],
          ),
        ),
        // Font scale
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.lineSoft)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Размер шрифта',
                style: AppTheme.sans(size: 14, color: t.text),
              ),
              if (settings != null)
                _SegSquare(
                  t: t,
                  value: settings.fontScale == FontScale.large
                      ? 'large'
                      : 'normal',
                  opts: const [('normal', 'ОБЫЧНЫЙ'), ('large', 'КРУПНЫЙ')],
                  locked: false,
                  onChanged: (v) {
                    final scale = v == 'large'
                        ? FontScale.large
                        : FontScale.normal;
                    ref
                        .read(settingsProvider.notifier)
                        .save(settings.copyWith(fontScale: scale));
                  },
                ),
            ],
          ),
        ),
        // Accent
        Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: t.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'АКЦЕНТНЫЙ ЦВЕТ',
                style: AppTheme.mono(
                  size: 10,
                  color: t.textMuted,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: AppColors.accentPresets.map((c) {
                  final selected = accent.toARGB32() == c.toARGB32();
                  return GestureDetector(
                    onTap: () => ref.read(accentProvider.notifier).set(c),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: c,
                        border: Border.all(
                          color: selected ? t.text : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? Center(
                              child: Container(
                                width: 10,
                                height: 10,
                                color: t.bg,
                              ),
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Text(
                '#${accent.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                style: AppTheme.mono(
                  size: 11,
                  color: t.textDim,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Update tile ───────────────────────────────────────────────────

class _UpdateTile extends ConsumerWidget {
  const _UpdateTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final updateState = ref.watch(updateProvider);
    return switch (updateState) {
      UpdateIdle() => _UpdateRow(
        t: t,
        label: 'Обновления',
        action: _SqBtn(
          t: t,
          label: 'ПРОВЕРИТЬ',
          onTap: () => ref.read(updateProvider.notifier).checkForUpdate(),
        ),
      ),
      UpdateChecking() => _UpdateRow(
        t: t,
        label: 'Проверка...',
        labelColor: t.textDim,
        action: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: t.accent),
        ),
      ),
      UpdateUpToDate(:final info) => _UpdateVersionTile(
        info: info,
        isUpdate: false,
      ),
      UpdateAvailable(:final info, :final resumableBytes) => _UpdateVersionTile(
        info: info,
        isUpdate: true,
        resumableBytes: resumableBytes,
      ),
      UpdateDownloading(:final info, :final downloaded, :final total) =>
        Container(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Скачивается v${info.version}',
                    style: AppTheme.sans(size: 14, color: t.text),
                  ),
                  GestureDetector(
                    onTap: () =>
                        ref.read(updateProvider.notifier).cancelDownload(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: t.line),
                      ),
                      child: Text(
                        'ОТМЕНА',
                        style: AppTheme.mono(
                          size: 10,
                          color: t.textDim,
                          letterSpacing: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: total > 0 ? downloaded / total : null,
                backgroundColor: t.line,
                color: t.accent,
                minHeight: 2,
              ),
              const SizedBox(height: 4),
              Text(
                total > 0
                    ? '${(downloaded / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} МБ'
                    : '${(downloaded / 1024 / 1024).toStringAsFixed(1)} МБ',
                style: AppTheme.mono(size: 10, color: t.textDim),
              ),
            ],
          ),
        ),
      UpdateDownloaded(:final info, :final filePath) => _UpdateRow(
        t: t,
        label: 'v${info.version} готова к установке',
        action: _SqBtn(
          t: t,
          label: 'УСТАНОВИТЬ',
          filled: true,
          onTap: () => ref.read(updateProvider.notifier).installApk(filePath),
        ),
      ),
      UpdateError(:final message, :final retryInfo) => _UpdateRow(
        t: t,
        label: message,
        labelColor: t.danger,
        action: _SqBtn(
          t: t,
          label: 'ПОВТОР',
          onTap: retryInfo != null
              ? () => ref.read(updateProvider.notifier).startDownload(retryInfo)
              : () => ref.read(updateProvider.notifier).checkForUpdate(),
        ),
      ),
    };
  }
}

class _UpdateRow extends StatelessWidget {
  final TeapodTokens t;
  final String label;
  final Color? labelColor;
  final Widget action;
  const _UpdateRow({
    required this.t,
    required this.label,
    required this.action,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: AppTheme.sans(size: 14, color: labelColor ?? t.text),
            ),
          ),
          const SizedBox(width: 12),
          action,
        ],
      ),
    );
  }
}

class _SqBtn extends StatelessWidget {
  final TeapodTokens t;
  final String label;
  final bool filled;
  final VoidCallback? onTap;
  const _SqBtn({
    required this.t,
    required this.label,
    this.filled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: filled ? t.accent : null,
        decoration: filled
            ? null
            : BoxDecoration(border: Border.all(color: t.line)),
        child: Text(
          label,
          style: AppTheme.mono(
            size: 10,
            color: filled ? t.bg : t.accent,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

class _UpdateVersionTile extends ConsumerWidget {
  final UpdateInfo info;
  final bool isUpdate;
  final int resumableBytes;
  const _UpdateVersionTile({
    required this.info,
    required this.isUpdate,
    this.resumableBytes = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final hasChangelog = info.changelog?.isNotEmpty ?? false;

    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: isUpdate ? t.accentSoft : Colors.transparent,
        border: Border.all(color: isUpdate ? t.accent : t.line),
      ),
      child: Text(
        'v${info.version}',
        style: AppTheme.mono(
          size: 10,
          color: isUpdate ? t.accent : t.textMuted,
          letterSpacing: 0.5,
        ),
      ),
    );

    final label = isUpdate ? 'доступно обновление' : 'актуальная версия';
    final btnLabel = isUpdate
        ? (resumableBytes > 0 ? 'ПРОДОЛЖИТЬ' : 'СКАЧАТЬ')
        : 'ПЕРЕУСТАНОВИТЬ';
    final onTap = isUpdate
        ? () => ref.read(updateProvider.notifier).startDownload(info)
        : () => ref.read(updateProvider.notifier).reinstall(info);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              badge,
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: AppTheme.sans(
                    size: 14,
                    color: isUpdate ? t.text : t.textDim,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _SqBtn(t: t, label: btnLabel, filled: isUpdate, onTap: onTap),
            ],
          ),
          if (hasChangelog) ...[
            const SizedBox(height: 10),
            SelectableText(
              info.changelog!,
              style: AppTheme.mono(size: 11, color: t.textDim, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Profiles row ──────────────────────────────────────────────────

class _ProfilesRow extends ConsumerWidget {
  final TeapodTokens t;
  const _ProfilesRow({required this.t});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileState = ref
        .watch(profileProvider)
        .maybeWhen(data: (d) => d, orElse: () => null);
    final profile = profileState?.activeProfile;
    final hint = profile == null
        ? 'загрузка...'
        : '${profile.name}${profile.readonly ? ' · только чтение' : ''}';

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ProfilesScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Профили',
                    style: AppTheme.sans(size: 14, color: t.text),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    hint,
                    style: AppTheme.mono(
                      size: 10,
                      color: t.textMuted,
                      letterSpacing: 0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text('›', style: AppTheme.mono(size: 16, color: t.textMuted)),
          ],
        ),
      ),
    );
  }
}

// ── DNS settings screen (kept, uses Material AppBar) ──────────────

String _dnsLabel(AppSettings settings) {
  if (settings.dnsPreset == 'custom') return settings.customDnsAddress;
  return DnsServerConfig.presets.firstWhere(
        (p) => p['value'] == settings.dnsPreset,
        orElse: () => {'label': settings.dnsPreset},
      )['label'] ??
      settings.dnsPreset;
}
