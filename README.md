# BZ5 Companion

Telemetry and monitoring for the **Toyota BZ5** (FAW-Toyota, BYD e-platform).

The app runs in two different places and reads the car in two different ways:

* on an **Android phone**, over an ELM327 BLE adapter plugged into the OBD-II port;
* **natively on the car's own head unit** (DiLink 5.0, Android 12), where it talks to the BYD vehicle framework directly and needs no adapter at all.

It surfaces what the dashboard keeps to itself: real state of health, per-cell balance across all 136 series cells, pack voltage under load, precise odometer, charging power and energy, and a long-running map of how much the car actually consumes at each speed and each outside temperature.

> **Unofficial project.** Not affiliated with Toyota, FAW-Toyota or BYD. Written by one BZ5 owner, for that car, after off-the-shelf scanners turned out not to see it. There are no stability guarantees: screens, database schema and constants change from build to build.

Current version: **0.1.76+175**. Releases are published automatically as GitHub Releases tagged `build-N`.

---

## Two ways to run it

| Target | How it reads the car | Notes |
|---|---|---|
| Android phone, 12+ | ELM327 BLE adapter, ISO 15765-4 + UDS | Needs the adapter plugged in and the car awake. Full OBD data set including per-cell voltages. |
| BZ5 / BZ3 head unit, DiLink 5.0 (Android 12, API 32) | BYD vehicle HAL push channel, plus the same OBD path if an adapter happens to be present | No adapter needed. Cluster-grade signal quality. Wide layout drawn for the car's own 2175 dp panel. |

### The two data planes

**OBD-II / UDS.** The BZ5 answers on non-standard diagnostic addresses outside the usual `7E0-7E7` block; the addressing rule is `RX = TX + 8`. Thirty-one ECUs are catalogued in `lib/data/ecu_registry.dart` together with the DIDs that were found to mean something. Reads are plain UDS `22 XX YY`.

The head-unit framework exposes its properties as literal hex feature IDs rather than names, and the full parsed registry of them — 10016 entries lifted out of the vehicle software's own configuration — is deliberately **not** published here. The right to decompile for interoperability does not extend to handing the results to everyone; the identifiers this app actually uses are the presets in `native_explorer_wide.dart` and the decoder table beside it.

**BYD vehicle HAL.** On the head unit the app subscribes to the framework's push telemetry. The important architectural detail: only the `*_COMMON` permission family is grantable at runtime, and it only opens the *listener* channel — the synchronous getters behind `*_GET` stay closed. So every live HAL value arrives as a push, never as a poll.

Where the two planes overlap (speed, pack voltage, current, SOC, gear, temperatures) the HAL value silently substitutes for the OBD one inside the *same* widget, in the same position, with no "HAL" badge. Signals that only one plane has — motor RPM, parking sensors, climate, odometer on one side; per-cell voltages and DTCs on the other — appear only where they exist. The rule the UI follows everywhere: **a card is shown when data actually flows, and is absent otherwise** — never a dash standing in for a number nobody measured.

---

## What it shows

**Dashboard.** SOC with range estimate, SOH, battery temperature, pack voltage and HV bus, odometer to 100 m, gear and mechanical parking-pawl state, lifetime cycle count.

**Cells.** All 136 series cells with min/max/spread, graded in context — LFP chemistry legitimately spreads wider near 100%, so a flat threshold would lie.

**Charging.** Live power, energy added this session, time to full. Energy comes from ΔSOC × pack capacity, not from the car's own counter (see *Calibration*).

**Trips and history.** Every drive stored locally with distance, energy, SOC and temperature envelope, peak power and regen. Chart series are persisted separately so they survive a reinstall. Charging is not logged as a trip.

**Trends.** Consumption and efficiency over time, built from odometer/SOC anchor walks rather than from summed trip fields, and averaged only over days where both sides of the ratio are actually covered.

**Measurements.** Steady-state consumption per speed band: a band earns a row after 120 s of qualified in-band driving, with dwell and guard rules so that traffic noise does not manufacture numbers.

**Atlas.** The long game: a grid of **11 speed bands (40-140 km/h) × 12 temperature windows (-20 °C to +35 °C in 5° steps) = 132 cells**. A cell freezes once it has collected its qualified 120 seconds, is stamped with the app version that produced it, and stops moving. Coverage is marked bronze/silver/gold; matured-but-not-frozen cells show as dashed. Collection stops at 140 km/h by design. The whole map can be exported as a shareable image with a QR code.

