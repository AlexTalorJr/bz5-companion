package com.bz5companion.bz5_companion

import android.content.Context

/**
 * Reflective wrapper around BYD framework classes that expose the
 * vehicle VIN.
 *
 * On a real BYD head unit the relevant classes live in
 * /system/framework/ and are loaded from the platform's boot classpath.
 * On a phone or emulator the classes aren't present, so reflection
 * throws and we treat the device as "not a head unit" — the app then
 * falls back to BLE+ELM mode.
 *
 * Two VIN-fetching methods are *expected* on BYDAutoBodyworkDevice:
 *
 *   String getRealAutoVIN()    // fresh from CAN; ~10-50ms on a warm bus
 *   String getAutoVIN()        // cached value the framework keeps in RAM
 *
 * `getRealAutoVIN()` triggers a UDS-style request on the body CAN — it
 * costs a frame round-trip but is authoritative. `getAutoVIN()` returns
 * whatever the framework cached at boot, which is fine for identity
 * checks but can be empty during the first seconds after IGN-on.
 *
 * v0.1.26+14: empirical field test on a Toyota BZ5 head unit
 * (TOYOTA AUTO/TOYOTA SPACE, carserver 2.1.0-alpha10) showed:
 *
 *   - Class.forName("...BYDAutoBodyworkDevice") succeeds (framework
 *     present).
 *   - Method.invoke for both getRealAutoVIN and getAutoVIN throws
 *     InvocationTargetException with cause==null (target threw an
 *     uncaught Throwable but no chained cause was preserved).
 *
 * The previous logger printed only `t.javaClass.simpleName + message`
 * which collapsed to `InvocationTargetException: null` for every
 * attempt — useless for diagnosis. The fix in this version:
 *
 *   1. Unwrap InvocationTargetException's target (it lives in
 *      `targetException`, not `cause`) and log its class+message+top
 *      6 stack frames.
 *   2. Walk the full cause chain so wrapped chains print fully.
 *   3. Try multiple method names and multiple classes — BZ5 firmware
 *      may have renamed methods, or VIN may live on a sibling class
 *      such as BYDAutoVersionDevice. Each attempt is logged with the
 *      exact reflection path tried.
 *
 * The reason we DON'T fall back to ICarPropertyService.getProperty
 * here: the property side needs a featureID we don't yet know, and we
 * haven't calibrated the catalog. Until then, this reflection path is
 * the only way to get VIN.
 */
class BydVinDetector {

    @Volatile private var lastVinFresh: String? = null
    @Volatile private var lastVinCached: String? = null

    // Tri-state memo: null = "haven't looked yet", true/false = result.
    @Volatile private var frameworkPresentMemo: Boolean? = null

    /**
     * v0.1.29+107: cheapest possible VIN read for platform identity — returns
     * whatever VIN we already have in memory (fresh preferred, else cached),
     * WITHOUT triggering any reflection or CAN round-trip. Never throws, never
     * blocks. Used by DiLinkProfiles only as a WEAK match signal: on BZ5 the
     * VIN reflection is known to throw (so this is usually null there), which
     * is fine — fingerprint + SDK carry the platform match.
     */
    fun lastKnownVin(): String? = lastVinFresh ?: lastVinCached

    /**
     * Cheap probe — does the BYD framework class exist on this device?
     * Result is cached across the process lifetime.
     */
    fun isFrameworkPresent(): Boolean {
        frameworkPresentMemo?.let { return it }
        val r = try {
            Class.forName(CLS_BODYWORK_DEVICE)
            true
        } catch (_: ClassNotFoundException) {
            false
        } catch (_: Throwable) {
            // Other failures (NoClassDefFoundError on partial system, security
            // exceptions, ...) we still treat as "not available" rather than
            // crashing the app.
            false
        }
        frameworkPresentMemo = r
        return r
    }

    /**
     * Returns the VIN string (17 chars) or null if unavailable.
     *
     * @param fresh true → bypass cache and force CAN read via getRealAutoVIN()
     *              false → prefer cached value from framework's getAutoVIN()
     *
     * On a phone or non-BYD device, returns null without throwing.
     *
     * v0.1.26+14: now tries multiple method names across two candidate
     * classes (Bodywork + Version). Each failure is fully unwrapped and
     * logged so we can see the target's real exception class and
     * message — not just an opaque "InvocationTargetException: null".
     */
    fun getVin(context: Context, fresh: Boolean): String? {
        if (!isFrameworkPresent()) return null

        // Quick path: serve in-memory cache when fresh isn't required.
        if (!fresh && lastVinCached != null) return lastVinCached

        // Ordered list of attempts: (className, methodName, freshness).
        // Order matters — we prefer the requested freshness, then fall
        // back. The first non-null valid VIN wins.
        val attempts: List<Triple<String, String, Boolean>> = if (fresh) {
            listOf(
                Triple(CLS_BODYWORK_DEVICE, "getRealAutoVIN", true),
                Triple(CLS_BODYWORK_DEVICE, "getAutoVIN", false),
                Triple(CLS_BODYWORK_DEVICE, "getVIN", false),
                Triple(CLS_BODYWORK_DEVICE, "getVinCode", false),
                Triple(CLS_VERSION_DEVICE, "getVIN", false),
                Triple(CLS_VERSION_DEVICE, "getVin", false),
            )
        } else {
            listOf(
                Triple(CLS_BODYWORK_DEVICE, "getAutoVIN", false),
                Triple(CLS_BODYWORK_DEVICE, "getVIN", false),
                Triple(CLS_BODYWORK_DEVICE, "getVinCode", false),
                Triple(CLS_BODYWORK_DEVICE, "getRealAutoVIN", true),
                Triple(CLS_VERSION_DEVICE, "getVIN", false),
                Triple(CLS_VERSION_DEVICE, "getVin", false),
            )
        }

        val failures = mutableListOf<String>()
        for ((cls, method, isFresh) in attempts) {
            val vin = tryOne(context, cls, method, failures)
            if (vin != null) {
                if (isFresh) lastVinFresh = vin
                lastVinCached = vin
                BydLogger.i(TAG, "VIN obtained via $cls.$method: $vin")
                return vin
            }
        }

        // All attempts failed. Log a consolidated summary so the user's
        // "Copy diagnostics" output explains the full picture in one
        // go, not 6 separate "VIN read failed" lines.
        BydLogger.w(
            TAG,
            "VIN read failed across ${attempts.size} method(s):\n" +
                failures.joinToString("\n")
        )
        return null
    }

