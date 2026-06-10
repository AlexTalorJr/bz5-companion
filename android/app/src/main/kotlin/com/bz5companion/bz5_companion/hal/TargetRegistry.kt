// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TargetRegistry.kt
// Synced: 2026-06-10 (recon v0.10.53, commit d37fbbc)
// SHA256: b4668fd0d09c4566d935af5c23483401ac40b9393290d6e3e8538a8097991552
package com.bz5companion.bz5_companion.hal

import android.content.Context

// === SHARED CANDIDATE (bz5_recon ↔ bz5_companion) ===
// File: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TargetRegistry.kt
// Owner: bz5_recon (patch 068)
// Sync method: copy-paste with checksum header.
//
// defaultTargets(ctx) — full 26-target list as seen in patch 067
// (TelemetryStateProbe.tryRegisterListener). Used by bz5_recon LiveMonitorService.
//
// streamingTargets(ctx) — 8-target subset for bz5_companion HAL data source:
// Statistic, Charging, Energy, Engine, Gearbox, Ac, Tyre, Radar. Excludes
// research-only (BigData sweep), silent-on-BZ5 (VehicleData, Motor, Sensor,
// Collision, VehicleHealth), and *_priority duplicate targets — companion
// doesn't need overlapping subscriptions.

/** Description of one push-channel target. Immutable. */
data class TargetSpec(
    /** Unique key used in callbacks and JSON output (e.g. "BYDAutoEngineDevice"). */
    val key: String,
    /** Fully qualified device class name. */
    val deviceClassName: String,
    /** Feature IDs to subscribe to via registerListener(listener, fids). */
    val featureIds: IntArray
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TargetSpec) return false
        return key == other.key && deviceClassName == other.deviceClassName &&
                featureIds.contentEquals(other.featureIds)
    }
    override fun hashCode(): Int {
        var h = key.hashCode()
        h = 31 * h + deviceClassName.hashCode()
        h = 31 * h + featureIds.contentHashCode()
        return h
    }
}

object TargetRegistry {

    private const val TAG = "TargetRegistry"

    /** Resolve feature IDs by category prefix from `BYDAutoFeatureIds`. */
    private fun namedIdsByPrefix(featureIdsCls: Class<*>?, prefix: String): Map<String, Int> {
        if (featureIdsCls == null) return emptyMap()
        return try {
            featureIdsCls.fields
                .filter { it.name.startsWith(prefix) && it.type == Int::class.javaPrimitiveType }
                .mapNotNull { f -> runCatching { f.name to f.getInt(null) }.getOrNull() }
                .toMap()
        } catch (_: Throwable) { emptyMap() }
    }

    /** Resolve feature IDs from an inner class by simpleName. */
    private fun fidsByInnerClassSimpleName(featureIdsCls: Class<*>?, simpleName: String): Map<String, Int> {
        if (featureIdsCls == null) return emptyMap()
        return try {
            val inner = featureIdsCls.declaredClasses.firstOrNull { it.simpleName == simpleName }
                ?: return emptyMap()
            inner.declaredFields
                .filter {
                    java.lang.reflect.Modifier.isStatic(it.modifiers) &&
                            it.type == Int::class.javaPrimitiveType
                }
                .mapNotNull { f ->
                    runCatching {
                        f.isAccessible = true
                        f.name to f.getInt(null)
                    }.getOrNull()
                }
                .toMap()
        } catch (_: Throwable) { emptyMap() }
    }

    private fun pickReadOnlyIds(map: Map<String, Int>, cap: Int): IntArray =
        map.entries
            .filter { !it.key.endsWith("_SET") }
            .map { it.value }
            .sorted()
            .take(cap)
            .toIntArray()

