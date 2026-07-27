package com.bz5companion.bz5_companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.random.Random

/**
 * v0.1.56+155 — autostart net (вариант D, spec Друга 3 20.07).
 * v0.1.58+157 — heartbeat instrumentation (Друг 3, 22.07 retraction).
 *
 * HISTORY, corrected. The +155 premise — «recon's LiveMonitorService
 * proved STICKY resurrection in the field» — was RETRACTED by Друг 3
 * on 22.07 after a real re-read of the recon raw data: the four 20.07
 * restarts were full process births (fresh session_ts, first CAN frame
 * 0.2 s after it), the autostart-receiver log was empty, and the FGS
 * launch-check (mAllowStartForeground false, p113) should wall a
 * system-driven STICKY restart exactly like it walls the receiver.
 * What actually restarted recon is UNKNOWN; the best-standing guess is
 * the standby bucket (recon was hand-opened constantly during debug →
 * active bucket → lenient restart policy; companion is not → restricted
 * → no restarts). Field 22.07 on companion agrees: only `armed:` lines,
 * zero `resurrected:`, the «взведён» notification gone after HU sleep.
 *
 * +157 therefore adds the ONLY instrument that yields facts instead of
 * hypotheses — a heartbeat trail: `born` (onCreate, pid + per-process
 * tag + fresh-boot flag), `beat` every 5 min (uptime/elapsedRealtime
 * pair — their divergence between beats of one tag is a suspend the
 * process SURVIVED), `destroy` (onDestroy — its ABSENCE before a new
 * `born` is a silent kill, i.e. force-stop-like). One day of ordinary
 * drives answers: does the process die at ignition-off, is it ever
 * reborn by the system, does anything survive suspend. No self-healing
 * in this patch — pure observation.
 *
 * v0.1.70+169 — ШАГ 1: ФОНОВЫЙ ЗАПУСК АКТИВИТИ СНЯТ.
 *
 * Друг 3 закрыл механизм 27.07 полевым хартбитом recon: три
 * перерождения за вечер, монотонный uptimeMillis через все три (ОС не
 * перезагружалась), ни одного destroy, у всех трёх null-intent. То
 * есть STICKY на этой прошивке РАБОТАЕТ, и отзыв 22.07 был ошибочным.
 * Заодно снимается и версия про standby bucket из абзаца выше.
 *
 * Одна поправка к его разбору, в его же пользу: «нет onDestroy →
 * force-stop» неверно. Настоящий force-stop переводит приложение в
 * stopped state, и sticky после него не работает ВООБЩЕ — трёх
 * перерождений recon просто не случилось бы. onDestroy не вызывается
 * и при обычном сносе процесса по памяти, а вот там sticky и
 * применяется. Читается это так: оба приложения убивает LMK, recon
 * система воскрешает, companion — нет.
 *
 * Второй его ответ (27.07, вечер) назвал вероятную причину: recon
 * LiveMonitorService HEADLESS — startActivity не зовёт ни разу, живёт
 * без UI. А этот сервис при воскрешении звал startActivity из фона,
 * что на Android 12 режется политикой Background-Activity-Launch:
 * foreground-статус сервиса сам по себе права на BAL не даёт.
 * Блокировка НЕ бросает исключение — система молча гасит запуск. И
 * всё это время маркер писал `launch=attempted-no-throw`, что мы
 * читали как «вероятно, поднялось». Инструмент +157 сообщал ровно
 * то, что мог; ошибка была в чтении.
 *
 * ЧЕГО ЭТОТ ПАТЧ НЕ ДЕЛАЕТ, СОЗНАТЕЛЬНО. Друг 3 предлагает два
 * условия сразу: убрать startActivity И сделать сервис тяжёлым,
 * реально собирающим. Второе для companion — не правка, а проект:
 * recon самодостаточен потому, что его хранилище на стороне Kotlin, а
 * здесь хранилище — Drift на стороне Dart, и сервис в него писать не
 * может. Сделав оба изменения разом, мы не узнали бы, какое
 * подействовало. Поэтому здесь ТОЛЬКО первое, и оно даёт двоичный
 * ответ за один день езды:
 *   • появился `resurrected:` без предшествующего `armed:` → стопором
 *     был BAL, вес сервиса ни при чём, headless-сервис выживает;
 *   • не появился → дело в весе или в чём-то третьем, и тогда шаг 2
 *     даёт сервису собственную подписку HAL.
 * Терять нечего: за весь лог до сих пор ноль воскрешений.
 *
 * Версия «Android 12 наказывает за фоновый BAL, переставая
 * sticky-воскрешать процесс» в план НЕ заложена: механизма такого
 * рода не известно, BAL режется поштучно. На решение это не влияет —
 * startActivity убирается потому, что он не работает, а не потому,
 * что за него наказывают.
 *
 * Устаревшая формулировка вопроса, ради истории — Android
 * 12 Background-Activity-Launch policy may silently block startActivity
 * from a background service on stock builds; HU launchers are often
 * laxer. Every attempt is appended to the marker file in Downloads —
 * the recon p112/p113 diagnostic pattern.
 *
 * Lifecycle: Dart arms the net via MethodChannel("bz5/autostart") once
 * per app launch on the head unit (canUseHal gate). Explicit STOP
 * action returns START_NOT_STICKY; the null-intent resurrection path
 * NEVER hits the stop branch (the trap Друг 3 warned about).
 */
