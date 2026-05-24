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

**Цель**: как можно короче, но **раскрывая суть** изменений. Пользователь читает `git log` глазами, не хочет скроллить через 150-строчные простыни на каждом патче. Структура:

```
<one-line summary: версия + одно предложение что и зачем>

<2-5 строк контекста: почему меняем, корневая причина или цель>

<техдетали bullet'ами: каждый изменённый файл + одна фраза что в нём>

<что НЕ тронуто — одна строка если нетривиально (например "BLE flow, Drift schema — не тронуто")>

<регрессия — одна строка если что-то проверял ("brace balance, pubspec parity, 7 auth scenarios — pass")>
```

**Ориентир по длине**: 10-30 строк типично, до ~50 если патч действительно архитектурный. **Не растягивай искусственно** — нет ничего полезного в пересказе кода, который читатель и так увидит в diff'е.

**Чего НЕ делать**:
- Не дублируй информацию из CLAUDE.md (например "per CLAUDE.md rule X" — пользователь сам знает свои правила).
- Не пересказывай diff построчно — git это делает лучше.
- Не пиши "POST-DELIVERY VERIFICATION" с 10 пунктами что user'у проверять — это inline в чате после патча, не в коммите.
- Не пиши истории про другие версии ("v0.1.29+5 had X, now we have Y") — для этого есть CLAUDE.md patch history table.

**Что обязательно**:
- Версия в первой строке.
- Корневая причина / цель — почему этот патч существует.
- Каждый изменённый файл упомянут.
- Если трогали protected file (с разрешения пользователя) — отметить явно.

**Язык**: английский (см. "Язык общения" в начале). Технические идентификаторы НЕ оборачивай в backticks (bash их съест) — просто `BydCarPropertyClient` plain.

