import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';
import 'trip_aggregates.dart';

/// v0.1.86+185 — ПОЕЗДКА ИЗ ФОНОВЫХ СТРОК.
///
/// ЗАЧЕМ. До этого патча поездка с закрытым приложением не появлялась
/// вовсе: сбор в автостарте (+182) писал журнал, разбор (+183) втягивал
/// его в `hal_samples`, и там строки и оставались. Поле 01.08 показало
/// цену: 25 км с закрытым приложением дали 9639 строк и НОЛЬ поездок. А
/// сырые `hal_samples` в облако не уходят и умирают при вайпе — значит
/// без этого файла фоновый сбор не приносил владельцу ничего долговечного.
///
/// ГРАНИЦЫ. Строитель зависит ТОЛЬКО от базы. Он не видит ни
/// `HalTelemetryService`, ни `connection.dart` — поэтому инвариант AA2
/// цел, и поэтому же он лежит отдельным файлом, а не внутри одного из
/// них. Гейт BS4 стережёт это грепом.
///
/// СЕТИ ЗДЕСЬ НЕТ НИ В ОДНОЙ СТРОКЕ. Поездка пишется в локальную базу и
/// получает `client_uuid` как любая другая; синхронизация подберёт её,
/// когда сеть появится, и не подберёт — поездка всё равно есть. Работа
/// без интернета не режим, а основной случай.
class BgTripBuilder {
  BgTripBuilder._();

  /// Разрыв в движении, разрезающий поездки. Пять минут выбраны по полю
  /// 01.08: между пробуждением ГУ в 10:50 и настоящим выездом в 11:01
  /// лежала пауза в 639 секунд, и склеивать их в одну поездку нельзя.
  static const Duration kMotionGap = Duration(minutes: 5);

  /// Короче этого поездки не бывает. Тем же полем: в 10:50:57 машина
  /// шевельнулась на 4 км/ч девять секунд и проехала 0.0 км — это не
  /// поездка, а перекат.
  static const double kMinDistanceKm = 0.3;

  /// Свежий хвост НЕ ТРОГАЕМ. Если последнее движение было только что,
  /// поездка, возможно, ещё идёт, и живой путь вот-вот создаст её сам —
  /// две поездки на один отрезок хуже, чем одна с опозданием до
  /// следующего запуска.
  static const Duration kFreshTail = Duration(minutes: 5);

  static const String _kWatermarkKey = 'bg_trip_watermark_ms';

  /// Сколько строк за один проход. Потолок, а не порция: остаток
  /// разбирается следующим открытием приложения, и водяной знак делает
  /// продолжение бесплатным.
  static const int kScanLimit = 50000;

