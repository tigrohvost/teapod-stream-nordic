# UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать UX-редизайн по спеке `docs/superpowers/specs/2026-07-09-ux-redesign-design.md`: вкладка Маршрутизация вместо Логов, редактирование настроек при подключённом VPN с баннером «переподключитесь», подэкран «Сеть», избранные конфиги, смена сервера с Home, полировка.

**Architecture:** Flutter + Riverpod (Notifier/AsyncNotifier). Новая логика: fingerprint настроек соединения в `VpnState2`, `pendingReconnectProvider`, пины `(subscriptionId?, name)` в `ConfigState`, нативное состояние `blocked` для kill switch. UI-паттерны проекта: console-стиль, `TeapodTokens`, mono/sans хелперы, `SetSectionHeader`, bottom sheets.

**Tech Stack:** Flutter 3.11+, Riverpod 3.3, Kotlin (XrayVpnService), SharedPreferences/EncryptedSharedPreferences.

## Global Constraints

- Строгая типизация, без `dynamic`/`any` без необходимости.
- Никаких `// ... остальной код` — полные реализации.
- Верификация: `flutter analyze` = 0 issues после каждой задачи; unit-тесты для чистой логики; финальная проверка на устройстве (НЕ переустанавливать приложение через adb без спроса — теряются данные).
- Тексты: статусы/console-заголовки EN, пояснения RU.
- Коммит после каждой задачи на ветке `teapod-ux`.
- После всего: обновить `wiki/components/ui_screens.md`, `wiki/index.md`, `wiki/log.md` (wiki в .gitignore — не коммитить).

---

### Task 1: Fingerprint настроек соединения + pendingReconnectProvider

**Files:**
- Create: `lib/core/models/connection_fingerprint.dart`
- Modify: `lib/providers/vpn_provider.dart`
- Test: `test/core/connection_fingerprint_test.dart`

**Interfaces:**
- Produces: `String connectionFingerprint(AppSettings s)`; `VpnState2.appliedFingerprint: String?`; `final pendingReconnectProvider = Provider<bool>`.

- [ ] **Step 1: Failing test**

```dart
// test/core/connection_fingerprint_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/connection_fingerprint.dart';
import 'package:teapodstream/core/services/settings_service.dart';

void main() {
  group('connectionFingerprint', () {
    test('идентичен для одинаковых настроек', () {
      expect(connectionFingerprint(const AppSettings()),
          connectionFingerprint(const AppSettings()));
    });
    test('меняется при изменении connection-полей', () {
      final base = const AppSettings();
      expect(connectionFingerprint(base.copyWith(mtu: 1400)),
          isNot(connectionFingerprint(base)));
      expect(connectionFingerprint(base.copyWith(killSwitchEnabled: true)),
          isNot(connectionFingerprint(base)));
      expect(connectionFingerprint(base.copyWith(splitTunnelingEnabled: true)),
          isNot(connectionFingerprint(base)));
    });
    test('не меняется от косметических полей', () {
      final base = const AppSettings();
      expect(connectionFingerprint(base.copyWith(fontScale: FontScale.large)),
          connectionFingerprint(base));
      expect(connectionFingerprint(base.copyWith(autoConnect: true)),
          connectionFingerprint(base));
      expect(connectionFingerprint(base.copyWith(subUserAgent: 'x')),
          connectionFingerprint(base));
    });
    test('возврат значения восстанавливает fingerprint', () {
      final base = const AppSettings();
      final changed = base.copyWith(enableUdp: !base.enableUdp);
      final reverted = changed.copyWith(enableUdp: base.enableUdp);
      expect(connectionFingerprint(reverted), connectionFingerprint(base));
    });
    test('set-поля не зависят от порядка', () {
      final a = const AppSettings().copyWith(excludedPackages: {'b', 'a'});
      final b = const AppSettings().copyWith(excludedPackages: {'a', 'b'});
      expect(connectionFingerprint(a), connectionFingerprint(b));
    });
  });
}
```

- [ ] **Step 2: Run** `flutter test test/core/connection_fingerprint_test.dart` — FAIL (нет файла).

- [ ] **Step 3: Реализация**

