# TelemetryDecoderTable — change log

Single source of truth for decoder changes shared between **bz5_recon**
(upstream, owns the table) and **bz5_companion** (downstream, copies the
table + adds local `companionOverrides`).

## Why this file exists

`TelemetryDecoderTable.kt` is copied between repos with a checksum header,
so a raw `git diff` of the file won't apply cleanly downstream (different
package line, different header, possible local overrides). This changelog
carries **only the delta** in a language-agnostic, copy-paste-ready form,
so the companion maintainer can sync just what changed without re-merging
the whole file.

## How to read this (companion maintainer / Друг 1)

1. Find the version you last synced (your checksum header says e.g.
   `recon v0.10.51`).
2. Apply every entry **newer** than that version, top to bottom.
3. Bump your file's checksum header to the newest recon version listed.
4. Your `companionOverrides` map is never touched by these entries — it
   layers on top of the base table at runtime.

## Entry legend

```
+ ADD     <key>  <name>  <unit>  <SOURCE>
          confidence: <why this is now trusted — correlation / ground truth>
          → <exact Kotlin put(...) line to paste into base table>

~ CHANGE  <key>  <field that changed>
          <old> → <new>  (<reason>)
          → <exact replacement Decoder(...) line>

- REMOVE  <key>  <name>
          <reason it's being demoted/removed>
          (delete the matching put(...) line; if it was a hypothesis,
           it may move to the commented HYPOTHESIS block instead)
```

`<SOURCE>` is one of `INT` / `DOUBLE` / `BUFDATA` (the `ValueSource`).
`<key>` is `"${targetKey}|0x${SUBTYPE_HEX8}"` exactly as it appears in the
table.

## Confidence bar for promotion (agreed with Друг 1, patch 069 review)

A decoder may go from commented-HYPOTHESIS to active `+ ADD` only when it
has **independent confirmation**, not just a plausible physical range:
- time-series correlation r ≥ 0.8 against a known signal, OR
- ground-truth match (dashboard readout, OBD cross-read, controlled input), OR
- exact-value cross-check against another confirmed fid.

Anything weaker stays commented with a `NEEDS-CORR-WITH-X` note.

---

# Changelog

## v0.10.52 (patch 072) — 2026-06-10 — BASELINE

Initial shared baseline at first companion handoff. **33 active decoders,
5 gated hypotheses.** This is a docs-only release: it adds this changelog
and a process-comment to the table header — the 33+5 decoder set is
byte-for-byte identical to v0.10.51, only the file header comment changed.
Companion copies the table at this checksum:
`SHA256 a4aedb627b9a30bddbc0734642a825390a1c3dc3a7c39ecc043a1b944571fa07`.

### Active (33)

| key | name | unit | source |
| --- | --- | --- | --- |
| `BYDAutoChargingDevice\|0x2D300008` | pack_voltage | V | INT |
| `BYDAutoChargingDevice\|0x2D300018` | pack_current | A | DOUBLE |
| `BYDAutoEnergyDevice\|0x45400030` | cell_v_highest | V | DOUBLE |
| `BYDAutoEnergyDevice\|0x45400010` | cell_v_lowest | V | DOUBLE |
| `BYDAutoEnergyDevice\|0x45400008` | cell_idx_highest | — | INT |
| `BYDAutoEnergyDevice\|0x45400028` | cell_idx_lowest | — | INT |
| `BYDAutoStatisticDevice\|0x15100008` | speed | km/h | INT |
| `BYDAutoStatisticDevice\|0x47300018` | insulation_resistance | MΩ | INT |
| `BYDAutoStatisticDevice\|0x99000191` | battery_serial | — | BUFDATA |
| `BYDAutoStatisticDevice\|0x49502010` | odometer | km | INT (×0.1) |
| `BYDAutoStatisticDevice\|0x49503010` | trip_a | km | INT (×0.1) |
| `BYDAutoStatisticDevice\|0x49503024` | trip_b | km | INT (×0.1) |
| `BYDAutoStatisticDevice\|0x49507032` | aux_battery_12v | V | DOUBLE |
| `BYDAutoEngineDevice\|0x28A00008` | motor_rpm | RPM | INT |
| `BYDAutoGearboxDevice\|0x0FB00020` | gear_enum | — | INT |
| `BYDAutoGearboxDevice\|0x22A00022` | brake_toggle | — | INT |
| `BYDAutoAcDevice\|0x2FC0001C` | ac_fan_speed | — | INT |
| `BYDAutoAcDevice\|0x2FC00018` | ac_temp_level | — | INT |
| `BYDAutoAcDevice\|0x2FC00028` | ac_setpoint | °C | DOUBLE |
| `BYDAutoAcDevice\|0x2FC0000C` | ac_on | — | INT |
| `BYDAutoAcDevice\|0x2FC00012` | ac_auto | — | INT |
| `BYDAutoAcDevice\|0x2FC0000B` | ac_recirc | — | INT |
| `BYDAutoAcDevice\|0x2FC00009` | ac_defrost | — | INT |
| `BYDAutoAcDevice\|0x2FC0000A` | ac_compressor | — | INT |
| `BYDAutoTyreDevice\|0x99000128` | tyre_pressure_generic | kPa | INT |
| `BYDAutoRadarDevice\|0x99000061` | radar_fl_corner | cm | INT |
| `BYDAutoRadarDevice\|0x99000062` | radar_fl_center | cm | INT |
| `BYDAutoRadarDevice\|0x99000063` | radar_fr_center | cm | INT |
| `BYDAutoRadarDevice\|0x99000064` | radar_fr_corner | cm | INT |
| `BYDAutoRadarDevice\|0x99000065` | radar_rl_corner | cm | INT |
| `BYDAutoRadarDevice\|0x99000066` | radar_rl_center | cm | INT |
| `BYDAutoRadarDevice\|0x99000067` | radar_rr_center | cm | INT |
| `BYDAutoRadarDevice\|0x99000068` | radar_rr_corner | cm | INT |

