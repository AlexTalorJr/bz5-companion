# BZ5 Companion v0.1.20 — Changes

**Bumped:** 0.1.19+1 → 0.1.20+1
**Files touched:** 9
**Triggered by:** parking sweeps 13/14/15 + BZ3 cross-validation + analysis of trips export 2026-05-18

## Patch summary

### Patch 1 — Cell V pair sanity guard (`connection.dart`)
**Bug:** ~3.6% of livelog driving samples (14/384 in session 8) had `cellMax < cellMin` or `|spread| > 100 mV` due to ELM stream misalignment not fully caught by v0.1.16 frame check. Leaked into snapshots (visible: 2026-05-18 snapshot id=26 spread=−2 mV).

**Fix:** Read 0x002B and 0x002D into local candidates first, validate pair, commit only if sane. Keep previous known-good values on drop. Counter `_cellPairDropCount` + getter for Diagnostics surfacing.

**Test:** Simulation against real session 8 data — guard catches exactly 14 anomalies (3.6% drop rate, matches analysis).

### Patch 2 — Pack V correction (`ecu_registry.dart` + 2 dashboard files)
**Bug:** 740/0x0014, 0x0016, 0x0022, 0x0023 were labeled as "Pack V instant/filtered/avg/alt" with ×0.025 scale. Reality: they are platform-nominal CONSTANTS (~450V on BZ5). Evidence:
- 5 trips on 2026-05-18: SOC 64→55%, HV bus 393→413V swing, cells −35 mV under load, but pack_v stayed glued to 450.0 ± 0.3
- Two parking sweeps 2 hours apart with driving in between: byte-identical (`4650 → 4650`)
- BZ3 cross-check: same DIDs return ~450V despite physical pack being ~85S/280V

**Fix:**
- Registry: labels rewritten to "Pack V nominal (const)" etc, category changed to `unknown` so they no longer appear as voltage measurements
- Dashboard (phone): `_MetricCard` "Pack V" now sources `hvBusV` first, falls back to `packV.toStringAsFixed(1) V*` with asterisk marker
- Dashboard wide: `_PackVoltageHero` reworked — HV bus is the 48-pt yellow primary, nominal V demoted to sidebar; header "PACK VOLTAGE (LIVE)"; widget params renamed `filteredV/instantV → nominalV/nominalInstV`

**Backward compat preserved:** `packVoltageV` getter kept (snapshot DB column still populated for historical continuity). Doc-comment rewritten to flag it as platform constant.

### Patch 3 — 740/0x0010, 0x0011 reclassified as PDU temps (`ecu_registry.dart`)
**Bug:** Labeled as "Contactor 1/2" status flags.

**Fix:** Now `DidSpec(name: 'PDU temp 1/2', offset: −40, category: thermal)`. Evidence: values dropped 19/18 raw units between yesterday-after-driving and today-after-cooldown sweeps (consistent with heatsink cooldown).

### Patch 4 — 782 OBC fully remapped (`ecu_registry.dart`)
Old labels were placeholders. New definitions based on parking sweep #13 + BZ3 cross-check:
- `0x0006`, `0x000B` → Charge V target (500V, identical on both cars)
- `0x000C` → Charge I max, scale ×0.1 (1000 → 100.0 A)
- `0x0009` → Charger V reading (semantics TBD — verify in charging session)
- `0x000A` → OBC operating hours (counter, +1 unit between BZ3/BZ5)
- `0x000F`, `0x0010` → OBC temp 1/2, offset −40 (thermal)
- `0x0057` → state flag, BZ5-only

### Patch 5 — N/A
Originally planned: remove 7E2 preset from sweep screen. There was no 7E2 preset to begin with (user tested via Custom). No code change needed.

### Patch 6 — TX→RX auto-update in Live Log form (`live_log.dart`)
**Bug:** When user changes TX field, RX stays at old value (default 791/0020 stays as 799 even after changing TX to 790). Resulted in silent timeouts that looked like missing DIDs.

**Fix:** `_autoRxForTx(tx)` helper at file scope computes RX = TX + 8 (UDS convention) with width preservation. Wired into TX field's `onChanged`. Only fires on TX change, not RX, so manual RX overrides still work.

**Test:** 13/13 cases pass: all known BZ5 ECUs (790→798, 791→799, 740→748, 782→78A, 7E2→7EA, 752→75A, 757→75F, 702→70A, 7E5→7ED), 4-char width (7901→7909), edge cases (empty/non-hex/too-short → null).

### Cosmetic — "Pack Monitor" → "PDU/HV Junction" everywhere
Renamed in `about.dart` (DID rows + section header), `wide/raw_data_wide.dart`, `sweep.dart` preset, registry labels for 744/745/746. Internal `packMonitorEcu` Dart identifier kept to avoid touching unrelated import sites.

## Regression checklist (all green)

- ✓ Brace/paren balance on all 9 files
- ✓ `packVoltageV` / `packVoltageInstantV` / `hvBusV` getters intact
- ✓ Snapshot DB writing unchanged (columns still populated)
- ✓ `pollEcusDriving` / `pollEcusCharging` / `pollEcusFull` lists unchanged
- ✓ `packMonitorEcu` / `chargerEcu` exports unchanged
- ✓ Sanity guard simulation: 14/384 dropped on real session 8 data (3.6% exact match)
- ✓ TX→RX mapper: 13/13 test cases including all known ECUs + edge cases
- ✓ Zero orphan references to renamed widget params (`filteredV:` / `instantV:`)
- ✓ No "Pack Monitor" string left in codebase

## Driving livelog plan for tomorrow (revised)

Now that 0x0023 is dead as a current candidate (proven constant via two-sweep diff), updated 6-DID set:

| # | TX/RX | DID | Why |
|---|---|---|---|
| 1 | 790/798 | 0x0015 | HV bus — primary live V (already verified, 46V swing) |
| 2 | 790/798 | 0x002B | cell min mV (will now be sanity-guarded) |
| 3 | 790/798 | 0x002D | cell max mV (sanity-guarded) |
| 4 | 790/798 | 0x1FFD | counter A — verify hours-as-low16 hypothesis |
| 5 | 790/798 | 0x1FFE | counter B — same |
| 6 | 740/748 | 0x0010 | PDU temp 1 — does it rise under load? |

All on 2 ECUs (790 and 740), so adaptive inter-DID gap from v0.1.18 should produce clean 80/200 ms spacing.

## Known TODO (post-v0.1.20)

- Driving sweep 790/0x1000-0x1FFF to find Current/Power/SOC×0.1 DIDs (still unsolved)
- Phase 2 architecture: VehicleProfile abstraction for BZ3 support (cell count, scales, DID overrides). Don't start until we have BZ3 livelog data.
- OBC livelog during charging session to verify 782/0x0009 and 782/0x000A semantics
