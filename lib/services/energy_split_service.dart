// v0.2.23+222 — РАЗДЕЛЕНИЕ ЭНЕРГИИ ПОЕЗДКИ: движение / климат и подогрев /
// прочее. v0.2.31+230: модель v2 по току инвертора — движение / климат и
// бортовая сеть ([computeEnergySplitV2], [computeEnergySplitAuto]). v0.2.26+225: живое накопленное разделение открытой поездки
// ([EnergySplitService.live]) той же функцией, доли — [energySplitShares].
//
// Модель Друга 3 (05.11.2026, поездка 399), поправки к схеме согласованы
// 05.11. Коэффициенты — посекундная подгонка (сверка Друг 1 / Друг 3 05.11:
// первые 1.096 / 0.661 подгонялись по знаку окна и к посекундному
// разделению не применимы). После 3–5 поездок на +222 Друг 3 подгонит
// их совместно и пришлёт одну пару. Python-зеркало с самопроверками и прогоном по экспорту:
// tools/mirror_plus222_split.py — числа здесь и там обязаны совпадать.
//
// Считается ОДИН раз на поездку, после её закрытия, по hal_samples этой
// поездки. Единственное место решения — [EnergySplitService]: он один
// выбирает поездки, считает и пишет. Экран только показывает.
//
// Почему наблюдение за таблицей, а не вызов из точки закрытия: поездку
// закрывают пять разных путей (живой HAL, восстановление брошенной,
// фоновый журнал, OBD, импорт). Вызов из каждого был бы пятью местами
// одного решения; наблюдение ловит все, включая досчёт старых поездок
// при первом запуске.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';

/// Константы модели — в одном месте. Меняются патчем по пересчётам
/// Друга 3; при смене коэффициентов меняется и [version], и тогда пересчёт
/// с отправкой заново перезапишет облако (Друг 2, 05.11).
class EnergySplitModel {
  /// Модель v1: момент × обороты, база «прочего». Остаётся у поездок без
  /// тока инвертора (все поездки до +230).
  static const String version = 'v1';

  /// v0.2.31+230 — МОДЕЛЬ v2 (Друг 3, письмо 09.11). «Движение» = ∫V·I_инв,
  /// «климат и бортовая сеть» = ∫V·I_бат − ∫V·I_инв, «прочее» = 0. Каждая
  /// энергия интегрируется отдельно по своему току с удержанием последнего
  /// значения, вычитание — только в конце: покадровая разность токов
  /// шумит до −8.6 кВт. Порог и покрытие — те же, что у v1.
  ///
  /// v0.2.32+231 (Друг 3, письмо по +230; решение владельца 09.11):
  /// движение = тяга − рекуперация, может быть меньше нуля; части v2 НЕ
  /// масштабируются к energy_used_kwh — их сумма равна energy_pack_kwh.
  /// v1 не меняется. Ни одна поездка v2 до +231 на сервер не ушла.
  static const String versionV2 = 'v2';
  static const double kTraction = 1.030;
  static const double kRegen = 0.835;
  static const double baseKw = 0.65;
  /// v0.2.30+229: 600 → 180 (решение владельца 07.11). Прогон зеркала по
  /// экспорту 07.11 без порога: у поездок до 5 мин (8 шт.) медианы
  /// движение 69 % / климат 14 %, 5–10 мин (12) — 66 / 22, длинных (33) —
  /// 67 / 20; покрытие 0.98–1.00; климат в ноль — 1 из 20 коротких.
  /// Модель посекундная, длинные окна ей не нужны; 10 минут были
  /// осторожным порогом исходной схемы, когда коротких данных не было.
  /// Коэффициенты те же — [version] не меняется. Живая строка на
  /// экране вождения подчиняется тому же порогу: «считается…» — 3 мин.
  static const int minTripSeconds = 180;
  static const double minCoverage = 0.8;

  /// Сигналы модели. `pack_voltage_fine` предпочтительнее, `pack_voltage`
  /// — запасной. `motor_power` не годится: целые кВт, на стоянке 1–2 кВт.
  static const List<String> signals = [
    'pack_voltage_fine',
    'pack_voltage',
    'pack_current',
    'motor_torque',
    'motor_rpm',
    // v0.2.31+230: ток инвертора, сигнал модели v2.
    'inverter_current',
  ];
}

