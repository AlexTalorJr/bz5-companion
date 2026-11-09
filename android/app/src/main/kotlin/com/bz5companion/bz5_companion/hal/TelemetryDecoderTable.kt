// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetryDecoderTable.kt
// Synced: 2026-11-09 (recon v0.10.157.1, commit p157, b1b95ca)
// SHA256: 1538e1e58c43a048f25526d292f6cbbe8a51edfb79dd1dd46114009ebf7a6adc
package com.bz5companion.bz5_companion.hal

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetryDecoderTable.kt
// Owner: bz5_recon (patch 068)
// Sync method: copy-paste with checksum header.
//
// Single source of truth for (targetKey, subtype) → semantic decode. Used
// by bz5_recon for offline JSON post-processing (optional) and by
// bz5_companion DecodedStreamSink for live UI updates.
//
// Friend 1 review (2026-06-09): layered design — base table + per-project
// override map. Companion can override a specific decoder locally without
// touching shared base:
//   val effective = TelemetryDecoderTable.table + companionOverrides
//
// CHANGE PROCESS: do NOT silently edit decoders here. Every add/change/
// remove gets a dated entry in DECODER_CHANGELOG.md (same directory) in
// copy-paste-ready form, so the companion maintainer can sync just the
// delta without re-merging this whole file. See that file's header for
// the promotion confidence bar and entry format.
//
// Sign convention note (clarified Friend 1 + Friend 3, patch 068 review):
// HAL pack_current (BYDAutoChargingDevice|0x2D300018) is discharge-positive.
// UDS C33 pack_current (DID 790/0009) is also discharge-positive. These are
// the SAME convention. No sign flip required between the two sources.
// "Charge negative" is a consequence of "discharge positive", not an
// alternative convention.
//
// Carrier rule (patch 155, recon v0.10.155): the framework delivers BOTH
// mIntValue and mDoubleValue on every event, one real and the other 0 (p081
// observation, RollupSink raw_trace). A decoder declared INT therefore gets a
// literal 0 when the value actually rides in mDoubleValue, and reports that 0
// as a measurement (trip-2 AC_TEMP_MAIN "0/1" where trip-1 saw dbl 23). The
// decode() below no longer trusts the declared source blindly: when the
// declared field is 0/absent and the other field is non-zero, it takes the
// other field and flags DecodedValue.typeConflict = true. ValueSource.ANY
// declares that the carrier is not known yet (new catalog-named AC fids):
// non-zero double wins, then non-zero int, then a true zero. Both carriers
// stay visible offline via RollupSink int_nonzero_n / dbl_nonzero_n.
//
// Decoders verified as of recon v0.10.49 (patch 069, post-Friend-1 review).
// Confirmed entries below have either direct decode verification (string
// payloads, exact-value cross-check) or strong time-series correlation
// (Engine RPM r=0.87 with speed, slope-match with theoretical reducer ratio).
// Hypothesis-only entries (r<0.7 with single candidate, or "physical range
// matches what we expect" without independent cross-check) are commented
// out below and marked NEEDS-CORR-WITH-X — promote to active only after
// the named cross-check confirms the mapping. Friend 1 (companion) review
// (2026-06-09): better to ship 25 known-good decoders than 30 with 5
// silent-fail surprises in production UI cards.

/** Source of the raw value for a [Decoder]. */
enum class ValueSource {
    /** Take `mIntValue` directly. */
    INT,
    /** Take `mDoubleValue` directly. */
    DOUBLE,
    /** No direct numeric value — payload is in `mBufData` (e.g. BigData CAN frames,
     *  Statistic battery serial). Caller must do format-specific extraction. */
    BUFDATA,
    /** Carrier not yet pinned (patch 155): take the non-zero one of
     *  `mDoubleValue` / `mIntValue`, double first. Used for catalog-named fids
     *  whose first live events have not been seen with both fields recorded. */
    ANY
}

/** Decoder spec for one (targetKey, subtype) combo. */
data class Decoder(
    /** Stable semantic name, e.g. "motor_rpm", "pack_current". */
    val name: String,
    /** SI unit, e.g. "RPM", "V", "A", "°C", "km", "km/h". */
    val unit: String,
    /** Which raw field carries the value. */
    val source: ValueSource,
    /** Multiplicative scale: physical = raw * scale + offset. */
    val scale: Double = 1.0,
    /** Additive offset. */
    val offset: Double = 0.0,
    /** Free-form notes (e.g. enum mapping for gear position). */
    val notes: String? = null
)

/**
 * Decoded value emitted by [TelemetryDecoderTable.decode]. Consumed by
 * DecodedStreamSink in bz5_companion to feed UI cards.
 */
