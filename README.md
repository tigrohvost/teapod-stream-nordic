# Teapod Stream Nordic

> Оригинальный проект: [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream)

[![Fork: teapod-stream](https://img.shields.io/badge/upstream-Wendor%2Fteapod--stream-88C0D0?style=for-the-badge&labelColor=2E3440)](https://github.com/Wendor/teapod-stream)
[![Flutter 3.11+](https://img.shields.io/badge/Flutter-3.11%2B-81A1C1?style=for-the-badge&labelColor=2E3440&logo=flutter)](https://flutter.dev/)
[![Android 10+](https://img.shields.io/badge/Android-10%2B-A3BE8C?style=for-the-badge&labelColor=2E3440&logo=android)](https://developer.android.com/)
[![Xray Core](https://img.shields.io/badge/Xray-core-B48EAD?style=for-the-badge&labelColor=2E3440)](https://github.com/XTLS/Xray-core)
[![License: MIT](https://img.shields.io/badge/License-MIT-EBCB8B?style=for-the-badge&labelColor=2E3440)](./LICENSE)

Современный Android VPN-клиент на Flutter с ядром Xray, поддержкой TUN-режима, split tunneling, подписок, QR-импорта и визуальным оформлением в палитре Nord.

<p align="center">
  <img src="screen1.png" alt="Teapod Stream Nordic — главный экран" width="280" />
  <img src="screen2.png" alt="Teapod Stream Nordic — экран состояния" width="280" />
</p>

## Зачем этот форк

`teapod-stream-nordic` сохраняет архитектуру и совместимость оригинального клиента, но делает повседневное использование приятнее:

- обновляет интерфейс в стиле Nord без тяжёлой визуальной перегрузки;
- улучшает главный экран и сценарий включения VPN;
- оставляет совместимость с Xray-конфигами и подписками upstream-проекта;
- сохраняет понятную структуру проекта для дальнейшей доработки;
- добавляет более аккуратную документацию для обычных пользователей и разработчиков.

Если вам нужен первоисточник, история архитектурных решений и базовые релизы, начинайте с upstream-репозитория: [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream).

## Что умеет приложение

| Возможность | Для пользователя | Статус |
| --- | --- | --- |
| VLESS / VMess / Trojan / Shadowsocks / Hysteria2 | Подключение к разным типам серверов | `есть` |
| TCP / WS / gRPC / HTTP/2 / QUIC / xHTTP | Работа с разными транспортами | `есть` |
| Полный VPN через Android `VpnService` | Весь трафик устройства идёт через туннель | `есть` |
| Proxy-only режим | Локальный SOCKS5 без полного VPN | `есть` |
| Split tunneling | Выбор, какие приложения идут через туннель | `есть` |
| Импорт по URL, QR и deeplink | Быстрое добавление конфигов и подписок | `есть` |
| Проверка скорости, трафика и IP | Визуальный контроль состояния соединения | `есть` |
| Встроенная Nord-тема | Более чистый и цельный внешний вид | `есть` |

## Быстрый старт для обычного пользователя

1. Установите APK на Android-устройство.
2. Импортируйте конфиг или подписку по ссылке, QR-коду или deeplink.
3. Выберите профиль в списке серверов.
4. Нажмите главную кнопку с опоссумом.
5. Подтвердите системный запрос Android на создание VPN-подключения.
6. Дождитесь статуса подключения и проверьте скорость, IP и маршрут трафика.

## Скриншоты

| Главный экран | Экран состояния |
| --- | --- |
| ![Главный экран](screen1.png) | ![Экран состояния](screen2.png) |

## Как это работает

Снаружи приложение выглядит как аккуратный VPN-клиент, но внутри оно разделено на несколько независимых слоёв. Это упрощает поддержку и делает поведение более предсказуемым.

### Пользовательский сценарий

Когда вы нажимаете кнопку подключения, приложение делает следующее:

1. берёт выбранный профиль и собирает Xray-конфиг;
2. передаёт его из Flutter UI в Android-часть через `MethodChannel`;
3. запускает `XrayVpnService`;
4. поднимает локальный SOCKS5-интерфейс для `xray-core`;
5. при полном VPN-режиме создаёт TUN через `android.net.VpnService`;
6. соединяет TUN с мостом `teapod-tun2socks`;
7. отправляет трафик в `xray-core`, который уже работает с удалённым сервером.

### Поток трафика в полном VPN-режиме

```text
[Приложения Android]
         ↓
[TUN / VpnService]
         ↓
[teapod-tun2socks]
         ↓
[SOCKS5 127.0.0.1:<port>]
         ↓
[xray-core]
         ↓
[Удалённый VPN / proxy сервер]
```

### Если включён режим proxy-only

В этом сценарии TUN не поднимается. Приложение работает как локальный прокси:

```text
[Клиентское приложение]
         ↓
[SOCKS5 127.0.0.1:<port>]
         ↓
[xray-core]
         ↓
[Удалённый сервер]
```

### Как работают split tunneling, DNS и маршрутизация

- split tunneling использует Android UID-потоки и правила включения/исключения приложений;
- DNS можно направлять через туннель или обходной маршрут в зависимости от настроек;
- для маршрутизации применяются `geoip.dat`, `geosite.dat`, пользовательские домены и пресеты правил;
- подписки загружаются по URL, затем декодируются как base64 или plain text и разбираются построчно как URI-конфиги.

## Архитектура проекта

### Основные слои

- `lib/ui/*` — экраны, виджеты, тема и пользовательские сценарии;
- `lib/providers/*` — состояние приложения на Riverpod;
- `lib/core/services/*` — storage, подписки, deeplink, обновления и служебная логика;
- `lib/protocols/xray/*` — сборка и парсинг Xray-конфигов;
- `android/app/src/main/kotlin/*` — Android-сервисы, foreground service, каналы связи и системная интеграция.

### Нативный сетевой стек

- `xray-core` — маршрутизация, транспорты и протоколы;
- `teapod-tun2socks` — мост между TUN и локальным SOCKS5;
- `teapod-core` — Android AAR, объединяющий нативные VPN-компоненты.

## Чем форк отличается от оригинала

- Nord-цветовая схема и более цельные визуальные акценты;
- кастомная круглая кнопка с изображением опоссума на главном экране;
- локальные улучшения читаемости UI и отдельных пользовательских сценариев;
- переработанная документация, ориентированная не только на разработчика, но и на конечного пользователя.

## Сборка

### Требования

- Flutter SDK `3.11+`
- Dart SDK `^3.11.4`
- Java `21+`
- Android SDK
- Android NDK `28.2.13676358`
- CMake `3.22.1`
- Android `minSdk 29+`

### Быстрые команды

```bash
# Скачать бинарные зависимости
./build.sh binaries

# Собрать debug APK
./build.sh debug

# Собрать release APK (split per ABI)
./build.sh release
```

### Где искать APK

После release-сборки артефакты находятся в каталоге:

```text
build/app/outputs/flutter-apk/
```

Обычно формируются APK для:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`

> Важно: для публичного релиза стоит использовать собственный release keystore, даже если локальная сборка проходит с текущей конфигурацией проекта.

## Используемое ПО и библиотеки

### Базовая платформа

- [Flutter](https://flutter.dev/) — UI и кроссплатформенная оболочка
- [Dart](https://dart.dev/) — основной язык клиентской части
- Android `VpnService` — системный API для VPN/TUN
- [Kotlin](https://kotlinlang.org/) — Android-слой
- [Gradle](https://gradle.org/) — сборка Android-части
- [CMake](https://cmake.org/) — сборка нативных компонентов
- [Java 21](https://openjdk.org/) — toolchain проекта

### Сетевые и VPN-компоненты

- [Xray-core](https://github.com/XTLS/Xray-core) — маршрутизация, транспорты, прокси-протоколы
- [teapod-core](https://github.com/Wendor/teapod-core) — Android AAR-обёртка для Xray/TUN-компонентов
- [teapod-tun2socks](https://github.com/Wendor/teapod-tun2socks) — мост TUN → SOCKS5
- [v2ray-rules-dat / Loyalsoldier](https://github.com/Loyalsoldier/v2ray-rules-dat) — `geoip.dat` и `geosite.dat`

### Flutter и Dart пакеты

- [`flutter_riverpod`](https://pub.dev/packages/flutter_riverpod) — управление состоянием
- [`shared_preferences`](https://pub.dev/packages/shared_preferences) — простые локальные настройки
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) — защищённое хранение чувствительных данных
- [`share_plus`](https://pub.dev/packages/share_plus) — системный обмен данными
- [`mobile_scanner`](https://pub.dev/packages/mobile_scanner) — QR-сканирование
- [`http`](https://pub.dev/packages/http) — сетевые запросы
- [`uuid`](https://pub.dev/packages/uuid) — генерация идентификаторов
- [`intl`](https://pub.dev/packages/intl) — локализация и форматирование
- [`fl_chart`](https://pub.dev/packages/fl_chart) — графики скорости и трафика
- [`google_fonts`](https://pub.dev/packages/google_fonts) — шрифты интерфейса
- [`permission_handler`](https://pub.dev/packages/permission_handler) — системные разрешения
- [`package_info_plus`](https://pub.dev/packages/package_info_plus) — версия и метаданные сборки
- [`url_launcher_android`](https://pub.dev/packages/url_launcher_android) — Android-реализация открытия ссылок
- [`url_launcher`](https://pub.dev/packages/url_launcher) — запуск внешних URL
- [`path_provider`](https://pub.dev/packages/path_provider) — системные директории
- [`socks5_proxy`](https://pub.dev/packages/socks5_proxy) — работа через локальный SOCKS5

### Dev-инструменты

- [`flutter_test`](https://api.flutter.dev/flutter/flutter_test/flutter_test-library.html) — тесты
- [`flutter_lints`](https://pub.dev/packages/flutter_lints) — правила качества кода
- [`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons) — генерация иконок приложения

## Благодарности

Этот форк существует благодаря работе upstream-авторов и экосистемы open source.

Отдельное спасибо:

- автору и участникам [Wendor/teapod-stream](https://github.com/Wendor/teapod-stream);
- авторам [Xray-core](https://github.com/XTLS/Xray-core);
- авторам [teapod-core](https://github.com/Wendor/teapod-core);
- авторам [teapod-tun2socks](https://github.com/Wendor/teapod-tun2socks);
- авторам [v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat);
- команде [Flutter](https://flutter.dev/);
- авторам всех подключённых пакетов из `pub.dev`.

Если вы развиваете этот форк публично, корректно указывать ссылку и на этот репозиторий, и на исходный upstream-проект.

## Лицензия

Этот репозиторий распространяется по лицензии [MIT](./LICENSE).

Лицензии сторонних компонентов смотрите в их исходных репозиториях и на страницах соответствующих пакетов. Если нужен юридически строгий пакет уведомлений для дистрибуции, имеет смысл дополнительно подготовить `THIRD_PARTY_NOTICES.md`.