```dart
// lib/core/models/connection_fingerprint.dart
import 'dart:convert';
import '../services/settings_service.dart';

/// Детерминированный отпечаток настроек, влияющих на активное соединение.
/// Меняется -> нужен reconnect. Косметика (тема, шрифт, autoConnect,
/// параметры подписок, geo-URL) не входит.
String connectionFingerprint(AppSettings s) {
  final map = <String, Object?>{
    'socksPort': s.socksPort,
    'randomPort': s.randomPort,
    'randomCredentials': s.randomCredentials,
    'socksUser': s.socksUser,
    'socksPassword': s.socksPassword,
    'proxyOnly': s.proxyOnly,
    'enableUdp': s.enableUdp,
    'allowIcmp': s.allowIcmp,
    'blockQuic': s.blockQuic,
    'mtu': s.mtu,
    'ipv6Enabled': s.ipv6Enabled,
    'tlsFingerprint': s.tlsFingerprint.name,
    'obsProbeIntervalSec': s.obsProbeIntervalSec,
    'logLevel': s.logLevel.name,
    'sniffingEnabled': s.sniffingEnabled,
    'dnsMode': s.dnsMode.name,
    'dnsPreset': s.dnsPreset,
    'customDnsAddress': s.customDnsAddress,
    'customDnsType': s.customDnsType,
    'dnsQueryStrategy': s.dnsQueryStrategy.name,
    'routing': s.routing.toJson(),
    'splitTunnelingEnabled': s.splitTunnelingEnabled,
    'vpnMode': s.vpnMode.name,
    'includedPackages': s.includedPackages.toList()..sort(),
    'excludedPackages': s.excludedPackages.toList()..sort(),
    'killSwitchEnabled': s.killSwitchEnabled,
    'showNotification': s.showNotification,
  };
  return jsonEncode(map);
}
```

Проверить импорты: `DnsMode`/`LogLevel` могут жить в других файлах — поправить импорты по факту (`vpn_engine.dart`, `vpn_log_entry.dart`). `RoutingSettings.toJson()` существует (используется в persistence) — если метода нет, сериализовать ключевые поля вручную.

- [ ] **Step 4: Run** тест — PASS.

- [ ] **Step 5: VpnState2.appliedFingerprint + provider**

В `vpn_provider.dart`:
- Поле `final String? appliedFingerprint;` в `VpnState2`, в `copyWith` — `appliedFingerprint: appliedFingerprint ?? this.appliedFingerprint` (не сбрасывается копированием; сбрасывается только конструированием нового `VpnState2()` при disconnect/error — это уже происходит).
- В `connect()` после построения `options`: `state = state.copyWith(..., appliedFingerprint: connectionFingerprint(settings));` (добавить к существующему copyWith с портом/creds).
- В `build()` в `Future.microtask` при обнаружении уже работающего VPN: после установки connected-состояния — `final s = await ref.read(settingsProvider.future); state = state.copyWith(appliedFingerprint: connectionFingerprint(s));`
- Provider в конце файла:

```dart
/// true — настройки изменены после подключения, для применения нужен reconnect.
final pendingReconnectProvider = Provider<bool>((ref) {
  final vpn = ref.watch(vpnProvider);
  if (!vpn.isConnected || vpn.appliedFingerprint == null) return false;
  final s = ref.watch(settingsProvider).maybeWhen(data: (d) => d, orElse: () => null);
  if (s == null) return false;
  return connectionFingerprint(s) != vpn.appliedFingerprint;
});
```

- [ ] **Step 6:** `flutter analyze` — 0 issues; `flutter test` — pass.
- [ ] **Step 7: Commit** `feat: fingerprint настроек соединения + pendingReconnectProvider`

---

### Task 2: Состояние blocked (kill switch) — native + Flutter

**Files:**
- Modify: `android/app/src/main/kotlin/com/teapodstream/teapodstream/XrayVpnService.kt`
- Modify: `lib/core/interfaces/vpn_engine.dart` (enum), `lib/providers/vpn_provider.dart`

**Interfaces:**
- Produces: native state string `"blocked"`; `VpnState.blocked`; `VpnState2.isBlocked`.

