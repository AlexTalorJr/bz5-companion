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
        ) ?: return

        queue.add(dv.toEventMap(targetKey, subtype))

        // Coalesce: only schedule a drain if one isn't already pending.
        if (drainScheduled.compareAndSet(false, true)) {
            mainHandler.post { drain() }
        }
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
