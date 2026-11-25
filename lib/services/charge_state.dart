// v0.2.37+236 — ЭТАП ЗАРЯДКИ, «ЗАЛИТО» ПО СЧЁТЧИКУ, СВЕРКА НАРУЖНОЙ
// ТЕМПЕРАТУРЫ. Чистый Dart без Flutter и без платформы: решения этого
// файла проверяются тестом (test/charge_state_test.dart) и зеркалом
// (tools/mirror_plus236_charge.py). HalTelemetryService только подаёт
// сюда значения и читает ответ.
//
// Источник правил — recon v0.10.159 (Друг 3, зарядки AC 13–14.11 и DC
// 20.11):
//   CHARGING_BATTERRY_DEVICE_STATE: 15 покой, 0 старт, 1 зарядка,
//     2 остановка; одинаково на AC и DC. 15 — НЕ «сессии нет» (Друг 3,
//     21.11): на DC 20.11 состояние оставалось 15 ещё 135 с после вставки
//     пистолета, а после конца зарядки двойка держится секунды и сменяется
//     на 15 при вставленном кабеле. Сессии нет, только когда нет пистолета.
//   CHARGING_GUN_CONNECT_STATE (шкала HAL): 1 нет, 2 AC, 3 DC. В firehose
//     то же поле идёт со сдвигом (0/1/2) — к шкале HAL его приводит
//     вызывающий.
//   CHARGING_TYPE (firehose): 8 не заряжается, 9 AC, 11 DC.
//   Счётчик 0x2D0 `gb_cycle_regen_kwh`: вся энергия в батарею, шаг 0.1
//     кВт·ч, кадр раз в 30 с; правило сброса не известно, падение
//     значения — сброс.

/// Этап сессии зарядки. `null` у [chargeStageOf] — состояние не известно
/// (значение DEVICE_STATE ещё не приходило), решает запасной путь.
enum ChargeStage {
  /// Сессии нет: пистолета нет (либо DEVICE_STATE 15 и пистолет не
  /// известен).
  none,

  /// Пистолет вставлен, DEVICE_STATE 15, зарядки в этом подключении ещё не
  /// было: подключено, зарядка не идёт.
  plugged,

  /// DEVICE_STATE 0: машина и станция договариваются.
  handshake,

  /// DEVICE_STATE 1: зарядка идёт.
  charging,

  /// DEVICE_STATE 2, либо 15 после зарядки в этом подключении: закончена.
  finished,
}

/// Этап по DEVICE_STATE и пистолету (шкала HAL: 1 нет, 2 AC, 3 DC).
/// [chargedThisPlugIn] — в этом подключении зарядка уже шла
/// ([nextChargedThisPlugIn]).
///
/// Таблица Друга 3 (21.11):
///   пистолета нет, любое состояние            → сессии нет;
///   вставлен, 15, зарядки ещё не было         → подключено, не идёт;
///   вставлен, 0                               → согласование;
///   вставлен, 1                               → идёт;
///   вставлен, 2 либо 15 после зарядки         → закончена.
///
/// Пистолет «нет» закрывает сессию при любом DEVICE_STATE: на отключении
/// AC пистолет уходит в 1 раньше, чем DEVICE_STATE проходит 2 → 15.
/// Пистолет не известен: 0/1/2 говорят сами за себя, а по 15 сказать
/// «подключено» нечем — сессии нет. Неизвестное значение DEVICE_STATE —
/// `null`, а не «нет сессии»: молча закрыть экран по числу, которого нет в
/// таблице, хуже, чем отдать решение запасному пути.
ChargeStage? chargeStageOf({
  double? deviceState,
  double? gun,
  bool chargedThisPlugIn = false,
}) {
  if (deviceState == null) return null;
  final int ds = deviceState.round();
  if (ds != 0 && ds != 1 && ds != 2 && ds != 15) return null;
  if (gun != null && gun.round() == 1) return ChargeStage.none;
  switch (ds) {
    case 0:
      return ChargeStage.handshake;
    case 1:
      return ChargeStage.charging;
    case 2:
      return ChargeStage.finished;
    default:
      if (gun == null) return ChargeStage.none;
      return chargedThisPlugIn ? ChargeStage.finished : ChargeStage.plugged;
  }
}

/// Признак «в этом подключении зарядка уже шла» после очередных значений.
/// Ставится состоянием 1 или 2, снимается, когда пистолета нет; иначе
/// держится. Состояние 15 его не снимает: это и есть «закончена, кабель
/// вставлен».
bool nextChargedThisPlugIn(bool prev, {double? deviceState, double? gun}) {
  if (gun != null && gun.round() == 1) return false;
  if (deviceState != null) {
    final int ds = deviceState.round();
    if (ds == 1 || ds == 2) return true;
  }
  return prev;
}

