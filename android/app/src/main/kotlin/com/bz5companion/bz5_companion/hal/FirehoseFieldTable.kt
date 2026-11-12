// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/FirehoseFieldTable.kt
// Synced: 2026-11-12 (recon v0.10.158, commit p158, 2b280a2)
// SHA256: b1a0986d938c188f5a2f6b045ce7ec96bdc89559b461aae6e4356668612a25c8
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

    val fields: List<FirehoseField> = listOf(
        // ─── Confirmed ───────────────────────────────────────────────────
        FirehoseField("gb_remaining_energy_kwh", 0x02EE, 0, 10, 14, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_REMAINING_BATTERY_POWER",
            notes = "remaining pack energy; 48.8 → 45.0 over 09.11 drive (∫V·I 3.63 + parking); morning 51.7; ~1 frame / 30 s"),
        FirehoseField("gb_cycle_discharge_kwh", 0x02D0, 0, 16, 16, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_ACTUAL_DISCHARGE_ENERGY_TOTAL",
            notes = "energy out of the pack since power-on; +5.0 vs ∫V·I(+) 5.07 on 09.11; resets per power cycle"),
        FirehoseField("gb_cycle_regen_kwh", 0x02D0, 0, 32, 16, 0.1, unit = "kWh",
            confirmed = true, catalogName = "GB_ACTUAL_RENEWABLE_ENERGY_TOTAL",
            notes = "energy into the pack since power-on; +1.6 vs ∫V·I(−) 1.57 on 09.11; resets per power cycle"),
        FirehoseField("fh_ac_temp_main_c", 0x02FC, 0, 32, 8, 0.5, unit = "°C",
            confirmed = true, catalogName = "AC_TEMP_MAIN",
            notes = "rule check: equals HAL 0x2FC00028 on all 35 events 07.11"),
        FirehoseField("fh_ac_temp_deputy_c", 0x02FC, 0, 40, 8, 0.5, unit = "°C",
            confirmed = true, catalogName = "AC_TEMP_DEPUTY",
            notes = "rule check: equals HAL 0x2FC00030"),
        FirehoseField("fh_energy_state", 0x0208, 0, 16, 4,
            confirmed = true, catalogName = "ENERGY_STATE",
            notes = "rule check: same values 0/2/5 as HAL 0x20800018"),

        // ─── Candidates (raw) ────────────────────────────────────────────
        FirehoseField("dcdc_byte6_raw", 0x02C7, 0, 48, 8,
            notes = "CANDIDATE 12 V load current (A?) on the DC-DC frame; base ~41, fan 7 → 60–68, " +
                "rear defrost → 78, seat heaters → 60 (09.11); byte 7 = 234 − byte 6; scale needs ATRV"),
        FirehoseField("ac_temp_out_raw", 0x02FC, 0, 48, 8, catalogName = "AC_TEMP_OUT",
            notes = "CANDIDATE: raw 134→132 while HAL TEMP_OUT 5→4 °C (09.11); fits raw×0.5−62, two points only"),
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
    )

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
