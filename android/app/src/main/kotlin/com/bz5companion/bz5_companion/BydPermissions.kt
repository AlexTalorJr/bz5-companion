package com.bz5companion.bz5_companion

import android.content.Context
import android.content.pm.PackageManager

/**
 * Catalog and runtime status of BYD car-platform permissions the app
 * uses (or might want to use).
 *
 * Three groups:
 *
 *  1. **Provider bind permission** (`com.byd.car.server.PROVIDER`,
 *     protectionLevel="normal"): granted at install time as long as
 *     the app declares `<uses-permission>` for it. Without this you
 *     can still open a ContentProvider in the abstract, but accessing
 *     the BinderProvider's binder will be refused by SecurityException.
 *
 *  2. **Per-domain BYDAUTO_*_COMMON permissions** (protectionLevel="dangerous"
 *     on most builds): runtime-grant required. Each AbsBYDAutoDevice
 *     reports its required read/write permission via `getGetPermission()`
 *     / `getSetPermission()` — they map 1:1 with these.
 *
 *  3. **Legacy / always-on**: storage permissions used by the snapshot
 *     export feature (already declared by the BLE codebase).
 *
 * The list below is what we currently care about. As we discover new
 * features whose `getGetPermission()` reports something not here, add
 * it — uncovered permissions silently fail at runtime, so it's worth
 * keeping this set complete.
 *
 * NB: this list is empirical. The exact "permission name → which
 * features it gates" mapping needs to be verified on a real BYD car.
 * The names were chosen by inspecting AbsBYDAutoDevice subclass
 * getGetPermission()/getSetPermission() in carserver.apk; if any of
 * these turn out to be wrong they'll show up as runtime denials in
 * logs (the property client logs the permission name from the
 * SecurityException).
 */
object BydPermissions {

    /** Permission name → human label, for the runtime-grant UI. */
    val PERMISSIONS: Map<String, String> = linkedMapOf(
        "com.byd.car.server.PROVIDER"             to "Car server provider (bind)",
        "android.permission.BYDAUTO_POWER_COMMON"    to "Power & ignition state",
        "android.permission.BYDAUTO_CHARGING_COMMON" to "Charging session",
        "android.permission.BYDAUTO_ENERGY_COMMON"   to "Battery / energy",
        "android.permission.BYDAUTO_SPEED_COMMON"    to "Vehicle speed",
        "android.permission.BYDAUTO_GEARBOX_COMMON"  to "Gearbox state",
        "android.permission.BYDAUTO_INSTRUMENT_COMMON" to "Instrument cluster",
        "android.permission.BYDAUTO_TYRE_COMMON"     to "Tyre pressure",
        "android.permission.BYDAUTO_STATISTIC_COMMON" to "Vehicle statistics",
        "android.permission.BYDAUTO_LOCATION_COMMON" to "Vehicle location",
        "android.permission.BYDAUTO_BODYWORK_COMMON" to "VIN / body data",
        "android.permission.BYDAUTO_DTC_COMMON"      to "Diagnostic codes",
        "android.permission.BYDAUTO_LIGHTS_COMMON"   to "Lights state",
        "android.permission.BYDAUTO_DOORLOCK_COMMON" to "Door lock state",
        "android.permission.BYDAUTO_TIME_COMMON"     to "Vehicle clock",
        "android.permission.BYDAUTO_TEST_COMMON"     to "Factory test channel",
        "android.permission.BYDAUTO_VERSION_COMMON"  to "Software version info",
    )

    /**
     * The dangerous-level permissions that must be runtime-requested.
     * Caller code should pass these to ActivityCompat.requestPermissions(...).
     */
    val DANGEROUS: List<String> = PERMISSIONS.keys
        .filter { it.startsWith("android.permission.BYDAUTO_") }

    /**
     * Report each permission's current state: declared in the merged
     * manifest, and granted at the OS level. Returns a list of maps
     * suitable for direct passing to Flutter.
     */
    fun declaredAndGranted(ctx: Context): List<Map<String, Any?>> {
        val pm = ctx.packageManager
        val pkg = ctx.packageName

        // Collect what the manifest actually declared. We use this to
        // distinguish "the app forgot to add <uses-permission>" from
        // "the OS denied a runtime grant".
        val declared: Set<String> = try {
            val info = pm.getPackageInfo(pkg, PackageManager.GET_PERMISSIONS)
            (info.requestedPermissions?.toSet()) ?: emptySet()
        } catch (_: Throwable) {
            emptySet()
        }

        return PERMISSIONS.map { (perm, label) ->
            val isDangerous = perm.startsWith("android.permission.BYDAUTO_")
            val grantedAtOs = ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
            mapOf(
                "permission" to perm,
                "label"      to label,
                "declared"   to (perm in declared),
                "granted"    to grantedAtOs,
                "dangerous"  to isDangerous,
            )
        }
    }
}
