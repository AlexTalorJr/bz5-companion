// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetryDecoderTable.kt
// Synced: 2026-06-10 (recon v0.10.53, commit d37fbbc)
// SHA256: 2178674794f89d643acab60dfd61999fed975aea07511d36e74c306481e08b2f
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
                notes = "raw units 100 m → ×0.1 = km"))
        put("BYDAutoStatisticDevice|0x49503010",
            Decoder("trip_a", "km", ValueSource.INT, scale = 0.1))
        put("BYDAutoStatisticDevice|0x49503024",
            Decoder("trip_b", "km", ValueSource.INT, scale = 0.1))
        put("BYDAutoStatisticDevice|0x49507032",
            Decoder("aux_battery_12v", "V", ValueSource.DOUBLE,
                notes = "AUX 12V health (13.7 V healthy)"))

        // ─── Engine (patch 066 decode via time-series correlation) ───────
        put("BYDAutoEngineDevice|0x28A00008",
            Decoder("motor_rpm", "RPM", ValueSource.INT,
                notes = "slope 79.3 RPM/(km/h) ≈ theoretical 78.5 for BZ5 single-speed reducer 9.7:1"))
        // HYPOTHESIS — needs corr-with primary pack_voltage on drive run:
        // put("BYDAutoEngineDevice|0x40F00008",
        //     Decoder("pack_voltage_xcheck", "V", ValueSource.INT,
        //         notes = "r=0.66 with Charging|0x2D300008 — middling; not promoted yet"))
        // HYPOTHESIS — name guessed from physical range (26–39 °C) and Engine
        // device family, but no independent corr or sensor cross-check.
        // Needs corr-with cabin OBD temp readout or charge-soak temp curve:
        // put("BYDAutoEngineDevice|0x3DB00008",
        //     Decoder("inverter_motor_temp", "°C", ValueSource.INT,
        //         notes = "26–39 °C observed; no strong correlation with speed; unverified semantic"))
        // HYPOTHESIS — r=0.52 with pack_current is weak; could be any of
        // {motor_torque, motor_power_kw, regen_target_pct}. Needs corr-with
        // pedal position or a clean accel/coast/regen segment for confirmation:
        // put("BYDAutoEngineDevice|0x15100020",
        //     Decoder("motor_torque", "Nm", ValueSource.INT,
        //         notes = "signed; r=0.52 with pack_current — weak; unverified"))

        // ─── Gearbox (patch 067 trip-1 partial decode) ───────────────────
        put("BYDAutoGearboxDevice|0x0FB00020",
            Decoder("gear_enum", "", ValueSource.INT,
                notes = "1=Park, 2=Reverse, 4=Drive, 3=unknown (need controlled sequence)"))
        put("BYDAutoGearboxDevice|0x22A00022",
            Decoder("brake_toggle", "", ValueSource.INT,
                notes = "0=released, 1=pressed"))
        // HYPOTHESIS — BZ5 is a single-speed EV with no clutch, name probably
        // misleading inherited from generic BYD framework. Could be brake-pedal
        // pressure tier, regen-paddle position, or some shifter-stalk state.
        // Needs corr-with deliberate paddle/pedal use to confirm semantic:
        // put("BYDAutoGearboxDevice|0x21800411",
        //     Decoder("clutch_toggle", "", ValueSource.INT,
        //         notes = "0/1/2/3 — pad/clutch state"))

        // ─── AC (event-driven climate control) ───────────────────────────
        put("BYDAutoAcDevice|0x2FC0001C",
            Decoder("ac_fan_speed", "", ValueSource.INT, notes = "1–7"))
        put("BYDAutoAcDevice|0x2FC00018",
            Decoder("ac_temp_level", "", ValueSource.INT, notes = "1–6"))
        put("BYDAutoAcDevice|0x2FC00028",
            Decoder("ac_setpoint", "°C", ValueSource.DOUBLE))
        put("BYDAutoAcDevice|0x2FC0000C", Decoder("ac_on", "", ValueSource.INT, notes = "0/1"))
        put("BYDAutoAcDevice|0x2FC00012", Decoder("ac_auto", "", ValueSource.INT, notes = "0/1"))
        put("BYDAutoAcDevice|0x2FC0000B", Decoder("ac_recirc", "", ValueSource.INT, notes = "0/1"))
        put("BYDAutoAcDevice|0x2FC00009", Decoder("ac_defrost", "", ValueSource.INT, notes = "0/1"))
        put("BYDAutoAcDevice|0x2FC0000A", Decoder("ac_compressor", "", ValueSource.INT, notes = "0/1"))

        // ─── Tyre (TPMS) ─────────────────────────────────────────────────
        put("BYDAutoTyreDevice|0x99000128",
            Decoder("tyre_pressure_generic", "kPa", ValueSource.INT,
                notes = "wheel position encoded in higher-byte; trip-1 only RIGHT_FRONT delivered"))

        // ─── Radar (8 parking sensors, patch 066) ────────────────────────
        // Range 62–127 cm; 127 = max range / no obstacle.
        put("BYDAutoRadarDevice|0x99000061", Decoder("radar_fl_corner", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000062", Decoder("radar_fl_center", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000063", Decoder("radar_fr_center", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000064", Decoder("radar_fr_corner", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000065", Decoder("radar_rl_corner", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000066", Decoder("radar_rl_center", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000067", Decoder("radar_rr_center", "cm", ValueSource.INT))
        put("BYDAutoRadarDevice|0x99000068", Decoder("radar_rr_corner", "cm", ValueSource.INT))
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
