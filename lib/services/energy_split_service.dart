// v0.2.23+222 — РАЗДЕЛЕНИЕ ЭНЕРГИИ ПОЕЗДКИ: движение / климат и подогрев /
// прочее. v0.2.31+230: модель v2 по току инвертора — движение / климат и
// бортовая сеть ([computeEnergySplitV2], [computeEnergySplitAuto]). v0.2.26+225: живое накопленное разделение открытой поездки
// ([EnergySplitService.live]) той же функцией, доли — [energySplitShares].
// v0.2.34+233: событийный счёт ([EventEnergyAccumulator], копит
// HalTelemetryService по каждому событию живого потока, суммы — в
// trips.extra под [EventEnergySums.extraKey]); раскладка v2 по нему —
// [computeEnergySplitEvents], выбор источника — [computeTripEnergySplit].
// Раскладка по hal_samples (3–4 с) — оценка `v2s`.
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
import 'dart:convert';
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

  /// v0.2.34+233 — ОЦЕНКА. Та же раскладка v2, но по hal_samples, где
  /// каждый сигнал записан раз в 3–4 с: по экспорту 10.11 она нефизична
  /// (климат 45 %, рекуперация инвертора больше вала; Друг 3). Метку
  /// получают поездки без событийных сумм — до +233, фоновые без живого
  /// потока, с неполным покрытием сумм. С этого патча `v2` — только по
  /// событиям ([computeEnergySplitEvents]).
  static const String versionV2s = 'v2s';

  /// v0.2.34+233: у v2 и v2s две части («Движение», «Климат и бортовая
  /// сеть»), «прочего» нет. Одно место для карточки и живой строки.
  static bool twoParts(String? model) =>
      model == versionV2 || model == versionV2s;
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

  /// v0.2.34+233: проверки событийной v2 (Друг 3, 10.11).
  static const double regenShaftK = 1.05;
  static const double regenShaftAbsKwh = 0.05;
  static const double boardLowKw = 0.2;
  static const double boardLowShare = 0.10;
  static const double boardNegKw = -0.3;

  /// Сигналы модели. `pack_voltage_fine` предпочтительнее, `pack_voltage`
  /// — запасной. `motor_power` не годится: целые кВт, на стоянке 1–2 кВт;
  /// v0.2.34+233: и это мощность батареи, а не вала.
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
  /// v0.2.34+233: у событийной v2 — какая проверка Друга 3 не прошла
  /// (`regen_above_shaft`, `board_minutes`); части тогда пусты. Только
  /// для строки в app_log.
  final String? rejected;
  /// v0.2.34+233: суммы, по которым посчитано (событийная v2), — для
  /// строки в app_log. null у v1 и v2s.
  final EventEnergySums? events;
  const EnergySplitResult(this.packKwh, this.coverage, this.coveredSeconds,
      this.motionKwh, this.climateKwh, this.otherKwh,
      {this.model = EnergySplitModel.version,
      this.tractionKwh,
      this.regenKwh,
      this.rejected,
      this.events});
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
/// tools/mirror_plus222_split.py. v0.2.34+233: по hal_samples это оценка —
/// метка [EnergySplitModel.versionV2s]; правило раскладки то же, что у
/// событийной v2.
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
        model: EnergySplitModel.versionV2s,
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
      model: EnergySplitModel.versionV2s,
      tractionKwh: eTraction,
      regenKwh: eRegen);
}

/// v0.2.31+230: выбор модели по hal_samples. Есть в поездке хоть один
/// отсчёт тока инвертора — v2 (с +233 — оценка v2s), иначе v1 (поездки
/// до +230 и поездки, где поток Engine не пришёл). Над ним —
/// [computeTripEnergySplit].
EnergySplitResult computeEnergySplitAuto(
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
  DateTime end,
) =>
    points.any((p) => p.name == 'inverter_current')
        ? checkSampleSplit(computeEnergySplitV2(points, start, end), points,
            start)
        : computeEnergySplit(points, start, end);