### Gated hypotheses (5) — commented out, NEEDS-CORR

| key | name | what's needed to promote |
| --- | --- | --- |
| `BYDAutoChargingDevice\|0x2FF00030` | pack_voltage_alt | corr-with primary pack_voltage on charge run |
| `BYDAutoEngineDevice\|0x40F00008` | pack_voltage_xcheck | r=0.66 currently — needs r≥0.8 on drive run |
| `BYDAutoEngineDevice\|0x3DB00008` | inverter_motor_temp | OBD temp cross-read or charge-soak curve |
| `BYDAutoEngineDevice\|0x15100020` | motor_torque | r=0.52 currently — pedal pos / clean accel-coast-regen segment |
| `BYDAutoGearboxDevice\|0x21800411` | clutch_toggle | semantic unknown (BZ5 has no clutch) — deliberate paddle/pedal test |

### Known-partial (active but incomplete) — note for companion

- `gear_enum`: 1=Park, 2=Reverse, 4=Drive confirmed; **3=unknown** (needs
  controlled gear sequence). Park-hold detection (for trip segmentation)
  works regardless.
- `tyre_pressure_generic`: wheel position is encoded in a higher byte; in
  observed trips only some wheel positions delivered callbacks per run.
  Subscription is fine — data arrives when the device emits.

---

## v0.10.53 (patch 073) — 2026-06-10 — targetKey normalization + streaming fix

No new decoders. Two correctness fixes raised by Друг 1 during HalDataSource
bring-up:

~ CHANGE  BYDAutoStatisticDevice_tail|0x49502010  →  BYDAutoStatisticDevice|0x49502010
~ CHANGE  BYDAutoStatisticDevice_tail|0x49503010  →  BYDAutoStatisticDevice|0x49503010
~ CHANGE  BYDAutoStatisticDevice_tail|0x49503024  →  BYDAutoStatisticDevice|0x49503024
~ CHANGE  BYDAutoStatisticDevice_tail|0x49507032  →  BYDAutoStatisticDevice|0x49507032
          The 4 odometer/trip/aux keys lost their `_tail` suffix. Reason:
          `_tail` was a recon subscription-split artifact (defaultTargets
          splits Statistic into head+tail to subscribe >64 fids). companion's
          streamingTargets() uses a single Statistic target, so these fids
          arrive under "BYDAutoStatisticDevice". Keys are now CANONICAL
          (no variant suffix).
          → companion: if you already pasted the v0.10.52 baseline with the
            `_tail` keys, rename those 4 keys to drop `_tail`. OR rely on the
            new normalizeTargetKey() (below) which makes the rename optional.

Two supporting code changes (already in the shared files you re-sync):

