# INTEGRATION.md — мерж scaffold в bz5-companion v0.1.27

Этот scaffold добавляет **native head-unit data path** параллельно с существующим BLE-режимом. Существующий код (`ConnectionService`, BLE, UDS) НЕ трогаем — он остаётся primary для телефонов. Native режим вступает в работу только когда `NativeDetector.isOnHeadUnit == true`.

## Pre-flight

```
существующий проект:
  android/app/src/main/AndroidManifest.xml
  android/app/src/main/kotlin/com/bz5companion/bz5_companion/MainActivity.kt
  android/app/build.gradle
  lib/services/connection.dart        (3519 строк — не трогаем)
  lib/screens/wide/                   (existing wide screens — добавляем сосед)
  pubspec.yaml                        (v0.1.26+11 → ↑ до v0.1.27+12)
```

## Шаг 1 — Скопировать файлы

```
# Kotlin plugin (создаются с нуля — конфликтов не будет)
cp -r android/app/src/main/kotlin/com/bz5companion/bz5_companion/Byd*.kt \
      <PROJECT>/android/app/src/main/kotlin/com/bz5companion/bz5_companion/

# Dart side
cp lib/services/data_source.dart        <PROJECT>/lib/services/
cp lib/services/native_car_channel.dart <PROJECT>/lib/services/
cp lib/services/native_detector.dart    <PROJECT>/lib/services/

# UI
cp lib/screens/wide/native_explorer_wide.dart <PROJECT>/lib/screens/wide/

# Docs (referenced from the explorer UI for catalog import)
cp -r docs <PROJECT>/docs/native_api/
```

## Шаг 2 — Зарегистрировать плагин

