# INTEGRATION.md — v0.1.27 native API scaffold + no-ADB debugging

Этот патч добавляет **native head-unit data path** параллельно с существующим BLE-режимом. Существующий код (`ConnectionService` 3519 LOC, `data/database.dart`, все screens) НЕ трогаем — BLE остаётся primary. Native режим активируется только когда `NativeDetector.isOnHeadUnit == true`.

## Контекст: нет ADB на машине

С recon-этапа известно: USB-debugging на BZ5 не запускается, доступ к `adb logcat` / `adb shell` / `adb install` пока недоступен. Вся диагностика должна жить **внутри приложения**. В этом патче специально добавлены инструменты для no-ADB workflow:

- `BydLogger` — ring buffer на 500 записей. Каждый `Log.i/w/e` из Kotlin фиксируется и виден в UI.
- `pullLogs` / `clearLogs` — Method channel для чтения буфера в Dart.
- `openAppSettings` — программно открывает Settings → App info → Permissions для ручной выдачи разрешений.
- `getDiagnostics` — снимок состояния: carserver установлен? провайдер резолвится? framework class найден? сколько permissions granted?
- **"Copy diagnostics"** кнопка — копирует весь снимок + последние 200 строк логов в clipboard. Можно вставить в Telegram / заметки / любое поле и переслать.

С этой инфраструктурой Native Explorer заменяет собой `adb logcat` для всех практических целей. Когда ADB всё-таки заведётся, обычные `logcat -s BydNativePlugin` тоже работают параллельно — мы пишем в оба канала.

## Что в патче

Полное содержимое архива `v0.1.27_native_api_scaffold.zip`:

```
android/app/src/main/AndroidManifest.xml                  (modified — +25 BYDAUTO permissions + queries)
android/app/src/main/kotlin/com/bz5companion/bz5_companion/
  MainActivity.kt                                          (modified — регистрация BydNativePlugin)
  BydNativePlugin.kt                                       (new — FlutterPlugin + Method/EventChannel)
  BydCarPropertyClient.kt                                  (new — raw IBinder.transact ICarPropertyService)
  BydVinDetector.kt                                        (new — reflection wrapper)
  BydDiagSocket.kt                                         (new — LocalSocket diag_socket_channel)
  BydPermissions.kt                                        (new — permission catalog + reporter)
  BydReflection.kt                                         (new — cached reflection helpers)
  BydLogger.kt                                             (new — in-app log ring buffer)
lib/services/
  data_source.dart                                         (new — abstract VehicleDataSource)
  native_car_channel.dart                                  (new — Dart обёртка над plugin)
  native_detector.dart                                     (new — ChangeNotifier isOnHeadUnit)
lib/screens/wide/
  head_unit_scaffold.dart                                  (modified — +5й destination "Native API")
  native_explorer_wide.dart                                (new — debug UI с log tail)
docs/
  BZ5_NATIVE_API_RECON.md                                  (new — recon отчёт)
  bz5_feature_catalog.csv                                  (new — 10016 feature IDs)
```

## Сборка через GitHub Actions

Существующий workflow (`build.yml`) подхватит все новые `.kt` и `.dart` автоматически — никаких изменений в CI не нужно. Никаких новых deps в `pubspec.yaml` (всё использует уже подключённые `flutter/material`, `flutter/services`, `flutter/foundation`, `provider`).

Команды:

```bash
cd ~/Downloads/bz5-companion
unzip -o ~/Downloads/BZ5/Companion/v0.1.27_native_api_scaffold.zip -d ./
grep "^version:" pubspec.yaml      # → 0.1.26+11 (НЕ бампим — scaffold-only, нет runtime изменений)
git status                          # должны быть:
                                    #   modified: android/app/src/main/AndroidManifest.xml
                                    #   modified: android/app/src/main/kotlin/.../MainActivity.kt
                                    #   modified: lib/screens/wide/head_unit_scaffold.dart
                                    #   new file: ~12 untracked под docs/, lib/services/*native*,
                                    #             lib/screens/wide/native_explorer_wide.dart,
                                    #             android/.../kotlin/Byd*.kt
git add -A
git commit -m "..."                 # текст commit message — см. в конце INTEGRATION.md
git push                            # GitHub Actions запускает сборку
```

После пуша CI выдаст APK как обычно. Скачивай артефакт со страницы Actions (или из релиза, если build.yml делает релиз) и переноси на машину одним из методов ниже.

## Установка APK на head unit без ADB

Без USB-debugging есть три практических пути. По убыванию надёжности для BZ5:

### Метод A — USB flash drive + Toyota launcher Проводник

1. Скопировать APK на USB-флешку (FAT32 рекомендую).
2. Воткнуть в USB-порт головы.
3. Открыть Toyota launcher → "Проводник" (file manager — тот же, что мы используем для просмотра экспортов трипов).
4. Найти `.apk` файл на флешке.
5. Тапнуть → запрос на установку из неизвестных источников → разрешить для Проводника (если первый раз).
6. Установить. Если уже стоит — будет диалог "обновить?" — да.

