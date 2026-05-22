# CLAUDE.md — правила работы над bz5-companion

Этот файл — память для Claude. Прочитать **до** того как что-то делать в этом репозитории. Здесь зафиксированы соглашения о доставке патчей, формате коммитов, регрессии и среде, чтобы они не терялись при сбросе контекстного окна.

## Язык общения

- **С пользователем — по-русски.** Все ответы в чате, инструкции, объяснения, вопросы.
- **Коммит-сообщения — по-английски.** Полностью, включая body и bullet'ы. Идентификаторы в коде (имена классов/методов/файлов) — английские в любом случае.
- **Код, комментарии в коде, docstrings, log сообщения — по-английски.** Это код, его читают разработчики и тулинг.
- **Markdown в `docs/` — по-английски** (BZ5_NATIVE_API_RECON.md, INTEGRATION.md и т.д.), потому что они часть исходников.
- **`CLAUDE.md` (этот файл) — по-русски**, исключение: это memo для меня и пользователя, а не для внешних читателей.

Старые коммит-сообщения в репо написаны на смеси языков (русский + английский) — это исторические артефакты, исправлять их задним числом не нужно. Новые — все на английском.

## TL;DR — три ключевых факта

1. **Сборка идёт через GitHub Actions**, у пользователя нет локальной Flutter SDK. Ты не запускаешь `flutter build`, ты доставляешь zip-патч.
2. **На головном устройстве BZ5 нет ADB**. Никаких `adb logcat`, `adb shell`, `pm grant`. Вся диагностика должна быть встроена в приложение (см. `BydLogger` + Native Explorer).
3. **Подпись APK одинаковая на всех билдах** (keystore из GitHub Actions secrets). Обновление инсталлируется поверх — БЕЗ удаления, данные сохраняются.

## Пути на машине пользователя

```
~/Downloads/BZ5/Companion/                ← landing folder для патч-zip'ов, которые я доставляю
~/Downloads/bz5-companion/                ← git working directory (git clone репозитория)
```

Все мои `present_files` zip'ы пользователь скачивает в первую, распаковывает во вторую.

## Формат доставки патча

### Имя zip'а

`v<MAJOR>.<MINOR>.<PATCH>[_<SUB>]_<descriptive_name>.zip`

Примеры из истории:
- `v0.1.20_patches.zip`
- `v0.1.21.3_hotfix.zip` (sub-version для hotfix)
- `v0.1.26_11_soc_derived_charging.zip` (sub-revision feature)
- `v0.1.26_9_FULL_cumulative.zip` (если редко — кумулятивная сборка нескольких patches)
- `v0.1.27_native_api_scaffold.zip`

Используй `_` для соединения, никаких пробелов. Описательная часть — 2-4 слова, что было сделано.

### Содержимое zip'а

Только **изменённые и новые файлы**, пути от корня репозитория. НЕ копируй немодифицированные файлы — они забьют `git status` шумом. НЕ создавай подпапку `patch/` внутри zip'а — пути должны раскрываться прямо в репо.

Хороший пример (v0.1.26+11):
```
lib/services/connection.dart           ← modified
lib/screens/wide/charging_view_wide.dart  ← modified
pubspec.yaml                           ← modified version
```

Плохой пример: zip с подпапкой `bz5_companion_native_scaffold/` или зеркалом всего lib/.

### Версионирование pubspec.yaml

```yaml
version: 0.1.26+11
```

Формат: `<semver>+<buildnum>`. Бампи:
- **Сделал feature/release** → бампи и semver, и buildnum.
- **Hotfix без feature** → бампи только PATCH или SUB.
- **Scaffold / infra / только новые файлы без runtime эффекта для существующих пользователей** → НЕ бампи. Зафиксируй в commit message что версия намеренно не бампится.

CI вычисляет финальную `versionName` сам из git history (`build.yml:36-42`), но `pubspec.yaml`'овая часть тоже отображается пользователю.

## Формат инструкций к сборке

Пользователь работает в bash на macOS. Привычный ему формат — bash блок, который копируется целиком:

```bash
cd ~/Downloads/bz5-companion
unzip -o ~/Downloads/BZ5/Companion/<file>.zip -d ./
grep "^version:" pubspec.yaml      # → 0.<X>.<Y>+<Z>  (комментарий о том, что ожидаем увидеть)
git status                          # описание ожидаемых изменений: что modified, что untracked
git add -A
git commit -m "<MULTILINE COMMIT MESSAGE>"
git push                            # GitHub Actions запускает сборку
```

