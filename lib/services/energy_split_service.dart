// v0.2.23+222 — РАЗДЕЛЕНИЕ ЭНЕРГИИ ПОЕЗДКИ: движение / климат и подогрев /
// прочее. v0.2.26+225: живое накопленное разделение открытой поездки
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

import '../data/database.dart';

/// Константы модели — в одном месте. Меняются патчем по пересчётам
/// Друга 3; при смене коэффициентов меняется и [version], и тогда пересчёт
/// с отправкой заново перезапишет облако (Друг 2, 05.11).
class EnergySplitModel {
  static const String version = 'v1';
  static const double kTraction = 1.030;
  static const double kRegen = 0.835;
  static const double baseKw = 0.65;
  static const int minTripSeconds = 600;
  static const double minCoverage = 0.8;

  /// Сигналы модели. `pack_voltage_fine` предпочтительнее, `pack_voltage`
  /// — запасной. `motor_power` не годится: целые кВт, на стоянке 1–2 кВт.
  static const List<String> signals = [
    'pack_voltage_fine',
    'pack_voltage',
    'pack_current',
    'motor_torque',
    'motor_rpm',
  ];
}

class EnergySplitResult {
  final double packKwh;
  final double coverage;
  final int coveredSeconds;
  final double? motionKwh;
  final double? climateKwh;
  final double? otherKwh;
  const EnergySplitResult(this.packKwh, this.coverage, this.coveredSeconds,
      this.motionKwh, this.climateKwh, this.otherKwh);
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
/// [shares] null — «считается…» (меньше 10 минут или мало покрытия).
class LiveEnergySplit {
  final int tripId;
  final ({double motion, double climate, double other})? shares;
  const LiveEnergySplit(this.tripId, this.shares);
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

class EnergySplitService {
  EnergySplitService(this._db);
  final AppDatabase _db;

  /// Поездки, получившие разделение, — CloudSyncService.requeueTrips
  /// (проводка в main.dart). Уже отправленная без разделения поездка
  /// уйдёт ещё раз; сервер обновит строку по client_uuid (Друг 2, §3).
  void Function(List<int> tripIds)? onTripsSplit;

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
    _sub ??= _db.watchTripsAwaitingSplit().listen((_) => unawaited(_kick()));
    _liveTimer ??=
        Timer.periodic(liveInterval, (_) => unawaited(_liveTick()));
    unawaited(_liveTick());
  }

  void dispose() {
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
      final r = computeEnergySplit(_livePts, t.startedAt, now);
      live.value = LiveEnergySplit(
          t.id, energySplitShares(r.motionKwh, r.climateKwh, r.otherKwh));
    } catch (e) {
      debugPrint('EnergySplit: live pass failed: $e');
    } finally {
      _liveBusy = false;
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
      final r = computeEnergySplit(pts, t.startedAt, end);
      final used = t.energyUsedKwh;
      // Решение владельца 05.11: части в кВт·ч = доля по батарее ×
      // energy_used_kwh, чтобы их сумма совпадала со строкой «Энергия».
      final k = (r.hasSplit && used != null && r.packKwh > 0)
          ? used / r.packKwh
          : 1.0;
      await _db.writeEnergySplit(
        t.id,
        coverage: r.coverage,
        packKwh: r.packKwh,
        motionKwh: r.motionKwh == null ? null : r.motionKwh! * k,
        climateKwh: r.climateKwh == null ? null : r.climateKwh! * k,
        otherKwh: r.otherKwh == null ? null : r.otherKwh! * k,
        model: EnergySplitModel.version,
      );
      debugPrint('EnergySplit: trip ${t.id} '
          '${r.hasSplit ? 'move=${(r.motionKwh! * k).toStringAsFixed(3)} '
              'climate=${(r.climateKwh! * k).toStringAsFixed(3)} '
              'other=${(r.otherKwh! * k).toStringAsFixed(3)}' : 'no split'} '
          'windows=${r.coveredSeconds ~/ 60} '
          'coverage=${r.coverage.toStringAsFixed(2)} '
          'pack=${r.packKwh.toStringAsFixed(3)} used=$used '
          'model=${EnergySplitModel.version}');
      if (r.hasSplit) split.add(t.id);
    }
    if (noData > 0) {
      debugPrint('EnergySplit: $noData trip(s) without HAL data — skipped');
    }
    if (split.isNotEmpty) onTripsSplit?.call(split);
  }
}