**Explorers and tools.** ECU explorer, HAL explorer, DID sweep (long, screen-awake), live logging with results view, app diagnostics, and an append-only diagnostic dump that can be handed off as a single file.

**Export.** One ZIP containing CSVs for every table, the SQLite file itself, and the diagnostic dump.

**Install / update screen.** The head unit cannot update an APK in place, so there is a dedicated screen for staging and launching an installation. See *Installing*.

---

## Autostart on the head unit

Android 12 blocks starting a foreground service straight from a broadcast receiver, so the app does not try. Instead:

```
BOOT_COMPLETED / QUICKBOOT_POWERON / MEDIA_MOUNTED
        → setAlarmClock(+250 ms) on itself
        → alarm fires → startForegroundService (allowed from alarm context)
```

Every wake is written to a marker log, which also travels out inside the diagnostic dump so it can be read without pulling files off the device. Measured latency of the bridge in the field is a few seconds rather than the nominal 250 ms — the alarm is exact, the framework's own startup is not.

The app must be opened by hand once after installation, otherwise it stays in Android's *stopped* state and receives no broadcasts at all.

---

## Cloud sync — optional, off until you turn it on

There is a sync client for a self-hosted bridge (`carbridge.neardo.work`). It exists for one concrete reason: the head unit cannot update an APK in place, and every reinstall wipes the local SQLite database.

If you register a device with a setup token, the app uploads trips, snapshots, sweep runs and results, live logs, and a once-a-minute heartbeat carrying the app version. The device token lives in the Android Keystore. Raw high-rate samples are never uploaded — the server refuses them by default and the client does not attempt it. The client never pulls anything back for its own UI; local storage is the source of truth.

**If you never register, nothing leaves the device.** There is no telemetry, no analytics and no third-party SDK anywhere in the build. But the earlier claim that this app "sends no data to any servers" is no longer true in general, and this README says so plainly.

What comes back after a reinstall: trips, snapshots, atlas reveals, chart series. What does **not** come back: raw samples and the Atlas collection ledger — meaning partially collected bands are lost.

---

## What it does not do

* **Read-only as shipped.** Nothing in the app writes to the vehicle: no climate, no locks, no windows. To be precise rather than reassuring: a property-write call does exist in the native layer (`BydCarPropertyClient.setProperty`, wrapped in `native_car_channel.dart`) because the framework exposes one, but it has no callers anywhere in the app and no screen reaches it. Grep for it and see.
* **No clearing of fault codes.**
* **Not a driving display.** Read it parked or charging; background logging while driving is the intended use.
* **No broadcast CAN sniffing over OBD.** The diagnostic gateway is isolated from the vehicle bus, so `ATMA` sees nothing. On the head unit the HAL plane fills part of that gap.
* **No signed pack current over UDS.** It has to be inferred, or taken from HAL on the head unit.
* **No remote access.**
* **No iOS build.**

---

## Installing

**Phone.** Grab the APK from [Releases](../../releases), sideload it, grant Bluetooth and Location (BLE scanning needs Location on Android), then pair the adapter from Settings → *Find adapter*. The OBD port is under the steering column on the left.

**Head unit.** DiLink's built-in installer performs clean installs only — it answers "already installed" to anything it recognises and counts that as success. So: uninstall the old version first, then install. Put the APK in a `SilentInstaller/` folder on a USB stick and plug it into the armrest port. On macOS run `dot_clean -m /Volumes/STICK` first, or AppleDouble `._*` files show up in the installer's list. There is no ADB access to the head unit.

Consequence worth planning around: **every head-unit reinstall wipes preferences and the local database.**

---

## Building from source

Flutter **3.27.4** stable, Dart 3.

One non-obvious thing: `android/` in this repository contains only `app/src/main` — the manifest, the Kotlin sources and the resources. The Gradle project is **not** committed. CI generates it with `flutter create --platforms=android` and then patches it (Kotlin 2.1.0 in `settings.gradle`, release signing in `app/build.gradle`). To build locally, run `flutter create --platforms=android --org com.bz5companion --project-name bz5_companion .` in a checkout first, then `flutter build apk`.