Никаких локальных `flutter build` или `adb install` — это всё через CI и через ручную установку с USB-флешки (см. секцию "Установка без ADB" ниже).

### Если в bash-блоке нужны экранирующие символы

В `git commit -m "..."` (двойные кавычки) переменные shell интерполируются. Если в commit-сообщении встречаются `$Foo`, `` ` ``, `\` — используй heredoc:

```bash
git commit -F - <<'COMMITMSG'
...
COMMITMSG
```

Одинарные кавычки вокруг heredoc-маркера отключают интерполяцию.

## Формат commit-сообщения

Подробный, многострочный. Структура:

```
<one-line summary: вер + лаконичное "что и зачем">

<абзац контекста: почему меняем, что было не так / какая фича добавляется>

<техдетали: точные пути файлов, что именно изменилось в каждом,
конкретные числа/факты, ссылки на где это в коде/recon доках>

<что НЕ тронуто: чтобы было понятно где регрессии заведомо нет>

<что осталось пендинг / deferred — следующие шаги>

<регрессионное тестирование: список того что я проверил перед отправкой>
```

Длина — от 30 до 150 строк нормально. Это git log, по нему искать. Хорошие примеры — в `v0.1.26+11` (SOC-derived charging), `v0.1.27_native_api_scaffold`. **Пишутся по-английски** (см. секцию "Язык общения" в начале файла). Старые коммиты в репо на смеси языков — это исторический артефакт, исправлять не надо, новые делать на английском.

Технические идентификаторы НЕ оборачивай в backticks внутри commit message — bash их съест. Просто `BydCarPropertyClient` plain text.

### Что обязательно упомянуть

- Каждый изменённый файл + одной фразой что в нём.
- Каждый новый файл + что он делает.
- Что НЕ меняли (особенно `connection.dart`, `database.dart`, BLE flow — пользователь явно беспокоится за регрессии).
- Регрессионное тестирование bullet'ами с ✅.

## Регрессионное тестирование — обязательно перед доставкой

У меня нет flutter SDK на этом контейнере (network egress ограничен). Что я делаю:

1. **Bracket/paren/brace balance** для всех Kotlin и Dart файлов через python.
2. **Kotlinc syntax check** (через `apt-get install kotlin` — кnotlin 1.3.31, старый, но синтаксически корректный код парсит). Ожидаемые false positives: trailing commas в parameter lists (Kotlin 1.4+), unresolved android.* / io.flutter.* (нет SDK в classpath). Реальные syntax errors надо вычистить.
3. **MethodChannel/EventChannel name match**: regex find в Dart и Kotlin, сравнить sets.
4. **Method dispatch consistency**: каждый `_method.invokeMethod('X')` в Dart должен соответствовать `"X" ->` в Kotlin `when (call.method)`.
5. **Plugin → support classes**: все вызовы из плагина в BydCarPropertyClient/BydVinDetector/BydDiagSocket/BydPermissions резолвятся к существующим методам.
6. **Cross-file Dart symbol resolution**: для каждого custom symbol используемого в файле — поиск его definition в imported file.
7. **AndroidManifest.xml well-formed**: `xml.etree.ElementTree.parse()`.
8. **File inventory**: перечисление ожидаемых файлов + проверка наличия каждого.

Все эти проверки должны быть в одном python-скрипте, который запускается в bash. Не делать "на глаз".

Хороший пример полного suite — в истории turn'ов v0.1.27 scaffold delivery.

### Когда Dart string-stripping регулярка ломается на Kotlin template strings

Kotlin `"foo ${bar.method()}"` содержит код внутри строки. Простое `re.sub(r'"..."', '""', t)` съест скобки из template expression и даст ложный fail на paren balance. Используй Kotlin-aware state machine (см. v0.1.27 final regression — там реализовано).

## Установка APK без ADB

В `INTEGRATION.md` (если делается feature, не релиз) или прямо в commit message — три метода в порядке надёжности:

1. **USB-флешка + Toyota Проводник** — самый надёжный для BZ5. Флешка FAT32 → USB-порт головы → file manager → тап на APK → разрешить установку из неизвестных источников.
2. **Облачное хранилище** — Яндекс.Диск/Drive/Telegram saved messages → скачать на голову → Проводник → установить.
3. **Bluetooth file transfer** — если поддерживается, отправь с телефона.

НЕ предлагай `adb install -r` — это не работает на этом железе.

## Установка приложения без потери данных

APK подписывается одним и тем же keystore во всех CI билдах (см. `build.yml:88-107`, secret `ANDROID_KEYSTORE_BASE64`). Поэтому:

- Обновление поверх → диалог "Обновить?", данные сохраняются.
- НЕ нужно `adb uninstall` / "Стереть данные" перед установкой.
- Только если подпись изменится (новый keystore secret в CI), Android откажет в установке поверх → потребуется uninstall со потерей данных. Этого избегаем.

## Структура проекта (на момент v0.1.27)

```
~/Downloads/bz5-companion/
├── android/
│   ├── app/
│   │   ├── src/main/
│   │   │   ├── AndroidManifest.xml             ← BLE perms, BYDAUTO perms, queries
│   │   │   └── kotlin/com/bz5companion/bz5_companion/
│   │   │       ├── MainActivity.kt              ← FlutterActivity + plugin registration
│   │   │       └── Byd*.kt                      ← Native API plugin (7 файлов)
│   │   └── build.gradle                        ← Flutter генерирует; CI патчит signing
│   ├── build.gradle
│   └── settings.gradle                         ← CI бампит Kotlin version до 2.1.0
├── lib/
│   ├── main.dart                               ← entry point, MaterialApp + Provider<ConnectionService>
│   ├── data/database.dart                      ← Drift schema (trips, samples, dtc)
│   ├── services/
│   │   ├── connection.dart                     ← 3519 LOC god-object: BLE+UDS+trip+charging
│   │   ├── elm327_ble.dart
│   │   ├── data_management.dart
│   │   ├── ecu_registry.dart
│   │   ├── export_service.dart
│   │   ├── data_source.dart                    ← v0.1.27: abstract VehicleDataSource
│   │   ├── native_car_channel.dart             ← v0.1.27: Dart wrapper над plugin
│   │   └── native_detector.dart                ← v0.1.27: isOnHeadUnit detector
│   ├── screens/
│   │   ├── history.dart, trip_detail.dart, live_log.dart, settings.dart
│   │   ├── live_log_results.dart, sweep.dart, sweep_results.dart
│   │   └── wide/                               ← head-unit (≥840dp) versions
│   │       ├── head_unit_scaffold.dart         ← NavigationRail с 5 destinations
│   │       ├── dashboard_wide.dart
│   │       ├── raw_data_wide.dart
│   │       ├── history_wide.dart
│   │       ├── charging_view_wide.dart
│   │       ├── settings_wide.dart
│   │       └── native_explorer_wide.dart       ← v0.1.27: debug UI + no-adb diagnostics
│   └── ...
├── pubspec.yaml                                ← version 0.1.<x>+<n>
├── build.yml                                   ← GitHub Actions workflow
└── docs/
    ├── BZ5_NATIVE_API_RECON.md                 ← BYD framework reverse engineering
    ├── INTEGRATION.md                          ← v0.1.27 install/test guide
    └── bz5_feature_catalog.csv                 ← 10016 feature IDs
