/// v0.1.32+131: the ONE place user-facing SOC is resolved.
///
/// Before +131 the expression
///   `hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct`
/// was copy-pasted across six screens, and it always preferred the
/// BMS-internal (true) SOC — which legitimately differs from the number
/// on the instrument cluster by ~1-2%. Users compared the app against
/// the cluster and read the difference as a bug.
///
/// Now every DISPLAYED SOC digit goes through [resolveUiSocPct], which
/// honours the user's SocSource setting (Settings → "Battery
/// percentage"). Math paths are deliberately NOT routed here: trip
/// energy (halSocForTrip), SOH and the charging-ETA input keep reading
/// precise SOC unconditionally — the setting changes pixels, not
/// physics.
library;

import 'connection.dart';
import 'hal_telemetry_service.dart';

/// User-facing SOC in %, per the SocSource preference.
///
///   - SocSource.display : the cluster figure — HAL soc_display (sticky,
///     event-driven, no hold window) → soc_battery → ROUNDED precise as
///     the last resort, so the scale never jumps between integer and
///     fractional while falling back. On a dongle-only setup (no HAL)
///     display-SOC does not exist in UDS — the honest fallback is the
///     precise OBD2 value, same as the pre-+131 behaviour.
///   - SocSource.precise : the pre-+131 resolution verbatim (BMS-true,
///     0.1% steps).
double? resolveUiSocPct(HalTelemetryService hal, ConnectionService svc) {
  // v0.1.42+141: CONFIRMED phone → the SocSource setting is hidden in
  // Settings and precise is forced here, so a value chosen back when
  // (or a shared-pref default) can't keep steering a control the user
  // can no longer see. Over the dongle "display" never existed anyway
  // — it silently degraded to round(precise); this returns the full
  // fractional value instead. Same probe discipline as the settings
  // gate: act only once the platform probe settled (canUseHal alone is
  // false on a cold-starting head unit too).
  if (hal.platformProbed && !hal.canUseHal) {
    return svc.socPrecisePct;
  }
  if (hal.socSource == SocSource.precise) {
    return hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct;
  }
  final d = hal.halSocDisplayPct;
  if (d != null) return d;
  final p = hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct;
  return p?.roundToDouble();
}

/// FP-safe split of a SOC value into the big integer part and the small
/// fractional suffix, for the "72" + ".4" two-Text layout the SOC cards
/// use. Rounds to the visible tenth FIRST (naive truncate() renders
/// 48.30 stored as 48.2999… as "48.2"), then splits.
///
/// v0.1.32+131: an integral value returns an EMPTY suffix — in
/// SocSource.display mode every value is integral and the card shows a
/// clean "72" like the cluster, not "72.0".
(String, String) splitSocDigits(double? v) {
  if (v == null) return ('—', '');
  final r = (v * 10).round() / 10;
  final frac = ((r - r.truncate()) * 10).round();
  return (r.truncate().toString(), frac == 0 ? '' : '.$frac');
}

/// Plain one-line SOC text ("72" / "72.4") for inline labels and chips.
/// [maxDecimals] caps the fractional digits (the wide charging screen
/// historically showed two); integral values always collapse to "72".
String formatSocPct(double v, {int maxDecimals = 1}) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(maxDecimals);
}

// ══════════ v0.2.14+213: мощность и фаза зарядки — по одному ответчику ══════════
//
// ПОЧЕМУ ЭТО ПЕРЕЕХАЛО СЮДА. Поле 24.08 привезло два снимка: баннер писал
// «Зарядка · запуск…», а фаза висела в «анализ…» — при живых 2.5 kW и
// 40.2 % на том же экране. Причина одна на оба места: они спрашивали
// ТОЛЬКО путь через донгл, которого на голове нет. +210 научил читать HAL
// герой-строку, историю и суммы, но баннер и фаза остались на прежнем
// пути.
//
// Латать их по отдельности было нельзя: цепочка выбора мощности жила
// внутри `_PowerHero`, и копия в баннере плюс копия в фазе дали бы ТРИ
// ответа на вопрос «сколько сейчас киловатт». Ровно та поломка, которую
// +209 лечил для предиката сессии. Поэтому цепочка и правило фазы стоят
// здесь, рядом с `resolveUiSocPct`, а экран, баннер и фаза их читают.
//
// Файл уже видит оба сервиса, так что новых связей не появилось.

/// Мощность зарядки и признак «это оценка, а не измерение».

/// Единственное место, где решается «сколько сейчас киловатт».
///
/// Порядок: UDS через донгл → HAL |V×I|. Ноль от HAL чистится до null
/// (правка +211: в моменте ток бывает нулевым при живой зарядке). Ноль на
/// выходе значит «числа нет», и экраны рисуют тире.
///
/// v0.2.16+215: третье звено — наклон энергосчётчика — УБРАНО вместе с
/// флагом `approx`. Экспорт 05.09 (AC, 2 ч 31 мин): счётчик давал 1.72 при
/// 2.93 по V×I, 2.9 на щитке и ≈2.8 по ΔSOC, устойчиво на 41 % ниже и без
/// реакции на колебания мощности. Знак «≈» перед заведомо неверным числом
/// не честность, а оправдание. Счётчик остался детектором зарядки — там он
/// честен (решение владельца, окно №23).
double resolveChargePowerKw(HalTelemetryService hal, ConnectionService svc) {
  final kwObd = svc.chargingPowerKw;
  final kwHalRaw = hal.halChargePowerKw;
  final kwHal = (kwHalRaw != null && kwHalRaw > 0) ? kwHalRaw : null;
  return kwObd > 0 ? kwObd : (kwHal ?? 0);
}