/// v0.2.35+234 — ПРОВЕРКА ОЦЕНКИ v2s. Те же проверки, что у событийной v2
/// ([energySplitCheck]), по суммам тех же отсчётов hal_samples через
/// [EventEnergyAccumulator] с пределом [EventEnergyAccumulator.sampleGapMs].
/// Не прошла — частей нет, пак, тяга и рекуперация остаются, причина — в
/// [EnergySplitResult.rejected] (строка EnergySplit в app_log).
EnergySplitResult checkSampleSplit(
  EnergySplitResult r,
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
) {
  if (!r.hasSplit) return r;
  final acc = EventEnergyAccumulator(start.millisecondsSinceEpoch,
      maxGapMs: EventEnergyAccumulator.sampleGapMs);
  for (final p in points) {
    acc.add(p.name, p.v, p.ts.millisecondsSinceEpoch);
  }
  final why = energySplitCheck(acc.snapshot());
  if (why == null) return r;
  return EnergySplitResult(
      r.packKwh, r.coverage, r.coveredSeconds, null, null, null,
      model: r.model,
      tractionKwh: r.tractionKwh,
      regenKwh: r.regenKwh,
      rejected: why);
}

/// v0.2.34+233 — СОБЫТИЙНЫЕ СУММЫ ПОЕЗДКИ. Снимок [EventEnergyAccumulator],
/// неизменяемый: его кладёт HalTelemetryService в trips.extra (раз в минуту
/// и при закрытии) и в снимок последнего движения (закрытие по началу
/// зарядки). Ключ в extra — [extraKey]; остальные ключи extra не трогаются
/// (запись слиянием, AppDatabase.mergeTripExtra), сервер хранит extra
/// целиком (Друг 2).
class EventEnergySums {
  static const String extraKey = 'evE';
  static const int format = 1;

  /// Сигналы счёта; порядок задаёт индексы [counts].
  static const List<String> signals = [
    'pack_voltage_fine',
    'pack_voltage',
    'pack_current',
    'inverter_current',
    'motor_torque',
    'motor_rpm',
  ];

  final double packKwh;
  final double tractionKwh;
  final double regenKwh;
  final double shaftTractionKwh;
  final double shaftRegenKwh;
  final double coveredSeconds;
  final int negativeIntervals;
  final int gaps;
  final List<int> counts;
  final int minutes;
  final int minutesLow;
  final int minutesNegative;
  final double? minuteMinKw;

  const EventEnergySums({
    required this.packKwh,
    required this.tractionKwh,
    required this.regenKwh,
    required this.shaftTractionKwh,
    required this.shaftRegenKwh,
    required this.coveredSeconds,
    required this.negativeIntervals,
    required this.gaps,
    required this.counts,
    required this.minutes,
    required this.minutesLow,
    required this.minutesNegative,
    required this.minuteMinKw,
    this.batteryRegenKwh,
    this.firehose = const {},
    this.firehoseStatus,
  });

  /// v0.2.35+234: рекуперация В БАТАРЕЮ — ∫V·I_бат при токе батареи < 0
  /// по тем же интервалам. Меньше рекуперации инвертора на бортовую сеть
  /// в эти секунды (Друг 3). null в суммах до +234.
  final double? batteryRegenKwh;

  /// v0.2.35+234: поля firehose за поездку — первое и последнее значение
  /// подтверждённых счётчиков ([firehoseTripFields]), только для сверки
  /// итога в app_log. Состояние сверки контрольных полей с HAL на момент
  /// снимка — [firehoseStatus] (`ok`, `unchecked`, `mismatch`).
  final Map<String, (double, double)> firehose;
  final String? firehoseStatus;