```

### Запомнённые vehicle facts (из livelog сессий)

- Пакет: 65.28 kWh для базовой / 73.984 kWh для большой
- **136 cells в series** (подтверждено BMS: 790/0x0B03 = 0x88 = 136, и
  marketing math: 136 × 150 Ah × 3.2 V = 65.28 kWh точно). Старые
  упоминания "124s" в коде и handoff — **ошибка**, исправлено в
  v0.1.27+2 (packVoltageFromCells использует `_packCellCount ?? 136`).
- LFP cells, HV bus 348-361 V (scale 0.025 V/unit), cell V 3.09-3.37 V
- Мотор: 200 kW (272 hp, 330 Nm)
- 1FFD low16 fingerprint = 0x3B09 (используется в connection.dart для распознавания протокола)
- Factory consumption: 144 Wh/km (WLTP, **не реальный**; реальный
  16-18 kWh/100km — поэтому footer "@ 14.4 kWh/100km · 65.28 kWh" в
  dashboard удалён в v0.1.29+1)
- OBC efficiency ~99% на AC slow
- Pack resistance R=0.18 Ω (для HV-bus-sag power heuristic в v0.1.26+10)
- **740/0022 = 0x4650 (450 V)** — платформенная константа, **НЕ live
  pack voltage** (verified across sweeps). Не использовать как primary V.
- **791/0038 stable ~80.5** при всех state — **НЕ pack current**
  (verified DC charging 2026-05-22: const при 0-92 A). Семантика TBD.
- **740/0009 — transient ADC noise**, не charger output V (verified v0.1.24).
- **hvBus (790/0015) под DC charging показывает -83V offset** относительно
  sum-of-cells на 76 kW peak — физически невозможно, значит DID имеет
  dual semantics. Не использовать как primary V под нагрузкой.

### Запомнённые decompile findings (BYD car framework)

- **Property names = literal hex feature IDs** `"0x<HEX>"`, НЕ человекочитаемые. Парсится через `HalFeatureProvider.transformHexString2Long`. Каталог 10016 features в `docs/bz5_feature_catalog.csv`.
- **3 параллельных канала данных**:
  1. `ICarPropertyService` через BinderProvider (URI=any, projection[0]=FQCN селектор)
  2. Direct HAL через reflection на `android.hardware.bydauto.*` (BYDAutoPowerDevice, BYDAutoVehicleDataDevice etc.)
  3. Unix abstract socket `diag_socket_channel` (DTC snapshot, парсится `@`/`#` разделителями)
