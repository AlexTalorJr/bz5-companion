package com.bz5companion.bz5_companion

import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.random.Random

/**
 * v0.1.72+171 — ОБЩИЙ ЖУРНАЛ АВТОЗАПУСКА.
 *
 * До этого патча запись маркера жила приватным методом внутри
 * AutostartService. С появлением BootReceiver писать в тот же файл
 * должны двое, и копировать логику второй раз нельзя по трём
 * причинам:
 *
 *   1. Файл ОДИН. Публичные Downloads на этой прошивке мертвы
 *      (поле 28.07: `public Downloads unwritable (fails=1)` в каждом
 *      из трёх процессов), поэтому единственный способ прочитать
 *      маркер — приватная копия, которую export_service кладёт в ZIP
 *      как `autostart_marker.txt`. Второй файл в эту трубу не влезет,
 *      и половина следа осталась бы недоступной.
 *   2. Тег процесса обязан быть общим. `procTag` инициализируется
 *      один раз на загрузку класса, то есть один раз на процесс. Если
 *      ресивер и сервис пишут ОДИН тег — они в одном процессе, и
 *      значит поднятый по мосту сервис живёт там же, где отработал
 *      ресивер. Разные теги означали бы, что процесс между двумя
 *      строками пересоздали. Из двух копий кода этот вывод сделать
 *      нельзя.
 *
 *      v0.1.75+174: до этого патча вывод нельзя было сделать и из
 *      одной копии — строки ресивера `ident()` не печатали, и тега в
 *      них просто не было. Утверждение выше стояло с +171 как
 *      обещание, которого код не выполнял. Теперь `BootReceiver`
 *      печатает `ident()` в каждой своей строке, и сравнение стало
 *      возможным.
 *   3. Двухуровневая запись (+170) уже один раз стоила нам поездки.
 *      Второй экземпляр той же лестницы — второй шанс разойтись.
 *
 * Состояние здесь процессное, а не глобальное в смысле приложения:
 * при пересоздании процесса тег и счётчик отказов начинаются заново,
 * и это ровно то, что нужно измерять.
 */
object AutostartMarker {
    private const val TAG = "Bz5Autostart"

    /** Имя файла и в публичных Downloads, и в приватной папке. Оно же
     *  зашито в export_service.dart — менять только парой. */
    const val FILE_NAME = "bz5_companion_autostart_log.txt"

    /** Один тег на ПРОЦЕСС: val объекта инициализируется при загрузке
     *  класса. Строки с общим тегом писал один живой процесс; новый
     *  тег — полное перерождение. */
    val procTag: String = "%04x".format(Random.nextInt(0x10000))

    /** Куда легла последняя строка: pub | priv | none. */
    @Volatile
    var where: String = "?"
        private set

    /** Сколько раз публичный путь отказал в этом процессе. */
    @Volatile
    var pubFails: Int = 0
        private set

    private var fallbackNoted = false

    /**
     * v0.1.74+173 — МЁРТВЫЙ ПУБЛИЧНЫЙ ПУТЬ БОЛЬШЕ НЕ ПРОБУЕТСЯ ДВАЖДЫ.
     *
     * Запись синхронна, и зовут её из onReceive (главный поток, лимит
     * 10 секунд) и из heartbeat на главном лупере. Прежняя редакция на
     * КАЖДУЮ строку сначала лезла в /sdcard/Download и ловила оттуда
     * исключение — а поле 28.07 показало, что этот путь на прошивке
     * мёртв наглухо. То есть на каждом пробуждении ГУ, в самый занятый
     * момент загрузки, мы делали обречённое обращение к внешнему
     * хранилищу на главном потоке. ANR маловероятен, но это ровно тот
     * класс отказов, который срабатывает раз в сотню загрузок и не
     * воспроизводится.
     *
     * Первая попытка в процессе остаётся: разрешение могло вернуться,
     * и узнать об этом можно только попробовав. Отказавшись однажды,
     * путь считается мёртвым до конца процесса — новый процесс
     * попробует заново.
     */
    private var pubDead = false

    /** pid + тег процесса + пара uptime/elapsedRealtime. `up` не
     *  считает глубокий сон, `el` считает: расхождение между двумя
     *  строками ОДНОГО тега — это сон, который процесс пережил. */
    fun ident(): String =
        "pid=${Process.myPid()} tag=$procTag" +
            " up=${SystemClock.uptimeMillis() / 1000}s" +
            " el=${SystemClock.elapsedRealtime() / 1000}s"