  /// Подтверждённые поля firehose, первое и последнее значение которых
  /// копится за поездку (recon FirehoseFieldTable, p158).
  static const List<String> firehoseTripFields = [
    'gb_cycle_discharge_kwh',
    'gb_cycle_regen_kwh',
    'gb_remaining_energy_kwh',
  ];

  /// Отношение рекуперации инвертора к рекуперации вала; null без вала.
  double? get regenRatio =>
      shaftRegenKwh > 0 ? regenKwh / shaftRegenKwh : null;

  static double _r(double v) => (v * 100000).roundToDouble() / 100000;

  Map<String, dynamic> toJson() => {
        'f': format,
        'pack': _r(packKwh),
        'trac': _r(tractionKwh),
        'regen': _r(regenKwh),
        'shTrac': _r(shaftTractionKwh),
        'shRegen': _r(shaftRegenKwh),
        'covS': _r(coveredSeconds),
        'neg': negativeIntervals,
        'gaps': gaps,
        'n': {
          for (var i = 0; i < signals.length; i++) signals[i]: counts[i],
        },
        'min': {
          'n': minutes,
          'low': minutesLow,
          'neg': minutesNegative,
          if (minuteMinKw != null) 'minKw': _r(minuteMinKw!),
        },
        if (batteryRegenKwh != null) 'regenBat': _r(batteryRegenKwh!),
        if (firehoseStatus != null || firehose.isNotEmpty)
          'fh': {
            if (firehoseStatus != null) 'st': firehoseStatus,
            for (final e in firehose.entries)
              e.key: [_r(e.value.$1), _r(e.value.$2)],
          },
      };

  /// Патч для AppDatabase.mergeTripExtra: версия блоба общая для всех
  /// писателей extra (`v: 1`), суммы — своим ключом.
  String toExtraPatch() =>
      jsonEncode({'v': 1, extraKey: toJson()});

  /// Суммы из extra поездки; null — ключа нет или он не читается.
  static EventEnergySums? fromExtra(String? extra) {
    if (extra == null || extra.isEmpty) return null;
    try {
      final obj = jsonDecode(extra);
      if (obj is! Map) return null;
      final m = obj[extraKey];
      if (m is! Map || m['f'] != format) return null;
      double d(Object? v) => v is num ? v.toDouble() : double.nan;
      int i(Object? v) => v is num ? v.toInt() : 0;
      final n = m['n'];
      final mn = m['min'];
      final r = EventEnergySums(
        packKwh: d(m['pack']),
        tractionKwh: d(m['trac']),
        regenKwh: d(m['regen']),
        shaftTractionKwh: d(m['shTrac']),
        shaftRegenKwh: d(m['shRegen']),
        coveredSeconds: d(m['covS']),
        negativeIntervals: i(m['neg']),
        gaps: i(m['gaps']),
        counts: [for (final s in signals) n is Map ? i(n[s]) : 0],
        minutes: mn is Map ? i(mn['n']) : 0,
        minutesLow: mn is Map ? i(mn['low']) : 0,
        minutesNegative: mn is Map ? i(mn['neg']) : 0,
        minuteMinKw: mn is Map && mn['minKw'] is num
            ? (mn['minKw'] as num).toDouble()
            : null,
        batteryRegenKwh:
            m['regenBat'] is num ? (m['regenBat'] as num).toDouble() : null,
        firehose: {
          if (m['fh'] is Map)
            for (final e in (m['fh'] as Map).entries)
              if (e.value is List &&
                  (e.value as List).length == 2 &&
                  (e.value as List)[0] is num &&
                  (e.value as List)[1] is num)
                e.key as String: (
                  ((e.value as List)[0] as num).toDouble(),
                  ((e.value as List)[1] as num).toDouble()
                ),
        },
        firehoseStatus: m['fh'] is Map && (m['fh'] as Map)['st'] is String
            ? (m['fh'] as Map)['st'] as String
            : null,
      );
      final core = [
        r.packKwh,
        r.tractionKwh,
        r.regenKwh,
        r.shaftTractionKwh,
        r.shaftRegenKwh,
        r.coveredSeconds,
      ];
      return core.any((x) => x.isNaN) ? null : r;
    } catch (_) {
      return null;
    }
  }
}

