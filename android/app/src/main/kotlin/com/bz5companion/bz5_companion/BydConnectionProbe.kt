package com.bz5companion.bz5_companion

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.IBinder
import android.os.Parcelable

/**
 * Diagnostic prober for every plausible way to reach
 * `ICarPropertyService` from our app's UID.
 *
 * Field test on carserver 2.1.0-alpha10 showed that the canonical
 * bootstrap (`ContentResolver.query(uri, [FQCN], ...)`) returns null
 * even though:
 *   - `pm.resolveContentProvider(authority)` succeeds (provider visible)
 *   - `com.byd.car.server.PROVIDER` permission is granted
 *   - the carserver package is installed (version 2.1.0-alpha10)
 *
 * Null return without SecurityException strongly suggests
 * `BinderProvider.query()` silently caught an internal exception
 * (Class.forName on a renamed FQCN, Spi.getService timing race, etc.).
 *
 * This prober walks a *matrix* of candidate URIs, projections, and
 * extraction strategies, capturing the outcome of each attempt
 * (cursor null/empty/extras keys/bundle key match) so the user can see
 * exactly which path is the closest to working — and we can adapt the
 * production `connect()` once we know.
 *
 * Every probe is read-only and side-effect-free. The prober never
 * registers a listener, never opens a real subscription.
 */
object BydConnectionProbe {

    private const val TAG = "BydConnectionProbe"
    private const val AUTHORITY = "com.byd.car.server.provider.CarServiceProvider"

    /**
     * Candidate FQCNs that `BinderProvider.query()` might accept as the
     * service selector. The primary is verified by decompile; the rest
     * are educated guesses for what the alpha10 build *might* have
     * renamed to.
     */
    private val IFACE_CANDIDATES = listOf(
        "com.byd.car.property.ICarPropertyService",       // recon-verified
        "com.byd.car.cd.property.ICarPropertyService",
        "com.byd.cd.property.ICarPropertyService",
        "com.byd.car.ICarPropertyService",
        "com.byd.datasource.feature.ICarPropertyService",
        "com.byd.car.server.property.ICarPropertyService",
        "com.byd.car.server.ICarPropertyService",
        "com.byd.spi.ipc.ICarPropertyService",
    )

    /** Candidate URIs — path-less + with explicit paths. */
    private val URI_PATHS = listOf("", "/service", "/binder", "/property", "/ICarPropertyService")

    /**
     * Candidate keys for the binder in `cursor.extras`. The primary
     * "binder" is recon-verified, the rest are common conventions.
     */
    private val EXTRAS_KEYS = listOf(
        "binder",
        "service",
        "car_service_binder",
        "ipc_binder",
        "binder_proxy",
        "BinderParcelable",
    )

    /**
     * Candidate method names for `ContentProvider.call()` fallback —
     * some BinderProvider implementations expose binders via call()
     * instead of (or in addition to) query().
     */
    private val CALL_METHODS = listOf(
        "getService", "getBinder", "binder", "service", "ICarPropertyService"
    )

    /**
     * Run every probe. Returns a structured report ready for serialization
     * to Dart. The report is *long* (40+ rows) but easy to skim — each
     * row is a single attempt with its outcome.
     */
    fun probeAll(ctx: Context): Map<String, Any?> {
        BydLogger.i(TAG, "BydConnectionProbe: starting full bootstrap probe")

        val results = mutableListOf<Map<String, Any?>>()

        // ─── Phase 1: provider metadata ─────────────────────────────────
        results += probeProviderMetadata(ctx)

        // ─── Phase 2: ContentResolver.query(uri, projection) matrix ────
        // For each (uri, projection) pair, log: cursor null/non-null,
        // row count, extras keys, whether any expected binder key was
        // present.
        for (path in URI_PATHS) {
            val uri = Uri.parse("content://$AUTHORITY$path")
            for (fqcn in IFACE_CANDIDATES) {
                results += probeQuery(ctx, uri, arrayOf(fqcn))
            }
        }
        // One bonus attempt: projection=null (some providers ignore
        // projection entirely and always return the same binder).
        results += probeQuery(ctx, Uri.parse("content://$AUTHORITY"), null)

        // ─── Phase 3: ContentProvider.call() matrix ─────────────────────
        // Some BinderProvider derivatives only expose the binder via
        // ContentProvider.call(method, arg, extras).
        val callUri = Uri.parse("content://$AUTHORITY")
        for (method in CALL_METHODS) {
            for (fqcn in IFACE_CANDIDATES) {
                results += probeCall(ctx, callUri, method, fqcn)
            }
        }

        // ─── Phase 4: ServiceManager.getService() ───────────────────────
        // Reflection-only, no public API. The system_server keeps a
        // global service table; some OEMs register their car services
        // there in addition to (or instead of) the provider pattern.
        results += probeServiceManager()

        BydLogger.i(TAG, "BydConnectionProbe: ${results.size} attempts complete")

        return mapOf(
            "authority" to AUTHORITY,
            "ifaceCandidates" to IFACE_CANDIDATES,
            "attemptCount" to results.size,
            "attempts" to results,
        )
    }