1. **decode() now normalizes targetKey.** Strips variant suffixes (_tail,
   _priority, _v2, _narrow, _sweep, _canDataCollect) before lookup, trying
   the exact key first then the normalized key. So a fid arriving as
   "BYDAutoStatisticDevice_tail|0x49502010" (recon) OR
   "BYDAutoStatisticDevice|0x49502010" (companion) both resolve to the same
   decoder. This means: even mismatched suffixes won't silently return null.

2. **streamingTargets() Statistic fix.** Previously subscribed only
   `take(64)` of the prefix-sorted catalog — the 0x495xxxxx block sorts
   beyond #64 on this device, so odometer/trip_a/trip_b/aux_12v were NEVER
   subscribed in companion (decode would never even be called for them).
   Now unions an explicit priority fid list. companion re-sync of
   TargetRegistry.kt is REQUIRED to receive these 4 params.

### New SHA256 (v0.10.53) — update your checksum headers

```
TargetRegistry.kt          b4668fd0d09c4566d935af5c23483401ac40b9393290d6e3e8538a8097991552
TelemetryDecoderTable.kt   2178674794f89d643acab60dfd61999fed975aea07511d36e74c306481e08b2f
```
(TelemetrySink / LiveTelemetrySubscriber / ReflectionCache unchanged from
v0.10.51 — SHAs stable: 28426f4a.. / 925befca.. / 9cf45133.. respectively.)

---

## v0.10.54 (patch 074) — 2026-06-10 — trip-2 drive run promotions

Structured drive run (gear sequence + accel/coast/regen + climate +
parktronic test, with dictaphone timestamps). Net: +2 promoted, 1 enum
completed, 8 AC decoders demoted (contradicted by data).

+ ADD     BYDAutoEngineDevice|0x40F00008  pack_voltage_xcheck  V  INT
          confidence: r=0.889 with Charging|0x2D300008 across 16 driving
          chunks (was r=0.66 in trip-1, now over threshold).
          → put("BYDAutoEngineDevice|0x40F00008",
                 Decoder("pack_voltage_xcheck", "V", ValueSource.INT))

+ ADD     BYDAutoEngineDevice|0x15100020  motor_torque_raw  (no unit)  INT
          confidence: r=0.861 median / r=0.994 on max-peaks with pack_current
          across accel/coast/regen. Sign coherent (accel +, regen −).
          CAUTION: scale unverified — raw range [-48..139] vs BZ5 peak torque
          ~310 Nm, so NO unit and name suffixed _raw. Do not present as Nm.
          → put("BYDAutoEngineDevice|0x15100020",
                 Decoder("motor_torque_raw", "", ValueSource.INT))

~ CHANGE  BYDAutoGearboxDevice|0x0FB00020  gear_enum  notes
          3=unknown → 3=Neutral. Confirmed by R→N→R→D→R→P sequence: full
          enum is now 1=Park, 2=Reverse, 3=Neutral, 4=Drive. No code change
          beyond the notes string — value mapping is interpreted downstream.

- REMOVE  BYDAutoAcDevice|0x2FC0001C  ac_fan_speed
- REMOVE  BYDAutoAcDevice|0x2FC00018  ac_temp_level
- REMOVE  BYDAutoAcDevice|0x2FC00028  ac_setpoint
- REMOVE  BYDAutoAcDevice|0x2FC0000C  ac_on
- REMOVE  BYDAutoAcDevice|0x2FC00012  ac_auto
- REMOVE  BYDAutoAcDevice|0x2FC0000B  ac_recirc
- REMOVE  BYDAutoAcDevice|0x2FC00009  ac_defrost
- REMOVE  BYDAutoAcDevice|0x2FC0000A  ac_compressor
          All 8 AC decoders were an early UNVERIFIED mapping. trip-2 climate
          test (set 23°, driver 21°, fan changes, off/on, auto) produced
          subtypes 0x2FC00014 / 0x2FC00028(INT) / 0x2FC00030 with values 0/1
          — neither the subtypes nor the value shapes match the table. Rather
          than ship wrong labels to your UI ("ac_setpoint: 1°"), all 8 are
          commented out pending a fresh timestamped climate-only test.
          → companion: if you pasted any AC decoder, REMOVE it. AC cards
            should not render until re-mapped.

### Active decoder count: 27 (was 33) — net −6 (+2 promoted, −8 AC demoted)

### Also noted (not table changes)
- Radar front-center sensors (0x99000062, 0x99000063) gave rich parktronic
  data (29–126 cm, 126 = max/no obstacle) — confirms those positions.
