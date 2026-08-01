// === COMPANION-AUTHORED (editable) — v0.1.83+182 ===
//
// КУДА УХОДЯТ РАСШИФРОВАННЫЕ СОБЫТИЯ. Один шов, две реализации.
//
// Зачем этот файл существует. Патч 2 добавляет сбор в автостарте, то
// есть второе место, куда должен уезжать расшифрованный поток. Прямой
// путь — своя копия расшифровки на стороне сервиса — отвергнут: ценное
// в декодировании не вендоренная таблица, а НАДСТРОЙКА companion,
// байтовые извлечения из BigData-кадров (soc_precise, SOH,
// battery_temp), и это самая чувствительная логика в проекте. Копия
// развелась бы с оригиналом молча.
//
// Поэтому меняется не расшифровка, а её адресат. DecodedStreamSink
// остаётся ОДНИМ экземпляром на процесс, а его выход — сменным.
package com.bz5companion.bz5_companion.hal

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionHandler
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Адресат расшифрованных событий. Три метода, и больше здесь быть не
 * должно: всё, что сложнее отправки готового пакета, живёт в
 * DecodedStreamSink и потому существует в единственном экземпляре.
 *
 * Пакет — это уже собранный список карт вида
 * `{name, unit, value, key, subtype, ts}`, у сырых кадров плюс
 * `can_id_hex`, `buf_hex`, `buf_size`.
 */
interface HalOut {
    /** Отправить склеенный пакет. Зовётся с главного лупера. */
    fun emit(batch: List<Map<String, Any?>>)

    /** Освободить ресурсы. Идемпотентно. */
    fun close()

    /** Имя для маркера и журнала: «flutter» или «journal». */
    val tag: String
}

/**
 * Фоновый выход: расшифрованные события в файл, строка на событие.
 *
 * ЧТО ЭТОТ КЛАСС ДОЛЖЕН СДЕЛАТЬ ПРАВИЛЬНО С ПЕРВОГО РАЗА, потому что
 * второй заход стоит поездки.
 *
 * 1. СЧЁТЧИКИ СЧИТАЮТСЯ ДО ВСЕГО. Главное неизвестное окна — отдаёт ли
 *    BYD HAL события, когда активити не на переднем плане. Ответ на него
 *    дают счётчики по целям, а не журнал: они уезжают в маркер
 *    автостарта, который читается экспортом и без всякого втягивания.
 *    Поэтому инкремент стоит ПЕРЕД придушиванием, ПЕРЕД отбрасыванием
 *    сырых кадров и ПЕРЕД потолком. Иначе исправно работающий HAL при
 *    полном журнале выглядел бы молчащим — ложно-отрицательный ответ на
 *    единственный вопрос, ради которого всё это написано.
 *
 * 2. НА ГЛАВНОМ ПОТОКЕ НЕТ ФАЙЛОВОГО ВВОДА-ВЫВОДА. `emit` приходит с
 *    главного лупера; запись уезжает на свой поток-одиночку. Тот же
 *    класс отказов, что вылечил +173 у маркера, только там путь был
 *    обречённый, а здесь частый.
 *
 * 3. ПОТОЛОК, А НЕ РОТАЦИЯ. Гейт BL7 запрещает ротацию из фонового
 *    контекста, и запрет здесь в силе: сервис поднимается на каждом
 *    пробуждении ГУ, а переименование файла под возможным чтением — та
 *    же порода ошибки, что подмена базы под живым Drift. Поэтому на
 *    потолке журнал ЗАКРЫВАЕТСЯ и говорит об этом строкой. Потеря
 *    хвоста хуже потери начала, но она ВИДНА, а счётчики остаются
 *    полными. Усечение делает втягивание — со стороны чтения.
 */
class JournalHalOut(private val ctx: Context) : HalOut {