В `android/app/src/main/kotlin/com/bz5companion/bz5_companion/MainActivity.kt` добавь регистрацию плагина (см. `MainActivity_example.kt` в scaffold'е):

```kotlin
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(BydNativePlugin())
}
```

## Шаг 3 — Слить AndroidManifest

Открой `AndroidManifest_additions.xml` из scaffold. Содержит:
- 17 `<uses-permission>` блоков
- `<queries>` блок (для Android 11+ package visibility)

Вставь `<uses-permission>` строки рядом с существующими BLE permissions. `<queries>` блок размести как прямой child `<manifest>` (рядом с `<uses-sdk>`).

⚠️ `<queries>` важен на API 30+ — без него `PackageManager`/`ContentResolver` могут отказать в доступе к `com.byd.car.server`, даже при наличии правильного permission.

## Шаг 4 — Добавить кнопку Native Explorer в head_unit_scaffold

В существующем `head_unit_scaffold.dart` (109 строк, NavigationRail с Dashboard/RawData/History/Settings) добавь destination:

```dart
NavigationRailDestination(
  icon: Icon(Icons.bug_report),
  label: Text('Native API'),
),
```

И в body switch — case для нового индекса:

```dart
case 4: // или какой свободный
  return NativeExplorerWide(detector: _nativeDetector);
```

где `_nativeDetector` — `NativeDetector` инстанс, создан в `initState()`:

```dart
late final NativeDetector _nativeDetector;

@override
void initState() {
  super.initState();
  _nativeDetector = NativeDetector();
  _nativeDetector.detect();  // fire-and-forget on startup
}
```

## Шаг 5 — Bump version

`pubspec.yaml`:
```yaml
version: 0.1.27+12
```

## Шаг 6 — Test plan (на реальной машине)

### 6.1 Smoke test
- Запустить на BZ5 head-unit'е (через ADB install из dev workstation)
- Открыть Native API экран → должно показать **VIN** и **головную плитку 'head unit: yes'**
- Если VIN = null → значит `BYDAutoBodyworkDevice` reflection не сработал; проверь logcat
- Если VIN есть, но permissions все красные → подтверди manifest

### 6.2 DTC snapshot
- Нажми **DTC snapshot** → должен прийти список (даже если 0 строк — это success)
- Если падает с error → проверь SELinux denials в `dmesg | grep avc`. Под user-build'ом `diag_socket_channel` может быть зарезан для не-system UID
- Если 0 строк всегда → попробуй `all_diag_data` через explicit MethodCall (или поменять default команду)

### 6.3 ICarPropertyService bootstrap
- Самый рисковый шаг — точный URL path и Bundle key для `BinderProvider` не подтверждены empirically
- Open logcat в фильтре `BydCarPropertyClient`
- Введи любой featureID из caталога (например `0x99002B0A` — TEST_CHECK_SHIPPING_INFORMATION) → нажми **Get**
- Если работает → отлично, выведи в issue какие path/key оказались верными
- Если "Could not obtain ICarPropertyService binder" → в logcat должна быть строка `Cursor for content://... has extras keys=[...] but no IBinder` — это даёт нам правильный ключ. Добавь его в `BUNDLE_KEY_CANDIDATES`. Также пробей все 5 URI candidates вручную через `adb shell content query --uri content://com.byd.car.server.provider.CarServiceProvider/...`
- Может оказаться, что bootstrap идёт не через query() а через `acquireUnstableContentProviderClient()` + `call()` — в таком случае нужна правка в `queryForBinder()`

### 6.4 Mapping featureID → semantics
Это **главная работа Native Explorer'а**. На стоянке:
- SOC: ищем feature, чьё значение в диапазоне 0..100 и стабильно
- Speed: должен быть 0 (или около)
- Voltage HV bus: ~350-400 V — но scaling может быть 0.025V/unit (значит ищем int ~14000)
- Voltage 12V: ~12-14 V (или *10 = 120-140 int)
- SoC delta — кататься на стоянке backwards (R) и forwards (D) на 1-2 метра, посмотреть какой featureID меняется
- Pack current: должен меняться с включением фар (потребитель ~5-10A)

Используем CSV-каталог: иди по строкам ENERGY и CHARGING сначала, потом INSTRUMENT и SPEED.

### 6.5 Subscribe rate
- Подпишись на скорость-кандидата → проедь немного → посчитай в logcat сколько событий в секунду
- Если ≥5 Гц — годится; если 1 Гц — Native режим бесполезен для driving telemetry, fallback на BLE polling

## Шаг 7 — Известные открытые вопросы (если что-то не работает)

| Симптом | Гипотеза | Что попробовать |
|---|---|---|
| `Class.forName(BYDAutoBodyworkDevice) → ClassNotFoundException` на head unit'е | Не та APK signing keychain / не системное приложение | Подписать debug APK тем же ключём, что и system; или платформенный signed APK через head-unit OTA tool |
| `cursor.getExtras() == null` | Не тот URI path | В logcat увидишь все пробованные. Скорее всего нужен path вида `service/<simple-name>` или fqcn |
| `RemoteException` или `transact returned false` | Не тот transaction code или wire format | Permute TX codes 1-10; включи verbose Parcel logging в BydCarPropertyClient |
| Event'ов нет после subscribe, но get работает | Сервер хочет PARCELABLE callback с описателем интерфейса, а наш Binder не предоставляет | Уточнить `LISTENER_TOKEN` и проверить onTransact code value |
| `SecurityException: BYDAUTO_X` | Permission не granted runtime | Settings → App perms → BZ5 Companion → grant; либо `adb shell pm grant <pkg> android.permission.BYDAUTO_X_COMMON` |
| Все native свойства возвращают `errorMsg: decode_failed` | Wire format не такой, как я угадал | Логирование Parcel.dataPosition() + первые 64 байта reply'я → реверсить вручную |

## Шаг 8 — В следующих итерациях

После того как маппинг featureID → семантика для критичных свойств установлен, в **v0.1.28**:

1. Создать `NativeCarDataSource implements VehicleDataSource` (используя key map'у)
2. Зафиксировать существующий `ConnectionService` как `BleObdDataSource` (минимальный wrapper)
3. В `head_unit_scaffold.dart` → выбор source через `NativeDetector.isOnHeadUnit`
4. Trip/charging detection, history, snapshot — переписать на `VehicleDataSource` API (всё ещё в `ConnectionService` логика, только источник swap'ается)

Это уже не scaffold-работа, а нормальный refactor.

---

**Конец интеграции.** Любые сюрпризы на машине → собирай logcat'ы с тегами `BydNativePlugin`, `BydCarPropertyClient`, `BydDiagSocket`, `BydVinDetector`.
