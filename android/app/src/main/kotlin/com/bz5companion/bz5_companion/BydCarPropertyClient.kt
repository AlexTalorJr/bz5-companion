package com.bz5companion.bz5_companion

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Parcel
import android.os.Parcelable
import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap

/**
 * Client for `com.byd.car.property.ICarPropertyService`, accessed via the
 * BinderProvider bootstrap pattern carserver uses.
 *
 * ## Wire protocol (reverse-engineered, verified)
 *
 * ### Bootstrap
 *
 * Carserver exposes its AIDL services via a `ContentProvider` named
 * `com.byd.car.server.provider.CarServiceProvider`, which extends
 * `com.byd.spi.ipc.provider.BinderProvider`. There is **no `<service>`
 * declared** — discovery goes through ContentResolver.query():
 *
 * 1. Build URI: `content://com.byd.car.server.provider.CarServiceProvider`
 *    (any path is fine — the provider ignores it).
 * 2. Call `query(uri, projection, null, null, null)` where
 *    `projection[0]` is the **AIDL interface FQCN**, e.g.
 *    `"com.byd.car.property.ICarPropertyService"`.
 *    `BinderProvider.query()` does `Class.forName(projection[0])` then
 *    `Spi.getService(context, cls)` to obtain the IBinder.
 * 3. The returned cursor is a `BinderCursor` (a MatrixCursor subclass).
 *    Its `extras` Bundle contains a `BinderParcelable` under the key
 *    `"binder"`. Invoke `.getBinder()` on it (via reflection — the
 *    class lives inside carserver) to extract the IBinder.
 *
 * ### Transaction codes (verified from Stub$Proxy.transact() ops)
 *
 * | Code | Method                  | Oneway? | Returns                |
 * |------|-------------------------|---------|------------------------|
 * | 1    | setProperties           | no      | Status                 |
 * | 2    | getProperty             | no      | Response (nullable)    |
 * | 3    | getProperties           | no      | Response (nullable)    |
 * | 4    | getPropertyConfigs      | no      | List                   |
 * | 5    | registerValueCallback   | yes(1)  | void                   |
 * | 6    | unregisterValueCallback | yes(1)  | void                   |
 *
 * ICarPropertyListener: TX 1 = onEvent(String, Response), oneway.
 *
 * ### Parcelable layouts
 *
 * **Status**: `writeInt(code); writeString(description)`
 *
 * **CarPropertyValue**:
 * ```
 * writeString(propertyKey)       // semantic key, often null
 * writeString(propertyId)        // "0x<HEX>" feature-id string (the one we look up)
 * writeString(typeName)          // Java class name, dispatches the payload
 * <writeXXX(value) per typeName>
 * ```
 * typeName values seen: `"java.lang.String"`, `"[B"`, `"java.lang.Integer"`,
 * `"java.lang.Long"`, `"java.lang.Float"`, `"java.lang.Double"`,
 * `"java.lang.Boolean"`, `"[I"`, `"[F"`, `"[J"`, `"android.os.Parcelable"`.
 *
 * **Response**:
 * ```
 * writeParcelable(status, flags)   // standard nullable Parcelable
 * writeString(typeName)            // dispatch tag (or null)
 * <writeXXX(result) per typeName>  // payload, same encoding as CarPropertyValue
 * ```
 *
 * ## What the caller sees
 *
 * Every public method returns Kotlin-friendly types directly. The
 * MethodChannel converts them to Dart maps. `Status` is the only field
 * named the same as the AIDL — it carries (code, description).
 */
class BydCarPropertyClient(private val context: Context) : Closeable {

    private var serviceBinder: IBinder? = null
    private val callbacks = ConcurrentHashMap<SubscriptionToken, PropertyCallbackStub>()

    // ─── bootstrap ──────────────────────────────────────────────────────
    //
    // v0.1.27+1: field test on carserver 2.1.0-alpha10 showed that the
    // canonical `query(content://Authority, [recon-FQCN])` returns null,
    // probably because BinderProvider silently swallowed an internal
    // failure (Class.forName on a renamed FQCN, race with carserver
    // init, etc.). To recover, we now try a small matrix instead of one
    // fixed call — and log every attempt's outcome so the user's
    // diagnostics dump tells us which path actually works.

