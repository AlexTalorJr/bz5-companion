// v0.1.56+155 — Dart side of the autostart net (вариант D).
//
// Arms AutostartService once per app launch, but ONLY on the head
// unit: the same canUseHal honesty gate as the «Замеры» tab — a phone
// has nothing to auto-collect, so it never gets a sticky service or a
// permanent notification. Waits for the platform-probe verdict via a
// listener because canUseHal settles asynchronously (+83/+139).
//
// This is the «начальный завод» the START_STICKY contract requires:
// the service must be started once by the app before ActivityManager
// will resurrect it. Every launch re-arms (idempotent — the service
// just refreshes its notification).
//
// v0.1.74+173 — У АВТОЗАПУСКА ПОЯВИЛСЯ ВЫКЛЮЧАТЕЛЬ.
//
// `disarm` висел в MethodChannel с +155 и не вызывался отсюда НИКОГДА.
// Пока всё держалось на START_STICKY, это сходило с рук: выключение
// происходило само собой — процесс умирал и не воскресал. С мостом
// +171 сервис поднимается на каждом пробуждении ГУ, и прекратить это
// стало нечем, кроме удаления приложения. Механизм, который
// включается тихо и не выключается вообще, — не механизм, а ловушка.
//
// Ключевая тонкость в том, что одного взвода мало: `attach` зовёт
// `arm` при КАЖДОМ запуске на ГУ, поэтому без памяти об отказе
// следующий же запуск приложения молча взвёл бы автозапуск обратно.
// Отсюда третье состояние на нативной стороне (см. AutostartPrefs):
// «не решали» ≠ «выключено».

// v0.1.94+193 — ПРОПУСК ПЕРЕСТАЛ БЫТЬ МОЛЧАЛИВЫМ.
//
// Поле 03–04.08 закрыло вопрос, ради которого этот файл читали: наш
// маркер несёт `autostart=on` 24 строками и ни одной `off`, мост
// планирует будильник на каждом системном действии и доводит до
// `bridged:`. Механизм исправен. Улика «autostart=off · SKIPPED_DISABLED»
// пришла из ЧУЖОГО журнала: companion пишет `bz5_companion_autostart_log`
// (+ номер сборки в публичном зеркале), а строка того класса живёт в
// файле с другим именем и другим форматом времени.
//
// Чинить, стало быть, нечего — но узнать это стоило разбора экспорта, а
// не одного взгляда на экран. Поэтому патч добавляет ровно то, чего не
// хватало для взгляда: КАЖДАЯ попытка взвода оставляет строку, включая
// ту, которая раньше уходила молчаливым `return`. Отказ владельца больше
// не выглядит как неработающий механизм.

import 'package:flutter/services.dart';

import 'hal_telemetry_service.dart';

/// Тройное состояние автозапуска. «Не решали» — это ОТСУТСТВИЕ решения, а
/// не третье значение флага: на нативной стороне оно кодируется парой
/// `armed=false, opt_out=false` (см. AutostartPrefs).
enum AutostartState { undecided, on, offByOwner }

class AutostartArm {
  AutostartArm._();

  static const MethodChannel _ch = MethodChannel('bz5/autostart');
  static bool _armed = false;
  static bool _resolving = false;

  /// Кэш отказа владельца. `null` — ещё не спрашивали. Кэш нужен
  /// потому, что слушатель HAL срабатывает часто, а ходить в канал на
  /// каждое уведомление незачем.
  static bool? _optOut;

  /// Attach to the HAL service and arm as soon as (and only if) the
  /// head-unit verdict lands. Safe to call once from main().
  static void attach(HalTelemetryService hal) {
    void tryArm() {
      if (_armed || _resolving || !hal.canUseHal) return;
      _resolving = true;
      _armIfAllowed().whenComplete(() => _resolving = false);
    }

    tryArm();
    hal.addListener(tryArm);
  }

  static Future<void> _armIfAllowed() async {
    _optOut ??= await _flag('optedOut');
    if (_optOut == true) {
      // v0.1.94+193: раньше здесь стоял голый `return`, и отказ владельца
      // был неотличим от неработающего взвода — ровно та неразличимость,
      // которая стоила окна разбора чужого журнала. Строку пишет натив: у
      // маркера один писатель на процесс, и вторую лестницу записи
      // заводить нельзя (см. AutostartMarker).
      await _ch
          .invokeMethod<bool>('armSkipped')
          .catchError((_) => false);
      return;
    }
    _armed = true;
    await _ch.invokeMethod<bool>('arm').catchError((_) => false);
  }

  /// Настоящее тройное состояние, прочитанное с нативной стороны — той
  /// самой, что читает BootReceiver. Dart-кэш `_armed` для показа не
  /// годится: он говорит лишь «звали ли мы `arm` в этом запуске».
  static Future<AutostartState> state() async {
    if (await _flag('isArmed')) return AutostartState.on;
    return await _flag('optedOut')
        ? AutostartState.offByOwner
        : AutostartState.undecided;
  }

  /// Журнал автозапуска целиком (хвост до 64 КБ) — чтобы уехал
  /// диаг-дампом, а не внутри экспортного ZIP. Тот канал 29.07 дважды
  /// доставил обрезанный архив; диаг-дамп доезжал целым каждый раз.
  static Future<String> marker() async {
    try {
      return await _ch.invokeMethod<String>('marker') ??
          '(пустой ответ канала)';
    } catch (e) {
      return '(маркер недоступен: $e)';
    }
  }

  /// ЗАПИСЬ СТРОКИ В ТОТ ЖЕ ФАЙЛ-ЖУРНАЛ. v0.1.97+196.
  ///
  /// До этого патча всё, что происходило с архивом ПОСЛЕ приёма файла,
  /// писалось только через `debugPrint` — то есть в кольцо в памяти,
  /// которое умирает вместе с процессом. А восстановление процесс как
  /// раз убивает: приложение закрывает себя, чтобы подменить базу до
  /// открытия. Поэтому причину отказа не видел никто и никогда, и три
  /// визита подряд разбирались вслепую.
  ///
  /// Файл-журнал переживает и смерть процесса, и перезапуск, и уезжает
  /// внутри архива экспорта сам. Нативная сторона уже умеет в него
  /// писать — здесь только дверь к ней.
  ///
  /// Молча глотает отказ канала: журнал — это наблюдение, и уронить
  /// из-за него восстановление было бы обменом ценного на дешёвое.
  static Future<void> write(String line) async {
    try {
      await _ch.invokeMethod<void>('markerWrite', {'line': line});
    } catch (_) {}
  }

  /// Взведён ли автозапуск сейчас — читается с нативной стороны, а не
  /// хранится второй копией здесь: единственный источник правды тот
  /// же, что читает BootReceiver.
  static Future<bool> isArmed() => _flag('isArmed');

  /// Включить. Снимает отказ владельца.
  static Future<void> enable() async {
    _optOut = false;
    _armed = true;
    await _ch.invokeMethod<bool>('arm').catchError((_) => false);
  }

  /// Выключить. Запоминает отказ, иначе следующий запуск взведёт
  /// обратно.
  static Future<void> disable() async {
    _optOut = true;
    _armed = false;
    await _ch.invokeMethod<bool>('disarm').catchError((_) => false);
  }

  static Future<bool> _flag(String method) async {
    try {
      return await _ch.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      // Канала нет — значит и автозапуска нет. На телефоне это норма.
      return false;
    }
  }
}
