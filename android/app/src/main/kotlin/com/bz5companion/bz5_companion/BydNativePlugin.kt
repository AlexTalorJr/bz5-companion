package com.bz5companion.bz5_companion

import android.app.Activity
import android.content.Context
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.BinaryMessenger
import java.util.concurrent.ConcurrentHashMap
import com.bz5companion.bz5_companion.hal.CompanionDecoderOverrides
import com.bz5companion.bz5_companion.hal.DecodedStreamSink
import com.bz5companion.bz5_companion.hal.DiLinkProfiles
import com.bz5companion.bz5_companion.hal.HalEngine
import com.bz5companion.bz5_companion.hal.TargetRegistry
import com.bz5companion.bz5_companion.hal.TargetSpec

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
class BydNativePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var appContext: Context

    // Activity binding is needed for runtime permission requests, which
    // require an Activity context (Context.startActivity won't trigger
    // the system permission dialog — only ActivityCompat.requestPermissions
    // on a real Activity does).
    @Volatile private var activity: Activity? = null

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

    // HAL push-telemetry subsystem (v0.1.29+61) — separate from the
    // ICarPropertyService path above. BYDAuto*Device.registerListener
    // push stream (vendored recon LiveTelemetrySubscriber) on its OWN
    // EventChannel so high-rate decoded telemetry never interleaves with
    // property-subscription events.
    private lateinit var halEventChannel: EventChannel
    @Volatile private var halSink: EventChannel.EventSink? = null
    // v0.1.29+107: the engine handle is now the platform-agnostic HalEngine
    // (a thin adapter over the vendored BZ5 LiveTelemetrySubscriber or the
    // vendored BZ3 Bz3TelemetrySubscriber). The BZ3-vs-BZ5 choice is made
    // once at start() by DiLinkProfiles.selectProfile() on device shape.
    @Volatile private var halEngine: HalEngine? = null
    @Volatile private var halStreamSink: DecodedStreamSink? = null
    // Last platform selection, surfaced to Dart (honesty UI) via
    // "halActivePlatform". Null until the first halStreamStart.
    @Volatile private var lastSelection: DiLinkProfiles.Selection? = null
    // Optional advanced-setting override of the platform id ("BZ3"/"BZ5").
    // Set from Dart via "halSetPlatformOverride"; null = auto-detect.
    @Volatile private var platformOverrideId: String? = null

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

        // Dedicated HAL telemetry stream. onListen just records the sink;
        // the subscription is started explicitly via halStreamStart (so
        // listening alone doesn't auto-bind the framework).
        halEventChannel = EventChannel(msgr, CHANNEL_HAL_EVENTS)
        halEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                halSink = sink
            }
            override fun onCancel(args: Any?) {
                stopHalStream()
                halSink = null
            }
        })
        BydLogger.i(TAG, "BydNativePlugin attached")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Unsubscribe everything so we don't leak listeners across hot-restart.
        for ((_, tok) in activeSubs) {
            try { propertyClient?.unsubscribe(tok) } catch (_: Throwable) {}
        }
        activeSubs.clear()
        try { propertyClient?.close() } catch (_: Throwable) {}
        propertyClient = null
        // v0.1.27+1: HAL probe maintains its own singleton cache for
        // BYDAutoXxxDevice instances; clear it so a hot-restart sees
        // fresh state and we don't keep stale instances if the
        // framework's internal state changed.
        try { BydHalProbe.clearCache() } catch (_: Throwable) {}

        stopHalStream()
        halSink = null

        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        halEventChannel.setStreamHandler(null)
        eventSink = null
        BydLogger.i(TAG, "BydNativePlugin detached")
    }

    // ─── ActivityAware ─────────────────────────────────────────────────────
    //
    // We track the current Activity so requestPermissions() can find a
    // real Activity to attach the system dialog to. Without this binding
    // the plugin would only have applicationContext, which can't host
    // the permission UI.

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
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
                "requestRuntimePermissions" -> result.success(requestRuntimePermissions())
                "pullLogs"          -> handlePullLogs(call, result)
                "clearLogs"         -> { BydLogger.clear(); result.success(true) }
                "openAppSettings"   -> result.success(openAppSettings())
                "getDiagnostics"    -> result.success(buildDiagnostics())
                // v0.1.27+1: deep probing endpoints. None of these
                // require ICarPropertyService to be reachable — they
                // are independent diagnostic paths the user runs from
                // Native Explorer to find a working route.
                "probeConnectionPaths" -> handleProbeConnectionPaths(result)
                "halProbeAll"          -> handleHalProbeAll(result)
                "halGet"               -> handleHalGet(call, result)
                // v0.1.29+61: HAL push-telemetry stream control.
                "halStreamStart"       -> handleHalStreamStart(result)
                "halStreamStop"        -> { stopHalStream(); result.success(true) }
                // v0.1.29+107: DiLink platform identity for honesty UI +
                // optional advanced-setting override of the engine choice.
                "halActivePlatform"    -> result.success(buildActivePlatform())
                "halSetPlatformOverride" -> {
                    platformOverrideId = call.argument<String>("id")
                    result.success(true)
                }
                // v0.1.29+100: read the byd car_status ContentProvider (service
                // health / maintenance / fluid flags). No HAL, no UDS, no dongle
                // — a plain ContentResolver query against a head-unit-local
                // provider. Returns a key→value String map (one table). Phone
                // has no such provider, so this only yields data on the HU.
                "queryCarStatus"       -> handleQueryCarStatus(call, result)
                else                -> result.notImplemented()
            }
        } catch (t: Throwable) {
            BydLogger.e(TAG, "onMethodCall[${call.method}] failed", t)
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

    // ─── v0.1.27+1: deep diagnostic probes ────────────────────────────────
    //
    // These three handlers exist to find a working data path on
    // firmware variants where the canonical ICarPropertyService
    // bootstrap fails silently. They run independently of the property
    // client, so they keep working even when connect() throws.

    private fun handleProbeConnectionPaths(result: MethodChannel.Result) {
        Thread {
            try {
                val report = BydConnectionProbe.probeAll(appContext)
                // Also stash a human-readable rendering so the UI can
                // copy-paste it without re-rendering on the Dart side.
                val text = BydConnectionProbe.renderReport(report)
                result.success(report + mapOf("rendered" to text))
            } catch (t: Throwable) {
                result.error("PROBE_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleHalProbeAll(result: MethodChannel.Result) {
        Thread {
            try {
                result.success(BydHalProbe.probeAll(appContext))
            } catch (t: Throwable) {
                result.error("HAL_PROBE_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    private fun handleHalGet(call: MethodCall, result: MethodChannel.Result) {
        val domain = call.argument<String>("domain")
            ?: return result.error("BAD_ARGS", "missing 'domain'", null)
        val featureIds = call.argument<List<Number>>("featureIds")
            ?: return result.error("BAD_ARGS", "missing 'featureIds'", null)
        val ints = IntArray(featureIds.size) { featureIds[it].toInt() }
        Thread {
            try {
                result.success(BydHalProbe.halGet(appContext, domain, ints))
            } catch (t: Throwable) {
                result.error("HAL_GET_ERROR", t.message, t.stackTraceToString())
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

    // ─── diagnostics (no-adb support) ──────────────────────────────────────

    private fun handlePullLogs(call: MethodCall, result: MethodChannel.Result) {
        val count = (call.argument<Int>("count") ?: 200).coerceIn(1, 500)
        val sinceTs = call.argument<Number>("sinceTs")?.toLong()
        result.success(BydLogger.pull(count, sinceTs))
    }

    /**
     * Open Android's "App info" screen for our package so the user can
     * grant permissions manually. On head units without ADB, this is the
     * only practical way to flip dangerous-level BYDAUTO_* permissions
     * to granted.
     *
     * Returns true on success, false if the system rejected the intent
     * (very rare — only if the launcher has stripped Settings).
     */
    private fun openAppSettings(): Boolean {
        return try {
            val intent = android.content.Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:${appContext.packageName}")
            ).apply {
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
            true
        } catch (t: Throwable) {
            BydLogger.w(TAG, "openAppSettings failed: ${t.message}")
            false
        }
    }

    /**
     * v0.1.26+14: programmatically trigger the system runtime-permission
     * prompt for every dangerous-level BYDAUTO_* permission that the
     * manifest declares but the OS hasn't granted yet.
     *
     * On the BZ5 field test, "Open App Settings" did show the app's
     * permission screen but BYDAUTO_* perms didn't appear there as
     * grantable entries — they're declared and "Declared" in our UI but
     * never reach the user-facing settings list. The likely reason is
     * that the system's per-app permission UI only surfaces permissions
     * the OS has classified as user-facing; signature-protected ones
     * are hidden. requestPermissions() may still work though, because
     * it asks the framework directly rather than going through Settings.
     *
     * Returns a map of result codes per permission:
     *   {"BYDAUTO_X": "requested" | "already_granted" | "no_activity"}
     * "requested" means the system dialog was shown (or the request
     * was queued — for some permissions the system grants silently
     * without showing a dialog). The actual outcome must be re-checked
     * via checkPermissions() after the dialog dismisses.
     */
    private fun requestRuntimePermissions(): Map<String, Any?> {
        val act = activity
        if (act == null) {
            BydLogger.w(TAG, "requestRuntimePermissions called with no Activity bound")
            return mapOf("ok" to false, "error" to "no_activity")
        }

        val toRequest = BydPermissions.DANGEROUS.filter {
            appContext.checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }

        if (toRequest.isEmpty()) {
            BydLogger.i(TAG, "requestRuntimePermissions: nothing to request, all granted")
            return mapOf("ok" to true, "requested" to 0, "alreadyGranted" to BydPermissions.DANGEROUS.size)
        }

        return try {
            ActivityCompat.requestPermissions(
                act,
                toRequest.toTypedArray(),
                REQ_CODE_BYDAUTO_PERMS
            )
            BydLogger.i(TAG, "requestRuntimePermissions: requested ${toRequest.size} perms")
            mapOf(
                "ok" to true,
                "requested" to toRequest.size,
                "alreadyGranted" to (BydPermissions.DANGEROUS.size - toRequest.size),
                "names" to toRequest,
            )
        } catch (t: Throwable) {
            BydLogger.w(TAG, "requestRuntimePermissions failed: ${t.message}")
            mapOf("ok" to false, "error" to (t.message ?: "unknown"))
        }
    }

    /**
     * Snapshot of everything we know about the environment. Used by the
     * Native Explorer's "Diagnostics" panel to give the user a single
     * exportable view of what's wrong.
     */
    private fun buildDiagnostics(): Map<String, Any?> {
        val pm = appContext.packageManager
        // Is carserver installed?
        val carServerInstalled = try {
            pm.getPackageInfo("com.byd.car.server", 0)
            true
        } catch (_: Throwable) { false }

        val carServerVersion: String? = try {
            pm.getPackageInfo("com.byd.car.server", 0).versionName
        } catch (_: Throwable) { null }

        // Does the BinderProvider authority resolve from our process?
        val providerResolves: Boolean = try {
            val info = pm.resolveContentProvider(
                "com.byd.car.server.provider.CarServiceProvider", 0
            )
            info != null
        } catch (_: Throwable) { false }

        // BYDAutoBodyworkDevice availability — the canonical head-unit
        // detection signal. If this is true we're on a real head unit.
        val frameworkPresent = try {
            vinDetector.isFrameworkPresent()
        } catch (_: Throwable) { false }

        // VIN cached (no I/O)
        val vinCached: String? = try {
            vinDetector.getVin(appContext, fresh = false)
        } catch (_: Throwable) { null }

        // Granted permission count
        val perms = try { BydPermissions.declaredAndGranted(appContext) } catch (_: Throwable) { emptyList() }
        val granted = perms.count { (it["granted"] == true) }
        val declared = perms.count { (it["declared"] == true) }

        return mapOf(
            "carServerInstalled" to carServerInstalled,
            "carServerVersion"   to carServerVersion,
            "providerResolves"   to providerResolves,
            "frameworkPresent"   to frameworkPresent,
            "vinCached"          to vinCached,
            "permissionsGranted" to granted,
            "permissionsDeclared" to declared,
            "permissionsTotal"   to perms.size,
            "logRingSize"        to BydLogger.size(),
            "packageName"        to appContext.packageName,
            "androidSdk"         to android.os.Build.VERSION.SDK_INT,
            "device"             to "${android.os.Build.MANUFACTURER}/${android.os.Build.MODEL}",
            // v0.1.29+107: fingerprint is the strongest DiLink platform marker
            // (BZ3 = "qti/trinket/trinket:10/...", BZ5 = "TOYOTA SPACE"...).
            "fingerprint"        to android.os.Build.FINGERPRINT,
        )
    }

    // ─── HAL push-telemetry control ────────────────────────────────────

    /**
     * v0.1.29+107: report the active DiLink platform + engine for honesty UI.
     * Reflects the LAST selection made by halStreamStart (null fields before
     * the first start). `predictedEngine` is what we would pick right now
     * given current signals + override, so the StatusScreen can show a sane
     * value even before the stream is started.
     */
    private fun buildActivePlatform(): Map<String, Any?> {
        val sel = lastSelection
        // Predict without side effects (no engine instantiation).
        val predicted = DiLinkProfiles.selectProfile(
            overrideId = platformOverrideId,
            fingerprint = android.os.Build.FINGERPRINT,
            sdk = android.os.Build.VERSION.SDK_INT,
            vin = vinDetector.lastKnownVin(),
        )
        return mapOf(
            "active"            to (halEngine != null),
            "overrideId"        to platformOverrideId,
            "platformId"        to (sel?.platformId ?: predicted.platformId),
            "displayName"       to (sel?.displayName ?: predicted.displayName),
            "engineKind"        to (sel?.engineKind?.name ?: predicted.engineKind.name),
            "reason"            to (sel?.reason ?: predicted.reason),
            "predictedPlatform" to predicted.platformId,
            "predictedEngine"   to predicted.engineKind.name,
            "fingerprint"       to android.os.Build.FINGERPRINT,
            "androidSdk"        to android.os.Build.VERSION.SDK_INT,
        )
    }

    /**
     * Start the live HAL telemetry subscription. Requires Dart to already
     * be listening on the HAL EventChannel (so there's a sink to push
     * into). Returns the subscriber start status (registered / failed
     * target counts) for bring-up diagnostics. Restarts cleanly if
     * already running.
     */
    private fun handleHalStreamStart(result: MethodChannel.Result) {
        val sink = halSink
            ?: return result.error(
                "HAL_NO_SINK",
                "Dart must listen on the HAL event channel before halStreamStart",
                null,
            )
        stopHalStream() // restart cleanly if already running

        // Bring-up can block (reflection + registerListener round-trips),
        // so run off the main thread; marshal status back via result.
        Thread {
            try {
                // v0.1.29+66: companion override layer — local decoder fixes
                // and battery-temp candidates (see CompanionDecoderOverrides).
                val streamSink = DecodedStreamSink(sink, CompanionDecoderOverrides.map)
                // The vendored registry is never edited (DO-NOT-EDIT / SHA
                // pinned); extra companion-only fids are layered on top by
                // copying the Statistic TargetSpec with an extended id set.
                val baseTargets = TargetRegistry.streamingTargets(appContext) // 8 targets
                val targets = baseTargets.map { spec ->
                    if (spec.key == "BYDAutoStatisticDevice")
                        spec.copy(
                            featureIds = spec.featureIds +
                                CompanionDecoderOverrides.extraStatisticFids
                        )
                    else spec
                } +
                // v0.1.29+89: BigData CAN-collect trigger + data channel.
                // streamingTargets() (the companion 8-target subset) omits
                // BYDAutoPowerDevice and BYDAutoBigDataDevice, so the GB32960
                // CAN-collect never starts and 0x99000020 frames (incl. our
                // 0x044C fractional SOC) never flow — confirmed by an export
                // showing 5403 HAL rows but ZERO BigData rows / no Power
                // device. recon starts the collect by subscribing Power with
                // canDataCollect fids 0x99000037+0x99000003 (the patch-046
                // breakthrough set), with BigData 0x99000020 as the data
                // channel. We layer both on here, in companion code, WITHOUT
                // editing the vendored registry (Друг 3: same registerListener,
                // no special call, no uid/permission dependency — Power is the
                // trigger that was simply missing from our subset).
                listOf(
                    TargetSpec(
                        "BYDAutoPowerDevice_canDataCollect",
                        "android.hardware.bydauto.power.BYDAutoPowerDevice",
                        intArrayOf(0x99000037.toInt(), 0x99000003.toInt()),
                    ),
                    TargetSpec(
                        "BYDAutoBigDataDevice_canDataCollect",
                        "android.hardware.bydauto.bigdata.BYDAutoBigDataDevice",
                        intArrayOf(0x99000020.toInt()),
                    ),
                )
                // v0.1.29+107: pick the DiLink platform by device shape and
                // instantiate the matching engine (BZ5/FIELDS or BZ3/GETTERS).
                // Model is a fact about the hardware, not a user preference, so
                // this is auto-detected here in the consumer (override only via
                // advanced setting). The HAL/OBD2 source toggle is a SEPARATE
                // layer and stays a user choice — do not conflate.
                val selection = DiLinkProfiles.selectProfile(
                    overrideId = platformOverrideId,
                    fingerprint = android.os.Build.FINGERPRINT,
                    sdk = android.os.Build.VERSION.SDK_INT,
                    vin = vinDetector.lastKnownVin(),
                )
                lastSelection = selection
                BydLogger.i(
                    TAG,
                    "DiLink platform: ${selection.platformId} " +
                        "(engine=${selection.engineKind}, reason=${selection.reason})"
                )

                // PER-PROFILE Engine safety: if this profile flags
                // unconditionalEngine (an unknown DiLink whose FeatureIds may
                // not resolve), make sure the Engine device is present even if
                // streamingTargets()'s fid-gate dropped it. Both known profiles
                // are false (recon q1 confirmed BZ3 FeatureIds resolve), so this
                // is a no-op for BZ3/BZ5 — purely future-proofing.
                val engineTargets =
                    if (selection.profile?.unconditionalEngine == true &&
                        targets.none { it.key == "BYDAutoEngineDevice" }) {
                        targets + TargetSpec(
                            "BYDAutoEngineDevice",
                            "android.hardware.bydauto.engine.BYDAutoEngineDevice",
                            intArrayOf(
                                0x28A00008.toInt(), 0x28A00018.toInt(),
                                0x15100020.toInt(), 0x3DB00010.toInt(),
                                0x3DB00008.toInt(),
                            ),
                        )
                    } else {
                        targets
                    }

                val engine = DiLinkProfiles.selectEngine(
                    selection.engineKind,
                    appContext,
                    streamSink,
                    engineTargets,
                )
                val status = engine.start()
                halStreamSink = streamSink
                halEngine = engine
                BydLogger.i(TAG, "HAL stream started: $status")
                // SubscriptionStatus is a data class — not channel-safe.
                // Marshal to a plain Map the Dart side parses (HalStartStatus).
                result.success(
                    mapOf(
                        "attempted" to status.targetsAttempted,
                        "registered" to status.targetsRegistered,
                        "failed" to status.targetsFailed,
                        "errors" to status.perTargetErrors,
                    )
                )
            } catch (t: Throwable) {
                BydLogger.e(TAG, "halStreamStart failed", t)
                stopHalStream()
                result.error("HAL_START_ERROR", t.message, t.stackTraceToString())
            }
        }.start()
    }

    /** Stop the HAL subscription and detach the bridging sink. Idempotent. */
    private fun stopHalStream() {
        try { halEngine?.stop() } catch (t: Throwable) {
            BydLogger.e(TAG, "halEngine.stop failed", t)
        }
        halEngine = null
        try { halStreamSink?.detach() } catch (_: Throwable) {}
        halStreamSink = null
    }

    /**
     * Read one table of the byd `car_status` ContentProvider into a flat
     * key→value String map. The provider lives in the head-unit system
     * image; on a phone it does not exist and the query returns null →
     * we hand back an empty map so the Dart side shows an honest empty
     * state rather than crashing.
     *
     * The provider rejects the bare authority ("Invalid URI") — a table
     * path is mandatory. We default to `car_status` (the key/value health
     * + maintenance table) but accept a `table` arg so the same endpoint
     * can later read `dicare_record` (service-event log) without a new
     * method.
     *
     * Read-only, side-effect-free. Cursor is always closed. Any throw is
     * converted to a Flutter error by the onMethodCall wrapper.
     */
    private fun handleQueryCarStatus(call: MethodCall, result: MethodChannel.Result) {
        val table = call.argument<String>("table") ?: "car_status"
        // Whitelist the table segment — the provider only exposes these two,
        // and this keeps the URI free of caller-supplied path tricks.
        val safeTable = when (table) {
            "car_status", "dicare_record" -> table
            else -> {
                result.error("BAD_ARGS", "unknown car_status table: $table", null)
                return
            }
        }
        Thread {
            val out = mutableMapOf<String, Any?>()
            val rows = mutableListOf<Map<String, String?>>()
            var cursor: android.database.Cursor? = null
            try {
                val uri = android.net.Uri.parse(
                    "content://com.byd.carStatusProvider/$safeTable"
                )
                cursor = appContext.contentResolver.query(uri, null, null, null, null)
                if (cursor == null) {
                    // Provider absent (phone) or refused — not an error, just
                    // "no data on this device".
                    out["table"] = safeTable
                    out["available"] = false
                    out["summary"] = "cursor=null (provider absent or refused)"
                    out["kv"] = emptyMap<String, String>()
                    out["rows"] = emptyList<Map<String, String?>>()
                    result.success(out)
                    return@Thread
                }

                val cols = try { cursor.columnNames.toList() } catch (_: Throwable) { emptyList() }
                out["columns"] = cols

                // The car_status table is key/value shaped (columns id/key/value).
                // Build a convenience kv map when those columns are present;
                // always also return the raw rows so dicare_record (which has a
                // different schema) is usable through the same path.
                val keyIdx = cursor.getColumnIndex("key")
                val valIdx = cursor.getColumnIndex("value")
                val kv = mutableMapOf<String, String>()

                while (cursor.moveToNext()) {
                    val row = mutableMapOf<String, String?>()
                    for (i in 0 until cursor.columnCount) {
                        val name = try { cursor.getColumnName(i) } catch (_: Throwable) { "col$i" }
                        val v = try { cursor.getString(i) } catch (_: Throwable) { null }
                        row[name] = v
                    }
                    rows += row
                    if (keyIdx >= 0 && valIdx >= 0) {
                        val k = try { cursor.getString(keyIdx) } catch (_: Throwable) { null }
                        val v = try { cursor.getString(valIdx) } catch (_: Throwable) { null }
                        if (k != null) kv[k] = v ?: ""
                    }
                }

                out["table"] = safeTable
                out["available"] = true
                out["rowCount"] = rows.size
                out["kv"] = kv
                out["rows"] = rows
                out["summary"] = "ok: ${rows.size} rows, ${kv.size} kv pairs"
                result.success(out)
            } catch (t: Throwable) {
                BydLogger.e(TAG, "queryCarStatus[$safeTable] failed", t)
                // Surface as an honest failure map rather than a hard error —
                // the UI treats available=false the same whether the provider
                // was missing or threw.
                result.success(
                    mapOf(
                        "table" to safeTable,
                        "available" to false,
                        "summary" to "threw: ${t.javaClass.simpleName}: ${t.message?.take(180)}",
                        "kv" to emptyMap<String, String>(),
                        "rows" to emptyList<Map<String, String?>>(),
                    )
                )
            } finally {
                try { cursor?.close() } catch (_: Throwable) {}
            }
        }.start()
    }

    companion object {
        private const val TAG = "BydNativePlugin"
        const val CHANNEL_METHOD = "bz5_companion/native_car"
        const val CHANNEL_EVENTS = "bz5_companion/native_car/events"
        const val CHANNEL_HAL_EVENTS = "bz5_companion/hal_telemetry/events"
        // Arbitrary 12-bit non-conflicting request code for our perm batch.
        private const val REQ_CODE_BYDAUTO_PERMS = 0x42D
    }
}