    private fun probeProviderMetadata(ctx: Context): Map<String, Any?> {
        val pm = ctx.packageManager
        val info = try {
            pm.resolveContentProvider(AUTHORITY, 0)
        } catch (_: Throwable) { null }

        return if (info == null) {
            mapOf(
                "phase" to "provider_metadata",
                "ok" to false,
                "summary" to "resolveContentProvider returned null",
            )
        } else {
            mapOf(
                "phase" to "provider_metadata",
                "ok" to true,
                "summary" to "provider resolved",
                "packageName" to info.packageName,
                "className" to info.name,
                "processName" to info.processName,
                "readPermission" to info.readPermission,
                "writePermission" to info.writePermission,
                "exported" to info.exported,
                "multiprocess" to info.multiprocess,
                "grantUriPermissions" to info.grantUriPermissions,
            )
        }
    }

    private fun probeQuery(ctx: Context, uri: Uri, projection: Array<String>?): Map<String, Any?> {
        val attempt = mutableMapOf<String, Any?>(
            "phase" to "query",
            "uri" to uri.toString(),
            "projection" to (projection?.toList() ?: listOf("null")),
        )

        val cursor: Cursor? = try {
            ctx.contentResolver.query(uri, projection, null, null, null)
        } catch (t: Throwable) {
            attempt["ok"] = false
            attempt["summary"] = "threw: ${t.javaClass.simpleName}: ${t.message?.take(180)}"
            return attempt
        }

        if (cursor == null) {
            attempt["ok"] = false
            attempt["summary"] = "cursor=null"
            return attempt
        }

        try {
            attempt["rowCount"] = cursor.count
            attempt["columnCount"] = cursor.columnCount
            attempt["columnNames"] = try { cursor.columnNames.toList() } catch (_: Throwable) { emptyList<String>() }

            val extras: Bundle? = cursor.extras
            if (extras == null) {
                attempt["ok"] = false
                attempt["summary"] = "cursor=ok, extras=null"
                return attempt
            }

            val keys = try { extras.keySet().toList() } catch (_: Throwable) { emptyList<String>() }
            attempt["extrasKeys"] = keys
            // For each candidate key, see if there's a Parcelable under
            // it and whether we can pull an IBinder out.
            val keyReports = mutableListOf<Map<String, Any?>>()
            for (k in (EXTRAS_KEYS + keys).distinct()) {
                val v: Any? = try { extras.get(k) } catch (_: Throwable) { null }
                if (v == null) continue
                val report = mutableMapOf<String, Any?>(
                    "key" to k,
                    "valueClass" to v.javaClass.name,
                )
                if (v is Parcelable) {
                    val m = BydReflection.method(v.javaClass, "getBinder")
                    if (m != null) {
                        try {
                            val b = m.invoke(v) as? IBinder
                            report["binderExtracted"] = (b != null)
                            if (b != null) {
                                report["binderAlive"] = b.isBinderAlive
                                report["binderClass"] = b.javaClass.name
                                report["binderInterfaceDescriptor"] = try {
                                    b.interfaceDescriptor
                                } catch (_: Throwable) { null }
                            }
                        } catch (t: Throwable) {
                            report["binderError"] = "${t.javaClass.simpleName}: ${t.message?.take(140)}"
                        }
                    } else {
                        report["binderExtracted"] = false
                        report["binderError"] = "no getBinder() method on ${v.javaClass.simpleName}"
                    }
                } else if (v is IBinder) {
                    report["binderExtracted"] = true
                    report["binderAlive"] = v.isBinderAlive
                    report["binderClass"] = v.javaClass.name
                }
                keyReports += report
            }
            attempt["keyReports"] = keyReports

            val gotBinder = keyReports.any { it["binderExtracted"] == true }
            attempt["ok"] = gotBinder
            attempt["summary"] = if (gotBinder) "binder extracted" else "no binder in extras"
        } finally {
            try { cursor.close() } catch (_: Throwable) {}
        }
        return attempt
    }

