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

import 'package:flutter/services.dart';

import 'hal_telemetry_service.dart';

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
    if (_optOut == true) return;
    _armed = true;
    await _ch.invokeMethod<bool>('arm').catchError((_) => false);
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