/// «AC» / «DC» по пистолету (шкала HAL) либо по типу зарядки firehose.
/// Пистолет первым: он известен с момента вставки, тип — только когда
/// зарядка уже идёт.
String? chargeTypeOf({double? gun, double? fhType}) {
  if (gun != null) {
    final int g = gun.round();
    if (g == 3) return 'DC';
    if (g == 2) return 'AC';
  }
  if (fhType != null) {
    final int t = fhType.round();
    if (t == 11) return 'DC';
    if (t == 9) return 'AC';
  }
  return null;
}

/// «Залито» за сессию по счётчику `gb_cycle_regen_kwh`.
///
/// Сумма приростов от открытия сессии.
///
/// v0.2.38+237 — ПОДТВЕРЖДЕНИЕ ВТОРЫМ КАДРОМ (recon v0.10.160, Друг 3).
/// Счётчик обнуляется при каждом включении машины, а одиночный ноль сразу
/// после пробуждения бывает ложным (13.11 17:44: 0, затем прежние 5.9).
/// Поэтому ни первый кадр потока, ни упавшее значение сразу базой не
/// становятся: кадр — кандидат, и базой его делает следующий кадр, если
/// он не меньше кандидата и не больше его на [maxStepKwh] (больше за
/// кадр в 30 с не зарядить). Следующий кадр вернулся к прежнему значению
/// или выше — кандидат был ложным, счёт идёт от прежнего. Цена: сумма
/// начинает расти на один кадр позже.
///
/// Рядом копится контроль — ∫V·I по току батареи за ту же сессию. На экран
/// он не идёт; расхождение со счётчиком видно в app_log ([diverged]).
class ChargedEnergyCounter {
  /// Интервал между событиями HAL длиннее этого в интеграл не идёт.
  static const double integralMaxGapS = 120.0;

  /// Наибольший прирост между кандидатом и подтверждающим кадром.
  static const double maxStepKwh = 2.0;

  double? _last;

  /// Кандидат в базу: первый кадр потока или упавшее значение.
  double? _pend;
  bool _open = false;
  bool _hasBase = false;
  double _sum = 0;

  /// База взята до начала зарядки. false — сессия подхвачена на ходу
  /// (поток стартовал посреди зарядки), сумма идёт с первого кадра.
  bool fromStart = false;
  int resets = 0;
  double integralKwh = 0;

  bool get isOpen => _open;

  /// Сумма по счётчику, кВт·ч. null — сессии нет либо базы ещё нет.
  double? get kwh => _open && _hasBase ? _sum : null;

  /// Кадр счётчика. Вне сессии значение только запоминается как база.
  void feed(double v) {
    final last = _last;
    final pend = _pend;
    if (pend != null) {
      if (v >= pend && v - pend <= maxStepKwh) {
        // Кандидат удержался: он и есть база (после падения — сброс).
        _pend = null;
        if (last != null) resets++;
        _last = v;
        if (_open) {
          _hasBase = true;
          _sum += v - pend;
        }
        return;
      }
      if (last != null && v >= last) {
        // Вернулось прежнее значение: кандидат был ложным кадром.
        _pend = null;
        _last = v;
        if (_open && _hasBase) _sum += v - last;
        return;
      }
      _pend = v;
      return;
    }
    if (last == null || v < last) {
      _pend = v;
      return;
    }
    _last = v;
    if (_open && _hasBase) _sum += v - last;
  }

  /// Открыть сессию. [beforeCharging] — зарядка в этот момент ещё не идёт
  /// (этап «согласование» или кабель только вставлен): база, пришедшая
  /// позже, всё равно считается базой «с начала».
  void open({required bool beforeCharging}) {
    if (_open) return;
    _open = true;
    _sum = 0;
    resets = 0;
    integralKwh = 0;
    _hasBase = _last != null;
    fromStart = _hasBase || beforeCharging;
  }

  void close() {
    _open = false;
  }

  /// Поток остановлен: значение счётчика устарело, базой быть не может.
  void forget() {
    _open = false;
    _hasBase = false;
    _last = null;
    _pend = null;
  }

  /// Контроль: мощность батареи [kw] (минус — в батарею), удержанная
  /// [dtS] секунд.
  void addIntegral(double? kw, double dtS) {
    if (!_open || kw == null) return;
    if (dtS <= 0 || dtS > integralMaxGapS) return;
    if (kw < 0) integralKwh += -kw * dtS / 3600.0;
  }

  /// Счётчик и ∫V·I разошлись больше чем на 0.5 кВт·ч и на 15 %.
  bool get diverged {
    final c = kwh;
    if (c == null) return false;
    final hi = c > integralKwh ? c : integralKwh;
    if (hi < 2.0) return false;
    final d = (c - integralKwh).abs();
    return d > 0.5 && d > 0.15 * hi;
  }
}