/// v0.2.34+233 — СОБЫТИЙНЫЙ СЧЁТ ЭНЕРГИИ, зеркало `Acc` в
/// tools/mirror_plus233_events.py (там же правило и эталон корпуса).
///
/// Время события — метка HAL (мс), а не приход пачки. Интервал — между
/// соседними событиями ЛЮБОГО сигнала счёта; по нему интегрируются
/// значения, которые держались ДО нового события. Значение не протухает
/// (поток шлёт по изменению). Интервал больше [gapMs] не считается и
/// считается разрывом; отрицательный не считается и считается отдельно;
/// часы при этом назад не идут. Покрытие — время, где известны V и оба
/// тока. Бортовая сеть по минутам поездки = (E_пак − E_инв) / покрытое
/// время минуты; минута учитывается от [minuteMinMs] покрытия.
class EventEnergyAccumulator {
  EventEnergyAccumulator(this.startMs, {this.maxGapMs = gapMs});

  /// v0.2.35+234: предел интервала. Для живого потока — [gapMs]; для
  /// проверки оценки по hal_samples (каждый сигнал раз в 3–4 с, интервалы
  /// между соседними строками до ~6 с) — [sampleGapMs].
  final int maxGapMs;

  /// Начало поездки (мс) — отсчёт минут.
  final int startMs;
  static const int gapMs = 5000;
  static const int sampleGapMs = 10000;
  static const int minuteMinMs = 30000;

  final Map<String, double> _last = {};
  int? _tPrev;
  double _pack = 0;
  double _trac = 0;
  double _regen = 0;
  double _regenBat = 0;
  final Map<String, double> _fhFirst = {};
  final Map<String, double> _fhLast = {};

  /// v0.2.35+234: состояние сверки firehose с HAL; ставит
  /// HalTelemetryService при каждой смене и в начале поездки.
  String? firehoseStatus;

  /// v0.2.35+234: значение подтверждённого поля firehose — первое и
  /// последнее за поездку. Другие имена не копятся.
  void addFirehose(String name, double value) {
    if (!EventEnergySums.firehoseTripFields.contains(name)) return;
    _fhFirst.putIfAbsent(name, () => value);
    _fhLast[name] = value;
  }
  double _shTrac = 0;
  double _shRegen = 0;
  int _covMs = 0;
  int _neg = 0;
  int _gaps = 0;
  final List<int> _counts = List<int>.filled(EventEnergySums.signals.length, 0);
  int _mIdx = -1;
  double _mE = 0;
  int _mCov = 0;
  int _minutes = 0;
  int _mLow = 0;
  int _mNeg = 0;
  double? _mMin;

  void add(String name, double value, int tsMs) {
    final ci = EventEnergySums.signals.indexOf(name);
    if (ci < 0) return;
    _counts[ci]++;
    final tp = _tPrev;
    if (tp != null) {
      final dt = tsMs - tp;
      if (dt < 0) {
        _neg++;
      } else if (dt > maxGapMs) {
        _gaps++;
      } else if (dt > 0) {
        _integrate(tp, dt);
      }
    }
    if (tp == null || tsMs >= tp) _tPrev = tsMs;
    _last[name] = value;
  }

