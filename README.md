# BZ5 Companion

Telemetry and monitoring for the **Toyota BZ5** (FAW-Toyota, BYD e-platform).

The app runs in two places and reads the car in two different ways:

* on an **Android phone**, through an ELM327 BLE adapter plugged into the OBD-II port;
* **on the car's own head unit** (DiLink 5.0, Android 12), where it talks to the BYD vehicle framework directly and needs no adapter.

It shows things the dashboard keeps to itself: the real state of health, the balance across all 136 series cells, pack voltage under load, a precise odometer, charging power and energy, and a map of how much the car actually uses at each speed and each outside temperature.

> **Unofficial project.** Not affiliated with Toyota, FAW-Toyota or BYD. Written by one BZ5 owner for that car, after the usual scanners turned out not to see it. Don't expect stability: screens, database schema and constants change from build to build.

Current version: **0.1.76+175**. Releases are published automatically as GitHub Releases tagged `build-N`.

---

## Two ways to run it

| Target | How it reads the car | Notes |
|---|---|---|
| Android phone, 12+ | ELM327 BLE adapter, ISO 15765-4 and UDS | Needs the adapter plugged in and the car awake. Full OBD data set, per-cell voltages included. |
| BZ5 / BZ3 head unit, DiLink 5.0 (Android 12, API 32) | BYD vehicle HAL push channel, plus the same OBD path if an adapter happens to be plugged in | No adapter needed, and the signals are as good as the ones the cluster gets. Wide layout drawn for the car's own 2175 dp panel. |

### The two data planes

**OBD-II / UDS.** The BZ5 answers on odd diagnostic addresses, outside the usual `7E0-7E7` block, and the addressing rule is `RX = TX + 8`. Thirty-one ECUs are listed in `lib/data/ecu_registry.dart` along with the DIDs that turned out to mean something. Reads are plain UDS `22 XX YY`.

The head-unit framework names its properties with literal hex feature IDs instead of words. The full registry runs to 10016 entries and is not published here. The ones this app uses are the presets in `native_explorer_wide.dart` and the decoder table next to it.

**BYD vehicle HAL.** On the head unit the app subscribes to the framework's push telemetry. One detail shapes everything else: only the `*_COMMON` permission family can be granted at runtime, and it opens the *listener* channel only. The synchronous getters behind `*_GET` stay shut, so every live HAL value has to arrive as a push.

Where the two planes overlap (speed, pack voltage, current, SOC, gear, temperatures) the HAL value quietly takes the place of the OBD one inside the *same* widget, in the same spot, with no "HAL" badge. Signals that only one plane has appear only where they exist: motor RPM, parking sensors, climate and odometer on one side, per-cell voltages and DTCs on the other. The UI follows one rule everywhere: **a card shows up when data is actually flowing, and is missing otherwise.** You won't see a dash standing in for a number nobody measured.

---

## What it shows

**Dashboard.** SOC with a range estimate, SOH, battery temperature, pack voltage and HV bus, odometer to 100 m, gear and mechanical parking-pawl state, lifetime cycle count.

**Cells.** All 136 series cells with min, max and spread. The grading takes SOC into account, because LFP really does spread wider near 100% and a flat threshold would lie about it.

**Charging.** Live power, energy added this session, time to full. Energy is computed from ΔSOC and pack capacity, not from the car's own counter (see *Calibration*).

**Trips and history.** Every drive is stored locally with distance, energy, the SOC and temperature range it covered, peak power and peak regen. Chart series are saved separately so they survive a reinstall. Charging is not logged as a trip.

**Trends.** Consumption and efficiency over time. These are built by walking odometer and SOC anchors instead of adding up trip fields, and averaged only over days where both halves of the ratio are actually covered.

**Measurements.** Steady-state consumption for each speed band. A band earns its row after 120 s of qualified driving inside it, with dwell and guard rules so that stop-and-go traffic can't invent numbers.

**Atlas.** The slow one. A grid of **11 speed bands (40-140 km/h) by 12 temperature windows (-20 °C to +35 °C in 5° steps), 132 cells in all**. Once a cell has collected its 120 qualified seconds it freezes, gets stamped with the app version that produced it, and stops changing. Coverage is marked bronze, silver or gold, and cells that matured but haven't frozen yet are drawn dashed. Collection stops at 140 km/h on purpose. You can export the whole map as an image with a QR code on it.

