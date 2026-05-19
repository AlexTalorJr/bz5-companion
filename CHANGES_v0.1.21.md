# BZ5 Companion v0.1.21 — Changes

**Bumped:** 0.1.20+1 → 0.1.21+1
**Files touched:** 10 (660 insertions, 88 deletions)
**Triggered by:** driving livelogs 13/14 + sweep 16 (2026-05-19) + user hypothesis

## Headline findings

### 🏆 790/0x1FFD high16 = SOC × 100 (precision 0.01%)

User's hypothesis verified perfectly. The DID we'd been calling "counter A" actually carries the high-precision SOC the project has been chasing since the original handoff. Verification:

| Time | Source | Snapshot SOC | 1FFD high16 / 100 | Δ |
|---|---|---|---|---|
| 2026-05-18 19:43 | sweep_11 | 56% | 55.50% | 0.50 |
| 2026-05-19 10:05 | session 13 start | 55% | 55.40% | 0.40 |
| 2026-05-19 10:13 | session 13 end | 54% | 53.90% | 0.10 |
| 2026-05-19 10:30 | sweep_16 + snapshot | 49% | 49.40% | 0.40 |

All four within ±0.5% (the rounding artifact between integer SOC at 790/0x0005 and precise SOC). Layout: `1FFD = [SOC×100 : u16 BE][const 0x3B09 : u16]`.

### 🏆 740/0x0008 = Vehicle speed (raw / 14.09 = km/h)

Previously labeled "Sub-pack V #1" with scale ×0.1 (which gave nonsensical ~97V "sub-pack" reading). Re-derived 2026-05-19:
- At standstill (cyc 1-4 of session 14): raw = 0
- At user-reported "90 km/h cruise" (cyc 121-140): raw = 1268 → **90.0 km/h exact**
- During acceleration phase: smooth ramp 0 → 1280

First confirmed live signal from 740 ECU under driving load.

### 🐛 v0.1.20 cell sanity guard didn't cover livelog write path

Livelog DOES NOT go through `_pollEcu()` and bypassed the v0.1.20 cell pair guard. Session 13 produced 27 / 159 cycles (17%) with `cellMax < cellMin` or `|spread| > 100mV`. Fixed by adding a separate guard layer in the livelog write path.

### 🐛 0xFFFF "data not available" written as real value

During heavy regen, BMS returned `620015FFFF` for 7 consecutive cycles in session 13. Standard UDS "no-data" marker, but the code wrote it as raw 65535 → 65535 × 0.025 = **1638 V** in graphs. Fixed by universal 0xFFFF detection in livelog sanity check (Layer 1).

## Patch details

### Patch A — Registry: sanity ranges + custom decoders (`ecu_registry.dart`)

Added two new categories:
- `DidCategory.soc` — for any SOC source (raw int or precise float)
- `DidCategory.dynamic` — changes under driving load (speed, motor signals)

Added to `DidSpec`:
- Optional `sanityRawMin`/`sanityRawMax` for per-DID range validation
- Method `checkSanityRaw(int)` → returns `'SANITY:*'` tag or null
- Universal handling of 0xFFFF (u16) and 0xFFFFFFFF (u32) as "data not available"

`decodeDid()` extended with a custom rule for `category: soc && did: 1FFD`: parses as 4-byte payload, returns `high16 / 100.0` as the SOC percentage. This means the registry-driven `_pollEcu` loop automatically populates `_latestValues['790']['1FFD']` with the right value — no special-case code needed in `connection.dart`.

DID re-labels (740):
- `0x0008` → **Vehicle speed**, scale 0.07097 (≈ 1/14.09), sanity 0..3000
- `0x0009` → **Motor signal (TBD)** — has ±200 swings under load but no clear semantic yet
- Removed misleading "Sub-pack V" labels

DID sanity additions:
- `790/0x0005` (SOC): 0..100
- `790/0x002B`/`002D` (cell V): 2000..3700 mV (LFP range with margin)
- `790/0x0015` (HV bus): raw 8000..24000 (= 200..600 V at ×0.025)
- `740/0x0010`/`0011` (PDU temp): raw 0..200 (offset −40 = −40..160 °C)

### Patch B — Livelog Layer-1 sanity guard (`connection.dart`)

New helper `_livelogSanityCheck(txEcu, did, rawHex)`:
1. Looks up DidSpec in registry
2. Parses payload as raw integer
3. Calls `spec.checkSanityRaw(raw)`
4. Returns `'SANITY:NA'` / `'SANITY:LOW:nnnn'` / `'SANITY:HIGH:nnnn'` / null

Wired into the livelog write loop BEFORE `insertLiveLogEntry`. On guard hit:
- `rawHex` replaced with `null`
- `errorCode` set to the `SANITY:*` tag
- Entry is still inserted (cycle structure preserved, post-mortem visibility)