- **VIN detect**: `BYDAutoBodyworkDevice.getRealAutoVIN()` (fresh) / `.getAutoVIN()` (cached). ClassNotFoundException → не head-unit → fallback BLE.
- **Wire-протокол ICarPropertyService verified**: TX codes 1=setProperties, 2=getProperty, 3=getProperties, 4=getPropertyConfigs, 5=registerValueCallback (oneway), 6=unregisterValueCallback (oneway). Listener TX=1 (oneway).
- **Type tagging — Java class name строкой**, не числом: `"java.lang.Integer"`, `"[B"`, `"java.lang.Long"` и т.д.

### Что НЕ известно (требует runtime пробы на машине)

- Маппинг конкретных featureID → семантика (SOC, скорость, voltage). Каталог есть, имён в нём нет.
- Какие BYDAUTO_*_COMMON / _GET permissions реально проверяются на firmware.
- Sample rate `registerValueCallback`.
- Поведение `getProperty` для permission-denied features (code в Response.status).

Для пробы — `Native API` экран в приложении, кнопки Get/Config/Subscribe + featureID textfield.

## Среда головного устройства BZ5

- **Android 12 (API 32)** на Toyota launcher с BYD framework jar
- **Нет ADB** (с recon-этапа), пока не получили. Всё через UI и Copy diagnostics.
- **Сильный SELinux на user-build**'е, может резать `diag_socket_channel` для non-system UID.
- **`<queries>` блок обязателен** в Manifest на API 30+ для видимости пакета `com.byd.car.server`.
- **24 BYDAUTO_* permissions** объявляем (оба стиля `_COMMON` и `_GET` — firmware использует неконсистентно). Missing permissions Android игнорирует.

## CI workflow важности (build.yml)

- Step 6 `flutter create --platforms=android --org com.bz5companion --project-name bz5_companion .` — non-destructive на существующих файлах. То что лежит в `android/app/src/main/` в репо — сохранится. Создаст только missing.
- Step 7 бампит Kotlin до 2.1.0 в `settings.gradle` (зависимости требуют Kotlin 2.x metadata).
- Step 8-9 декодируют keystore из base64 secret и патчат `build.gradle` с release signing. Critical: при отсутствии любого keystore secret CI прерывается, чтобы случайно не выкатить debug-signed APK (был баг в v0.1.14.34 — выкатили дебаг, не апгрейдилось поверх).
- Build APK с `--build-number=$BUILD_NUMBER --build-name=$VERSION_NAME` где BUILD_NUMBER = `git rev-list --count HEAD`.
- APK артефакт публикуется в Actions, доступен 30 дней. На git tag — релизится через `softprops/action-gh-release@v2`.

Поэтому: после `git push` ждать ~5 минут пока CI отработает, потом скачивать APK артефакт из вкладки Actions GitHub.

## bz5-bridge — облачный backend (отдельный репо, отдельная плоскость)

С v0.1.28 у проекта есть **серверный компонент** — `bz5-bridge`,
FastAPI + Postgres сервис на VPS владельца. Не путать с
`bz5_companion`: это два **независимых** репозитория, два деплоя,
два source of truth.

