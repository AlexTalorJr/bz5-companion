// === COMPANION-AUTHORED (editable) — v0.1.83+182 ===
//
// ОДНА ПОДПИСКА НА ПРОЦЕСС. Владелец движка, сника и набора целей.
//
// ПОЧЕМУ ЭТО ОБЪЕКТ, А НЕ ПОЛЯ СЕРВИСА ИЛИ ПЛАГИНА. В манифесте у
// `AutostartService` НЕТ атрибута `android:process` — сервис живёт в том
// же процессе, что MainActivity и движок Flutter. Проверено чтением
// манифеста, строки 233–234. Отсюда следует главное: рукопожатия между
// сервисом и плагином через интенты не нужно, потому что это не два
// собеседника, а два входа в одну память.
//
// А главный риск патча 2 — ДВОЙНАЯ ПОДПИСКА. Охрана в самих движках
// per-instance: `active` в `LiveTelemetrySubscriber` — это
// `AtomicBoolean` поля экземпляра, и два экземпляра зарегистрируют по
// прокси на одни и те же устройства, ничего друг о друге не узнав.
// Сломался бы при этом живой поток — то есть ровно то, что работает.
//
// Процессный владелец снимает риск целиком и без договорённостей: один
// экземпляр физически не может подписаться дважды. Заодно исчезает
// вторая беда, которой в спеке не было: при передаче потока от журнала
// к Flutter НЕ НУЖНО отписываться и подписываться заново, а значит нет
// и окна между отпиской и подпиской, в которое проваливались бы
// события. Меняется только адресат (см. HalOut).
package com.bz5companion.bz5_companion.hal

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.EventChannel

object HalStreamOwner {

    private const val TAG = "HalStreamOwner"

    @Volatile private var engine: HalEngine? = null
    @Volatile private var streamSink: DecodedStreamSink? = null
    @Volatile private var journal: JournalHalOut? = null
    @Volatile private var selection: DiLinkProfiles.Selection? = null
    @Volatile private var lastStatus: SubscriptionStatus =
        SubscriptionStatus(0, 0, 0, emptyMap())

    const val OUT_FLUTTER = "flutter"
    const val OUT_NONE = "-"

    /** «journal», «flutter» или «-», когда подписки нет. */
    @Volatile private var outTag: String = OUT_NONE

    val isActive: Boolean get() = engine?.isActive == true
    fun selection(): DiLinkProfiles.Selection? = selection
    fun status(): SubscriptionStatus = lastStatus
    fun activeOut(): String = outTag
    fun engineTag(): String? = engine?.engineTag

    /** Полная строка счётчиков фонового журнала, или null, если его нет. */
    fun journalSnapshot(): String? = journal?.snapshot()

    /**
     * Сколько событий вообще пришло в фоновый выход. null — журнала нет.
     *
     * Единственное число, которым можно честно подписать уведомление:
     * `targetsRegistered > 0` НЕ означает, что события идут — вендоренный
     * `SubscriptionStatus` предупреждает об этом прямо (silent push wall,
     * цель регистрируется и молчит). Разница между «подписались» и
     * «получаем» и есть главное неизвестное окна, поэтому смешивать их в
     * одну надпись нельзя.
     */
    fun journalSeen(): Long? = journal?.seenTotal()

    /**
     * Читатель забрал файл журнала — бюджет потолка начинается заново.
     *
     * Протокол, а не догадка: журнал, дойдя до потолка, останавливает
     * запись и сам из этого состояния не выходит. Зовётся из Dart после
     * успешного втягивания. Журнала может не быть (свежий процесс,
     * телефон) — тогда это ничего не делает, и так и должно быть.
     */
    fun noteJournalConsumed() {
        journal?.onConsumed()
    }