- New radar subtypes 0x99000072 / 0x99000073 appeared (0–4 range) — likely
  zone/status, not distance. Not added (unconfirmed).
- inverter_motor_temp (0x3DB00008) still HYPOTHESIS: rose 29→56°C under load
  (plausible) but r=0.50 with current — below bar. Stays commented.

### New SHA256 (v0.10.54)
```
TelemetryDecoderTable.kt   757b802c1df1e1599d4d762bd95618cd87361bbd9198af7a15999d03bb35e7a0
```
(All four other shared files unchanged from v0.10.53.)

---
## v0.10.55 (patch 075) — 2026-06-10 — firmware catalog cross-reference

The BYDAutoFeatureIds firmware catalog (6699 fids) was cross-referenced
against every decoded and undecoded subtype. This gave EXACT firmware names,
confirmed guesses, corrected two misidentifications, and added many new
parameters. Active decoders 27 → 51.

### Corrected (firmware name ≠ our guess)
~ CHANGE  Engine|0x15100020  motor_current_proxy → motor_power (kW)
          Firmware: ENGINE_POWER. NOT a current echo — it's motor power.
          Verified: ENGINE_POWER ≈ torque×ω, ratio 0.99–1.03 (trip-3); peak
          208 ≈ nameplate 200 kW. Correlated with current only because
          P≈V×I at ~constant V. This corrects the earlier (unshipped) current-proxy reading of this fid.
          → put("BYDAutoEngineDevice|0x15100020", Decoder("motor_power","kW",INT))
~ CHANGE  Engine|0x40F00008  pack_voltage_xcheck → motor_control_voltage (V)
          Firmware: ENGINE_DRIVER_MOTOR_CONTROL_VOLTAGE (inverter DC bus),
          not a pack-V cross-check. Tracks pack V (r=0.889) but distinct.
~ CHANGE  Statistic|0x49507032  aux_battery_12v → avg_consumption_50km (kWh/100km)
          Firmware: STATISTIC_LAST_50KM_EQUAL_FUEL_CON. Owner confirmed 12.8
          = avg consumption last 50 km, NOT 12V aux. Earlier misread.
          (No confirmed AUX-12V fid now — open item.)
~ CHANGE  Gearbox|0x21800411  clutch_toggle(hypothesis) → epb_state
          Firmware: GEARBOX_EPB_STATE (electronic parking brake). BZ5 has no
          clutch. Promoted from hypothesis.
~ CHANGE  Gearbox|0x22A00022  brake_toggle → brake_pedal (GEARBOX_BRAKE_PEDAL)

### Promoted to active (firmware-confirmed)
+ ADD  Engine|0x28A00018  motor_torque  Nm  DOUBLE
       ENGINE_DRIVER_MOTOR_TORQUE. Signed, peak 330 Nm = nameplate; T×ω
       matches ENGINE_POWER and 200 kW. This is the REAL torque (the thing
       0x15100020 was mistaken for in v0.10.54).
+ ADD  Engine|0x3DB00010  motor_temp  °C  INT  (ENGINE_DRIVER_MOTOR_TEMP)
+ ADD  Engine|0x3DB00008  inverter_temp  °C  INT  (ENGINE_DRIVER_MOTOR_CONTROL_TEMP;
       distinct from motor_temp, r=0.03 — two real temperatures)
+ ADD  Statistic|0x2D300030  soc_battery  %  INT  (STATISTIC_SOC_BATTERY_PERCENTAGE)
+ ADD  Statistic|0x49505038  soc_display  %  DOUBLE  (STATISTIC_ELEC_PERCENTAGE)
+ ADD  Statistic|0x49507028  ev_range  km  INT  (STATISTIC_ELEC_DRIVING_RANGE)
+ ADD  Statistic|0x44500830  instant_consumption  kWh/100km  INT  (STATISTIC_INSTANT_EV_CONSUME)
+ ADD  Statistic|0x47800020  cell_temp_lowest  °C  INT  (STATISTIC_PROBE_LOWEST_TEMP)

