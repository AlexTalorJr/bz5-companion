package com.bz5companion.bz5_companion

import android.content.Context
import java.lang.reflect.InvocationTargetException

/**
 * Direct HAL probing through reflection on `android.hardware.bydauto.*`
 * device classes — a parallel path to ICarPropertyService.
 *
 * ## Why
 *
 * Field test on carserver 2.1.0-alpha10 (BZ5, Toyota launcher) showed
 * that `ContentResolver.query(content://CarServiceProvider, [FQCN])`
 * returns null even though the provider resolves and the bind
 * permission is granted. The most likely cause is that BinderProvider
 * silently swallows an internal failure (Class.forName, Spi.getService,
 * etc.) and returns null without a logcat trail.
 *
 * Meanwhile, the same firmware *does* let us call
 * `BYDAutoBodyworkDevice.getInstance(ctx)` and reach the deep
 * `getDataFlag()` permission check. That is — the HAL device factories
 * are accessible and methods on them dispatch correctly through to the
 * framework's internal IPC. They just gate on per-domain
 * `BYDAUTO_*_GET` / `_COMMON` permissions.
 *
 * Strategy: for every domain whose `_COMMON` permission is already
 * granted by the OS, we should be able to call `dev.get(int[], Class)`
 * directly — bypassing CarServiceProvider entirely. Some domains may
 * also turn out to be single-tier (only `_COMMON`, no second `_GET`
 * layer) — those would just work. The Bodywork case (two layers) is
 * not necessarily the rule.
 *
 * ## Probing structure
 *
 * For each candidate `BYDAutoXxxDevice` class:
 *
 *   1. Does `Class.forName` succeed? (i.e. is the class on the
 *      classpath?)
 *   2. Does `getInstance(Context)` return non-null? (i.e. is the
 *      framework happy to construct the singleton — equivalent to
 *      passing the *_COMMON permission check on getInstance).
 *   3. What methods does the class expose? (We list them so we can
 *      learn convenience getters like `getMcuStatus()`,
 *      `getAutoType()`, `getSOC()` if they exist on this firmware.)
 *   4. Does the generic `.get(int[], Class)` method exist? Most
 *      `AbsBYDAutoDevice` subclasses have it; absence is a strong
 *      hint the class was renamed or refactored on this firmware.
 *
 * Steps 1-3 are cheap and never trigger permission denial — they're
 * pure reflection over classloader state. Step 4 (and any actual
 * `.get()` call) will hit the runtime permission check.
 *
 * ## Domain inventory
 *
 * We probe the 8 highest-priority domains for telemetry. Ordinal
 * numbers come from `BydAutoDeviceType` enum (see RECON §5). Class
 * package follows the convention
 * `android.hardware.bydauto.<lowercase_domain>.BYDAuto<Domain>Device`.
 */
object BydHalProbe {

    private const val TAG = "BydHalProbe"

    data class HalDomain(
        val ordinal: Int,
        val name: String,
        val className: String,
        val commonPermission: String,
        val getPermission: String,
    )

