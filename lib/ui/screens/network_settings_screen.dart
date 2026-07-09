import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/services/settings_service.dart';
import '../../providers/profile_provider.dart';
import '../../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/hero_panel.dart';
import '../widgets/reconnect_banner.dart';
import '../widgets/settings_shared.dart';

/// Экспертные сетевые настройки: SOCKS, TUN, TLS fingerprint, observatory.
class NetworkSettingsScreen extends ConsumerStatefulWidget {
  const NetworkSettingsScreen({super.key});

  @override
  ConsumerState<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends ConsumerState<NetworkSettingsScreen> {
  TextEditingController? _socksPortCtrl;
  TextEditingController? _socksUserCtrl;
  TextEditingController? _socksPasswordCtrl;
  TextEditingController? _mtuCtrl;
  TextEditingController? _obsCtrl;

  void _ensureControllers(AppSettings s) {
    _socksPortCtrl ??= TextEditingController(text: s.socksPort.toString());
    _socksUserCtrl ??= TextEditingController(text: s.socksUser);
    _socksPasswordCtrl ??= TextEditingController(text: s.socksPassword);
    _mtuCtrl ??= TextEditingController(text: s.mtu.toString());
    _obsCtrl ??= TextEditingController(text: s.obsProbeIntervalSec.toString());
  }

  @override
  void dispose() {
    _socksPortCtrl?.dispose();
    _socksUserCtrl?.dispose();
    _socksPasswordCtrl?.dispose();
    _mtuCtrl?.dispose();
    _obsCtrl?.dispose();
    super.dispose();
  }

  void _update(AppSettings s) => ref.read(settingsProvider.notifier).save(s);

  static String _fpLabel(TlsFingerprint fp) =>
      fp == TlsFingerprint.defaultFp ? 'DEFAULT' : fp.name.toUpperCase();

  void _showFingerprintPicker(BuildContext context, AppSettings s) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    showModalBottomSheet(
      context: context,
      backgroundColor: t.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(children: [
                Expanded(
                  child: Text('tls // fingerprint',
                      style: AppTheme.mono(size: 10, color: t.textMuted, letterSpacing: 1)),
                ),
              ]),
            ),
            Container(height: 1, color: t.line),
            for (final fp in TlsFingerprint.values)
              InkWell(
                onTap: () {
                  _update(s.copyWith(tlsFingerprint: fp));
                  Navigator.pop(ctx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_fpLabel(fp),
                            style: AppTheme.mono(
                                size: 12,
                                color: fp == s.tlsFingerprint ? t.accent : t.text,
                                letterSpacing: 0.5)),
                      ),
                      if (fp == s.tlsFingerprint)
                        Text('●', style: AppTheme.mono(size: 10, color: t.accent)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).extension<TeapodTokens>()!;
    final settingsAsync = ref.watch(settingsProvider);
    final profileState =
        ref.watch(profileProvider).maybeWhen(data: (d) => d, orElse: () => null);
    final locked = profileState?.isReadonly ?? false;

    return Scaffold(
      body: SafeArea(
        child: settingsAsync.when(
          loading: () => Center(
              child: CircularProgressIndicator(color: t.accent, strokeWidth: 1.5)),
          error: (e, _) => Center(
              child: Text('Ошибка: $e', style: AppTheme.mono(size: 12, color: t.danger))),
          data: (s) {
            _ensureControllers(s);
            return Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration:
                      BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('teapod.stream // network',
                          style: AppTheme.mono(size: 10, color: t.textMuted, letterSpacing: 1)),
                      Text('socks [${s.randomPort ? 'rnd' : s.socksPort}]',
                          style: AppTheme.mono(size: 10, color: t.textMuted, letterSpacing: 1)),
                    ],
                  ),
                ),
                BreadcrumbBar(t: t, parent: 'settings', current: 'network'),
                HeroPanel(
                  t: t,
                  tagline: 'СЕТЬ · SOCKS · TUN',
                  title: 'NETWORK',
                ),
                const ReconnectBanner(),
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      SetSectionHeader(t: t, addr: '0x31', label: 'socks'),
                      SetRowToggle(
                        t: t,
                        title: 'Случайный порт',
                        hint: 'Случайный SOCKS порт при каждом подключении',
                        value: s.randomPort,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(randomPort: v)),
                      ),
                      if (!s.randomPort)
                        SetInlineField(
                          t: t,
                          label: 'SOCKS5 порт',
                          locked: locked,
                          child: SetNumField(
                            t: t,
                            controller: _socksPortCtrl!,
                            enabled: !locked,
                            hint: '10808',
                            onChanged: (v) {
                              final socks = int.tryParse(v);
                              if (socks != null) {
                                _update(s.copyWith(socksPort: socks.clamp(1024, 65535)));
                              }
                            },
                          ),
                        ),
                      SetRowToggle(
                        t: t,
                        title: 'Случайные учётные данные',
                        hint: 'Генерировать случайный логин/пароль SOCKS',
                        value: s.randomCredentials,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(randomCredentials: v)),
                      ),
                      if (!s.randomCredentials) ...[
                        SetInlineField(
                          t: t,
                          label: 'Логин SOCKS',
                          locked: locked,
                          child: SetCredField(
                            controller: _socksUserCtrl!,
                            enabled: !locked,
                            hint: 'без пароля',
                            onChanged: (_) => _update(s.copyWith(
                              socksUser: _socksUserCtrl!.text,
                              socksPassword: _socksPasswordCtrl!.text,
                            )),
                            t: t,
                          ),
                        ),
                        SetInlineField(
                          t: t,
                          label: 'Пароль SOCKS',
                          locked: locked,
                          child: SetCredField(
                            controller: _socksPasswordCtrl!,
                            enabled: !locked,
                            hint: 'без пароля',
                            obscureText: true,
                            onChanged: (_) => _update(s.copyWith(
                              socksUser: _socksUserCtrl!.text,
                              socksPassword: _socksPasswordCtrl!.text,
                            )),
                            t: t,
                          ),
                        ),
                      ],
                      SetRowToggle(
                        t: t,
                        title: 'Только прокси',
                        hint: 'Запустить SOCKS прокси без VPN-туннеля',
                        value: s.proxyOnly,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(proxyOnly: v)),
                      ),
                      SetSectionHeader(t: t, addr: '0x32', label: 'traffic'),
                      SetRowToggle(
                        t: t,
                        title: 'UDP',
                        hint: 'Разрешить UDP-трафик через SOCKS',
                        value: s.enableUdp,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(enableUdp: v)),
                      ),
                      SetRowToggle(
                        t: t,
                        title: 'ICMP (ping)',
                        hint: 'Разрешить ping-запросы через туннель',
                        value: s.allowIcmp,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(allowIcmp: v)),
                      ),
                      SetRowToggle(
                        t: t,
                        title: 'Блокировать QUIC',
                        hint: 'TUN отвечает на UDP 443 ICMP-ом "порт недоступен": браузер мгновенно падает на TCP вместо ожидания QUIC-таймаута (~55с). Трафик из устройства не уходит.',
                        value: s.blockQuic,
                        locked: locked,
                        onChange: (v) => _update(s.copyWith(blockQuic: v)),
                      ),
                      // TLS fingerprint (uTLS) override
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                        decoration: BoxDecoration(
                            border: Border(bottom: BorderSide(color: t.lineSoft))),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('TLS fingerprint',
                                    style: AppTheme.sans(size: 14, color: t.text)),
                                const SizedBox(height: 3),
                                Text('uTLS-маскировка ClientHello (TLS/REALITY)',
                                    style: AppTheme.mono(
                                        size: 10, color: t.textMuted, letterSpacing: 0.5)),
                              ],
                            ),
                            GestureDetector(
                              onTap: locked
                                  ? () => showReadonlySnack(context)
                                  : () => _showFingerprintPicker(context, s),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration:
                                    BoxDecoration(border: Border.all(color: t.line)),
                                child: Text(_fpLabel(s.tlsFingerprint),
                                    style: AppTheme.mono(
                                        size: 11,
                                        color: locked ? t.textDim : t.accent,
                                        letterSpacing: 0.5)),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SetSectionHeader(t: t, addr: '0x33', label: 'tun'),
                      if (!s.proxyOnly)
                        SetRowToggle(
                          t: t,
                          title: 'IPv6 в туннеле',
                          hint: 'Добавить IPv6-адрес на TUN-интерфейс. Включайте только если VPN-сервер имеет IPv6: иначе приложения с IPv6-адресами (Telegram) зависают. При выключении IPv6 блокируется системой без утечек — приложения мгновенно переходят на IPv4.',
                          value: s.ipv6Enabled,
                          locked: locked,
                          onChange: (v) => _update(s.copyWith(ipv6Enabled: v)),
                        ),
                      if (!s.proxyOnly)
                        SetInlineField(
                          t: t,
                          label: 'MTU',
                          locked: locked,
                          child: SetNumField(
                            t: t,
                            controller: _mtuCtrl!,
                            enabled: !locked,
                            hint: '1500',
                            onChanged: (v) {
                              final mtu = int.tryParse(v);
                              if (mtu != null) {
                                _update(s.copyWith(mtu: mtu.clamp(576, 9000)));
                              }
                            },
                          ),
                        ),
                      SetInlineField(
                        t: t,
                        label: 'Observatory мин. интервал, сек',
                        locked: locked,
                        child: SetNumField(
                          t: t,
                          controller: _obsCtrl!,
                          enabled: !locked,
                          hint: '600',
                          onChanged: (v) {
                            final sec = int.tryParse(v);
                            if (sec != null) {
                              _update(s.copyWith(obsProbeIntervalSec: sec.clamp(0, 86400)));
                            }
                          },
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
