// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/FirehoseFieldTable.kt
// Synced: 2026-11-24 (recon v0.10.160, commit p160)
// SHA256: fc35d4a8572e7373024ab0bbacc671c701b861f8ae1537aeee7ada0abe12aae4
package com.bz5companion.bz5_companion.hal

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/FirehoseFieldTable.kt
// Owner: bz5_recon (patch 158)
// Sync method: copy-paste with checksum header, like TelemetryDecoderTable.
// Changes go to DECODER_CHANGELOG.md. Frame overview: FIREHOSE_FRAMES.md.
//
// Fields decoded straight from BigData firehose frames (target
// BYDAutoBigDataDevice_canDataCollect, subtype 0x99000020). Several of them
// belong to device classes we cannot open (Gb: class_not_found, Bodywork:
// SecurityException at getInstance, Power: no COMMON grant), but their CAN
// frames do pass through the firehose.
//
// Buffer layout (checked on 84 909 frames, recon 09.11 evening):
//   [0..1] 0x0000
//   [2..3] CAN ID, big-endian
//   [4]    page number (0 for plain frames; 0x0495 uses 2,3,6,7,8,11)
//   [5]    flag byte, 0x00 or 0x02, meaning unknown
//   [6..]  payload: 5, 8, 16, 32 or 64 bytes
//
// Catalog fid → position rule: fid = 0xCCC PP LLL, CCC = CAN ID, PP = page,
// start bit = (LLL and 0xFF) − 8, bits numbered little-endian (Intel) over the
// payload. Checked against HAL on AC_TEMP_MAIN/DEPUTY (0x2FC00028/30, 35
// events 07.11) and ENERGY_STATE 0x20800018 (0/2/5 on 09.11), and against
// ∫V·I on the 0x2D0 counters. The catalog gives start bits only, so widths
// below come from the next catalog field in the same frame or from data.
//
// STATUS: CONFIRMED fields carry a physical scale and may feed UI. CANDIDATE
// fields are raw research values: record them, do not show them as physics.

data class FirehoseField(
    /** Stable semantic name. */
    val name: String,
    /** CAN ID as in buffer bytes [2..3]. */
    val canId: Int,
    /** Page number as in buffer byte [4]. */
    val page: Int,
    /** Start bit, little-endian bit numbering over the payload. */
    val startBit: Int,
    /** Field width in bits, 1..32. */
    val width: Int,
    /** physical = raw * scale + offset. */
    val scale: Double = 1.0,
    val offset: Double = 0.0,
    val unit: String = "",
    val confirmed: Boolean = false,
    /** Catalog name the position comes from, or "" if none. */
    val catalogName: String = "",
    val notes: String = ""
)

object FirehoseFieldTable {

    const val FIREHOSE_SUBTYPE = 0x99000020L
    private const val PAYLOAD_OFFSET = 6

    /** p160: reset behaviour of the 0x2D0 counters, from Companion 13–21.11. */
    private const val GB_CYCLE_RESET_NOTE =
        "Resets to 0 at every power-on from off (all drives 15–21.11, even after a 10 min stop); " +
            "keeps counting while a charge started or running in the same on-cycle (14.11, 15.11, 20.11 DC). " +
            "A single 0 frame right after wake can be transient (13.11 17:44). Use end − start within " +
            "an on-cycle; treat a drop that persists as a reset"