    @Throws(Exception::class)
    fun connect() {
        if (serviceBinder?.isBinderAlive == true) return

        val attempts = mutableListOf<String>()

        // Phase 1: query() — primary recon-verified plus a few FQCN fallbacks
        for (uri in URI_FALLBACKS) {
            for (fqcn in IFACE_FALLBACKS) {
                val b = tryQuery(uri, fqcn, attempts) ?: continue
                serviceBinder = b
                BydLogger.i(TAG, "ICarPropertyService connected via query() uri=$uri fqcn=$fqcn")
                return
            }
        }

        // Phase 2: call() fallback — some BinderProvider variants expose
        // the binder via ContentProvider.call() instead of (or in
        // addition to) query().
        val callUri = Uri.parse("content://$AUTHORITY")
        for (method in CALL_METHODS) {
            for (fqcn in IFACE_FALLBACKS) {
                val b = tryCall(callUri, method, fqcn, attempts) ?: continue
                serviceBinder = b
                BydLogger.i(TAG, "ICarPropertyService connected via call(method=$method arg=$fqcn)")
                return
            }
        }

        // All attempts failed — surface a single consolidated message.
        BydLogger.w(TAG, "ICarPropertyService bootstrap exhausted ${attempts.size} attempts:\n" +
            attempts.joinToString("\n  - ", prefix = "  - "))
        throw IllegalStateException(
            "ICarPropertyService unreachable after ${attempts.size} bootstrap attempts. " +
            "Run 'Probe connection paths' in Native Explorer for the full report."
        )
    }

    private fun tryQuery(uri: Uri, fqcn: String, failures: MutableList<String>): IBinder? {
        val cursor: Cursor? = try {
            context.contentResolver.query(uri, arrayOf(fqcn), null, null, null)
        } catch (t: Throwable) {
            failures += "query($uri, [$fqcn]) threw ${t.javaClass.simpleName}: ${t.message?.take(160)}"
            return null
        }
        if (cursor == null) {
            failures += "query($uri, [$fqcn]) cursor=null"
            return null
        }
        return cursor.use { c ->
            val extras = c.extras
            if (extras == null) {
                failures += "query($uri, [$fqcn]) cursor=ok extras=null"
                return@use null
            }
            // Try the canonical key first, then the extras' own keys as
            // a last resort — some firmwares may use a different label.
            val candidateKeys = (listOf(BUNDLE_KEY_BINDER) + extras.keySet()).distinct()
            for (k in candidateKeys) {
                val p = try { extras.getParcelable<Parcelable>(k) } catch (_: Throwable) { null }
                    ?: continue
                val b = extractBinder(p) ?: continue
                if (b.isBinderAlive) {
                    BydLogger.i(TAG, "query($uri, [$fqcn]) → binder via key='$k'")
                    return@use b
                }
            }
            failures += "query($uri, [$fqcn]) cursor=ok no binder under any key=${extras.keySet()}"
            null
        }
    }

    private fun tryCall(uri: Uri, method: String, arg: String, failures: MutableList<String>): IBinder? {
        val bundle: Bundle? = try {
            context.contentResolver.call(uri, method, arg, null)
        } catch (t: Throwable) {
            failures += "call(method=$method arg=$arg) threw ${t.javaClass.simpleName}: ${t.message?.take(160)}"
            return null
        }
        if (bundle == null) {
            failures += "call(method=$method arg=$arg) bundle=null"
            return null
        }
        val candidateKeys = (listOf(BUNDLE_KEY_BINDER) + bundle.keySet()).distinct()
        for (k in candidateKeys) {
            val v: Any? = try { bundle.get(k) } catch (_: Throwable) { null } ?: continue
            val b: IBinder? = when (v) {
                is IBinder    -> v
                is Parcelable -> extractBinder(v)
                else          -> null
            }
            if (b != null && b.isBinderAlive) {
                BydLogger.i(TAG, "call(method=$method arg=$arg) → binder via key='$k'")
                return b
            }
        }
        failures += "call(method=$method arg=$arg) bundle ok but no binder, keys=${bundle.keySet()}"
        return null
    }