class EnergySplitResult {
  final double packKwh;
  final double coverage;
  final int coveredSeconds;
  final double? motionKwh;
  final double? climateKwh;
  final double? otherKwh;
  /// v0.2.31+230: какой моделью посчитано — [EnergySplitModel.version]
  /// или [EnergySplitModel.versionV2].
  final String model;
  /// v0.2.32+231: у v2 — тяга (∫V·I_инв при I > 0) и рекуперация
  /// (∫|V·I_инв| при I < 0), кВт·ч. Только для строки в app_log.
  final double? tractionKwh;
  final double? regenKwh;
  const EnergySplitResult(this.packKwh, this.coverage, this.coveredSeconds,
      this.motionKwh, this.climateKwh, this.otherKwh,
      {this.model = EnergySplitModel.version,
      this.tractionKwh,
      this.regenKwh});
  bool get hasSplit => motionKwh != null;
}

/// v0.2.26+225: доли трёх частей — ОДНО место для карточки истории и
/// живой строки на экране вождения, чтобы последнее живое число совпало
/// с карточкой. null — частей нет или их сумма не положительна.
({double motion, double climate, double other})? energySplitShares(
    double? motion, double? climate, double? other) {
  if (motion == null || climate == null || other == null) return null;
  final sum = motion + climate + other;
  if (sum <= 0) return null;
  return (motion: motion / sum, climate: climate / sum, other: other / sum);
}

/// v0.2.26+225: живое накопленное разделение открытой поездки.
/// [shares] null — «считается…» (короче [EnergySplitModel.minTripSeconds]
/// или мало покрытия).
class LiveEnergySplit {
  final int tripId;
  final ({double motion, double climate, double other})? shares;
  /// v0.2.31+230: модель живого расчёта; у v2 строка «прочего» не нужна.
  final String model;
  const LiveEnergySplit(this.tripId, this.shares,
      {this.model = EnergySplitModel.version});
}

/// Чистая функция, зеркало `split()` в tools/mirror_plus222_split.py.
///
/// Шаг 1 с, удержание последнего значения каждого сигнала с его первого
/// сэмпла в поездке (на стоянке момент и обороты почти не шлют событий —
/// требование сэмпла в каждом окне выбросило бы именно стоянки). Сумма по
/// секундам равна сумме окон по 60 с; окна задают только зерно покрытия.
/// Остаток считается на уровне ПОЕЗДКИ: обрезка по окнам превращала бы шум
/// (±0.8 кВт на окно) в ложный климат.
EnergySplitResult computeEnergySplit(
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
  DateTime end,
) {
  final startS = start.millisecondsSinceEpoch / 1000.0;
  final endS = end.millisecondsSinceEpoch / 1000.0;
  final last = <String, double>{};
  var i = 0;
  var covered = 0;
  var ePack = 0.0;
  var eMotion = 0.0;
  for (var s = startS.ceil(); s < endS; s++) {
    while (i < points.length &&
        points[i].ts.millisecondsSinceEpoch / 1000.0 <= s) {
      last[points[i].name] = points[i].v;
      i++;
    }
    final v = last['pack_voltage_fine'] ?? last['pack_voltage'];
    final cur = last['pack_current'];
    final tq = last['motor_torque'];
    final n = last['motor_rpm'];
    if (v == null || cur == null || tq == null || n == null) continue;
    covered++;
    final pPack = v * cur / 1000.0;
    final pMech = tq * n * 2 * math.pi / 60 / 1000.0;
    final motion = EnergySplitModel.kTraction * math.max(pMech, 0.0) +
        EnergySplitModel.kRegen * math.min(pMech, 0.0);
    ePack += pPack / 3600.0;
    eMotion += motion / 3600.0;
  }
  final dur = endS - startS;
  final cov = dur > 0 ? covered / dur : 0.0;
  if (dur < EnergySplitModel.minTripSeconds ||
      cov < EnergySplitModel.minCoverage ||
      ePack <= 0) {
    return EnergySplitResult(ePack, cov, covered, null, null, null);
  }
  final residual = ePack - eMotion;
  var other = EnergySplitModel.baseKw * covered / 3600.0;
  var climate = residual - other;
  if (climate < 0) {
    climate = 0;
    other = residual;
  }
  return EnergySplitResult(ePack, cov, covered, eMotion, climate, other);
}