/// Единственное место, где решается «сколько ждать».
///
/// v0.2.17+216: до этого время до полного считалось ЧЕТЫРЬМЯ способами в
/// четырёх местах — панели дэшбордов делили остаток kWh на мощность и
/// отвечали сразу, широкий экран и баннер ждали ≥0.5 % роста SOC и две
/// минуты, потом делили темп роста (в подписи при этом стояло «нужно ≥5
/// минут», хотя 0.5 % на 2.9 kW набегает за семь). Водитель видел два
/// разных времени на двух экранах. Теперь мощность V×I надёжна всю сессию
/// (+215), и ждать нечего: остаток ёмкости до цели, делённый на мощность.
///
/// SOC берётся ТОЧНЫЙ, не тот, что выбран для показа (+131): это
/// арифметика, а не цифра на экране. null — нет мощности или заряда, либо
/// цель уже достигнута. Оценка линейная и к концу занижает: в CV ток
/// падает, подпись на экране об этом говорит.
int? resolveEtaSeconds(HalTelemetryService hal, ConnectionService svc,
    {double targetPct = 100}) {
  final kw = resolveChargePowerKw(hal, svc);
  if (kw <= 0.1) return null;
  final soc = hal.useHalForSoc
      ? hal.halSocPct
      : (svc.socPrecisePct ?? svc.readNumeric('790', '0005'));
  if (soc == null || soc >= targetPct) return null;
  final hours =
      (targetPct - soc) / 100 * ConnectionService.batteryCapacityKwh / kw;
  return (hours * 3600).round();
}

/// Фаза зарядки, считаемая от любого живого источника.
///
/// Правило то же, что жило в `ConnectionService.chargingPhase`, но входы
/// больше не привязаны к донглу: активность — UDS ∨ HAL, мощность — через
/// [resolveChargePowerKw], SOC — через [resolveUiSocPct], максимум ячейки
/// из UDS либо из HAL (там вольты, здесь милливольты).
///
/// Порог в три точки истории оставлен: без него пик мощности не с чем
/// сравнивать, и CV нельзя отличить от CC. Историю берём ту, которая
/// реально наполняется — на голове это HAL.
ChargingPhase resolveChargingPhase(
    HalTelemetryService hal, ConnectionService svc) {
  if (!(svc.isCharging || hal.halChargingActive)) {
    return ChargingPhase.unknown;
  }

  final udsHist = svc.chargingHistory;
  final halHist = hal.halChargingHistory;
  final useHal = udsHist.length < 3;
  final int points = useHal ? halHist.length : udsHist.length;
  if (points < 3) return ChargingPhase.unknown;

  final soc = resolveUiSocPct(hal, svc);
  final powerKw = resolveChargePowerKw(hal, svc);

  // ── v0.2.15+214: ПОРОГ ПО МОЩНОСТИ УБРАН ──
  //
  // Было: «почти готово», если мощность ниже 3 kW. Правило писалось под
  // быструю зарядку, где 3 kW действительно значит конец. На домашней AC
  // 2.9 kW — нормальный режим С ПЕРВОЙ СЕКУНДЫ, поэтому фаза врала всю
  // сессию: поле 28.08 показало «Почти готово» при 17.2 % заряда. Это была
  // прямая ложь водителю, и порог заменён на единственный признак, который
  // не зависит от типа зарядки, — сам уровень заряда.
  if (soc != null && soc >= 95) {
    return ChargingPhase.almostDone;
  }

  final cellHighV = hal.halCellVHighest;
  final maxCellMv = svc.globalMaxCellMv ??
      (cellHighV != null ? (cellHighV * 1000).round() : null);
  if (maxCellMv != null && maxCellMv >= 3400) {
    double peak = 0;
    if (useHal) {
      for (final p in halHist) {
        final v = p.kw ?? 0;
        if (v > peak) peak = v;
      }
    } else {
      for (final s in udsHist) {
        final v = s.powerKw ?? 0;
        if (v > peak) peak = v;
      }
    }
    if (peak > 0 && powerKw < peak * 0.8) return ChargingPhase.cv;
  }
  // На AC отличить CC от CV нечем: тейпер виден по спаду тока при почти
  // постоянном напряжении, а ток там приходит трижды за семь минут —
  // производную строить не из чего. Поэтому до 95 % честно говорим CC, а не
  // угадываем переход. Если разведка привезёт фазу готовым сигналом от
  // машины, это правило целиком выбрасывается.
  return ChargingPhase.cc;
}