- [ ] **Step 1: Native.** В `stopVpn` (`XrayVpnService.kt:923-933`, блок `finally`): если `keepTunAsSink && !reconnecting` → `setState("blocked")` вместо `setState(resultState)`. `keepTunAsSink` вычисляется внутри `try` — вынести в локальную переменную уровня метода (объявить до `try`).
- [ ] **Step 2: Native disconnect из blocked.** `stopVpn` идемпотентен через `isRunning.compareAndSet` — при повторном ACTION_DISCONNECT из состояния blocked он выйдет сразу и TUN-sink не закроется. В обработчике `ACTION_DISCONNECT` (около строки 270): если `currentNativeState == "blocked"` → закрыть `tunInterface`, `tunInterface = null`, `setState("disconnected")`, `stopForeground`/`stopSelf` (по образцу существующего кода отключения). Аналогично: `ACTION_CONNECT`/`ACTION_CONNECT_QUICK` при blocked работают как обычно (startVpn закрывает старый TUN после establish — уже реализовано для реконнекта).
- [ ] **Step 3: Flutter.** `vpn_engine.dart`: `enum VpnState { disconnected, connecting, connected, disconnecting, error, blocked }`. `vpn_provider.dart`: `_parseState` — `'blocked' => VpnState.blocked`; `VpnState2.isBlocked => connectionState == VpnState.blocked`; в `_onNativeState`: ветка `blocked` — сбросить таймеры и статистику как для disconnected (`_statsPoller?.cancel(); state = VpnState2(connectionState: VpnState.blocked);` — `_connectedAt = null`). `connect()` guard не трогать (isConnected=false при blocked — подключение разрешено). `disconnect()` guard: разрешить вызов при blocked (сейчас первый `if` пропустит, т.к. state != disconnected/disconnecting — ок).
- [ ] **Step 4:** `flutter analyze`; Kotlin компиляция — `./build.sh debug` (или отложить сборку APK до финала, но синтаксис проверить).
- [ ] **Step 5: Commit** `feat: состояние blocked для kill switch`

---

### Task 3: Навигация — вкладка Маршрутизация, логи через push

**Files:**
- Modify: `lib/app.dart`, `lib/ui/screens/routing_screen.dart`, `lib/ui/screens/logs_screen.dart`, `lib/ui/screens/home_screen.dart`
- Modify: `lib/ui/widgets/breadcrumb_bar.dart` (если нужен параметр)

**Interfaces:**
- Produces: `final tabIndexProvider = StateProvider<int>((ref) => 0);` в `lib/app.dart` (экспортируется, Home использует для перехода на вкладку Конфиги в Task 7); `LogsScreen({this.breadcrumbParent})` — если null, breadcrumb не показывается.

- [ ] **Step 1: app.dart.** `_pages = [HomeScreen(), ConfigsScreen(), RoutingScreen(), SettingsScreen()]`. `_currentIndex` заменить на `ref.watch(tabIndexProvider)`; `onTap: (i) => ref.read(tabIndexProvider.notifier).state = i`. Вкладки: `shield/VPN`, `key/Конфиги`, `route/Маршрут`, `cog/Настройки` (badge остаётся на Настройках). Новый `_TabIcon.route` в painter: развилка — линия (4,20)→(12,12)→(4,4) не годится; рисуем: `canvas.drawLine(Offset(4,19), Offset(10,12))`, `drawLine(Offset(10,12), Offset(4,5))` — нет, проще стрелки-маршрут: две ломаные `path: (4,17)→(10,17)→(14,7)→(20,7)` + стрелка `(17,4)→(20,7)→(17,10)`. Реализовать Path со strokeCap round.
- [ ] **Step 2: routing_screen.dart:134** — удалить строку `BreadcrumbBar(...)` и её импорт, если не используется.
- [ ] **Step 3: logs_screen.dart.** Конструктор: `const LogsScreen({super.key, this.breadcrumbParent}); final String? breadcrumbParent;` После console header вставить `if (widget.breadcrumbParent != null) BreadcrumbBar(t: t, parent: widget.breadcrumbParent!, current: 'logs')`.
- [ ] **Step 4: home_screen.dart `_HeaderStrip`.** Правую часть заменить на Row: иконка логов (`_TabIcon.list` переиспользовать нельзя — приватный; использовать `Icon(Icons.receipt_long_outlined, size: 14)` в квадратной кнопке 28×28 c border t.line) + существующий `sys.state [код]`. Тап → `Navigator.push(context, MaterialPageRoute(builder: (_) => const LogsScreen(breadcrumbParent: 'home')))`. `_HeaderStrip` станет виджетом с BuildContext-навигацией — ок.
- [ ] **Step 5: settings_screen.dart.** В секции about (0x50) перед `_UpdateChannelSegment` добавить `_RowChev(title: 'Логи', hint: 'журнал приложения и xray', onTap: push LogsScreen(breadcrumbParent: 'settings'))`. В секции 0x40 удалить `_RowChev «Маршрутизация трафика»`.
- [ ] **Step 6:** `flutter analyze`; Commit `feat: вкладка Маршрутизация, логи перенесены в push-навигацию`

