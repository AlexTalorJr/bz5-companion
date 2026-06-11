// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetryDecoderTable.kt
// Synced: 2026-06-11 (recon v0.10.57, commit p078)
// SHA256: b26144b8299079a02d4ca346ee373a12d353a40835da5908103859d4a70ee3c9
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
    BUFDATA
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
    val timestampMs: Long
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
        // HYPOTHESIS — needs corr-with primary pack_voltage on charge run:
        // put("BYDAutoChargingDevice|0x2FF00030",
        //     Decoder("pack_voltage_alt", "V", ValueSource.DOUBLE,
        //         notes = "possibly high-side; not independently verified"))

        // ─── Energy (cells) ──────────────────────────────────────────────
        put("BYDAutoEnergyDevice|0x45400030",
            Decoder("cell_v_highest", "V", ValueSource.DOUBLE,
                notes = "3.25–3.27 V parked LFP"))
        put("BYDAutoEnergyDevice|0x45400010",
            Decoder("cell_v_lowest",  "V", ValueSource.DOUBLE,
                notes = "3.24–3.26 V parked LFP"))
        put("BYDAutoEnergyDevice|0x45400008",
            Decoder("cell_idx_highest", "", ValueSource.INT,
                notes = "1–136"))
        put("BYDAutoEnergyDevice|0x45400028",
            Decoder("cell_idx_lowest",  "", ValueSource.INT,
                notes = "1–136"))

        // ─── Statistic (head, first 64) ──────────────────────────────────
        put("BYDAutoStatisticDevice|0x15100008",
            Decoder("speed", "km/h", ValueSource.INT,
                notes = "averaged ~8.7 Hz; verified ground-truth in trip-1"))
        put("BYDAutoStatisticDevice|0x47300018",
            Decoder("insulation_resistance", "MΩ", ValueSource.INT,
                notes = "16–18 MΩ healthy"))
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
        put("BYDAutoStatisticDevice|0x47800020",
            Decoder("cell_temp_lowest", "°C", ValueSource.INT,
                notes = "STATISTIC_PROBE_LOWEST_TEMP; lowest cell-probe temperature"))

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
        put("BYDAutoAcDevice|0x2FC00028",
            Decoder("ac_temp_main", "", ValueSource.INT,
                notes = "AC_TEMP_MAIN (driver setpoint); raw — scale TBD by climate test"))
        put("BYDAutoAcDevice|0x2FC00030",
            Decoder("ac_temp_deputy", "", ValueSource.INT,
                notes = "AC_TEMP_DEPUTY (passenger setpoint); raw — scale TBD"))
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
            Decoder("ac_temp_out", "°C", ValueSource.DOUBLE, notes = "AC_TEMP_OUT (outside temp)"))

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
    }

    /**
     * Decode a raw event into a [DecodedValue], or null if no decoder exists
     * for this (targetKey, subtype) pair, or the relevant raw field is null.
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
        val raw: Double = when (d.source) {
            ValueSource.INT    -> intValue?.toDouble() ?: return null
            ValueSource.DOUBLE -> doubleValue ?: return null
            ValueSource.BUFDATA -> return null  // caller does format-specific decode
        }
        val physical = raw * d.scale + d.offset
        return DecodedValue(d.name, physical, d.unit, timestampMs)
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
