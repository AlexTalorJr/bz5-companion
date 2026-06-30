// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/Bz3TelemetrySubscriber.kt
// Synced: 2026-06-30 (recon v0.10.79, commit p100)
// SHA256: dca150f550d55fd63a6a87e1f86534b814700c70426ff5fce8255ef974a29a16
package com.bz5companion.bz5_companion.hal

import android.content.Context
import android.util.Log
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/Bz3TelemetrySubscriber.kt
// Owner: bz5_recon (patch 100)
// Sync method: copy-paste with checksum header (until shared module exists).
// DO NOT edit downstream without re-syncing upstream.
//
// BZ3 counterpart of LiveTelemetrySubscriber. Same public contract
// (start/stop/isActive/statusSnapshot), same TelemetrySink output — so a
// consumer (RollupSink in recon, DecodedStreamSink in companion) cannot tell
// BZ3 from BZ5: it receives identical onRawEvent(targetKey, subtype, int,
// double, buf, ts) calls. The companion picks BZ3 vs BZ5 engine by device
// fingerprint (trinket/SDK29 → BZ3) — that selection lives in the consumer,
// not here.
//
// Why a SEPARATE class instead of branching inside LiveTelemetrySubscriber:
// the two differ in exactly two places, both verified on real BZ3 hardware
// (probes p096 / p098 / p099):
//
//   1. REGISTRATION arity. BZ5 uses the 2-arg registerListener(listener,
//      int[] fids). BZ3 only exposes the 1-arg registerListener(listener)
//      that is proxy-compatible with android.hardware.IBYDAutoListener. The
//      BZ5 2-arg lookup fails on BZ3 with no_matching_registerListener
//      (attempted=29, registered=0) — that was the original BZ3 wall.
//
//   2. PAYLOAD EXTRACTION. On BZ5 the event object exposes its data via
//      FIELDS (mDeviceSubType / mIntValue / mDoubleValue / mBufData) read by
//      ReflectionCache. On BZ3 those fields are CLOSED to reflection (p098
//      dump: `fields` empty); data is reachable ONLY through GETTERS:
//        getEventType()   → subtype/fid  (Int, unsigned u32; e.g. 0x99000020,
//                           0x15100008 speed, 0x28A00008 RPM — same fids as BZ5)
//        getValue()       → Int    (sentinel −1 when not an int payload)
//        getDoubleValue() → Double (sentinel 0 when not a double payload)
//        getBufferData()  → ByteArray (BigData CAN frame; null otherwise)
//      The BigData buffer keeps the BZ5 wire layout (b[0..1]=0x0000,
//      b[2..3]=CAN_ID u16BE), so downstream BigData handling is unchanged.
//
// Everything else (TargetRegistry.streamingTargets, TelemetrySink contract,
// TelemetryDecoderTable, RollupSink's BigData-by-CAN-id bucketing) is shared
// with BZ5 untouched. featureIds on each TargetSpec are simply ignored here
// (1-arg registration takes no fid list); the device list itself is reused.

/**
 * Subscribes to BYDAuto*Device push channels on a BZ3 head unit and forwards
 * raw events to a [TelemetrySink].
 *
 * Lifecycle / thread model: identical contract to [LiveTelemetrySubscriber].
 *   - Construct with (ctx, sink, targets). Empty targets ⇒ streamingTargets(ctx).
 *   - [start] registers all listeners (CAS-guarded, idempotent).
 *   - Sink callbacks arrive on framework binder threads — implementations
 *     MUST be fast / non-blocking (see TelemetrySink doc).
 *   - [stop] unregisters all; idempotent; instance restartable.
 */