### Метод B — через облачное хранилище

1. Загрузить APK в Яндекс.Диск / Google Drive / Telegram saved messages.
2. На головы открыть соответствующее приложение (если установлено) или браузер.
3. Скачать APK на головы (обычно попадает в `/storage/emulated/0/Download/`).
4. Открыть тот же Проводник → Download → тапнуть APK → установить.

### Метод C — Bluetooth file transfer

Если телефон поддерживает Bluetooth Object Push, можно отправить APK с телефона на голову через Bluetooth → файл попадает в `/storage/emulated/0/Bluetooth/`. Дальше как в методе A.

Если ничего не работает — значит на машине вырезаны "Install from unknown sources" возможности. Тогда APK можно подписывать с тем же ключом, что используется для системных приложений (бывает доступно в engineering builds через "Settings → About → Build number ×7" пасхалку), но это уже другая задача.

## Тестирование без ADB — пошаговый план

После установки и запуска приложения:

### Шаг 1 — Открыть Native API экран

В HeadUnitScaffold появился 5-й destination "Native API" (иконка bug_report). Тапни.

**Ожидаемое содержимое на head unit'е BZ5:**
- Status card: `Detected: yes`, `Head unit: yes`, `VIN: LCO4F1A60RC...` (17 символов)
- Environment card: `carserver installed ✓`, `provider resolves ✓`, `framework present ✓`
- Permissions card: список из 24 BYDAUTO_*; часть зелёная (granted), часть оранжевая (declared но не granted)
- Logs card снизу: появляются записи `I/BydCarPropertyClient: ICarPropertyService connected via content://...`

**Ожидаемое содержимое на телефоне** (вне машины):
- Status: `Detected: yes`, `Head unit: no`, `VIN: —`
- Environment: всё ✗ (carserver не установлен — это нормально)
- Permissions card: все серые (системе пофиг на BYDAUTO_*)
- Logs: пусто или только `I/BydNativePlugin: BydNativePlugin attached`

Если ты на машине и видишь `Head unit: no` → нажми **VIN refresh (fresh)**. Если всё равно no — открой Logs снизу, ищи строки `W/BydVinDetector: VIN read failed: ...`. Текст ошибки скажет почему.

### Шаг 2 — Грантовать BYDAUTO_* permissions

Permissions card покажет какие из 24 BYDAUTO_* permissions не granted. Тапни **Open App Settings** — откроется системный Settings → App info → BZ5 Companion. Зайди в Permissions, найди раздел "Дополнительные разрешения" или подобный, и грантуй BYDAUTO_*. На BYD/BZ5 firmware'е они должны появиться как доступные пункты (это dangerous-уровень, выдаются runtime).

Если в Settings нет такого раздела или BYDAUTO_* там не появились → значит system либо не знает об этих permissions (тогда они автоматически granted, всё ок), либо они signature-level и нужна system подпись (тогда без engineering build не обойтись).

Вернись в приложение → нажми **Re-check perms**. Должны загореться зелёные значки.

### Шаг 3 — Probe feature ID

Сначала проверь что ICarPropertyService реально отвечает:

1. Введи `0x99002B0A` (TEST_CHECK_SHIPPING_INFORMATION — известный test feature). Нажми **Config**.
2. В result-блоке должно появиться `[{propertyKey: ..., propertyId: 0x99002B0A, dataType: ..., readPermission: ...}]`.
3. Если получил `error: PROPERTY_CONFIG_ERROR` или похожее — открой Logs, должны быть строки от `BydCarPropertyClient`. Самая частая причина: provider не нашёлся → значит `<queries>` блок в AndroidManifest не сработал, или сам провайдер на firmware'е называется иначе. Скопируй логи (кнопка copy в шапке Logs) и вышли.

Затем попробуй realtime read:

1. Введи featureID из catalog (например один из `interfaceName=POWER` или `INSTRUMENT`).
2. Нажми **Get** — должно быть `GET 0x... → {name: 0x..., ok: true, value: <число>, type: <Java-class>}`.
3. Нажми **Subscribe** — featureID добавится в "Active subscriptions" блок справа, и каждое событие будет видно в Logs.

### Шаг 4 — Map featureID → semantics

Это главная работа Native Explorer'а. На стоянке:
- SOC: стабильное значение 0..100 (или 0..10000 если scale ×100). `interfaceName=POWER` или `ENERGY`.
- Speed: 0. `interfaceName=SPEED`.
- HV voltage: ~350-400V (или ~14000-16000 если scale 0.025V/unit). `ENERGY` или `POWER`.
- 12V voltage: ~12-14V (или ~120-140 если ×10).
- Pack current: меняется при включении фар (+5-10A). `ENERGY`.

`docs/bz5_feature_catalog.csv` (10016 строк) — фильтруй по interfaceName, пробуй featureID, отмечай в своей таблице. Когда найдёшь SOC/speed/voltage/current — это и есть исходные данные для следующей итерации (NativeCarDataSource).