    /**
     * The domains we care about. Order is meaningful — the UI surfaces
     * results in this order, putting the ones most relevant to the OBD
     * replacement use case first.
     */
    val DOMAINS: List<HalDomain> = listOf(
        HalDomain(18, "ENERGY",
            "android.hardware.bydauto.energy.BYDAutoEnergyDevice",
            "android.permission.BYDAUTO_ENERGY_COMMON",
            "android.permission.BYDAUTO_ENERGY_GET"),
        HalDomain(4,  "CHARGING",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            "android.permission.BYDAUTO_CHARGING_COMMON",
            "android.permission.BYDAUTO_CHARGING_GET"),
        HalDomain(8,  "SPEED",
            "android.hardware.bydauto.speed.BYDAutoSpeedDevice",
            "android.permission.BYDAUTO_SPEED_COMMON",
            "android.permission.BYDAUTO_SPEED_GET"),
        HalDomain(5,  "GEARBOX",
            "android.hardware.bydauto.gearbox.BYDAutoGearboxDevice",
            "android.permission.BYDAUTO_GEARBOX_COMMON",
            "android.permission.BYDAUTO_GEARBOX_GET"),
        HalDomain(22, "STATISTIC",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            "android.permission.BYDAUTO_STATISTIC_COMMON",
            "android.permission.BYDAUTO_STATISTIC_GET"),
        HalDomain(33, "TYRE",
            "android.hardware.bydauto.tyre.BYDAutoTyreDevice",
            "android.permission.BYDAUTO_TYRE_COMMON",
            "android.permission.BYDAUTO_TYRE_GET"),
        HalDomain(3,  "INSTRUMENT",
            "android.hardware.bydauto.instrument.BYDAutoInstrumentDevice",
            "android.permission.BYDAUTO_INSTRUMENT_COMMON",
            "android.permission.BYDAUTO_INSTRUMENT_GET"),
        HalDomain(0,  "POWER",
            "android.hardware.bydauto.power.BYDAutoPowerDevice",
            "android.permission.BYDAUTO_POWER_COMMON",
            "android.permission.BYDAUTO_POWER_GET"),
        // Bodywork (VIN) — already covered by BydVinDetector but probed
        // here too so the diagnostic dump is self-contained.
        HalDomain(2, "BODYWORK",
            "android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice",
            "android.permission.BYDAUTO_BODYWORK_COMMON",
            "android.permission.BYDAUTO_BODYWORK_GET"),
        // Vehicle data — raw CAN frame stream, may not be available on
        // user builds.
        HalDomain(42, "VEHICLE_DATA",
            "android.hardware.bydauto.vehicledata.BYDAutoVehicleDataDevice",
            "android.permission.BYDAUTO_VEHICLE_DATA_COMMON",
            "android.permission.BYDAUTO_VEHICLE_DATA_GET"),
    )

    /**
     * Probe every known HAL domain for class availability, getInstance
     * reachability and exposed method names. No actual `.get()` calls
     * are made — we just inspect the class via reflection.
     *
     * Returns one map per domain with shape:
     *
     *   name            : "ENERGY"
     *   ordinal         : 18
     *   className       : "android.hardware.bydauto.energy.BYDAutoEnergyDevice"
     *   classLoaded     : true|false
     *   classError      : null | "ClassNotFoundException: ..."
     *   getInstanceOk   : true|false
     *   getInstanceErr  : null | "SecurityException: BYDAUTO_..."
     *   hasGenericGet   : true|false   // does dev.get(int[], Class) exist
     *   methodsPublic   : ["getInstance", "registerListener", ...] up to 40
     *   commonGranted   : true|false
     *   getGranted      : true|false
     */
    fun probeAll(ctx: Context): List<Map<String, Any?>> {
        return DOMAINS.map { probeOne(ctx, it) }
    }