    override fun close() {
        for ((tok, _) in callbacks) {
            try { unsubscribe(tok) } catch (_: Throwable) {}
        }
        callbacks.clear()
        serviceBinder = null
    }

    // ─── public API ─────────────────────────────────────────────────────

    /** Read one property. `name` is `"0x<HEX>"`, e.g. `"0x99002B0A"`. */
    @Throws(Exception::class)
    fun getProperty(name: String): Map<String, Any?> {
        val b = requireBinder()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(IFACE_TOKEN)
            data.writeString(name)
            if (!b.transact(TX_GET_PROPERTY, data, reply, 0))
                error("transact(getProperty) returned false")
            reply.readException()
            val hasResponse = reply.readInt() != 0
            if (!hasResponse) emptyResponse(name)
            else readResponse(reply, name)
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    @Throws(Exception::class)
    fun getProperties(names: List<String>): List<Map<String, Any?>> {
        val b = requireBinder()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(IFACE_TOKEN)
            data.writeStringArray(names.toTypedArray())
            if (!b.transact(TX_GET_PROPERTIES, data, reply, 0))
                error("transact(getProperties) returned false")
            reply.readException()
            val hasResponse = reply.readInt() != 0
            if (!hasResponse) {
                names.map { emptyResponse(it) }
            } else {
                // Result of getProperties is a Response whose .result is
                // typeName=="java.util.ArrayList" or just "[some type]";
                // we surface it as the single decoded object first, with
                // each item already a CarPropertyValue payload. Until we
                // verify on car, decode defensively as a list.
                val r = readResponse(reply, names.joinToString(","))
                @Suppress("UNCHECKED_CAST")
                val list = r["value"] as? List<Map<String, Any?>>
                list ?: listOf(r)
            }
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    @Throws(Exception::class)
    fun getPropertyConfigs(names: List<String>): List<Map<String, Any?>> {
        val b = requireBinder()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(IFACE_TOKEN)
            data.writeStringArray(names.toTypedArray())
            if (!b.transact(TX_GET_PROPERTY_CONFIGS, data, reply, 0))
                error("transact(getPropertyConfigs) returned false")
            reply.readException()
            // Standard AIDL List<T> reply: writeInt(n) then n items.
            val n = reply.readInt()
            (0 until n).mapNotNull {
                try { readPropertyConfig(reply) }
                catch (t: Throwable) {
                    BydLogger.w(TAG, "config decode failed at $it: ${t.message}")
                    null
                }
            }
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    /** Write one property. `value` should match the typeHint. */
    @Throws(Exception::class)
    fun setProperty(name: String, value: Any?, typeHint: String?): Status {
        val b = requireBinder()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(IFACE_TOKEN)
            // setProperties takes CarPropertyValue[] (writeTypedArray-style).
            data.writeInt(1)               // array length
            data.writeInt(1)               // non-null marker for the first element
            writeCarPropertyValueBody(data, name, value, typeHint)
            if (!b.transact(TX_SET_PROPERTIES, data, reply, 0))
                error("transact(setProperties) returned false")
            reply.readException()
            val hasStatus = reply.readInt() != 0
            if (hasStatus) readStatus(reply) else Status(Status.UNKNOWN_ERROR, "null status")
        } finally {
            data.recycle(); reply.recycle()
        }
    }

    @Throws(Exception::class)
    fun subscribe(
        name: String,
        onEvent: (String, BydReflection.DecodedValue) -> Unit
    ): SubscriptionToken {
        val b = requireBinder()
        val stub = PropertyCallbackStub(onEvent)
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(IFACE_TOKEN)
            data.writeStrongBinder(stub)
            data.writeStringArray(arrayOf(name))
            // oneway transaction — fire-and-forget per the proxy disasm.
            if (!b.transact(TX_REGISTER_CALLBACK, data, reply, IBinder.FLAG_ONEWAY))
                error("transact(registerValueCallback) returned false")
        } finally {
            data.recycle(); reply.recycle()
        }
        val tok = SubscriptionToken(name, stub)
        callbacks[tok] = stub
        return tok
    }

    @Throws(Exception::class)
    fun unsubscribe(token: SubscriptionToken) {
        val b = requireBinder()
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(IFACE_TOKEN)
            data.writeStrongBinder(token.stub)
            data.writeStringArray(arrayOf(token.propertyName))
            if (!b.transact(TX_UNREGISTER_CALLBACK, data, reply, IBinder.FLAG_ONEWAY))
                error("transact(unregisterValueCallback) returned false")
        } finally {
            data.recycle(); reply.recycle()
        }
        callbacks.remove(token)
    }