### Шаг 5 — DTC snapshot

В Status card → **DTC snapshot**. Должен прийти список диагностических кодов (даже если 0 строк — это success). Если падает с error — обычно это SELinux denial на user-build'е. К сожалению, без ADB / `dmesg | grep avc` это не диагностировать. Логи приложения покажут `W/BydDiagSocket: ...` но без подробностей.

DTC channel не критичен для первой итерации — пропускай этот шаг если не работает.

### Шаг 6 — Export diagnostics

Когда что-то идёт не так — Status card → **Copy diagnostics**. Это копирует в clipboard:

```
=== BZ5 Companion native diagnostics ===
Captured: 2026-05-21T...
--- environment ---
  carServerInstalled: true
  providerResolves: true
  ...
--- detector ---
  isOnHeadUnit: true
  vin: LCO4...
--- permissions (24) ---
  G  android.permission.BYDAUTO_POWER_COMMON
  D  android.permission.BYDAUTO_CHARGING_GET
  ?  android.permission.BYDAUTO_BIGDATA_COMMON
  ...
--- recent logs (47) ---
  10:23:01.234 I/BydNativePlugin: BydNativePlugin attached
  10:23:01.456 I/BydCarPropertyClient: ICarPropertyService connected via content://...
  10:23:15.789 W/BydCarPropertyClient: Unknown response typeName='com.byd.Foo'
      at com.byd.car.property.Response.readFromParcel(Response.java:...)
      ...
```

Открой Telegram / Заметки / любое поле ввода → долгий тап → "Вставить". Получишь весь снимок состояния в текстовом виде. Пришли мне — пойму что происходит.

## Известные проблемы и обходные пути

| Симптом в Native Explorer | Что это значит | Что делать |
|---|---|---|
| Status: `Head unit: no`, Environment: framework absent | Не head-unit (или Toyota убрала BYDAutoBodyworkDevice из framework jar) | Если ты на машине и видишь это — Copy diagnostics, пришли. На телефоне это норма |
| Environment: `provider resolves ✗` | `<queries>` блок в manifest не работает или carserver authority другой | Проверь что в AndroidManifest есть `<queries><package android:name="com.byd.car.server"/>`; если есть — может быть SELinux. Copy diagnostics |
| Permissions: все Declared (оранжевые), ни одной Granted | Не нажал Open App Settings, или в Settings нет BYDAUTO_* раздела | Перейти в Settings вручную: Apps → BZ5 Companion → Permissions. Если их там нет — на firmware'е они signature-level, без system подписи не получим |
| Probe Config: `error: PROPERTY_CONFIG_ERROR` | Bootstrap или TX code mismatch | Copy diagnostics, в Logs будет stack trace |
| Probe Get: `ok: false, code: 5 (UNAVAILABLE)` | Permission denied конкретно для этого feature | Description в response поможет — Logs покажет имя permission'а |
| Subscribe: события не приходят, но Get работает | Listener token не совпадает или TX code | Copy diagnostics — в Logs `W/BydCarPropertyClient: listener decode failed for ...` |
| Все Get'ы возвращают `value: null, type: null` | Wire format не совпадает с тем что carserver пишет | Это значит BYD переделал Parcelable. Copy diagnostics + featureID который пробовал |
| Native Explorer вообще не открывается / падает на старте | Скорее всего ошибка в Dart — открой logcat в более старой версии Logcat View, или используй другой APK (debug build с печать stacktrace в overlay) | Не должно случиться — bracket-balance в Dart проверен. Но если падает — `flutter run` через локальную сборку даст stacktrace |

## Что ДЕЛАТЬ если ADB всё-таки заведётся

Все скрипты из старой версии INTEGRATION.md остаются валидными:

```bash
adb logcat -s BydNativePlugin:V BydCarPropertyClient:V BydDiagSocket:V BydVinDetector:V
adb shell pm grant com.bz5companion.bz5_companion android.permission.BYDAUTO_POWER_COMMON
adb shell content query --uri content://com.byd.car.server.provider.CarServiceProvider \
                        --projection com.byd.car.property.ICarPropertyService
adb shell ps -A | grep car.server
adb shell dmesg | tail -50 | grep -i avc      # SELinux denials (только для DTC issues)
```

С ADB всё проще, но всё что я добавил в этой версии продолжает работать параллельно — `BydLogger` пишет и в logcat, и в ring buffer.

## Phase 2 (deferred, v0.1.28+)

После того как featureID → semantics маппинг сделан:

1. `lib/services/native_car_data_source.dart` — реализация `VehicleDataSource` поверх `NativeCarChannel`.
2. `lib/services/ble_obd_data_source.dart` — обёртка над `ConnectionService` (минимальный адаптер).
3. `head_unit_scaffold.dart` → выбор source через `NativeDetector.isOnHeadUnit`.
4. Existing wide screens (charging_view_wide, dashboard_wide и т.д.) переписать на `VehicleDataSource` API.

Это отдельные коммиты, не scaffold-работа.