### Источник правды о контракте — **публичные endpoints живой инсталляции**

```
https://carbridge.neardo.work/client-api.md   ← intent + rules + retry policy
https://carbridge.neardo.work/openapi.json    ← machine spec, FastAPI auto-gen
https://carbridge.neardo.work/docs            ← Swagger UI (для глаз)
```

**Перед тем как трогать любой клиентский код связанный с bridge'ом**
(`lib/services/cloud_sync_service.dart`, `lib/services/bridge_diag_service.dart`,
setup flow в Settings) — **обязательно** прочитать обе спеки выше.
Они auto-deploy'ятся при каждом `make deploy` на VPS; версия в
памяти / в старой переписке быстро устаревает.

Если WebFetch к этим URL'ам падает — попроси владельца проверить
статус bridge'а **до** того как делать предположения о контракте.

### Две независимые плоскости в bridge'е

Это критичный архитектурный принцип. Они НЕ должны смешиваться в
клиенте:

**Plane B — Cloud backup** (`/v1/data/*`):
- Долговечная. Трипы, snapshots, sweep runs, live-log sessions,
  feature catalog.
- Клиент: `lib/services/cloud_sync_service.dart` — singleton
  ChangeNotifier. Включается флагом `cloud_sync_enabled` в
  SharedPreferences.
- UI: блок "Cloud backup" в Settings screen.
- Что делает: периодически (1 min) пушит новые Drift-записи на
  сервер по cursor'ам. Read-only к Drift, никогда не пишет обратно.

**Plane A — Diagnostic recon** (`/v1/diag/*`, `/v1/commands/*`):
- Временная. Будет удалена когда native API калибровка завершится
  и Plane A перестанет быть нужным.
- Клиент: `lib/services/bridge_diag_service.dart` — singleton
  ChangeNotifier. Включается флагом `bridge_diag_enabled`.
- UI: только в Native Explorer screen (debug-only, скрыт за toggle).
- Что делает: long-poll к `/v1/commands/next`, исполняет команды
  через NativeCarChannel или BLE, постит результат обратно.

**Принцип не нарушать**:
- Никакого shared state между двумя сервисами.
- Никаких shared cursors, shared backoff, shared error buffers.
- Каждый имеет свой флаг в SharedPreferences.
- Каждый можно выключить независимо.
- UI каждого появляется только в своём месте (Settings vs Native
  Explorer); никогда не на основных экранах Dashboard/Driver/etc.

### Авторизация — три типа токенов

- **Setup token** — одноразовый, выдаётся владельцем человеку.
  Используется ОДИН раз в `POST /v1/setup/register-device`.
  Клиент дропает после успешной регистрации.
- **Client token** — формат `<device_id>.<secret>`. Возвращается
  register-device endpoint'ом. Хранится в `flutter_secure_storage`
  (Keystore/Keychain), **никогда не в SharedPreferences**.
  Используется для всех ingest + command channel calls.
- **Admin token** — у владельца / у Claude Code на VPS. **В app
  никогда не попадает**.

### Vehicle и device-ids — текущие константы для тестов

- `vehicle_id = 842665c4-a20b-4c6f-bc9c-ece32bf58cc8` (BYD BZ5 2024)
- `BRIDGE_DOMAIN = carbridge.neardo.work`

После register-device клиент получает device_id, дальше работает
по нему. Setup token ротируется владельцем — не хардкодить.

### CLIENT_API.md error contract memo

Эта секция отражает ПОНИМАНИЕ автора клиента на момент написания
этой строки. **При расхождении со спекой на сервере — спека на
сервере выигрывает**, обнови этот раздел или просто перечитай
WebFetch.

- 401 → markTokenBad после **3 подряд** (не первого). Это
  отступление от изначального дизайна — нужно для устойчивости
  к транзиентным сбоям nginx во время deploy. Реализовано не
  везде — проверить.
- 403 samples_disabled → запомнить в prefs `samples-rejected: true`,
  не повторять 24 часа.
- 408/429/5xx → exponential backoff 5/15/45/120 s.
- 409 already_revoked → сразу authFailed, попросить re-register.
- Idempotency через `(device_id, client_*_id)` UNIQUE с ON CONFLICT
  DO NOTHING. Повтор POST'а — безопасный no-op.

### Что НЕ делать на клиентской стороне (повтор для bridge-кода)

Это копия v2-prompt'а §4 для напоминания:

