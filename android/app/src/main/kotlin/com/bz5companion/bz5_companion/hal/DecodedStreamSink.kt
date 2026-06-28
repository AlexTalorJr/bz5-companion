// === COMPANION-AUTHORED (not vendored) ===
// This file is owned by bz5_companion. It implements the frozen
// TelemetrySink interface (vendored from recon) and bridges the live HAL
// telemetry stream into a Flutter EventChannel.
//
// Contract notes carried from the recon handoff (v0.10.53):
//   - LiveTelemetrySubscriber already de-dupes the framework's double
//     dispatch: it calls onRawEvent ONCE per event (the onDataChanged
//     path) and never the onDataEventChanged duplicate. So this sink sees
//     a clean stream — no dedup needed here. (If we ever wrote our own
//     Proxy/handler we'd have to handle onDataChanged-only ourselves.)
//   - onRawEvent runs on the framework's BINDER thread. It must NOT block
//     and must NOT touch the EventSink directly (EventSink.success is
//     main-thread-only). We enqueue and drain on the main looper.
//   - pack_current and every other value arrives already decoded by
//     TelemetryDecoderTable (HAL gives finished units). We apply NO manual
//     arithmetic here — no (raw-5018)*0.1021, no sign flip, no scale.
package com.bz5companion.bz5_companion.hal

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bridges [TelemetrySink] (binder-thread, decoded) → a Flutter
 * EventChannel (main-thread, batched).
 *
 * Lifecycle is owned by the plugin: construct with the active EventSink
 * when Dart starts listening, call [detach] when Dart cancels so late
 * binder callbacks become no-ops instead of touching a dead sink.
 *
 * Batching: events arrive at up to ~50 Hz aggregate (speed ~8.7 Hz plus
 * the other 7 targets). Posting one main-looper message per event would
 * flood the platform-channel. We coalesce: a single drain pass ships
 * everything queued since the last pass as one List<Map>, and we only
 * post a drain when one isn't already pending.
 */
