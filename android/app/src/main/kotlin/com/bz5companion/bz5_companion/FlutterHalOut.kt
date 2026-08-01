package com.bz5companion.bz5_companion

import android.util.Log
import com.bz5companion.bz5_companion.hal.HalOut
import io.flutter.plugin.common.EventChannel

/*
 * v0.1.86+185 — КЛАСС ПЕРЕЕХАЛ СЮДА ИЗ ПАКЕТА `hal`, И ЭТО ТРЕТИЙ ПУНКТ
 * АРХИТЕКТУРНОЙ РЕВИЗИИ.
 *
 * Гейт BP1 утверждал, что расшифровка развязана с Flutter, а мерил это
 * ПО ОДНОМУ ФАЙЛУ: `DecodedStreamSink` не упоминает EventChannel. Файл
 * был чист, пакет — нет. `FlutterHalOut` лежал в `hal` и импортировал
 * `io.flutter`, то есть весь пакет тянул Flutter, и второй выход
 * расшифровки — журнал, который пишется именно тогда, когда Flutter
 * мёртв, — жил в пакете, без Flutter не собиравшемся. Граница проходила
 * не там, где её мерили.
 *
 * Теперь ни один файл в `hal` не знает слова `io.flutter`, а
 * Flutter-адаптер лежит там, где Flutter и так живёт: рядом с плагином,
 * в корневом пакете. Зависимость осталась одна и направлена вниз —
 * корень знает про `hal`, `hal` про корень не знает. Гейт BS7 мерит это
 * грепом по всему каталогу пакета, а не по одному файлу.
 */
/**
 * Прежнее поведение, слово в слово: пакет уходит в EventChannel.
 *
 * `success` обязан зваться с главного потока, и он там и зовётся —
 * DecodedStreamSink сливает очередь через `mainHandler.post`. Класс
 * существует только затем, чтобы EventChannel перестал быть ЕДИНСТВЕННЫМ
 * мыслимым выходом расшифровки.
 */
class FlutterHalOut(private val sink: EventChannel.EventSink) : HalOut {
    /**
     * Отправить пакет, проглотив отказ мёртвого EventSink.
     *
     * До +181 здесь стоял голый `sink.success(batch)` в `drain()`, и это
     * была незамеченная гонка: между разрушением движка Flutter и сменой
     * адресата проходят миллисекунды, а колбэки binder идут все эти
     * миллисекунды. Исключение с ГЛАВНОГО лупера — это не потерянное
     * событие, а падение приложения. Раньше окно было короче (адресат
     * снимался тем же вызовом, что рушил Flutter); теперь смену делает
     * владелец, поэтому окно стало шире, и охрана обязательна.
     */
    override fun emit(batch: List<Map<String, Any?>>) {
        try {
            sink.success(batch)
        } catch (t: Throwable) {
            Log.w("FlutterHalOut", "dead sink: ${t.javaClass.simpleName}")
        }
    }

    override fun close() {
        // Жизненным циклом EventSink владеет Flutter, не мы.
    }

    override val tag: String get() = "flutter"
}
