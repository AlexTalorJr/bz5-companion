// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/ReflectionCache.kt
// Synced: 2026-06-10 (recon v0.10.53, commit d37fbbc)
// SHA256: 9cf45133f4f36937c399265d7c95fb866757c56336468a71cdf32c2752a38625
package com.bz5companion.bz5_companion.hal

import java.lang.reflect.Field
import java.util.concurrent.ConcurrentHashMap

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/ReflectionCache.kt
// Owner: bz5_recon (patch 068)
// Sync method: copy-paste with checksum header.
//
// Hot-path field accessor cache for BYDAutoEvent / BYDAutoBigDataEvent / etc.
// In patch 067, every callback walked the entire class chain and read all
// declared fields via describeArg() — measured ~150 µs per BigData callback,
// adding up to ~450 ms CPU per 30s window at 120 Hz × 25 fields. With the
// cache, per-callback cost drops to ~5 µs (4 cached field reads).

/**
 * Caches per-class `Field` references for the four payload fields we care
 * about. First lookup walks the class chain; subsequent lookups are O(1).
 *
 * Thread-safe — ConcurrentHashMap, Fields are immutable once accessible=true.
 */
object ReflectionCache {

    /** Names searched up the class chain for each logical field. The
     *  framework's BYDAutoEvent hierarchy stores them under `mDeviceSubType`
     *  / `mIntValue` / `mDoubleValue` / `mBufData` (verified against
     *  patch 047 describeArg dumps). */
    private const val SUBTYPE_FIELD = "mDeviceSubType"
    private const val INT_FIELD     = "mIntValue"
    private const val DOUBLE_FIELD  = "mDoubleValue"
    private const val BUF_FIELD     = "mBufData"

    /** key: event Class, value: AccessorBundle (nullable fields if not on this class) */
    private val cache = ConcurrentHashMap<Class<*>, AccessorBundle>()

    data class AccessorBundle(
        val subtype: Field?,   // nullable in case event class lacks it
        val intVal:  Field?,
        val dblVal:  Field?,
        val bufVal:  Field?
    )

    fun accessors(cls: Class<*>): AccessorBundle =
        cache.computeIfAbsent(cls) { build(it) }

    private fun build(cls: Class<*>): AccessorBundle {
        var subtype: Field? = null
        var intVal:  Field? = null
        var dblVal:  Field? = null
        var bufVal:  Field? = null

        var c: Class<*>? = cls
        while (c != null && c != Any::class.java) {
            val declared = try { c.declaredFields } catch (_: Throwable) { emptyArray() }
            for (f in declared) {
                if (java.lang.reflect.Modifier.isStatic(f.modifiers)) continue
                when (f.name) {
                    SUBTYPE_FIELD -> if (subtype == null) { f.isAccessible = true; subtype = f }
                    INT_FIELD     -> if (intVal  == null) { f.isAccessible = true; intVal  = f }
                    DOUBLE_FIELD  -> if (dblVal  == null) { f.isAccessible = true; dblVal  = f }
                    BUF_FIELD     -> if (bufVal  == null) { f.isAccessible = true; bufVal  = f }
                }
            }
            c = c.superclass
        }
        return AccessorBundle(subtype, intVal, dblVal, bufVal)
    }

    /**
     * Read all four payload fields from an event object via cached accessors.
     * Returns nulls for fields not present on the class or read errors.
     */
    data class EventPayload(
        val subtype: Long,
        val intValue: Int?,
        val doubleValue: Double?,
        val bufData: ByteArray?
    )

    /**
     * Extract payload from an event. `subtype` defaults to 0L if mDeviceSubType
     * is absent — caller should treat 0 as "no subtype known" (none of the
     * real BZ5 fids equal 0).
     */
    fun extract(event: Any): EventPayload {
        val ab = accessors(event.javaClass)
        val subtypeRaw = try {
            ab.subtype?.get(event)
        } catch (_: Throwable) { null }
        // mDeviceSubType is declared as int but contains unsigned u32 values
        // (e.g. 0x99000020). Widen to Long via `& 0xFFFFFFFFL` so callers get
        // a non-negative key for hex stringification.
        val subtype: Long = when (subtypeRaw) {
            is Int  -> subtypeRaw.toLong() and 0xFFFFFFFFL
            is Long -> subtypeRaw and 0xFFFFFFFFL
            else    -> 0L
        }
        val intValue = try {
            when (val v = ab.intVal?.get(event)) {
                is Int -> v
                is Number -> v.toInt()
                else -> null
            }
        } catch (_: Throwable) { null }
        val doubleValue = try {
            when (val v = ab.dblVal?.get(event)) {
                is Double -> v
                is Number -> v.toDouble()
                else -> null
            }
        } catch (_: Throwable) { null }
        val bufData = try {
            ab.bufVal?.get(event) as? ByteArray
        } catch (_: Throwable) { null }
        return EventPayload(subtype, intValue, doubleValue, bufData)
    }
}