    val fields: List<FirehoseField> = listOf(
        // ─── Confirmed ───────────────────────────────────────────────────
        FirehoseField("gb_remaining_energy_kwh", 0x02EE, 0, 10, 14, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_REMAINING_BATTERY_POWER",
            notes = "remaining pack energy; 48.8 → 45.0 over 09.11 drive (∫V·I 3.63 + parking); ~1 frame / 30 s. " +
                "Full pack reads 65.2 at SOC 98.9 (16.11, 21.11) = nominal, so it does not show ageing. " +
                "Not linear in SOC: ~0.69 kWh per % between 49 and 99 %; prefer it over SOC × capacity"),
        FirehoseField("gb_cycle_discharge_kwh", 0x02D0, 0, 16, 16, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_ACTUAL_DISCHARGE_ENERGY_TOTAL",
            notes = "energy out of the pack; +5.0 vs ∫V·I(+) 5.07 on 09.11. " + GB_CYCLE_RESET_NOTE),
        FirehoseField("gb_cycle_regen_kwh", 0x02D0, 0, 32, 16, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_ACTUAL_RENEWABLE_ENERGY_TOTAL",
            notes = "ALL energy into the pack: regen AND charging. Regen +1.6 vs ∫V·I(−) 1.57 (09.11); " +
                "AC night charge +44.3 vs remaining-energy +45.1 (13–14.11); DC +2.3 vs ∫V·I 2.27 (20.11); " +
                "on DC it reads ~7 % above stored energy (terminal energy incl. I·R loss). " + GB_CYCLE_RESET_NOTE),
        FirehoseField("fh_ac_temp_main_c", 0x02FC, 0, 32, 8, 0.5, unit = "°C",
            confirmed = true, catalogName = "AC_TEMP_MAIN",
            notes = "rule check: equals HAL 0x2FC00028 on all 35 events 07.11"),
        FirehoseField("fh_ac_temp_deputy_c", 0x02FC, 0, 40, 8, 0.5, unit = "°C",
            confirmed = true, catalogName = "AC_TEMP_DEPUTY",
            notes = "rule check: equals HAL 0x2FC00030"),
        FirehoseField("fh_energy_state", 0x0208, 0, 16, 4,
            confirmed = true, catalogName = "ENERGY_STATE",
            notes = "rule check: same values 0/2/5 as HAL 0x20800018"),
        // p159: outside air. Replaces candidate ac_temp_out_raw (same bits).
        FirehoseField("fh_temp_out_c", 0x02FC, 0, 48, 8, 1.0, -128.0, unit = "°C",
            confirmed = true, catalogName = "AC_TEMP_OUT",
            notes = "outside air, step 1 °C, ~0.9 Hz from stream start; every HAL AC_TEMP_OUT event matched " +
                "(raw 133/132/128/132 ↔ 5/4/0/4 °C, 09–14.11)"),

        // p159: charging state, calibrated on AC 13–14.11 and DC 20.11.
        // Frame 0x2EB comes at ~1 Hz whatever happens, so these give the
        // current state right after the stream starts. Whole frame: rest
        // 06 42 1F 00 00 20 88 F0; AC charging 05 42 11 00 00 24 89 FA;
        // DC charging 05 42 D1 00 00 28 CB F4.
        FirehoseField("fh_charging_device_state", 0x02EB, 0, 16, 4,
            confirmed = true, catalogName = "CHARGING_BATTERRY_DEVICE_STATE",
            notes = "15 rest, 0 starting, 1 charging, 2 stopping; AC and DC; within 1 s of HAL"),
        FirehoseField("fh_charging_gun_connect_state", 0x02EB, 0, 42, 3,
            confirmed = true, catalogName = "CHARGING_GUN_CONNECT_STATE",
            notes = "0 no gun, 1 AC gun, 2 DC gun; HAL 0x2EB00832 = this + 1"),
        FirehoseField("fh_charging_type", 0x02EB, 0, 48, 4,
            confirmed = true, catalogName = "CHARGING_TYPE",
            notes = "8 not charging, 9 AC charging, 11 DC charging; upper nibble of the byte differs " +
                "(8 rest/AC, 0 DC gun, C DC charging) and is left out"),
        FirehoseField("fh_obc_working_status", 0x02C3, 0, 2, 4,
            confirmed = true, catalogName = "CHARGING_SYSTEM_WORKING_STATUS",
            notes = "on-board charger, AC only: 0 rest, 2 charging, 3 stopping (1 starting seen only in HAL); " +
                "frame idle during DC; ~1 frame / 30 s"),

        // p160: DC-DC output (12 V side) load current. Replaces candidate
        // dcdc_byte6_raw (same bits). Scale from clean 12 V load steps on
        // 24.11, climate off, inverter at 0, against battery power:
        //   rear defrost  +34.7 units  +0.285 kW   8.2 W/unit
        //   seat heaters  +17.6 units  +0.13 kW    7.4 W/unit
        // 7.4–8.2 W/unit on the HV side, DC-DC ~90 %, 12 V rail ~13.3 V
        // (ATRV reads 12.8, adapters read low) → ~0.5 A per unit, no offset.
        // Checks: base 30 → ~15 A ≈ 200 W; rear defrost ~17 A; two seats
        // ~9 A; wheel ~3.4 A; low beams ~1.7 A; blower at 7 ~10 A.
        FirehoseField("dcdc_load_current_a", 0x02C7, 0, 48, 8, 0.5, unit = "A",
            confirmed = true,
            notes = "12 V load current at the DC-DC output; scale ±15 % (depends on assumed DC-DC efficiency " +
                "and 12 V level); ~1 Hz; byte 7 = 234 − byte 6 (check byte). Power ≈ value × 13.3 V"),

        // ─── Candidates (raw) ────────────────────────────────────────────

        FirehoseField("bodywork_battery_voltage_level", 0x02FC, 0, 58, 2,
            catalogName = "BODYWORK_BATTERY_VOLTAGE_LEVEL",
            notes = "CANDIDATE 12 V level enum; always 1 so far"),
        FirehoseField("gb_dcdc_state_alarm", 0x02C7, 0, 26, 2, catalogName = "GB_DCDC_STATE_ALARM",
            notes = "CANDIDATE; always 1 so far"),
        FirehoseField("gb_dcdc_temp_alarm", 0x02C7, 0, 8, 2, catalogName = "GB_DCDC_TEMP_ALARM",
            notes = "CANDIDATE; always 0 so far"),
        FirehoseField("bodywork_power_level", 0x01CD, 0, 34, 3, catalogName = "BODYWORK_POWER_LEVEL",
            notes = "CANDIDATE power mode (OFF/ACC/ON?); always 3 so far, also outside READY"),
        FirehoseField("energy_bcm_state", 0x01CD, 0, 10, 2, catalogName = "ENERGY_BCM_STATE",
            notes = "CANDIDATE; always 2 so far"),
        FirehoseField("smart_charging_state_2nd", 0x01CD, 0, 20, 3,
            catalogName = "CHARGING_SMART_CHARGING_STATE_2nd",
            notes = "CANDIDATE: 12 V top-up from the pack while parked?; always 0 so far"),
        FirehoseField("fh_charging_ctrl_byte0", 0x02EB, 0, 0, 8,
            notes = "CANDIDATE, no catalog field: 6 rest, 2 DC handshake, 5 charging (AC and DC), 4 stopping"),
        FirehoseField("fh_obc_gun_identification", 0x02C3, 0, 46, 2,
            catalogName = "CHARGING_GUN_IDENTIFICATION",
            notes = "CANDIDATE: 1 while the on-board charger runs (AC), 0 otherwise; frame idle on DC"),
        FirehoseField("fh_vtov_discharge_quantity", 0x02EB, 0, 24, 16,
            catalogName = "CHARGING_VTOV_DISCHARGE_QUANTITY",
            notes = "CANDIDATE V2L energy; 0 on all drives and charges so far"),
    )