### Patch C — Livelog Layer-2 cell pair guard (`connection.dart`)

New async helper `_livelogCellPairGuard(db, sessionId)` runs after a full cycle is written:
1. Fetches the current cycle's entries from DB
2. Locates 790/0x002B and 790/0x002D rows
3. If both passed Layer-1 AND parse as numbers, validates the pair
4. On pair failure (`max < min` OR `|spread| > 100 mV`), post-updates BOTH to `errorCode='SANITY:PAIR:nnn'`

Why two layers: single ELM frame can swap responses between DIDs polled in the same cycle. Each value individually passes Layer-1 (both are physically possible cell voltages), but the pair is impossible. Catching requires looking at them together.

### Patch D — Precise SOC integration (`connection.dart` + `ecu_registry.dart`)

Two-step:
1. Registry decoder (Patch A) populates `_latestValues['790']['1FFD']` with `high16 / 100.0`
2. New getter `socPrecisePct` in `ConnectionService` reads that value with range guard 0..100

Recommended UI usage:
```dart
final soc = svc.socPrecisePct ?? svc.socPercent?.toDouble();
```

### Patch E — Vehicle speed getter (`connection.dart`)

Getter `vehicleSpeedKmh` reads decoded value from `_latestValues['740']['0008']` (registry handles the ×0.07097 scale). Range guard 0..220 km/h.

### Patch F — Trip metrics expansion (`database.dart` + `connection.dart`)

Database schema v4 → v5 (additive migration only, existing trips unaffected):
- `peakSpeedKmh` — already in v4, populated now for the first time
- `avgMovingSpeedKmh` — average across moving samples (speed > 1 km/h)
- `movingSeconds` — accumulated wall-clock seconds with speed > 1 km/h
- `idleSeconds` — accumulated wall-clock seconds in Ready but speed ≤ 1 km/h
- `energyFromSocKwh` — independent energy metric: `(socStart_precise − socEnd_precise) × pack_capacity_kWh / 100`. Higher resolution than the integer-SOC version.

Tracking logic in `_trackTripMetrics()`:
- Each cycle: read speed, peg as moving/idle based on > 1.0 km/h threshold
- Time delta from last sample (rough — poll cycles are 1.2-8s)
- Avg computed at trip-end as `_tripSpeedSum / _tripSpeedSamples`
- Trip-start precise SOC captured the first time 1FFD is seen

### Patch G — About screen updates (`about.dart`)

- 790 BMS DID list: added 0x1FFD with "★ (v0.1.21)" marker
- 740 PDU section: added 0x0008 (Vehicle speed) and 0x0009 (Motor signal TBD)
- Removed incorrect "0x0B03 = total cells 136" line (it's a platform constant, same byte on BZ3 and BZ5 with different physical cell counts)

## Regression checklist (all green)

Static analysis on all 10 touched files:
- ✓ Brace/paren balance OK everywhere
- ✓ No duplicate identifier definitions (caught 2 dupes during merge with prior scaffolding, fixed)
- ✓ `packVoltageV` / `hvBusV` / other v0.1.20 getters still exist
- ✓ Snapshot DB write path unchanged
- ✓ `pollEcusDriving` / `pollEcusCharging` / `pollEcusFull` lists unchanged
- ✓ All v0.1.21 audit checks: 17/17

Behavioral simulation on real captured data:
- ✓ 1FFD decoder: 4/4 verification points within ±0.5% of integer SOC
- ✓ Speed decoder: 0 km/h at standstill, 89.99 km/h at user's "90 km/h cruise" (Δ=0.01)
- ✓ Layer-1 guard on session 13: 14 × HV-bus 0xFFFF caught, no false positives
- ✓ Layer-2 guard on session 13: 27 / 159 pair anomalies caught (17.0% — higher than session 8's 3.6% because session 13 had heavier accel/regen)

## What still needs verification on real hardware

Tomorrow's quick test (~3-5 min driving):
1. Drive briefly with a livelog of `790/0x1FFD, 790/0x0015, 790/0x002B, 790/0x002D, 740/0x0008`
2. Confirm 1FFD shows ~0.49 → 0.48 → 0.47... evolving smoothly during driving (not jumping in 1% steps)
3. Confirm 0x0015 no longer shows 1638 V outliers in the captured CSV
4. Confirm session has zero cell-pair-spread anomalies in export
5. Confirm 740/0x0008 matches your speedo

If all four pass — v0.1.21 is locked in for daily use.

## Known TODO (post-v0.1.21)

- Trip dashboard UI: surface new metrics (avg speed, moving/idle time, energy from precise SOC)
- 1FFE low16 still unexplained — needs 30+ minute livelog to catch any rate change
- 740/0x0009 motor signal — needs simultaneous logging with pedal/torque DID once we find one
- Phase 2 VehicleProfile abstraction (BZ3 support) — wait until we have BZ3 livelog