class DecodedStreamSink(
    eventSink: EventChannel.EventSink,
    private val overrides: Map<String, Decoder> = emptyMap(),
) : TelemetrySink {

    @Volatile
    private var sink: EventChannel.EventSink? = eventSink

    private val queue = ConcurrentLinkedQueue<Map<String, Any?>>()
    private val drainScheduled = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())

    // ─── COMPANION-AUTHORED: fractional SOC from BigData (v0.1.29+86) ───
    //
    // 0x044C is a CAN-ID INSIDE the BigData raw frame (channel
    // BYDAutoBigDataDevice, subtype 0x99000020), NOT a standalone fid. The
    // vendored TelemetryDecoderTable cannot reach into the frame to pull
    // bytes [10:11] (its decode() returns null for BUFDATA — "caller does
    // format-specific decode"), and the override map only does scale/offset
    // on whole fids. So the byte-level extraction lives HERE, in the sink we
    // own, exactly where bufData is in hand.
    //
    // companion already SUBSCRIBES to this channel — the vendored
    // TargetRegistry.streamingTargets includes BYDAutoBigDataDevice_canData-
    // Collect (fid 0x99000020), so the frame already arrives at onRawEvent.
    // No recon change is needed (Друг 3 confirmed: emission is companion-side,
    // the stream is ours; vendored files unchanged, SHA intact).
    //
    // Frame layout (recon-confirmed): [0..1]=0x0000, [2..3]=CAN_ID (BE),
    // [4..]=payload. For 0x044C: SOC% = u16LE(b[10],b[11]) × 0.1. Formula
    // validated on a wide SOC range (71.6–77.8%, RMSE 0.065% vs UDS
    // 790/1FFD) and on a real frame (SOC 65.2%, recon 16:13). Cadence is
    // SLOW — ~2 frames per 30 s (≈ every 15 s), bus-limited, NOT 1 Hz; the
    // pipeline must treat its absence on a given tick as normal, never an
    // error. A frame is identified by header [0:1]==0 + CAN-ID, NOT by the
    // event subtype (that is 0x99000020 for the entire BigData channel and
    // cannot distinguish 0x044C). The frame is always 14 bytes and never
    // out of range across 89 frames / two sessions (Друг 3), so length +
    // header + CAN-ID + 0..100 range is sufficient validation.
    private val bigDataSubtype: Long = 0x99000020L
    private val socPreciseCanId: Int = 0x044C

    // v0.1.29+90: additional companion-side extractions from BigData frames,
    // all confirmed against ground-truth in the recon HANDOFF (Друг 3's
    // synchronous 30-min drive, 2026-06-24/25). These close halOnly dashes
    // that OBD2-only signals leave blank without a dongle:
    //   • SOH from 0x02D3 b[10]  — direct read, =97 matched OBD2 (TWÉRDO),
    //     arrives ~1 Hz (0x02D3 is a fast BMS frame). Closes "SOH —".
    //   • battery_temp from 0x044C b[12] — °C = raw−40. CONFIRMED on the DC
    //     fast-charge session (recon, 2026-06-28): r=+0.986 vs the per-module
    //     UDS ground-truth over a wide 33→43°C range, slope 1.04, RMSE 0.6°C.
    //     v0.1.29+101: was b[7] until this DC validation — b[7] turned out
    //     FLAT (32–34°C while the pack actually ran 33–43°C), i.e. NOT the
    //     temperature. b[12] tracks the real pack temp. Used as a FALLBACK
    //     behind the confirmed probe 0x47800010 (exact but sleeps at
    //     standstill); this fills the cell when the probe is asleep.
    //   • soc_precise from 0x044C u16LE[10]×0.1 — fractional SOC (existing).
    private val socFrameCanId: Int = 0x044C      // soc_precise + battery_temp
    private val bmsFrameCanId: Int = 0x02D3      // SOH
    private val socPreciseTempByte: Int = 12     // 0x044C b[12], °C = raw−40 (DC-confirmed, was b[7])
    private val sohByte: Int = 10                // 0x02D3 b[10], direct %

    // v0.1.29+88: raw BigData diagnostic logging. For these CAN-IDs the sink
    // emits an EXTRA event (name="bigdata_raw") carrying the full frame hex,
    // so an export can be diffed against recon line-by-line and so we can
    // confirm whether a frame (e.g. 0x044C) arrives at all — separating
    // "frame doesn't arrive" from "frame arrives but filter/decode drops it".
    // Whitelist only (Друг 3's set) — BigData is ~60 events/s across 103
    // CAN-IDs, logging everything raw would bloat the DB (~5–6k rows / 90 s).
    // No rollup of the rest in this version (separate task if a full CAN
    // overview is ever needed). The decoded signals (incl. soc_precise) are
    // logged separately on the Dart side, per-name throttled.
    private val bigDataRawWhitelist: Set<Int> =
        setOf(0x02D3, 0x044B, 0x044C, 0x0478, 0x0681, 0x0682)

    /** Detach from the Dart sink. Idempotent. Safe to call from any thread. */
    fun detach() {
        sink = null
        queue.clear()
    }

    // ─── TelemetrySink ────────────────────────────────────────────────

    override fun onRawEvent(
        targetKey: String,
        subtype: Long,
        intValue: Int?,
        doubleValue: Double?,
        bufData: ByteArray?,
        timestampMs: Long,
    ) {
        if (sink == null) return  // detached — drop silently

        // decode() returns null for unmapped / hypothesis subtypes → we
        // simply don't forward them (no card appears downstream). It also
        // normalizes the targetKey (strips _tail/_priority/... variant
        // suffixes) internally, so we pass targetKey through untouched.
        val dv = TelemetryDecoderTable.decode(
            targetKey, subtype, intValue, doubleValue, bufData, timestampMs, overrides
        )

        if (dv == null) {
            // v0.1.29+86/+90: the base table dropped it (BUFDATA → null).
            // Before discarding, run the companion-side byte-level extractions
            // we do on BigData frames (soc_precise, SOH, battery_temp). Each
            // emits its own named signal. Everything else with no decoder
            // stays dropped, exactly as before.
            if (subtype == bigDataSubtype && bufData != null) {
                // For whitelisted CAN-IDs, emit a raw-frame diagnostic event
                // (full hex) so the export can be diffed against recon and
                // frame arrival can be confirmed (+88).
                maybeEmitBigDataRaw(bufData, subtype, timestampMs)
                emitBigDataSignals(bufData, subtype, timestampMs)
            }
            return
        }

        queue.add(dv.toEventMap(targetKey, subtype))

        // Coalesce: only schedule a drain if one isn't already pending.
        if (drainScheduled.compareAndSet(false, true)) {
            mainHandler.post { drain() }
        }
    }

    // ─── COMPANION-AUTHORED: BigData byte-level extraction (v0.1.29+86/+90) ──

    /**
     * Extract every companion-side signal carried inside BigData raw frames
     * and queue each as its own named event. Called for any BigData frame
     * (subtype 0x99000020); each extractor self-gates on its CAN-ID so only
     * the relevant frame produces a value.
     *
     * Frames are identified the robust way recon does — header `[0:1]`==0x0000
     * then CAN-ID from `[2:3]` — NOT by the event subtype (always 0x99000020
     * for the whole BigData channel, so it can't tell frames apart). All
     * offsets/formulas are ground-truth-confirmed (see the field block up top
     * and the recon HANDOFF). No OBD2 arithmetic — these are raw-frame field
     * reads (e.g. u16LE×0.1), not the pre-decoded HAL contract.
     *
     *   0x044C → soc_precise  = u16LE[10] × 0.1        (fractional SOC, %)
     *   0x044C → battery_temp_bigdata = b[7] − 40      (°C, CANDIDATE fallback)
     *   0x02D3 → soh          = b[10]                  (%, direct, TWÉRDO)
     */
    private fun emitBigDataSignals(bufData: ByteArray, subtype: Long, timestampMs: Long) {
        if (bufData.size < 4) return
        if (bufData[0].toInt() != 0 || bufData[1].toInt() != 0) return
        val canId = ((bufData[2].toInt() and 0xff) shl 8) or
            (bufData[3].toInt() and 0xff)
        var queued = false

        if (canId == socFrameCanId && bufData.size >= 14) {
            // soc_precise = u16LE[10] × 0.1
            val lo = bufData[10].toInt() and 0xff
            val hi = bufData[11].toInt() and 0xff
            val soc = ((hi shl 8) or lo) * 0.1
            if (soc in 0.0..100.0) {
                queue.add(bigDataSignalMap("soc_precise", "%", soc, subtype, timestampMs))
                queued = true
            }
            // battery_temp_bigdata = b[7] − 40 (CANDIDATE; Dart treats it as
            // a fallback behind the confirmed probe). Plausible pack range.
            val tC = (bufData[socPreciseTempByte].toInt() and 0xff) - 40
            if (tC in -40..90) {
                queue.add(bigDataSignalMap(
                    "battery_temp_bigdata", "°C", tC.toDouble(), subtype, timestampMs))
                queued = true
            }
        }

        if (canId == bmsFrameCanId && bufData.size >= 14) {
            // SOH = b[10], direct percent (=97 matched OBD2, TWÉRDO).
            val soh = bufData[sohByte].toInt() and 0xff
            if (soh in 0..100) {
                queue.add(bigDataSignalMap("soh", "%", soh.toDouble(), subtype, timestampMs))
                queued = true
            }
        }

        if (queued && drainScheduled.compareAndSet(false, true)) {
            mainHandler.post { drain() }
        }
    }

    /**
     * Build a Flutter event map for a BigData-extracted signal. Mirrors
     * [toEventMap]'s contract ({name, unit, value, key, subtype, ts}) so the
     * Dart side routes it like any other signal. The canonical key is built
     * from the BigData target + subtype via the same vendored helpers the
     * decoder path uses, so the Dart allowlist/freshness see a normal name.
     */
    private fun bigDataSignalMap(
        name: String,
        unit: String,
        value: Double,
        subtype: Long,
        timestampMs: Long,
    ): Map<String, Any?> =
        mapOf(
            "name" to name,
            "unit" to unit,
            "value" to value,
            "key" to TelemetryDecoderTable.key(
                TelemetryDecoderTable.normalizeTargetKey(
                    "android.hardware.bydauto.bigdata.BYDAutoBigDataDevice"),
                subtype,
            ),
            "subtype" to subtype,
            "ts" to timestampMs,
        )

    /**
     * v0.1.29+88: if this BigData frame's CAN-ID is whitelisted, queue a
     * raw-frame diagnostic event carrying the full hex. The Dart side
     * recognises name=="bigdata_raw" and writes it to hal_samples with
     * source='bigdata'. Schema matches what recon logs so the two can be
     * diffed: can_id_hex (from `buf[2:3]`), buf_hex (full frame), buf_size,
     * subtype (masked unsigned). int/double are sentinels for BigData (the
     * real data is in the buffer) and are not forwarded here.
     */
    private fun maybeEmitBigDataRaw(
        bufData: ByteArray,
        subtype: Long,
        timestampMs: Long,
    ) {
        if (bufData.size < 4) return
        if (bufData[0].toInt() != 0 || bufData[1].toInt() != 0) return
        val canId = ((bufData[2].toInt() and 0xff) shl 8) or
            (bufData[3].toInt() and 0xff)
        if (canId !in bigDataRawWhitelist) return
        queue.add(
            mapOf(
                "name" to "bigdata_raw",
                "unit" to "",
                "value" to null,
                "key" to "BYDAutoBigDataDevice_canDataCollect",
                "subtype" to subtype,
                "ts" to timestampMs,
                // diagnostic extras (Dart routes these into hal_samples):
                "can_id_hex" to String.format("0x%04X", canId),
                "buf_hex" to toHex(bufData),
                "buf_size" to bufData.size,
            )
        )
        if (drainScheduled.compareAndSet(false, true)) {
            mainHandler.post { drain() }
        }
    }

    private fun toHex(b: ByteArray): String {
        val sb = StringBuilder(b.size * 2)
        for (x in b) sb.append(String.format("%02X", x.toInt() and 0xff))
        return sb.toString()
    }

    // onTargetEvent: per-target lifecycle / health signal (REGISTERED_OK,
    // REGISTER_FAILED, etc). Unused in phase 1 (mutually-exclusive sources
    // don't need it). When we wire auto HAL→OBD2 fallback we'll consume the
    // degradation signal here; default no-op for now.
    override fun onTargetEvent(event: TargetEvent) {
        // no-op (phase 1)
    }

    // ─── drain ────────────────────────────────────────────────────────

    private fun drain() {
        drainScheduled.set(false)
        val s = sink ?: run { queue.clear(); return }
        if (queue.isEmpty()) return

        // Snapshot everything queued since the last pass into one batch.
        val batch = ArrayList<Map<String, Any?>>(queue.size)
        while (true) {
            val item = queue.poll() ?: break
            batch.add(item)
        }
        if (batch.isNotEmpty()) {
            // EventSink.success on the main looper (we're on it here).
            s.success(batch)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// DecodedValue → Flutter event map.
//
// Verified against the vendored TelemetryDecoderTable.kt (recon v0.10.53):
// DecodedValue is { name: String, value: Double, unit: String,
// timestampMs: Long } — it carries NO key/subtype of its own, so we build
// the canonical key here from the originating (targetKey, subtype) using
// the table's own public helpers (normalizeTargetKey strips _tail/etc., key
// formats the 0xHEX8 — identical to how decode() resolved the decoder, so
// the Dart side can route by the same canonical key the decoder lives under).
//
// Flutter contract (hal_telemetry_channel.dart parses exactly these keys):
//   { "name": String, "unit": String, "value": double,
//     "key": String, "subtype": int, "ts": int }
// ─────────────────────────────────────────────────────────────────────
private fun DecodedValue.toEventMap(targetKey: String, subtype: Long): Map<String, Any?> =
    mapOf(
        "name" to name,
        "unit" to unit,
        "value" to value,
        "key" to TelemetryDecoderTable.key(
            TelemetryDecoderTable.normalizeTargetKey(targetKey), subtype,
        ),
        "subtype" to subtype,
        "ts" to timestampMs,
    )