    /** versionName приложения; «?» если PackageManager отказал. */
    fun appVersion(context: Context): String = try {
        context.packageManager
            .getPackageInfo(context.packageName, 0).versionName ?: "?"
    } catch (t: Throwable) {
        "?"
    }

    /**
     * Дописать строку. Сначала публичные Downloads, при отказе —
     * приватная папка приложения (+170). Синхронизировано: ресивер
     * работает на главном потоке, а heartbeat сервиса — свой Runnable
     * на том же Looper, но полагаться на это в общем коде не стоит.
     */
    @Synchronized
    fun write(context: Context, line: String) {
        val ts =
            SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val text = "$ts  $line\n"
        if (!pubDead) {
            try {
                File("/sdcard/Download/$FILE_NAME").appendText(text)
                where = "pub"
                return
            } catch (t: Throwable) {
                pubFails++
                pubDead = true
            }
        }
        try {
            File(context.filesDir, FILE_NAME).appendText(text)
            where = "priv"
        } catch (t: Throwable) {
            where = "none"
            Log.w(TAG, "marker: both paths failed: ${t.message}")
        }
    }

    /**
     * v0.1.75+174 — ПРОЧИТАТЬ ЖУРНАЛ, ЧТОБЫ ОН УЕХАЛ ДРУГИМ КАНАЛОМ.
     *
     * Приватная копия — единственный читаемый экземпляр (публичные
     * Downloads мертвы), и до сих пор она выбиралась только внутри
     * экспортного ZIP. Канал оказался ненадёжным: 29.07 два архива
     * подряд приехали обрезанными ровно на кратном 32 КиБ — подпись
     * несброшенного буфера, из которого не доехал последний неполный
     * блок. Диаг-дамп при этом доезжал целым каждый раз: он мелкий и
     * пишется отдельно.
     *
     * Отсюда правило, а не разовая заплатка: критическая мелочь не
     * должна зависеть от доставки хрупкой большой посылки. Журнал
     * весит килобайты и теперь может ехать в диаг-дампе.
     *
     * ХВОСТ ЧИТАЕТСЯ ПОЗИЦИОНИРОВАНИЕМ, а не отрезкой после чтения, и
     * это не микрооптимизация. Журнал append-only и не чистится:
     * по полю 29.07 средняя строка 96 байт, биения идут каждые 5 минут,
     * значит при круглосуточном процессе ~27 КБ в сутки и около 10 МБ
     * в год — а этот патч ещё и ускорил рост, добавив `ident()` в
     * строки ресивера. `readText()` положил бы весь файл в память, да
     * ещё в UTF-16, то есть вдвое, плюс копия под substring — и всё это
     * на платформенном потоке, то есть на главном. Отложенный ANR на
     * приборе, который зовут ровно тогда, когда что-то уже пошло не так.
     *
     * Через `RandomAccessFile` в память попадает не больше `maxBytes`
     * независимо от размера файла. Обрезка по границе строки
     * ОБЯЗАТЕЛЬНА, а не косметика: позиция может попасть в середину
     * UTF-8 последовательности. Размер целого файла сообщается в первой
     * строке, чтобы рост был виден без доступа к устройству.
     *
     * v0.1.77+176 — РОТАЦИЯ ПОЯВИЛАСЬ, И ИМЕННО ЗДЕСЬ.
     *
     * Открытый пункт +174 закрыт. Место выбрано не по удобству: `read()`
     * зовут из MethodChannel, то есть на переднем плане и по инициативе
     * владельца, а не в момент загрузки ГУ. Из boot-контекста ротация
     * недостижима КОНСТРУКТИВНО — не по флагу, который можно уронить, а
     * потому что единственный её вызов стоит здесь, а ресивер и сервис
     * зовут только `write()`. Перезапись многомегабайтного файла на
     * главном потоке во время загрузки — риск того же класса, который
     * +174 здесь и убирал.
     *
     * Rename между записями безопасен: наши записи открывают и
     * закрывают файл на КАЖДУЮ строку (`appendText`), поэтому открытого
     * дескриптора, который переехал бы вместе с inode, не существует.
     * Худшее, что может случиться при совпадении по времени, — одна
     * строка биения ляжет в файл, который через миллисекунду сменят;
     * цена — одна строка раз в несколько месяцев.
     */
    fun read(context: Context, maxBytes: Int = 64 * 1024): String = try {
        val rotated = rotateIfHuge(context)
        val f = File(context.filesDir, FILE_NAME)
        val head = if (rotated != null) "($rotated)\n" else ""
        if (!f.exists()) {
            "(маркера нет: $FILE_NAME не создан в filesDir)"
        } else {
            val total = f.length()
            if (total <= maxBytes) {
                head + f.readText()
            } else {
                val buf = ByteArray(maxBytes)
                RandomAccessFile(f, "r").use { raf ->
                    raf.seek(total - maxBytes)
                    raf.readFully(buf)
                }
                val tail = String(buf, Charsets.UTF_8)
                // Первая строка почти наверняка обрублена позицией, и
                // первый символ мог попасть в середину UTF-8
                // последовательности — отрезаем до первого перевода.
                val cut = tail.indexOf('\n')
                val body = if (cut >= 0) tail.substring(cut + 1) else tail
                head + "(показан хвост $maxBytes из $total байт)\n$body"
            }
        }
    } catch (t: Throwable) {
        "(маркер не прочитан: ${t.javaClass.simpleName}: ${t.message})"
    }

