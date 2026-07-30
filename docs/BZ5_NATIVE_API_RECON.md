# BZ5 / DiLink 5.0 Native API — recon отчёт

**Дата**: 2026-05-21 (v2 — verified wire protocol)  
**Источник**: decompile `com.byd.diagnosticinfo` (1.5.1.0), `com.byd.byddatachecktool` (1.5.0.0), `com.byd.CanDataCollect` (v12), `com.byd.car.server` (2.1.0-alpha10)  
**Цель**: проектирование native-режима для bz5-companion на head-unit'е без OBD-адаптера

**Что нового в v2 (по сравнению с первым проходом):**
- Полностью верифицированный bootstrap-протокол через `BinderProvider` (URI + projection + bundle key) — §2
- Точные transaction codes (1..6) и parcel layouts `Status`/`CarPropertyValue`/`Response` — §3.1
- HAL listener callbacks (`onDataEventChanged`, `onMcuStatusChanged`, `onWholeFrameDataChanged` и др.) — §8 "Resolved by CanDataCollect"
- Listener oneway TX code и wire-формат `onEvent` event — §3.1

---

## TL;DR

В машине есть **три параллельных канала** для получения данных:

| Канал | Что даёт | Подходит для | Permission |
|---|---|---|---|
| `ICarPropertyService` через `CarServiceProvider` (ContentProvider→AIDL) | get/set/subscribe по integer feature ID (в обёртке hex-string) | **Realtime telemetry, основная замена UDS** | `com.byd.car.server.PROVIDER` (normal) + per-domain `BYDAUTO_*_COMMON` (dangerous) |
| `BYDAutoXxxDevice` framework (system jar) | прямой HAL без сервера | Особые случаи, обход сервера | reflection-доступ, требует BYDAUTO_*_COMMON |
| Unix socket `diag_socket_channel` | snapshot DTC database (json key/value) | DTC scan, заводские диагностики | нет (LocalSocket abstract namespace) |

Реестр известных features — **10016 свойств** в `assets/config_{1,2,3}.bin` сервера. Полный разобранный каталог (10016 свойств) в публичном репозитории НЕ публикуется: право на декомпиляцию ради совместимости не покрывает оптовую передачу полученных данных третьим лицам. Используемые идентификаторы перечислены пресетами в `native_explorer_wide.dart` и таблицей декодеров.

**Ключевая дисквалификация прошлого плана**: string property names — это **НЕ** `"battery.soc"`, а литеральные hex-encoded feature IDs вида `"0x99002B0A"`. Человекочитаемых имён в системе нет.

---

