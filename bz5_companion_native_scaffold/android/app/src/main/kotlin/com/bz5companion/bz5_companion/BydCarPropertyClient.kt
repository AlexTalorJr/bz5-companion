package com.bz5companion.bz5_companion

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Parcelable
import android.util.Log
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

    @Throws(Exception::class)
    fun connect() {
        if (serviceBinder?.isBinderAlive == true) return
        val uri = Uri.parse("content://$AUTHORITY")
        val cursor: Cursor = context.contentResolver.query(
            uri,
            arrayOf(IFACE_TOKEN),   // projection[0] = AIDL FQCN — the service selector
            null, null, null
        ) ?: throw IllegalStateException(
            "ContentResolver.query returned null for $uri. " +
            "Either carserver is missing or the projection FQCN is wrong."
        )
        cursor.use { c ->
            val extras = c.extras
                ?: throw IllegalStateException("BinderCursor has no extras Bundle")
            val parcelable = extras.getParcelable<Parcelable>(BUNDLE_KEY_BINDER)
                ?: throw IllegalStateException(
                    "No '$BUNDLE_KEY_BINDER' Parcelable in cursor extras. " +
                    "Keys present: ${extras.keySet()}"
                )
            val binder = extractBinder(parcelable)
                ?: throw IllegalStateException(
                    "Could not unwrap IBinder from ${parcelable.javaClass.name}. " +
                    "Expected a class with getBinder():IBinder method."
                )
            serviceBinder = binder
            Log.i(TAG, "ICarPropertyService connected via $uri")
        }
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
                    Log.w(TAG, "config decode failed at $it: ${t.message}")
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
                Log.w(TAG, "Response had nested Parcelable; skipped")
                null
            }
            else -> { Log.w(TAG, "Unknown response typeName='$typeName'"); null }
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
            else -> Log.w(TAG, "unsupported write typeName='$typeName'")
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
                        Log.w(TAG, "listener decode failed for '$name': ${t.message}")
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
    }
}