- Не трогать `connection.dart` / `elm327_ble.dart` / `database.dart`
  при работе над bridge кодом. Bridge — аддитивный слой.
- Не модифицировать существующие Drift таблицы. Bridge state
  (cursors, retry queue) живёт в SharedPreferences или новой
  таблице `bridge_outbox`, никогда inline в existing tables.
- Два независимых сервиса, не один комбинированный uploader.
- Команды от server'а выполнять serially в order received.
  Не reorder'ить.

### Что осталось как baseline для будущих сессий

- **v0.1.28+1** — CloudSyncService Phase 1 (ingest + setup). Готов
  но **ещё не интегрирован end-to-end** (ждём подтверждения 
  обновлённого error contract от server'а и patch'а с 429/409/3-401).
- **BridgeDiagService** — не начат на момент v0.1.29+1. Track 2
  в roadmap.
- **MCP-сервер** поверх admin endpoints bridge'а — anti-scope сейчас.
  Когда будет — клиентский Claude получит способность ставить
  команды через MCP вместо curl.


## Принципы кода

- **Минимальное вторжение в существующий код**. `ConnectionService` (3519 LOC) — не рефакторить. Новые feature — параллельные модули.
- **Defensive logging**. Каждая reflection вызывает BydLogger.w/e на failure. Каждый transact логирует код результата. Помогает потом разбирать "что пошло не так" без debugger'а.
- **Type safety на платформенной границе**. Все методы plugin'а возвращают `Map<String, Object?>` с известными keys; Dart адаптеры (NativeStatus.fromMap, PermissionStatus.fromMap, NativeLogEntry.fromMap) делают conversion с явными `.toString()` / `as bool?`.
- **No external state**. Plugin singleton'ы можно, но избегать глобальных mutable variables. Всё что long-lived — через ChangeNotifier и Provider.
- **Existing Dart formatting style**: 2-space indent, trailing commas в multi-line constructor args, `library;` в начале файла для документации.

## Антипаттерны (что НЕ делать)

- ❌ НЕ создавать подпапку `scaffold/` или `patch/` внутри zip — пути должны быть от корня репо.
- ❌ НЕ предлагать `adb install` / `adb logcat` / `pm grant` как primary workflow.
- ❌ НЕ бампить версию для scaffold/infra патчей.
- ❌ НЕ модифицировать `connection.dart`, `database.dart`, `elm327_ble.dart` без явной просьбы — пользователь дорожит регрессионной стабильностью BLE flow.
- ❌ НЕ ставить большие assets в Flutter `pubspec.yaml` без необходимости — CSV каталог 615 KB живёт в `docs/`, не в `assets/`.
- ❌ НЕ генерировать `.aidl` файлы для ICarPropertyService — у Response.result полиморфный type-tagged Object, AIDL stub generator такое не умеет. Используем raw `IBinder.transact()`.
- ❌ НЕ забывать о trailing commas в Kotlin — старый kotlinc на этом контейнере (1.3.31) ругается, но prod Kotlin 2.1+ принимает.

## Когда сомневаешься

- Спрашивай у пользователя путь к файлу если неуверен (lib/ vs lib/screens/wide/) — лучше уточнить, чем заоверрайтить кастомизацию.
- Если редактируешь MainActivity.kt / AndroidManifest.xml — предупреждай в commit message что если у пользователя там были кастомные правки, они потерялись, и предлагай `git diff HEAD~1` для проверки.
- Если что-то неоднозначное в decompile recon — отметь в `docs/BZ5_NATIVE_API_RECON.md` как "не верифицировано" и не клади в production код, пока пользователь не подтвердит на машине.

## Patch history at a glance — последние патчи и их суть

Когда восстанавливаешь контекст в новой сессии, эта таблица —
быстрый способ понять что недавно делали и какая логика в каком
файле живёт. Список в обратном хронологическом порядке.

