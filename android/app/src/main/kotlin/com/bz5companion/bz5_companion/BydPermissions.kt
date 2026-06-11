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
 *  3. **Per-domain BYDAUTO_*_GET variants**: present on newer BYD
 *     firmware where Read and Write got split into separate
 *     permissions. CanDataCollect.apk declared `BYDAUTO_POWER_GET`
 *     specifically (not _COMMON), so the convention is inconsistent
 *     across domains. We declare both variants in the manifest for
 *     the domains where the inconsistency was observed.
 *
 * v0.1.26+14: catalog expanded from 17 to 24 entries to match the
 * manifest. Previously the Native Explorer would report "1 / 17
 * declared (of 17 known)" while the manifest had 24 declared — the
 * extra 7 (`_GET` variants + vehicle_data + bigdata) were invisible
 * to the UI. Now the count is honest.
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
        "com.byd.car.server.PROVIDER"                  to "Car server provider (bind)",
        // _COMMON variants — historical naming.
        "android.permission.BYDAUTO_POWER_COMMON"      to "Power & ignition (R/W)",
        "android.permission.BYDAUTO_CHARGING_COMMON"   to "Charging session (R/W)",
        "android.permission.BYDAUTO_ENERGY_COMMON"     to "Battery / energy (R/W)",
        "android.permission.BYDAUTO_SPEED_COMMON"      to "Vehicle speed (R/W)",
        "android.permission.BYDAUTO_GEARBOX_COMMON"    to "Gearbox state (R/W)",
        "android.permission.BYDAUTO_INSTRUMENT_COMMON" to "Instrument cluster",
        "android.permission.BYDAUTO_TYRE_COMMON"       to "Tyre pressure",
        "android.permission.BYDAUTO_STATISTIC_COMMON"  to "Vehicle statistics (R/W)",
        "android.permission.BYDAUTO_LOCATION_COMMON"   to "Vehicle location",
        "android.permission.BYDAUTO_BODYWORK_COMMON"   to "VIN / body data",
        "android.permission.BYDAUTO_DTC_COMMON"        to "Diagnostic codes",
        "android.permission.BYDAUTO_LIGHTS_COMMON"     to "Lights state",
        "android.permission.BYDAUTO_DOORLOCK_COMMON"   to "Door lock state",
        "android.permission.BYDAUTO_TIME_COMMON"       to "Vehicle clock",
        "android.permission.BYDAUTO_TEST_COMMON"       to "Factory test channel",
        "android.permission.BYDAUTO_VERSION_COMMON"    to "Software version info",
        // _GET variants — used on firmware revisions where R/W is
        // split. v0.1.26+15: empirical test on a real BZ5 showed
        // BYDAUTO_BODYWORK_GET is required for Bodywork.getDataFlag()
        // (line 2201) AFTER _COMMON grants. So the two-layer gating
        // is real and per-domain. We now declare _GET for all 18
        // domains — the system silently ignores names that don't exist
        // on this particular firmware.
        "android.permission.BYDAUTO_POWER_GET"            to "Power & ignition (R only)",
        "android.permission.BYDAUTO_CHARGING_GET"         to "Charging session (R only)",
        "android.permission.BYDAUTO_ENERGY_GET"           to "Battery / energy (R only)",
        "android.permission.BYDAUTO_SPEED_GET"            to "Vehicle speed (R only)",
        "android.permission.BYDAUTO_GEARBOX_GET"          to "Gearbox state (R only)",
        "android.permission.BYDAUTO_INSTRUMENT_GET"       to "Instrument cluster (R only)",
        "android.permission.BYDAUTO_TYRE_GET"             to "Tyre pressure (R only)",
        "android.permission.BYDAUTO_STATISTIC_GET"        to "Vehicle statistics (R only)",
        "android.permission.BYDAUTO_LOCATION_GET"         to "Vehicle location (R only)",
        "android.permission.BYDAUTO_BODYWORK_GET"         to "VIN / body data (R only)",
        "android.permission.BYDAUTO_DTC_GET"              to "Diagnostic codes (R only)",
        "android.permission.BYDAUTO_LIGHTS_GET"           to "Lights state (R only)",
        "android.permission.BYDAUTO_DOORLOCK_GET"         to "Door lock state (R only)",
        "android.permission.BYDAUTO_TIME_GET"             to "Vehicle clock (R only)",
        "android.permission.BYDAUTO_TEST_GET"             to "Factory test channel (R only)",
        "android.permission.BYDAUTO_VERSION_GET"          to "Software version info (R only)",
        // Newer / specialised domains.
        "android.permission.BYDAUTO_VEHICLE_DATA_COMMON"  to "Vehicle data (CAN frame stream)",
        "android.permission.BYDAUTO_BIGDATA_COMMON"       to "Big data / register tables",
        "android.permission.BYDAUTO_VEHICLE_DATA_GET"     to "Vehicle data (R only)",
        "android.permission.BYDAUTO_BIGDATA_GET"          to "Big data (R only)",
        // v0.1.29+66: AC domain — the one _COMMON we never declared.
        // Field-confirmed missing on 2026-06-11 (HAL Test: AcDevice
        // getInstance SecurityException naming BYDAUTO_AC_COMMON).
        "android.permission.BYDAUTO_AC_COMMON"            to "Climate / AC state (R/W)",
        "android.permission.BYDAUTO_AC_GET"               to "Climate / AC state (R only)",
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