data class DecodedValue(
    val name: String,
    val value: Double,
    val unit: String,
    val timestampMs: Long,
    /** Which raw field actually supplied [value] (patch 155). Always set by
     *  decode(); the default only keeps older 4-arg constructor calls compiling. */
    val carrier: ValueSource = ValueSource.DOUBLE,
    /** True when the decoder's declared source was 0/absent and the value was
     *  taken from the other field instead (patch 155). A companion sink may
     *  show such a value but should not promote the fid's carrier on it. */
    val typeConflict: Boolean = false
)

object TelemetryDecoderTable {

    /** Key format: `"${targetKey}|0x${subtypeHex8}"`, where subtype is
     *  formatted as `"0x%08X"` with the upper bit included if set. */
    fun key(targetKey: String, subtype: Long): String =
        "$targetKey|0x" + java.lang.String.format("%08X", subtype and 0xFFFFFFFFL)

    /** Base table — known fids from patches 053–067 + trip-1 validation.
     *  Companion projects can extend via local override map. */
    val table: Map<String, Decoder> = buildMap {
        // ─── Charging ────────────────────────────────────────────────────
        put("BYDAutoChargingDevice|0x2D300008",
            Decoder("pack_voltage", "V", ValueSource.INT,
                notes = "447-454 V parked (136-cell LFP)"))
        put("BYDAutoChargingDevice|0x2D300018",
            Decoder("pack_current", "A", ValueSource.DOUBLE,
                notes = "discharge-positive; same convention as UDS C33"))
        // p083 mislabeled this as charge_power_ac (kW) on a single 2.68 reading.
        // p084 CORRECTION: it is cumulative CHARGE ENERGY in kWh, not power.
        // Evidence (5-min run 20:32, 10 chunks): value rose monotonically
        // 2.025 → 2.141, never falling; dE/dt = 1.74 kW constant; the value did
        // NOT reset between the 19:50 (~0.82) and 20:32 (2.025) sessions, so it
        // is a persistent accumulator (session/daily counter, not per-snapshot).
        // Absolute check: 0.82 kWh / 2.85 kW ≈ 17 min = how long Alex had been
        // charging. dE/dt 1.74 kW < wall 2.6-3.1 kW = OBC losses + cabin/12V
        // load while sitting. Active only while AC-charging.
        put("BYDAutoChargingDevice|0x2C100818",
            Decoder("charge_energy_kwh", "kWh", ValueSource.DOUBLE,
                notes = "cumulative charge energy; monotonic accumulator (persists across sessions); active only while AC-charging; dE/dt≈1.74kW vs wall 2.6-3.1 (OBC+aux losses); scale 1.0"))
        // p156: confirmed pack_voltage_fine. DC-charge run 06.08 verified this
        // as the high-resolution pack terminal voltage; it is the voltage the
        // companion power/energy split runs on. Name/unit/type frozen to match
        // companion (pack_voltage_fine / V / DOUBLE) so its hal_samples history
        // and the companion override carry over without a break.
        put("BYDAutoChargingDevice|0x2FF00030",
            Decoder("pack_voltage_fine", "V", ValueSource.DOUBLE,
                notes = "CHARGING_TOTAL_VOLTAGE; pack terminal V, high-res; verified DC-charge 06.08; powers energy split"))

        // ─── Energy (cells) ──────────────────────────────────────────────
        put("BYDAutoEnergyDevice|0x45400030",
            Decoder("cell_v_highest", "V", ValueSource.DOUBLE,
                notes = "3.25–3.27 V parked LFP"))
        put("BYDAutoEnergyDevice|0x45400010",
            Decoder("cell_v_lowest",  "V", ValueSource.DOUBLE,
                notes = "3.24–3.26 V parked LFP"))
        // p079: names were mirrored. Catalog: 0x...08 = ENERGY_LOWEST_VOLT_
        // BATTERY_NUM, 0x...28 = ENERGY_HIGHEST_VOLT_BATTERY_NUM. Swapped so
        // cell_idx_lowest pairs with cell_v_lowest (0x45400010) and highest
        // with highest (0x45400030).
        put("BYDAutoEnergyDevice|0x45400008",
            Decoder("cell_idx_lowest", "", ValueSource.INT,
                notes = "ENERGY_LOWEST_VOLT_BATTERY_NUM; index of lowest-voltage cell; 1–136"))
        put("BYDAutoEnergyDevice|0x45400028",
            Decoder("cell_idx_highest",  "", ValueSource.INT,
                notes = "ENERGY_HIGHEST_VOLT_BATTERY_NUM; index of highest-voltage cell; 1–136"))

        // ─── Statistic (head, first 64) ──────────────────────────────────
        put("BYDAutoStatisticDevice|0x15100008",
            Decoder("speed", "km/h", ValueSource.INT,
                notes = "averaged ~8.7 Hz; verified ground-truth in trip-1"))
        put("BYDAutoStatisticDevice|0x47300018",
            Decoder("insulation_resistance", "MΩ", ValueSource.INT, scale = 0.001,
                notes = "STATISTIC_INSULATION_RESISTANCE_VALUE; raw kΩ ×0.001→MΩ; 11.8–14.1 MΩ healthy"))
        put("BYDAutoStatisticDevice|0x99000191",
            Decoder("battery_serial", "", ValueSource.BUFDATA,
                notes = "48B ASCII; decoded as string"))

        // ─── Statistic (tail) ────────────────────────────────────────────
        put("BYDAutoStatisticDevice|0x49502010",
            Decoder("odometer", "km", ValueSource.INT, scale = 0.1,
                notes = "STATISTIC_TOTAL_MILEAGE; raw units 100 m → ×0.1 = km"))
        put("BYDAutoStatisticDevice|0x49503010",
            Decoder("trip_a", "km", ValueSource.INT, scale = 0.1))
        put("BYDAutoStatisticDevice|0x49503024",
            Decoder("trip_b", "km", ValueSource.INT, scale = 0.1))
        put("BYDAutoStatisticDevice|0x49507032",
            Decoder("avg_consumption_50km", "kWh/100km", ValueSource.DOUBLE,
                notes = "STATISTIC_LAST_50KM_EQUAL_FUEL_CON; 12.8 observed (avg consumption last 50km). NOT aux 12V — earlier misread."))

        // ─── Statistic (new from firmware catalog, patch 075) ────────────
        put("BYDAutoStatisticDevice|0x2D300030",
            Decoder("soc_battery", "%", ValueSource.INT,
                notes = "STATISTIC_SOC_BATTERY_PERCENTAGE; BMS state of charge"))
        put("BYDAutoStatisticDevice|0x49505038",
            Decoder("soc_display", "%", ValueSource.DOUBLE,
                notes = "STATISTIC_ELEC_PERCENTAGE; dashboard-displayed charge %"))
        put("BYDAutoStatisticDevice|0x49507028",
            Decoder("ev_range", "km", ValueSource.INT,
                notes = "STATISTIC_ELEC_DRIVING_RANGE; estimated remaining range"))
        put("BYDAutoStatisticDevice|0x44500830",
            Decoder("instant_consumption", "kWh/100km", ValueSource.INT,
                notes = "STATISTIC_INSTANT_EV_CONSUME; instantaneous consumption"))
        // p079 #4: QUARANTINED STATISTIC_PROBE_LOWEST_TEMP — both INT and
        // DOUBLE fields carry garbage (~1.03e9), never plausible °C. Re-enable
        // only if a future chunk shows 20–40°C.
        // put("BYDAutoStatisticDevice|0x47800020",
        //     Decoder("cell_temp_lowest", "°C", ValueSource.INT,
        //         notes = "STATISTIC_PROBE_LOWEST_TEMP; lowest cell-probe temperature"))
        // p079 #5: PROBE_HIGHEST_TEMP. p083: promoted to canonical battery_temp.
        // 4-run analysis (14 Jun) shows a healthy ~0.5 Hz stream (n=12–15/chunk),
        // 21–22°C on a warm day, matching the OEM cluster (Bat 21°) AND companion
        // OBD2 790/002F. NOT the rare/event-only fid the old handoff feared, and
        // NOT 28–31 — that was a different (hotter) day. This IS battery temp.
        put("BYDAutoStatisticDevice|0x47800010",
            Decoder("battery_temp", "°C", ValueSource.INT,
                notes = "STATISTIC_PROBE_HIGHEST_TEMP; canonical pack temperature; ~0.5 Hz stream; 21–22°C warm day; matches OEM cluster + OBD2 790/002F"))

        // p156: three p082 battery-temp candidates REMOVED. 0x000DA09B /
        // 0x00072559 / 0x0004CFF3 are legacy-format fids absent from the bZ5
        // firmware catalog (present by name only, under get()-only short
        // numbers 0x30A/0x2F2/0x2F3). Zero events every run was the catalog
        // mismatch, not a DC-vs-AC timing effect.

        // ─── Engine (names from firmware BYDAutoFeatureIds catalog, patch 075) ─
        // The firmware catalog resolved the long-running Engine fid guesses to
        // exact names. Two prior misidentifications corrected:
        //   0x15100020: was "motor_current_proxy" → ENGINE_POWER (kW). Verified:
        //     ENGINE_POWER ≈ torque×ω with ratio 0.99–1.03 (trip-3); peak 208
        //     ≈ nameplate 200 kW. It correlated with current only because
        //     P ≈ V×I at ~constant V — it IS independent power, not an echo.
        //   0x40F00008: was "pack_voltage_xcheck" → ENGINE_DRIVER_MOTOR_CONTROL_
        //     VOLTAGE (inverter control voltage, not pack V). r=0.889 with pack
        //     V because both track the same DC bus, but semantically distinct.
        put("BYDAutoEngineDevice|0x28A00008",
            Decoder("motor_rpm", "RPM", ValueSource.INT,
                notes = "ENGINE_DRIVER_MOTOR_SPEED; slope 79.3 RPM/(km/h), r=0.968 speed; nameplate max ~16000"))
        put("BYDAutoEngineDevice|0x28A00018",
            Decoder("motor_torque", "Nm", ValueSource.DOUBLE,
                notes = "ENGINE_DRIVER_MOTOR_TORQUE; signed, peak 330 Nm = nameplate; T×ω matches ENGINE_POWER & 200kW"))
        put("BYDAutoEngineDevice|0x15100020",
            Decoder("motor_power", "kW", ValueSource.INT,
                notes = "ENGINE_POWER; signed; peak 208≈200kW nameplate; = torque×ω ratio 0.99-1.03 (trip-3)"))
        put("BYDAutoEngineDevice|0x3DB00010",
            Decoder("motor_temp", "°C", ValueSource.INT,
                notes = "ENGINE_DRIVER_MOTOR_TEMP; 30–44 °C observed"))
        put("BYDAutoEngineDevice|0x3DB00008",
            Decoder("inverter_temp", "°C", ValueSource.INT,
                notes = "ENGINE_DRIVER_MOTOR_CONTROL_TEMP (inverter); 25–55 °C; distinct from motor_temp (r=0.03)"))
        put("BYDAutoEngineDevice|0x40F00008",
            Decoder("motor_control_voltage", "V", ValueSource.INT,
                notes = "ENGINE_DRIVER_MOTOR_CONTROL_VOLTAGE; inverter DC bus, tracks pack V (r=0.889) but distinct"))
        // p083: motor-side current candidate. On 18:29 launch run ranged
        // -156..+513 A (mDoubleValue), sign tracking traction/regen, amplitude
        // slightly wider than pack_current (513 vs 494). Hypothesis: motor/phase
        // current, independent of pack_current. Added to raw_trace this patch to
        // regress pointwise vs pack_current (0x2D300018). Name provisional.
        put("BYDAutoEngineDevice|0x40800008",
            Decoder("motor_current_candidate", "A", ValueSource.DOUBLE,
                notes = "p083 CANDIDATE; -156..+513 A; sign=traction/regen; wider than pack_current; verify independence via raw_trace regression"))

        // ─── Gearbox (patch 067 trip-1 partial decode) ───────────────────
        put("BYDAutoGearboxDevice|0x0FB00020",
            Decoder("gear_enum", "", ValueSource.INT,
                notes = "1=Park, 2=Reverse, 3=Neutral, 4=Drive (full enum confirmed trip-2 R→N→R→D→R→P sequence)"))
        put("BYDAutoGearboxDevice|0x22A00022",
            Decoder("brake_pedal", "", ValueSource.INT,
                notes = "GEARBOX_BRAKE_PEDAL; 0=released, 1=pressed"))
        // PROMOTED patch 075 via firmware catalog: GEARBOX_EPB_STATE — the
        // electronic parking brake, not a clutch (BZ5 is single-speed, no
        // clutch). Earlier "clutch_toggle" hypothesis retired.
        put("BYDAutoGearboxDevice|0x21800411",
            Decoder("epb_state", "", ValueSource.INT,
                notes = "GEARBOX_EPB_STATE; electronic parking brake state (0/1/2/3)"))

        // ─── AC (event-driven climate control) ───────────────────────────
        // ─── AC (re-mapped from firmware catalog, patch 075) ─────────────
        // The p074 demotion was right to drop the old guesses. The catalog now
        // gives exact names; trip-2 subtypes 0x2FC00014/00028/00030 resolve to
        // AC_CYCLE_MODE / AC_TEMP_MAIN / AC_TEMP_DEPUTY. NAMES are firmware-
        // exact, but VALUE SCALE is not yet pinned: trip-2 climate actions
        // produced small ints (0/1) on TEMP_MAIN where setpoints 21/23 were
        // expected, so the temp encoding (offset/scale, or "level index" vs
        // °C) still needs a dedicated stationary climate test with per-action
        // timestamps. Promoted with names; companion should treat values as
        // raw until the climate test confirms scale.
        // p155: trip-1 (patch 066) saw 0x2FC00028 as mDoubleValue 23 (= the
        // 23 °C setpoint), trip-2 saw mIntValue 0/1 under the INT decoder. That
        // is the carrier rule case, not a scale puzzle: the value rides in the
        // double field and INT read the empty zero. Both setpoints go to ANY
        // until the ac_raw climate test records both fields per event.
        // p156: ac_raw export 23.10 settled the carrier — setpoints ride in
        // mDoubleValue (18.0/18.5/21.0/23.5, 0.5 step). Pinned DOUBLE.
        put("BYDAutoAcDevice|0x2FC00028",
            Decoder("ac_temp_main", "°C", ValueSource.DOUBLE,
                notes = "AC_TEMP_MAIN (driver setpoint); ac_raw 23.10 dbl 18.0–23.5 step 0.5 — carrier DOUBLE confirmed"))
        put("BYDAutoAcDevice|0x2FC00030",
            Decoder("ac_temp_deputy", "°C", ValueSource.DOUBLE,
                notes = "AC_TEMP_DEPUTY (passenger setpoint); ac_raw 23.10 dbl, carrier DOUBLE confirmed"))
        put("BYDAutoAcDevice|0x2FC0001C",
            Decoder("ac_wind_level", "", ValueSource.INT, notes = "AC_WIND_LEVEL (fan speed)"))
        put("BYDAutoAcDevice|0x2FC00018",
            Decoder("ac_wind_mode", "", ValueSource.INT, notes = "AC_WIND_MODE (airflow direction)"))
        put("BYDAutoAcDevice|0x2FC00014",
            Decoder("ac_cycle_mode", "", ValueSource.INT, notes = "AC_CYCLE_MODE (recirc/fresh)"))
        put("BYDAutoAcDevice|0x2FC00010",
            Decoder("ac_power_state", "", ValueSource.INT, notes = "AC_POWER_STATE (on/off)"))
        put("BYDAutoAcDevice|0x2FC00012",
            Decoder("ac_ctrl_mode", "", ValueSource.INT, notes = "AC_CTRL_MODE (auto/manual)"))
        put("BYDAutoAcDevice|0x2FC00038",
            Decoder("ac_temp_out", "°C", ValueSource.INT, notes = "AC_TEMP_OUT (outside temp); INT carries 27–30°C, DOUBLE was 0"))

        // ─── AC — remaining catalog-named fids (patch 155) ────────────────
        // Names are exact from the firmware BYDAutoFeatureIds catalog (recon
        // v0.10.56 export, class Ac). The first four are the trip-1 (patch 066)
        // subtypes that never had a decoder; the last three have not been seen
        // live yet (0x2FA0 base, probably event-driven: PTC only when heating).
        // Carrier and enum semantics unknown, hence ANY and empty unit; the
        // climate test (one action per 10 s, both fields logged) pins them.
        // 0x2FC00009 AC_COMPRESSOR_MODE is also the A/C-off marker for the
        // firehose correlation: CAN 0x02FC carries the same panel state.
        // p156: ac_raw 23.10 showed every AC enum rides in mIntValue — pinned INT.
        // Fids not yet seen live (0x2FA* PTC/warm) stay ANY until first event.
        put("BYDAutoAcDevice|0x2FC00009",
            Decoder("ac_compressor_mode", "", ValueSource.INT, notes = "AC_COMPRESSOR_MODE (A/C button); ac_raw int 0/1; A/C off marker; enum semantics TBD"))
        put("BYDAutoAcDevice|0x2FC0000A",
            Decoder("ac_compressor_manual_sign", "", ValueSource.INT, notes = "AC_COMPRESSOR_MANUAL_SIGN; ac_raw int; manual-override flag"))
        put("BYDAutoAcDevice|0x2FC0000B",
            Decoder("ac_windmode_manual_sign", "", ValueSource.INT, notes = "AC_WINDMODE_MANUAL_SIGN; ac_raw int; manual-override flag"))
        put("BYDAutoAcDevice|0x2FC0000C",
            Decoder("ac_windlevel_manual_sign", "", ValueSource.INT, notes = "AC_WINDLEVEL_MANUAL_SIGN; ac_raw int; manual-override flag"))
        put("BYDAutoAcDevice|0x2FC00016",
            Decoder("ac_defrost_front_state", "", ValueSource.INT, notes = "AC_DEFROST_FRONT_STATE; windscreen defrost; ac_raw int enum"))
        put("BYDAutoAcDevice|0x2FA0000C",
            Decoder("ac_ptc_state", "", ValueSource.ANY, notes = "AC_PTC_STATE; PTC heater state, not duty; not yet seen live (0x2FA0 base)"))
        put("BYDAutoAcDevice|0x2FA00026",
            Decoder("ac_ptc_preheat_signal", "", ValueSource.ANY, notes = "AC_PTC_PREHEAT_SIGNAL; not yet seen live"))

        // p156: remaining catalog-named AC fids (class Ac, v0.10.56). Those seen
        // in ac_raw 23.10 are INT enums; the two 0x2FA0/0x4330 warm fids not yet
        // seen live stay ANY. All enum semantics TBD by climate test.
        put("BYDAutoAcDevice|0x2FC00024",
            Decoder("ac_tempctrl_separate_state", "", ValueSource.INT, notes = "AC_TEMPCTRL_SEPARATE_STATE; dual-zone split on/off; ac_raw int"))
        put("BYDAutoAcDevice|0x2FA00014",
            Decoder("ac_max_cooling_state", "", ValueSource.INT, notes = "AC_MAX_COOLING_STATE; ac_raw int 0/1"))
        put("BYDAutoAcDevice|0x2FA0000A",
            Decoder("ac_ventilation_state", "", ValueSource.ANY, notes = "AC_VENTILATION_STATE; values not yet classified; carrier ANY"))
        put("BYDAutoAcDevice|0x40600031",
            Decoder("ac_defrost_rear_state", "", ValueSource.INT, notes = "AC_DEFROST_REAR_STATE; rear-window defrost; ac_raw int 0/1"))
        put("BYDAutoAcDevice|0x44300008",
            Decoder("ac_quick_clean_air", "", ValueSource.INT, notes = "AC_QUICK_CLEAN_AIR; ac_raw int 0/1"))
        put("BYDAutoAcDevice|0x2FA0003C",
            Decoder("ac_warm_state", "", ValueSource.ANY, notes = "AC_WARM_STATE; heat-pump/PTC warm mode; not yet seen live"))
        put("BYDAutoAcDevice|0x43300020",
            Decoder("ac_warm_type_flag", "", ValueSource.ANY, notes = "AC_WARM_TYPE_FLAG; warm source flag; not yet seen live"))

        // ─── Tyre (TPMS) — wheel positions from firmware catalog, patch 075 ──
        // Ground-truth confirmed (owner reading 2.7–2.9 bar, ~20°C). Pressure
        // is kPa (287–292 = 2.87–2.92 bar), temperature is °C direct.
        // Positions are EXACT from firmware names (no guessing).
        put("BYDAutoTyreDevice|0x99000124",
            Decoder("tyre_pressure_fl", "kPa", ValueSource.INT, notes = "TYRE_PRESSURE_VALUE_LEFT_FRONT"))
        put("BYDAutoTyreDevice|0x99000128",
            Decoder("tyre_pressure_fr", "kPa", ValueSource.INT, notes = "TYRE_PRESSURE_VALUE_RIGHT_FRONT"))
        put("BYDAutoTyreDevice|0x9900012C",
            Decoder("tyre_pressure_rl", "kPa", ValueSource.INT, notes = "TYRE_PRESSURE_VALUE_LEFT_REAR"))
        put("BYDAutoTyreDevice|0x99000130",
            Decoder("tyre_pressure_rr", "kPa", ValueSource.INT, notes = "TYRE_PRESSURE_VALUE_RIGHT_REAR"))
        put("BYDAutoTyreDevice|0x99000183",
            Decoder("tyre_temp_fl", "°C", ValueSource.DOUBLE, notes = "TYRE_TEMPERATURE_VALUE_LEFT_FRONT"))
        put("BYDAutoTyreDevice|0x99000185",
            Decoder("tyre_temp_fr", "°C", ValueSource.DOUBLE, notes = "TYRE_TEMPERATURE_VALUE_RIGHT_FRONT"))
        put("BYDAutoTyreDevice|0x99000187",
            Decoder("tyre_temp_rl", "°C", ValueSource.DOUBLE, notes = "TYRE_TEMPERATURE_VALUE_LEFT_REAR"))
        put("BYDAutoTyreDevice|0x99000189",
            Decoder("tyre_temp_rr", "°C", ValueSource.DOUBLE, notes = "TYRE_TEMPERATURE_VALUE_RIGHT_REAR"))

        // ─── Radar obstacle distance (8 sensors) ─────────────────────────
        // Names from firmware BYDAutoFeatureIds catalog (patch 078). The old
        // corner/center labels (patch 066) were PRE-catalog positional guesses
        // and were wrong for the four rear/side sensors — e.g. 0x65 was
        // labelled "rl_corner" but firmware = RADAR_OBSTACLE_DISTANCE_LEFT (a
        // side sensor), and 0x68 was "rr_corner" but firmware = ..._RIGHT.
        // Now mapped 1:1 to the firmware fid names so companion UI places each
        // sensor correctly.
        // Range observed 19–127 in the s3 parking run; 126/127 = clear / no
        // obstacle. Unit assumed cm; absolute scale not yet pinned by a
        // tape-measure ground truth — treat as raw distance index until then.
        put("BYDAutoRadarDevice|0x99000061", Decoder("radar_obstacle_left_front", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT_FRONT (front, outer left)"))
        put("BYDAutoRadarDevice|0x99000062", Decoder("radar_obstacle_front_left_mid", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_FRONT_LEFT_MID (front, inner left)"))
        put("BYDAutoRadarDevice|0x99000063", Decoder("radar_obstacle_front_right_mid", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_FRONT_RIGHT_MID (front, inner right)"))
        put("BYDAutoRadarDevice|0x99000064", Decoder("radar_obstacle_right_front", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT_FRONT (front, outer right)"))
        put("BYDAutoRadarDevice|0x99000065", Decoder("radar_obstacle_left", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT (rear, outer left)"))
        put("BYDAutoRadarDevice|0x99000066", Decoder("radar_obstacle_left_rear", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_LEFT_REAR (rear, inner left)"))
        put("BYDAutoRadarDevice|0x99000067", Decoder("radar_obstacle_right_rear", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT_REAR (rear, inner right)"))
        put("BYDAutoRadarDevice|0x99000068", Decoder("radar_obstacle_right", "cm", ValueSource.INT, notes = "RADAR_OBSTACLE_DISTANCE_RIGHT (rear, outer right)"))

        // ─── Radar probe state (8 sensors, patch 078) ────────────────────
        // RADAR_PROBE_STATE_* — per-sensor enum, observed 0–4 in the s3
        // parking run (0 when clear). Likely a proximity/warning-zone level or
        // sensor health code; exact value→meaning mapping is TBD (needs a
        // controlled approach against a known obstacle distance). Confirmed
        // live (all 8 fids fired in s3); promoted as raw enum with semantics
        // pending. Companion may show as a raw badge until decoded.
        put("BYDAutoRadarDevice|0x99000071", Decoder("radar_state_left_front", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT_FRONT; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000072", Decoder("radar_state_front_left_mid", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_FRONT_LEFT_MID; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000073", Decoder("radar_state_front_right_mid", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_FRONT_RIGHT_MID; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000074", Decoder("radar_state_right_front", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT_FRONT; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000075", Decoder("radar_state_left", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000076", Decoder("radar_state_left_rear", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_LEFT_REAR; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000077", Decoder("radar_state_right_rear", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT_REAR; enum 0-4, semantics TBD"))
        put("BYDAutoRadarDevice|0x99000078", Decoder("radar_state_right", "", ValueSource.INT, notes = "RADAR_PROBE_STATE_RIGHT; enum 0-4, semantics TBD"))

        // ─── Powertrain/energy state enums (patch 089) ───────────────────
        // PROMOTED после полного аудита live-потока 24 июня: эти три фида
        // СТАБИЛЬНО текут (by_subtype в каждом live-чанке), но не были
        // декодированы — проскакивали как «прочие subtype». Все три — enum/
        // флаги состояния (int), НЕ непрерывная телеметрия. Семантика значений
        // pending (нужен контролируемый прогон с известными переходами).
        // ВАЖНО: ENGINE_DRIVER_POWER (0x40A00010) — это флаг 0/1 (драйв-режим
        // активен), НЕ мощность в кВт. Не путать с engine_power 0x15100020
        // (та — знаковая мощность пакета, r=0.999 с V·I). Имя обманчиво.
        put("BYDAutoEngineDevice|0x40A00010",
            Decoder("engine_driver_power_flag", "", ValueSource.INT,
                notes = "ENGINE_DRIVER_POWER; флаг 0/1 (драйв активен), НЕ кВт; semantics TBD"))
        put("BYDAutoEngineDevice|0x40A00011",
            Decoder("motor_state", "", ValueSource.INT,
                notes = "ENGINE_DRIVER_MOTOR_STATE; enum (набл. 1-2), вероятно idle/active; semantics TBD"))
        put("BYDAutoEnergyDevice|0x20800018",
            Decoder("energy_state", "", ValueSource.INT,
                notes = "ENERGY_STATE; enum (набл. 2-5); состояние энергосистемы; semantics TBD"))
    }

    /**
     * Decode a raw event into a [DecodedValue], or null if no decoder exists
     * for this (targetKey, subtype) pair, or neither raw field is present.
     * Which field supplies the value is decided by [pickCarrier] (patch 155);
     * the result carries that choice in `carrier` / `typeConflict`.
     *
     * targetKey NORMALIZATION (patch 073): the same physical fid can arrive
     * under different target keys depending on how the subscription split the
     * device. recon's defaultTargets() emits odometer under
     * "BYDAutoStatisticDevice_tail"; companion's streamingTargets() emits the
     * same fid under "BYDAutoStatisticDevice". Likewise *_priority / *_v2 /
     * *_narrow / *_sweep / *_canDataCollect are all the SAME underlying
     * device. We strip any such suffix before lookup so a single decoder
     * entry matches regardless of which subscription variant delivered it.
     * Lookups try the exact key first (lets a suffixed entry win if ever
     * needed), then the normalized key.
     *
     * @param overrides Optional per-project overrides that take precedence
     *                  over the base [table] for matching keys (exact, then
     *                  normalized).
     */
    fun decode(
        targetKey: String,
        subtype: Long,
        intValue: Int?,
        doubleValue: Double?,
        bufData: ByteArray?,
        timestampMs: Long,
        overrides: Map<String, Decoder> = emptyMap()
    ): DecodedValue? {
        val exactKey = key(targetKey, subtype)
        val normKey  = key(normalizeTargetKey(targetKey), subtype)
        val d = overrides[exactKey] ?: overrides[normKey]
            ?: table[exactKey] ?: table[normKey]
            ?: return null
        val picked = pickCarrier(d.source, intValue, doubleValue) ?: return null
        val physical = picked.raw * d.scale + d.offset
        return DecodedValue(d.name, physical, d.unit, timestampMs,
            carrier = picked.carrier, typeConflict = picked.conflict)
    }

    /** Result of [pickCarrier]: the raw number, the field it came from, and
     *  whether that field differs from the decoder's declared source. */
    data class Picked(val raw: Double, val carrier: ValueSource, val conflict: Boolean)

    /**
     * Carrier rule (patch 155). The framework fills BOTH fields on every
     * event, one real and the other 0. A declared source whose field is 0 or
     * absent while the other field is non-zero is a carrier conflict: the
     * value is taken from the other field and flagged. A true zero (both
     * fields 0, or the declared field 0 and the other absent) decodes as 0
     * without a flag. [ValueSource.ANY] prefers a non-zero double, then a
     * non-zero int, then a zero from whichever field is present.
     * Returns null for BUFDATA and when neither field is present.
     */
    fun pickCarrier(source: ValueSource, intValue: Int?, doubleValue: Double?): Picked? {
        val i = intValue
        val d = doubleValue?.takeIf { it.isFinite() }
        val iLive = i != null && i != 0
        val dLive = d != null && d != 0.0
        return when (source) {
            ValueSource.BUFDATA -> null  // caller does format-specific decode
            ValueSource.INT -> when {
                iLive     -> Picked(i!!.toDouble(), ValueSource.INT, false)
                dLive     -> Picked(d!!, ValueSource.DOUBLE, true)
                i != null -> Picked(0.0, ValueSource.INT, false)
                else      -> null
            }
            ValueSource.DOUBLE -> when {
                dLive     -> Picked(d!!, ValueSource.DOUBLE, false)
                iLive     -> Picked(i!!.toDouble(), ValueSource.INT, true)
                d != null -> Picked(0.0, ValueSource.DOUBLE, false)
                else      -> null
            }
            ValueSource.ANY -> when {
                dLive     -> Picked(d!!, ValueSource.DOUBLE, false)
                iLive     -> Picked(i!!.toDouble(), ValueSource.INT, false)
                d != null -> Picked(0.0, ValueSource.DOUBLE, false)
                i != null -> Picked(0.0, ValueSource.INT, false)
                else      -> null
            }
        }
    }

    /**
     * Strip subscription-variant suffixes from a target key so the same
     * physical device maps to one canonical key. E.g.
     * "BYDAutoStatisticDevice_tail" → "BYDAutoStatisticDevice",
     * "BYDAutoChargingDevice_priority" → "BYDAutoChargingDevice".
     * Suffixes recognized: _tail, _priority, _v2, _narrow, _sweep,
     * _canDataCollect. A key with no recognized suffix is returned unchanged.
     */
    fun normalizeTargetKey(targetKey: String): String {
        val idx = targetKey.indexOf('_')
        if (idx <= 0) return targetKey
        // Only strip if the prefix is a BYDAuto*Device base name.
        val base = targetKey.substring(0, idx)
        return if (base.startsWith("BYDAuto") && base.endsWith("Device")) base else targetKey
    }
}
