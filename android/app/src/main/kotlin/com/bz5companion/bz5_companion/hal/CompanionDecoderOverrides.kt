// === COMPANION-AUTHORED (not vendored) ===
// This file is owned by bz5_companion. It is the per-project override
// layer the shared TelemetryDecoderTable was designed for (see that
// file's header, "Friend 1 review 2026-06-09: layered design — base
// table + per-project override map"). The vendored files stay
// byte-identical to recon; everything companion needs to add or fix
// locally lives here and is passed into DecodedStreamSink / the
// subscription at construction time in BydNativePlugin.
//
// PROMOTION RULE: entries here are either (a) local fixes awaiting an
// official recon decoder-table release, or (b) measurement CANDIDATES
// surfacing in HAL Test for verification. Nothing in this file may feed
// a daily-driver UI card until verified against an independent source
// (the OBD2 DID or the instrument cluster) — at which point it should
// be promoted into the shared table via Friend 3 and removed from here.
package com.bz5companion.bz5_companion.hal

object CompanionDecoderOverrides {

    /**
     * Override / extension decoders, layered over the shared base table
     * (override wins on key collision — see TelemetryDecoderTable.decode).
     */
    val map: Map<String, Decoder> = mapOf(
        // LOCAL FIX (v0.1.29+66) — shared table ships scale=1.0 which
        // renders raw kΩ as "MΩ" (live reading 13517 "MΩ" on 2026-06-11
        // drive, physically absurd). Truth: raw is kΩ → scale 0.001 gives
        // 13.5 MΩ.
        //
        // v0.2.4+203 — ОДНА ПОЛОСА НОРМЫ, А НЕ ДВЕ. Здесь стояло
        // «14–18 MΩ», в общей таблице «16–18 MΩ», а замеры дали
        // 6.1–17.1 MΩ при медиане 15.5 (108 замеров, экспорт 11.08,
        // сводка в tools/data/export_summary_20260811.txt). Обе прежние
        // полосы противоречили данным, и разошлись между собой. Теперь
        // написано одно и то же в обоих файлах, и написано наблюдение.
        // Official fix queued recon-side (p079); drop this entry on the
        // next re-vendor that contains it.
        "BYDAutoStatisticDevice|0x47300018" to Decoder(
            "insulation_resistance", "MΩ", ValueSource.INT,
            scale = 0.001,
            notes = "LOCAL FIX over shared scale=1.0 bug; raw is kΩ"),

        // CANDIDATES (v0.1.29+66) — battery temperature search. None of
        // these is in the shared active table; recon saw PROBE_HIGHEST_TEMP
        // live at 20–21 °C (plausible = ambient) and never saw the
        // AVERAGE/HIGHEST/LOWEST trio deliver. They surface in HAL Test
        // only, for correlation against OBD2 790/002F. NOT wired to any
        // dashboard card.
        "BYDAutoStatisticDevice|0x47800010" to Decoder(
            "probe_highest_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE battery temp; verify vs 790/002F"),
        "BYDAutoStatisticDevice|0x00049367" to Decoder(
            "battery_temp_avg", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_AVERAGE_BATTERY_TEMP; never seen live"),
        "BYDAutoStatisticDevice|0x00090D49" to Decoder(
            "battery_temp_high", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_HIGHEST_BATTERY_TEMP; never seen live"),
        "BYDAutoStatisticDevice|0x000A4490" to Decoder(
            "battery_temp_low", "°C", ValueSource.INT,
            notes = "CANDIDATE STATISTIC_LOWEST_BATTERY_TEMP; never seen live"),

        // CANDIDATES (v0.1.29+70, status updated +72) — Energy/Charging
        // temp fids. Battery temperature is now resolved via
        // probe_highest_temp (0x47800010, promoted below this patch), so
        // these are no longer needed as a battery-temp fallback. They are
        // NOT dead-confirmed for us, though: recon (Friend 3, v0.10.61,
        // n=4) saw zero events across charge/city/motorway, but all three
        // are charging-CONTEXT fids by name (DC port temp, V2X max-power
        // battery temp, V2X max-temp-allowed) and we have NOT yet run a
        // charge session with HAL Test open. They stay in the override as
        // a no-cost decoder layer (already subscribed, just decoded) until
        // verified on an AC/DC charge. Surface in HAL Test only — NOT in
        // the consumed allowlist, NOT on any card.
        "BYDAutoEnergyDevice|0x000DA09B" to Decoder(
            "energy_dc_port_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE charging-context; recon n=4 no events in drive — verify during a charge with HAL Test open"),
        "BYDAutoChargingDevice|0x00072559" to Decoder(
            "charging_max_power_batt_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE charging-context; recon n=4 no events in drive — verify during a charge with HAL Test open"),
        "BYDAutoChargingDevice|0x0004CFF3" to Decoder(
            "charging_max_temp_allowed", "°C", ValueSource.INT,
            notes = "CANDIDATE charging-context; recon n=4 no events in drive — verify during a charge with HAL Test open"),

        // PROMOTED (v0.1.44+143) — accumulated charge energy, kWh.
        // Verified by recon on a live AC session (p084): monotonic
        // counter, active on AC, dE/dt 1.74 kW vs 2.6–3.1 kW at the
        // socket = OBC losses. Promoted WITHOUT a candidate stage per
        // that verification (Alex, 15.07). The subscription has existed
        // in the vendored TargetRegistry all along (both branches) —
        // only the decoder was missing, so DecodedStreamSink dropped
        // every frame. ⚠️ The counter is a LIFETIME total and NEVER
        // resets between sessions: consumers must work strictly by
        // derivative (rise = charging) and per-session DELTA from an
        // anchored value — never by level.
        "BYDAutoChargingDevice|0x2C100818" to Decoder(
            "charge_energy_kwh", "kWh", ValueSource.DOUBLE,
            notes = "recon p084 verified on AC; monotonic lifetime total — consume by derivative/delta only"),

        // CANDIDATE (v0.1.44+143) — CHARGING_GUN_CONNECT_STATE. Same
        // story: subscribed since the vendored registry, never decoded,
        // frames dropped → the plug/unplug enum was never collected.
        // Rule p068/p083: HAL Test + the diag journal ONLY, never a UI
        // consumer — HalTelemetryService logs value CHANGES with
        // timestamps to hal_samples so the next AC/DC plug/unplug run
        // collects the enum for free. Phase B (sticky getter + session
        // anchoring on gun-connect, OR with the current detector) is a
        // separate patch once the enum is confirmed.
        // v0.2.8+207 — ФЛАГ КАБЕЛЯ. CHARGING_CHARGER_CONNECT_STATE по
        // каталогу; recon 14.08 (v0.10.110, session 165329): событие
        // int=1 в 16:53:59 — за 36 с до первого зарядного тока, int=0
        // в 17:21 — выдёргивание кабеля. Ровно два события за сессию —
        // событийный флаг, на dart-стороне обязана быть липкость.
        // Подписка уже была (TargetRegistry, оба списка) — события
        // приходили и резались здесь, отсутствием записи.
        "BYDAutoChargingDevice|0x0A50000D" to Decoder(
            "charger_connect_state", "", ValueSource.INT,
            notes = "CHARGING_CHARGER_CONNECT_STATE; 1=plugged 0=unplugged; recon 20260814_165329"),

        // v0.2.9+208 — КАНДИДАТ ДОЗРЕЛ, enum подтверждён полем:
        // 3 в 16:53:55 14.08 (секунда в секунду с флагом DC-подключения),
        // 1 в 17:20:35 (отключение), 2 на старте ночной AC-сессии 15.08.
        // Итого: 1=отключён, 2=AC, 3=DC. Пять старых строк остаются под
        // прежним именем charging_gun_connect_candidate — историю читать
        // по subtype, как с переименованием ячеек в +203.
        "BYDAutoChargingDevice|0x2EB00832" to Decoder(
            "charging_gun_state", "", ValueSource.INT,
            notes = "1=disconnected 2=AC 3=DC; field-confirmed 14-16.08 (was charging_gun_connect_candidate)"),

        // v0.2.23+222 — ТОЧНОЕ НАПРЯЖЕНИЕ БАТАРЕИ ДЕРЖИМ ЗДЕСЬ. В recon p155
        // запись 0x2FF00030 закомментирована как непроверенная гипотеза
        // `pack_voltage_alt`; у companion она подтверждена DC-зарядкой 06.08,
        // и на ней стоят мощность, энергия и разделение энергии поездки.
        // Без перекрытия переход на p155 молча снял бы сигнал. Друг 3 просил
        // внести её в recon; снять отсюда, когда внесёт.
        //
        // 0x47800020 cell_temp_lowest p155 поместил в карантин (оба поля —
        // мусор ~1e9), и его не возвращаем: решение владельца 05.11.
        "BYDAutoChargingDevice|0x2FF00030" to Decoder(
            "pack_voltage_fine", "V", ValueSource.DOUBLE,
            notes = "fractional volts; confirmed by recon 06.08 DC charge; commented out in p155"),

        // v0.2.23+222: the seven AC candidates added here in +219
        // (0x2FC00009/0A/0B/0C/16, 0x2FA0000C/26) moved into the vendored
        // table with recon p155 under the same names, as ValueSource.ANY.
        // An override here would shadow p155 and its carrier rule, so none
        // is kept (Friend 3, 05.11: all seven are in p155's Ac list).
    )

    /**
     * Extra Statistic-device feature ids companion subscribes to on top
     * of the vendored TargetRegistry.streamingTargets set. Applied by
     * BydNativePlugin as a copy-on-top of the "BYDAutoStatisticDevice"
     * TargetSpec — the vendored registry file itself is never edited.
     *
     * 0x47800010 = STATISTIC_PROBE_HIGHEST_TEMP. The AVERAGE/HIGHEST/
     * LOWEST trio (0x00049367 / 0x00090D49 / 0x000A4490) is already
     * inside the registry's top-64 prefix subscription, so only the
     * probe fid needs adding here.
     */
    val extraStatisticFids: IntArray = intArrayOf(0x47800010)

    /**
     * v0.2.23+222 — СИГНАЛЫ ПОДОГРЕВА, сырой записью без расшифровки
     * (Friend 3, 05.11). Нужны, чтобы зимой отделить подогрев батареи от
     * климата в разделении энергии поездки. Ни один ещё не приходил живым.
     *
     * Instrument: 0x35902039 INSTRUMENT_BATTERY_HEATING_ENERGY_TEMPORARILY_
     * LIMITED, 0x3A700028 INSTRUMENT_AIR_HEATING_DISPLAY_STATE. Вендорная
     * подписка берёт 80 младших из ~490 fid панели, эти два за границей —
     * добавляются сверху, как Statistic.
     *
     * Bodywork: 0x2FA00016 BODYWORK_BATTERY_COOLANT_STATUS. Устройство
     * убрано из вендорного списка в июне (recon p078: SecurityException на
     * getInstance). Friend 3: это несработавшее runtime-разрешение
     * BODYWORK_COMMON, как было с AC; у recon registerListener работает.
     * Отказ подписки запустит самовосстановление разрешений из +220.
     *
     * Четыре сигнала AC (PTC, прогрев) уже в подписке AC, их пишет ac_raw.
     */
    val extraInstrumentFids: IntArray = intArrayOf(0x35902039, 0x3A700028)
    val bodyworkHeatFids: IntArray = intArrayOf(0x2FA00016)

    /** Device key → fids written raw as `heat_raw_<FID>` by the sink.
     *  Everything else from these devices is dropped there. */
    val heatRawFids: Map<String, Set<Long>> = mapOf(
        "BYDAutoInstrumentDevice" to extraInstrumentFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoBodyworkDevice" to bodyworkHeatFids.map { it.toLong() and 0xFFFFFFFFL }.toSet()
    )

    /**
     * v0.2.27+226 — СОСТОЯНИЯ НАГРУЗОК, сырой записью `state_raw_<FID>`
     * (Друг 3, 06.11). Нужны регрессии «Прочего» и климата в разделении
     * энергии: что было включено, пока шла поездка. Значения — номера
     * ступеней, а не ватты; в ватты их переведёт только регрессия.
     * Только hal_samples, в облако не идут.
     *
     * Lights (класс BYDAutoLightsDevice, разрешение BYDAUTO_LIGHT_*):
     * 0x3310000A LIGHT_LOW_BEAM_LIGHT, 0x3310000C LIGHT_HIGH_BEAM_LIGHT.
     *
     * Setting, подогрев сидений: водитель и пассажир в ДВУХ версиях
     * (`_STATE` 0x48D00010 / 0x3480000B и `_STATE1` 0x3B400042 /
     * 0x3B400044) — какую шлёт bZ5, неизвестно; задние 0x34800025,
     * 0x3480002C. Вентиляция: 0x48D00008, 0x48D0000B, 0x48600008,
     * 0x48600010. Руль: 0x31000040 SET_STEERING_WHEEL_HEAT_STATE.
     * НЕ подписываемся: `*_STATE_SET` (команды), `SET_HAS_*` (признак
     * комплектации), `SETTING_*_CONFIG` (конфигурация).
     *
     * Bodywork, 12 В: 0x2FC00042 BODYWORK_BATTERY_VOLTAGE_LEVEL по каталогу
     * recon (снят рефлексией BYDAutoFeatureIds на самой машине, Друг 3
     * 06.11). 0x000450BF — номер старого формата из tools/data/
     * feature_ids.txt, который снят с другой прошивки и с bZ5 расходится
     * (там же 0x2FC00042 назван PM25_ANION_CONFIG; на bZ5 это 0x43300025).
     * Оба подписаны до экспорта: ожидается только 0x2FC00042, второй снять
     * следующим патчем. Номера fid брать из каталога recon v0.10.56.
     *
     * Statistic: 0x2F300030 STATISTIC_DC_DC_STATE. Ac: 0x40600031
     * AC_DEFROST_REAR_STATE — кадры Ac уже пишутся целиком как ac_raw, здесь
     * только гарантия подписки (вендорная берёт 80 из списка AC_).
     */
    val lightStateFids: IntArray = intArrayOf(0x3310000A, 0x3310000C)
    val settingStateFids: IntArray = intArrayOf(
        0x48D00010, 0x3B400042, 0x3480000B, 0x3B400044, 0x34800025, 0x3480002C,
        0x48D00008, 0x48D0000B, 0x48600008, 0x48600010,
        0x31000040
    )
    val bodyworkStateFids: IntArray = intArrayOf(0x000450BF, 0x2FC00042)
    val statisticStateFids: IntArray = intArrayOf(0x2F300030)
    val extraAcFids: IntArray = intArrayOf(0x40600031)

    /** Device key → fids written raw as `state_raw_<FID>` by the sink. */
    val stateRawFids: Map<String, Set<Long>> = mapOf(
        "BYDAutoLightsDevice" to lightStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoSettingDevice" to settingStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoBodyworkDevice" to bodyworkStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoStatisticDevice" to statisticStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet()
    )
}