    /**
     * Один раз на процесс сообщить В САМОМ ФАЙЛЕ, что публичный путь
     * мёртв и строки уехали в приватную копию. Без этой строки при
     * следующем разборе никто не поймёт, почему в Downloads пусто.
     * Зовётся после первой записи — раньше `where` ещё не известно.
     */
    @Synchronized
    fun noteFallback(context: Context) {
        if (fallbackNoted || where == "pub") return
        fallbackNoted = true
        write(
            context,
            "marker: public Downloads unwritable" +
                " (fails=$pubFails), writing app-private" +
                " — arrives in the export ZIP as autostart_marker.txt"
        )
    }

    /** Выше этого размера журнал усекается. */
    private const val ROTATE_ABOVE = 2 * 1024 * 1024

    /** Сколько хвоста остаётся после усечения. */
    private const val ROTATE_KEEP = 256 * 1024

    /**
     * v0.1.77+176 — §C: УСЕЧЕНИЕ ЖУРНАЛА.
     *
     * Журнал append-only и не чистился никогда: по полю 29.07 средняя
     * строка 96 байт, биения каждые 5 минут, то есть ~27 КБ в сутки и
     * порядка 10 МБ в год при круглосуточном процессе. +174 вылечил
     * только ЧТЕНИЕ (позиционированием), рост остался.
     *
     * ЕДИНСТВЕННЫЙ ВЫЗОВ — из `read()`. Это и есть защита от
     * boot-контекста: не флаг, который можно уронить правкой, а
     * отсутствие второго пути. Ресивер и сервис зовут `write()`, и
     * `write()` про ротацию не знает.
     *
     * Хвост читается позиционированием, пишется в ВРЕМЕННЫЙ файл и
     * подставляется одним `rename` — атомарно на POSIX. Порядок именно
     * такой: усечение на месте (открыть на запись, переписать) в момент
     * отказа питания оставило бы обрезанный журнал, а он здесь
     * единственный свидетель.
     *
     * Обрезка по границе строки обязательна и здесь: позиция попадает в
     * середину UTF-8 последовательности так же, как при чтении.
     *
     * Возвращает строку отчёта для диаг-дампа либо null, если ротация не
     * потребовалась. Молча не усекает: пропавшие килобайты журнала
     * читались бы как потеря данных.
     */
    @Synchronized
    private fun rotateIfHuge(context: Context): String? {
        val f = File(context.filesDir, FILE_NAME)
        val total = try {
            if (!f.exists()) return null else f.length()
        } catch (t: Throwable) {
            return null
        }
        if (total <= ROTATE_ABOVE) return null
        val tmp = File(context.filesDir, "$FILE_NAME.rot")
        return try {
            val buf = ByteArray(ROTATE_KEEP)
            RandomAccessFile(f, "r").use { raf ->
                raf.seek(total - ROTATE_KEEP)
                raf.readFully(buf)
            }
            val tail = String(buf, Charsets.UTF_8)
            val cut = tail.indexOf('\n')
            val body = if (cut >= 0) tail.substring(cut + 1) else tail
            val ts = SimpleDateFormat(
                "yyyy-MM-dd HH:mm:ss", Locale.US
            ).format(Date())
            tmp.writeText(
                "$ts  marker: rotated, was $total bytes," +
                    " kept the last $ROTATE_KEEP\n" + body
            )
            if (tmp.renameTo(f)) {
                "rotate: $total → ${f.length()} bytes"
            } else {
                tmp.delete()
                "rotate: rename refused, file left as is"
            }
        } catch (t: Throwable) {
            try {
                tmp.delete()
            } catch (ignored: Throwable) {
            }
            "rotate: ${t.javaClass.simpleName}: ${t.message}"
        }
    }
}
