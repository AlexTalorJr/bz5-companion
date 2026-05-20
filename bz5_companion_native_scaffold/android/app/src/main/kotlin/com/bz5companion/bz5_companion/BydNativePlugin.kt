package com.bz5companion.bz5_companion

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.ConcurrentHashMap

/**
 * Native bridge for talking to BYD/DiLink 5.0 car framework from Flutter.
 *
 * This plugin exposes three independent capabilities through a single
 * MethodChannel (`bz5_companion/native_car`) plus one EventChannel
 * (`bz5_companion/native_car/events`):
 *
 *  1. **VIN detect** (`detectVin`) — reflection lookup of
 *     android.hardware.bydauto.bodywork.BYDAutoBodyworkDevice. If the class
 *     exists, we're running on the head unit and can use native data; if
 *     it doesn't, we're on a phone and must fall back to BLE+ELM. Cheap
 *     auto-detect, safe to call on any device.
 *
 *  2. **Diagnostic snapshot** (`diagSnapshot`) — LocalSocket abstract
 *     namespace `diag_socket_channel`, reverse-engineered from
 *     com.byd.diagnosticinfo. Returns a list of DTC/diagnostic rows with
 *     name/value pairs. SNAPSHOT semantics, not realtime.
 *
 *  3. **ICarPropertyService** (`getProperty`, `getProperties`,
 *     `subscribe`, `unsubscribe`, `setProperty`) — talks to
 *     com.byd.car.server's ContentProvider, retrieves the IBinder,
 *     and forwards AIDL transactions. Returns decoded values to Flutter.
 *     Streaming subscriptions emit through the EventChannel.
 *
 * All three are best-effort: every entry point catches Throwable and
 * returns a structured error so the Dart side can decide what to do.
 * Nothing here throws into Flutter's main thread.
 *
 * Permissions you may need declared in AndroidManifest:
 *
 *   <uses-permission android:name="com.byd.car.server.PROVIDER" />
 *   <uses-permission android:name="android.permission.BYDAUTO_ENERGY_COMMON" />
 *   <uses-permission android:name="android.permission.BYDAUTO_CHARGING_COMMON" />
 *   <uses-permission android:name="android.permission.BYDAUTO_SPEED_COMMON" />
 *   ...  (the full set of *_COMMON permissions the app uses)
 *
 * The COMMON permissions are dangerous-level — you must runtime-request
 * them on Android 6+. See BydPermissions.PERMISSIONS for the full list.
 */
class BydNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context

    // VIN detector is stateless; share a single instance for caching.
    private val vinDetector = BydVinDetector()

    // Property client is bound lazily on first use; we keep the singleton.
    private var propertyClient: BydCarPropertyClient? = null

    // Active subscriptions, keyed by property name. We dedupe so multiple
    // Dart-side subscribers to the same property share one HAL listener.
    private val activeSubs = ConcurrentHashMap<String, BydCarPropertyClient.SubscriptionToken>()

    // The single EventSink that broadcasts to Dart. Created on first
    // listen, cleared when Dart cancels.
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val msgr: BinaryMessenger = binding.binaryMessenger

        methodChannel = MethodChannel(msgr, CHANNEL_METHOD)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(msgr, CHANNEL_EVENTS)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }

            override fun onCancel(args: Any?) {
                eventSink = null
            }
        })
        Log.i(TAG, "BydNativePlugin attached")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Unsubscribe everything so we don't leak listeners across hot-restart.
        for ((_, tok) in activeSubs) {
            try { propertyClient?.unsubscribe(tok) } catch (_: Throwable) {}
        }
        activeSubs.clear()
        try { propertyClient?.close() } catch (_: Throwable) {}
        propertyClient = null

        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        Log.i(TAG, "BydNativePlugin detached")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Wrap every handler so an exception becomes a Flutter error rather
        // than a JVM crash on the main thread.
        try {
            when (call.method) {
                "isNativeAvailable" -> result.success(vinDetector.isFrameworkPresent())
                "detectVin"         -> handleDetectVin(call, result)
                "diagSnapshot"      -> handleDiagSnapshot(call, result)
                "getProperty"       -> handleGetProperty(call, result)
                "getProperties"     -> handleGetProperties(call, result)
                "getPropertyConfig" -> handleGetPropertyConfig(call, result)
                "subscribe"         -> handleSubscribe(call, result)
                "unsubscribe"       -> handleUnsubscribe(call, result)
                "setProperty"       -> handleSetProperty(call, result)
                "checkPermissions"  -> result.success(BydPermissions.declaredAndGranted(appContext))
                else                -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "onMethodCall[${call.method}] failed", t)
            result.error("NATIVE_ERROR", t.message ?: t.javaClass.simpleName, t.stackTraceToString())
        }
    }

    // ─── dispatch handlers ────────────────────────────────────────────────

    private fun handleDetectVin(call: MethodCall, result: MethodChannel.Result) {
        // Fresh = pulls from CAN (slower, ~tens of ms);
        // cached = previously read value (fast).
        val fresh = call.argument<Boolean>("fresh") ?: false
        val vin = vinDetector.getVin(appContext, fresh = fresh)
        // null on a phone (ClassNotFoundException) or if the framework
        // hides this device. The caller treats null as "not on head unit".
        result.success(vin)
    }

    private fun handleDiagSnapshot(call: MethodCall, result: MethodChannel.Result) {
        val command = call.argument<String>("command") ?: "latest_diag_data"
        val timeoutMs = call.argument<Int>("timeoutMs") ?: 5000
        // Run on a worker thread because LocalSocket.connect can block.
        // Use a tiny thread pool, not main looper.
        Thread {
            try {
                val rows = BydDiagSocket.readSnapshot(command, timeoutMs)
                // Re-marshal to Flutter on the main thread (MethodChannel.Result
                // is documented as main-thread-only).
                methodChannel.invokeMethod("__noop", null) // ping to switch context isn't needed,
                                                          // Result is allowed off-thread on recent
                                                          // Flutter; we just use it directly here.
                result.success(rows)
            } catch (t: Throwable) {
                result.error("DIAG_SOCKET_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleGetProperty(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
            ?: return result.error("BAD_ARGS", "missing 'name'", null)
        val client = obtainClient()
        // getProperty is sync but we don't want to block the main thread.
        Thread {
            try {
                val v = client.getProperty(name)
                result.success(v)
            } catch (t: Throwable) {
                result.error("PROPERTY_GET_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleGetProperties(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names")
            ?: return result.error("BAD_ARGS", "missing 'names'", null)
        val client = obtainClient()
        Thread {
            try {
                val v = client.getProperties(names)
                result.success(v)
            } catch (t: Throwable) {
                result.error("PROPERTY_GET_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleGetPropertyConfig(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names")
            ?: return result.error("BAD_ARGS", "missing 'names'", null)
        val client = obtainClient()
        Thread {
            try {
                result.success(client.getPropertyConfigs(names))
            } catch (t: Throwable) {
                result.error("CONFIG_GET_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleSubscribe(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names")
            ?: return result.error("BAD_ARGS", "missing 'names'", null)
        val client = obtainClient()
        Thread {
            try {
                for (n in names) {
                    // De-dupe: if there's already a subscription for this
                    // property, skip — events are broadcast to all Dart
                    // listeners via the single EventChannel.
                    if (activeSubs.containsKey(n)) continue
                    val tok = client.subscribe(n) { propName, decoded ->
                        // Dispatch to Flutter. EventSink.success is safe to
                        // call off the main thread on Android.
                        eventSink?.success(mapOf(
                            "name" to propName,
                            "value" to decoded.value,
                            "type"  to decoded.typeHint,
                            "tsMs"  to System.currentTimeMillis(),
                        ))
                    }
                    activeSubs[n] = tok
                }
                result.success(activeSubs.keys.toList())
            } catch (t: Throwable) {
                result.error("SUBSCRIBE_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleUnsubscribe(call: MethodCall, result: MethodChannel.Result) {
        val names = call.argument<List<String>>("names")
            ?: return result.error("BAD_ARGS", "missing 'names'", null)
        Thread {
            try {
                for (n in names) {
                    val tok = activeSubs.remove(n) ?: continue
                    propertyClient?.unsubscribe(tok)
                }
                result.success(true)
            } catch (t: Throwable) {
                result.error("UNSUBSCRIBE_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleSetProperty(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
            ?: return result.error("BAD_ARGS", "missing 'name'", null)
        val value = call.argument<Any>("value")
            ?: return result.error("BAD_ARGS", "missing 'value'", null)
        val typeHint = call.argument<String>("type") // optional: 'int', 'long', 'float', 'double', 'bytes', 'string'
        val client = obtainClient()
        Thread {
            try {
                val status = client.setProperty(name, value, typeHint)
                result.success(mapOf("code" to status.code, "description" to status.description))
            } catch (t: Throwable) {
                result.error("PROPERTY_SET_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    // ─── lifecycle helpers ─────────────────────────────────────────────────

    @Synchronized
    private fun obtainClient(): BydCarPropertyClient {
        return propertyClient ?: run {
            val c = BydCarPropertyClient(appContext)
            // Connecting binds the AIDL through the BinderProvider URI.
            // Fails with descriptive exception if the provider isn't
            // present on this device.
            c.connect()
            propertyClient = c
            c
        }
    }

    companion object {
        private const val TAG = "BydNativePlugin"
        const val CHANNEL_METHOD = "bz5_companion/native_car"
        const val CHANNEL_EVENTS = "bz5_companion/native_car/events"
    }
}