    companion object {
        private const val TAG = "JournalHalOut"

        /** Читается Dart-стороной (`hal_bg_journal.dart`) из filesDir. */
        const val FILE_NAME = "bz5_hal_bg_journal.jsonl"

        /**
         * ВЕРСИЯ ФОРМАТА. Пишется первой строкой каждого нового файла и
         * проверяется читателем.
         *
         * Зачем. Файл — приватный протокол через границу языков, ключи в
         * нём короткие (`ts/n/k/u/v`) и ничем себя не называют. Журнал,
         * оставшийся на диске от прежней сборки с другой раскладкой, был
         * бы разобран МОЛЧА и уехал бы в `hal_samples` мусором. В этом же
         * коде задача уже решена один раз — `kPrefsFormat` в
         * `import_service.dart`, — и решать её здесь иначе было бы
         * несимметрично.
         *
         * Литерал по обе стороны границы: приватную константу Kotlin
         * компилятор Dart не отдаст, поэтому расхождение ловится только
         * текстом, то есть гейтом.
         */
        const val FMT: Int = 1

        /**
         * Потолок. Восемь мебибайт при придушивании 3 с на имя сигнала —
         * порядка четырёх часов езды, больше любой поездки владельца.
         * Файл живёт во внутреннем хранилище и забирается при каждом
         * открытии приложения, поэтому расти ему только между открытиями.
         */
        const val CAP_BYTES: Long = 8L * 1024 * 1024

        /**
         * Придушивание на ИМЯ сигнала, а не на цель. Ровно то же окно, что
         * у `_halDiagThrottle` в `hal_telemetry_service.dart`, и это не
         * совпадение: фоновые строки лягут в ту же таблицу `hal_samples`,
         * что и живые, и разной плотностью различались бы в любом расчёте.
         */
        const val THROTTLE_MS: Long = 3_000L

        /**
         * v0.1.86+185 — ПОРОГ ПО ИМЕНИ, а не один на всех.
         *
         * Поле 01.08 показало, куда уходил бюджет журнала: за 45 минут
         * `soh` дал 949 строк, а `soc_precise` — 94. Порог был общий, и
         * сигнал, который не меняется за сессию, съедал вдесятеро больше
         * места, чем тот, из которого считается расход. Журнал при этом
         * упирался в потолок ровно теми строками, которые не нужны.
         *
         * Здесь только исключения; всё неперечисленное остаётся на
         * `THROTTLE_MS`, то есть поведение по умолчанию прежнее.
         *
         * СЕКУНДА — тем, из чего строится поездка и расход. Плотнее
         * секунды смысла нет: втянутые строки хранятся с точностью до
         * секунды (`hal_samples.timestamp` — unix-секунды), и два кадра в
         * одну секунду в базе неразличимы.
         *
         * МИНУТА — тем, что за поездку меняется на единицы или не
         * меняется вовсе. `odometer` в минуту на скорости 115 км/ч это
         * шаг под два километра, и для дистанции этого мало — поэтому он
         * НЕ здесь, а в `MEDIUM` ниже.
         */
        val THROTTLE_FAST_MS: Map<String, Long> = mapOf(
            "pack_current" to 1_000L,
            "speed" to 1_000L,
            "soc_precise" to 1_000L,
            "motor_power" to 1_000L,
        )

        /** Десять секунд: меняется медленно, но участвует в расчёте. */
        val THROTTLE_MEDIUM_MS: Map<String, Long> = mapOf(
            "odometer" to 10_000L,
            "pack_voltage" to 10_000L,
            "cell_v_lowest" to 10_000L,
            "cell_v_highest" to 10_000L,
            "battery_temp_bigdata" to 10_000L,
        )

        /** Минута: за поездку не меняется или меняется на единицы. */
        val THROTTLE_SLOW_MS: Map<String, Long> = mapOf(
            "soh" to 60_000L,
            "trip_a" to 60_000L,
            "trip_b" to 60_000L,
            "cell_idx_lowest" to 60_000L,
            "cell_idx_highest" to 60_000L,
            "insulation_resistance" to 60_000L,
            "avg_consumption_50km" to 60_000L,
        )

        /**
         * Порог для имени. Три карты, а не одна, только ради читаемости
         * намерения — склеены они здесь, и склеены ОДИН РАЗ на класс, а
         * не на кадр: `emit` зовётся десятки раз в секунду.
         */
        val THROTTLE_BY_NAME: Map<String, Long> =
            THROTTLE_FAST_MS + THROTTLE_MEDIUM_MS + THROTTLE_SLOW_MS

        fun throttleFor(name: String): Long =
            THROTTLE_BY_NAME[name] ?: THROTTLE_MS

        /**
         * Граница очереди записи. Прежняя редакция брала
         * `newSingleThreadExecutor()`, а у него `LinkedBlockingQueue` БЕЗ
         * границы, и каждая задача держит копию пакета. Застрявшая
         * флеш-память в долгой поездке давала бы рост памяти в
         * foreground-сервисе — тот класс отказов, что срабатывает раз в
         * сотню загрузок и не воспроизводится. Теперь очередь конечна, а
         * отказ ставится в счётчик уронов, который уже есть: потеря,
         * названная числом, лучше памяти, названной ничем.
         */
        const val QUEUE_CAPACITY: Int = 256

        /** Имя, под которым сырые кадры приходят из сника. */
        private const val RAW_NAME = "bigdata_raw"
    }