---

### Task 4: Настройки — разблокировка при подключённом VPN

**Files:**
- Modify: `lib/ui/screens/settings_screen.dart`

**Interfaces:**
- Consumes: ничего нового. `locked` внутри экрана теперь = только `profileReadonly`.

- [ ] **Step 1.** `_SettingsScreenState.build`: `vpnLocked` удалить; `locked = profileReadonly`. `_SettingsBody(isConnected: ...)` — параметр удалить; поле `locked` в body = `isProfileReadonly`.
- [ ] **Step 2.** `_SetHeroPanel`: тексты при locked — только readonly-ветка (`'профиль заблокирован · только чтение'`); ветку `'отключите VPN чтобы изменить параметры'` удалить. `_SetHeaderStrip` `[locked/open]` остаётся (locked теперь только readonly).
- [ ] **Step 3.** Snackbar для readonly: в `_RowToggle`, `_RowChev`, `_SegSquare`, `_InlineField`-полях при `locked` вместо `onChanged: null` — обернуть весь ряд в `GestureDetector(onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Профиль только для чтения'))))`, элементы управления оставить визуально disabled. Реализовать единообразно: в каждом row-виджете `if (locked) return _LockedWrap(child: row)` где `_LockedWrap` — приватный виджет с этим GestureDetector (absorbing).
- [ ] **Step 4.** `Positioned.fill IgnorePointer` оверлей (строки 889-894) удалить.
- [ ] **Step 5:** `flutter analyze`; Commit `feat: настройки редактируемы при подключённом VPN`

---

### Task 5: ReconnectBanner на Настройках и Home

**Files:**
- Create: `lib/ui/widgets/reconnect_banner.dart`
- Modify: `lib/ui/screens/settings_screen.dart`, `lib/ui/screens/home_screen.dart`

**Interfaces:**
- Consumes: `pendingReconnectProvider`, `vpnProvider.notifier.reconnectWithNewConfig()`.
- Produces: `class ReconnectBanner extends ConsumerWidget` — рендерит SizedBox.shrink когда баннер не нужен.

- [ ] **Step 1: Виджет**

```dart
// lib/ui/widgets/reconnect_banner.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/vpn_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Баннер «настройки изменены — переподключитесь».
/// Виден только когда pendingReconnectProvider == true.
class ReconnectBanner extends ConsumerWidget {
  const ReconnectBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingReconnectProvider);
    if (!pending) return const SizedBox.shrink();
    final t = Theme.of(context).extension<TeapodTokens>()!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      decoration: BoxDecoration(
        color: t.accentFade,
        border: Border(bottom: BorderSide(color: t.accent, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('настройки изменены · применятся после переподключения',
                style: AppTheme.mono(size: 10, color: t.text, letterSpacing: 0.5)),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => ref.read(vpnProvider.notifier).reconnectWithNewConfig(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: t.accent,
              child: Text('ПЕРЕПОДКЛЮЧИТЬ',
                  style: AppTheme.mono(size: 9, color: t.bg, letterSpacing: 1)),
            ),
          ),
        ],
      ),
    );
  }
}
```

Проверить наличие токена `t.accentFade` (используется в configs_screen) — если нет в TeapodTokens, взять `t.accentSoft`.

- [ ] **Step 2.** settings_screen: `ReconnectBanner()` в Column после `_SetHeroPanel`, перед `Expanded`. home_screen: после `_HeaderStrip`, перед `_HeroPanel`.
- [ ] **Step 3:** `flutter analyze`; Commit `feat: баннер переподключения при изменённых настройках`

---

### Task 6: Подэкран «Сеть», DNS-консолидация, split-toggle, update наверх

**Files:**
- Create: `lib/ui/screens/network_settings_screen.dart`
- Modify: `lib/ui/screens/settings_screen.dart`, `lib/ui/screens/dns_settings_screen.dart`, `lib/ui/screens/split_tunnel_screen.dart`, `lib/ui/widgets/settings_shared.dart`

**Interfaces:**
- Produces: `class NetworkSettingsScreen extends ConsumerStatefulWidget`; общие row-виджеты в `settings_shared.dart`: `SetRowToggle`, `SetRowChev`, `SetInlineField`, `SetSegSquare`, `SetCredField`, `SetSquareSwitch` (публичные копии приватных из settings_screen, с параметром `locked` и snackbar-обёрткой из Task 4).