    private fun probeCall(ctx: Context, uri: Uri, method: String, arg: String): Map<String, Any?> {
        val attempt = mutableMapOf<String, Any?>(
            "phase" to "call",
            "uri" to uri.toString(),
            "method" to method,
            "arg" to arg,
        )

        val result: Bundle? = try {
            ctx.contentResolver.call(uri, method, arg, null)
        } catch (t: Throwable) {
            attempt["ok"] = false
            attempt["summary"] = "threw: ${t.javaClass.simpleName}: ${t.message?.take(180)}"
            return attempt
        }

        if (result == null) {
            attempt["ok"] = false
            attempt["summary"] = "bundle=null"
            return attempt
        }

        val keys = try { result.keySet().toList() } catch (_: Throwable) { emptyList<String>() }
        attempt["bundleKeys"] = keys

        val keyReports = mutableListOf<Map<String, Any?>>()
        for (k in (EXTRAS_KEYS + keys).distinct()) {
            val v: Any? = try { result.get(k) } catch (_: Throwable) { null }
            if (v == null) continue
            val report = mutableMapOf<String, Any?>(
                "key" to k,
                "valueClass" to v.javaClass.name,
            )
            if (v is Parcelable) {
                val m = BydReflection.method(v.javaClass, "getBinder")
                if (m != null) {
                    try {
                        val b = m.invoke(v) as? IBinder
                        report["binderExtracted"] = (b != null)
                        if (b != null) {
                            report["binderAlive"] = b.isBinderAlive
                            report["binderClass"] = b.javaClass.name
                        }
                    } catch (t: Throwable) {
                        report["binderError"] = "${t.javaClass.simpleName}: ${t.message?.take(140)}"
                    }
                }
            } else if (v is IBinder) {
                report["binderExtracted"] = true
                report["binderAlive"] = v.isBinderAlive
                report["binderClass"] = v.javaClass.name
            }
            keyReports += report
        }
        attempt["keyReports"] = keyReports

        val gotBinder = keyReports.any { it["binderExtracted"] == true }
        attempt["ok"] = gotBinder
        attempt["summary"] = if (gotBinder) "binder extracted via call" else "no binder in bundle"
        return attempt
    }

    /**
     * Probe `android.os.ServiceManager.getService(String)` via reflection.
     * This is a hidden API but accessible via reflection for read-only
     * lookups. If carserver also registers its services in the system
     * service table, this gives us a binder directly — no provider needed.
     */
    private fun probeServiceManager(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "phase" to "servicemanager",
        )

        val smCls = try { Class.forName("android.os.ServiceManager") } catch (t: Throwable) {
            out["ok"] = false
            out["summary"] = "ServiceManager class not loadable: ${t.message?.take(120)}"
            return out
        }

        // Try listServices first to see what's registered.
        val knownServices: List<String> = try {
            val m = smCls.getMethod("listServices")
            @Suppress("UNCHECKED_CAST")
            val arr = m.invoke(null) as? Array<String>
            arr?.toList() ?: emptyList()
        } catch (_: Throwable) { emptyList() }

        // Filter the list for anything that smells of "car", "byd", "property", "vehicle".
        val carlike = knownServices.filter { s ->
            val l = s.lowercase()
            l.contains("car") || l.contains("byd") || l.contains("property") ||
            l.contains("vehicle") || l.contains("hal")
        }
        out["carlikeServices"] = carlike
        out["totalServicesVisible"] = knownServices.size

