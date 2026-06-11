// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetrySink.kt
// Synced: 2026-06-11 (recon v0.10.57, commit p078)
// SHA256: 28426f4a53bec05385b8e83e2bee56ebc77cc7d88d70405ba3e2834d0caf402a
package com.bz5companion.bz5_companion.hal

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TelemetrySink.kt
// Owner: bz5_recon (patch 068)
// Sync method: copy-paste with checksum header (until shared module exists)
// DO NOT edit downstream without re-syncing upstream.
//
// Friend 1 review (2026-06-09): signature approved, eventMethod field
// deferred (add only if onDataChanged vs onDataEventChanged semantics
// diverge in practice). subtype passed as Long (raw u32 in signed Long
// after `& 0xFFFFFFFFL`) — hex stringification is Sink-internal concern.
//
// THREAD MODEL — critical:
//   onRawEvent is called from the framework listener thread (binder pool).
//   Implementations MUST be fast and non-blocking: append to lock-free /
//   concurrent structures only. NO file I/O, NO JSON serialization, NO
//   synchronous push to Flutter EventChannel. Heavy work belongs in a
//   separate worker thread that drains the Sink's accumulators.

/**
 * Receiver of raw telemetry events from [LiveTelemetrySubscriber].
 *
 * Each implementation defines its own consumption pattern:
 *   - [RollupSink] (bz5_recon): per-(target,subtype) batch rollup, periodic
 *     snapshotAndReset() flushed to JSON chunk files.
 *   - DecodedStreamSink (bz5_companion, planned): per-callback decode via
 *     [TelemetryDecoderTable], streaming push to UI via main looper post.
 *
 * @see LiveTelemetrySubscriber for the subscription machinery that feeds events here.
 */
interface TelemetrySink {

    /**
     * Single raw event from a target's framework listener.
     *
     * MUST return quickly. Anything heavier than a ConcurrentHashMap put or
     * an AtomicInteger increment belongs in a separate thread that reads
     * accumulators populated here.
     *
     * @param targetKey       Stable key from the originating [TargetSpec],
     *                        e.g. `"BYDAutoEngineDevice"`.
     * @param subtype         `mDeviceSubType` of the event object, as raw
     *                        unsigned-u32 widened into a signed Long
     *                        via `& 0xFFFFFFFFL`. Example: `0x28A00008L`.
     * @param intValue        `mIntValue` field, or null if the event has
     *                        no int payload.
     * @param doubleValue     `mDoubleValue` field, or null.
     * @param bufData         `mBufData` byte buffer (BigData CAN frames,
     *                        Statistic battery serial, etc.), or null.
     *                        Caller may retain the reference; do not mutate.
     * @param timestampMs     `System.currentTimeMillis()` captured at the
     *                        moment the proxy handler entered onRawEvent.
     */
    fun onRawEvent(
        targetKey: String,
        subtype: Long,
        intValue: Int?,
        doubleValue: Double?,
        bufData: ByteArray?,
        timestampMs: Long
    )

    /**
     * Lifecycle notification for a single target. Default no-op — only
     * implementations that care about subscription health override this.
     *
     * Currently emitted: REGISTERED_OK, REGISTER_FAILED, UNREGISTERED_OK,
     * UNREGISTER_FAILED, ON_ERROR_CALLBACK (framework called onError on
     * the proxy listener).
     *
     * TODO (deferred per Friend 1 review): add a per-target "no callbacks
     * received in N seconds" degradation signal — would let bz5_companion
     * fail over HAL → OBD2 BLE gracefully without a full subscription
     * teardown. Not in patch 068; intentionally postponed until first
     * production HAL run in companion proves degradation is a real risk.
     */
    fun onTargetEvent(event: TargetEvent) {}
}

/** Lifecycle event for a single target. See [TelemetrySink.onTargetEvent]. */
data class TargetEvent(
    val targetKey: String,
    val kind: Kind,
    val message: String? = null
) {
    enum class Kind {
        REGISTERED_OK,
        REGISTER_FAILED,
        UNREGISTERED_OK,
        UNREGISTER_FAILED,
        /** Framework invoked onError() on our proxy listener. */
        ON_ERROR_CALLBACK,
    }
}

/**
 * Immediate result of [LiveTelemetrySubscriber.start]. Reflects only the
 * register-time outcome, NOT whether callbacks will actually flow — a target
 * may register successfully and never deliver an event (silent push wall).
 */
data class SubscriptionStatus(
    val targetsAttempted: Int,
    val targetsRegistered: Int,
    val targetsFailed: Int,
    /** key → last register-phase error message; entries only for failed targets. */
    val perTargetErrors: Map<String, String>,
)