- [ ] **Step 1: Расшарить row-виджеты.** Перенести `_RowToggle`, `_RowChev`, `_InlineField`, `_CredField`, `_SegSquare`, `_SquareSwitch` из settings_screen в `settings_shared.dart` с публичными именами (`SetRowToggle`, …), обновить все использования в settings_screen.
- [ ] **Step 2: NetworkSettingsScreen.** Структура экрана: Scaffold → SafeArea → Column: console header (`teapod.stream // network`), `BreadcrumbBar(parent: 'settings', current: 'network')`, `HeroPanel(tagline: 'СЕТЬ · SOCKS · TUN', title: 'NETWORK')`, Expanded(ListView). Перенести из settings_screen секции 0x30 целиком: randomPort + SOCKS5 порт (TextField+`_socksPortCtrl`), randomCredentials + логин/пароль, proxyOnly, UDP, ICMP, blockQuic, TLS fingerprint (пикер `_showFingerprintPicker` + `_fpLabel` перенести), IPv6, MTU (+`_mtuCtrl`, `_updateMtu`), Observatory (+`_obsCtrl`). Контроллеры и `_updatePorts`/`_updateCredentials`/`_updateMtu`/`_updateObsInterval` переезжают в state этого экрана (скопировать логику из `_SettingsBodyState`, из settings_screen удалить). `locked` = profileReadonly (из profileProvider).
- [ ] **Step 3: DNS.** dns_settings_screen: добавить наверх списка два блока из settings_screen — «Режим DNS» (SegSquare proxy/direct) и «DNS стратегия» (ipv4Only/ipv6Only/auto); из settings_screen удалить.
- [ ] **Step 4: Главный список настроек.** Секция 0x30 теперь: `SetSectionHeader('0x30', 'network')` + `SetRowChev('Сеть', hint: 'SOCKS ${s.randomPort ? 'random' : s.socksPort} · MTU ${s.mtu}', → NetworkSettingsScreen)` + `SetRowChev('DNS', hint: _dnsLabel(s), → DnsSettingsScreen)`.
- [ ] **Step 5: Split tunnel.** split_tunnel_screen: над mode-селектором добавить `SetRowToggle('Сплит-туннелирование', value: s.splitTunnelingEnabled, ...)`; при выключенном — список приложений скрыт (показывать hint-текст «включите, чтобы выбрать приложения»). В settings_screen секция 0x40: единственный `SetRowChev('Сплит-туннелирование', hint: s.splitTunnelingEnabled ? '${s.vpnMode == VpnMode.onlySelected ? s.includedPackages.length : s.excludedPackages.length} прил · ${s.vpnMode == VpnMode.onlySelected ? 'ТОЛЬКО' : 'КРОМЕ'}' : 'выкл', → SplitTunnelScreen)`; toggle удалить.
- [ ] **Step 6: Update наверх.** В `_SettingsBodyState.build`: `final hasUpdate = ref.watch(updateProvider)` — виджет body не Consumer; поднять чтение в `SettingsScreen.build` и передать `hasUpdate: bool`. При true — контейнер с `_UpdateTile` первым элементом ListView (до 0x10), из секции about в этом случае убрать (оставить `_UpdateChannelSegment` на месте).
- [ ] **Step 7:** `flutter analyze`; Commit `feat: подэкран Сеть, DNS-консолидация, split-toggle внутри экрана, update наверху`

---

### Task 7: Home — ячейка «Сервер», bottom sheet, пустое состояние, managed-фикс

**Files:**
- Create: `lib/ui/widgets/server_picker_sheet.dart`
- Modify: `lib/ui/screens/home_screen.dart`

**Interfaces:**
- Consumes: `tabIndexProvider` (Task 3), `configProvider`, `effectiveConfigProvider`, `vpnProvider`. Пины появятся в Task 8 — sheet строится без них, Task 9 добавит секцию.
- Produces: `Future<void> showServerPicker(BuildContext context, WidgetRef ref)`.

