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
import com.bz5companion.bz5_companion.hal.HalStreamOwner

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
 * tag + the up/el pair), `beat` every 5 min (uptime/elapsedRealtime
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
 * v0.1.72+171 — ОПЫТ ЗАКРЫТ, ОТВЕТ ОТРИЦАТЕЛЬНЫЙ.
 *
 * Первый читаемый маркер (28.07, спасённый запасным путём +170) даёт
 * три строки `born:` — 17:30:05, 19:22:24, 19:53:13 — и каждая идёт в
 * паре с `armed: com.bz5companion.ARM`. Эта строка возможна ровно
 * одна: MainActivity → MethodChannel → Dart, то есть приложение
 * открывал владелец. Строк `resurrected:` ноль. Строк `destroy:` тоже
 * ноль — процесс убивают жёстко, и перезапуск система не планирует.
 * На том же железе в тот же день recon вставал сам за 7–8 секунд
 * после каждого из четырёх пробуждений ГУ; единственная разница между
 * приложениями — наличие ресивера.
 *
 * Поэтому START_STICKY остаётся (он ничего не стоит и однажды может
 * сработать), но надежда на него снята, а наверх добавлен третий,
 * рабочий путь: BootReceiver + мост через setAlarmClock. Его вход
 * сюда — ACTION_BRIDGE, и он ОБЯЗАН быть отличим от ARM в маркере.
 *
 * Lifecycle: Dart arms the net via MethodChannel("bz5/autostart") once
 * per app launch on the head unit (canUseHal gate). Explicit STOP
 * action returns START_NOT_STICKY; the null-intent resurrection path
 * NEVER hits the stop branch (the trap Друг 3 warned about). Мост
 * входит третьим действием и не задевает ни одну из двух веток.
 *
 * v0.1.83+182 — ШАГ 2: СЕРВИС НАКОНЕЦ СОБИРАЕТ.
 *
 * До этого патча за тумблером стояла пустота: уведомление и биение раз
 * в пять минут. Надпись это признавала честно — «автозапуск сработал,
 * сбор начнётся при открытии», — и признавать было что: сбор жил в
 * BydNativePlugin внутри движка Flutter внутри активити.
 *
 * Возражение +169 («сделать сервис тяжёлым — не правка, а проект,
 * потому что хранилище у companion на стороне Dart, и сервис в Drift
 * писать не может») остаётся верным и здесь НЕ опровергается. Оно
 * обходится: сервис пишет не в базу, а в журнал строк, а втягивает
 * журнал в `hal_samples` уже Dart, при открытии приложения. База
 * по-прежнему принадлежит одному хозяину.
 *
 * ГЛАВНОЕ НЕИЗВЕСТНОЕ, НА КОТОРОЕ ЭТОТ ПАТЧ ОТВЕЧАЕТ ОДНОЙ ПОЕЗДКОЙ:
 * отдаёт ли BYD HAL события, когда активити не на переднем плане.
 * Сервис поднимается — подтверждено четырежды строками `bridged`, — но
 * подписка из фона на этой прошивке не проверялась НИКОГДА. Ответ даёт
 * строка `hal-bg:` в маркере, и она устроена так, чтобы быть читаемой
 * с фотографии экрана: счётчики по целям считаются до придушивания, до
 * отбрасывания сырых кадров и до потолка журнала (см. JournalHalOut).
 * Молчит HAL фону — все дальнейшие варианты сбора бессмысленны, и
 * узнать это дешевле всего сейчас.
 *
 * ПОЧЕМУ ЗДЕСЬ НЕТ НИ СЛОВА ПРО ДВОЙНУЮ ПОДПИСКУ. Она невозможна:
 * подписка одна на процесс и лежит в HalStreamOwner, а сервис и
 * движок Flutter живут в ОДНОМ процессе (в манифесте у сервиса нет
 * android:process). Поэтому рукопожатия с Dart тоже нет — на
 * ACTION_ARM сервис не делает ничего, потому что делать нечего:
 * halStreamStart со стороны Dart просто перенаправит тот же поток себе.
 */
class AutostartService : Service() {

    companion object {
        const val ACTION_ARM = "com.bz5companion.ARM"
        const val ACTION_STOP = "com.bz5companion.STOP"

        /** v0.1.72+171. Действие моста — ОТДЕЛЬНОЕ от ACTION_ARM, и это
         *  не косметика. Подними ресивер сервис с ARM — в маркере
         *  появилась бы строка `armed: com.bz5companion.ARM`,
         *  неотличимая от той, что пишет открытое владельцем
         *  приложение, и весь опыт снова стал бы нечитаем ровно так
         *  же, как опыт +169. Различитель обязан быть в самой строке. */
        const val ACTION_BRIDGE = "com.bz5companion.BRIDGE"

        private const val CHANNEL_ID = "bz5_autostart"
        private const val NOTIF_ID = 4151

        /** +157 heartbeat cadence. 5 min: coarse enough to be free,
         *  fine enough to time a kill to the ignition-off it matches. */
        private const val HEARTBEAT_MS = 5 * 60 * 1000L
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Как сервис поднялся в последний раз: без владельца или с ним.
     *  Нужен обновлению надписи — оно приходит позже, а различитель
     *  «поднялся сам» терять нельзя. */
    @Volatile private var lastHeadless: Boolean = false

    /** Владелец сказал «выключить». Отложенные обновления надписи после
     *  этого обязаны молчать: `postDelayed` на 15 с переживает stopSelf и
     *  без этой охраны воскресил бы уведомление у выключенного сервиса. */
    @Volatile private var stopping: Boolean = false

    // ── +157 heartbeat: pure observation, no self-healing here ──

    private val hbHandler = Handler(Looper.getMainLooper())
    private val hbTick = object : Runnable {
        override fun run() {
            marker("beat: ${ident()}")
            // v0.1.83+182: счётчики HAL тем же биением. ОТДЕЛЬНОЙ строкой,
            // а не припиской к `beat`: `beat` читается граблением по всему
            // журналу автозапуска с +157, и его формат менять нельзя, не
            // обесценив прежние файлы. Строки нет, когда подписки нет —
            // честность важнее полноты (нет данных ≠ нули).
            HalStreamOwner.journalSnapshot()?.let { marker("hal-bg: $it") }
            refreshNotification()
            hbHandler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    /** pid + process tag + the uptime/elapsedRealtime pair. `up`
     *  excludes deep sleep, `el` includes it: `el` jumping ahead of
     *  `up` between two beats of the SAME tag is a suspend the process
     *  survived; both restarting near zero with a NEW tag is a reboot.
     *  v0.1.72+171: тег общий с BootReceiver — см. AutostartMarker. */
    private fun ident(): String = AutostartMarker.ident()

    override fun onCreate() {
        super.onCreate()
        // История флага, снятого в +170: +157 мерил по elapsedRealtime,
        // +162 перевёл на uptimeMillis, +170 снял вывод целиком.
        // Оба числа по-прежнему пишутся — по ним видно, пережил ли
        // процесс засыпание (расхождение up и el между beat'ами одного
        // тега), а утверждений о характере загрузки они не несут.
        // +169: версия сборки в маркер. Файл дописывается с +155 и
        // уже пережил полтора десятка сборок; без этого поля нельзя
        // сказать, какая строка чьей версией написана, а вся ценность
        // опыта — в сравнении «до/после».
        //
        // v0.1.71+170: FLAG `fresh-boot` УБРАН, ОН ВРАЛ.
        //
        // Он считался как upMs < FRESH_BOOT_MS, то есть кодировал
        // допущение «BOOT_COMPLETED приходит только при малом
        // uptime». На этой платформе это неверно: ресиверный лог
        // recon от 28.07 показывает FIRED BOOT_COMPLETED в 12:29 при
        // системе, поднятой сутками ранее. uptimeMillis — монотонное
        // время ЯДРА, оно не сбрасывается при перезапуске фреймворка
        // поверх живого ядра, а BOOT_COMPLETED рассылает именно
        // фреймворк. Отличить холодную загрузку от перезапуска
        // контейнера по up/el НЕЛЬЗЯ — поэтому числа остаются, а
        // вывод из них больше не делается.
        //
        // v0.1.72+171: ПАРА up/el ПЕЧАТАЛАСЬ ДВАЖДЫ. `ident()` её уже
        // отдаёт, а строка `born` дописывала свою копию тех же двух
        // чисел — видно в поле 28.07:
        //   born: pid=20990 tag=c490 up=8306s el=101601s
        //         up=8306s el=101601s build=0.1.71.244
        // Косметика, но в единственной диагностике, ради которой всё
        // и затевалось.
        marker("born: ${ident()} build=${appVersion()}")
        AutostartMarker.noteFallback(this)
        hbHandler.postDelayed(hbTick, HEARTBEAT_MS)
    }

    override fun onDestroy() {
        // A polite kill logs this line; a force-stop never reaches it.
        // The ABSENCE of `destroy` before the next `born` is itself the
        // measurement.
        hbHandler.removeCallbacks(hbTick)
        // Последний снимок счётчиков. Строка `destroy` в поле пока не
        // появлялась ни разу (ГУ убивает процесс жёстко), поэтому
        // рассчитывать на неё нельзя — но если она есть, числа в ней
        // самые полные, какие будут.
        HalStreamOwner.journalSnapshot()?.let { marker("hal-bg: $it") }
        // v0.1.83+182: НЕ ОСТАВЛЯТЬ ПОДПИСКУ БЕЗ ВЛАДЕЛЬЦА.
        //
        // Прежняя редакция писала снимок и уходила, а зарегистрированные
        // прокси у устройств BYD оставались висеть: сервиса, который держал
        // процесс на переднем плане, больше нет, а подписка есть. Ломалось
        // это не сразу и, скорее всего, никогда — процесс всё равно умрёт,
        // — но ресурс без хозяина это ресурс без хозяина.
        //
        // Условие обязательно: если поток у Dart, снимать НЕЛЬЗЯ. Сервис
        // может быть остановлен системой при живом открытом приложении, и
        // безусловный stopAll() погасил бы приборы на экране машины.
        if (HalStreamOwner.activeOut() != HalStreamOwner.OUT_FLUTTER) {
            try { HalStreamOwner.stopAll() } catch (_: Throwable) {}
        }
        marker("destroy: ${ident()}")
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Explicit stop only — a null intent is a STICKY resurrection
        // and must fall through to the relaunch path below.
        if (intent?.action == ACTION_STOP) {
            // v0.1.83+182: явный отказ владельца снимает и подписку.
            // Иначе выключенный автозапуск продолжал бы писать журнал —
            // тумблер, который выключает уведомление и не выключает
            // работу, это ровно тот класс лжи, что лечил +173.
            HalStreamOwner.journalSnapshot()?.let { marker("hal-bg: $it") }
            try { HalStreamOwner.stopAll() } catch (_: Throwable) {}
            stopping = true
            marker("stop: explicit ACTION_STOP · ${ident()}")
            stopSelf()
            return START_NOT_STICKY
        }

        // v0.1.70+169: null intent = system-driven STICKY relaunch.
        val resurrected = intent == null
        // v0.1.72+171: третий путь наверх — мост из BootReceiver.
        // Владельца в нём нет ровно так же, как в воскрешении, поэтому
        // нотификация для обоих одна: «поднялся сам».
        val bridged = intent?.action == ACTION_BRIDGE
        lastHeadless = resurrected || bridged
        startForeground(NOTIF_ID, buildNotification(lastHeadless))

        // v0.1.83+182: СБОР. Поднимается на всех трёх путях, включая ARM.
        //
        // Почему и на ARM тоже, хотя владелец в этот момент открывает
        // приложение: между `arm` из MainActivity и `halStreamStart` из
        // Dart проходит вся инициализация HalTelemetryService, и это
        // секунды на холодном старте. Подписка одна на процесс, так что
        // поднять её раньше — не вторая подписка, а та же самая, и Dart
        // просто заберёт её себе. Заодно снимается зависимость от того,
        // чем именно кончится инициализация Dart.
        //
        // На РАБОЧЕМ потоке: внутри отражение и обходы registerListener,
        // а onStartCommand — главный поток с лимитом ANR. Ошибку
        // записываем строкой: сервис обязан подняться даже если HAL
        // недоступен (телефон, чужая прошивка), а не падать.
        startCollectingAsync()

        if (resurrected) {
            // HEADLESS. Никакого startActivity: из фона он всё равно
            // не проходит, а маркер «attempted-no-throw» вводил в
            // заблуждение. `flags` пишем сырыми — в них живут
            // START_FLAG_REDELIVERY (1) и START_FLAG_RETRY (2), и
            // ненулевое значение отличило бы повтор доставки от
            // обычного sticky-перезапуска.
            marker("resurrected: headless flags=$flags · ${ident()}")
        } else if (bridged) {
            // Строка, ради которой сделан весь патч. Её появление БЕЗ
            // предшествующего `armed:` и означает, что ГУ поднял нас
            // сам. Перед ней в том же файле обязана стоять пара
            // FIRED/ALARM_SCHEDULED → OK от ресивера.
            marker("bridged: $ACTION_BRIDGE · flags=$flags · ${ident()}")
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
     *
     * v0.1.72+171: параметр назывался `resurrected`, но путей наверх
     * без владельца стало два — sticky-воскрешение и мост. Разделять
     * их НА ЭКРАНЕ незачем: владельцу важно одно — приложение
     * поднялось само и ждёт нажатия, чтобы начать писать. Какой
     * именно путь сработал, различает маркер.
     */
    private fun buildNotification(headless: Boolean = false): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "BZ5 Companion autostart",
                        NotificationManager.IMPORTANCE_MIN
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
                if (headless) {
                    // v0.1.74+173: прежний текст «нажмите, чтобы
                    // записывать» обещал больше, чем есть. Сборщика у
                    // companion нет: сбор живёт в BydNativePlugin
                    // внутри Flutter-движка внутри активити, и нажатие
                    // всего лишь откроет приложение. Пока это так,
                    // надпись обязана описывать состояние, а не звать
                    // к действию с несуществующим результатом.
                    // v0.1.83+182: прежний текст «сбор начнётся при
                    // открытии» был честен ровно до этого патча — сбора
                    // за тумблером действительно не было. Теперь есть, и
                    // надпись обязана называть его настоящее состояние, а
                    // не факт срабатывания автозапуска.
                    "автозапуск сработал · ${collectingText()}"
                } else {
                    "автостарт взведён · ${collectingText()}"
                }
            )
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    /**
     * Переписать надпись уведомления под текущее состояние сбора.
     *
     * Существует потому, что `startForeground` зовётся ДО того, как
     * подписка сделана: в тот момент честно сказать можно только
     * «поднимаю». Дальше состояние узнаётся, и надпись обязана его
     * догнать — иначе на экране машины навсегда останется обещание.
     *
     * Отказ NotificationManager проглатывается: надпись — удобство, а
     * сбор от неё не зависит. Числа всё равно уедут в маркер.
     */
    private fun refreshNotification() {
        if (stopping) return
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(lastHeadless))
        } catch (t: Throwable) {
            // Молча — см. выше.
        }
    }

    /**
     * ЧТО НАПИСАНО НА ЭКРАНЕ МАШИНЫ ПРО СБОР. Четыре состояния, и ни одно
     * не выдаёт себя за другое.
     *
     * Различать «подписались» и «получаем события» ОБЯЗАТЕЛЬНО.
     * Вендоренный `SubscriptionStatus` предупреждает прямо: цель может
     * зарегистрироваться и не отдать ни одного события (silent push
     * wall). Разница между этими двумя и есть главное неизвестное окна —
     * склей их в одну надпись, и мы прочитали бы с фотографии ответ,
     * которого не получали.
     */
    private fun collectingText(): String {
        val seen = HalStreamOwner.journalSeen()
        return when {
            seen == null -> "сбор не поднят"
            seen > 0L -> "идёт сбор, событий $seen"
            HalStreamOwner.status().targetsRegistered > 0 ->
                "сбор поднят, событий пока нет"
            else -> "HAL не отвечает, сбора нет"
        }
    }

    /**
     * Поднять подписку HAL на рабочем потоке и записать исход строкой.
     *
     * Строка `hal-start:` — это ответ на «дошли ли мы вообще до
     * регистрации», а `hal-bg:` (биение) — на «пошли ли события».
     * Различать их обязательно: ноль зарегистрированных целей и нуль
     * событий при восьми зарегистрированных — разные диагнозы с
     * разными следующими шагами.
     */
    private fun startCollectingAsync() {
        Thread {
            try {
                val st = HalStreamOwner.startForBackground(applicationContext)
                marker(
                    "hal-start: attempted=${st.targetsAttempted}" +
                        " registered=${st.targetsRegistered}" +
                        " failed=${st.targetsFailed}" +
                        " out=${HalStreamOwner.activeOut()}" +
                        " engine=${HalStreamOwner.engineTag() ?: "-"}"
                )
                // Надпись на экране машины обязана догнать факт: до этой
                // строки она говорила «поднимаю сбор», и это было верно
                // ровно до сих пор. Плюс отложенная проверка через 15 с —
                // поездка короче пяти минут иначе так и осталась бы с
                // текстом «событий пока нет» при работающем потоке.
                hbHandler.post { refreshNotification() }
                hbHandler.postDelayed({ refreshNotification() }, 15_000L)
                if (st.targetsFailed > 0) {
                    // Причины по целям, а не общий вердикт: именно они
                    // отличают «класс не найден» (не та прошивка) от
                    // «отказано» (не выданы COMMON-разрешения).
                    for ((k, v) in st.perTargetErrors) {
                        marker("hal-fail: $k · $v")
                    }
                }
            } catch (t: Throwable) {
                marker("hal-start: threw ${t.javaClass.simpleName}: ${t.message}")
            }
        }.apply { name = "bz5-hal-bg-start"; isDaemon = true }.start()
    }

    /** versionName приложения; «?» если PackageManager отказал. */
    private fun appVersion(): String = AutostartMarker.appVersion(this)

    /**
     * Append-only полевой маркер — рецепт recon p112/p113.
     *
     * v0.1.71+170 дал ему запасной путь: публичные Downloads, при
     * отказе — приватная папка приложения, о чём файл сообщает сам.
     * Поле 28.07 подтвердило, что публичный путь на этой прошивке
     * мёртв, и приватная копия — единственный читаемый канал; она
     * уезжает в экспортный ZIP как `autostart_marker.txt`.
     *
     * v0.1.72+171: тело переехало в AutostartMarker, потому что писать
     * в этот файл теперь должны двое — сервис и BootReceiver. Здесь
     * остаётся обёртка: call-site короче, а главное — весь класс
     * продолжает читаться как «пишу в маркер», а не «зову объект».
     */
    private fun marker(line: String) = AutostartMarker.write(this, line)
}
