// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/LiveTelemetrySubscriber.kt
// Synced: 2026-06-11 (recon v0.10.57, commit p078)
// SHA256: 925befca76c4d73065c6aa35a0f589846ab6bb74cf6a6213a09f4c525814642e
package com.bz5companion.bz5_companion.hal

import android.content.Context
import android.util.Log
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/LiveTelemetrySubscriber.kt
// Owner: bz5_recon (patch 068)
// Sync method: copy-paste with checksum header.
//
// Subscription machinery extracted from TelemetryStateProbe.tryRegisterListener
// (patches 046–067). Sink-agnostic: this class only handles
//   1. resolve BYDAuto*Device.getInstance(ctx)
//   2. build a Proxy implementing android.hardware.IBYDAutoListener
//   3. registerListener(proxy, featureIds[])
//   4. on each callback, extract payload via ReflectionCache and forward
//      to a single TelemetrySink
//   5. unregisterListener() on stop()
//
// Used by bz5_recon LiveMonitorService (with RollupSink) for batch chunks.
// Used by bz5_companion HalDataSource (with DecodedStreamSink, planned) for
// streaming decoded values to UI.

/**
 * Subscribes to a list of BYDAuto*Device push channels and forwards raw
 * events to a [TelemetrySink].
 *
 * Lifecycle:
 *   - Construct with (ctx, sink, targets)
 *   - [start] — register all listeners. Idempotent — second call returns same status.
 *   - Sink receives onRawEvent() callbacks from framework binder threads.
 *   - [stop] — unregister all listeners. Idempotent. After stop(), instance
 *     can be restarted with another [start] call (re-builds proxies fresh).
 *
 * Thread safety:
 *   - start/stop should be called from one controller thread (worker, UI).
 *     They use a CAS guard but rapid concurrent calls aren't supported.
 *   - Sink callbacks arrive on framework listener threads.
 */