/// v0.2.31+230 — МОДЕЛЬ v2, зеркало `split_v2()` в
/// tools/mirror_plus222_split.py.
///
/// Шаг 1 с, удержание последнего значения каждого сигнала с его первого
/// сэмпла, как у v1. ∫V·I_бат, тяга (∫V·I_инв при I > 0) и рекуперация
/// (∫|V·I_инв| при I < 0) копятся по отдельности; движение = тяга −
/// рекуперация, «климат и бортовая сеть» = ∫V·I_бат − движение — на уровне
/// поездки. v0.2.32+231: движение может быть меньше нуля (длинный спуск),
/// оно не обрезается. Если отрицателен климат (шум или поездка почти без
/// нагрузок), климат = 0, движение = вся энергия батареи. Сумма частей
/// всегда равна энергии батареи; «прочее» = 0.
EnergySplitResult computeEnergySplitV2(
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
  DateTime end,
) {
  final startS = start.millisecondsSinceEpoch / 1000.0;
  final endS = end.millisecondsSinceEpoch / 1000.0;
  final last = <String, double>{};
  var i = 0;
  var covered = 0;
  var ePack = 0.0;
  var eTraction = 0.0;
  var eRegen = 0.0;
  for (var s = startS.ceil(); s < endS; s++) {
    while (i < points.length &&
        points[i].ts.millisecondsSinceEpoch / 1000.0 <= s) {
      last[points[i].name] = points[i].v;
      i++;
    }
    final v = last['pack_voltage_fine'] ?? last['pack_voltage'];
    final iBat = last['pack_current'];
    final iInv = last['inverter_current'];
    if (v == null || iBat == null || iInv == null) continue;
    covered++;
    ePack += v * iBat / 1000.0 / 3600.0;
    final pInv = v * iInv / 1000.0 / 3600.0;
    if (pInv > 0) {
      eTraction += pInv;
    } else {
      eRegen -= pInv;
    }
  }
  final dur = endS - startS;
  final cov = dur > 0 ? covered / dur : 0.0;
  if (dur < EnergySplitModel.minTripSeconds ||
      cov < EnergySplitModel.minCoverage ||
      ePack <= 0) {
    return EnergySplitResult(ePack, cov, covered, null, null, null,
        model: EnergySplitModel.versionV2,
        tractionKwh: eTraction,
        regenKwh: eRegen);
  }
  var motion = eTraction - eRegen;
  var climate = ePack - motion;
  if (climate < 0) {
    climate = 0;
    motion = ePack;
  }
  return EnergySplitResult(ePack, cov, covered, motion, climate, 0.0,
      model: EnergySplitModel.versionV2,
      tractionKwh: eTraction,
      regenKwh: eRegen);
}

/// v0.2.31+230: выбор модели — ОДНО место для расчёта после закрытия и
/// живой строки. Есть в поездке хоть один отсчёт тока инвертора — v2,
/// иначе v1 (поездки до +230 и поездки, где поток Engine не пришёл).
EnergySplitResult computeEnergySplitAuto(
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
  DateTime end,
) =>
    points.any((p) => p.name == 'inverter_current')
        ? computeEnergySplitV2(points, start, end)
        : computeEnergySplit(points, start, end);

class EnergySplitService {
  EnergySplitService(this._db);
  final AppDatabase _db;

  /// Поездки, получившие разделение, — CloudSyncService.requeueTrips
  /// (проводка в main.dart). Уже отправленная без разделения поездка
  /// уйдёт ещё раз; сервер обновит строку по client_uuid (Друг 2, §3).
  ///
  /// v0.2.30+229: сюда идёт КАЖДАЯ поездка, которой записалась модель, а
  /// не только получившая части. Короткая поездка получает модель, пак и
  /// покрытие без частей; раньше она повторно не уходила, и если отправка
  /// успевала до расчёта, сервер этих полей не видел (1201–1204, Друг 2
  /// 07.11 §5). Модель без частей ничего на сервере не стирает: частей у
  /// такой поездки там нет — их считает только эта голова.
  void Function(List<int> tripIds)? onTripsSplit;

  /// v0.2.30+229: разовый пересчёт поездок с моделью без частей под
  /// новый порог (см. [_recomputePartless]). Ключ привязан к базе —
  /// ImportService снимает его при импорте архива.
  static const String recomputeKey = 'energy_split_recompute_229';

  StreamSubscription<List<Trip>>? _sub;
  bool _busy = false;
  bool _again = false;

  /// v0.2.26+225: живое разделение открытой поездки для TripMetricsPanel.
  /// null — открытой поездки нет или у неё нет данных HAL (строка
  /// скрыта). Считает та же [computeEnergySplit] по тем же сигналам
  /// hal_samples поездки от начала до сейчас, а не по живому потоку.
  /// Последнее живое число почти совпадает с карточкой истории: живое
  /// посчитано до последнего такта, карточка — до endedAt, разница —
  /// меньше минуты в конце поездки.
  final ValueNotifier<LiveEnergySplit?> live = ValueNotifier(null);
  static const Duration liveInterval = Duration(minutes: 1);
  Timer? _liveTimer;
  bool _liveBusy = false;

