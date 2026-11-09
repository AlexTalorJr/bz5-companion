// === SHARED FROM bz5_recon — DO NOT EDIT (re-sync from recon) ===
// Source: bz5-recon/android/app/src/main/kotlin/com/bz5/recon/live/TargetRegistry.kt
// Synced: 2026-11-09 (recon v0.10.157.1, commit p157, b1b95ca)
// SHA256: eca553ac5ebab8eae580cc2c8e55ae7db8f61434d0aa8d07ae6befb46a8c3ff4
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
     * p157: like pickReadOnlyIds, but also drops legacy-format fids (top byte
     * 0x00, catalog kind "legacy"). Those are get()-only numbers: get() needs
     * the signature-level _GET permission we do not hold. None arrived on the
     * listener in the 06.11/07.11 exports, and p156 found the same for the
     * legacy numbers it removed. Inside a capped harvest they only burn
     * slots. Used by recon's Charging harvest, where 50 of the first 80 slots
     * went to legacy numbers and push fids such as CAP_STATE_AC/DC fell
     * outside the cap. Not used by streamingTargets.
     */
    private fun pickPushIds(map: Map<String, Int>, cap: Int): IntArray =
        map.entries
            .filter { !it.key.endsWith("_SET") && (it.value ushr 24) != 0 }
            .map { it.value }
            .distinct()
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
        // p156: POWER_LOW_VOLTAGE as its OWN registration, kept apart from the
        // two GB32960 regs above so it can never perturb the 0x99000020 BigData
        // stream they depend on. 12 V candidate — may be volts or a low-voltage
        // flag; raw_trace settles which. getInstance on Power succeeded 2026-06-11.
        targets.add(TargetSpec(
            "BYDAutoPowerDevice_lowvoltage",
            "android.hardware.bydauto.power.BYDAutoPowerDevice",
            intArrayOf(0x1CD0003D.toInt())
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

        // p157: the catalog spells ten read-only Statistic fids with an extra S
        // (STATISTICS_AVERAGE_INSTANT_EV_LAST_200M 0x35906010 and others). The
        // "STATISTIC_" prefix never matched them, so they were never subscribed.
        // Merged here so they fall into the head/tail split like the rest.
        val statisticNamedIds = namedIdsByPrefix(featureIdsCls, "STATISTIC_") +
            namedIdsByPrefix(featureIdsCls, "STATISTICS_").filterKeys { !it.endsWith("_SET") }
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

        // Patch 077 — exploratory Gb/Speed/Bodywork targets: CLOSED (patch 078).
        // Three sessions on 2026-06-11 proved all three are unreachable for an
        // untrusted app, and unlike the silent devices below they FAIL at
        // getInstance (logged errors every run, not zero-cost silence):
        //   BYDAutoGbDevice       → class_not_found (not in untrusted classpath)
        //   BYDAutoSpeedDevice    → SecurityException BYDAUTO_SPEED_GET
        //   BYDAutoBodyworkDevice → SecurityException BYDAUTO_BODYWORK_GET
        // The Bodywork push-channel hypothesis is refuted: the signature wall
        // sits on getInstance, so registerListener is never reached — the
        // _COMMON ≠ _GET escape does not apply here. Targets removed to keep
        // the run log clean. accelerator-pedal depth stays an OBD2-only path.

        // p157: push fids only, cap raised to 120 (catalog has 110 read-only
        // non-legacy CHARGING_ fids, so the whole class is covered). Brings in
        // CAP_STATE_AC/DC 0x4FB00020/18, AC_CHARGING_CURRENT_TYPE 0x44F00831,
        // BATTERRY_DEVICE_STATE 0x2EB00018, CHARGE_REST_TIME_DD 0x32300038,
        // STOP_QUANTITY_SETTING 0x2FF00828, LOW_POWER_CHARGING_INDICATION_SIGN
        // 0x2FF0081C, SMART_CHARGING_STATE 0x44900840, VTOV_DISCHARGE_QUANTITY
        // 0x2EB00820, DISCHARGE_STATE_VTOL 0x2F40080B and the rest.
        if (chargingNamedIds.isNotEmpty()) targets.add(TargetSpec(
            "BYDAutoChargingDevice",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            pickPushIds(chargingNamedIds, 120)))
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

        // (Patch 077 Gb/Speed/Bodywork target additions removed in patch 078 —
        //  see closure note above where their fid resolution used to live.)

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
                0x2610001F.toInt(),
                0x20800018.toInt(), 0x2120040E.toInt()
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoChargingDevice_priority",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            intArrayOf(
                0x2D300008.toInt(), 0x2D300018.toInt(), 0x1AC01010.toInt(), 0x2EB00838.toInt(), 0x2FF00030.toInt(),
                0x0A50000D.toInt(), 0x2EB00832.toInt(), 0x2C100818.toInt(),
                0x46C00808.toInt(), 0x46C00818.toInt(),
                // p085: 0x2FF00020 CHARGING_CHARGE_TEMPERATURE_CTL_STATE — battery-temp
                // candidate, never subscribed before. Charging harvest takes the first 80
                // fids by value, and this value (~805M) falls outside that slice, so it was
                // never reached via the prefix path. Forced here as an explicit priority fid.
                // Raw-traced in RollupSink to learn whether it carries a temperature value
                // or just a control-state enum (0/1/2) before any decoder is written.
                0x2FF00820.toInt(),
                // p156: energy-split / charge-metering fids (names from bZ5 catalog).
                // CHARGE_POWER_DD and AC_CHARGING_CURRENT stream only while charging;
                // IRON_BATTERY_POWER_MODE shows when DC-DC tops up the 12 V LFP.
                0x32300018.toInt(), 0x44F00833.toInt(), 0x44900842.toInt(),
                // p128: GB_INSULATION_ALARM, кадр 0x2FF байт 1 бит 2. Штатный
                // флаг тревоги по изоляции. Нужен вместо выдуманной «полосы
                // здоровья» 14..18 МОм: такой полосы я никогда не измерял и в
                // отчёты не писал. Порог по ГОСТ для пакета 451.7 В это
                // 100 Ом на вольт, то есть 0.045 МОм, замер 14.14 выше него в
                // сотни раз. Правильный признак это флаг плюс тренд, не полоса.
                0x2FF00012.toInt()
            )
        ))
        // ─── p128: приборный блок 0x495 и силовой блок 0x40A/0x3DB ─────────
        // Почему явным списком, а не через harvest. Instrument-подписка берёт
        // первые 80 фидов из 579 по возрастанию числа. Весь дисплейный блок
        // 0x495xxxxx по значению много больше и в эти 80 не попадает никогда.
        // То же с Gb-категорией: устройства Gb нет вовсе, её фиды не подписаны
        // ниоткуда. Проверено сверкой каталога с обоими списками подписки:
        // 22 фида из моего прошлого предложения уже подписаны, эти 16 нет.
        //
        // Что это даёт. Кадр 0x495 страничный, страницы 1..11. По каталогу:
        // стр.2 одометр, стр.5 средняя скорость и процент заряда на щитке,
        // стр.6 давление четырёх шин и единица давления, стр.7 расход и запас
        // хода, стр.8 мощность внешней зарядки, стр.9 температура ОЖ в
        // процентах, стр.10 температура четырёх шин, стр.11 пробег поездки.
        // Единицы берём с самого щитка, поэтому масштаб не надо угадывать.
        //
        // Метка: гипотеза. Имя из каталога говорит про смысл, но не про
        // масштаб и не про ширину. До логов с железа значениями не считаем.
        targets.add(TargetSpec(
            "BYDAutoInstrumentDevice_display",
            "android.hardware.bydauto.instrument.BYDAutoInstrumentDevice",
            intArrayOf(
                0x49502010.toInt(),  // TOTAL_MILEAGE          стр.2 одометр
                0x4950202B.toInt(),  // DD_MILEAGE_UNIT        стр.2 единица
                0x4950502C.toInt(),  // AVERAGE_SPEED          стр.5
                0x49506010.toInt(),  // LF_TYRE_PRESSURE       стр.6
                0x4950601C.toInt(),  // RF_TYRE_PRESSURE       стр.6
                0x49506028.toInt(),  // LB_TYRE_PRESSURE       стр.6
                0x49506034.toInt(),  // RB_TYRE_PRESSURE       стр.6
                0x49506040.toInt(),  // UNIT_PRESSURE          стр.6 единица
                0x49508010.toInt(),  // EXTERNAL_CHARGING_POWER стр.8
                0x49509018.toInt(),  // WATER_TEMP_METER_PERCENT стр.9
                0x4950A018.toInt(),  // LF_TYRE_TEMPERATURE    стр.10
                0x4950A024.toInt(),  // RF_TYRE_TEMPERATURE    стр.10
                0x4950A030.toInt(),  // LB_TYRE_TEMPERATURE    стр.10
                0x4950A03C.toInt(),  // RB_TYRE_TEMPERATURE    стр.10
                0x49503040.toInt(),  // DD_OUT_TEMP            стр.3 наружная
                0x4950B01C.toInt()   // CURRENT_JOURNEY_DRIVE_MILEAGE стр.11
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoEngineDevice_priority",
            "android.hardware.bydauto.engine.BYDAutoEngineDevice",
            intArrayOf(
                0x28A00008.toInt(),  // DRIVER_MOTOR_SPEED    обороты, кадр 0x28A байт 0
                0x28A00018.toInt(),  // DRIVER_MOTOR_TORQUE   момент, кадр 0x28A байт 2
                0x3DB00008.toInt(),  // DRIVER_MOTOR_CONTROL_TEMP  инвертор
                0x3DB00010.toInt(),  // DRIVER_MOTOR_TEMP          мотор
                0x15100020.toInt(),  // ENGINE_POWER          кадр 0x151 байт 3
                0x40A00010.toInt(),  // DRIVER_POWER          флаг, ширина 1 бит
                0x40A00011.toInt(),  // DRIVER_MOTOR_STATE    признак готовности
                0x40A00014.toInt(),  // GB_POWER_MOTOR_TEMP_STATE
                0x40A00015.toInt()   // GB_IPM_TEMP_STATE
            )
        ))
        targets.add(TargetSpec(
            "BYDAutoStatisticDevice_priority",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            intArrayOf(
                0x2D300030.toInt(), 0x44500830.toInt(),
                0x49502010.toInt(), 0x49507028.toInt(), 0x49505038.toInt(), 0x47300018.toInt(),
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

        // ─── p157: cross-device subscription experiments ───────────────────
        // Evidence so far: a fid arrives only on the device whose catalog class
        // owns its name. Odometer 0x49502010 sits in Instrument_display and in
        // Statistic_priority; in the 06.11/07.11 exports it came only via
        // Statistic (catalog name STATISTIC_TOTAL_MILEAGE), and both Instrument
        // targets show zero callbacks. Power gets zero callbacks too (no
        // POWER_COMMON grant). So the two fids below, owned by Instrument and Power, never reach us.
        // Each is registered on a granted device that already delivers fids
        // from the same CAN frame, as its own target, so callback_count and the
        // corpus key show the answer per experiment. Zero events = hypothesis
        // holds and the fid is out of reach; any event = cross-device works.
        //   0x1CD0003D POWER_LOW_VOLTAGE (Power): frame 0x1CD is BCM; Energy
        //     owns ENERGY_BCM_STATE 0x1CD00012, Charging owns
        //     CHARGING_SMART_CHARGING_STATE_2nd 0x1CD0001C. Volts or flag is
        //     settled from the corpus, where every event is kept raw.
        //   0x49503040 INSTRUMENT_DD_OUT_TEMP and 0x4950303F
        //     INSTRUMENT_UNIT_TEMPERATURE (Instrument): frame 0x495 page 3,
        //     Statistic owns DD_MILEAGE1/2 0x49503010/24 on the same page,
        //     and those arrive.
        targets.add(TargetSpec(
            "BYDAutoEnergyDevice_xdev",
            "android.hardware.bydauto.energy.BYDAutoEnergyDevice",
            intArrayOf(0x1CD0003D.toInt())
        ))
        targets.add(TargetSpec(
            "BYDAutoChargingDevice_xdev",
            "android.hardware.bydauto.charging.BYDAutoChargingDevice",
            intArrayOf(0x1CD0003D.toInt())
        ))
        targets.add(TargetSpec(
            "BYDAutoStatisticDevice_xdev",
            "android.hardware.bydauto.statistic.BYDAutoStatisticDevice",
            intArrayOf(0x49503040.toInt(), 0x4950303F.toInt())
        ))

        // p086 — LIGHTS stop-lamp probe. Tests one fid: 0x33100012
        // LIGHT_CMD_STOP_LIGHT_STATE (state of the brake LAMP, not the pedal).
        // Goal: a companion brake indicator that reflects actual lamp state,
        // including regen-only braking with the pedal released (an EV lights
        // its stop lamps above a deceleration threshold). GEARBOX_BRAKE_PEDAL
        // is pedal-only and would miss that case.
        //
        // Expectation is GUARDED. p078 closed Bodywork/Speed/Gb after three
        // sessions: all three threw SecurityException at getInstance (the
        // signature wall sits on getInstance, BEFORE registerListener, so the
        // COMMON-vs-GET escape never applies). LIGHTS is the same framework and
        // very likely behaves the same. BUT BYDAutoLightsDevice was never
        // isolated in the live subscriber for this specific fid, and it was NOT
        // in the p078 closure list, so we confirm with data, not assumption.
        // One run settles it via lifecycle_events: REGISTERED_OK (then the
        // feature is doable) or getInstance_threw SecurityException (then LIGHTS
        // is closed like Bodywork and companion falls back to a regen-threshold
        // estimate from motor_torque 0x28A00018 + pack_current, both granted and
        // already flowing). Note class name is plural "Lights" (matches the
        // BYDAutoLightsDevice used in TelemetryStateProbe), not "Light".
        targets.add(TargetSpec(
            "BYDAutoLightsDevice_priority",
            "android.hardware.bydauto.lights.BYDAutoLightsDevice",
            intArrayOf(0x33100012.toInt())
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
            0x49507032,             // avg_consumption_50km
            0x2D300030,             // soc_battery (patch 075)
            0x49505038,             // soc_display (patch 075)
            0x49507028,             // ev_range (patch 075)
            0x44500830,             // instant_consumption (patch 075)
            0x47800020,             // cell_temp_lowest (patch 075)
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
                0x1AC01010.toInt(), 0x2EB00832.toInt(), 0x0A50000D.toInt(), 0x2C100818.toInt()
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
