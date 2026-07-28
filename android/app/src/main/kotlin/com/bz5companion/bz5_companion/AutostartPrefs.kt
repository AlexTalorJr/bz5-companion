package com.bz5companion.bz5_companion

import android.content.Context

/**
 * v0.1.72+171 — ФЛАГ ВЗВОДА, ПЕРЕЖИВАЮЩИЙ ПРОЦЕСС.
 *
 * До этого патча взвод был транзиентным: Dart звал `arm` через
 * MethodChannel один раз за запуск, и всё знание о том, что автозапуск
 * нужен, жило в живом сервисе. Ресиверу, который просыпается на
 * BOOT_COMPLETED в процессе, где ещё нет ни Flutter-движка, ни
 * сервиса, спросить об этом было нечего.
 *
 * Пишется ровно там же, где раньше только слался Intent — в обработчике
 * `arm`/`disarm` в MainActivity. Dart-сторона (AutostartArm) не
 * меняется: она за гейтом `canUseHal`, поэтому на телефоне флаг НИКОГДА
 * не выставляется, и ресивер там сам собой становится пустышкой — той
 * же честностью, что и вкладка «Замеры».
 *
 * commit(), а не apply(): флаг ставится один раз за запуск, цена
 * синхронной записи одного boolean неизмерима, а apply() — отложенная
 * запись, и ГУ, который убивает процессы жёстко (за 28.07 ни одной
 * строки `destroy:` в маркере), может её не дождаться. Терять флаг
 * нельзя: без него следующее пробуждение пройдёт мимо.
 */
object AutostartPrefs {
    private const val PREFS = "bz5_autostart"
    private const val KEY_ARMED = "armed"

    /** По умолчанию false: свежая установка молчит, пока приложение не
     *  открыли хотя бы раз. Это не ограничение, а факт — из
     *  stopped-state ресивер всё равно не получает broadcast. */
    fun isArmed(context: Context): Boolean = try {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ARMED, false)
    } catch (t: Throwable) {
        false
    }

    fun setArmed(context: Context, armed: Boolean) {
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ARMED, armed).commit()
        } catch (t: Throwable) {
            // Молча: отказ prefs не должен ронять открытие приложения.
            // Следствие — ресивер не сработает, и это видно по маркеру.
        }
    }
}