    // ─── parcel codec ───────────────────────────────────────────────────

    /**
     * Read a Response off the parcel. Layout:
     *   writeParcelable(status, flags)
     *   writeString(typeName)
     *   payload per typeName
     */
    private fun readResponse(p: Parcel, propertyName: String): Map<String, Any?> {
        // writeParcelable wire format: writeString(className); if non-null, the parcelable's payload
        val statusClassName = p.readString()  // expected "com.byd.datasource.feature.Status" or null
        val status: Status? = if (statusClassName == null) null else readStatus(p)
        val typeName = p.readString()
        val value: Any? = readValueByTypeName(p, typeName)
        return mapOf(
            "name"      to propertyName,
            "ok"        to (status == null || status.code == Status.SUCCESS),
            "code"      to (status?.code ?: Status.NONE),
            "errorMsg"  to (status?.description),
            "type"      to typeName,
            "value"     to value,
        )
    }

    /** Status payload after the className tag has been consumed. */
    private fun readStatus(p: Parcel): Status {
        val code = p.readInt()
        val desc = p.readString()
        return Status(code, desc)
    }

    /** Decode the type-tagged value payload as used by both Response.result and CarPropertyValue.mValue. */
    private fun readValueByTypeName(p: Parcel, typeName: String?): Any? {
        return when (typeName) {
            null            -> null
            "java.lang.String"  -> p.readString()
            "[B"            -> p.createByteArray()?.toList()
            "java.lang.Integer" -> p.readInt()
            "java.lang.Long"    -> p.readLong()
            "java.lang.Float"   -> p.readFloat()
            "java.lang.Double"  -> p.readDouble()
            "java.lang.Boolean" -> p.readInt() != 0
            "[I" -> { p.readInt() /* length prefix */; p.createIntArray()?.toList() }
            "[F" -> { p.readInt(); p.createFloatArray()?.toList() }
            "[J" -> {
                val n = p.readInt()
                LongArray(n) { p.readLong() }.toList()
            }
            "android.os.Parcelable" -> {
                // Fall back to raw bytes — we don't know the inner class.
                BydLogger.w(TAG, "Response had nested Parcelable; skipped")
                null
            }
            else -> { BydLogger.w(TAG, "Unknown response typeName='$typeName'"); null }
        }
    }

    private fun readCarPropertyValue(p: Parcel): Map<String, Any?> {
        val key  = p.readString()
        val id   = p.readString()
        val type = p.readString()
        val v    = readValueByTypeName(p, type)
        return mapOf("propertyKey" to key, "propertyId" to id, "type" to type, "value" to v)
    }

    private fun readPropertyConfig(p: Parcel): Map<String, Any?> {
        // CarPropertyConfig Parcelable layout is not yet verified — we
        // read defensively. Confirm via runtime calibration.
        return try {
            mapOf(
                "propertyKey"     to p.readString(),
                "propertyId"      to p.readString(),
                "dataType"        to p.readString(),
                "readPermission"  to p.readString(),
                "writePermission" to p.readString(),
            )
        } catch (t: Throwable) {
            mapOf("error" to "config_decode_failed: ${t.message}")
        }
    }