### TPMS — full 4-wheel, positions EXACT from firmware (no guessing)
+ ADD  Tyre|0x99000124  tyre_pressure_fl  kPa  (TYRE_PRESSURE_VALUE_LEFT_FRONT)
+ ADD  Tyre|0x99000128  tyre_pressure_fr  kPa  (RIGHT_FRONT) — was tyre_pressure_generic
+ ADD  Tyre|0x9900012C  tyre_pressure_rl  kPa  (LEFT_REAR)
+ ADD  Tyre|0x99000130  tyre_pressure_rr  kPa  (RIGHT_REAR)
+ ADD  Tyre|0x99000183  tyre_temp_fl  °C  (LEFT_FRONT)
+ ADD  Tyre|0x99000185  tyre_temp_fr  °C  (RIGHT_FRONT)
+ ADD  Tyre|0x99000187  tyre_temp_rl  °C  (LEFT_REAR)
+ ADD  Tyre|0x99000189  tyre_temp_rr  °C  (RIGHT_REAR)
       Pressure kPa (287–292 = 2.87–2.92 bar) and temp °C confirmed against
       owner reading (2.7–2.9 bar, ~20°C). Companion's earlier fix-1 fix-2
       wheel-position questions are now resolved from firmware directly.

### AC — re-mapped from firmware (names exact, value SCALE still TBD)
+ ADD  Ac|0x2FC00028  ac_temp_main  (AC_TEMP_MAIN, driver setpoint)
+ ADD  Ac|0x2FC00030  ac_temp_deputy  (AC_TEMP_DEPUTY, passenger)
+ ADD  Ac|0x2FC0001C  ac_wind_level  (AC_WIND_LEVEL, fan)
+ ADD  Ac|0x2FC00018  ac_wind_mode  (AC_WIND_MODE)
+ ADD  Ac|0x2FC00014  ac_cycle_mode  (AC_CYCLE_MODE)
+ ADD  Ac|0x2FC00010  ac_power_state  (AC_POWER_STATE)
+ ADD  Ac|0x2FC00012  ac_ctrl_mode  (AC_CTRL_MODE)
+ ADD  Ac|0x2FC00038  ac_temp_out  °C  (AC_TEMP_OUT, outside temp)
       NAMES are firmware-exact. VALUE SCALE for temp setpoints is NOT yet
       pinned (trip-2 showed small ints where 21/23 expected). companion:
       treat AC temp values as raw until a dedicated stationary climate test
       confirms scale/offset. Wind/mode/state toggles are safe to show.

### streamingTargets() updated
TargetRegistry.streamingTargets() Statistic priority list extended with the
5 new Statistic fids (soc_battery, soc_display, ev_range, instant_consumption,
cell_temp_lowest). companion MUST re-sync TargetRegistry.kt to receive them.

### Active decoder count: 27 → 51

### Lesson logged
Firmware catalog names are authoritative for SEMANTIC (what a fid is), but
not always for unit/scale (how to interpret the value). 0x49507032 looked
like 12V but the owner confirmed the catalog's "avg consumption" reading —
so trust the catalog name, verify the scale against ground truth.

### New SHA256 (v0.10.55)
```
TargetRegistry.kt          627031f86402719a6cbeadbbc189ae87f413ea6d7540b5195fceac809648d1d2
TelemetryDecoderTable.kt   ac6a42a6540520e41a8269ff43897c0a46ba0b6295e7e90e1e46f50ff6d80801
```
(TelemetrySink / LiveTelemetrySubscriber / ReflectionCache unchanged from v0.10.51.)

NOTE: version jumps 0.10.54 → 0.10.55 directly. An intermediate WOT-analysis
patch existed in a side branch (motor_current_proxy) but was never shipped —
the firmware catalog superseded its conclusion before it reached origin, so
it was dropped to keep history linear.

---

## v0.10.57 (patch 078) — 2026-06-11 — radar firmware-faithful re-map + probe states

Source: 2026-06-11 three-session run on v0.10.56. Session 3 = dedicated
parking-sensor maneuvers: 608 radar callbacks, all 16 radar fids fired.

### ~ CHANGE — 8 radar distance decoders renamed to firmware fid names

The patch-066 corner/center labels were pre-catalog positional GUESSES and
mislabelled the four rear/side sensors. Firmware catalog is authoritative.
Only the semantic (which sensor each fid is) changed; unit stays cm, scale
unchanged. Before this, companion placed 4 of 8 sensors in the wrong UI slot.