- [ ] **Step 1: server_picker_sheet.dart.** `showModalBottomSheet` (стиль как `_showConfigMenu`: `backgroundColor: t.bg`, `RoundedRectangleBorder(borderRadius: BorderRadius.zero)`, `isScrollControlled: true`, maxHeight 70%): заголовок `select // server`, затем ListView: для каждой подписки — mini-заголовок (имя, mono 10 muted), под ним конфиги; standalone — первым под заголовком `[local]`. Ряд: имя (sans 13), протокол-тег, ping справа (accent), активный — `t.accentFade` фон + левая полоса 2px (по образцу `_ConfigRow`). Тап: `Navigator.pop`; `configProvider.notifier.setActiveConfig(id)`; если `vpnProvider` isConnected/isBusy → `reconnectWithNewConfig()` (логика `_selectConfig` из configs_screen).
- [ ] **Step 2: Ячейка «Сервер».** В `_MetricsGrid` ячейку «Протокол» заменить: label `'Сервер'`, value = `config.name` (не mono 20 — sans 14 w500, ellipsis), hint = `'$protoLabel · $address:$port'`, справа маленький chevron `›` (mono 12 textDim). Обернуть в GestureDetector → `showServerPicker(context, ref)`. `_MetricsGrid` станет ConsumerWidget (нужен ref) — передать `WidgetRef` через параметр либо конвертировать; конвертировать в ConsumerWidget.
- [ ] **Step 3: Пустое состояние.** В `HomeScreen.build`: `canToggle == false` → `_StateInfo` subtitle: `'нет конфигурации — добавьте'`. `_PowerCore.onTap` при `!enabled`: вместо null — `() => ref.read(tabIndexProvider.notifier).state = 1`. Прокинуть отдельный `onDisabledTap`.
- [ ] **Step 4: Blocked-состояние (использует Task 2).** В `_StateInfo`: `vpnState.isBlocked` → stateWord `'BLOCKED'` цветом `t.danger`, subtitle `'kill switch · трафик заблокирован'`. Под subtitle кнопка-текст `'отключить'` (mono 11 underline) → `vpnProvider.notifier.disconnect()`. `_PowerCore`: при blocked внешнее кольцо `t.danger`, тап → `connect()` (toggle сработает: isConnected=false).
- [ ] **Step 5: Managed-фикс.** `home_screen.dart:626`: `TextSpan(text: detail)` без суффикса `' · управляется сервером'`; в ветку `isOnlySelected` добавить `' · роутинг управляется сервером'`, чтобы обе ветки были полными.
- [ ] **Step 6:** `flutter analyze`; Commit `feat: смена сервера с Home, пустое и blocked состояния`

---

### Task 8: Пины — модель, storage, provider

**Files:**
- Create: `lib/core/models/pinned_ref.dart`
- Modify: `lib/core/services/storage_secure_service.dart`, `lib/core/services/config_storage_service.dart`, `lib/providers/config_provider.dart`
- Test: `test/core/pinned_ref_test.dart`

**Interfaces:**
- Produces:

```dart
class PinnedRef {
  final String? subscriptionId; // null = standalone
  final String name;
  const PinnedRef({required this.subscriptionId, required this.name});
  Map<String, dynamic> toJson();
  factory PinnedRef.fromJson(Map<String, dynamic> json);
  bool matches(VpnConfig c) => c.subscriptionId == subscriptionId && c.name == name;
  // == и hashCode по (subscriptionId, name)
}
```

- `ConfigState.pins: List<PinnedRef>`; `List<(PinnedRef, VpnConfig?)> get resolvedPins` — для каждого пина первый матч из configs или null.
- `ConfigNotifier.togglePin(VpnConfig c)`, `ConfigNotifier.unpin(PinnedRef ref)`, `bool isPinned(VpnConfig c)` на ConfigState.
- Storage: `ConfigStorageService.loadPins()/savePins(List<PinnedRef>)` через `StorageSecureService` (raw JSON string, по образцу configs).

- [ ] **Step 1: Failing test**

```dart
// test/core/pinned_ref_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:teapodstream/core/models/pinned_ref.dart';
import 'package:teapodstream/core/models/vpn_config.dart';
import 'package:teapodstream/providers/config_provider.dart';

VpnConfig cfg(String id, String name, {String? subId}) => VpnConfig(
      id: id, name: name, protocol: VpnProtocol.vless,
      address: 'a.example', port: 443, uuid: 'u',
      createdAt: DateTime(2026), subscriptionId: subId,
    );

void main() {
  test('пин резолвится по (subId, name) после смены id конфига', () {
    const pin = PinnedRef(subscriptionId: 's1', name: 'Amsterdam');
    final before = ConfigState(configs: [cfg('old', 'Amsterdam', subId: 's1')], pins: const [pin]);
    expect(before.resolvedPins.single.$2!.id, 'old');
    // после обновления подписки конфиг пересоздан с новым id
    final after = ConfigState(configs: [cfg('new', 'Amsterdam', subId: 's1')], pins: const [pin]);
    expect(after.resolvedPins.single.$2!.id, 'new');
  });
  test('исчезнувшее имя -> null, пин сохраняется', () {
    const pin = PinnedRef(subscriptionId: 's1', name: 'Gone');
    final st = ConfigState(configs: [cfg('x', 'Other', subId: 's1')], pins: const [pin]);
    expect(st.resolvedPins.single.$2, isNull);
  });
  test('одинаковые имена в разных подписках не путаются', () {
    const pin = PinnedRef(subscriptionId: 's2', name: 'NL');
    final st = ConfigState(
      configs: [cfg('a', 'NL', subId: 's1'), cfg('b', 'NL', subId: 's2')],
      pins: const [pin],
    );
    expect(st.resolvedPins.single.$2!.id, 'b');
  });
  test('json roundtrip', () {
    const pin = PinnedRef(subscriptionId: null, name: 'Local');
    expect(PinnedRef.fromJson(pin.toJson()), pin);
  });
}
```

