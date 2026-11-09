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
        // v0.2.29+228: перекрытие изоляции 0x47300018 снято — p155 несёт
        // ровно то же (insulation_resistance, MΩ, INT, scale 0.001; Друг 3,
        // 06.11).
        //
        // CANDIDATES (v0.1.29+66) — battery temperature search. None of
        // these is in the shared active table; recon saw PROBE_HIGHEST_TEMP
        // live at 20–21 °C (plausible = ambient) and never saw the
        // AVERAGE/HIGHEST/LOWEST trio deliver. They surface in HAL Test
        // only, for correlation against OBD2 790/002F. NOT wired to any
        // dashboard card.
        "BYDAutoStatisticDevice|0x47800010" to Decoder(
            "probe_highest_temp", "°C", ValueSource.INT,
            notes = "CANDIDATE battery temp; verify vs 790/002F"),
        // v0.2.29+228: кандидаты battery_temp_avg/high/low (0x49367,
        // 0x90D49, 0xA4490) сняты — номера с другой прошивки, в каталоге bZ5
        // их нет ни по номеру, ни по имени; за все прогоны ни одного события
        // (Друг 3, 06.11). Температура батареи — 0x47800010 выше.

        // v0.2.29+228: кандидаты energy_dc_port_temp (0xDA09B),
        // charging_max_power_batt_temp (0x72559), charging_max_temp_allowed
        // (0x4CFF3) сняты. Номера с другой прошивки; на bZ5 эти имена —
        // 0x30A / 0x2F2 / 0x2F3, kind=legacy, читаются только синхронным
        // get(), который недоверенному приложению закрыт. Дело не в DC-
        // зарядке: номер чужой (Друг 3, 06.11).

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

        // v0.2.31+230: перекрытие 0x2FF00030 pack_voltage_fine снято — recon
        // p156 активировал запись под тем же именем, единицей и полем (V,
        // DOUBLE). История hal_samples продолжается без разрыва.
        //
        // 0x47800020 cell_temp_lowest p155 поместил в карантин (оба поля —
        // мусор ~1e9), и его не возвращаем: решение владельца 05.11.

        // v0.2.31+230 — ТОК ИНВЕРТОРА. ENGINE_MOTOR_CONTROL_ELEC 0x40800008,
        // А, поле double, плюс = разряд, около 0.75 Гц, на P ровно 0
        // (Друг 3, письмо 09.11). В таблице recon он всё ещё
        // `motor_current_candidate`; Друг 3 переведёт его в активные под
        // этим именем, тогда перекрытие снимается. На нём стоит модель
        // разделения энергии v2: «движение» = ∫V·I_инв.
        "BYDAutoEngineDevice|0x40800008" to Decoder(
            "inverter_current", "A", ValueSource.DOUBLE,
            notes = "ENGINE_MOTOR_CONTROL_ELEC; inverter DC input current, discharge-positive; 0 in P (Friend 3, 09.11)"),

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
     * 0x47800010 = STATISTIC_PROBE_HIGHEST_TEMP (battery temperature,
     * checked against the cluster and OBD 790/002F). It is outside the
     * registry's top-64 prefix subscription, so it is added here.
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
     * v0.2.29+228: Bodywork (0x2FA00016) снят. getInstance закрыт
     * signature-разрешением BYDAUTO_BODYWORK_GET (recon p078, 11.06; по
     * каталогу bZ5 — SecurityException:BYDAUTO_BODYWORK_GET), запрос
     * _COMMON не помогает. Подогрев батареи остаётся в «климат и подогрев».
     *
     * Четыре сигнала AC (PTC, прогрев) уже в подписке AC, их пишет ac_raw.
     */
    val extraInstrumentFids: IntArray = intArrayOf(0x35902039, 0x3A700028)

    /** Device key → fids written raw as `heat_raw_<FID>` by the sink.
     *  Everything else from these devices is dropped there. */
    val heatRawFids: Map<String, Set<Long>> = mapOf(
        "BYDAutoInstrumentDevice" to extraInstrumentFids.map { it.toLong() and 0xFFFFFFFFL }.toSet()
    )

    /**
     * v0.2.27+226 — СОСТОЯНИЯ НАГРУЗОК, сырой записью `state_raw_<FID>`
     * (Друг 3, 06.11). Нужны регрессии «Прочего» и климата в разделении
     * энергии: что было включено, пока шла поездка. Значения — номера
     * ступеней или флаги, а не ватты; в ватты их переведёт только
     * регрессия. Только hal_samples, в облако не идут.
     *
     * v0.2.29+228 — СВЕРЕНО С КАТАЛОГОМ bZ5 (tools/data/
     * bydauto_feature_ids_bz5_v0_10_56.csv, гейт DB2):
     *  - Lights снят: класс BYDAutoLightsDevice на bZ5 — class_not_found
     *    (recon 11.06), фар не будет; разрешения BYDAUTO_LIGHT_* тоже сняты.
     *  - Bodywork снят: SecurityException:BYDAUTO_BODYWORK_GET, 12 В
     *    (0x2FC00042) с него не прийти.
     *  - Setting остаётся: класс есть, getInstance 11.06 не вызывался —
     *    ответит строка `HAL: BYDAutoSettingDevice …` в app_log и проба recon.
     *
     * Setting, подогрев сидений: водитель и пассажир в ДВУХ версиях
     * (`_STATE` 0x48D00010 / 0x3480000B и `_STATE1` 0x3B400042 /
     * 0x3B400044) — какую шлёт bZ5, неизвестно; задние 0x34800025,
     * 0x3480002C. Вентиляция: 0x48D00008, 0x48D0000B, 0x48600008,
     * 0x48600010. Руль: 0x31000040 SET_STEERING_WHEEL_HEAT_STATE.
     * НЕ подписываемся: `*_STATE_SET` (команды), `SET_HAS_*` (признак
     * комплектации), `SETTING_*_CONFIG` (конфигурация).
     *
     * Power: v0.2.31+230 — отдельная регистрация 0x1CD0003D POWER_LOW_VOLTAGE
     * снята. За двое суток ни одного события (экспорты 07.11 и 09.11), Друг
     * 3: подписка на Power нам не работает. 12 В теперь читает телефон через
     * адаптер (ATRV). Регистрация GB32960 на Power не тронута.
     *
     * Charging: 0x44900842 CHARGING_IRON_BATTERY_POWER_MODE — режим
     * 12-вольтовой LFP-батареи, покажет подзарядку от DC-DC. В вендорном
     * явном списке Charging его нет — добавляется сверху (extraChargingFids).
     * v0.2.31+230: recon p156 внёс его в `Charging_priority` своих
     * defaultTargets, но не в streamingTargets, — добавка остаётся.
     *
     * Statistic: 0x2F300030 STATISTIC_DC_DC_STATE — уже в первых 64
     * вендорной подписки Statistic, добавлять не нужно (гейт DB3 считает
     * подписку по каталогу тем же правилом). Тот же fid есть в Energy как
     * ENERGY_DC_WORK_MODE; Energy у нас подписан явным списком без него.
     */
    val settingStateFids: IntArray = intArrayOf(
        0x48D00010, 0x3B400042, 0x3480000B, 0x3B400044, 0x34800025, 0x3480002C,
        0x48D00008, 0x48D0000B, 0x48600008, 0x48600010,
        0x31000040
    )
    val extraChargingFids: IntArray = intArrayOf(0x44900842)
    val statisticStateFids: IntArray = intArrayOf(0x2F300030)

    /** Device key → fids written raw as `state_raw_<FID>` by the sink. */
    val stateRawFids: Map<String, Set<Long>> = mapOf(
        "BYDAutoSettingDevice" to settingStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoChargingDevice" to extraChargingFids.map { it.toLong() and 0xFFFFFFFFL }.toSet(),
        "BYDAutoStatisticDevice" to statisticStateFids.map { it.toLong() and 0xFFFFFFFFL }.toSet()
    )
}
