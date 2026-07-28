package com.bz5companion.bz5_companion

import android.content.Context
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
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
        try {
            File("/sdcard/Download/$FILE_NAME").appendText(text)
            where = "pub"
            return
        } catch (t: Throwable) {
            pubFails++
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
}