  void _integrate(int tp, int dt) {
    final h = dt / 3600000.0;
    final v = _last['pack_voltage_fine'] ?? _last['pack_voltage'];
    final ib = _last['pack_current'];
    final ii = _last['inverter_current'];
    if (v != null && ib != null && ii != null) {
      _covMs += dt;
      final pb = v * ib / 1000.0;
      final pi = v * ii / 1000.0;
      _pack += pb * h;
      if (pb < 0) _regenBat -= pb * h;
      if (pi > 0) {
        _trac += pi * h;
      } else {
        _regen -= pi * h;
      }
      final idx = math.max(0, tp - startMs) ~/ 60000;
      if (idx != _mIdx) {
        if (_mIdx >= 0) {
          final kw = _minuteKw(_mE, _mCov);
          if (kw != null) {
            _minutes++;
            if (kw < EnergySplitModel.boardLowKw) _mLow++;
            if (kw < EnergySplitModel.boardNegKw) _mNeg++;
            _mMin = _mMin == null ? kw : math.min(_mMin!, kw);
          }
        }
        _mIdx = idx;
        _mE = 0;
        _mCov = 0;
      }
      _mE += (pb - pi) * h;
      _mCov += dt;
    }
    final tq = _last['motor_torque'];
    final n = _last['motor_rpm'];
    if (tq != null && n != null) {
      final ps = tq * n * 2 * math.pi / 60 / 1000.0;
      if (ps > 0) {
        _shTrac += ps * h;
      } else {
        _shRegen -= ps * h;
      }
    }
  }

  static double? _minuteKw(double e, int covMs) =>
      covMs < minuteMinMs ? null : e / (covMs / 3600000.0);

  /// Снимок. Открытая минута учитывается так же, как закрытая, если
  /// покрыта от [minuteMinMs]; само накопление не меняется.
  EventEnergySums snapshot() {
    var minutes = _minutes;
    var low = _mLow;
    var neg = _mNeg;
    var mn = _mMin;
    if (_mIdx >= 0) {
      final kw = _minuteKw(_mE, _mCov);
      if (kw != null) {
        minutes++;
        if (kw < EnergySplitModel.boardLowKw) low++;
        if (kw < EnergySplitModel.boardNegKw) neg++;
        mn = mn == null ? kw : math.min(mn, kw);
      }
    }
    return EventEnergySums(
      packKwh: _pack,
      tractionKwh: _trac,
      regenKwh: _regen,
      batteryRegenKwh: _regenBat,
      firehose: {
        for (final k in _fhFirst.keys) k: (_fhFirst[k]!, _fhLast[k]!),
      },
      firehoseStatus: firehoseStatus,
      shaftTractionKwh: _shTrac,
      shaftRegenKwh: _shRegen,
      coveredSeconds: _covMs / 1000.0,
      negativeIntervals: _neg,
      gaps: _gaps,
      counts: List<int>.unmodifiable(_counts),
      minutes: minutes,
      minutesLow: low,
      minutesNegative: neg,
      minuteMinKw: mn,
    );
  }
}

/// v0.2.35+234 — ПРОВЕРКИ ДРУГА 3, ОДНО МЕСТО для событийной v2 и для
/// оценки v2s по hal_samples: рекуперация инвертора не больше вала ×
/// [EnergySplitModel.regenShaftK] + [EnergySplitModel.regenShaftAbsKwh];
/// минут бортовой сети ниже [EnergySplitModel.boardLowKw] не больше
/// [EnergySplitModel.boardLowShare], ни одной ниже
/// [EnergySplitModel.boardNegKw]. null — проверки пройдены, иначе причина.
/// До +234 оценка v2s шла без проверок; по экспорту 12.11 ни одна из шести
/// поездок v2s их не прошла (1223: климат 48 %, Друг 2).
String? energySplitCheck(EventEnergySums s) {
  if (s.regenKwh >
      s.shaftRegenKwh * EnergySplitModel.regenShaftK +
          EnergySplitModel.regenShaftAbsKwh) {
    return 'regen_above_shaft';
  }
  if (s.minutes > 0 &&
      (s.minutesLow > EnergySplitModel.boardLowShare * s.minutes ||
          s.minutesNegative > 0)) {
    return 'board_minutes';
  }
  return null;
}