Сигнатуру конструктора `VpnConfig` сверить с моделью и поправить хелпер `cfg`.

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Реализация.** `pinned_ref.dart` по интерфейсу выше. `ConfigState`: поле `pins` (default `const []`), в `copyWith` — `List<PinnedRef>? pins`, `resolvedPins` как `late final`. `ConfigNotifier.build()`: `final pins = await storage.loadPins();`. `togglePin(c)`: пин с `(c.subscriptionId, c.name)` — удалить если есть, иначе добавить в конец; `savePins`; state update. `unpin(ref)`: удалить + persist. Storage: в `StorageSecureService` добавить `readPinsRaw()/writePinsRaw(String)` по образцу configs-методов (ключ `'pinned_refs'`); `ConfigStorageService.loadPins/savePins` — JSON list.
- [ ] **Step 4: Run** тесты + `flutter analyze` — PASS/0.
- [ ] **Step 5: Commit** `feat: модель и хранение закреплённых подключений`

---

### Task 9: Конфиги — группа [pinned], меню ⋮, режим сортировки

**Files:**
- Modify: `lib/ui/screens/configs_screen.dart`, `lib/ui/widgets/server_picker_sheet.dart`

**Interfaces:**
- Consumes: `ConfigState.pins/resolvedPins`, `togglePin/unpin/isPinned`.

- [ ] **Step 1: Группа [pinned].** Новый виджет `_PinnedGroup` (по образцу `_LocalGroup`, без reorder): заголовок `[pinned]` c адресом `[--]`, звёздочка-иконка. Ряды: resolved → `_ConfigRow` (addr = индекс в группе); unresolved → строка с именем `t.textMuted`, тегом `LOST`, hint `'нет в подписке · долгий тап — открепить'`, long-press → sheet с единственным пунктом «Открепить». Вставить первым элементом в `_buildGroupedList` и `_buildFlatList` (в flat-режиме тоже сверху). Группа не сворачивается (мал размер) — без expand-state.
- [ ] **Step 2: Пункт меню.** В `_showConfigMenu` первым пунктом: `_SheetTile(label: cs.isPinned(config) ? 'Открепить' : 'Закрепить', onTap: togglePin)`.
- [ ] **Step 3: Кнопка ⋮.** В `_ConfigRow` справа после ping: `GestureDetector(onTap: onLongPress)` c `Icon(Icons.more_vert, size: 16, color: t.textMuted)` в SizedBox 32×44. В строке подписки (`_SubGroup`) аналогично — вызывает `_showSubMenu`. long-press остаётся.
- [ ] **Step 4: Режим сортировки.** В `_ConfigsScreenState`: `bool _sortMode = false` (не персистится). В settings-sheet ⊟ третий `_ToggleTile('режим сортировки', value: _sortMode)`. При `_sortMode`: в `_ConfigRow` и строке подписки вместо ⋮ показывается `ReorderableDragStartListener(index: …, child: Icon(Icons.drag_handle, size: 16))`; `draggableIndex`-механика через hex-адрес удаляется (`ReorderableDelayedDragStartListener` на addr, подсветка addr). Пробросить `sortMode` в `_LocalGroup`/`_SubGroup`/`_ConfigRow`. При `_sortByPing == true` сортировка руками невозможна — в sheet дизейблить toggle сортировки (и наоборот).
- [ ] **Step 5: Home sheet.** В `server_picker_sheet.dart` первой секцией `[pinned]` — resolved-пины (unresolved пропускаются).
- [ ] **Step 6:** `flutter analyze`; Commit `feat: избранные подключения, меню ⋮, явный режим сортировки`

