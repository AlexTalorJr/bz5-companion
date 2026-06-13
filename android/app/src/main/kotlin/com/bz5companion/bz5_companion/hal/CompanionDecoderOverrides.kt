// === COMPANION-AUTHORED (not vendored) ===
// This file is owned by bz5_companion. It is the per-project override
// layer the shared TelemetryDecoderTable was designed for (see that
// file's header, "Friend 1 review 2026-06-09: layered design — base
// table + per-project override map"). The vendored files stay
// byte-identical to recon; everything companion needs to add or fix
// locally lives here and is passed into DecodedStreamSink / the
// subscription at construction time in BydNativePlugin.
//
// PROMOTION RULE: entries here are either (a) local fixes awaiting an
// official recon decoder-table release, or (b) measurement CANDIDATES
// surfacing in HAL Test for verification. Nothing in this file may feed
// a daily-driver UI card until verified against an independent source
// (the OBD2 DID or the instrument cluster) — at which point it should
// be promoted into the shared table via Friend 3 and removed from here.
package com.bz5companion.bz5_companion.hal

object CompanionDecoderOverrides {

    /**
     * Override / extension decoders, layered over the shared base table
     * (override wins on key collision — see TelemetryDecoderTable.decode).
     */
    val map: Map<String, Decoder> = mapOf(
        // LOCAL FIX (v0.1.29+66) — shared table ships scale=1.0 which
        // renders raw kΩ as "MΩ" (live reading 13517 "MΩ" on 2026-06-11
        // drive, physically absurd). Truth: raw is kΩ → scale 0.001 gives
        // 13.5 MΩ, inside the 14–18 MΩ healthy band recon documented.
        // Official fix queued recon-side (p079); drop this entry on the
        // next re-vendor that contains it.
        "BYDAutoStatisticDevice|0x47300018" to Decoder(
            "insulation_resistance", "MΩ", ValueSource.INT,
            scale = 0.001,
            notes = "LOCAL FIX over shared scale=1.0 bug; raw is kΩ"),

        // CANDIDATES (v0.1.29+66) — battery temperature search. None of
        // these is in the shared active table; recon saw PROBE_HIGHEST_TEMP
        // live at 20–21 °C (plausible = ambient) and never saw the
        // AVERAGE/HIGHEST/LOWEST trio deliver. They surface in HAL Test
        // only, for correlation against OBD2 790/002F. NOT wired to any
        // dashboard card.
        "BYDAutoStatisticDevice|0x47800010" to Decoder(
            "probe_highest_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE battery temp; verify vs 790/002F"),
        "BYDAutoStatisticDevice|0x00049367" to Decoder(
            "battery_temp_avg", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_AVERAGE_BATTERY_TEMP; never seen live"),
        "BYDAutoStatisticDevice|0x00090D49" to Decoder(
            "battery_temp_high", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_HIGHEST_BATTERY_TEMP; never seen live"),
        "BYDAutoStatisticDevice|0x000A4490" to Decoder(
            "battery_temp_low", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_LOWEST_BATTERY_TEMP; never seen live"),

        // CANDIDATES (v0.1.29+70) — battery temp, SECOND attempt on the
        // RIGHT devices. The +66 round only probed BYDAutoStatisticDevice
        // (PROBE + the AVG/HIGH/LOW trio) — all aggregates, rare by design,
        // confirmed dead on our hardware AND in recon's raw chunks. We
        // never tried the profile devices. These fids are ALREADY in the
        // vendored Energy/Charging subscriptions (Energy harvests all 33;
        // these Charging fids sit at positions 19 & 33 of the 80 picked) —
        // they flow raw but get dropped for lack of a decoder, exactly the
        // insulation situation. So this is a pure decoder addition, no
        // subscription change. Surface in HAL Test, correlate vs OBD2
        // 790/002F; promote the one that tracks it into the shared table.
        "BYDAutoEnergyDevice|0x000DA09B" to Decoder(
            "energy_dc_port_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE ENERGY_DC_CHARGING_PORT_TEMP; on the battery profile device"),
        "BYDAutoChargingDevice|0x00072559" to Decoder(
            "charging_max_power_batt_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE CHARGING_VTOV_MAX_POWER_BATTERY_TEMP"),
        "BYDAutoChargingDevice|0x0004CFF3" to Decoder(
            "charging_max_temp_allowed", "°C", ValueSource.INT,
            notes = "CANDIDATE CHARGING_VTOV_MAX_TEMP_ALLOWED"),
    )

    /**
     * Extra Statistic-device feature ids companion subscribes to on top
     * of the vendored TargetRegistry.streamingTargets set. Applied by
     * BydNativePlugin as a copy-on-top of the "BYDAutoStatisticDevice"
     * TargetSpec — the vendored registry file itself is never edited.
     *
     * 0x47800010 = STATISTIC_PROBE_HIGHEST_TEMP. The AVERAGE/HIGHEST/
     * LOWEST trio (0x00049367 / 0x00090D49 / 0x000A4490) is already
     * inside the registry's top-64 prefix subscription, so only the
     * probe fid needs adding here.
     */
    val extraStatisticFids: IntArray = intArrayOf(0x47800010)
}
