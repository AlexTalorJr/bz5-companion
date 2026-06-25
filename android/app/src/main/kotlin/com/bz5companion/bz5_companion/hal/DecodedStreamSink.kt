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
    // [4..]=payload. For 0x044C: SOC% = u16LE(b[10],b[11]) × 0.1. Integrity
    // is double-checked: length must be 14, and b[10]+b[13] == 325 (a frame
    // checksum byte Друг 3 found constant across 89 frames / two sessions).
    // Formula validated on a wide SOC range (71.6–77.8%, RMSE 0.065% vs UDS
    // 790/1FFD). Cadence ~30 s (bus-limited; not 1 Hz). Anything failing the
    // length / checksum / 0..100 range yields null (frame dropped silently).
    private val bigDataSubtype: Long = 0x99000020L
    private val socPreciseCanId: Int = 0x044C
    private val socPreciseChecksum: Int = 325

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
            // v0.1.29+86: the base table dropped it (BUFDATA → null). Before
            // we discard, try the one companion-side byte-level extraction we
            // do: fractional SOC out of the BigData frame. Everything else
            // with no decoder stays dropped, exactly as before.
            if (subtype == bigDataSubtype && bufData != null) {
                val soc = extractSocPrecise(bufData)
                if (soc != null) {
                    queue.add(socPreciseEventMap(soc, subtype, timestampMs))
                    if (drainScheduled.compareAndSet(false, true)) {
                        mainHandler.post { drain() }
                    }
                }
            }
            return
        }

        queue.add(dv.toEventMap(targetKey, subtype))

        // Coalesce: only schedule a drain if one isn't already pending.
        if (drainScheduled.compareAndSet(false, true)) {
            mainHandler.post { drain() }
        }
    }

    // ─── COMPANION-AUTHORED: BigData byte-level extraction (v0.1.29+86) ──

    /**
     * Pull fractional SOC (%) out of a BigData raw frame, or null if this
     * frame is not 0x044C, is malformed, or fails the integrity / range
     * checks. See the field block at the top of the class for the layout
     * and the provenance of the formula and checksum.
     *
     * No OBD2 arithmetic here — this is a raw-frame field extraction
     * (u16LE × 0.1), not the pre-decoded HAL contract that forbids manual
     * pack_current scaling.
     */
    private fun extractSocPrecise(bufData: ByteArray): Double? {
        if (bufData.size < 14) return null
        val canId = ((bufData[2].toInt() and 0xff) shl 8) or
            (bufData[3].toInt() and 0xff)
        if (canId != socPreciseCanId) return null
        // u16LE over absolute bytes [10],[11].
        val lo = bufData[10].toInt() and 0xff
        val hi = bufData[11].toInt() and 0xff
        val soc = ((hi shl 8) or lo) * 0.1
        // Integrity: constant frame checksum b[10] + b[13] == 325.
        val checksum = (bufData[10].toInt() and 0xff) + (bufData[13].toInt() and 0xff)
        if (checksum != socPreciseChecksum) return null
        if (soc < 0.0 || soc > 100.0) return null
        return soc
    }

    /**
     * Build the Flutter event map for soc_precise. Mirrors [toEventMap]'s
     * contract ({name, unit, value, key, subtype, ts}) so the Dart side
     * routes it like any other signal. The canonical key is built from the
     * BigData target + subtype via the same vendored helpers the decoder
     * path uses, so allowlist/freshness on the Dart side see a normal name.
     */
    private fun socPreciseEventMap(
        soc: Double,
        subtype: Long,
        timestampMs: Long,
    ): Map<String, Any?> =
        mapOf(
            "name" to "soc_precise",
            "unit" to "%",
            "value" to soc,
            "key" to TelemetryDecoderTable.key(
                TelemetryDecoderTable.normalizeTargetKey(
                    "android.hardware.bydauto.bigdata.BYDAutoBigDataDevice"),
                subtype,
            ),
            "subtype" to subtype,
            "ts" to timestampMs,
        )

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