  /// v0.2.26+225: точки открытой поездки в памяти. Первый такт по поездке
  /// читает её строки один раз (как расчёт при закрытии в +222), дальше
  /// раз в минуту дочитываются только строки с id в (_liveMaxId, max id] —
  /// диапазон по первичному ключу. Граница — max id на начало такта, и
  /// [_liveMaxId] сдвигается до неё всегда, даже если подходящих строк не
  /// было: иначе поездка без сигналов модели читала бы таблицу с нуля
  /// каждую минуту. Чтение всей таблицы каждую минуту держало бы
  /// единственное соединение Drift, и запись HAL ждала бы. Память живёт
  /// одну поездку: смена поездки или её конец — сброс.
  int? _liveTripId;
  int _liveMaxId = 0;
  final List<({DateTime ts, String name, double v})> _livePts = [];

  void _liveReset([int? tripId]) {
    _liveTripId = tripId;
    _liveMaxId = 0;
    _livePts.clear();
  }

  void start() {
    unawaited(_recomputePartless());
    _sub ??= _db.watchTripsAwaitingSplit().listen((_) => unawaited(_kick()));
    _liveTimer ??=
        Timer.periodic(liveInterval, (_) => unawaited(_liveTick()));
    unawaited(_liveTick());
  }

  void dispose() {
    _flushNoData();
    _sub?.cancel();
    _sub = null;
    _liveTimer?.cancel();
    _liveTimer = null;
    live.dispose();
  }

  Future<void> _liveTick() async {
    if (_liveBusy) return;
    _liveBusy = true;
    try {
      final open = await _db.getOpenTrips();
      // dispose() мог прийти, пока шёл запрос: ValueNotifier после
      // dispose писать нельзя.
      if (_liveTimer == null) return;
      if (open.isEmpty) {
        _liveReset();
        live.value = null;
        return;
      }
      // getOpenTrips упорядочен по началу: последняя — текущая поездка.
      // Экран дополнительно сверяет id с поездкой, которую показывает.
      final t = open.last;
      if (t.id != _liveTripId) _liveReset(t.id);
      final now = DateTime.now();
      final upTo = await _db.maxHalSampleId();
      final rows = await _db.halSignalRowsInIdRange(
          _liveMaxId, upTo, t.startedAt, EnergySplitModel.signals);
      // Такты не пересекаются (_liveBusy), поездка за время запроса не
      // меняется; проверяется только dispose().
      if (_liveTimer == null) return;
      _liveMaxId = upTo;
      if (rows.isNotEmpty) {
        // Строки идут по id; по времени они почти всегда тоже по порядку.
        // Сортировка только если порядок нарушен (фоновый журнал пишет
        // пакетами задним числом). Равные времена — в любом порядке, как
        // у halSignalsBetween при расчёте после закрытия.
        final ordered = (_livePts.isEmpty ||
                !rows.first.ts.isBefore(_livePts.last.ts)) &&
            _sortedByTs(rows);
        _livePts.addAll(rows);
        if (!ordered) _livePts.sort((a, b) => a.ts.compareTo(b.ts));
      }
      if (_livePts.isEmpty) {
        live.value = null;
        return;
      }
      final r = computeEnergySplitAuto(_livePts, t.startedAt, now);
      live.value = LiveEnergySplit(
          t.id, energySplitShares(r.motionKwh, r.climateKwh, r.otherKwh),
          model: r.model);
    } catch (e) {
      debugPrint('EnergySplit: live pass failed: $e');
    } finally {
      _liveBusy = false;
    }
  }