    /**
     * Single reflection attempt with full root-cause unwrapping. Returns
     * the valid VIN string on success, null on any failure. Appends a
     * diagnostic line to [failures] on failure (which the caller will
     * log as a single consolidated message).
     */
    private fun tryOne(
        context: Context,
        className: String,
        methodName: String,
        failures: MutableList<String>,
    ): String? {
        return try {
            val cls = Class.forName(className)
            val getInstance = cls.getMethod("getInstance", Context::class.java)
            val dev = getInstance.invoke(null, context)
                ?: run {
                    failures += "  $className.$methodName: getInstance returned null"
                    return null
                }

            val method = cls.getMethod(methodName)
            val vin = method.invoke(dev) as? String
            // Validate shape — VIN is exactly 17 alphanumeric, no I/O/Q.
            if (vin != null && vin.length == 17 && vin.matches(VIN_REGEX)) {
                vin
            } else {
                failures += "  $className.$methodName: invalid response '${vin ?: "null"}'"
                null
            }
        } catch (e: NoSuchMethodException) {
            failures += "  $className.$methodName: NoSuchMethod (firmware has no such method)"
            null
        } catch (e: ClassNotFoundException) {
            failures += "  $className.$methodName: class not present"
            null
        } catch (e: java.lang.reflect.InvocationTargetException) {
            // This is the case the field test hit. The target of the
            // reflective call threw, and InvocationTargetException wraps
            // it in `.targetException` (Throwable.cause may be null
            // depending on JVM mood). We unwrap manually.
            val target = e.targetException ?: e.cause
            val summary = if (target == null) {
                "${e.javaClass.simpleName}: no targetException (impossible but happens — likely security manager null'd it)"
            } else {
                summarizeCauseChain(target)
            }
            failures += "  $className.$methodName: InvocationTargetException\n    $summary"
            null
        } catch (t: Throwable) {
            failures += "  $className.$methodName: ${t.javaClass.simpleName}: ${t.message}"
            null
        }
    }

    /**
     * Builds a multi-line summary of the entire cause chain with up to
     * 4 stack frames per level. This is what we wanted in v0.1.27 but
     * didn't have — the field log showed "InvocationTargetException:
     * null" with no way to know what the actual problem was.
     */
    private fun summarizeCauseChain(top: Throwable): String {
        val sb = StringBuilder()
        var current: Throwable? = top
        var level = 0
        while (current != null && level < 5) {
            val prefix = if (level == 0) "" else "    caused by → "
            sb.append(prefix)
            sb.append(current.javaClass.name)
            current.message?.let { sb.append(": ").append(it) }
            sb.append("\n")
            // Up to 4 frames per level.
            val stack = current.stackTrace
            val limit = minOf(stack.size, 4)
            for (i in 0 until limit) {
                sb.append("      at ").append(stack[i]).append("\n")
            }
            if (stack.size > limit) sb.append("      ... +${stack.size - limit} frames\n")
            val next = current.cause
            if (next == null || next === current) break
            current = next
            level++
        }
        return sb.toString().trimEnd()
    }

    /**
     * Probe the framework for the AutoType integer — a numeric model
     * identifier that may help distinguish BZ5 from other BYD variants.
     * Returns null if unavailable.
     */
    fun getAutoType(context: Context): Int? {
        if (!isFrameworkPresent()) return null
        return try {
            val cls = Class.forName(CLS_BODYWORK_DEVICE)
            val dev = cls.getMethod("getInstance", Context::class.java).invoke(null, context)
            (cls.getMethod("getAutoType").invoke(dev) as? Int)
        } catch (t: Throwable) {
            BydLogger.w(TAG, "getAutoType failed: ${t.message}")
            null
        }
    }

    companion object {
        private const val TAG = "BydVinDetector"
        private const val CLS_BODYWORK_DEVICE =
            "android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice"
        private const val CLS_VERSION_DEVICE =
            "android.hardware.bydauto.version.BYDAutoVersionDevice"
        // VIN: 17 chars, no I, O, Q
        private val VIN_REGEX = Regex("[A-HJ-NPR-Z0-9]{17}")
    }
}