class Bz3TelemetrySubscriber(
    private val ctx: Context,
    private val sink: TelemetrySink,
    private val targets: List<TargetSpec> = emptyList()
) {

    private val active = AtomicBoolean(false)
    private val registrations = CopyOnWriteArrayList<Registration>()
    private var lastStatus: SubscriptionStatus = SubscriptionStatus(0, 0, 0, emptyMap())
    private var listenerInterface: Class<*>? = null

    // Cache of per-event-class getters (hot path). Resolved lazily on the
    // first event of each class, then O(1).
    private data class EventGetters(
        val eventType: Method?,
        val value: Method?,
        val doubleValue: Method?,
        val bufferData: Method?
    )
    private val gettersCache = ConcurrentHashMap<Class<*>, EventGetters>()

    private data class Registration(
        val spec: TargetSpec,
        val deviceInstance: Any,
        val proxy: Any
    )

    val isActive: Boolean
        get() = active.get()

    /** Register listeners for all targets. Idempotent. */
    fun start(): SubscriptionStatus {
        if (!active.compareAndSet(false, true)) {
            Log.w(TAG, "start() called but already active; returning cached status")
            return lastStatus
        }

        val effectiveTargets = if (targets.isEmpty()) {
            TargetRegistry.streamingTargets(ctx)
        } else {
            targets
        }

        listenerInterface = try {
            Class.forName("android.hardware.IBYDAutoListener")
        } catch (e: Throwable) {
            active.set(false)
            val err = "IBYDAutoListener_class_not_found: ${e.javaClass.simpleName}"
            lastStatus = SubscriptionStatus(
                targetsAttempted = effectiveTargets.size,
                targetsRegistered = 0,
                targetsFailed = effectiveTargets.size,
                perTargetErrors = effectiveTargets.associate { it.key to err }
            )
            return lastStatus
        }

        val errors = mutableMapOf<String, String>()
        var attempted = 0
        var registered = 0

        for (spec in effectiveTargets) {
            attempted++
            val err = tryRegister(spec)
            if (err == null) {
                registered++
                sink.onTargetEvent(TargetEvent(spec.key, TargetEvent.Kind.REGISTERED_OK))
            } else {
                errors[spec.key] = err
                sink.onTargetEvent(TargetEvent(spec.key, TargetEvent.Kind.REGISTER_FAILED, err))
            }
        }

        lastStatus = SubscriptionStatus(
            targetsAttempted = attempted,
            targetsRegistered = registered,
            targetsFailed = attempted - registered,
            perTargetErrors = errors.toMap()
        )
        Log.i(TAG, "start() complete (BZ3): registered=$registered/$attempted")
        return lastStatus
    }

    /**
     * Register one target via the 1-arg registerListener(IBYDAutoListener).
     * Returns null on success, error string on failure.
     */
    private fun tryRegister(spec: TargetSpec): String? {
        val cls = try {
            Class.forName(spec.deviceClassName)
        } catch (e: ClassNotFoundException) {
            return "class_not_found"
        } catch (e: Throwable) {
            return "class_forName: ${e.javaClass.simpleName}: ${e.message?.take(80)}"
        }

        val instance = try {
            cls.getMethod("getInstance", Context::class.java).invoke(null, ctx)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            val cause = e.cause
            return "getInstance_threw: ${cause?.javaClass?.simpleName}: ${cause?.message?.take(80)}"
        } catch (e: Throwable) {
            return "getInstance: ${e.javaClass.simpleName}: ${e.message?.take(80)}"
        } ?: return "getInstance_returned_null"

        val ifc = listenerInterface ?: return "listener_interface_null_state"

        // BZ3: 1-arg registerListener(IBYDAutoListener). Match by assignability
        // (proxy implements the interface). This is the overload BZ5's 2-arg
        // lookup skipped.
        val registerMethod = try {
            cls.methods.firstOrNull { m ->
                m.name == "registerListener" &&
                        m.parameterCount == 1 &&
                        m.parameterTypes[0].isAssignableFrom(ifc)
            }
        } catch (e: Throwable) {
            return "registerListener_lookup: ${e.javaClass.simpleName}"
        } ?: return "no_matching_registerListener_1arg"

        val proxy = try {
            Proxy.newProxyInstance(
                ifc.classLoader,
                arrayOf(ifc),
                makeInvocationHandler(spec)
            )
        } catch (e: Throwable) {
            return "proxy_build: ${e.javaClass.simpleName}: ${e.message?.take(80)}"
        }

        try {
            registerMethod.invoke(instance, proxy)
        } catch (e: java.lang.reflect.InvocationTargetException) {
            val cause = e.cause
            return "registerListener_threw: ${cause?.javaClass?.simpleName}: ${cause?.message?.take(120)}"
        } catch (e: Throwable) {
            return "registerListener: ${e.javaClass.simpleName}: ${e.message?.take(80)}"
        }

        registrations.add(Registration(spec, instance, proxy))
        return null
    }

    private fun makeInvocationHandler(spec: TargetSpec): InvocationHandler {
        return InvocationHandler { proxyRef, method, args ->
            when (method.name) {
                "onDataChanged" -> {
                    // BZ3 carries the event object in args[0]; subtype + payload
                    // come from its getters. (onDataEventChanged is the framework's
                    // duplicate dispatch — args[0]=Integer subtype — handled below
                    // by ignoring it, mirroring the BZ5 p071 decision: process
                    // onDataChanged only to avoid double-counting / subtype=0.)
                    val first = args?.firstOrNull()
                    if (first != null) {
                        dispatchEvent(spec.key, first)
                    }
                    null
                }
                "onDataEventChanged" -> {
                    // Duplicate of onDataChanged. Ignored to avoid double counting.
                    null
                }
                "onError" -> {
                    val code = (args?.getOrNull(0) as? Int) ?: -1
                    val msg = (args?.getOrNull(1) as? String) ?: ""
                    try {
                        sink.onTargetEvent(TargetEvent(
                            spec.key,
                            TargetEvent.Kind.ON_ERROR_CALLBACK,
                            "code=$code msg=${msg.take(120)}"
                        ))
                    } catch (_: Throwable) {}
                    null
                }
                "hashCode" -> System.identityHashCode(proxyRef)
                "equals"   -> args?.firstOrNull() === proxyRef
                "toString" -> "Bz3TelemetryListener@${spec.key}"
                else -> null
            }
        }
    }

    /**
     * Extract (subtype, payload) from a BZ3 event via cached getters and push
     * to the sink. Kept tiny + non-blocking (binder thread).
     */
    private fun dispatchEvent(targetKey: String, event: Any) {
        val g = gettersFor(event.javaClass)

        val subtypeRaw = try { g.eventType?.invoke(event) } catch (_: Throwable) { null }
        val subtype: Long = when (subtypeRaw) {
            is Int  -> subtypeRaw.toLong() and 0xFFFFFFFFL
            is Long -> subtypeRaw and 0xFFFFFFFFL
            else    -> return  // no eventType ⇒ cannot key it; drop
        }

        val intValue: Int? = try {
            when (val v = g.value?.invoke(event)) {
                is Int -> if (v == -1) null else v   // −1 = "not an int payload" sentinel
                is Number -> v.toInt()
                else -> null
            }
        } catch (_: Throwable) { null }

        val doubleValue: Double? = try {
            when (val v = g.doubleValue?.invoke(event)) {
                is Double -> if (v == 0.0) null else v  // 0 = "not a double payload" sentinel
                is Number -> v.toDouble()
                else -> null
            }
        } catch (_: Throwable) { null }

        val bufData: ByteArray? = try {
            g.bufferData?.invoke(event) as? ByteArray
        } catch (_: Throwable) { null }

        val nowMs = System.currentTimeMillis()
        try {
            sink.onRawEvent(targetKey, subtype, intValue, doubleValue, bufData, nowMs)
        } catch (e: Throwable) {
            // Sink threw — do not propagate to framework (would tear down our
            // registration). Mirror BZ5 behavior: log + drop.
            Log.w(TAG, "sink.onRawEvent threw for $targetKey: ${e.javaClass.simpleName}")
        }
    }

    private fun gettersFor(cls: Class<*>): EventGetters =
        gettersCache.computeIfAbsent(cls) { c ->
            fun find(name: String): Method? = try {
                c.getMethod(name).also { it.isAccessible = true }
            } catch (_: Throwable) { null }
            EventGetters(
                eventType = find("getEventType"),
                value = find("getValue"),
                doubleValue = find("getDoubleValue"),
                bufferData = find("getBufferData")
            )
        }

    /** Unregister all listeners. Idempotent. */
    fun stop() {
        if (!active.compareAndSet(true, false)) {
            return
        }
        for (reg in registrations) {
            try {
                val unreg = reg.deviceInstance.javaClass.methods.firstOrNull { m ->
                    m.name == "unregisterListener" &&
                            m.parameterCount == 1 &&
                            m.parameterTypes[0].name == "android.hardware.IBYDAutoListener"
                } ?: reg.deviceInstance.javaClass.methods.firstOrNull {
                    it.name == "unregisterListener" && it.parameterCount == 1
                } ?: reg.deviceInstance.javaClass.methods.firstOrNull { it.name == "unregisterListener" }

                if (unreg != null) {
                    unreg.invoke(reg.deviceInstance, reg.proxy)
                    sink.onTargetEvent(TargetEvent(reg.spec.key, TargetEvent.Kind.UNREGISTERED_OK))
                } else {
                    sink.onTargetEvent(TargetEvent(
                        reg.spec.key,
                        TargetEvent.Kind.UNREGISTER_FAILED,
                        "unregisterListener_method_not_found_LEAK"
                    ))
                }
            } catch (e: Throwable) {
                sink.onTargetEvent(TargetEvent(
                    reg.spec.key,
                    TargetEvent.Kind.UNREGISTER_FAILED,
                    "${e.javaClass.simpleName}: ${e.message?.take(80)}"
                ))
            }
        }
        registrations.clear()
        Log.i(TAG, "stop() complete (BZ3)")
    }

    /** Snapshot of last start() outcome. */
    fun statusSnapshot(): SubscriptionStatus = lastStatus

    companion object {
        private const val TAG = "Bz3TelemetrySubscr"
    }
}