```
~ CHANGE  BYDAutoRadarDevice|0x99000061  name   radar_fl_corner -> radar_obstacle_left_front
          -> Decoder("radar_obstacle_left_front", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT_FRONT (front, outer left)")
~ CHANGE  BYDAutoRadarDevice|0x99000062  name   radar_fl_center -> radar_obstacle_front_left_mid
          -> Decoder("radar_obstacle_front_left_mid", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_FRONT_LEFT_MID (front, inner left)")
~ CHANGE  BYDAutoRadarDevice|0x99000063  name   radar_fr_center -> radar_obstacle_front_right_mid
          -> Decoder("radar_obstacle_front_right_mid", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_FRONT_RIGHT_MID (front, inner right)")
~ CHANGE  BYDAutoRadarDevice|0x99000064  name   radar_fr_corner -> radar_obstacle_right_front
          -> Decoder("radar_obstacle_right_front", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT_FRONT (front, outer right)")
~ CHANGE  BYDAutoRadarDevice|0x99000065  name   radar_rl_corner -> radar_obstacle_left   (WAS MISLABELLED: rear OUTER-LEFT side sensor, not a rear-left corner)
          -> Decoder("radar_obstacle_left", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT (rear, outer left)")
~ CHANGE  BYDAutoRadarDevice|0x99000066  name   radar_rl_center -> radar_obstacle_left_rear
          -> Decoder("radar_obstacle_left_rear", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT_REAR (rear, inner left)")
~ CHANGE  BYDAutoRadarDevice|0x99000067  name   radar_rr_center -> radar_obstacle_right_rear
          -> Decoder("radar_obstacle_right_rear", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT_REAR (rear, inner right)")
~ CHANGE  BYDAutoRadarDevice|0x99000068  name   radar_rr_corner -> radar_obstacle_right  (WAS MISLABELLED: rear OUTER-RIGHT side sensor)
          -> Decoder("radar_obstacle_right", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT (rear, outer right)")
```

### + ADD — 8 radar probe-state decoders

confidence: all 8 fired live in s3 (ground truth = parking maneuver). Enum
0-4, 0 when clear. Value->meaning mapping not yet decoded (raw enum). Names
firmware-exact.

```
+ ADD  BYDAutoRadarDevice|0x99000071  radar_state_left_front       ""  INT
       -> put("BYDAutoRadarDevice|0x99000071", Decoder("radar_state_left_front", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT_FRONT; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000072  radar_state_front_left_mid   ""  INT
       -> put("BYDAutoRadarDevice|0x99000072", Decoder("radar_state_front_left_mid", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_FRONT_LEFT_MID; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000073  radar_state_front_right_mid  ""  INT
       -> put("BYDAutoRadarDevice|0x99000073", Decoder("radar_state_front_right_mid", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_FRONT_RIGHT_MID; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000074  radar_state_right_front      ""  INT
       -> put("BYDAutoRadarDevice|0x99000074", Decoder("radar_state_right_front", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT_FRONT; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000075  radar_state_left             ""  INT
       -> put("BYDAutoRadarDevice|0x99000075", Decoder("radar_state_left", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000076  radar_state_left_rear        ""  INT
       -> put("BYDAutoRadarDevice|0x99000076", Decoder("radar_state_left_rear", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT_REAR; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000077  radar_state_right_rear       ""  INT
       -> put("BYDAutoRadarDevice|0x99000077", Decoder("radar_state_right_rear", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT_REAR; enum 0-4, semantics TBD"))
+ ADD  BYDAutoRadarDevice|0x99000078  radar_state_right            ""  INT
       -> put("BYDAutoRadarDevice|0x99000078", Decoder("radar_state_right", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT; enum 0-4, semantics TBD"))
```

### TargetRegistry note (recon-only, no companion action)
defaultTargets() dropped the dead Gb/Speed/Bodywork p077 targets (all walled
at getInstance). streamingTargets() unchanged — companion already subscribes
to all RADAR_* via pickReadOnlyIds(radarNamedIds, 32), so the 8 new probe
states arrive automatically once you sync the table delta above. No re-sync
of TargetRegistry.kt needed this patch.

### Active decoder count: 51 -> 59  (+8 probe states; 8 renames net 0)

### New SHA256 (v0.10.57)
(recompute after apply; TargetRegistry.kt + TelemetryDecoderTable.kt changed;
 the other four live/ files unchanged from v0.10.51.)

---

<!--
TEMPLATE for the next entry — copy below this line, fill in, delete the comment:
                 Decoder("param_name", "unit", ValueSource.SOURCE))

~ CHANGE  BYDAutoXxxDevice|0xZZZZZZZZ  scale
          0.1 → 1.0  (<reason>)
          → Decoder("param_name", "unit", ValueSource.SOURCE)

- REMOVE  BYDAutoXxxDevice|0xZZZZZZZZ  param_name
          <reason>
-->