/// Сверка наружной температуры firehose (`fh_temp_out_c`) с событием HAL
/// `ac_temp_out`.
///
/// HAL шлёт температуру только на изменение и без первого значения после
/// старта потока, поэтому сравнивать можно только в момент события: оно
/// по построению свежее. После события firehose (около 1 Гц) обязан
/// показать то же число в пределах [holdMs]; экспорт 21.11 — 28 событий из
/// 28, один раз с отставанием на отсчёт. Не показал — [untrusted] до
/// [resetForTrip]: такты атласа до конца поездки идут в «t° неизвестна».
class OutsideTempCheck {
  static const int holdMs = 10000;

  bool untrusted = false;
  String? lastDetail;
  double? _expect;
  int? _sinceMs;

  /// Событие HAL. [nowMs] — монотонные часы.
  void feedHal(double c, int nowMs) {
    _expect = c;
    _sinceMs = nowMs;
  }

  /// Значение firehose; true — [untrusted] только что стало true.
  bool feedFirehose(double c, int nowMs) {
    final e = _expect;
    final since = _sinceMs;
    if (e == null || since == null) return false;
    if ((c - e).abs() < 0.5) {
      _expect = null;
      _sinceMs = null;
      return false;
    }
    if (untrusted || nowMs - since < holdMs) return false;
    untrusted = true;
    lastDetail = 'fh_temp_out_c=$c vs ac_temp_out=$e';
    return true;
  }

  void resetForTrip() {
    untrusted = false;
    lastDetail = null;
    _expect = null;
    _sinceMs = null;
  }
}

/// v0.2.39+238 — «ЗАПАСЕНО ЗА СТОЯНКУ» ПО ОСТАТКУ 0x2EE.
///
/// `gb_remaining_energy_kwh` — оценка BMS запасённой энергии, шаг 0.1
/// кВт·ч, кадр около 1 Гц. Пока голова спит, кадров нет; зарядка на
/// стоянке видна как разница между последним значением перед сном и
/// первым после пробуждения (схема Друга 3, 25.11; на 25 стоянках 13–21.11
/// без зарядки остаток не менялся, экспорт 25.11 — 23 перехода из 23).
/// К моменту вставки пистолета счёт не привязан.
///
/// Зарядка при работающей голове сюда не идёт (решение владельца 25.11,
/// вариант А): её показывает «залито» по счётчику 0x2D0. Поэтому рост
/// засчитывается только после перерыва ([afterBreak] у [feed]): первый
/// кадр процесса (последнее значение взято из настроек) либо кадр после
/// паузы потока не короче [breakSeconds]. Короткий пропуск кадров на
/// DC-зарядке (150 кВт — 0.04 кВт·ч в секунду) запасом не становится.
///
/// Скачок больше [minRiseKwh] в любую сторону — кандидат; подтверждает
/// его следующий кадр в пределах [confirmKwh] от кандидата. Ложный
/// одиночный кадр (ноль, мусор) не сдвигает последнее значение и не даёт
/// запаса при возврате к нему.
///
/// Сумма копится до [clear] — начала поездки: несколько пробуждений на
/// одной стоянке складываются.
class StoredEnergyTracker {
  static const double minRiseKwh = 0.2;
  static const double confirmKwh = 0.2;
  static const int breakSeconds = 120;

  /// Значение за пределами — не кадр остатка (батарея 65.28 кВт·ч).
  static const double maxKwh = 80;

  double? _last;
  double? _pend;
  bool _pendAfterBreak = false;
  double _stored = 0;
  bool _has = false;
  bool _loaded = false;

  /// Последнее принятое значение — его сервис хранит в настройках.
  double? get lastKwh => _last;

  /// Запасено с начала стоянки; null — зарядки на стоянке не было.
  double? get storedKwh => _has ? _stored : null;

  /// Сохранённое прежним процессом. До вызова кадры не принимаются:
  /// первый кадр без прежнего значения стал бы базой, и ночная зарядка
  /// потерялась бы.
  void load({double? lastKwh, double? storedKwh}) {
    _last = lastKwh;
    _pend = null;
    _stored = storedKwh ?? 0;
    _has = storedKwh != null;
    _loaded = true;
  }

  /// Кадр остатка. Возвращает подтверждённый рост, засчитанный в запас,
  /// иначе null.
  double? feed(double v, {required bool afterBreak}) {
    if (!_loaded || v <= 0 || v > maxKwh) return null;
    final last = _last;
    if (last == null) {
      _last = v;
      return null;
    }
    if ((v - last).abs() <= minRiseKwh) {
      _pend = null;
      _last = v;
      return null;
    }
    final pend = _pend;
    if (pend == null || (v - pend).abs() > confirmKwh) {
      _pend = v;
      _pendAfterBreak = afterBreak;
      return null;
    }
    _pend = null;
    _last = v;
    final rise = v - last;
    if (rise <= 0 || !_pendAfterBreak) return null;
    _stored += rise;
    _has = true;
    return rise;
  }

  /// Началась поездка: запас стоянки больше не показывается.
  void clear() {
    _stored = 0;
    _has = false;
  }
}