class LiveTelemetrySubscriber(
    private val ctx: Context,
    private val sink: TelemetrySink,
    private val targets: List<TargetSpec> = emptyList()
) {

    private val active = AtomicBoolean(false)

    /** Live registrations — populated by start(), drained by stop(). */
    private val registrations = CopyOnWriteArrayList<Registration>()

    private var lastStatus: SubscriptionStatus = SubscriptionStatus(0, 0, 0, emptyMap())

    /** Resolved once at start(). */
    private var listenerInterface: Class<*>? = null

    // ─── Diagnostic capture (patch 070) ──────────────────────────────────
    // Captures the first DIAG_LIMIT_PER_TARGET callbacks per target with
    // method.name, args composition, and field structure of args[0]. Used
    // once at session start to investigate the 50% subtype=0 mystery —
    // hypothesis: framework dispatches both onDataChanged and
    // onDataEventChanged for the same event, with one variant carrying a
    // payload object lacking mDeviceSubType.
    //
    // Counters are AtomicInteger keyed by target.key — increment-and-check
    // pattern, so concurrent callbacks from framework binder threads can
    // race up to DIAG_LIMIT_PER_TARGET without exceeding it meaningfully.
    private val diagCounters = ConcurrentHashMap<String, AtomicInteger>()
    private val diagEntries  = ConcurrentHashMap<String, MutableList<Map<String, Any?>>>()

    private data class Registration(
        val spec: TargetSpec,
        val deviceInstance: Any,
        val proxy: Any
    )

    val isActive: Boolean
        get() = active.get()

    /**
     * Register listeners for all targets. Idempotent — returns cached status
     * if already active.
     */
    fun start(): SubscriptionStatus {
        if (!active.compareAndSet(false, true)) {
            Log.w(TAG, "start() called but already active; returning cached status")
            return lastStatus
        }

        val effectiveTargets = if (targets.isEmpty()) {
            TargetRegistry.defaultTargets(ctx)
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
        Log.i(TAG, "start() complete: registered=$registered/$attempted")
        return lastStatus
    }

    /**
     * Try to register a single target. Returns null on success, error message
     * string on failure. On success, appends to [registrations].
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

        val registerMethod = try {
            cls.methods.firstOrNull { m ->
                m.name == "registerListener" &&
                        m.parameterCount == 2 &&
                        m.parameterTypes[0].name == "android.hardware.IBYDAutoListener" &&
                        m.parameterTypes[1] == IntArray::class.java
            }
        } catch (e: Throwable) {
            return "registerListener_lookup: ${e.javaClass.simpleName}"
        } ?: return "no_matching_registerListener"

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
            registerMethod.invoke(instance, proxy, spec.featureIds)
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
        // Capture spec.key into closure — used as targetKey on every callback.
        // sink is captured from outer class field.
        return InvocationHandler { proxyRef, method, args ->
            when (method.name) {
                "onDataChanged", "onDataEventChanged" -> {
                    val nowMs = System.currentTimeMillis()

                    // Diagnostic capture — first DIAG_LIMIT_PER_TARGET callbacks
                    // per target are dumped with method.name + args composition +
                    // args[0] field structure. After the cap, this branch is
                    // skipped cheaply via the counter check. Capture BOTH methods
                    // so the dump still shows the dispatch pattern if re-run.
                    captureDiagnostic(spec.key, method, args)

                    // Patch 071 — process onDataChanged ONLY.
                    //
                    // Patch 070 diagnostic confirmed the framework dispatches
                    // every event TWICE, in strict alternation:
                    //   onDataChanged([BYDAutoEvent])
                    //       → subtype in event.mDeviceSubType,
                    //         value in mIntValue / mDoubleValue / mBufData
                    //   onDataEventChanged([Integer subtype, BYDAutoEventValue])
                    //       → subtype in args[0] (Integer),
                    //         value in args[1].intValue/doubleValue/bufferDataValue
                    //
                    // The two carry IDENTICAL (subtype, value) pairs — verified
                    // across Engine/BigData/Energy/Charging in the v0.10.50 dump.
                    // onDataEventChanged's floatValue/floatArrayValue/intArrayValue
                    // were always sentinel/null, so it adds no information.
                    //
                    // Before patch 071 we processed both and read args[0] only:
                    // for onDataEventChanged, args[0] is a java.lang.Integer with
                    // no mDeviceSubType field → ReflectionCache fell back to 0L,
                    // producing the "exactly 50% subtype=0" noise AND double-
                    // counting every event. Ignoring onDataEventChanged fixes
                    // both: clean subtypes, true callback rates (half the prior
                    // inflated numbers).
                    if (method.name == "onDataEventChanged") {
                        return@InvocationHandler null
                    }

                    val first = args?.firstOrNull()
                    if (first != null) {
                        val payload = try {
                            ReflectionCache.extract(first)
                        } catch (_: Throwable) {
                            null
                        }
                        if (payload != null) {
                            try {
                                sink.onRawEvent(
                                    spec.key,
                                    payload.subtype,
                                    payload.intValue,
                                    payload.doubleValue,
                                    payload.bufData,
                                    nowMs
                                )
                            } catch (e: Throwable) {
                                // Sink threw — do not propagate back to framework
                                // (would tear down our registration). Log + drop.
                                Log.w(TAG, "sink.onRawEvent threw for ${spec.key}: ${e.javaClass.simpleName}")
                            }
                        }
                    }
                    null
                }
                "onError" -> {
                    val code = (args?.getOrNull(0) as? Int) ?: -1
                    val msg  = (args?.getOrNull(1) as? String) ?: ""
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
                "toString" -> "Bz5TelemetryListener@${spec.key}"
                else -> null
            }
        }
    }

    /**
     * Unregister all listeners. Idempotent — safe to call multiple times,
     * safe to call from finally even if start() failed mid-way.
     */
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
        Log.i(TAG, "stop() complete")
    }

    /** Snapshot of last start() outcome. */
    fun statusSnapshot(): SubscriptionStatus = lastStatus

    /**
     * Capture diagnostic info for one callback invocation. After
     * [DIAG_LIMIT_PER_TARGET] entries per target, becomes a cheap counter
     * read + early-return.
     *
     * Records:
     *   - method.name (onDataChanged vs onDataEventChanged vs anything else)
     *   - args.size
     *   - for each arg: javaClass.name + value summary (primitives shown
     *     directly; objects dumped via reflection of declared fields)
     *
     * Output is consumed by [takeDiagnostics] called by LiveMonitorService
     * after the first chunk window — embedded into the first chunk JSON
     * for offline analysis.
     */
    private fun captureDiagnostic(targetKey: String, method: Method, args: Array<Any?>?) {
        val counter = diagCounters.computeIfAbsent(targetKey) { AtomicInteger(0) }
        val current = counter.get()
        if (current >= DIAG_LIMIT_PER_TARGET) return
        // CAS to claim this slot — protects against rare race where two
        // threads both pass the check above and would both append.
        if (!counter.compareAndSet(current, current + 1)) return

        val entry = try {
            buildDiagnosticEntry(method, args)
        } catch (e: Throwable) {
            mapOf("error" to "${e.javaClass.simpleName}: ${e.message?.take(80)}")
        }
        diagEntries
            .computeIfAbsent(targetKey) { java.util.Collections.synchronizedList(mutableListOf()) }
            .add(entry)
    }

    private fun buildDiagnosticEntry(method: Method, args: Array<Any?>?): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        out["method"] = method.name
        out["args_size"] = args?.size ?: 0
        val argsList = mutableListOf<Map<String, Any?>>()
        args?.forEachIndexed { idx, a -> argsList.add(summarizeArg(idx, a)) }
        out["args"] = argsList
        return out
    }

    private fun summarizeArg(idx: Int, a: Any?): Map<String, Any?> {
        if (a == null) return mapOf("idx" to idx, "class" to "null")
        val cls = a.javaClass
        val clsName = cls.name
        val info = linkedMapOf<String, Any?>("idx" to idx, "class" to clsName)
        // Primitives / boxed numbers — show value inline.
        when (a) {
            is Number, is Boolean, is Char -> {
                info["primitive_value"] = a.toString()
                return info
            }
            is String -> {
                info["string_value"] = a.take(120)
                return info
            }
            is ByteArray -> {
                info["byte_array_size"] = a.size
                info["byte_array_hex_head"] = a.take(32).joinToString("") {
                    "%02x".format(it.toInt() and 0xff)
                }
                return info
            }
        }
        // Object — dump declared fields up the class chain (cap at 32 fields
        // total to bound output size).
        val fieldDump = linkedMapOf<String, Any?>()
        var fieldsSeen = 0
        var c: Class<*>? = cls
        while (c != null && c != Any::class.java && fieldsSeen < 32) {
            val declared = try { c.declaredFields } catch (_: Throwable) { emptyArray() }
            for (f in declared) {
                if (java.lang.reflect.Modifier.isStatic(f.modifiers)) continue
                if (fieldsSeen >= 32) break
                if (fieldDump.containsKey(f.name)) continue  // child class shadows parent
                fieldsSeen++
                val fv = try {
                    f.isAccessible = true
                    val raw = f.get(a)
                    summarizeFieldValue(raw)
                } catch (e: Throwable) {
                    "<read_error: ${e.javaClass.simpleName}>"
                }
                fieldDump[f.name] = fv
            }
            c = c.superclass
        }
        info["fields"] = fieldDump
        return info
    }

    private fun summarizeFieldValue(v: Any?): String {
        if (v == null) return "null"
        return when (v) {
            is ByteArray -> "byte[${v.size}]=" + v.take(16).joinToString("") {
                "%02x".format(it.toInt() and 0xff)
            } + if (v.size > 16) "..." else ""
            is IntArray -> "int[${v.size}]=" + v.take(8).joinToString(",")
            is Number -> {
                // Show Int values both as decimal and hex (since fid's are typically hex).
                if (v is Int) "${v} (0x${java.lang.String.format("%08X", v)})"
                else v.toString()
            }
            is Boolean, is Char -> v.toString()
            is String -> "\"${v.take(80)}\""
            else -> "<${v.javaClass.simpleName}>"
        }
    }

    /**
     * Atomically extract accumulated diagnostic entries and clear internal
     * state. Returned map is `targetKey -> List<Map>` ready for JSON
     * serialization. Called by LiveMonitorService after first chunk window
     * — second call returns empty map.
     */
    fun takeDiagnostics(): Map<String, List<Map<String, Any?>>> {
        val out = mutableMapOf<String, List<Map<String, Any?>>>()
        // Snapshot keys, then drain each list. Concurrent additions racing
        // with this drain will be lost — acceptable since we expect this
        // call to happen after the diagnostic cap is already reached.
        for ((key, list) in diagEntries) {
            val copy = synchronized(list) { ArrayList(list).also { list.clear() } }
            if (copy.isNotEmpty()) out[key] = copy
        }
        return out
    }

    companion object {
        private const val TAG = "LiveTelemetrySubscr"
        /** Diagnostic dump caps at this many callbacks per target. */
        const val DIAG_LIMIT_PER_TARGET = 10
    }
}