  /// Разобрать всё, что накопилось. Идемпотентно: приписанные строки
  /// второй раз не читаются (штамп `trip_id`), а участки без движения
  /// отсекаются водяным знаком — иначе стоянка на зарядке перечитывалась
  /// бы при каждом запуске и росла бы без конца.
  static Future<BgTripBuildResult> run(
    AppDatabase db, {
    DateTime? now,
    double batteryCapacityKwh = 65.28,
  }) async {
    final at = now ?? DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final wmMs = prefs.getInt(_kWatermarkKey);
      final after =
          wmMs == null ? null : DateTime.fromMillisecondsSinceEpoch(wmMs);
      final rows = List<HalSample>.of(
          await db.getUnassignedHalSamples(after: after, limit: kScanLimit));
      // Выборка упёрлась в потолок — значит хвост обрезан произвольно, и
      // последний кластер может быть половиной поездки. Такой кластер
      // откладываем: следующий проход увидит его целиком.
      final truncated = rows.length >= kScanLimit;
      if (rows.length < 2) {
        return const BgTripBuildResult(scanned: 0, built: 0, discarded: 0);
      }

      // v0.1.86+185 — ЧАСЫ ГУ. RTC головного устройства до синхронизации
      // может отставать, и тогда `at` оказывается РАНЬШЕ строк, которые
      // мы же и записали. Условие свежего хвоста ниже сработало бы на
      // всех кластерах сразу, не построилось бы ничего, и снаружи это
      // выглядело бы как «фоновые поездки не работают» — без единой
      // строки, объясняющей почему.
      //
      // Отказ здесь правильный (данные целы, знак не двинулся, следующий
      // проход при верных часах разберёт всё), но он ОБЯЗАН БЫТЬ СЛЫШЕН.
      // Молчаливая деградация в поле неотличима от поломки.
      final future = rows.where((r) => r.timestamp.isAfter(at)).length;
      if (future > 0) {
        final skewSec = rows.last.timestamp.difference(at).inSeconds;
        // ОТСЕКАЕМ БУДУЩЕЕ, А НЕ ОСТАНАВЛИВАЕМСЯ ИЗ-ЗА НЕГО. Первая
        // редакция этой охраны выходила из сборки целиком, стоило хоть
        // одной строке оказаться впереди часов, — и одного кадра с битой
        // меткой хватило бы, чтобы фоновые поездки не строились уже
        // никогда. Отставший RTC и битая строка различаются не видом, а
        // долей: когда впереди часов вся выборка, строить действительно
        // нечего.
        rows.removeWhere((r) => r.timestamp.isAfter(at));
        debugPrint('BgTrip: $future строк впереди часов ГУ на $skewSec с '
            '— отброшены');
        if (rows.length < 2) {
          return BgTripBuildResult(
              scanned: future,
              built: 0,
              discarded: 0,
              error: 'clock behind data by ${skewSec}s');
        }
      }

      final clusters = _motionClusters(rows);
      var built = 0;
      var discarded = 0;
      DateTime? watermark;
      DateTime? deferredFrom;

      for (var i = 0; i < clusters.length; i++) {
        final c = clusters[i];
        // Хвост моложе kFreshTail оставляем следующему запуску И НЕ
        // ДВИГАЕМ ПО НЕМУ ВОДЯНОЙ ЗНАК — иначе он пропал бы навсегда.
        // Обрезанная потолком выборка отдаёт последний кластер туда же.
        // Обрезанный последний кластер откладываем — но ТОЛЬКО ЕСЛИ ОН
        // НЕ ПЕРВЫЙ. Иначе водяной знак не сдвинется вовсе, и одна
        // длинная поездка (потолок в 50 000 строк это примерно три с
        // половиной часа за рулём) перечитывалась бы при каждом открытии
        // и не строилась бы никогда. Первый и обрезанный собираем как
        // есть: он закончится на последней загруженной строке, остаток
        // станет отдельной поездкой следующим проходом. Длинная поездка,
        // разрезанная надвое, — плата понятная; вечная тишина — нет.
        final deferTruncated =
            truncated && i == clusters.length - 1 && i > 0;
        if (deferTruncated || at.difference(c.$2) < kFreshTail) {
          deferredFrom = c.$1;
          break;
        }
        final window = [
          for (final r in rows)
            if (!r.timestamp.isBefore(c.$1) && !r.timestamp.isAfter(c.$2)) r
        ];
        final ok = await _buildOne(db, window, c.$1, c.$2, batteryCapacityKwh);
        if (ok) {
          built++;
        } else {
          discarded++;
        }
        watermark = c.$2;
      }
      // ЗНАК ДВИГАЕТСЯ И ТОГДА, КОГДА ДВИЖЕНИЯ НЕ БЫЛО ВОВСЕ. Без этого
      // сутки на зарядке — а это тысячи строк без единого метра — читались
      // бы заново при каждом открытии приложения и росли бы без предела:
      // штампа у них нет и не будет, потому что поездки нет.
      //
      // Верхняя граница — либо начало отложенного кластера (его строки
      // нужны следующему проходу целиком), либо последняя строка старше
      // свежего хвоста.
      final limit = deferredFrom ?? at.subtract(kFreshTail);
      for (final r in rows) {
        if (r.timestamp.isBefore(limit) &&
            (watermark == null || r.timestamp.isAfter(watermark))) {
          watermark = r.timestamp;
        }
      }
      if (watermark != null) {
        await prefs.setInt(_kWatermarkKey, watermark.millisecondsSinceEpoch);
      }
      debugPrint('BgTrip: scanned=${rows.length} built=$built '
          'discarded=$discarded');
      return BgTripBuildResult(
          scanned: rows.length, built: built, discarded: discarded);
    } catch (e) {
      debugPrint('BgTrip: build failed — $e');
      return BgTripBuildResult(
          scanned: 0, built: 0, discarded: 0, error: e.toString());
    }
  }

  /// Кластеры движения: пары (начало, конец).
  ///
  /// Движением считается либо ненулевая скорость, либо РОСТ одометра.
  /// Одного признака мало: `speed` приходит ON-CHANGE и на ровном ходу
  /// молчит, а `odometer` пришёл в поле только с 11:01:57, хотя машина
  /// шевелилась и раньше. Вместе они закрывают дыры друг друга.
  static List<(DateTime, DateTime)> _motionClusters(List<HalSample> rows) {
    final motion = <DateTime>[];
    double? lastOdo;
    for (final r in rows) {
      final v = r.numericValue;
      if (v == null) continue;
      if (r.name == 'speed') {
        if (v > 0) motion.add(r.timestamp);
      } else if (r.name == 'odometer') {
        if (lastOdo != null && v > lastOdo) motion.add(r.timestamp);
        lastOdo = v;
      }
    }
    if (motion.isEmpty) return const [];
    motion.sort();
    final out = <(DateTime, DateTime)>[];
    var start = motion.first;
    var prev = motion.first;
    for (final t in motion.skip(1)) {
      if (t.difference(prev) > kMotionGap) {
        out.add((start, prev));
        start = t;
      }
      prev = t;
    }
    out.add((start, prev));
    return out;
  }

  /// Собрать одну поездку из окна. Возвращает false, если окно поездкой
  /// не является — тогда строки остаются без штампа, а водяной знак всё
  /// равно уходит вперёд.
  static Future<bool> _buildOne(
    AppDatabase db,
    List<HalSample> window,
    DateTime from,
    DateTime to,
    double batteryCapacityKwh,
  ) async {
    double? firstOf(String n) {
      for (final r in window) {
        if (r.name == n && r.numericValue != null) return r.numericValue;
      }
      return null;
    }

    double? lastOf(String n) {
      for (final r in window.reversed) {
        if (r.name == n && r.numericValue != null) return r.numericValue;
      }
      return null;
    }

    double? minOf(String n) {
      double? m;
      for (final r in window) {
        final v = r.numericValue;
        if (r.name == n && v != null && (m == null || v < m)) m = v;
      }
      return m;
    }

    double? maxOf(String n) {
      double? m;
      for (final r in window) {
        final v = r.numericValue;
        if (r.name == n && v != null && (m == null || v > m)) m = v;
      }
      return m;
    }

    final startOdo = firstOf('odometer');
    final endOdo = lastOf('odometer');
    final startSoc = firstOf('soc_precise');
    final endSoc = lastOf('soc_precise');

    // Скорость: сумма и счёт ТОЛЬКО по движущимся отсчётам — так же, как
    // копит живой путь, иначе средняя скорость поездки поедет вниз от
    // стояния на светофоре.
    var speedSum = 0.0;
    var speedSamples = 0;
    for (final r in window) {
      final v = r.numericValue;
      if (r.name == 'speed' && v != null && v > 0) {
        speedSum += v;
        speedSamples++;
      }
    }

    final derived = computeTripDerived(
      startOdoKm: startOdo,
      endOdoKm: endOdo,
      startSocPct: startSoc,
      endSocPct: endSoc,
      // ПЕРЕКРЁСТНОЙ ПРОВЕРКИ ЗДЕСЬ НЕТ, И ПОЛЕ ОСТАЁТСЯ ПУСТЫМ. У живого
      // пути `energyFromSocKwh` считается по ДРУГОМУ источнику, чем
      // `energyUsedKwh`, и в том весь его смысл. В фоне источник один —
      // `soc_precise`, — и заполнить оба значило бы сверить число с самим
      // собой и выдать совпадение за подтверждение.
      startSocPrecisePct: null,
      endSocPrecisePct: null,
      speedSum: speedSum,
      speedSamples: speedSamples,
      batteryCapacityKwh: batteryCapacityKwh,
    );

    final dist = derived.distanceKm;
    if (dist == null || dist < kMinDistanceKm) return false;

    // Разброс ячеек: пара «выше/ниже» приходит разными кадрами, поэтому
    // считаем по последним известным значениям обоих, а не по одному
    // кадру — иначе разброс не посчитается никогда.
    double? spreadMv;
    double? hi;
    double? lo;
    for (final r in window) {
      final v = r.numericValue;
      if (v == null) continue;
      if (r.name == 'cell_v_highest') hi = v;
      if (r.name == 'cell_v_lowest') lo = v;
      if (hi != null && lo != null) {
        final d = (hi - lo) * 1000.0;
        if (spreadMv == null || d > spreadMv) spreadMv = d;
      }
    }

    final totalSec = to.difference(from).inSeconds;
    // ВРЕМЯ В ДВИЖЕНИИ СЧИТАЕТСЯ ПО ПРОМЕЖУТКАМ, А НЕ УМНОЖЕНИЕМ НА ШАГ
    // ПРОРЕЖИВАНИЯ. Первая редакция брала `speedSamples * 3`, и это было
    // бы верно ровно до §2 того же патча, который опустил порог `speed`
    // до секунды: время в движении выросло бы втрое, а простой ушёл бы в
    // минус. Промежуток ограничен сверху, иначе молчание ON-CHANGE на
    // ровном ходу зачлось бы как стоянка наоборот.
    const maxGapSec = 15;
    var movingSec = 0;
    DateTime? prevMoving;
    for (final r in window) {
      final v = r.numericValue;
      if (r.name != 'speed' || v == null || v <= 0) continue;
      if (prevMoving != null) {
        final gap = r.timestamp.difference(prevMoving).inSeconds;
        movingSec += gap > maxGapSec ? maxGapSec : gap;
      }
      prevMoving = r.timestamp;
    }
    // Вставка и штамп ОДНОЙ ТРАНЗАКЦИЕЙ: врозь они оставляли поездку без
    // приписанных строк, и следующий запуск строил её второй раз.
    await db.insertTripWithStampedSamples(
      windowFrom: from,
      windowTo: to,
      startedAt: from,
      endedAt: to,
      source: kSourceHalBg,
      startSoc: startSoc,
      endSoc: endSoc,
      startOdo: startOdo,
      endOdo: endOdo,
      sampleCount: window.length,
      distanceKm: dist,
      energyUsedKwh: derived.energyUsedKwh,
      avgConsumptionKwh100km: derived.avgConsumptionKwh100km,
      minBatteryTempC: minOf('battery_temp_bigdata'),
      maxBatteryTempC: maxOf('battery_temp_bigdata'),
      maxCellSpreadMv: spreadMv,
      minSoc: minOf('soc_precise'),
      maxSoc: maxOf('soc_precise'),
      peakSpeedKmh: maxOf('speed'),
      avgMovingSpeedKmh: derived.avgMovingSpeedKmh,
      movingSeconds: movingSec > 0 ? movingSec : null,
      idleSeconds: totalSec > movingSec ? totalSec - movingSec : null,
      energyFromSocKwh: derived.energyFromSocKwh,
    );
    return true;
  }
}

/// Метка происхождения в `trips.source`. Литерал живёт здесь, а читается
/// экраном поездки — HAL-поездка обязана называться своим именем.
const String kSourceHalBg = 'hal_bg';

/// Отчёт одного прохода. Все поля считаются всегда, даже когда строить
/// нечего: ноль построенных при тысяче просмотренных — это диагноз, а
/// молчание — нет.
class BgTripBuildResult {
  final int scanned;
  final int built;
  final int discarded;
  final String? error;

  const BgTripBuildResult({
    required this.scanned,
    required this.built,
    required this.discarded,
    this.error,
  });

  @override
  String toString() => 'BgTripBuildResult(scanned: $scanned, built: $built, '
      'discarded: $discarded, error: $error)';
}