**Хороший пример** (краткость через структуру bullet'ов, не через жертвование сутью):

```
v0.1.29+10 hotfix: add INTERNET permission for cloud sync

CloudSyncService (added v0.1.28+1) couldn't make any HTTPS calls —
AndroidManifest was missing INTERNET permission. Symptom: errno=7
host lookup failed. Field-discovered when owner first tried setup
flow on head unit; previously unexercised path.

Changes:
- AndroidManifest.xml: added INTERNET + ACCESS_NETWORK_STATE
- pubspec.yaml + cloud_sync_service.dart: version 0.1.29+10
- CLAUDE.md: new pre-flight section on permission ↔ feature parity

Not touched: Dart code, BLE flow, Drift schema.
Regression: XML balance, version triple-match, parity check — pass.
```

## Регрессионное тестирование — обязательно перед доставкой

**Основной инструмент с v0.1.29+14**: `python3 tools/check_repo.py` из корня репо. 7 проверок, exit 0 = pass, 1 = fail, 2 = misconfig (запущен не из корня). Запускать **перед каждой доставкой патча** — и решать failures **внутри** того же патча, а не "временно отложить" (v0.1.29+9 показал что "временно" живёт минимум 4 версии).

Что покрывает (источник правды — сам файл `tools/check_repo.py`):

- Brace balance на всех `lib/*.dart` (catches truncated edits)
- pubspec.yaml ↔ imports parity (lesson v0.1.29+3)
- Version triple-sync pubspec / cloud_sync._readAppVersion / _kDiagVersion (lesson v0.1.29+1)
- Android permissions ↔ Flutter feature pairings (lesson v0.1.29+10)
- Null-safety guard hazard heuristic (lesson v0.1.29+5)
- BZ3 tall portrait layout math consistency (lesson v0.1.29+7, +13)
- Protected files structural sanity tripwire

**Что НЕ покрывает**: runtime behaviour, Dart type-checking (это работа `flutter analyze` + kernel snapshot в build.yml), визуальные регрессии (это поле).

Когда добавляешь новую feature — расширяй `check_repo.py` соответствующим check'ом, **не** оставляй проверку только в bash heredoc сессии. Эти heredoc'и теряются между context resets. `check_repo.py` — не теряются.

### Дополнительно если контейнер позволяет

У меня нет flutter SDK на этом контейнере (network egress ограничен). Сверх `check_repo.py` иногда полезно:

1. **Kotlinc syntax check** (через `apt-get install kotlin` — kotlin 1.3.31, старый, но синтаксически корректный код парсит). Ожидаемые false positives: trailing commas в parameter lists (Kotlin 1.4+), unresolved android.* / io.flutter.* (нет SDK в classpath). Реальные syntax errors надо вычистить.
2. **MethodChannel/EventChannel name match**: regex find в Dart и Kotlin, сравнить sets.
3. **Method dispatch consistency**: каждый `_method.invokeMethod('X')` в Dart должен соответствовать `"X" ->` в Kotlin `when (call.method)`.
4. **Plugin → support classes**: все вызовы из плагина в BydCarPropertyClient/BydVinDetector/BydDiagSocket/BydPermissions резолвятся к существующим методам.
5. **Cross-file Dart symbol resolution**: для каждого custom symbol используемого в файле — поиск его definition в imported file.
6. **AndroidManifest.xml well-formed**: `xml.etree.ElementTree.parse()`.
7. **File inventory**: перечисление ожидаемых файлов + проверка наличия каждого.

Эти проверки имеет смысл оставить в session bash heredoc — они либо требуют tools, либо специфичны для конкретного patch'а. Но general-purpose проверки **всегда** в `check_repo.py`.

### Когда Dart string-stripping регулярка ломается на Kotlin template strings

Kotlin `"foo ${bar.method()}"` содержит код внутри строки. Простое `re.sub(r'"..."', '""', t)` съест скобки из template expression и даст ложный fail на paren balance. Используй Kotlin-aware state machine (см. v0.1.27 final regression — там реализовано).

## Pre-flight: где может жить дублирующая логика (читать ПЕРЕД редактированием)

Кодовая база накопила параллельные реализации одного и того же UX-концепта в нескольких файлах без абстракции в shared widget. Когда трогаешь любую из перечисленных ниже концепций — обязательно проверь **все** места, не только то с которого начал. Пропуски здесь дорого обходятся: концепции v0.1.27+1 (M6 fallback color) и v0.1.27+2 (Pack V from cells) каждая прожили по два-три патча прежде чем накрыть все экраны (см. историю пропусков в конце секции).

Метод проверки прежде чем редактировать любой файл из `lib/screens/` или `lib/services/`:

```bash
grep -rln "<symbol_or_concept_to_change>" lib/screens/ lib/services/
```

Если grep вернул >1 файла — внимательно подумать какие правки нужны и в остальных.

### Pack V (отображение pack voltage)

Три параллельных места отображения, все должны рендерить одну и ту же primary value (сейчас `packVoltageFromCells`):

- `lib/screens/dashboard.dart` — phone dashboard, метрик-карта "Pack V"
- `lib/screens/wide/dashboard_wide.dart` — head unit Analytics tab, класс `_PackVoltageHero`
- `lib/screens/wide/driver_view_wide.dart` — head unit Driver tab, status strip строка с иконкой `Icons.bolt`

Плюс две точки записи в snapshot DB (колонка `packVoltageV`):

- `lib/services/connection.dart`, метод `_maybeWriteSnapshot` (~line 1879)
- `lib/services/connection.dart`, метод `captureSnapshot` (~line 2604)

Любое изменение источника, fallback chain, или формата — пять файлов, не один. Quick check:

```bash
grep -rn "packVoltageV\|packVoltageFromCells\|hvBusV" lib/screens/ lib/services/connection.dart
```

### Модули M1..M10 (cell-balance строки)

Две параллельные реализации widget'а с **одинаковым именем `_ModuleRow`** в разных файлах:

- `lib/screens/cells.dart` — full-width row с temp label внутри бара. Helper `_buildModuleRows` делает neighbour-fallback temp для модулей без сенсора (M6 на BZ5).
- `lib/screens/wide/dashboard_wide.dart` — узкий bar в `_ModulesListPanel`. С v0.1.29+4 имеет аналогичный neighbour-fallback inline в `build()` метод панели.

При изменении render-логики (цвет, fallback, hasTemp условие) — оба места. Quick check:

```bash
grep -rn "_ModuleRow\|hasAnyTemp\|fallbackTempC\|_buildModuleRows" lib/screens/
```

### pubspec.yaml ↔ lib/ package: imports

При добавлении `import 'package:X/...'` в любой Dart файл — пакет X **обязательно** должен появиться в `pubspec.yaml` под `dependencies:`. CI билд падает на kernel snapshot с `FileSystemException` если хоть один импорт без объявленного deps. Симптом в логе CI:

```
Error: Couldn't resolve the package 'X' in 'package:X/X.dart'.
```

CloudSyncService v0.1.28+1 пропустил `flutter_secure_storage` и `http` → три CI билда подряд (v0.1.28+1, v0.1.29+0, v0.1.29+1, v0.1.29+2) упали по этой причине, прежде чем hotfix v0.1.29+3 закрыл. **Тип ошибки не очевиден из контекста**: imports локально парсятся и анализируются обычными инструментами Dart, проблема всплывает только в CI Flutter kernel build. Поэтому в regression suite ОБЯЗАТЕЛЕН такой check:

```bash
# Все импортируемые пакеты
grep -rhE "^import 'package:[a-z][a-z0-9_]*/" lib/ \
  | sed -E "s|.*package:([^/]+)/.*|\\1|" | sort -u > /tmp/imported

# Все объявленные deps (примитивно, но работает)
awk '/^dependencies:/,/^dev_dependencies:/' pubspec.yaml \
  | grep -E "^  [a-z]" | cut -d: -f1 | tr -d ' ' | sort -u > /tmp/declared

diff /tmp/imported /tmp/declared
```

`<` в diff = используется, но не объявлен (**обязательно фиксить, CI упадёт**).
`>` в diff = объявлен, но не используется (ОК, можно почистить).

### Android permissions при работе с новыми фичами

При добавлении любой фичи которая использует системный ресурс — **проверить что соответствующее permission объявлено в `android/app/src/main/AndroidManifest.xml`**. Особенно когда это **новый класс ресурса** (раньше приложение не делало сетевых запросов и не объявляло `INTERNET`; добавили CloudSyncService — а permission забыли).

Симптом отсутствующего permission **не вылавливается ни Dart analyzer'ом, ни CI'ем** — приложение собирается чисто, ставится без ошибок, и падает только в момент когда соответствующий syscall реально вызывается. Самые "тихие" примеры:

- `INTERNET` отсутствует → `Failed host lookup ... errno=7 No address associated with hostname`. DNS resolver работает как stub. Любые `package:http` запросы упадут с SocketException.
- `ACCESS_NETWORK_STATE` отсутствует → `Connectivity.checkConnectivity()` либо кидает, либо возвращает unreliable значение.
- `BLUETOOTH_CONNECT` (Android 12+) отсутствует → `flutter_blue_plus` connect() кидает SecurityException только на API 31+.
- `FOREGROUND_SERVICE` отсутствует → app silently killed при попытке startForegroundService.
- `POST_NOTIFICATIONS` (Android 13+) отсутствует → системные уведомления не показываются и не кидают error.

Quick check при добавлении любой фичи которая делает что-то "новое":

```bash
# Все permissions объявлены сейчас:
grep "uses-permission" android/app/src/main/AndroidManifest.xml \
  | sed -E 's|.*name="([^"]+)".*|\1|'
```

Сопоставить с тем что новая фича использует — если networking, проверить `INTERNET`; если background sync — проверить `WAKE_LOCK` и (опц.) `FOREGROUND_SERVICE`; если новый sensor — проверить соответствующий dangerous permission. Список Android permissions: https://developer.android.com/reference/android/Manifest.permission

История пропусков: v0.1.28+1 ввёл CloudSyncService с HTTPS через `package:http`, но `INTERNET` permission не добавили. APK собирался и ставился без проблем 9 версий подряд; фактически network-flow не тестировался до v0.1.29+9 когда владелец впервые открыл setup dialog → мгновенный `errno=7`. Hotfix v0.1.29+10 добавил `INTERNET` и `ACCESS_NETWORK_STATE`.

### Версии и pubspec

При бампе версии трогать **два** места:

- `pubspec.yaml` строка `version: 0.1.X+Y`
- `lib/services/cloud_sync_service.dart` метод `_readAppVersion()` — hardcoded string

Иначе bridge heartbeat репортит устаревшую версию (косметический баг, но засоряет admin UI). v0.1.29+1 делали без bump'а cloud_sync, оно отрепортилось как 0.1.28+1 → задним числом увидели в v0.1.29+2. Когда package_info_plus добавим — оба места можно будет схлопнуть в одно.

### Dart null safety и type promotion при правке guard-переменных

Dart 3 flow analyzer промоутит nullable-локалы через final-bound boolean guards:

```dart
final temp = something.maybeNull;       // double?
final hasTemp = temp != null;
if (hasTemp) {
  temp.someMethod();                    // ← Dart знает temp non-null, ОК
}
```

Но **семантика promotion привязана к именно тому identifier'у который тестировался**. Если ты переопределяешь guard на ДРУГУЮ переменную — promotion слетает для старой:

```dart
// БЫЛО:
final hasTemp = module.hasAnyTemp && temp != null;
// промоутит temp внутри if (hasTemp)

// СТАЛО (после рефакторинга для fallback):
final tempForColor = temp ?? fallbackTempC;
final hasTemp = tempForColor != null;
// теперь промоутит tempForColor, НО НЕ temp.
// Downstream `if (hasTemp) { temp.toStringAsFixed(...) }` ломается:
//   "Operator cannot be called on 'double?' because it is potentially null"
```

`dart analyze` локально нет в этой среде, и CI ловит это только на kernel snapshot этапе (после ~3 минут установки Android SDK), что делает цикл feedback'а **очень дорогим**.

Чек-лист **обязательно** перед коммитом любого изменения guard-локала (`hasX = ... != null` или подобное):

1. Найди ВСЕ usages этого guard внутри функции:
   ```bash
   grep -nE "if \(hasTemp\b|hasTemp \?|\?\? hasTemp" lib/screens/wide/dashboard_wide.dart
   ```
2. Для каждого блока `if (guard) { ... }` или ternary `guard ? thenBranch : elseBranch` — посмотри какие nullable-локалы там используются.
3. Если используется локал X который **раньше** промоутился через guard (потому что guard был `X != null` или содержал `X != null`), а **теперь** уже нет — нужен либо явный `if (X != null)` внутри ветки, либо отдельный guard `hasX = X != null`, либо `X!` если уверен что не null.

История пропусков: v0.1.29+4 поменял `hasTemp` с `module.hasAnyTemp && temp != null` на `tempForColor != null`. Code downstream (text label на linе 1216-1228 dashboard_wide.dart) использовал `temp` непосредственно — упал в CI build #76. Хотфикс v0.1.29+5 заменил `hasTemp` на `temp != null` именно в text label (color/border остаются на `hasTemp`, потому что им нужен promotion на `tempForColor`).

### История пропусков (чтобы не повторять)

| Концепция | Pattern пропусков | Окончательно закрыт |
|---|---|---|
| M6 neighbour-fallback color | v0.1.27+1 сделал только cells.dart; Analytics tab остался с `Colors.transparent` ещё на 2 минорных версии | v0.1.29+4 |
| Pack V → packVoltageFromCells | v0.1.27+2 сделал только Analytics `_PackVoltageHero`; phone dashboard забыт (v0.1.29+2), Driver wide забыт (v0.1.29+4). Snapshot column полтора месяца писала 740/0x0022 platform constant (~450V) — фикс v0.1.29+2 | v0.1.29+4 |
| CloudSync deps в pubspec | v0.1.28+1 добавил два import'а без объявления deps; три consecutive CI failure'а до v0.1.29+3 | v0.1.29+3 |
| Dart type promotion при смене guard | v0.1.29+4 переопределил `hasTemp` на проверку другой переменной; downstream `temp.toStringAsFixed` слетел; CI build #76 упал на kernel snapshot | v0.1.29+5 |
| BZ3 layout threshold (Android density bucket) | v0.1.29+1 рассчитал logical dp от маркетинговых PPI (172/160=1.075); реальность Android pins hdpi=1.5 → BZ3 720×1106dp; пороги не сработали 2 версии | v0.1.29+7 |
| Дублирование widgets между phone и wide layouts | v0.1.29+1 создал собственный `_TallDriverSection` в dashboard.dart вместо переиспользования `_TripMetricsPanel` из driver_view_wide.dart; v0.1.29+8 пришлось extract в shared `lib/widgets/driver_panels.dart` чтобы убрать drift | v0.1.29+8 (через shared widgets pattern) |
| Android permissions (INTERNET / NETWORK_STATE) | v0.1.28+1 добавил CloudSyncService с HTTP клиентом но забыл `<uses-permission android:name="android.permission.INTERNET">` в AndroidManifest. Сетевой stack возвращает stub resolver → `errno=7 host lookup failed` на любой запрос. Не проявлялось 2 версии потому что владелец не пробовал boevoy setup flow; вылезло сразу как открыл диалог | v0.1.29+10 |
| cloud_sync `_readAppVersion()` hardcoded | sync с pubspec руками каждый bump; пропуски v0.1.29+1 не заметили | TBD когда добавим package_info_plus |

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
- ⚠️ Файлы `connection.dart`, `database.dart`, `elm327_ble.dart` — protected. **Если трогать их разумно и необходимо для решения задачи, СПРОСИ у пользователя разрешения явно** ("Для X нужно тронуть connection.dart, конкретно метод Y — можно?"). Не игнорируй задачу молча и не предлагай worse solution только чтобы их обойти. Пользователь либо разрешит, либо предложит альтернативу. По умолчанию (без спроса) — не трогать.
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
| 0.1.29+16  | BZ3 layout fix per field feedback: (1) Между двух строк TripMetricsPanel было наложение — `SizedBox(height)` 130 → 200, теперь header + row1 + divider + row2 + cost row помещаются без overflow. (2) Grid 3-col cards были слишком ужаты (50dp при aspect 4.5, "слишком узко" по словам BZ3 user) → aspect 4.5 → 3.0, теперь карточки 74.7 dp. (3) При новой высоте compact mode `_MetricCard` не триггерится (74.7 > 70 threshold) — карточки рендерятся как полноценный phone-style Column layout. Заодно `check_repo.py` BZ3 layout math check переписан: вместо "обязательно compact mode" — "card height в range 40-100dp, compact опционален". cloud_sync `_readAppVersion` → 0.1.29+16. |
| 0.1.29+15  | P1.1 Турн A — BridgeDiagService scaffold + long-poll loop (Plane A per CLIENT_API.md §7). Новый файл `lib/services/bridge_diag_service.dart` (~310 строк, ChangeNotifier). Long-poll `GET /v1/commands/next?wait=30` цикл, статусы (disabled/notRegistered/polling/executing/error/authFailed), 3-strike auth counter (как у CloudSync), 5s backoff на network errors, 401 transient → AuthException eventually. Команды от сервера сейчас все отклоняются с `{ok:false, error_kind:"unsupported"}` (Turn B добавит BLE handlers, Turn C — native). Settings UI: Bridge diagnostic card с toggle + статистикой. Токен и base URL шарятся с CloudSyncService через те же SharedPreferences/secure storage keys (read-only — CloudSync владелец). После успешного `_showCloudSetupDialog` — `refreshTokenFromSharedStorage()` для BridgeDiag. main.dart получил четвёртый provider. cloud_sync `_readAppVersion` → 0.1.29+15. |
| 0.1.29+14  | Добавлен `tools/check_repo.py` — формализация регрессионного suite'а как файл репо (переживёт context resets). 7 проверок: brace balance на всех `lib/*.dart`, pubspec ↔ imports parity, version triple-sync (pubspec / cloud_sync / _kDiagVersion), Android permissions ↔ feature pairings, null-safety guard hazard heuristic (`hasX = Y != null` → потеря промоушна Y вниз по коду), BZ3 layout math (детектор thresholds + aspect ratio + compact threshold consistency), structural sanity для protected files. Exit 0/1/2. Запуск: `python3 tools/check_repo.py` из корня репо. Скрипт **немедленно нашёл** version drift: `_kDiagVersion='v0.1.29+8'` в dashboard.dart при pubspec=0.1.29+13 — попутно исправлен → `_kDiagVersion='v0.1.29+14'`. cloud_sync `_readAppVersion` → 0.1.29+14. |
| 0.1.29+13  | BZ3 layout polish per field feedback: (1) TripMetricsPanel compact font bumps — labelFontSize 9→11, unitFontSize 11→13 (BZ3 user сообщил "очень мелкий шрифт"). (2) `_GridCards` childAspectRatio для 3-col grid 1.3 → 2.2 — карточки стали значительно шире чем выше, экономия ~30dp по высоте. (3) `_MetricCard` через `LayoutBuilder` авто-детектит compact (maxHeight < 60) → переключает padding 12→`(8,5)`, valueFontSize 24→20, labelFontSize 10→9, iconSize 18→14, убирает `Spacer()` (используется `MainAxisAlignment.spaceBetween`). Phone (2-col, maxHeight ~80-100) — байт-в-байт как раньше. Должно убрать вертикальную прокрутку на BZ3 tall. cloud_sync `_readAppVersion` → 0.1.29+13. |
| 0.1.29+12  | Отключён lint workflow — `.github/workflows/lint.yml` теперь только `workflow_dispatch` (manual trigger), не fires автоматически на push/PR. Reason: слишком много pre-existing info/warning'ов в репо (deprecated_member_use, prefer_const_constructors, unused_field в connection.dart, etc.) перевешивали сигнал. Реальные type errors всё равно ловит build.yml на kernel snapshot — медленнее (~3 мин vs ~30 сек) но без шума. cloud_sync `_readAppVersion` → 0.1.29+12. |
| 0.1.29+11  | Hotfix lint.yml: добавлен `dart run build_runner build --delete-conflicting-outputs` step (мирор с build.yml). Без него Drift codegen не запускался → 200+ `Undefined name 'trips'`/`Undefined class 'Trip'` errors на CI. Заодно: убраны 2 избыточных `import 'dart:ui'` (FontFeature реэкспортируется через material.dart) в dashboard.dart и driver_panels.dart. test/widget_test.dart заменён пустым stub'ом (auto-scaffolded от `flutter create` ссылался на несуществующий `MyApp` класс — `creation_with_non_type` error). cloud_sync `_readAppVersion` → 0.1.29+11. |
| 0.1.29+10  | Hotfix: добавлены `INTERNET` и `ACCESS_NETWORK_STATE` permissions в `AndroidManifest.xml`. Без них Dart http client кидал `SocketException: Failed host lookup ... errno=7` на любой сетевой запрос — DNS не резолвился потому что Android networking stack для приложений без `INTERNET` отдаёт stub resolver. CloudSyncService с v0.1.28+1 был фактически неработоспособен (никто не пробовал boevoy setup flow). Обнаружено когда пользователь впервые ставил cloud backup на head unit. cloud_sync `_readAppVersion` → 0.1.29+10. |
| 0.1.29+9   | CloudSyncService Phase 3 hardening per CLIENT_API.md §1+§8: одиночный 401 больше не убивает токен — счётчик `_consecutiveAuthFailures` в памяти, throw `_TransientAuthException` пока <3 (soft error, не trip), `_AuthException` (permanent → wipe token, stop timers) только при ≥3 подряд ИЛИ 409 already_revoked. Любой 2xx сбрасывает счётчик. 408/429/5xx получают exponential backoff 5/15/45/120s внутри `_postIngest` (4 retry'я), потом `_RetryableException` который в syncOnce записывает soft error без wipe'а. Retry-After header (если сервер пришлёт) honored с cap 5min. Только один файл изменён. |
| 0.1.29+8   | BZ3 tall portrait dashboard перепроектирован: Speed/Status strip + компактная SoC card в top row (3:2), полная TripMetricsPanel (6 cells + TRIP COST) под parking pawl, грид 6 cells (SOH/Battery/PackV/Odometer/PDU1/PDU2) — без Cycles/Gear/Speed (Gear переехал в SoC badge), Calibration card убран. Подход: извлечены `SpeedAndStatusStrip`, `TripMetricsPanel`, `TripCell`, `consumptionColor` из `driver_view_wide.dart` в новый `lib/widgets/driver_panels.dart` как public widgets с параметром `compact: bool`. Driver wide использует default (full size); dashboard на tall — `compact: true`. Phone layout НЕ изменён. cloud_sync `_readAppVersion` → 0.1.29+8. |
| 0.1.29+7   | BZ3 tall portrait threshold переопределён под реальные размеры (полученные через v0.1.29+6 diagnostic). Было `height > 1400 && width > 700` (ожидали dpr=1.075); реальность — Android pins hdpi (dpr=1.5), BZ3 рапортует `720 × 1106 dp`. Новый порог `height >= 1000 && width >= 720`. Phones не проходят isWide, BZ5 портретный не доходит до этого кода. `_LayoutDiagnostic` остался — теперь скрыт на phones (`shortestSide < 600`), показывается только когда head-unit-class экран не triggers tall layout. Внутри diagnostic'а пороги синхронизированы с detector'ом. cloud_sync → 0.1.29+7. |
| 0.1.29+6   | Diagnostic: BZ3 field test показал что tall portrait threshold (`height > 1400 && width > 700`) не срабатывает в проде, причина неясна. В `_PhysicsModelCard` добавлен `_LayoutDiagnostic` widget — рендерится только когда tall layout НЕ активен, показывает `mq.size`, `devicePixelRatio`, `mq.padding`, `mq.viewInsets`, и результат проверки threshold'а. После скриншота от BZ3 пользователя — точечно поправим threshold в следующем патче. Threshold логика не тронута. Также: новый `.github/workflows/lint.yml` — `flutter analyze` без assembleRelease, ~30 сек feedback вместо 3 мин, ловит type errors класса v0.1.29+5. cloud_sync `_readAppVersion` → 0.1.29+6. |
| 0.1.29+5   | Hotfix: null safety regression от v0.1.29+4. `_ModuleRow` text label на dashboard_wide.dart использовал `temp` напрямую внутри ветки `if (hasTemp)`; после смены `hasTemp` на `tempForColor != null` Dart перестал промоутить `temp` в non-null → kernel snapshot fail на CI #76. Условие text label теперь `temp != null` (только своё измерение модуля); color/border остаются на `hasTemp` (включают fallback). Semantics: M6 показывает "no temp" в text, но bar заливается цветом M5 — идентично cells.dart. cloud_sync `_readAppVersion` → 0.1.29+5. |
| 0.1.29+4   | Driver tab Pack V переключён на packVoltageFromCells (был на hvBusV — показывал 400.8V вместо 458.4V). dashboard_wide `_ModulesListPanel` получил neighbour-fallback temp для M6 — был с `Colors.transparent`, теперь рендерится цветом M5 идентично cells.dart. cloud_sync `_readAppVersion` → 0.1.29+4. |
| 0.1.29+3   | Hotfix: добавлены `flutter_secure_storage: ^9.0.0` и `http: ^1.2.0` в `pubspec.yaml` dependencies. CloudSyncService импортировал оба пакета с v0.1.28+1, но в pubspec они никогда не были — три CI билда подряд падали с `Couldn't resolve the package`. cloud_sync `_readAppVersion` → 0.1.29+3. |
| 0.1.29+2   | Phone dashboard Pack V переключён на packVoltageFromCells (был на hvBusV; синхронизирован с wide). snapshot DB column `packVoltageV` тоже теперь хранит sum-of-cells (был 740/0x0022 platform constant — все записи AC сессии 2026-05-23 содержали 450.0V). cloud_sync `_readAppVersion` → 0.1.29+2 (был 0.1.28+1 → heartbeat репортил устаревшее). |
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

### Файлы которые **не** меняем без спроса (protected, см. Антипаттерны выше)

- `lib/services/connection.dart` — спросить разрешения; только additive getter'ы по умолчанию
- `lib/services/elm327_ble.dart` — спросить разрешения
- `lib/data/database.dart` (Drift schema) — спросить разрешения (любая правка → миграция)
- Любой `.g.dart` (auto-generated, никогда руками)

### AndroidManifest.xml — раньше был "не трогать", теперь не protected

С v0.1.29+10 manifest **можно** редактировать (там обнаружилось что `INTERNET` permission отсутствует с v0.1.28+1 и cloud sync не работал). Перед редактированием — предупредить пользователя в commit message что если у него были локальные кастомные правки, надо проверить `git diff HEAD~1`.



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