---

### Task 10: Pressable + цели нажатия + Semantics

**Files:**
- Create: `lib/ui/widgets/pressable.dart`
- Modify: `lib/app.dart`, `lib/ui/screens/home_screen.dart`, `lib/ui/screens/configs_screen.dart`, `lib/ui/widgets/settings_shared.dart`

**Interfaces:**
- Produces:

```dart
/// GestureDetector с подсветкой фона при нажатии (console-стиль, без ripple).
class Pressable extends StatefulWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? pressedColor; // default: TeapodTokens.accentFade
  final Widget child;
  const Pressable({super.key, this.onTap, this.onLongPress, this.pressedColor, required this.child});
}
```

Реализация: `_pressed` state через onTapDown/onTapUp/onTapCancel, `AnimatedContainer(duration: 90ms, color: _pressed ? pressedColor : Colors.transparent)`.

- [ ] **Step 1.** Создать `pressable.dart` (полный код по интерфейсу).
- [ ] **Step 2.** Применить: `SetRowToggle`/`SetRowChev`/sheet-тайлы (`_SheetTile` в configs_screen) / `_ConfigRow` / `_IconBtn`. Для `SetRowToggle` — тап по всей строке переключает значение. `_IconBtn` в configs_screen: контейнер 28×28 → 36×36 (иконка 16), между кнопками SizedBox(width: 4).
- [ ] **Step 3: Semantics.** app.dart таббар: обернуть item в `Semantics(label: item.label, button: true, selected: active)`. home_screen `_PowerCore`: `Semantics(label: actionLabel, button: true)`. `_IconBtn`: параметр `semanticLabel` → `Semantics(label:)` (заполнить: 'настройки отображения', 'экспорт', 'обновить все', 'добавить').
- [ ] **Step 4:** `flutter analyze`; Commit `feat: тактильный отклик, увеличенные цели, semantics`

---

### Task 11: Clipboard-детект и языковые правки

**Files:**
- Modify: `lib/ui/screens/add_config_screen.dart`, `lib/ui/screens/home_screen.dart`

- [ ] **Step 1: Clipboard.** В `_AddConfigScreenState.initState`: `Clipboard.getData(Clipboard.kTextPlain)` → если текст матчит `RegExp(r'^(vless|vmess|trojan|ss|hy2|https?)://', caseSensitive: false)` и поле ввода пусто → `setState(() => _clipboardSuggestion = text)`. Под полем ввода кнопка-чип: `Pressable` контейнер с border t.accent, текст `'вставить из буфера: ${suggestion ellipsis 40}'` → подставляет в TextField и скрывает чип.
- [ ] **Step 2: Тексты home_screen.** `'tap to connect'` → `'нажмите для подключения'`; `'negotiating session…'` → `'установка соединения…'`; `'closing session…'` → `'завершение сеанса…'`. Статусы ONLINE/HANDSHAKE/SHUTDOWN/OFFLINE/BLOCKED — EN, не трогать.
- [ ] **Step 3:** `flutter analyze`; Commit `feat: автодетект буфера обмена, языковые правки`

---

### Task 12: Финальная верификация и вики

- [ ] **Step 1.** `flutter analyze` — 0 issues; `flutter test` — все тесты (кроме pre-existing падающего `widget_test.dart` — проверить статус на чистом дереве).
- [ ] **Step 2.** `./build.sh debug` — APK собирается (включая Kotlin из Task 2).
- [ ] **Step 3.** Предложить пользователю `./build.sh run` на устройстве (не переустанавливать без спроса) — smoke: вкладки, смена сервера с Home, изменение настройки при подключённом VPN → баннер → переподключение, пины, blocked-состояние (выдернуть сеть при kill switch — по возможности).
- [ ] **Step 4.** Вики: `wiki/components/ui_screens.md` (новая навигация, NetworkSettingsScreen, ServerPickerSheet, ReconnectBanner, пины, sort mode), `wiki/components/vpn_provider.md` (appliedFingerprint, pendingReconnectProvider, blocked), `wiki/components/config_provider.md` (pins), `wiki/components/android_native.md` (blocked state), `wiki/index.md`, `wiki/log.md`, пометки в `wiki/ux-review.md` (что реализовано).
- [ ] **Step 5.** Commit `docs: обновление вики после UX-редизайна` (только docs/, wiki не коммитится).