        // Try a handful of common names directly.
        val tryNames = listOf(
            "car_property", "car_service", "car",
            "byd_car_property", "byd_property", "byd_car", "bydauto",
            "vehicle.car.property", "car.property.ICarPropertyService",
            "ICarPropertyService",
        )
        val results = mutableListOf<Map<String, Any?>>()
        val getService = try { smCls.getMethod("getService", String::class.java) } catch (_: Throwable) { null }
        if (getService == null) {
            out["ok"] = false
            out["summary"] = "ServiceManager.getService method not accessible (likely hidden)"
            return out
        }
        for (n in tryNames + carlike) {
            try {
                val b = getService.invoke(null, n) as? IBinder
                if (b != null) {
                    results += mapOf(
                        "name" to n,
                        "found" to true,
                        "binderClass" to b.javaClass.name,
                        "interfaceDescriptor" to (try { b.interfaceDescriptor } catch (_: Throwable) { null }),
                        "alive" to b.isBinderAlive,
                    )
                }
            } catch (_: Throwable) {
                // skip — bad names are noise
            }
        }
        out["foundServices"] = results
        out["ok"] = results.isNotEmpty()
        out["summary"] = if (results.isEmpty())
            "no relevant services in ServiceManager (${knownServices.size} total visible)"
        else "${results.size} service binders found"
        return out
    }

    /**
     * Render the probe report as a human-friendly text dump — used by
     * the UI's "copy to clipboard" feature. Keep it newline-delimited
     * and grep-able.
     */
    fun renderReport(report: Map<String, Any?>): String {
        val sb = StringBuilder()
        sb.appendLine("=== BZ5 Companion: Connection Probe ===")
        sb.appendLine("Captured: ${java.time.Instant.now()}")
        sb.appendLine("Authority: ${report["authority"]}")
        sb.appendLine("Total attempts: ${report["attemptCount"]}")
        sb.appendLine()
        @Suppress("UNCHECKED_CAST")
        val attempts = report["attempts"] as? List<Map<String, Any?>> ?: emptyList()
        // Group by phase for readability.
        for ((phase, group) in attempts.groupBy { it["phase"] }) {
            sb.appendLine("--- $phase (${group.size}) ---")
            for (a in group) {
                val ok = a["ok"] == true
                val mark = if (ok) "✓" else "✗"
                val summary = a["summary"] ?: ""
                val locator = when (phase) {
                    "query" -> "${a["uri"]} ⟵ ${a["projection"]}"
                    "call"  -> "${a["uri"]} method=${a["method"]} arg=${a["arg"]}"
                    "servicemanager" -> "ServiceManager"
                    "provider_metadata" -> "providerInfo"
                    else -> ""
                }
                sb.append("  $mark $locator — $summary")
                if (a["rowCount"] != null) sb.append(" [rows=${a["rowCount"]}]")
                if (a["extrasKeys"] != null) sb.append(" extras=${a["extrasKeys"]}")
                sb.appendLine()
                @Suppress("UNCHECKED_CAST")
                val kr = a["keyReports"] as? List<Map<String, Any?>> ?: emptyList()
                for (r in kr) {
                    sb.append("      key='${r["key"]}' cls=${r["valueClass"]}")
                    if (r["binderExtracted"] == true) sb.append(" → BINDER (${r["binderClass"]}, alive=${r["binderAlive"]})")
                    if (r["binderError"] != null) sb.append(" → err=${r["binderError"]}")
                    sb.appendLine()
                }
                @Suppress("UNCHECKED_CAST")
                val found = a["foundServices"] as? List<Map<String, Any?>>
                if (found != null) {
                    for (f in found) sb.appendLine("      service ${f["name"]} → ${f["binderClass"]}")
                }
                @Suppress("UNCHECKED_CAST")
                val carlike = a["carlikeServices"] as? List<String>
                if (carlike != null && carlike.isNotEmpty()) {
                    sb.appendLine("      car-like names visible: ${carlike.joinToString(", ")}")
                }
            }
            sb.appendLine()
        }
        return sb.toString()
    }
}