    /**
     * СБОРКА НАБОРА ЦЕЛЕЙ — В ОДНОМ МЕСТЕ, И ЭТО МЕСТО ЗДЕСЬ.
     *
     * До этого патча шестьдесят строк сборки лежали инлайном внутри
     * `handleHalStreamStart`. Сервису понадобился тот же набор, и
     * соблазн был скопировать. Цена копии измеряется точно: разойдись
     * список на паре `BYDAutoPowerDevice_canDataCollect` +
     * `BYDAutoBigDataDevice_canDataCollect`, и GB32960-сбор в фоне не
     * стартует, кадры 0x99000020 не идут, а вместе с ними тихо
     * исчезают soc_precise, SOH и температура батареи — то есть ровно
     * та надстройка companion, ради сохранения которой единственным
     * экземпляром и затевался весь шов HalOut. Отчёт при этом остался
     * бы зелёным: события идут, счётчики растут, просто три сигнала
     * молчат.
     *
     * Вендоренный `TargetRegistry` не правится (SHA-пиннут); всё
     * лишнее наслаивается сверху, как и было.
     */
    fun buildTargets(
        ctx: Context,
        selection: DiLinkProfiles.Selection,
    ): List<TargetSpec> {
        val base = TargetRegistry.streamingTargets(ctx)
        val withStatistic = base.map { spec ->
            if (spec.key == "BYDAutoStatisticDevice")
                spec.copy(
                    featureIds = spec.featureIds +
                        CompanionDecoderOverrides.extraStatisticFids
                )
            else spec
        }
        // v0.1.29+89: триггер GB32960-сбора плюс канал данных.
        // streamingTargets() (подмножество из восьми целей) не содержит
        // ни Power, ни BigData, поэтому сбор не начинается сам и кадры
        // 0x99000020 не приходят вовсе.
        val withCollect = withStatistic + listOf(
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
        // Страховка на неизвестный DiLink: у обоих известных профилей
        // флаг false, так что для BZ3/BZ5 это пустая ветка.
        return if (selection.profile?.unconditionalEngine == true &&
            withCollect.none { it.key == "BYDAutoEngineDevice" }
        ) {
            withCollect + TargetSpec(
                "BYDAutoEngineDevice",
                "android.hardware.bydauto.engine.BYDAutoEngineDevice",
                intArrayOf(
                    0x28A00008.toInt(), 0x28A00018.toInt(),
                    0x15100020.toInt(), 0x3DB00010.toInt(),
                    0x3DB00008.toInt(),
                ),
            )
        } else {
            withCollect
        }
    }

    /**
     * Поднять подписку, если её нет, и направить выход в файл.
     *
     * Зовётся из `AutostartService` — то есть из процесса, где
     * Flutter-движка может не быть вовсе (воскрешение или мост поднимают
     * сервис первым). Ничего от Flutter здесь и не требуется: выбор
     * платформы — чистая функция от отпечатка и SDK.
     *
     * ОБ ОТСУТСТВИИ `overrideId`. Ручная подмена платформы живёт
     * транзиентным полем плагина и в prefs не сохраняется, поэтому в
     * фоне её прочитать нечем и она сознательно игнорируется. Это не
     * потеря: отпечаток `TOYOTA SPACE` + sdk 32 дают BZ5 однозначно, а
     * подмена существует как отладочный инструмент живой сессии.
     *
     * БЛОКИРУЕТ. Внутри отражение и обходы `registerListener`; звать
     * только с рабочего потока.
     */
    @Synchronized
    fun startForBackground(ctx: Context): SubscriptionStatus {
        // ── ДЕФЕКТ, НАЙДЕННЫЙ ПЕРВОЙ РЕВИЗИЕЙ. ЧИТАТЬ ВНИМАТЕЛЬНО. ──
        //
        // Этот метод зовётся на КАЖДОМ onStartCommand — то есть на каждом
        // срабатывании моста (четыре цикла за вечер в поле 31.07), на
        // каждом sticky-воскрешении И на каждом ARM, когда владелец
        // открывает приложение.
        //
        // Без охраны ниже происходило бы вот что: приложение открыто, Dart
        // держит поток, срабатывает будильник моста → onStartCommand →
        // startForBackground → движок жив, значит ensureEngine делает
        // setOut(journal) — и живой поток УХОДИТ У DART ИЗ-ПОД НОГ.
        // Приборы на экране машины замирают, атлас перестаёт набираться,
        // а журнал при этом исправно пишется, так что ни один счётчик и
        // ни один гейт не покраснеет. Нашлось бы это полевым визитом, и
        // выглядело бы как «HAL опять отвалился».
        //
        // Владелец потока определяется одним признаком: если он уже
        // Flutter, фоновому сбору здесь делать нечего. Гейт BP10.
        if (engine != null && outTag == OUT_FLUTTER) return lastStatus
        val j = journal ?: JournalHalOut(ctx).also { journal = it }
        ensureEngine(ctx, overrideId = null, out = j)
        outTag = j.tag
        return lastStatus
    }

    /**
     * Отдать поток Flutter. Возвращает статус подписки — той же формы,
     * что раньше возвращал `halStreamStart`.
     *
     * ДВИЖОК НЕ ПЕРЕСОЗДАЁТСЯ, если он уже жив. Это и есть смысл всей
     * постройки: `stop()` + `start()` на передаче означали бы отписку и
     * подписку на живой машине, то есть провал событий в промежутке и
     * два прокси на устройстве в момент перекрытия.
     */
    @Synchronized
    fun attachFlutter(
        ctx: Context,
        sink: EventChannel.EventSink,
        overrideId: String?,
    ): SubscriptionStatus {
        val out = FlutterHalOut(sink)
        ensureEngine(ctx, overrideId, out)
        streamSink?.setOut(out)
        outTag = out.tag
        return lastStatus
    }

    /**
     * Flutter ушёл. Дальше два исхода, и различает их взвод автозапуска.
     *
     * Взведён — подписка ОСТАЁТСЯ и продолжает писать в журнал: сервис
     * жив в этом же процессе, и именно для этого случая патч и написан.
     * Не взведён (телефон — там `AutostartArm` за гейтом `canUseHal`
     * флаг не ставит никогда) — подписка снимается целиком, поведение
     * ровно прежнее.
     */
    @Synchronized
    fun detachFlutter(ctx: Context) {
        val armed = AutostartPrefsBridge.isArmed(ctx) &&
            !AutostartPrefsBridge.optedOut(ctx)
        if (!armed || engine == null) {
            stopAll()
            return
        }
        val j = journal ?: JournalHalOut(ctx).also { journal = it }
        streamSink?.setOut(j)
        outTag = j.tag
        Log.i(TAG, "Flutter detached; stream continues into the journal")
    }

    /** Снять подписку целиком. Идемпотентно. */
    @Synchronized
    fun stopAll() {
        try { engine?.stop() } catch (t: Throwable) {
            Log.e(TAG, "engine.stop failed", t)
        }
        engine = null
        try { streamSink?.detach() } catch (_: Throwable) {}
        streamSink = null
        try { journal?.close() } catch (_: Throwable) {}
        journal = null
        outTag = OUT_NONE
    }

    /**
     * Создать движок и сник, если их нет. Уже живой движок не трогается
     * ни при каких условиях — см. `attachFlutter`.
     */
    private fun ensureEngine(ctx: Context, overrideId: String?, out: HalOut) {
        if (engine != null) {
            streamSink?.setOut(out)
            return
        }
        val sel = DiLinkProfiles.selectProfile(
            overrideId = overrideId,
            fingerprint = android.os.Build.FINGERPRINT,
            sdk = android.os.Build.VERSION.SDK_INT,
            // VIN у BZ5 намеренно не сигнал: getRealAutoVIN на этой
            // прошивке бросает (полевая проверка BydVinDetector).
            vin = null,
        )
        selection = sel
        val sink = DecodedStreamSink(out, CompanionDecoderOverrides.map)
        val eng = DiLinkProfiles.selectEngine(
            sel.engineKind, ctx, sink, buildTargets(ctx, sel),
        )
        lastStatus = eng.start()
        streamSink = sink
        engine = eng
        Log.i(
            TAG,
            "HAL stream started into ${out.tag}: $lastStatus " +
                "(platform=${sel.platformId}, engine=${sel.engineKind})",
        )
    }
}

/**
 * Тонкая переадресация к `AutostartPrefs`, который лежит в корневом
 * пакете. Нужна затем, чтобы пакет `hal` не импортировал корневой:
 * зависимость в эту сторону уже есть (плагин и сервис зовут `hal`), и
 * встречная сделала бы её круговой на уровне чтения, а не компилятора.
 */
private object AutostartPrefsBridge {
    fun isArmed(ctx: Context): Boolean =
        com.bz5companion.bz5_companion.AutostartPrefs.isArmed(ctx)

    fun optedOut(ctx: Context): Boolean =
        com.bz5companion.bz5_companion.AutostartPrefs.optedOut(ctx)
}
