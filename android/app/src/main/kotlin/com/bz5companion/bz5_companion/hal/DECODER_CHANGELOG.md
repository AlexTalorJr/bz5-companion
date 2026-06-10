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



## vX.Y.Z (patch NNN) — YYYY-MM-DD

+ ADD     BYDAutoXxxDevice|0xZZZZZZZZ  param_name  unit  SOURCE
          confidence: <correlation / ground truth / cross-check detail>
          → put("BYDAutoXxxDevice|0xZZZZZZZZ",
                 Decoder("param_name", "unit", ValueSource.SOURCE))

~ CHANGE  BYDAutoXxxDevice|0xZZZZZZZZ  scale
          0.1 → 1.0  (<reason>)
          → Decoder("param_name", "unit", ValueSource.SOURCE)

- REMOVE  BYDAutoXxxDevice|0xZZZZZZZZ  param_name
          <reason>
-->