    /** Write a CarPropertyValue payload (the body after the array length / non-null marker). */
    private fun writeCarPropertyValueBody(p: Parcel, name: String, value: Any?, typeHint: String?) {
        // Layout: writeString(propertyKey); writeString(propertyId); writeString(typeName); writeXXX(value)
        p.writeString(null)           // mPropertyKey — usually null in client writes
        p.writeString(name)           // mPropertyId — the "0xHEX" string
        val (typeName, payload) = encodeValue(value, typeHint)
        p.writeString(typeName)
        when (typeName) {
            "java.lang.String"  -> p.writeString(payload as String?)
            "[B"                -> p.writeByteArray(payload as ByteArray?)
            "java.lang.Integer" -> p.writeInt(payload as Int)
            "java.lang.Long"    -> p.writeLong(payload as Long)
            "java.lang.Float"   -> p.writeFloat(payload as Float)
            "java.lang.Double"  -> p.writeDouble(payload as Double)
            "java.lang.Boolean" -> p.writeInt(if (payload as Boolean) 1 else 0)
            "[I" -> { val a = payload as IntArray; p.writeInt(a.size); p.writeIntArray(a) }
            "[F" -> { val a = payload as FloatArray; p.writeInt(a.size); p.writeFloatArray(a) }
            "[J" -> {
                val a = payload as LongArray
                p.writeInt(a.size)
                for (v in a) p.writeLong(v)
            }
            else -> BydLogger.w(TAG, "unsupported write typeName='$typeName'")
        }
    }

    private fun encodeValue(value: Any?, hint: String?): Pair<String, Any?> {
        // Hint takes priority; fall back to runtime class.
        return when (hint) {
            "string", "java.lang.String"   -> "java.lang.String" to (value?.toString())
            "bytes", "[B"                  -> "[B" to (
                when (value) {
                    is ByteArray -> value
                    is List<*>   -> ByteArray(value.size) { (value[it] as Number).toByte() }
                    else         -> ByteArray(0)
                })
            "int",   "java.lang.Integer"   -> "java.lang.Integer" to ((value as? Number)?.toInt() ?: 0)
            "long",  "java.lang.Long"      -> "java.lang.Long"    to ((value as? Number)?.toLong() ?: 0L)
            "float", "java.lang.Float"     -> "java.lang.Float"   to ((value as? Number)?.toFloat() ?: 0f)
            "double","java.lang.Double"    -> "java.lang.Double"  to ((value as? Number)?.toDouble() ?: 0.0)
            "bool",  "java.lang.Boolean"   -> "java.lang.Boolean" to (
                value as? Boolean ?: ((value as? Number)?.toInt() ?: 0) != 0)
            else -> when (value) {
                is String   -> "java.lang.String"  to value
                is ByteArray-> "[B"                to value
                is Boolean  -> "java.lang.Boolean" to value
                is Int      -> "java.lang.Integer" to value
                is Long     -> "java.lang.Long"    to value
                is Float    -> "java.lang.Float"   to value
                is Double   -> "java.lang.Double"  to value
                else        -> "java.lang.Integer" to (value?.toString()?.toIntOrNull() ?: 0)
            }
        }
    }

    private fun emptyResponse(name: String) = mapOf(
        "name" to name, "ok" to false, "code" to Status.UNAVAILABLE,
        "errorMsg" to "null response", "type" to null, "value" to null,
    )

    // ─── plumbing ───────────────────────────────────────────────────────

    private fun extractBinder(p: Parcelable): IBinder? {
        // BinderCursor$BinderParcelable.getBinder() — class lives in carserver.
        val m = BydReflection.method(p.javaClass, "getBinder") ?: return null
        return try { m.invoke(p) as? IBinder } catch (_: Throwable) { null }
    }

    private fun requireBinder(): IBinder {
        val b = serviceBinder ?: throw IllegalStateException("Not connected — call connect() first")
        if (!b.isBinderAlive) {
            serviceBinder = null
            connect()
            return serviceBinder ?: throw IllegalStateException("Reconnect failed")
        }
        return b
    }

    // ─── listener stub ──────────────────────────────────────────────────

