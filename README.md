# Teapod Stream Nordic

> Оригинальный проект: [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream)

Современный форк Android VPN-клиента на Flutter с движком Xray, TUN-режимом, split tunneling, поддержкой подписок и визуально переработанным интерфейсом в палитре Nord.

![Nordic preview](screen1.png)

## Что это за репозиторий

`teapod-stream-nordic` — это форк оригинального `teapod-stream`, в котором сохранена основная архитектура и функциональность клиента, но доработаны:

- визуальная тема в стиле Nord;
- главный экран и кнопка управления VPN;
- часть UX-деталей;
- некоторые аспекты безопасности, устойчивости и читаемости кода.

Если вам нужен первоисточник, активная upstream-история и оригинальные релизы, начинайте с репозитория автора: [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream).

---

## Возможности

- протоколы: **VLESS**, **VMess**, **Trojan**, **Shadowsocks**, **Hysteria2**;
- транспорты: **TCP**, **WebSocket**, **gRPC**, **HTTP/2**, **QUIC**, **xHTTP**, **HTTPUpgrade**, **SplitHTTP**;
- режим полного VPN через `VpnService` + TUN;
- режим **"только прокси"** без поднятия TUN;
- split tunneling по списку приложений;
- маршрутизация по странам, доменам и `geosite`;
- подписки по URL, включая base64 и plain-text форматы;
- импорт через deeplink и QR;
- отображение скорости, трафика, состояния и IP;
- встроенная проверка обновлений;
- современная Nord-стилизация интерфейса.

---

## Как это работает

Ниже — практическая схема работы приложения без маркетинговых упрощений.

### 1. Что делает приложение при подключении

Когда пользователь нажимает кнопку подключения:

1. Flutter UI формирует Xray-конфиг на основе выбранного профиля.
2. Конфиг передаётся в Android-часть через `MethodChannel`.
3. Android запускает `XrayVpnService`.
4. Сервис:
   - поднимает локальный SOCKS5-inbound для `xray-core`;
   - при необходимости создаёт TUN-интерфейс через `android.net.VpnService`;
   - подключает TUN к мосту `teapod-tun2socks`;
   - запускает `xray-core` из `teapod-core.aar`.

### 2. Поток трафика в TUN-режиме

```text
[Android apps]
      ↓
[TUN interface / VpnService]
      ↓
[teapod-tun2socks]
      ↓
[SOCKS5 127.0.0.1:<port>]
      ↓
[xray-core]
      ↓
[VPN / proxy server]
```

То есть приложение не «туннелит интернет само по себе» на уровне UI. UI только управляет сервисом, хранит настройки и показывает состояние. Основная транспортная работа выполняется нативными компонентами.

### 3. Режим «только прокси»

Если включён proxy-only режим, TUN не создаётся. Тогда схема такая:

```text
[Клиентское приложение, настроенное на SOCKS5]
      ↓
[SOCKS5 127.0.0.1:<port>]
      ↓
[xray-core]
      ↓
[Удалённый сервер]
```

Это полезно, когда нужен локальный прокси без полного VPN-режима.

### 4. Split tunneling

Split tunneling работает на стороне Android и `teapod-tun2socks`:

- приложение получает список установленных пакетов;
- пользователь задаёт, что включать или исключать;
- при работе через TUN мост определяет UID владельца соединения;
- дальше трафик либо пропускается в туннель, либо игнорируется согласно выбранному режиму.

### 5. DNS и маршрутизация

Приложение умеет строить Xray-конфиг так, чтобы DNS-запросы:

- шли через VPN;
- или обходили туннель;
- или разрешались через выбранные DNS-провайдеры.

Для правил маршрутизации используются:

- `geoip.dat`;
- `geosite.dat`;
- пользовательские домены;
- пресеты вроде ad-block/geosite-маршрутизации.

### 6. Подписки и импорт

Подписки загружаются по URL, затем:

- содержимое декодируется как base64 или читается как plain text;
- каждая строка разбирается как URI-конфиг;
- валидные конфиги сохраняются локально;
- метаданные подписки используются для названия, срока действия и статуса.

Deeplink-импорт поддерживает профильные и пакетные схемы вида `teapod://import/...`.

---

## Архитектура проекта

### UI и логика состояния

Основная клиентская часть написана на Flutter.

Ключевые слои:

- `lib/ui/*` — экраны, виджеты, тема;
- `lib/providers/*` — состояние приложения на Riverpod;
- `lib/core/services/*` — storage, подписки, deeplink, обновления;
- `lib/protocols/xray/*` — парсинг и сборка Xray-конфига.

### Android-часть

Нативная часть расположена в `android/app/src/main/kotlin/...` и отвечает за:

- запуск `VpnService`;
- работу foreground service;
- связь Flutter ↔ Android через `MethodChannel` и `EventChannel`;
- подготовку бинарных ресурсов;
- инсталляцию APK-обновлений;
- работу quick settings tile.

### Нативный сетевой стек

Трафиковая часть собрана из внешних компонентов:

- `xray-core` — маршрутизация и протоколы;
- `teapod-tun2socks` — мост между TUN и SOCKS5;
- `teapod-core` — Android AAR, объединяющий `xray-core` и `teapod-tun2socks`.

---

## Чем этот форк отличается от оригинала

На момент текущего состояния репозитория форк включает такие заметные изменения:

- Nord-цветовая схема и обновлённые акценты интерфейса;
- кастомная главная кнопка с круглым изображением опоссума;
- корректировки читаемости и поведения главного экрана;
- локальные улучшения по устойчивости UI;
- часть снижения рискованных поверхностей по сравнению с прежним состоянием форка.

Если хотите увидеть фундаментальные архитектурные решения, сравнивайте этот репозиторий с upstream: [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream).

---

## Сборка

### Требования

- Flutter SDK `3.11+`
- Java `21+`
- Android SDK
- Android NDK `28.2.13676358`
- CMake `3.22.1`

### Быстрый сценарий

```bash
# 1. Скачать бинарные зависимости
./build.sh binaries

# 2. Debug APK
./build.sh debug

# 3. Release APK (split per ABI)
./build.sh release
```

### Выходные артефакты

После release-сборки APK находятся в:

```text
build/app/outputs/flutter-apk/
```

Обычно формируются варианты для:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`

> Важно: текущая release-сборка в проекте по умолчанию может использовать debug signing config. Для реального публичного релиза нужно подключить собственный release keystore.

---

## Что используется внутри

Ниже — список ключевого ПО, библиотек и компонентов, на которых держится проект.

### Базовая платформа

- [Flutter](https://flutter.dev/) — UI и кроссплатформенный каркас приложения
- [Dart](https://dart.dev/) — основной язык клиентской части
- Android `VpnService` — системный API для VPN/TUN
- Kotlin — Android-слой
- Gradle — Android-сборка
- CMake — нативная сборка Android-модуля
- Java 21 — toolchain для сборки

### Сетевые и VPN-компоненты

- [Xray-core](https://github.com/XTLS/Xray-core) — ядро прокси-маршрутизации
- [teapod-core](https://github.com/Wendor/teapod-core) — AAR-обёртка для Android
- [teapod-tun2socks](https://github.com/Wendor/teapod-tun2socks) — TUN → SOCKS5 bridge
- [v2ray-rules-dat / Loyalsoldier](https://github.com/Loyalsoldier/v2ray-rules-dat) — `geoip.dat` и `geosite.dat`

### Flutter / Dart библиотеки

#### Состояние и приложение

- [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) — state management
- [`shared_preferences`](https://pub.dev/packages/shared_preferences) — хранение простых настроек
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) — защищённое хранение чувствительных данных

#### Сеть и подписки

- [`http`](https://pub.dev/packages/http) — HTTP-запросы
- [`socks5_proxy`](https://pub.dev/packages/socks5_proxy) — работа через локальный SOCKS5

#### UX и системная интеграция

- [`mobile_scanner`](https://pub.dev/packages/mobile_scanner) — QR-сканирование
- [`share_plus`](https://pub.dev/packages/share_plus) — системный share sheet
- [`permission_handler`](https://pub.dev/packages/permission_handler) — запросы разрешений
- [`url_launcher`](https://pub.dev/packages/url_launcher) — открытие внешних ссылок
- [`url_launcher_android`](https://pub.dev/packages/url_launcher_android) — Android-реализация launcher API
- [`package_info_plus`](https://pub.dev/packages/package_info_plus) — версия приложения и build metadata
- [`path_provider`](https://pub.dev/packages/path_provider) — системные директории

#### UI и утилиты

- [`google_fonts`](https://pub.dev/packages/google_fonts) — шрифты интерфейса
- [`fl_chart`](https://pub.dev/packages/fl_chart) — графики
- [`intl`](https://pub.dev/packages/intl) — форматирование
- [`uuid`](https://pub.dev/packages/uuid) — генерация идентификаторов

#### Инструменты разработки

- [`flutter_test`](https://api.flutter.dev/flutter/flutter_test/flutter_test-library.html) — тесты
- [`flutter_lints`](https://pub.dev/packages/flutter_lints) — lint rules
- [`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons) — генерация launcher icon assets

---

## Благодарности и кредиты

Этот репозиторий существует благодаря работе множества авторов и open-source проектов.

В первую очередь:

- автору оригинального клиента — [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream)
- авторам [Xray-core](https://github.com/XTLS/Xray-core)
- авторам [teapod-core](https://github.com/Wendor/teapod-core)
- авторам [teapod-tun2socks](https://github.com/Wendor/teapod-tun2socks)
- авторам [v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
- команде [Flutter](https://flutter.dev/)
- авторам всех перечисленных пакетов из `pub.dev`

Если вы используете этот форк публично, корректно указывать ссылку как на этот репозиторий, так и на upstream-источник.

---

## Важные замечания

- Это форк клиентского VPN-приложения, а не самостоятельный сетевой протокол.
- Корректная работа зависит от совместимого серверного конфига.
- Перед распространением собственных APK стоит проверить:
  - release signing;
  - политику обновлений;
  - актуальность `teapod-core`;
  - набор разрешений в AndroidManifest.

---

## Лицензии

Смотрите лицензии исходных компонентов в их соответствующих репозиториях:

- [Xray-core / MIT](https://github.com/XTLS/Xray-core)
- [teapod-core](https://github.com/Wendor/teapod-core)
- [teapod-tun2socks / MIT](https://github.com/Wendor/teapod-tun2socks)
- лицензии Flutter/Dart-пакетов — на страницах соответствующих пакетов `pub.dev`

Если нужен юридически строгий список лицензий для дистрибуции, лучше сформировать отдельный `THIRD_PARTY_NOTICES.md` на основе lockfile и всех upstream-компонентов.
