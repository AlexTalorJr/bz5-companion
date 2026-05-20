package com.bz5companion.bz5_companion

import android.content.Context
import android.util.Log

/**
 * Reflective wrapper around `android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice`.
 *
 * On a real BYD head unit, this class lives in /system/framework/ and is
 * loaded from the platform's boot classpath. On a phone or emulator the
 * class isn't present, so `Class.forName` throws and we treat the device
 * as "not a head unit" — the app should then fall back to BLE+ELM mode.
 *
 * Two VIN-fetching methods exist on the system class:
 *
 *   String getRealAutoVIN()    // fresh from CAN; ~10-50ms on a warm bus
 *   String getAutoVIN()        // cached value the framework keeps in RAM
 *
 * `getRealAutoVIN()` triggers a UDS-style request on the body CAN — it
 * costs a frame round-trip but is authoritative. `getAutoVIN()` returns
 * whatever the framework cached at boot, which is fine for identity
 * checks but can be empty during the first few seconds after IGN-on.
 *
 * Caching policy here: we keep both the last-fresh and last-cached VIN
 * in memory and only re-call the framework when `fresh=true` is asked
 * for explicitly. Repeated `isFrameworkPresent()` calls are free —
 * reflection lookup result is memoized.
 */
class BydVinDetector {

    @Volatile private var lastVinFresh: String? = null
    @Volatile private var lastVinCached: String? = null

    // Tri-state memo: null = "haven't looked yet", true/false = result.
    @Volatile private var frameworkPresentMemo: Boolean? = null

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
     */
    fun getVin(context: Context, fresh: Boolean): String? {
        if (!isFrameworkPresent()) return null

        // Quick path: serve in-memory cache when fresh isn't required.
        if (!fresh && lastVinCached != null) return lastVinCached

        return try {
            val cls = Class.forName(CLS_BODYWORK_DEVICE)
            val getInstance = cls.getMethod("getInstance", Context::class.java)
            val dev = getInstance.invoke(null, context)
                ?: throw IllegalStateException("BYDAutoBodyworkDevice.getInstance returned null")

            val methodName = if (fresh) "getRealAutoVIN" else "getAutoVIN"
            // Some framework builds may not expose the cached variant on
            // older devices. Fall back to the other method if NoSuchMethod.
            val method = try {
                cls.getMethod(methodName)
            } catch (_: NoSuchMethodException) {
                cls.getMethod(if (fresh) "getAutoVIN" else "getRealAutoVIN")
            }

            val vin = method.invoke(dev) as? String
            // Validate shape — VIN is exactly 17 alphanumeric, no I/O/Q.
            if (vin != null && vin.length == 17 && vin.matches(VIN_REGEX)) {
                if (fresh) lastVinFresh = vin
                lastVinCached = vin
                vin
            } else {
                // Framework returned empty/garbage — treat as unavailable
                // but don't poison the cache.
                Log.w(TAG, "VIN read returned invalid value: '$vin'")
                null
            }
        } catch (t: Throwable) {
            Log.w(TAG, "VIN read failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
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
            Log.w(TAG, "getAutoType failed: ${t.message}")
            null
        }
    }

    companion object {
        private const val TAG = "BydVinDetector"
        private const val CLS_BODYWORK_DEVICE =
            "android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice"
        // VIN: 17 chars, no I, O, Q
        private val VIN_REGEX = Regex("[A-HJ-NPR-Z0-9]{17}")
    }
}