    /**
     * Full 26-target list as used by [com.bz5.recon.probes.TelemetryStateProbe]
     * in patch 067. Returned list size depends on which inner classes /
     * prefixes resolve against the device's BYDAutoFeatureIds.
     *
     * Includes BigData sweep, *_priority explicit-fid duplicates, and silent
     * devices (Motor/Sensor/Collision/VehicleData/VehicleHealth) for negative
     * intel — they cost very little (zero callbacks) and confirm framework
     * dispatch is the silencer, not our code.
     */
    @Suppress("LongMethod")
    fun defaultTargets(ctx: Context): List<TargetSpec> {
        val featureIdsCls = try {
            Class.forName("android.hardware.bydauto.BYDAutoFeatureIds")
        } catch (_: Throwable) { null }

        val targets = mutableListOf<TargetSpec>()

        // Original Power / BigData / Statistic / VehicleData targets — fid lists
        // baked from patches 046–050. Do not pull from featureIdsCls because
        // these are explicit canDataCollect-derived lists.
        targets.add(TargetSpec(
            "BYDAutoPowerDevice_canDataCollect",
            "android.hardware.bydauto.power.BYDAutoPowerDevice",
            intArrayOf(0x99000037.toInt(), 0x99000003.toInt())
        ))
        targets.add(TargetSpec(
            "BYDAutoPowerDevice_sweep",
            "android.hardware.bydauto.power.BYDAutoPowerDevice",
            (0x99000001..0x99000050).map { it.toInt() }.toIntArray()
        ))
        targets.add(TargetSpec(
            "BYDAutoBigDataDevice_canDataCollect",
            "android.hardware.bydauto.bigdata.BYDAutoBigDataDevice",
            intArrayOf(0x99000020.toInt())
        ))
        targets.add(TargetSpec(
            "BYDAutoBigDataDevice_sweep",
            "android.hardware.bydauto.bigdata.BYDAutoBigDataDevice",
            (0x99000010..0x99000030)
                .map { it.toInt() }
                .filter { it != 0x99000020.toInt() }
                .toIntArray()
        ))

        val statisticNamedIds = namedIdsByPrefix(featureIdsCls, "STATISTIC_")
        val statisticIdsForSub: IntArray = if (statisticNamedIds.isNotEmpty()) {
            statisticNamedIds.values.sorted().take(64).toIntArray()
        } else {
            intArrayOf(0x99000191.toInt())
        }
        targets.add(TargetSpec(
            "BYDAutoStatisticDevice",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            statisticIdsForSub
        ))
        targets.add(TargetSpec(
            "BYDAutoVehicleDataDevice_narrow",
            "android.hardware.bydauto.vehicledata.BYDAutoVehicleDataDevice",
            intArrayOf(
                0x99000001.toInt(), 0x99000002.toInt(), 0x99000004.toInt(),
                0x99000005.toInt(), 0x99000006.toInt()
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoVehicleDataDevice_sweep",
            "android.hardware.bydauto.vehicledata.BYDAutoVehicleDataDevice",
            (0x99000007..0x99000030).map { it.toInt() }.toIntArray()
        ))

        // COMMON-granted device categories — prefix-based fid harvest.
        val chargingNamedIds   = namedIdsByPrefix(featureIdsCls, "CHARGING_")
        val energyNamedIds     = namedIdsByPrefix(featureIdsCls, "ENERGY_")
        val gearboxNamedIds    = namedIdsByPrefix(featureIdsCls, "GEARBOX_")
        val tyreNamedIds       = namedIdsByPrefix(featureIdsCls, "TYRE_")
        val timeNamedIds       = namedIdsByPrefix(featureIdsCls, "TIME_")
        val instrumentNamedIds = namedIdsByPrefix(featureIdsCls, "INSTRUMENT_")
        val acNamedIds         = namedIdsByPrefix(featureIdsCls, "AC_")
        val dtcNamedIds        = fidsByInnerClassSimpleName(featureIdsCls, "Dtc")

        // Patch 066 — 6 NEW devices via generic Proxy. Inner-class lookup
        // robust against prefix variations.
        val motorNamedIds         = fidsByInnerClassSimpleName(featureIdsCls, "Motor")
        val engineNamedIds        = fidsByInnerClassSimpleName(featureIdsCls, "Engine")
        val sensorNamedIds        = fidsByInnerClassSimpleName(featureIdsCls, "Sensor")
        val collisionNamedIds     = fidsByInnerClassSimpleName(featureIdsCls, "Collision")
        val radarNamedIds         = fidsByInnerClassSimpleName(featureIdsCls, "Radar")
        val vehicleHealthNamedIds = fidsByInnerClassSimpleName(featureIdsCls, "VehicleHealth")

        if (chargingNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoChargingDevice",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            pickReadOnlyIds(chargingNamedIds, 80)))
        if (energyNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoEnergyDevice",
            "android.hardware.bydauto.energy.BYDAutoEnergyDevice",
            pickReadOnlyIds(energyNamedIds, 33)))
        if (gearboxNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoGearboxDevice",
            "android.hardware.bydauto.gearbox.BYDAutoGearboxDevice",
            pickReadOnlyIds(gearboxNamedIds, 12)))
        if (tyreNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoTyreDevice",
            "android.hardware.bydauto.tyre.BYDAutoTyreDevice",
            pickReadOnlyIds(tyreNamedIds, 42)))
        if (timeNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoTimeDevice",
            "android.hardware.bydauto.time.BYDAutoTimeDevice",
            pickReadOnlyIds(timeNamedIds, 44)))
        if (instrumentNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoInstrumentDevice",
            "android.hardware.bydauto.instrument.BYDAutoInstrumentDevice",
            pickReadOnlyIds(instrumentNamedIds, 80)))
        if (acNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoAcDevice",
            "android.hardware.bydauto.ac.BYDAutoAcDevice",
            pickReadOnlyIds(acNamedIds, 80)))
        if (dtcNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoDtcDevice",
            "android.hardware.bydauto.dtc.BYDAutoDtcDevice",
            pickReadOnlyIds(dtcNamedIds, 8)))

        // Patch 066 — 6 new generic-Proxy devices.
        if (motorNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoMotorDevice",
            "android.hardware.bydauto.motor.BYDAutoMotorDevice",
            pickReadOnlyIds(motorNamedIds, 32)))
        if (engineNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoEngineDevice",
            "android.hardware.bydauto.engine.BYDAutoEngineDevice",
            pickReadOnlyIds(engineNamedIds, 32)))
        if (sensorNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoSensorDevice",
            "android.hardware.bydauto.sensor.BYDAutoSensorDevice",
            pickReadOnlyIds(sensorNamedIds, 32)))
        if (collisionNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoCollisionDevice",
            "android.hardware.bydauto.collision.BYDAutoCollisionDevice",
            pickReadOnlyIds(collisionNamedIds, 32)))
        if (radarNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoRadarDevice",
            "android.hardware.bydauto.radar.BYDAutoRadarDevice",
            pickReadOnlyIds(radarNamedIds, 32)))
        if (vehicleHealthNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoVehicleHealthDevice",
            "android.hardware.bydauto.vehiclehealth.BYDAutoVehicleHealthDevice",
            pickReadOnlyIds(vehicleHealthNamedIds, 32)))

        // Statistic tail — fids 65..N if catalog > 64.
        if (statisticNamedIds.size > 64) {
            val tailIds = statisticNamedIds.values.sorted().drop(64).toIntArray()
            if (tailIds.isNotEmpty()) targets.add(TargetSpec(
                "BYDAutoStatisticDevice_tail",
                "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
                tailIds
            ))
        }

        // ─── *_priority explicit-fid targets (patch 058) ────────────────────
        // Duplicate subscriptions to known high-value fids on Energy / Charging /
        // Statistic — guarantees coverage of decoded params even if listener
        // doesn't deliver for sort-by-int top-N.
        targets.add(TargetSpec(
            "BYDAutoEnergyDevice_priority",
            "android.hardware.bydauto.energy.BYDAutoEnergyDevice",
            intArrayOf(
                0x45400008.toInt(), 0x45400010.toInt(), 0x45400028.toInt(), 0x45400030.toInt(),
                0x000D4B3F.toInt(), 0x00062686.toInt(), 0x000D7696.toInt(), 0x2610001F.toInt(),
                0x0009B8E6.toInt(), 0x000DA09B.toInt(), 0x000F33B4.toInt(),
                0x20800018.toInt(), 0x2120040E.toInt()
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoChargingDevice_priority",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            intArrayOf(
                0x2D300008.toInt(), 0x2D300018.toInt(), 0x1AC01010.toInt(), 0x000B95EC.toInt(),
                0x000B4C9A.toInt(), 0x000C1311.toInt(), 0x2EB00838.toInt(), 0x2FF00030.toInt(),
                0x0A50000D.toInt(), 0x2EB00832.toInt(), 0x2C100818.toInt(),
                0x46C00808.toInt(), 0x46C00818.toInt()
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoStatisticDevice_priority",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            intArrayOf(
                0x2D300030.toInt(), 0x0005F84D.toInt(), 0x000FF694.toInt(), 0x44500830.toInt(),
                0x49502010.toInt(), 0x49507028.toInt(), 0x49505038.toInt(), 0x000EF358.toInt(),
                0x0006A408.toInt(), 0x00090D49.toInt(), 0x000A4490.toInt(), 0x00049367.toInt(),
                0x000C4B18.toInt(), 0x00040A7D.toInt(), 0x000CCE5F.toInt(), 0x47300018.toInt(),
                0x15100008.toInt()
            )
        ))
        if (tyreNamedIds.isNotEmpty()) {
            val tyrePriority = tyreNamedIds.entries
                .filter { it.key.startsWith("TYRE_PRESSURE_VALUE_") || it.key.startsWith("TYRE_TEMPERATURE_VALUE_") }
                .map { it.value }
                .toIntArray()
            if (tyrePriority.isNotEmpty()) targets.add(TargetSpec(
                "BYDAutoTyreDevice_priority",
                "android.hardware.bydauto.tyre.BYDAutoTyreDevice",
                tyrePriority
            ))
        }
        if (dtcNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoDtcDevice_v2",
            "android.hardware.bydauto.dtc.BYDAutoDtcDevice",
            dtcNamedIds.values.toIntArray()
        ))

        return targets
    }

    /**
     * Minimal subset for bz5_companion HAL data source. 8 targets covering
     * the parameters companion's UI cards / Trends tab actually consume:
     *
     * | Target      | Decoded values                                              |
     * | ----------- | ----------------------------------------------------------- |
     * | Statistic   | speed (0x15100008), odometer, AUX 12V, trip A/B, SOC, SOH   |
     * | Charging    | pack voltage, pack current                                  |
     * | Energy      | cell V min/max + indices                                    |
     * | Engine      | motor RPM, inverter temp, motor torque, pack V cross-check  |
     * | Gearbox     | gear enum, brake toggle, clutch toggle                      |
     * | Ac          | fan speed, temp level, setpoint, mode toggles               |
     * | Tyre        | TPMS pressures + temps (4 wheels)                           |
     * | Radar       | 8 parking sensors (cm)                                      |
     *
     * EXCLUDED:
     *  - BigData (raw CAN dump — research only, companion has decoded
     *    paths above for everything it cares about)
     *  - VehicleData / Motor / Sensor / Collision / VehicleHealth (silent
     *    on BZ5 firmware per patch 066 — no callbacks ever delivered)
     *  - Sweep targets (debug only)
     *  - *_priority duplicates (full subscription above already covers them)
     */
    fun streamingTargets(ctx: Context): List<TargetSpec> {
        val featureIdsCls = try {
            Class.forName("android.hardware.bydauto.BYDAutoFeatureIds")
        } catch (_: Throwable) { null }

        val out = mutableListOf<TargetSpec>()

        // Statistic — top 64 prefix-named fids UNION the known-good high-value
        // fids that decode to confirmed parameters companion needs.
        //
        // BUGFIX (patch 073, raised by Друг 1): the previous version subscribed
        // only `take(64)` of the prefix-sorted catalog. Sorted by value, the
        // 0x495xxxxx block (odometer 0x49502010, trip_a 0x49503010, trip_b
        // 0x49503024, aux_12v 0x49507032) falls BEYOND the first 64 on this
        // device, so those four were never subscribed in companion — decode()
        // would return null forever. recon's defaultTargets() avoided this by
        // splitting a separate BYDAutoStatisticDevice_tail target; companion's
        // single Statistic target must instead UNION the priority fids in
        // explicitly. All arrive under targetKey "BYDAutoStatisticDevice".
        val statisticNamedIds = namedIdsByPrefix(featureIdsCls, "STATISTIC_")
        val statisticPriority = intArrayOf(
            0x15100008,             // speed
            0x47300018,             // insulation_resistance
            0x49502010,             // odometer
            0x49503010,             // trip_a
            0x49503024,             // trip_b
            0x49507032,             // aux_battery_12v
            0x99000191.toInt()      // battery_serial (bufdata)
        )
        val statisticIds: IntArray = if (statisticNamedIds.isNotEmpty()) {
            // top-64 prefix fids ∪ priority fids, deduplicated.
            (statisticNamedIds.values.sorted().take(64) + statisticPriority.toList())
                .toSortedSet()
                .toIntArray()
        } else {
            statisticPriority
        }
        out.add(TargetSpec(
            "BYDAutoStatisticDevice",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            statisticIds
        ))

        // Charging — explicit list (priority fids known from patch 058).
        out.add(TargetSpec(
            "BYDAutoChargingDevice",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            intArrayOf(
                0x2D300008.toInt(), 0x2D300018.toInt(), 0x2FF00030.toInt(),
                0x1AC01010.toInt(), 0x000B95EC.toInt(), 0x000B4C9A.toInt(),
                0x2EB00832.toInt(), 0x0A50000D.toInt(), 0x2C100818.toInt()
            )
        ))

        // Energy — cell voltage min/max + indices.
        out.add(TargetSpec(
            "BYDAutoEnergyDevice",
            "android.hardware.bydauto.energy.BYDAutoEnergyDevice",
            intArrayOf(
                0x45400008.toInt(), 0x45400010.toInt(),
                0x45400028.toInt(), 0x45400030.toInt(),
                0x20800018.toInt()
            )
        ))

        // Engine — RPM, temp, torque, pack V cross-check (patch 066 decode).
        val engineNamedIds = fidsByInnerClassSimpleName(featureIdsCls, "Engine")
        if (engineNamedIds.isNotEmpty()) out.add(TargetSpec(
            "BYDAutoEngineDevice",
            "android.hardware.bydauto.engine.BYDAutoEngineDevice",
            pickReadOnlyIds(engineNamedIds, 32)
        ))

        // Gearbox — gear, brake, clutch.
        val gearboxNamedIds = namedIdsByPrefix(featureIdsCls, "GEARBOX_")
        if (gearboxNamedIds.isNotEmpty()) out.add(TargetSpec(
            "BYDAutoGearboxDevice",
            "android.hardware.bydauto.gearbox.BYDAutoGearboxDevice",
            pickReadOnlyIds(gearboxNamedIds, 12)
        ))

        // AC — climate state (event-driven).
        val acNamedIds = namedIdsByPrefix(featureIdsCls, "AC_")
        if (acNamedIds.isNotEmpty()) out.add(TargetSpec(
            "BYDAutoAcDevice",
            "android.hardware.bydauto.ac.BYDAutoAcDevice",
            pickReadOnlyIds(acNamedIds, 80)
        ))

        // Tyre — pressures + temps per wheel.
        val tyreNamedIds = namedIdsByPrefix(featureIdsCls, "TYRE_")
        if (tyreNamedIds.isNotEmpty()) {
            val tyreIds = tyreNamedIds.entries
                .filter { it.key.startsWith("TYRE_PRESSURE_VALUE_") || it.key.startsWith("TYRE_TEMPERATURE_VALUE_") }
                .map { it.value }
                .toIntArray()
            if (tyreIds.isNotEmpty()) out.add(TargetSpec(
                "BYDAutoTyreDevice",
                "android.hardware.bydauto.tyre.BYDAutoTyreDevice",
                tyreIds
            ))
        }

        // Radar — 8 parking sensors.
        val radarNamedIds = fidsByInnerClassSimpleName(featureIdsCls, "Radar")
        if (radarNamedIds.isNotEmpty()) out.add(TargetSpec(
            "BYDAutoRadarDevice",
            "android.hardware.bydauto.radar.BYDAutoRadarDevice",
            pickReadOnlyIds(radarNamedIds, 32)
        ))

        return out
    }
}
