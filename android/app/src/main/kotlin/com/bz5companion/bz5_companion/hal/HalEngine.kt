// === COMPANION-AUTHORED (editable) — DiLink platform fork, patch +107 ===
// NOT vendored. This file is the thin seam between BydNativePlugin and the
// two vendored HAL engines (LiveTelemetrySubscriber = BZ5/FIELDS,
// Bz3TelemetrySubscriber = BZ3/GETTERS). It exists so the plugin holds ONE
// reference type (HalEngine) and the BZ3-vs-BZ5 choice is made once, in the
// consumer, by device shape — exactly as the recon handoff prescribes.
//
// WHY ADAPTERS INSTEAD OF `: HalEngine` ON THE ENGINES:
//   Both engines are SHA-pinned DO-NOT-EDIT vendored files. We must not add
//   a supertype to their class declarations (that would edit the vendored
//   body and break the sync contract). Instead each adapter OWNS an engine
//   instance and forwards the four contract calls. The engines already share
//   an identical public surface (start/stop/isActive/statusSnapshot and the
//   same (Context, TelemetrySink, List<TargetSpec>) constructor), so the
//   adapters are pure pass-throughs — no behavioural logic lives here.
package com.bz5companion.bz5_companion.hal

import android.content.Context

/**
 * Uniform handle over a HAL telemetry engine, regardless of platform shape.
 *
 * Implementations wrap a vendored subscriber whose public contract is
 * identical across BZ3/BZ5; the only real difference (1-arg vs 2-arg
 * registerListener; getter vs field payload extraction) is fully contained
 * inside the wrapped engine and invisible here.
 *
 * Lifecycle/thread model is the wrapped engine's: [start] is CAS-guarded and
 * idempotent, sink callbacks arrive on framework binder threads, [stop] is
 * idempotent and leaves the instance restartable.
 */
interface HalEngine {
    fun start(): SubscriptionStatus
    fun stop()
    val isActive: Boolean
    fun statusSnapshot(): SubscriptionStatus

    /** Human-readable tag for honesty UI / logs, e.g. "FIELDS" or "GETTERS". */
    val engineTag: String
}

/**
 * BZ5 / FIELDS engine. Wraps the vendored [LiveTelemetrySubscriber]
 * (payload via mDeviceSubType/mIntValue/mDoubleValue/mBufData fields,
 * 2-arg registerListener(listener, int[])).
 */
class Bz5EngineAdapter(
    ctx: Context,
    sink: TelemetrySink,
    targets: List<TargetSpec> = emptyList()
) : HalEngine {
    private val engine = LiveTelemetrySubscriber(ctx, sink, targets)
    override fun start(): SubscriptionStatus = engine.start()
    override fun stop() = engine.stop()
    override val isActive: Boolean get() = engine.isActive
    override fun statusSnapshot(): SubscriptionStatus = engine.statusSnapshot()
    override val engineTag: String get() = "FIELDS"
}

/**
 * BZ3 / GETTERS engine. Wraps the vendored [Bz3TelemetrySubscriber]
 * (payload via getEventType/getValue/getDoubleValue/getBufferData getters,
 * 1-arg registerListener(IBYDAutoListener)). featureIds on each TargetSpec
 * are ignored by this engine (1-arg registration), but the device list
 * itself is reused — so the same streamingTargets(ctx) feeds both.
 */
class Bz3EngineAdapter(
    ctx: Context,
    sink: TelemetrySink,
    targets: List<TargetSpec> = emptyList()
) : HalEngine {
    private val engine = Bz3TelemetrySubscriber(ctx, sink, targets)
    override fun start(): SubscriptionStatus = engine.start()
    override fun stop() = engine.stop()
    override val isActive: Boolean get() = engine.isActive
    override fun statusSnapshot(): SubscriptionStatus = engine.statusSnapshot()
    override val engineTag: String get() = "GETTERS"
}