## 1. Архитектура BYD car framework

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Client App (bz5-companion на head unit'е)                                │
└──────────────────────────────────────┬───────────────────────────────────┘
                                       │
            ┌──────────────────────────┴──────────────────────────────┐
            │                                                          │
            ▼  ContentResolver.query(uri)→BinderCursor                ▼  Reflection
┌──────────────────────────────────────┐               ┌──────────────────────────────┐
│  CarServiceProvider                  │               │  System framework classes      │
│  (ContentProvider in com.byd.car...) │               │  (android.hardware.bydauto.*)  │
│  extends BinderProvider (spi.ipc)    │               │  Built into /system/framework/ │
└──────────┬───────────────────────────┘               └──────────────┬───────────────┘
           │ exposes binders                                          │
           ▼                                                          │
┌──────────────────────────────────────┐                              │
│  ICarPropertyService (AIDL)          │                              │
│  - getProperty(name)                 │                              │
│  - getProperties(names)              │                              │
│  - setProperties(values)             │                              │
│  - registerValueCallback(L, names)   │                              │
│  - unregisterValueCallback(L, names) │                              │
└──────────┬───────────────────────────┘                              │
           │ delegates to HalFeatureController                        │
           ▼                                                          │
┌──────────────────────────────────────┐                              │
│  HalFeatureController (singleton)    │                              │
│  Loads FeatureList from              │                              │
│  assets/config_{1,2,3}.bin (proto)   │                              │
│  Maps featureID → interfaceName →    │                              │
│  AbsBYDAutoDevice instance           │                              │
└──────────┬───────────────────────────┘                              │
           │ calls .get/.set/.registerListener                        │
           ▼                                                          ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  AbsBYDAutoDevice (abstract base, in framework.jar)                      │
│    BYDAutoEventValue get(int[] featureIds, Class<?> cls)                 │
│    int set(int[] featureIds, BYDAutoEventValue value)                    │
│    void registerListener(IBYDAutoListener listener, int[] featureIds)    │
│    String getGetPermission()      // per-device read permission name     │
│    String getSetPermission()      // per-device write permission name    │
│                                                                          │
│  45 concrete subclasses (POWER, ENERGY, CHARGING, SPEED, MOTOR, ...)     │
│    each: BYDAutoXxxDevice.getInstance(Context) -> singleton              │
└──────────────────────────────────────────────────────────────────────────┘
```

## 2. Bootstrap (как клиент подключается)

`com.byd.car.server` **не объявляет `<service>`** в манифесте, **только три `<provider>`**:

```xml
<provider android:name="com.byd.car.server.provider.CarServiceProvider"
          android:exported="true"
          android:authorities="com.byd.car.server.provider.CarServiceProvider" />

<provider android:name="com.byd.vem.VehicleContentProvider"
          android:exported="true"
          android:authorities="com_byd_vem_data;com_byd_map_ui;
                              google_maps_settings;google_maps_energy;
                              google_maps_assisted_driving;google_maps_vehicle_profile" />

<provider android:name="com.gpack.service.provider.VehicleServiceProvider"
          android:exported="true"
          android:process=":GpackService"
          android:authorities="com.gpack.service.provider.VehicleServiceProvider" />
```

Bootstrap идёт через `query()` на ContentProvider'е, который вернёт `BinderCursor` с обёрнутым `IBinder`. **Протокол полностью верифицирован по dex carserver:**

```kotlin
// 1. URI — любой путь под authority, провайдер path игнорирует
val uri = Uri.parse("content://com.byd.car.server.provider.CarServiceProvider")

// 2. projection[0] = FQCN AIDL интерфейса — это и есть селектор сервиса
val cursor = contentResolver.query(
    uri,
    arrayOf("com.byd.car.property.ICarPropertyService"),
    null, null, null
)

// 3. BinderCursor.extras содержит BinderParcelable под ключом "binder"
val parcelable = cursor.extras.getParcelable<Parcelable>("binder")
//    BinderParcelable.getBinder():IBinder — через reflection
val binder = parcelable.javaClass.getMethod("getBinder").invoke(parcelable) as IBinder
```

`BinderProvider.query()` в SPI делает: `Class.forName(projection[0])` → `Spi.getService(ctx, cls)` → возвращает IBinder, обёрнутый в `BinderCursor` (см. `Lcom/byd/spi/ipc/cursor/BinderCursor;` в dex). Поэтому **`projection[0]` — это единственный обязательный параметр query**; остальные игнорируются.

Объявленный permission `com.byd.car.server.PROVIDER` с `protectionLevel="0x00000000"` = **normal** = любое приложение получает доступ по `<uses-permission>` без runtime-запроса.

## 3. ICarPropertyService AIDL (полная сигнатура)

```aidl
package com.byd.car.property;

import com.byd.datasource.feature.Response;
import com.byd.datasource.feature.Status;
import com.byd.car.property.CarPropertyValue;
import com.byd.car.property.ICarPropertyListener;

interface ICarPropertyService {
    Response getProperty(String name);
    Response getProperties(in String[] names);
    List getPropertyConfigs(in String[] names);
    Status  setProperties(in CarPropertyValue[] values);
    void    registerValueCallback(ICarPropertyListener listener, in String[] names);
    void    unregisterValueCallback(ICarPropertyListener listener, in String[] names);
}

interface ICarPropertyListener {
    void onEvent(String name, in Response response);
}
```

Сопутствующие типы (`Response`, `Status`, `CarPropertyValue`, `Caller`) живут в пакетах `com.byd.datasource.feature.*` и `com.byd.car.property.*` — нужно вытаскивать из `carserver.apk` для копирования в проект.

### 3.1. Verified wire protocol (low-level)

Из dex carserver вытащены **точные** transaction codes и parcel layouts. Проверено по `ICarPropertyService$Stub$Proxy.<each method>` — это сгенерированный AIDL код, так что цифры абсолютные.

**Transaction codes**:

| Code | Метод                   | Flags        | Возвращает              |
|------|-------------------------|--------------|-------------------------|
| 1    | setProperties           | 0 (sync)     | `Status` (nullable)     |
| 2    | getProperty             | 0 (sync)     | `Response` (nullable)   |
| 3    | getProperties           | 0 (sync)     | `Response` (nullable)   |
| 4    | getPropertyConfigs      | 0 (sync)     | `List<CarPropertyConfig>` |
| 5    | registerValueCallback   | 1 (oneway)   | void                    |
| 6    | unregisterValueCallback | 1 (oneway)   | void                    |

ICarPropertyListener: TX 1 = `onEvent(String name, Response r)`, oneway.

**Interface tokens**:
- `"com.byd.car.property.ICarPropertyService"`
- `"com.byd.car.property.ICarPropertyListener"`

**Parcelable layouts** (по `<init>(Parcel)` и `writeToParcel()`):

`Status` — 2 поля:
```
writeInt(code)
writeString(description)
```
Static codes из `Status.<clinit>` (имена явные, ordinals не верифицированы — d8 их затёр):
`STATUS_SUCCESS`, `STATUS_NONE`, `STATUS_FAILED`, `STATUS_INVALID_ARG`,
`STATUS_TIMEOUT`, `STATUS_UNAVAILABLE`, `STATUS_BLOCKING`, `STATUS_UNKNOWN_ERROR`.

`CarPropertyValue` — 3 строки + type-tagged payload:
```
writeString(mPropertyKey)   // semantic key, обычно null в client→server
writeString(mPropertyId)    // "0x<HEX>" feature-id строка ← это то, что мы пишем в getProperty
writeString(typeName)       // Java FQCN значения; диспатчит payload:
// case "java.lang.String":    writeString(value)
// case "[B":                  writeByteArray(value)
// case "java.lang.Integer":   writeInt(value)
// case "java.lang.Long":      writeLong(value)
// case "java.lang.Float":     writeFloat(value)
// case "java.lang.Double":    writeDouble(value)
// case "java.lang.Boolean":   writeInt(value ? 1 : 0)
// case "[I":                  writeInt(length); writeIntArray(value)
// case "[F":                  writeInt(length); writeFloatArray(value)
// case "[J":                  writeInt(length); for v in array: writeLong(v)
// case "android.os.Parcelable": writeParcelable(value, flags)
```

`Response` — `status` + type-tagged `result`:
```
writeParcelable(status, flags)   // null-safe Parcelable: className tag + payload, или null
writeString(typeName)            // ИЛИ null, если result == null
<payload по typeName>            // тот же диспатч, что у CarPropertyValue.mValue
```

**Listener event format** (server→client transact code 1, oneway):
```
writeInterfaceToken("com.byd.car.property.ICarPropertyListener")
writeString(name)               // "0x<HEX>"
writeInt(hasResponse)           // 0 или 1
if hasResponse: writeToParcel(response, 0)
```

## 4. Низкоуровневый HAL (если нужен обход сервера)

```java
// Pattern для любого AbsBYDAutoDevice subclass:
AbsBYDAutoDevice dev = BYDAutoEnergyDevice.getInstance(ctx);  // или Charging, Speed, ...

// READ - синхронно
int[] features = { 0x55..., 0x99... };  // integer featureIDs
BYDAutoEventValue v = dev.get(features, BYDAutoEventValue.class);
// v.intValue (I), v.bufferDataValue ([B), и др. поля

// WRITE - синхронно, возвращает status int
BYDAutoEventValue wv = new BYDAutoEventValue();
wv.intValue = 42;
int rc = dev.set(features, wv);

// SUBSCRIBE - push-based
AbsBYDAutoXxxListener listener = new AbsBYDAutoXxxListener() {
    @Override
    public void onDataEventChanged(int featureId, BYDAutoEventValue value) {
        // …
    }
};
dev.registerListener(listener, features);
// Cleanup:
dev.unregisterListener(listener);
```

`AbsBYDAutoDevice`-метод `getGetPermission()` возвращает permission name (e.g. `"android.permission.BYDAUTO_ENERGY_COMMON"`) — это та dangerous-permission, которую надо runtime-запросить.

## 5. BydAutoDeviceType — полная таблица 45 устройств

`interfaceName` (proto field 4) маршрутизирует featureID к конкретному `AbsBYDAutoDevice`:

| Ord | Name | Ord | Name | Ord | Name |
|----:|---|----:|---|----:|---|
| 0 | POWER | 15 | GB | 30 | LOCATION |
| 1 | SETTING | 16 | OTA | 31 | REMINDER |
| 2 | BODY | 17 | LIGHTS | 32 | RADIO |
| 3 | INSTRUMENT | 18 | **ENERGY** | 33 | **TYRE** |
| 4 | **CHARGING** | 19 | DOORLOCK | 34 | REAR_VIEWMIRROR |
| 5 | **GEARBOX** | 20 | WIPER | 35 | RESCUE |
| 6 | ENGINE | 21 | TIME | 36 | **DTC** |
| 7 | SAFETYBELT | 22 | **STATISTICS** | 37 | TEST |
| 8 | **SPEED** | 23 | AUDIO | 38 | VERSION |
| 9 | CALL | 24 | RSE | 39 | YUNCTRL_DIV15 |
| 10 | SPECIAL | 25 | RADAR | 40 | BIGDATA |
| 11 | SENSOR | 26 | PM25 | 41 | MONITOR |
| 12 | ADAS | 27 | PHONE | 42 | VEHICLE_DATA |
| 13 | AC | 28 | SECURITY | 43 | MQTT |
| 14 | PANORAMA | 29 | COLLISION | 44 | CPU_TEMPRATURE |

Жирным — устройства приоритетных для bz5-companion.

## 6. FeatureLists.proto (восстановленная схема)

```protobuf
syntax = "proto3";

message FeatureList {
  repeated Feature featureList = 1;
}

message Feature {
  uint64 featureID    = 1;   // packed ID, ВСЕГДА присутствует
  int32  dataType     = 2;   // Java type code (см. ниже)
  int32  dataFlowType = 3;   // 0=READ implicit (config_1), 1=WRITE (config_2), 2=READ_WRITE (config_3)
  int32  interfaceName = 4;  // BydAutoDeviceType ordinal, OPTIONAL (defaults to POWER=0 = system default routing)
}
```

**Assets**:
- `assets/config_1.bin` (68 KB, **6789 features**) — read-only
- `assets/config_2.bin` (32 KB, **2668 features**) — write-only
- `assets/config_3.bin` (6.8 KB, **559 features**) — read-write

Итого **10016 уникальных feature ID**. Каталог держится вне публичного репозитория, см. выше.

**dataType codes** в config (TBD — нужна runtime-калибровка):

| Code | Частота в config_1 | Предположение |
|---:|---:|---|
| 1 | 1911 | Integer / int32 |
| 2 | 1321 | Long / int64 |
| 12 | 1006 | ? (массовый — возможно Float-derived) |
| 3 | 565 | Float? |
| 4 | 319 | Double? |
| 13 | 259 | ? |
| 23 | 254 | byte[] / buffer? |
| 17 | 194 | ? |

## 7. Property name format — критическое уточнение

В `HalFeatureProvider.transformHexString2Long(String s)`:

```java
return Long.parseLong(s.substring(2), 16);
```

То есть **property name = `"0x" + uppercase_hex(featureID)`**. Пример:
- featureID `2566914314` (decimal) = `0x99002B0A` (hex)
- AIDL вызов: `getProperty("0x99002B0A")`

**Никаких** `"battery.soc"`, `"vehicle.speed"`, и т.д. — это была наша ошибочная гипотеза.

## 8. Что мы НЕ знаем (требуется runtime-проба)

1. **Какой featureID = SOC, voltage, speed, etc.** — нужно runtime-перебирать catalog и логировать значения. На стоянке SOC = константа, скорость = 0, voltage ≈ 350-400V. Можно отфильтровать по диапазонам и dataType. Стартовый список идентификаторов — пресеты в `native_explorer_wide.dart`.

2. **Какой dataType code в `config_*.bin` = `"java.lang.Integer"` / `"java.lang.Long"` / ...** Калибровка: `getPropertyConfigs(["0x..."])` вернёт `CarPropertyConfig` с полем-классом значения. Текущая гипотеза `dataType=1=Integer, 2=Long, 3=Float, 4=Double, 23=byte[]` неверна — proto-конфиги используют другой `dataType` код, чем wire format типа. Type name на wire — это **строковое имя Java-класса** (см. §3.1), независимо от `dataType` в protobuf.

3. **Работает ли `registerValueCallback` для non-system UID**. Provider permission = normal, но per-feature `read_permission` могут быть `signature|privileged`. Гипотеза: для большинства публичных features (BYDAUTO_*_COMMON) — да.

4. **Какие `BYDAUTO_*_COMMON` permissions реально требуются** при runtime. `HalFeatureController` вызывает `PermissionUtils.checkCallingPermissions(...)` с permission names из `cfg.getReadPermission()`. Без них AIDL вернёт `Response` с `status.code != SUCCESS` и текстом в description. Можно использовать как probe-механизм: `getProperty("0x...")` → если `status.description` упоминает permission, добавить в manifest.

5. **Поведение при отсутствии permission** — `Response.status.code` коды нужны empirically (см. также пункт 2 для калибровки).

6. **Скорость event'ов через `registerValueCallback`** — sample rate. Для драйва нам нужно хотя бы 5 Гц на скорость и SOC. Серверная сторона может троттлить.

### Resolved by carserver dex dive (2026-05-21):

- ✅ ContentProvider URI: любой путь под `content://com.byd.car.server.provider.CarServiceProvider`; **`projection[0]` = AIDL FQCN** — это и есть селектор сервиса.
- ✅ Bundle extras key: `"binder"`. Внутри — `BinderCursor$BinderParcelable` (reflection-доступ к `.getBinder()`).
- ✅ Transaction codes 1..6 (см. §3.1).
- ✅ Parcelable wire layouts для `Status`, `CarPropertyValue`, `Response` (см. §3.1).
- ✅ Listener TX code = 1 (oneway).
- ✅ Type tagging: на wire значения помечаются строкой Java-класса (`"java.lang.Integer"`, `"[B"`, …), а не числовым `dataType` из protobuf.

### Verified by CanDataCollect dex dive (2026-05-21):

- ✅ HAL `registerListener(AbsXxxListener, int[])` подтверждён на трёх устройствах (Power, Statistic, BigData).
- ✅ `unregisterListener(AbsXxxListener)` — БЕЗ int[] (одна сигнатура для всех слушателей).
- ✅ Listener callback shapes:
  - `AbsBYDAutoStatisticListener.onDataEventChanged(int featureId, BYDAutoEventValue value)` — generic data event.
  - `AbsBYDAutoPowerListener.onMcuStatusChanged(int)`, `onPowerCtlStatusChanged(int, int)` — domain-specific.
  - `AbsBYDAutoBigDataListener.onNeedRendRegisterTable(int)`, `onWholeFrameDataChanged(byte[])` — raw CAN frame stream.
- ✅ Доп. методы HAL устройств:
  - `BYDAutoBodyworkDevice.getAutoType():I` — модель машины
  - `BYDAutoPowerDevice.getMcuStatus():I`, `wakeUpMcu():I`, `getPowerCtlStatus(int):I`
  - `BYDAutoVehicleDataDevice.sendRegisterTable(int, byte[]):I` — подписка на CAN ID диапазон (для BigData listener)
  - `BYDAutoStatisticDevice.get(int[], Class)` — общий get
- ✅ `BYDAutoEventValue.bufferDataValue:[B` — поле подтверждено.
- ✅ Используемая featureID-константа: `BYDAutoFeatureIds.STATISTIC_BATTERY_SERIAL_NUMBER` (значение в framework.jar).

## 9. Diag socket channel (snapshot DTC)

Параллельный канал, не через сервер:

```kotlin
val socket = LocalSocket()
socket.connect(LocalSocketAddress("diag_socket_channel", LocalSocketAddress.Namespace.ABSTRACT))
socket.outputStream.write("latest_diag_data".toByteArray())  // или "all_diag_data"
val reader = BufferedReader(InputStreamReader(socket.inputStream))
val response = reader.readLines().joinToString()
// Parse: rows split by '@', columns split by '#'
// 10 columns: id, moduleType, moduleName, dtc, state(0=fault), destBitfield, diagType, describe, jsonData, recordTime
// jsonData = `{"data":[{"key":"name","value":"value"}, ...]}`
// Filter rows where (destBitfield & 0xF00) >> 8 == 1
```

Permission gating: **отсутствует на уровне AIDL** (это просто Linux abstract socket). Может быть зарезано SELinux'ом для не-system UID. Empirically test нужен.

## 10. VIN-based auto-detect (для DataSource resolver)

```java
// На реальной BYD-машине:
Class<?> c = Class.forName("android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice");
Object dev = c.getMethod("getInstance", Context.class).invoke(null, context);
String vin = (String) c.getMethod("getRealAutoVIN").invoke(dev);
// → 17-symbol VIN, e.g. "LCO4F1A60RC123456" для BZ5

// На телефоне:
//   ClassNotFoundException → "не head unit" → BLE OBD mode

// Метод getRealAutoVIN() даёт свежий VIN с CAN; getAutoVIN() — кэшированный.
// Оба существуют, обе — на BYDAutoBodyworkDevice.
```

## 11. Сводка для имплементации

**Прямо сейчас можно делать:**
- ✅ Auto-detect "запущены на head unit'е" — VIN reflection
- ✅ Diag socket клиент — DTC scan replacement (snapshot mode)
- ✅ Kotlin plugin scaffold с MethodChannel API
- ✅ DataSource abstraction в Dart, рефактор ConnectionService

**Требует runtime-проб (отдельная сессия в машине):**
- 🔍 Маппинг featureID → семантика (SOC, speed, voltage, ...) — runtime сравнение со значениями приборки
- 🔍 Подтверждение `registerValueCallback` rate и работоспособности
- 🔍 Permission gating empirics
- 🔍 BinderProvider.query() bootstrap URI / extras format

Стартовый список для probing — пресеты в `native_explorer_wide.dart`.

## 12. Источники в репо

- полный каталог 10016 features (parsed из proto configs) — вне публичного репозитория
- `byd_internals_findings.md` — recon до текущей сессии
- `bz5_findings_v1_0_0.zip` — AIDL сигнатуры всех 93 сервисов  
- `carserver_assets/` — оригинальные `config_*.bin` + parsed `.txt` (proto raw decode)

## 13. Field test 2026-05-21 (carserver 2.1.0-alpha10) и стратегия параллельных каналов

После накатывания v0.1.26+14..+17 на реальный head unit (TOYOTA AUTO/TOYOTA SPACE, Android 12) выяснились конкретные ограничения этой firmware:

### 13.1 Two-layer permission gating (confirmed)

`BYDAutoBodyworkDevice` имеет **два независимых** permission check:

- `getInstance(Context)` — line 628 — требует `BYDAUTO_BODYWORK_COMMON`
- `getDataFlag()` — line 2201, вызывается из любого VIN getter — требует `BYDAUTO_BODYWORK_GET`

`_COMMON` гранчится после `requestRuntimePermissions()` (declared as dangerous), но `_GET` на этом образе firmware — **signature-protected**, runtime grant не помогает. Без system signature reflection-доступ к VIN перекрыт. Это same pattern, который вероятно действует и на других доменах.

Granted после `requestRuntimePermissions`: BODYWORK_COMMON, ENERGY_COMMON, SPEED_COMMON, GEARBOX_COMMON, INSTRUMENT_COMMON, TYRE_COMMON, STATISTIC_COMMON, CHARGING_COMMON, TIME_COMMON. Denied: POWER_COMMON (sic), все `_GET`, VEHICLE_DATA_COMMON, BIGDATA_COMMON, и остальные редкие `_COMMON`.

### 13.2 ContentResolver.query returned null (open problem)

Канонический bootstrap для `ICarPropertyService`:

```kotlin
contentResolver.query(content://com.byd.car.server.provider.CarServiceProvider,
                      arrayOf("com.byd.car.property.ICarPropertyService"),
                      null, null, null)
```

на alpha10 **возвращает null**, при этом:

- `pm.resolveContentProvider(authority)` → non-null (provider visible)
- `com.byd.car.server.PROVIDER` permission — granted
- `<queries>` блок в манифесте присутствует
- `Class.forName("...BYDAutoBodyworkDevice")` succeeds (framework on classpath)
- Никакого SecurityException не бросается — просто **молчаливый null**

Симптом match'ит паттерн "BinderProvider.query() catch-all returned null on internal failure" (Class.forName на нашем FQCN внутри carserver-процесса, race с lazy registration, или Spi.getService возвращает null до permission check).

### 13.3 Strategy: parallel diagnostic + parallel data channels

В v0.1.27+1 добавлены три новых диагностических endpoint'а в плагине, доступных через Native Explorer → секция "Deep Probe":

1. **`probeConnectionPaths` (BydConnectionProbe.probeAll)** — матрица из 4 URI × 8 FQCN candidates × `query()` + 5 `call()` method names + `ServiceManager.getService()` через рефлексию. Возвращает структурированный отчёт `{ attempts: [...] }` с outcome каждой попытки (cursor null/empty, extras keys, binder extraction status) плюс предготовленный clipboard-friendly text rendering.

2. **`halProbeAll` (BydHalProbe.probeAll)** — для каждого из 10 BYDAuto*Device доменов: пробует Class.forName, getInstance(Context), inventory public methods (до 40), наличие generic `.get(int[], Class)`, состояние `_COMMON`/`_GET` permission. Это **independent path** — не требует ContentProvider вообще, использует тот же reflection, которым ходит BydVinDetector (и который, как мы знаем, доходит до permission check, т.е. инфраструктура HAL device factories на этой firmware работает).

3. **`halGet` (BydHalProbe.halGet)** — прямой вызов `dev.get(int[], BYDAutoEventValue.class)` для указанного домена и feature ID. Decode через тот же `BydReflection.decodeEventValue` что и event listener'ы. Bypasses CarServiceProvider entirely.

В Native Explorer для всех трёх — кнопки + dropdown domain + feature ID input. Результаты копируются в clipboard для return в чат.

### 13.4 What to do next on the car

Workflow для следующего field test:

1. Установить v0.1.27+1.
2. Запустить "Request perms" (Native Explorer → Status), убедиться что 10 `_COMMON` гранчены.
3. Нажать **"Probe connection paths"**, отправить отчёт в чат. Это покажет: a) есть ли FQCN variant, который проходит query; b) reagiruет ли BinderProvider на `call()`; c) видны ли car-related services в `ServiceManager.listServices()`.
4. Нажать **"HAL probe all domains"**. Для каждого домена с `getInstance OK` и `hasGenericGet=true` — можем читать данные напрямую.
5. Для green-доменов попробовать "HAL Direct Get" с feature ID из presets — отправить значение в чат, оценить magnitude.

После этих шагов мы будем знать **какой именно путь работает** и можем писать `NativeCarDataSource` поверх него (HAL direct, через `dev.get`, или ICarPropertyService — что окажется доступным).

### 13.5 Fallback plan if both paths blocked

Если ни ContentProvider ни HAL direct не дают пройти permission checks:

- Получить engineering build firmware у дилера / на форумах BZ5 (signature-protected перестанет применяться к нашему unsigned APK)
- Изучить, не предоставляет ли третий вектор — `diag_socket_channel` (Unix abstract socket, SELinux-зависим, текущая попытка падала с EACCES) — чего-то полезного. Это можно повторно проверить через "DTC snapshot" в Native Explorer после `_COMMON` grants — некоторые SELinux политики смягчаются после permission grants даже без system signature.
- В крайнем случае — остаёмся на BLE+ELM как primary, native API как opportunistic add-on (VIN auto-detect, DTC scan).


---

**Конец recon**. Дальше — имплементация в bz5-companion.