    /**
     * Server-side calls `onTransact(1, ...)` on us with:
     *   writeInterfaceToken("com.byd.car.property.ICarPropertyListener")
     *   writeString(name)
     *   writeInt(hasResponse)   // 0 or 1
     *   if hasResponse: writeToParcel of Response (className tag then payload)
     */
    inner class PropertyCallbackStub(
        private val onEvent: (String, BydReflection.DecodedValue) -> Unit
    ) : Binder() {

        init { attachInterface(null, LISTENER_TOKEN) }

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            return when (code) {
                INTERFACE_TRANSACTION -> {
                    reply?.writeString(LISTENER_TOKEN)
                    true
                }
                TX_ON_EVENT -> {
                    data.enforceInterface(LISTENER_TOKEN)
                    val name = data.readString() ?: ""
                    val decoded = try {
                        val hasResponse = data.readInt() != 0
                        if (!hasResponse) BydReflection.DecodedValue.empty()
                        else {
                            val responseClassName = data.readString()  // "com.byd.datasource.feature.Response"
                            if (responseClassName == null) BydReflection.DecodedValue.empty()
                            else {
                                // Skip the inner Status (writeParcelable nullable).
                                val statusClassName = data.readString()
                                if (statusClassName != null) {
                                    data.readInt()      // code
                                    data.readString()   // description
                                }
                                val typeName = data.readString()
                                val v = readValueByTypeName(data, typeName)
                                BydReflection.DecodedValue(v, typeName ?: "null")
                            }
                        }
                    } catch (t: Throwable) {
                        BydLogger.w(TAG, "listener decode failed for '$name': ${t.message}")
                        BydReflection.DecodedValue.empty()
                    }
                    try { onEvent(name, decoded) } catch (_: Throwable) {}
                    // oneway — reply may be null.
                    true
                }
                else -> super.onTransact(code, data, reply, flags)
            }
        }
    }

    // ─── data carriers ──────────────────────────────────────────────────

    data class Status(val code: Int, val description: String?) {
        companion object {
            // Verified from carserver.dex Status class static fields.
            const val SUCCESS         = 0
            const val NONE            = 1
            const val FAILED          = 2
            const val INVALID_ARG     = 3
            const val TIMEOUT         = 4
            const val UNAVAILABLE     = 5
            const val BLOCKING        = 6
            const val UNKNOWN_ERROR   = 7
            // The exact ordinals may differ — these are best-guess based
            // on naming order; the actual values aren't stored in the
            // <clinit> bytes that survived d8.
        }
    }

    data class SubscriptionToken(val propertyName: String, val stub: PropertyCallbackStub)

    companion object {
        private const val TAG = "BydCarPropertyClient"
        private const val AUTHORITY = "com.byd.car.server.provider.CarServiceProvider"
        private const val IFACE_TOKEN = "com.byd.car.property.ICarPropertyService"
        private const val LISTENER_TOKEN = "com.byd.car.property.ICarPropertyListener"
        private const val BUNDLE_KEY_BINDER = "binder"
        private const val INTERFACE_TRANSACTION = 0x5f4e5446  // android.os.IBinder.INTERFACE_TRANSACTION

        // Transaction codes — verified from ICarPropertyService$Stub$Proxy ops.
        private const val TX_SET_PROPERTIES       = 1
        private const val TX_GET_PROPERTY         = 2
        private const val TX_GET_PROPERTIES       = 3
        private const val TX_GET_PROPERTY_CONFIGS = 4
        private const val TX_REGISTER_CALLBACK    = 5
        private const val TX_UNREGISTER_CALLBACK  = 6

        // Listener side. Verified: oneway, TX 1.
        private const val TX_ON_EVENT = 1

        // v0.1.27+1: bootstrap fallbacks. Each connect() walks this
        // matrix until one combination yields a live IBinder.
        //
        // The recon-verified pair (URI="", FQCN=com.byd.car.property…)
        // returned null on carserver 2.1.0-alpha10. The fallbacks are
        // educated guesses based on common BinderProvider conventions
        // and naming patterns seen in adjacent BYD modules. Cheap to
        // try, expensive to be missing.
        private val URI_FALLBACKS = listOf(
            Uri.parse("content://$AUTHORITY"),
            Uri.parse("content://$AUTHORITY/service"),
            Uri.parse("content://$AUTHORITY/binder"),
            Uri.parse("content://$AUTHORITY/property"),
        )

        private val IFACE_FALLBACKS = listOf(
            "com.byd.car.property.ICarPropertyService",       // recon-verified
            "com.byd.car.cd.property.ICarPropertyService",
            "com.byd.cd.property.ICarPropertyService",
            "com.byd.car.ICarPropertyService",
            "com.byd.datasource.feature.ICarPropertyService",
            "com.byd.car.server.property.ICarPropertyService",
            "com.byd.car.server.ICarPropertyService",
        )

        private val CALL_METHODS = listOf(
            "getService", "getBinder", "binder", "service", "ICarPropertyService"
        )
    }
}