  /// v0.2.30+229 — РАЗОВЫЙ ПЕРЕСЧЁТ ПОД ПОРОГ 3 МИНУТЫ. Поездкам с
  /// моделью без частей разделение снимается, и наблюдение за таблицей
  /// посчитает их заново: от 3 минут они получат части, короче — снова
  /// модель без частей; все уйдут на сервер (правило [onTripsSplit]).
  /// Только поездки не старше первого сэмпла hal_samples: старшие
  /// пересчитать не по чему, а снятие отметки сделало бы их «без данных»
  /// и стёрло бы локально пак, который есть.
  Future<void> _recomputePartless() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(recomputeKey) ?? false) return;
      final since = await _db.earliestHalSampleAt();
      final n = since == null ? 0 : await _db.clearPartlessEnergySplitSince(since);
      await prefs.setBool(recomputeKey, true);
      debugPrint('EnergySplit: $n trip(s) without parts queued for '
          'recompute (threshold ${EnergySplitModel.minTripSeconds} s, +229)');
    } catch (e) {
      debugPrint('EnergySplit: recompute pass failed: $e');
    }
  }

  static bool _sortedByTs(List<({DateTime ts, String name, double v})> xs) {
    for (var i = 1; i < xs.length; i++) {
      if (xs[i].ts.isBefore(xs[i - 1].ts)) return false;
    }
    return true;
  }

  Future<void> _kick() async {
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _runPending();
      } while (_again);
    } catch (e) {
      debugPrint('EnergySplit: pass failed: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _runPending() async {
    final pending = await _db.tripsAwaitingSplit();
    if (pending.isEmpty) return;
    final first = await _db.earliestHalSampleAt();
    final split = <int>[];
    var noData = 0;
    for (final t in pending) {
      final end = t.endedAt;
      if (end == null) continue;
      final pts = (first == null || end.isBefore(first))
          ? const <({DateTime ts, String name, double v})>[]
          : await _db.halSignalsBetween(
              t.startedAt, end, EnergySplitModel.signals);
      if (pts.isEmpty) {
        // Нет данных HAL — поездка с телефона, чужая из облака или старше
        // хранения. Отметка только локальная (покрытие 0, модель пуста):
        // такая поездка НЕ шлёт полей разделения и не может стереть
        // разделение, посчитанное на другом устройстве.
        await _db.writeEnergySplit(t.id, coverage: 0);
        noData++;
        continue;
      }
      final r = computeEnergySplitAuto(pts, t.startedAt, end);
      final used = t.energyUsedKwh;
      // Решение владельца 05.11: части в кВт·ч = доля по батарее ×
      // energy_used_kwh, чтобы их сумма совпадала со строкой «Энергия».
      // v0.2.32+231: только для v1. У v2 масштаба нет: energy_used_kwh
      // считается по SOC, и масштаб перенёс бы погрешность SOC на части
      // (Друг 3); части v2 в сумме дают energy_pack_kwh (Друг 2 принял).
      final k = (r.model == EnergySplitModel.version &&
              r.hasSplit &&
              used != null &&
              r.packKwh > 0)
          ? used / r.packKwh
          : 1.0;
      await _db.writeEnergySplit(
        t.id,
        coverage: r.coverage,
        packKwh: r.packKwh,
        motionKwh: r.motionKwh == null ? null : r.motionKwh! * k,
        climateKwh: r.climateKwh == null ? null : r.climateKwh! * k,
        otherKwh: r.otherKwh == null ? null : r.otherKwh! * k,
        model: r.model,
      );
      debugPrint('EnergySplit: trip ${t.id} '
          '${r.hasSplit ? 'move=${(r.motionKwh! * k).toStringAsFixed(3)} '
              'climate=${(r.climateKwh! * k).toStringAsFixed(3)} '
              'other=${(r.otherKwh! * k).toStringAsFixed(3)}' : 'no split'} '
          'windows=${r.coveredSeconds ~/ 60} '
          'coverage=${r.coverage.toStringAsFixed(2)} '
          'pack=${r.packKwh.toStringAsFixed(3)} used=$used '
          '${r.tractionKwh == null ? '' : 'traction=${r.tractionKwh!.toStringAsFixed(3)} '
              'regen=${r.regenKwh!.toStringAsFixed(3)} '}'
          'model=${r.model}');
      // v0.2.30+229: любая записанная модель — на отправку (см. onTripsSplit).
      split.add(t.id);
    }
    if (noData > 0) _noteNoData(noData);
    if (split.isNotEmpty) onTripsSplit?.call(split);
  }

  /// v0.2.31+230 — ОДНА СТРОКА НА ПРОХОД. Восстановление из облака вносит
  /// поездки пачками, и каждая пачка запускала [_runPending] со своей
  /// строкой «N trip(s) without HAL data — skipped»: в экспорте 09.11 11:20
  /// это около 150 строк из 250 в app_log. Теперь счёт копится и пишется
  /// одной строкой, когда пачки перестали приходить на [noDataQuiet].
  /// Отметки в базе пишутся как прежде, сразу; откладывается только строка.
  static const Duration noDataQuiet = Duration(seconds: 10);
  int _noDataPending = 0;
  Timer? _noDataTimer;

  void _noteNoData(int n) {
    _noDataPending += n;
    _noDataTimer?.cancel();
    _noDataTimer = Timer(noDataQuiet, _flushNoData);
  }

  void _flushNoData() {
    _noDataTimer?.cancel();
    _noDataTimer = null;
    if (_noDataPending == 0) return;
    debugPrint('EnergySplit: $_noDataPending trip(s) without HAL data — '
        'skipped (local mark only)');
    _noDataPending = 0;
  }
}