/// v0.2.35+234 — ПОКРЫВАЮТ ЛИ СУММЫ ПОЕЗДКУ. Одно правило для раскладки
/// ([computeEnergySplitEvents]) и для рекуперации поездки
/// (HalTelemetryService): суммы берутся, только если покрыто не меньше
/// [EnergySplitModel.minCoverage] времени поездки.
bool eventSumsCoverTrip(EventEnergySums s, DateTime start, DateTime end) {
  final dur = end.difference(start).inMilliseconds / 1000.0;
  if (dur <= 0) return false;
  return math.min(1.0, s.coveredSeconds / dur) >= EnergySplitModel.minCoverage;
}

/// v0.2.34+233 — РАСКЛАДКА v2 ПО СОБЫТИЙНЫМ СУММАМ, зеркало
/// `split_events()` в tools/mirror_plus233_events.py.
///
/// null — суммы покрывают меньше [EnergySplitModel.minCoverage] поездки
/// (живой поток подхватил поездку на ходу, поток прерывался): тогда берётся
/// оценка по hal_samples ([computeTripEnergySplit]). Движение = тяга −
/// рекуперация инвертора, климат = пак − движение (< 0 → 0, движение =
/// пак), прочее 0, без масштаба. Проверки Друга 3: рекуперация инвертора
/// не больше вала × [EnergySplitModel.regenShaftK] +
/// [EnergySplitModel.regenShaftAbsKwh]; минут бортовой сети ниже
/// [EnergySplitModel.boardLowKw] не больше [EnergySplitModel.boardLowShare],
/// ни одной ниже [EnergySplitModel.boardNegKw]. Не прошла — частей нет,
/// пак остаётся.
EnergySplitResult? computeEnergySplitEvents(
    EventEnergySums s, DateTime start, DateTime end) {
  if (!eventSumsCoverTrip(s, start, end)) return null;
  final dur = end.difference(start).inMilliseconds / 1000.0;
  final cov = math.min(1.0, s.coveredSeconds / dur);
  final covered = s.coveredSeconds.round();
  EnergySplitResult partless([String? why]) => EnergySplitResult(
      s.packKwh, cov, covered, null, null, null,
      model: EnergySplitModel.versionV2,
      tractionKwh: s.tractionKwh,
      regenKwh: s.regenKwh,
      rejected: why,
      events: s);
  if (dur < EnergySplitModel.minTripSeconds || s.packKwh <= 0) {
    return partless();
  }
  final why = energySplitCheck(s);
  if (why != null) return partless(why);
  var motion = s.tractionKwh - s.regenKwh;
  var climate = s.packKwh - motion;
  if (climate < 0) {
    climate = 0;
    motion = s.packKwh;
  }
  return EnergySplitResult(s.packKwh, cov, covered, motion, climate, 0.0,
      model: EnergySplitModel.versionV2,
      tractionKwh: s.tractionKwh,
      regenKwh: s.regenKwh,
      events: s);
}

