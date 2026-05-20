package com.bz5companion.bz5_companion

import android.util.Log
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.util.Collections

/**
 * Reflection helpers shared by the property client and any other code
 * that talks to `android.hardware.bydauto.*`.
 *
 * Caches resolved Class / Method / Field handles per JVM. Reflection
 * lookups are cheap once but expensive when called per-event, and the
 * property client touches BYDAutoEventValue on every realtime update —
 * so this caching matters.
 *
 * Every method here is null-safe: failures degrade to null/false rather
 * than throwing, so we never propagate a NoSuchMethodError up through
 * the event loop.
 */
object BydReflection {

    private const val TAG = "BydReflection"

    // Synchronized HashMaps because we need to store null values
    // (to negatively-cache "looked up, doesn't exist"). ConcurrentHashMap
    // forbids null values, so we use synchronizedMap(HashMap) instead.
    // Throughput is fine — these maps are read-mostly after warmup.
    private val classCache  = Collections.synchronizedMap(HashMap<String, Class<*>?>())
    private val methodCache = Collections.synchronizedMap(HashMap<String, Method?>())
    private val fieldCache  = Collections.synchronizedMap(HashMap<String, Field?>())

    /** Load a class by name with negative caching. Returns null if absent. */
    fun cls(name: String): Class<*>? {
        // Distinguish "haven't looked yet" (key absent) from
        // "looked and found nothing" (key present, value null).
        if (classCache.containsKey(name)) return classCache[name]
        val c = try {
            Class.forName(name)
        } catch (_: ClassNotFoundException) {
            null
        } catch (t: Throwable) {
            Log.w(TAG, "cls('$name') failed: ${t.javaClass.simpleName}: ${t.message}")
            null
        }
        classCache[name] = c
        return c
    }

    /** Look up a method by simple signature key, cached. */
    fun method(clazz: Class<*>, name: String, vararg paramTypes: Class<*>): Method? {
        val key = "${clazz.name}#$name(${paramTypes.joinToString(",") { it.name }})"
        if (methodCache.containsKey(key)) return methodCache[key]
        val m = try {
            clazz.getMethod(name, *paramTypes).also { it.isAccessible = true }
        } catch (_: NoSuchMethodException) {
            null
        } catch (t: Throwable) {
            Log.w(TAG, "method('$key') failed: ${t.message}")
            null
        }
        methodCache[key] = m
        return m
    }

    /** Look up a field on a class (including non-public via getDeclaredField). */
    fun field(clazz: Class<*>, name: String): Field? {
        val key = "${clazz.name}#$name"
        if (fieldCache.containsKey(key)) return fieldCache[key]
        // Walk up the inheritance chain — BYDAutoEventValue may inherit
        // from a base class on some firmware variants and fields could
        // live on either side.
        var c: Class<*>? = clazz
        var f: Field? = null
        while (c != null && f == null) {
            f = try {
                c.getDeclaredField(name).also { it.isAccessible = true }
            } catch (_: NoSuchFieldException) {
                null
            } catch (t: Throwable) {
                Log.w(TAG, "field('$key') failed: ${t.message}")
                null
            }
            c = c.superclass
        }
        fieldCache[key] = f
        return f
    }

    /**
     * Extract a usable Dart-compatible value + a coarse type hint from
     * a BYDAutoEventValue instance. Returns DecodedValue.empty when the
     * value object is null or has no useful fields.
     *
     * BYDAutoEventValue fields we know about:
     *   - intValue (I) — scalar int
     *   - bufferDataValue ([B) — byte array
     *
     * Other fields likely exist (floatValue, longValue, stringValue)
     * but were not observed in carserver.apk's usage. The decoder
     * probes for them defensively so newer firmware that adds fields
     * keeps working.
     */
    fun decodeEventValue(value: Any?): DecodedValue {
        if (value == null) return DecodedValue.empty()
        val cls = value.javaClass

        // Probe known and likely fields. First successful non-default
        // read wins — the caller can examine `typeHint` to tell which
        // path was taken.
        // Order matters: we try the most specific first.
        listOf("stringValue" to "string",
               "longValue"   to "long",
               "intValue"    to "int",
               "floatValue"  to "float",
               "doubleValue" to "double").forEach { (fname, hint) ->
            val f = field(cls, fname) ?: return@forEach
            val raw = try { f.get(value) } catch (_: Throwable) { null } ?: return@forEach
            // For numeric scalars, also accept zero as a real value — we
            // can't distinguish "unset" from "actually zero". The first
            // matching field is what carserver populates for this event.
            return DecodedValue(raw, hint)
        }

        // Buffer payload (byte[]). Return as List<Int> for cleaner
        // Flutter marshaling (avoids byte-sign confusion across the
        // platform channel).
        field(cls, "bufferDataValue")?.let { f ->
            val raw = try { f.get(value) } catch (_: Throwable) { null }
            if (raw is ByteArray && raw.isNotEmpty()) {
                return DecodedValue(raw.map { it.toInt() and 0xFF }, "bytes")
            }
        }

        return DecodedValue.empty()
    }

    data class DecodedValue(val value: Any?, val typeHint: String) {
        companion object {
            fun empty() = DecodedValue(null, "empty")
        }
    }
}
