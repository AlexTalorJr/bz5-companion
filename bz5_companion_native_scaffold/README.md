# BZ5 Companion — Native API Scaffold (v2)

Дроп-ин дополнение к bz5-companion v0.1.26+11 для работы через **native HAL** на head-unit'е BZ5/BYD без OBD-адаптера. Существующий BLE+ELM путь не трогается.

**v2 update**: wire-протокол `ICarPropertyService` полностью верифицирован по dex `com.byd.car.server` (transaction codes 1–6, Parcelable layouts `Status`/`CarPropertyValue`/`Response`, BinderProvider bootstrap). Подробности — `docs/BZ5_NATIVE_API_RECON.md` §3.1.

## Что внутри

```
bz5_companion_native_scaffold/
├── README.md                                                    ← этот файл
├── INTEGRATION.md                                               ← step-by-step мерж
├── docs/
│   ├── BZ5_NATIVE_API_RECON.md                                  ← reverse-engineering отчёт
│
├── android/app/src/main/
│   ├── AndroidManifest_additions.xml                            ← permissions + queries snippet
│   └── kotlin/com/bz5companion/bz5_companion/
│       ├── BydNativePlugin.kt                                   ← FlutterPlugin entry point
│       ├── BydVinDetector.kt                                    ← VIN via reflection (auto-detect)
│       ├── BydDiagSocket.kt                                     ← LocalSocket diag_socket_channel client
│       ├── BydCarPropertyClient.kt                              ← ICarPropertyService AIDL via BinderProvider (verified)
│       ├── BydPermissions.kt                                    ← permission catalog + state
│       ├── BydReflection.kt                                     ← cached reflection helpers
│       └── MainActivity_example.kt                              ← integration reference
│
└── lib/
    ├── services/
    │   ├── data_source.dart                                     ← abstract VehicleDataSource
    │   ├── native_car_channel.dart                              ← MethodChannel/EventChannel wrapper
    │   └── native_detector.dart                                 ← isOnHeadUnit auto-detect
    └── screens/wide/
        └── native_explorer_wide.dart                            ← UI debugger / featureID prober
```

## Архитектура

```
┌─────────────────────────────────────────────────┐
│ Flutter UI (head_unit_scaffold + native_explorer)│
└──────────────────┬──────────────────────────────┘
                   │  Dart
                   ▼
       ┌─────────────────────┐
       │ NativeCarChannel    │ ← lib/services/native_car_channel.dart
       └──────────┬──────────┘
                  │ MethodChannel "bz5_companion/native_car"
                  │ EventChannel  "bz5_companion/native_car/events"
                  ▼
     ┌─────────────────────────┐
     │ BydNativePlugin         │ ← android/.../BydNativePlugin.kt
     └──┬──────┬──────┬────────┘
        │      │      │
        ▼      ▼      ▼
   VinDetector  DiagSocket  CarPropertyClient
       │           │            │
       │           │            │ ContentResolver.query()
       │           │            │ → BinderCursor → IBinder
       │           │            ▼
       │           │      ICarPropertyService AIDL
       │           │            │
       │           ▼            ▼
       │     LocalSocket   com.byd.car.server
       │     diag_socket_channel
       ▼
android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice
        (via reflection on system framework)
```

## Что сделано / что осталось

| Компонент | Статус | Описание |
|---|---|---|
| Recon (отчёт) | ✅ done | v2 — wire-протокол верифицирован по dex |
| Feature catalog | ✅ done | 10016 properties с типами и устройствами |
| Kotlin plugin scaffold | ✅ done | MethodChannel + EventChannel dispatch |
| VIN detect | ✅ done | Должно работать сразу на car-target |
| Diag socket client | ✅ done | Должно работать сразу (если SELinux позволит) |
| Permission catalog | ✅ done | 22 known perms (включая `_GET` варианты), готов к runtime-grant |
| Reflection helpers | ✅ done | Cached, null-safe |
| ICarPropertyService client | ✅ done | Все TX codes / parcel layouts верифицированы (см. §3.1 recon) |
| Dart channel wrapper | ✅ done | Готов к использованию |
| Native auto-detector | ✅ done | ChangeNotifier-based |
| Native Explorer UI | ✅ done | Двойного назначения: status + prober |
| NativeCarDataSource impl | ❌ deferred | После того как featureID semantics calibration сделана |
| ConnectionService refactor | ❌ deferred | Phase 2 — пока не трогаем BLE |

Что осталось empirically на машине (не блокирует первый билд):

1. **Map featureID → semantic** (SOC, скорость, voltage, etc.) — каталог из 10016 нужно профильтровать рантайм-пробой. Native Explorer UI это и делает: пробуй featureID, смотришь значение, и помечаешь как "SOC=0x99002B0A" в своей таблице.
2. **Какие именно `BYDAUTO_*_COMMON` / `_GET` permissions требует конкретный feature** — manifest сейчас декларирует супермножество, runtime покажет какие реально нужны (логируется в `Response.status.description`).
3. **Sample rate `registerValueCallback`** — нужно убедиться что для скорости/SOC хотя бы 5 Гц.

## AIDL strategy

Намеренно НЕ используем `.aidl`-файлы и Gradle's AIDL code-gen, потому что:
- `Response.result` и `CarPropertyValue.mValue` — это `Object` с runtime-полиморфизмом по `writeString(typeName)`; AIDL stub generator такое не умеет.
- Wire-формат не "AIDL-стандартный": Parcelable полей сериализуются через ручные `writeString(className) + writeXXX(value)` диспатчи, что выходит за рамки `parcelable Foo;` декларации.
- `IBinder.transact()` напрямую даёт нам контроль над байтами — мы зеркалим то, что carserver реально пишет/читает.

Все TX codes и wire layouts верифицированы в `BydCarPropertyClient.kt` по `Stub$Proxy` дисассемблу — точные ссылки в `BZ5_NATIVE_API_RECON.md` §3.1. Если в будущей firmware BYD изменит порядок методов в `.aidl`, это сломает наш клиент молча (transact с неправильным кодом вернёт `false` или nonsense parcel) — у нас есть defensive логирование на всех ветках, так что прокблема будет видна в logcat сразу.

## Безопасность / privacy

- Все BYDAUTO permissions — dangerous-level, требуют user grant
- Diag socket — без gating, но SELinux может зарезать
- Native data **никогда не покидает устройство** иначе как через UI (snapshot export, как в существующем BLE flow)
- Catalog CSV — собран из системных APK, никаких пользовательских данных

## Совместимость

- Tested против: `com.byd.car.server` v2.1.0-alpha10 (target SDK 33, min 24)
- BYDAuto framework versioning не имеет видимого API contract — все breaking changes будут видны через reflection failure → graceful fallback на BLE
- Если в будущих firmware Anthropic API меняется (например, `getRealAutoVIN` переименован) — `BydVinDetector` обработает через NoSuchMethodException и попробует альтернативные имена

## Дальше

Внимательно прочитай **INTEGRATION.md** — там pre-flight checklist и test plan для первого запуска на машине.