    /** p159: name of the field RawCaptureSink uses as charging evidence. */
    const val CHARGING_STATE_FIELD = "fh_charging_device_state"
    /** p159: fh_charging_device_state value meaning "charging". */
    const val CHARGING_STATE_ACTIVE = 1L

    private val byFrame: Map<Long, List<FirehoseField>> =
        fields.groupBy { (it.canId.toLong() shl 8) or it.page.toLong() }

    /** CAN ID and page of a firehose buffer, or null if it is not one. */
    fun parse(buf: ByteArray?): Pair<Int, Int>? {
        if (buf == null || buf.size <= PAYLOAD_OFFSET) return null
        if (buf[0].toInt() != 0 || buf[1].toInt() != 0) return null
        val canId = ((buf[2].toInt() and 0xff) shl 8) or (buf[3].toInt() and 0xff)
        val page = buf[4].toInt() and 0xff
        return canId to page
    }

    /** Fields defined for this frame, or an empty list. */
    fun fieldsFor(canId: Int, page: Int): List<FirehoseField> =
        byFrame[(canId.toLong() shl 8) or page.toLong()] ?: emptyList()

    /**
     * Raw unsigned value of [f] in firehose buffer [buf], or null when the
     * payload is too short. [buf] is the whole buffer (header included).
     */
    fun extractRaw(f: FirehoseField, buf: ByteArray): Long? {
        val payloadLen = buf.size - PAYLOAD_OFFSET
        if (f.startBit < 0 || f.startBit + f.width > payloadLen * 8) return null
        var v = 0L
        for (i in 0 until f.width) {
            val bit = f.startBit + i
            val byte = buf[PAYLOAD_OFFSET + bit / 8].toInt() and 0xff
            if ((byte ushr (bit % 8)) and 1 == 1) v = v or (1L shl i)
        }
        return v
    }

    fun physical(f: FirehoseField, raw: Long): Double = raw * f.scale + f.offset
}