A real device is required for anything involving BLE or the car framework; emulators are useless here.

Workflows in `.github/workflows/`:

* `build.yml` — APK build, then a GitHub Release tagged `build-N` with `make_latest`, where N is the commit count;
* `test.yml` — `flutter test`, independent of the build;
* `lint.yml` — analysis.

---

## Verification harness

Changes to this repository are gated by scripts in `tools/`, run before anything is committed:

| Script | What it checks |
|---|---|
| `check_repo.py` | structural sanity of protected files, layout invariants |
| `const_l10n_check.py` | no localisation lookups inside `const` spans |
| `hal_sync_check.py` | HAL signal table stays in sync with its consumers |
| `regress_plus35.py` | the standing regression suite, organised into lettered eras — every behavioural fix that ever regressed has a named check here |
| `dart_balance.py` | brace/paren balance and missing imports across `lib/` |
| `atlas_a1_check.py` | Atlas identity: frozen ⊕ live must equal the session counter, verified against real field dumps |
| `mirror_plus164.py` | Dart↔Python mirror of the consumption maths |

Baseline for the current HEAD: `7/7` · `OK` · `22/0/0` · `490 PASS / 1 WARN / 0 FAIL` · `74/74`.

Two hard-won rules encoded here: any check that matches source text must strip comments first (five separate gates once passed by reading their own explanatory comment), and every gate must be *mutation-tested* — revert the thing it guards and require that specific gate to fail, or it is not a gate.

---

## Language

The UI ships in **English and Russian** (`lib/l10n/strings.dart`, resolved by `LocaleService`).

Source comments, `docs/` and the gate scripts are substantially in Russian. This is not purely cosmetic: the regression gate alone carries 97 quoted Russian UI strings as match anchors, so the Russian text in this repository is load-bearing and cannot be swapped out without rewriting the harness alongside it.

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

* **Pack capacity 65.28 kWh** on this vehicle; a 73.984 kWh variant is owner-reported. Auto-detection of the variant is not implemented.
* **136 series cells**, read from DID `790/0x0B03` with 136 as the fallback.
* **Nominal 14.4 kWh/100 km** is used only as a fallback for the range estimate when the car's own figure is unavailable.
* **Charge counter `0x0B00` is deprecated and must not be used.** It was originally calibrated at ~460 Wh per unit; a controlled 5-minute AC charge at constant power proved it is not a linear energy counter at all — it increments on internal BMS/OBC state-machine events. All energy now comes from ΔSOC × pack capacity.

Physical constants live in `Bz5Model` in `lib/services/connection.dart`.

---

## Known gaps

* **No collector service.** Collection runs inside the Flutter engine inside the activity; the only declared service is the autostart one. When Android kills the process, collection stops until something wakes it. A headless collector is an open design problem, not a bug with a fix pending.
* **Gaps in the tick stream** of roughly 35-40 s per session, reproducible across sessions, cause unknown.
* Head-unit installs remain manual; in-app installation is in progress.

---

## Vehicle support

Verified on the Toyota BZ5 (FAW-Toyota). The DID map and the HAL signal table were derived specifically for it. Related DiLink 5.0 / BYD e-platform vehicles may work partially — the head-unit side is more likely to port than the OBD side — but nothing is promised.

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Apache rather than MIT for reasons specific to this project: it grants patents explicitly, it states in section 6 that no trademark rights travel with it (which matters in a repository full of other people's model names), it requires modified files to be marked as changed so a broken fork is not mistaken for this build, and its warranty and liability sections are written out rather than compressed into a single line.

**Supplied free of charge, outside any commercial activity.** There is no paid edition, no paid service, and no donation that gates access to the software or to its updates. The optional cloud sync collects vehicle telemetry only in order to serve the app itself. This is stated because it is a condition rather than a slogan: EU law exempts free and open-source software supplied outside a commercial activity from the product-liability and cyber-resilience regimes that otherwise treat software as a product, and that exemption is what this project relies on.

Security reports: see [SECURITY.md](SECURITY.md).

---

## Acknowledgments

Built by one owner over several months of driving, reading and reverse engineering, with Claude (Anthropic) doing protocol analysis, code generation, and most of the verification harness. Scattered posts from Chinese and Russian EV communities pointed at where to look first.