/// v0.2.34+233 — ВЫБОР ИСТОЧНИКА, ОДНО место для расчёта после закрытия и
/// живой строки: есть событийные суммы с достаточным покрытием — v2 по
/// ним; иначе — по hal_samples ([computeEnergySplitAuto]: v2s или v1).
EnergySplitResult computeTripEnergySplit(
  EventEnergySums? events,
  List<({DateTime ts, String name, double v})> points,
  DateTime start,
  DateTime end,
) =>
    (events == null ? null : computeEnergySplitEvents(events, start, end)) ??
    computeEnergySplitAuto(points, start, end);

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

  /// v0.2.34+233: разовая перемаркировка `v2` без событийных сумм в `v2s`
  /// (см. [_relabelSampleV2]). Привязан к базе, как [recomputeKey].
  static const String relabelKey = 'energy_split_v2s_233';

  /// v0.2.35+234: разовая перепроверка v2s с частями (см.
  /// [_recheckSampleSplits]). Привязан к базе.
  static const String recheckKey = 'energy_split_v2s_checks_234';

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
    unawaited(_relabelSampleV2());
    unawaited(_recheckSampleSplits());
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
      if (_livePts.isEmpty && EventEnergySums.fromExtra(t.extra) == null) {
        live.value = null;
        return;
      }
      // v0.2.34+233: тот же выбор источника, что после закрытия. Суммы
      // HalTelemetryService кладёт в extra раз в минуту — живая строка
      // отстаёт от них не больше чем на такт.
      final r = computeTripEnergySplit(EventEnergySums.fromExtra(t.extra),
          _livePts, t.startedAt, now);
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

  /// v0.2.34+233 — ПЕРЕСЧЁТ ПО ПРАВИЛУ, А НЕ ПО СПИСКУ. Каждая закрытая
  /// поездка с моделью `v2` без событийных сумм посчитана по hal_samples —
  /// это оценка. Если её hal_samples ещё здесь (начало не раньше первого
  /// сэмпла), разделение снимается, наблюдение посчитает её заново (`v2s`
  /// по нынешнему правилу, части в сумме = пак) и отправит: повтор с
  /// моделью заменяет на сервере все шесть полей (Друг 2). Если данных
  /// нет — меняется только локальная метка, без отправки: на сервере
  /// поездку поправит устройство, у которого данные есть, а телефон не
  /// шлёт чужие поездки.
  Future<void> _relabelSampleV2() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(relabelKey) ?? false) return;
      final since = await _db.earliestHalSampleAt();
      var recompute = 0;
      var relabel = 0;
      for (final t in await _db.closedTripsWithSplitModel(
          EnergySplitModel.versionV2)) {
        if (EventEnergySums.fromExtra(t.extra) != null) continue;
        if (since != null && !t.startedAt.isBefore(since)) {
          await _db.clearEnergySplit(t.id);
          recompute++;
        } else {
          await _db.setEnergySplitModel(t.id, EnergySplitModel.versionV2s);
          relabel++;
        }
      }
      await prefs.setBool(relabelKey, true);
      debugPrint('EnergySplit: v2 without event sums -> v2s: '
          '$recompute recomputed from hal_samples, $relabel relabelled '
          'locally (+233)');
    } catch (e) {
      debugPrint('EnergySplit: v2s relabel pass failed: $e');
    }
  }

  /// v0.2.35+234 — ПЕРЕПРОВЕРКА ОЦЕНОК ПО ПРАВИЛУ. Каждая закрытая поездка
  /// v2s с частями посчитана без проверок Друга 3. Если её hal_samples
  /// ещё здесь, разделение снимается; наблюдение посчитает её заново, уже
  /// с проверками ([checkSampleSplit]), и отправит — пустые части на
  /// сервере стирают старые (правило Друга 2). Без данных поездку проверить
  /// нечем, и она не трогается.
  Future<void> _recheckSampleSplits() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(recheckKey) ?? false) return;
      final since = await _db.earliestHalSampleAt();
      var n = 0;
      if (since != null) {
        for (final t in await _db.closedTripsWithSplitModel(
            EnergySplitModel.versionV2s)) {
          if (t.energyMotionKwh == null) continue;
          if (t.startedAt.isBefore(since)) continue;
          await _db.clearEnergySplit(t.id);
          n++;
        }
      }
      await prefs.setBool(recheckKey, true);
      debugPrint('EnergySplit: v2s with parts re-checked: $n cleared for '
          'recompute with the Friend 3 checks (+234)');
    } catch (e) {
      debugPrint('EnergySplit: v2s re-check pass failed: $e');
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
      // v0.2.34+233: событийные суммы поездки. Если по ним считается
      // (computeTripEnergySplit возьмёт их), hal_samples не читаются.
      final ev = EventEnergySums.fromExtra(t.extra);
      final byEvents = ev != null &&
          computeEnergySplitEvents(ev, t.startedAt, end) != null;
      final pts = (byEvents || first == null || end.isBefore(first))
          ? const <({DateTime ts, String name, double v})>[]
          : await _db.halSignalsBetween(
              t.startedAt, end, EnergySplitModel.signals);
      if (!byEvents && pts.isEmpty) {
        // Нет данных HAL — поездка с телефона, чужая из облака или старше
        // хранения. Отметка только локальная (покрытие 0, модель пуста):
        // такая поездка НЕ шлёт полей разделения и не может стереть
        // разделение, посчитанное на другом устройстве.
        await _db.writeEnergySplit(t.id, coverage: 0);
        noData++;
        continue;
      }
      final r = computeTripEnergySplit(ev, pts, t.startedAt, end);
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
          '${_eventsLog(r)}'
          '${r.rejected == null ? '' : 'rejected=${r.rejected} '}'
          'model=${r.model}');
      // v0.2.30+229: любая записанная модель — на отправку (см. onTripsSplit).
      split.add(t.id);
    }
    if (noData > 0) _noteNoData(noData);
    if (split.isNotEmpty) onTripsSplit?.call(split);
  }

  /// v0.2.34+233: подробности событийной v2 для строки EnergySplit —
  /// маркер для проверки по экспорту (покрытие, разрывы, отрицательные
  /// интервалы, рекуперация инвертор/вал, минуты бортовой сети, число
  /// событий по сигналам и причина отказа, если проверка не прошла).
  static String _eventsLog(EnergySplitResult r) {
    final e = r.events;
    if (e == null) return '';
    final ratio = e.regenRatio;
    final counts = [
      for (var i = 0; i < EventEnergySums.signals.length; i++)
        '${EventEnergySums.signals[i]}:${e.counts[i]}'
    ].join(',');
    return 'events cov=${e.coveredSeconds.toStringAsFixed(0)}s '
        'gaps=${e.gaps} neg=${e.negativeIntervals} '
        'shaft=${e.shaftTractionKwh.toStringAsFixed(3)}/'
        '${e.shaftRegenKwh.toStringAsFixed(3)} '
        'regen_ratio=${ratio == null ? '-' : ratio.toStringAsFixed(3)} '
        'minutes=${e.minutes} low=${e.minutesLow} below_neg=${e.minutesNegative} '
        'min_kw=${e.minuteMinKw == null ? '-' : e.minuteMinKw!.toStringAsFixed(2)} '
        'n=$counts '
        '${e.batteryRegenKwh == null ? '' : 'regen_bat=${e.batteryRegenKwh!.toStringAsFixed(3)} '}'
        '${_firehoseLog(e)}';
  }

  /// v0.2.35+234: сверка итога со счётчиками firehose (Друг 3): разряд и
  /// заряд за цикл включения (0x2D0, шаг 0.1 кВт·ч, сброс при выключении —
  /// сравнивать только по концу поездки) и остаток пака (0x2EE). Значение
  /// меньше начального у счётчика — сброс внутри поездки, разность не
  /// пишется. `fh_st` — сверка контрольных полей с HAL; при `mismatch`
  /// числа firehose недостоверны.
  static String _firehoseLog(EventEnergySums e) {
    if (e.firehose.isEmpty && e.firehoseStatus == null) return '';
    String delta(String k, {bool down = false}) {
      final v = e.firehose[k];
      if (v == null) return '-';
      final d = down ? v.$1 - v.$2 : v.$2 - v.$1;
      if (!down && d < 0) return 'reset';
      return d.toStringAsFixed(1);
    }
    return 'fh_st=${e.firehoseStatus ?? '-'} '
        'fh_dis=${delta('gb_cycle_discharge_kwh')} '
        'fh_reg=${delta('gb_cycle_regen_kwh')} '
        'fh_rem_drop=${delta('gb_remaining_energy_kwh', down: true)} ';
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