class AutostartService : Service() {

    companion object {
        private const val TAG = "Bz5Autostart"
        const val ACTION_ARM = "com.bz5companion.ARM"
        const val ACTION_STOP = "com.bz5companion.STOP"
        private const val CHANNEL_ID = "bz5_autostart"
        private const val NOTIF_ID = 4151
        private const val MARKER = "bz5_companion_autostart_log.txt"

        /** +157 heartbeat cadence. 5 min: coarse enough to be free,
         *  fine enough to time a kill to the ignition-off it matches. */
        private const val HEARTBEAT_MS = 5 * 60 * 1000L

        /** v0.1.63+162: fresh-boot window, measured on uptimeMillis
         *  (which stops in deep sleep) rather than elapsedRealtime. */
        private const val FRESH_BOOT_MS = 5 * 60 * 1000L

        /** One tag per PROCESS — a companion-object val initialises
         *  once per class load, i.e. once per process. Lines sharing a
         *  tag came from one living process; a new tag is a full
         *  process rebirth (Друг 3's session_ts evidence, made cheap). */
        private val PROC_TAG = "%04x".format(Random.nextInt(0x10000))
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── +157 heartbeat: pure observation, no self-healing here ──

    private val hbHandler = Handler(Looper.getMainLooper())
    private val hbTick = object : Runnable {
        override fun run() {
            marker("beat: ${ident()}")
            hbHandler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    /** pid + process tag + the uptime/elapsedRealtime pair. `up`
     *  excludes deep sleep, `el` includes it: `el` jumping ahead of
     *  `up` between two beats of the SAME tag is a suspend the process
     *  survived; both restarting near zero with a NEW tag is a reboot. */
    private fun ident(): String =
        "pid=${Process.myPid()} tag=$PROC_TAG" +
            " up=${SystemClock.uptimeMillis() / 1000}s" +
            " el=${SystemClock.elapsedRealtime() / 1000}s"

    override fun onCreate() {
        super.onCreate()
        // fresh-boot flag. v0.1.63+162 FIX: the original test used
        // elapsedRealtime, which keeps ticking through deep sleep. A head
        // unit that has been parked overnight and merely woke up reported
        // hours of elapsed time and the flag said «not a fresh boot»
        // even when the OS had genuinely just started; the inverse case
        // (a real reboot after a long sleep) is the one that made the log
        // lie. uptimeMillis stops in deep sleep, so a small uptime really
        // does mean the kernel started recently. Both numbers are written
        // out so an old log can still be read against a new one.
        val upMs = SystemClock.uptimeMillis()
        val elMs = SystemClock.elapsedRealtime()
        val freshBoot = upMs < FRESH_BOOT_MS
        // +169: версия сборки в маркер. Файл дописывается с +155 и
        // уже пережил полтора десятка сборок; без этого поля нельзя
        // сказать, какая строка чьей версией написана, а вся ценность
        // опыта — в сравнении «до/после».
        marker(
            "born: ${ident()} fresh-boot=$freshBoot" +
                " (up=${upMs / 1000}s el=${elMs / 1000}s) build=${appVersion()}"
        )
        hbHandler.postDelayed(hbTick, HEARTBEAT_MS)
    }

    override fun onDestroy() {
        // A polite kill logs this line; a force-stop never reaches it.
        // The ABSENCE of `destroy` before the next `born` is itself the
        // measurement.
        hbHandler.removeCallbacks(hbTick)
        marker("destroy: ${ident()}")
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Explicit stop only — a null intent is a STICKY resurrection
        // and must fall through to the relaunch path below.
        if (intent?.action == ACTION_STOP) {
            marker("stop: explicit ACTION_STOP · ${ident()}")
            stopSelf()
            return START_NOT_STICKY
        }

        // v0.1.70+169: null intent = system-driven STICKY relaunch.
        val resurrected = intent == null
        startForeground(NOTIF_ID, buildNotification(resurrected))

        if (resurrected) {
            // HEADLESS. Никакого startActivity: из фона он всё равно
            // не проходит, а маркер «attempted-no-throw» вводил в
            // заблуждение. `flags` пишем сырыми — в них живут
            // START_FLAG_REDELIVERY (1) и START_FLAG_RETRY (2), и
            // ненулевое значение отличило бы повтор доставки от
            // обычного sticky-перезапуска.
            marker("resurrected: headless flags=$flags · ${ident()}")
        } else {
            marker("armed: ${intent?.action ?: "no-action"} · ${ident()}")
        }
        return START_STICKY
    }

    /**
     * v0.1.70+169. Две правки.
     *
     * 1. Текст зависит от того, как сервис поднялся. Воскрешение
     *    теперь видно НА ЭКРАНЕ машины, а не только в маркере в
     *    Downloads — читать файл, чтобы узнать результат опыта,
     *    больше не обязательно.
     * 2. Появился contentIntent. Раньше нотификация не открывала
     *    ничего: тап по ней не делал ровно ничего. Пока сбор не
     *    умеет идти headless, ЕДИНСТВЕННЫЙ законный путь поднять UI —
     *    это тап пользователя; BAL его разрешает, в отличие от
     *    startActivity из фона. На опыт это не влияет: PendingIntent
     *    пассивен, пока по нему не нажали.
     */
    private fun buildNotification(resurrected: Boolean = false): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "BZ5 Companion autostart",
                        NotificationManager.IMPORTANCE_MIN,
                    ).apply { setShowBadge(false) }
                )
            }
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        // FLAG_IMMUTABLE обязателен с Android 12 и существует с API 23.
        var piFlags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            piFlags = piFlags or PendingIntent.FLAG_IMMUTABLE
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                )
            },
            piFlags
        )
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("BZ5 Companion")
            .setContentText(
                if (resurrected) {
                    "восстановлен системой — нажмите, чтобы записывать"
                } else {
                    "автостарт взведён"
                }
            )
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    /** versionName приложения; «?» если PackageManager отказал. */
    private fun appVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (t: Throwable) {
        "?"
    }

    /** Append-only field marker — the recon p112/p113 diagnostic pattern. */
    private fun marker(line: String) {
        try {
            val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
            val f = File("/sdcard/Download/$MARKER")
            f.appendText("$ts  $line\n")
        } catch (t: Throwable) {
            Log.w(TAG, "marker write failed: ${t.message}")
        }
    }
}