**Explorers and tools.** An ECU explorer, a HAL explorer, a DID sweep (slow, keeps the screen awake), live logging with a results view, app diagnostics, and an append-only diagnostic dump you can send as a single file.

**Export.** One ZIP with a CSV per table, the SQLite file itself, and the diagnostic dump.

**Install / update screen.** The head unit can't update an APK in place, so there's a screen for staging and launching an install. See *Installing*.

---

## Autostart on the head unit

Android 12 won't let a broadcast receiver start a foreground service, so the app doesn't try. It goes the long way round:

```
BOOT_COMPLETED / QUICKBOOT_POWERON / MEDIA_MOUNTED
        -> setAlarmClock(+250 ms) on itself
        -> alarm fires -> startForegroundService (allowed from alarm context)
```

Every wake is written to a marker log, and that log also rides out inside the diagnostic dump, so you can read it without pulling files off the device. In the field the bridge takes a few seconds rather than the nominal 250 ms. The alarm is exact; the framework's own startup isn't.

You have to open the app by hand once after installing it. Until you do, Android keeps it in the *stopped* state and it receives no broadcasts at all.

---

## Cloud sync (optional, off until you turn it on)

There's a sync client for a self-hosted bridge (`carbridge.neardo.work`). It exists for one reason: the head unit can't update an APK in place, and every reinstall wipes the local SQLite database.

If you register a device with a setup token, the app uploads trips, snapshots, sweep runs and results, live logs, and a heartbeat once a minute that carries the app version. The device token lives in the Android Keystore. Raw high-rate samples are never uploaded, because the server refuses them by default and the client doesn't try. The client never pulls anything back for its own screens; what's on the device is what it trusts.

**If you never register, nothing leaves the device.** No telemetry, no analytics, no third-party SDK anywhere in the build.

After a reinstall you get back trips, snapshots, atlas reveals and chart series. You don't get back raw samples or the Atlas collection ledger, so partly collected bands are lost.

---

## What it doesn't do

* **It doesn't write to the car.** No climate, no locks, no windows. There is a property-write call in the native layer, `BydCarPropertyClient.setProperty`, because the framework offers one, but nothing calls it and no screen reaches it.
* **It doesn't clear fault codes.**
* **It isn't a driving display.** Read it parked or charging. Logging in the background while you drive is the intended use.
* **It can't sniff broadcast CAN over OBD.** The diagnostic gateway is cut off from the vehicle bus, so `ATMA` sees nothing. On the head unit the HAL plane covers part of that gap.
* **It can't get signed pack current over UDS.** That has to be inferred, or taken from HAL on the head unit.
* **No remote access.**
* **No iOS build.**

---

## Installing

**Phone.** Grab the APK from [Releases](../../releases), sideload it, grant Bluetooth and Location (BLE scanning needs Location on Android), then pair the adapter from Settings, *Find adapter*. The OBD port is under the steering column on the left.

**Head unit.** DiLink's built-in installer only does clean installs. It answers "already installed" to anything it recognises and counts that as a success, so uninstall the old version first and then install. Put the APK in a `SilentInstaller/` folder on a USB stick and plug the stick into the armrest port. On macOS run `dot_clean -m /Volumes/STICK` first, otherwise AppleDouble `._*` files show up in the installer's list. There's no ADB access to the head unit.

Plan around this: **every head-unit reinstall wipes preferences and the local database.**

---

## Building from source

Flutter **3.27.4** stable, Dart 3.

`android/` in this repository holds only `app/src/main`: the manifest, the Kotlin sources and the resources. The Gradle project isn't committed. CI generates it with `flutter create --platforms=android` and then patches it (Kotlin 2.1.0 in `settings.gradle`, release signing in `app/build.gradle`). To build locally, run this in a checkout first:

```
flutter create --platforms=android --org com.bz5companion --project-name bz5_companion .
```

and then `flutter build apk`.

You need a real device for anything that touches BLE or the car framework. Emulators are no help.

Workflows in `.github/workflows/`:

* `build.yml` builds the APK and publishes a GitHub Release tagged `build-N` with `make_latest`, where N is the commit count;
* `test.yml` runs `flutter test`, separately from the build;
* `lint.yml` runs analysis.

---

## Verification harness

Changes here go through the scripts in `tools/` before anything is committed:

| Script | What it checks |
|---|---|
| `check_repo.py` | protected files are structurally intact, layout invariants hold |
| `const_l10n_check.py` | no localisation lookups inside `const` spans |
| `hal_sync_check.py` | the HAL signal table still matches its consumers |
| `regress_plus35.py` | the regression suite. Every behaviour that ever broke has a named check in here, grouped into lettered eras |
| `dart_balance.py` | brace and paren balance, plus missing imports, across `lib/` |
| `atlas_a1_check.py` | the Atlas identity: frozen plus live has to equal the session counter, checked against real field dumps |
| `mirror_plus164.py` | a Python mirror of the consumption maths, compared against the Dart |

Baseline for the current HEAD: `7/7`, `OK`, `22/0/0`, `490 PASS / 1 WARN / 0 FAIL`, `74/74`.

The gates follow two rules. A check that matches source text strips comments first. And every gate is mutation-tested: revert the thing it guards, and that gate has to fail, or it isn't a gate.

---

## Language

The UI ships in **English and Russian** (`lib/l10n/strings.dart`, resolved by `LocaleService`).

Source comments, `docs/` and the gate scripts are mostly Russian. The Russian UI strings do more than show text: the regression gate quotes 97 of them as match anchors, so translating them means rewriting the harness in the same change.

---

## Repository layout

```
lib/
  ble/          ELM327 transport and client
  data/         Drift database, ECU/DID registry, atlas projection
  screens/      phone screens; screens/wide/ = head-unit layouts
  services/     connection, HAL telemetry, cloud sync, export, autostart
  widgets/      atlas grid and export, band cards, driver panels
  l10n/         EN/RU strings
android/app/src/main/
  kotlin/       BYD framework bridge, HAL subscriber, autostart, APK install
  AndroidManifest.xml
tools/          verification gates
docs/           reverse-engineering notes
test/           flutter test suite
LICENSE  NOTICE  SECURITY.md
```

---

## Calibration and constants

* **Pack capacity 65.28 kWh** on this car. There's a 73.984 kWh variant that owners report, but the app doesn't detect which one it's talking to.
* **136 series cells**, read from DID `790/0x0B03`, with 136 as the fallback.
* **14.4 kWh/100 km** is a fallback for the range estimate, used only when the car's own figure isn't available.
* **Charge counter `0x0B00` is deprecated. Don't use it.** It was calibrated at about 460 Wh per unit at first. Then a controlled 5-minute AC charge at constant power showed it isn't a linear energy counter at all: it ticks on internal BMS and OBC state-machine events. All energy now comes from ΔSOC and pack capacity.

Physical constants live in `Bz5Model` in `lib/services/connection.dart`.

---

## Known gaps

* **There's no collector service.** Collection runs inside the Flutter engine inside the activity, and the only service in the manifest is the autostart one. When Android kills the process, collection stops until something wakes it up again. A headless collector is still an open design question.
* **The tick stream has gaps** of roughly 35-40 s per session. It reproduces across sessions and the cause isn't known.
* Head-unit installs are still manual. In-app installation is being worked on.

---

## Vehicle support

Checked on the Toyota BZ5 (FAW-Toyota). The DID map and the HAL signal table were worked out for that car specifically. Other DiLink 5.0 or BYD e-platform vehicles may work in part, and the head-unit side is likelier to port than the OBD side, but nothing is promised.

---

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). Two clauses to know before you fork: section 6 grants no rights in anyone's trademarks, and section 4(b) says a modified file has to be marked as modified, so a fork doesn't get mistaken for this build.

**Supplied free of charge, outside any commercial activity.** No paid edition, no paid service, and no donation that gates access to the software or its updates. The optional cloud sync collects vehicle telemetry only to serve the app itself.

Security reports: see [SECURITY.md](SECURITY.md).

---

## Acknowledgments

Built by one owner over several months of driving, reading and reverse engineering, with Claude (Anthropic) doing protocol analysis, code generation and most of the verification harness. Scattered posts in Chinese and Russian EV communities pointed at where to look first.