    /** Цель → сколько событий пришло. Полные числа, без придушивания. */
    private val perTarget = ConcurrentHashMap<String, AtomicLong>()
    private val seen = AtomicLong(0)
    private val written = AtomicLong(0)
    private val dropped = AtomicLong(0)

    /**
     * Тип фабрики ЯВНЫЙ, а не голая лямбда, и это не стиль.
     *
     * Проверка конструкции отдельным файлом на разрешимых типах (приём
     * `/tmp/t.kt` из окна №10) дала на лямбде «cannot infer a type for
     * this parameter. Please specify it explicitly» — то есть вывод типа
     * на месте ThreadFactory внутри конструктора Java здесь не работает.
     * Отличить настоящую ошибку от возрастной особенности локального
     * компилятора было нечем, а цена явного типа — одна строка.
     */
    private val threads = ThreadFactory { r ->
        Thread(r, "bz5-hal-journal").apply { isDaemon = true }
    }

    private val io = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(QUEUE_CAPACITY),
        threads,
        RejectedExecutionHandler { _, _ -> dropped.incrementAndGet() }
    )

    /** Трогается только с потока-одиночки. */
    private val lastPerName = HashMap<String, Long>()

    @Volatile private var full = false
    @Volatile private var closed = false
    @Volatile private var lastError: String? = null

    override fun emit(batch: List<Map<String, Any?>>) {
        if (closed) return
        // ── Считаем всё и сразу, до любых решений. ──
        for (e in batch) {
            seen.incrementAndGet()
            val key = e["key"] as? String
            val target = if (key == null) "?" else targetOf(key)
            perTarget.getOrPut(target) { AtomicLong(0) }.incrementAndGet()
        }
        if (full) {
            dropped.addAndGet(batch.size.toLong())
            return
        }
        // Запись — на своём потоке. Отказ переполненной очереди попадёт в
        // `dropped` через RejectedExecutionHandler, а не в исключение.
        val copy = ArrayList(batch)
        try {
            io.execute { append(copy) }
        } catch (t: Throwable) {
            dropped.addAndGet(copy.size.toLong())
        }
    }

    /** `Target|0xAAAAAAAA` → `Target`. */
    private fun targetOf(key: String): String {
        val i = key.indexOf('|')
        return if (i < 0) key else key.substring(0, i)
    }

    private fun append(batch: List<Map<String, Any?>>) {
        val f = File(ctx.filesDir, FILE_NAME)
        // ДЛИНА БЕРЁТСЯ У ФАЙЛОВОЙ СИСТЕМЫ КАЖДЫЙ РАЗ, а не помнится полем.
        //
        // Прежняя редакция читала длину однажды и вела счётчик сама. Читатель
        // забирает файл переименованием, и после этого запомненное число
        // относилось к файлу, которого больше нет: потолок срабатывал на
        // мебибайты раньше до конца процесса. Один `stat` на запись (их
        // порядка восьми в секунду при придушивании) стоит неизмеримо
        // меньше, чем целый класс расхождения с действительностью.
        val existed = f.exists()
        var bytes = if (existed) f.length() else 0L
        val sb = StringBuilder()
        // Новый файл обязан начинаться заголовком версии — иначе читатель
        // отвергнет его целиком, и правильно сделает.
        if (!existed) {
            sb.append(header())
            lastPerName.clear()
        }
        var kept = 0
        for (e in batch) {
            val name = e["name"] as? String ?: continue
            // Сырые кадры в журнал НЕ идут: их шестьдесят в секунду, они
            // нужны для построчного сравнения с recon, и на этот вопрос
            // фоновый сбор не отвечает. В счётчиках они уже учтены.
            if (name == RAW_NAME) {
                dropped.incrementAndGet()
                continue
            }
            val ts = (e["ts"] as? Number)?.toLong() ?: continue
            val prev = lastPerName[name]
            if (prev != null && ts - prev < throttleFor(name)) {
                dropped.incrementAndGet()
                continue
            }
            lastPerName[name] = ts
            sb.append(line(e, name, ts))
            kept++
        }
        if (kept == 0) return
        val text = sb.toString()
        val size = text.toByteArray().size.toLong()
        if (bytes + size > CAP_BYTES) {
            full = true
            try {
                f.appendText(
                    "{\"_\":\"full\",\"at\":${System.currentTimeMillis()}," +
                        "\"bytes\":$bytes}\n"
                )
            } catch (t: Throwable) {
                lastError = "${t.javaClass.simpleName}: ${t.message}"
            }
            dropped.addAndGet(kept.toLong())
            Log.w(TAG, "journal cap reached at $bytes bytes; appending stopped")
            return
        }
        try {
            f.appendText(text)
            bytes += size
            written.addAndGet(kept.toLong())
        } catch (t: Throwable) {
            lastError = "${t.javaClass.simpleName}: ${t.message}"
            dropped.addAndGet(kept.toLong())
        }
    }

    /** Первая строка файла: версия формата и сборка, её написавшая. */
    private fun header(): String =
        "{\"_\":\"hdr\",\"fmt\":$FMT,\"build\":\"" +
            esc(appVersion()) + "\"}\n"

    private fun appVersion(): String = try {
        ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "?"
    } catch (t: Throwable) {
        "?"
    }

    /**
     * ЧИТАТЕЛЬ ЗАБРАЛ ФАЙЛ. Бюджет потолка начинается заново.
     *
     * Явное уведомление, а не догадка по исчезнувшему файлу: `full`
     * останавливает запись до этого вызова, и самостоятельно журнал из
     * этого состояния не выйдет — `emit` при `full` до файловой системы
     * не доходит вовсе, и заметить пропажу ему нечем. Признай пропажу
     * молча — получилась бы догадка о действиях другой стороны; так это
     * протокол, и его видно.
     *
     * Не позвали (старая сборка Dart) — журнал остаётся полным и говорит
     * об этом `full=yes` в маркере. Честный отказ вместо тихой ошибки.
     */
    fun onConsumed() {
        full = false
        try { io.execute { lastPerName.clear() } } catch (_: Throwable) {}
        Log.i(TAG, "journal consumed by the reader; cap budget reset")
    }

    /**
     * Одна строка JSON без внешней библиотеки. Ключи короткие: файл
     * пишется десятками тысяч строк, и `"value"` против `"v"` — четыре
     * байта на строку, то есть проценты потолка.
     */
    private fun line(e: Map<String, Any?>, name: String, ts: Long): String {
        val v = (e["value"] as? Number)?.toDouble()
        val sb = StringBuilder(96)
        sb.append("{\"ts\":").append(ts)
        sb.append(",\"n\":\"").append(esc(name)).append('"')
        sb.append(",\"k\":\"").append(esc(e["key"] as? String ?: "")).append('"')
        sb.append(",\"u\":\"").append(esc(e["unit"] as? String ?: "")).append('"')
        if (v != null && !v.isNaN() && !v.isInfinite()) {
            sb.append(",\"v\":").append(v)
        }
        sb.append("}\n")
        return sb.toString()
    }

    private fun esc(s: String): String =
        s.replace("\\", "\\\\").replace("\"", "\\\"")

    /**
     * Строка для маркера автозапуска. ГЛАВНЫЙ канал ответа на вопрос
     * окна, поэтому обязана быть читаемой глазами с фотографии и полной
     * без журнала.
     */
    fun snapshot(): String {
        val per = perTarget.entries
            .sortedByDescending { it.value.get() }
            .joinToString(" ") { "${it.key}=${it.value.get()}" }
        val err = lastError?.let { " err=$it" } ?: ""
        return "seen=${seen.get()} rows=${written.get()} drop=${dropped.get()}" +
            " full=${if (full) "yes" else "no"}$err · ${if (per.isEmpty()) "-" else per}"
    }

    /** Событий получено всего — по нему и только по нему судят, жив ли HAL в фоне. */
    fun seenTotal(): Long = seen.get()

    override fun close() {
        if (closed) return
        closed = true
        try { io.shutdown() } catch (_: Throwable) {}
    }

    override val tag: String get() = "journal"
}