| Версия     | Что сделано (одна строка) |
|------------|---------------------------|
| 0.1.29+1   | BZ3 tall portrait dashboard: conditional 3-col grid + `_TallDriverSection` под grid когда `height > 1400 && width > 700`. Удалён factory footer "@14.4 kWh/100km · 65.28 kWh" из SocCard и из Calibration card (устаревший + BZ5-specific). |
| 0.1.28+1   | CloudSyncService: новый файл `lib/services/cloud_sync_service.dart` (singleton ChangeNotifier), Plane B ingest для trips/snapshots/sweeps/livelogs/heartbeat. UI в Settings (новая секция Cloud backup с 3-шаговым setup-флоу). Added deps: `http`, `flutter_secure_storage`. **Pending**: 429 retry, 409 already_revoked, 3-consecutive-401 — ждём финальный CLIENT_API.md от bridge owner'а. |
| 0.1.27+2   | `packVoltageFromCells` getter в connection.dart — primary live pack V = avg(20 cells) × (_packCellCount ?? 136). Заменяет hvBusV (показывал -83V offset при DC charging — физически невозможно) и nominal 450V константу. **Аддитивный getter, существующие не тронуты**. Dashboard hero panel переключён на новый источник. |
| 0.1.27+1   | Trip cost UI (CostSettings ChangeNotifier + UI в Settings: cost_per_kwh + currency_symbol). Driver wide получил primary cost cell справа от "THIS TRIP #N". Trip Detail: добавлен "Total cost", удалены неработающие Peak power / Peak regen rows + italic note про HV-bus sag estimation. Cells.dart: header 'TEMP °C' → 'Δ'. M6 fallback color от соседнего модуля. |
| 0.1.26+18  | Diagnostic dump file feature: новый `lib/services/diag_dump_file.dart` пишет в `/sdcard/Download/bz5_companion_diag.md`. Toggle "Auto-append" в Dump card в Native Explorer. |

### Файлы которые накапливают изменения чаще всего

- `lib/services/connection.dart` — но **только additive getter'ы**,
  без рефакторинга existing logic
- `lib/screens/dashboard.dart` — узкий dashboard, BZ5 phone + BZ3 portrait
- `lib/screens/wide/dashboard_wide.dart` — широкий dashboard, BZ5 head unit
- `lib/screens/settings.dart` — растёт каждый patch (cost, cloud sync, etc.)
- `lib/screens/wide/driver_view_wide.dart` — Driver tab head unit

### Файлы которые **не** меняем

- `lib/services/elm327_ble.dart`
- `lib/data/database.dart` (Drift schema — никаких новых таблиц/колонок)
- `android/app/src/main/AndroidManifest.xml` (BLE+BYDAUTO perms финализированы)
- Любой `.g.dart` (auto-generated)



В этом репо до v0.1.27 в `.gitignore` была строка:

```
android/app/src/main/kotlin/
```

Она исключала ВСЁ содержимое kotlin/ директории. Причина: до native API там жил только auto-generated `MainActivity.kt` от `flutter create`, и пользователь не хотел его трекать (CI его сам регенерирует).

С v0.1.27 эта строка убрана из .gitignore (см. коммит scaffold native HAL API). Теперь все 8 файлов под `android/app/src/main/kotlin/com/bz5companion/bz5_companion/` трекаются:

- `MainActivity.kt`
- `BydNativePlugin.kt`
- `BydCarPropertyClient.kt`
- `BydDiagSocket.kt`
- `BydVinDetector.kt`
- `BydPermissions.kt`
- `BydReflection.kt`
- `BydLogger.kt`

**Что важно для будущих патчей**: при доставке любых изменений в Kotlin файлы или при добавлении новых под этим путём — никаких `git add -f` не нужно, обычный `git add -A` работает. НО если будущий пользователь (или ты в будущей сессии) внезапно увидит что Kotlin файлы не появились в `git status` после unzip патча — первым делом проверить `.gitignore` и `git check-ignore -v <file>`.

### Поведение `flutter create` в CI (build.yml:45)

`flutter create --platforms=android --org ... .` — non-destructive к существующим файлам. Если `MainActivity.kt` чекаутится из git до этого шага, Flutter его не перезапишет. Это документированное поведение Flutter SDK.

Если когда-нибудь Flutter изменит это поведение (поломает обратную совместимость) — симптом будет: после push CI собирает APK где Native Explorer не работает (потому что регистрации `BydNativePlugin` в `MainActivity.configureFlutterEngine` нет). Тогда:

1. Скачать APK из artifacts.
2. `unzip apk; cat classes.dex | strings | grep BydNativePlugin` — проверить попал ли наш код в APK.
3. Если не попал — добавить в build.yml после шага `flutter create` шаг копирования наших Kotlin файлов из репо в `android/app/src/main/kotlin/...`. Звучит абсурдно (они там уже должны быть), но если `flutter create` их затёр — это единственный способ.
