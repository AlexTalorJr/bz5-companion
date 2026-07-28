package com.bz5companion.bz5_companion

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * v0.1.72+171 — МОСТ АВТОЗАПУСКА.
 *
 * ЗАЧЕМ. Опыт +169/+170 закрыт с отрицательным результатом: за 28.07 в
 * маркере три строки `born:`, и все три идут в паре с
 * `armed: com.bz5companion.ARM` — то есть приложение каждый раз
 * открывал владелец. Ни одной строки `resurrected:`; START_STICKY не
 * воскресил ничего. Ни одной строки `destroy:` — процесс убивают
 * жёстко, и перезапуск система не планирует. При этом на том же
 * железе в тот же день recon вставал САМ за 7–8 секунд после каждого
 * из четырёх пробуждений ГУ. Разница между двумя приложениями ровно
 * одна: у recon есть ресивер, у companion его нет (снят в +155 по
 * раннему ошибочному выводу о «стене boot-пути»).
 *
 * КАК. Рецепт recon p115, подтверждённый его ресиверным логом:
 *
 *     12:29:38  FIRED  BOOT_COMPLETED            → ALARM_SCHEDULED
 *     12:29:46  FIRED  ...AUTOSTART_ALARM        → OK
 *
 * Ресивер НЕ пытается поднять foreground-сервис прямо из
 * boot-контекста: стена `mAllowStartForeground` (p113) там жива и
 * бросает ForegroundServiceStartNotAllowedException. Вместо этого он
 * ставит будильник НА СЕБЯ и выходит. Сработавший будильник кладёт
 * приложение во временный allowlist, и уже из этого контекста
 * startForegroundService разрешён. Задержка в 250 мс — номинал; в
 * поле между двумя строками проходит 5–8 секунд, потому что ГУ в этот
 * момент занят собой. Это нормально и на критерий не влияет.
 *
 * ТРИ СИСТЕМНЫХ ДЕЙСТВИЯ, а не одно. BOOT_COMPLETED на этой прошивке
 * рассылается и при перезапуске фреймворка поверх живого ядра (лог
 * recon: FIRED при uptime в сутки), QUICKBOOT_POWERON — вариант для
 * быстрого старта, MEDIA_MOUNTED ловит момент, когда ГУ поднял
 * хранилище. Дедуп не нужен: PendingIntent один и тот же, и второй
 * setAlarmClock заменяет первый, а не добавляет второй. Поле это
 * подтверждает — 19:16:59 MEDIA_MOUNTED и 19:17:03 BOOT_COMPLETED
 * дали ОДНО срабатывание в 19:17:11.
 *
 * ЧЕГО ЭТОТ ПАТЧ НЕ ДЕЛАЕТ. Поднимается существующий
 * AutostartService, который ничего не собирает: сборщика у companion
 * нет вообще (единственный <service> в манифесте — этот, а сбор живёт
 * в BydNativePlugin внутри Flutter-движка внутри активити). Здесь
 * проверяется ЦЕПОЧКА — доходит ли управление до нашего кода без
 * участия владельца. Headless-сбор — отдельный проект.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        /** Собственное действие моста. Приходит явным intent'ом от
         *  AlarmManager, но объявлено и в манифесте — в точности как у
         *  recon, чей путь проверен в поле; расходиться с работающим
         *  рецептом ради косметики не стоит целой поездки. */
        const val ACTION_ALARM = "com.bz5companion.AUTOSTART_ALARM"

        /** Номинал задержки. Меньше не нужно: цель не в скорости, а в
         *  смене контекста с boot на alarm. */
        private const val BRIDGE_DELAY_MS = 250L

        /** Один код запроса на всё — так все системные действия
         *  сходятся в ОДИН PendingIntent и один будильник. */
        private const val REQ_ALARM = 4152

        /** Отдельный код: показной intent — активити, а не broadcast,
         *  и делить код с мостом он не должен. */
        private const val REQ_SHOW = 4153
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: "null"
        val armed = AutostartPrefs.isArmed(context)
        AutostartMarker.write(
            context,
            "FIRED action=$action autostart=${if (armed) "on" else "off"}" +
                " sdk=${Build.VERSION.SDK_INT} build=" +
                AutostartMarker.appVersion(context)
        )
        AutostartMarker.noteFallback(context)

        if (!armed) {
            // Телефон или свежая установка, которую ещё не открывали.
            AutostartMarker.write(
                context, "START action=$action result=NOT_ARMED"
            )
            return
        }

        if (action == ACTION_ALARM) {
            raiseService(context, action)
        } else {
            scheduleBridge(context, action)
        }
    }

    /** Первая ступень: будильник на себя из boot-контекста. */
    private fun scheduleBridge(context: Context, action: String) {
        try {
            // Внутри try, а не до него: `as AlarmManager` по null бросит
            // и убьёт onReceive БЕЗ строки в маркере, а весь смысл этого
            // файла в том, что всякая попытка оставляет след. Ни одна
            // ветка здесь не имеет права умереть молча.
            val am =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + BRIDGE_DELAY_MS
            // На Android 12 SCHEDULE_EXACT_ALARM выдаётся автоматически по
            // одному объявлению в манифесте, но пользователь может его
            // отозвать, а на 14+ автоматической выдачи уже нет. Если
            // точность недоступна — ставим неточный будильник и ПИШЕМ об
            // этом: exact=no в маркере объяснит, почему мост стал
            // срабатывать через минуты или почему перестал совсем
            // (временный allowlist даётся именно точному будильнику).
            val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                am.canScheduleExactAlarms()
            } else {
                true
            }
            if (exact) {
                am.setAlarmClock(
                    AlarmManager.AlarmClockInfo(at, showIntent(context)),
                    bridgeIntent(context)
                )
            } else {
                am.set(AlarmManager.RTC_WAKEUP, at, bridgeIntent(context))
            }
            AutostartMarker.write(
                context,
                "START action=$action result=ALARM_SCHEDULED" +
                    " delay=${BRIDGE_DELAY_MS}ms" +
                    " exact=${if (exact) "yes" else "no"}"
            )
        } catch (t: Throwable) {
            AutostartMarker.write(
                context,
                "START action=$action result=ALARM_ERR" +
                    " ${t.javaClass.simpleName}: ${t.message}"
            )
        }
    }

    /** Вторая ступень: из alarm-контекста FGS разрешён. */
    private fun raiseService(context: Context, action: String) {
        try {
            val i = Intent(context, AutostartService::class.java)
                .setAction(AutostartService.ACTION_BRIDGE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
            AutostartMarker.write(
                context, "START action=$action result=OK"
            )
        } catch (t: Throwable) {
            // Сюда попадает ForegroundServiceStartNotAllowedException,
            // если временного allowlist не случилось. Имя класса в
            // маркере отличит эту стену от любой другой поломки.
            AutostartMarker.write(
                context,
                "START action=$action result=ERR" +
                    " ${t.javaClass.simpleName}: ${t.message}"
            )
        }
    }

    private fun bridgeIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            REQ_ALARM,
            Intent(context, BootReceiver::class.java).setAction(ACTION_ALARM),
            piFlags()
        )

    /**
     * Что показать, если система захочет показать этот будильник.
     *
     * Документация разрешает здесь null, и recon так и делает, но
     * проверить поведение ЭТОЙ прошивки на пустом showIntent нечем, а
     * цена ошибки — поездка: NPE внутри AlarmManager убил бы мост
     * целиком и молча. Открытие MainActivity — законный и осмысленный
     * ответ на «покажи детали будильника», стоит он одного объекта, и
     * допущение снимает.
     */
    private fun showIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQ_SHOW,
            Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
            piFlags()
        )

    /** FLAG_IMMUTABLE обязателен с Android 12 и существует с API 23. */
    private fun piFlags(): Int {
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return flags
    }
}