    fun probeOne(ctx: Context, dom: HalDomain): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "name"           to dom.name,
            "ordinal"        to dom.ordinal,
            "className"      to dom.className,
            "commonGranted"  to (ctx.checkSelfPermission(dom.commonPermission)
                == android.content.pm.PackageManager.PERMISSION_GRANTED),
            "getGranted"     to (ctx.checkSelfPermission(dom.getPermission)
                == android.content.pm.PackageManager.PERMISSION_GRANTED),
        )

        val cls = try {
            Class.forName(dom.className)
        } catch (t: Throwable) {
            out["classLoaded"] = false
            out["classError"]  = "${t.javaClass.simpleName}: ${t.message}"
            return out
        }
        out["classLoaded"] = true
        out["classError"]  = null

        // Inventory public methods (declared on this class plus inherited).
        // Cap at 40 to keep dumps readable.
        out["methodsPublic"] = try {
            cls.methods.asSequence()
                .map { m ->
                    val args = m.parameterTypes.joinToString(",") { it.simpleName }
                    "${m.name}($args):${m.returnType.simpleName}"
                }
                .distinct()
                .take(40)
                .toList()
        } catch (_: Throwable) { emptyList<String>() }

        // The generic .get(int[], Class) probe — does the method exist?
        // We DO NOT invoke it here (that would burn a permission check
        // and possibly log noise); we just look up the signature.
        out["hasGenericGet"] = try {
            cls.getMethod("get", IntArray::class.java, Class::class.java)
            true
        } catch (_: Throwable) { false }

        // Try getInstance(Context) — this is the one that throws on
        // permission denial in v0.1.26+14 field test.
        try {
            val getInstance = cls.getMethod("getInstance", Context::class.java)
            val dev = getInstance.invoke(null, ctx)
            if (dev == null) {
                out["getInstanceOk"]  = false
                out["getInstanceErr"] = "returned null"
            } else {
                out["getInstanceOk"]  = true
                out["getInstanceErr"] = null
                // Memorize for later .get() calls without re-doing the cost.
                instanceCache[dom.name] = dev
            }
        } catch (e: InvocationTargetException) {
            val cause = e.targetException ?: e.cause
            out["getInstanceOk"]  = false
            out["getInstanceErr"] = cause?.let {
                "${it.javaClass.simpleName}: ${it.message?.take(180)}"
            } ?: "InvocationTargetException with null cause"
        } catch (t: Throwable) {
            out["getInstanceOk"]  = false
            out["getInstanceErr"] = "${t.javaClass.simpleName}: ${t.message?.take(180)}"
        }

        return out
    }

    /**
     * Call `dev.get(featureIds, BYDAutoEventValue.class)` on the named
     * domain. Returns a decoded value map or an error description.
     *
     * Result shape (success):
     *   ok        : true
     *   domain    : "ENERGY"
     *   featureIds: [0x99002B0A]
     *   typeHint  : "int" | "long" | "float" | "double" | "bytes" | "string"
     *   value     : decoded value (Dart-compatible)
     *   rawClass  : "android.hardware.bydauto.event.BYDAutoEventValue"
     *
     * Result shape (failure):
     *   ok        : false
     *   domain    : "ENERGY"
     *   error     : "SecurityException: ..."
     *   errorClass: "SecurityException"
     */
    fun halGet(ctx: Context, domainName: String, featureIds: IntArray): Map<String, Any?> {
        val dom = DOMAINS.firstOrNull { it.name == domainName }
            ?: return mapOf(
                "ok" to false,
                "domain" to domainName,
                "error" to "unknown domain '$domainName'",
                "errorClass" to "IllegalArgumentException",
            )

        // Resolve/load the device on demand. We avoid the instance
        // cache for first-time access so the caller gets fresh
        // SecurityException visibility — caching a half-broken instance
        // would silently swallow the diagnostic value.
        val dev: Any = instanceCache[dom.name] ?: run {
            val cls = try { Class.forName(dom.className) } catch (t: Throwable) {
                return mapOf(
                    "ok" to false, "domain" to dom.name,
                    "error" to "class not loaded: ${t.message}",
                    "errorClass" to t.javaClass.simpleName,
                )
            }
            try {
                val inst = cls.getMethod("getInstance", Context::class.java)
                    .invoke(null, ctx)
                if (inst == null) {
                    return mapOf(
                        "ok" to false, "domain" to dom.name,
                        "error" to "getInstance returned null",
                        "errorClass" to "NullPointerException",
                    )
                }
                instanceCache[dom.name] = inst
                inst
            } catch (e: InvocationTargetException) {
                val c = e.targetException ?: e.cause
                return mapOf(
                    "ok" to false, "domain" to dom.name,
                    "error" to "getInstance failed: ${c?.javaClass?.simpleName}: ${c?.message?.take(220)}",
                    "errorClass" to (c?.javaClass?.simpleName ?: "InvocationTargetException"),
                )
            } catch (t: Throwable) {
                return mapOf(
                    "ok" to false, "domain" to dom.name,
                    "error" to "getInstance threw: ${t.javaClass.simpleName}: ${t.message?.take(220)}",
                    "errorClass" to t.javaClass.simpleName,
                )
            }
        }

        // Now call .get(int[], Class).
        // Class to pass: BYDAutoEventValue. We need the actual class
        // object — try both common locations.
        val eventCls = tryLoadEventValueClass()
            ?: return mapOf(
                "ok" to false, "domain" to dom.name,
                "error" to "BYDAutoEventValue class not found on this firmware",
                "errorClass" to "ClassNotFoundException",
            )

        val getMethod = try {
            dev.javaClass.getMethod("get", IntArray::class.java, Class::class.java)
        } catch (_: NoSuchMethodException) {
            return mapOf(
                "ok" to false, "domain" to dom.name,
                "error" to "device has no .get(int[], Class) — try the per-domain convenience methods listed in methodsPublic",
                "errorClass" to "NoSuchMethodException",
            )
        } catch (t: Throwable) {
            return mapOf(
                "ok" to false, "domain" to dom.name,
                "error" to "${t.javaClass.simpleName}: ${t.message?.take(220)}",
                "errorClass" to t.javaClass.simpleName,
            )
        }

        val raw: Any? = try {
            getMethod.invoke(dev, featureIds, eventCls)
        } catch (e: InvocationTargetException) {
            val c = e.targetException ?: e.cause
            return mapOf(
                "ok" to false, "domain" to dom.name,
                "featureIds" to featureIds.toList(),
                "error" to "get() threw: ${c?.javaClass?.simpleName}: ${c?.message?.take(260)}",
                "errorClass" to (c?.javaClass?.simpleName ?: "InvocationTargetException"),
            )
        } catch (t: Throwable) {
            return mapOf(
                "ok" to false, "domain" to dom.name,
                "featureIds" to featureIds.toList(),
                "error" to "${t.javaClass.simpleName}: ${t.message?.take(260)}",
                "errorClass" to t.javaClass.simpleName,
            )
        }

        if (raw == null) {
            return mapOf(
                "ok" to false, "domain" to dom.name,
                "featureIds" to featureIds.toList(),
                "error" to "get() returned null (likely feature ID not registered for this domain)",
                "errorClass" to "NullPointerException",
            )
        }

        val decoded = BydReflection.decodeEventValue(raw)
        return mapOf(
            "ok"         to true,
            "domain"     to dom.name,
            "featureIds" to featureIds.toList(),
            "typeHint"   to decoded.typeHint,
            "value"      to decoded.value,
            "rawClass"   to raw.javaClass.name,
        )
    }

    /**
     * Try the common locations for BYDAutoEventValue. The class moved
     * between framework versions (older was in `.event`, newer in
     * `.BYDAutoEventValue` at top-level, third-party builds may
     * inline it elsewhere).
     */
    private fun tryLoadEventValueClass(): Class<*>? {
        for (n in EVENT_VALUE_CANDIDATES) {
            try { return Class.forName(n) } catch (_: Throwable) { /* keep trying */ }
        }
        return null
    }

    private val EVENT_VALUE_CANDIDATES = listOf(
        "android.hardware.bydauto.event.BYDAutoEventValue",
        "android.hardware.bydauto.BYDAutoEventValue",
        "android.hardware.bydauto.common.BYDAutoEventValue",
        "android.hardware.bydauto.value.BYDAutoEventValue",
    )

    /**
     * Per-process cache of instantiated HAL devices. Cleared on plugin
     * detach (the plugin's onDetachedFromEngine is wired to call
     * [clearCache]).
     */
    private val instanceCache = java.util.concurrent.ConcurrentHashMap<String, Any>()

    fun clearCache() { instanceCache.clear() }
}
