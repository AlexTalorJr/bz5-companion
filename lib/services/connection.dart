import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;

import '../ble/elm327_ble.dart';
import '../ble/elm327_client.dart';
import '../data/ecu_registry.dart';
import '../data/database.dart';

enum ConnectionStatus { disconnected, scanning, connecting, connected, error }
enum PollMode { driving, charging, full }

/// v0.1.29+22: sentinel object used by `runLiveLog` to detect which arm
/// of a `Future.any` race won. We can't rely on a typed null because
/// `readDid` legitimately returns `EcuResponse?` and a null result has
/// its own meaning; an `Object` instance disambiguates the kill arm via
/// `identical(...)`.
final Object _killedSentinel = Object();

/// v0.1.29+23: SharedPreferences key for the monotonic
/// `client_session_id` counter used when inserting LiveLogSession rows.
/// Survives app restart and in-place APK updates (phone). Does NOT
/// survive uninstall+install (head unit) — that's a known gap, see
/// runLiveLog for rationale.
const String _kLiveLogSessionIdNext =
    'connection_live_log_session_id_next';

/// v0.1.29+29: same idea for CanMonitorSession rows. Separate namespace
/// from live-log: the bridge enforces UNIQUE(device_id,
/// client_session_id) PER TABLE (livelog vs canmonitor are different
/// tables), so the two counters can coexist without collision. Carrying
/// a distinct key makes the intent explicit and avoids any accidental
/// cross-tail growth between the two streams.
const String _kCanMonitorSessionIdNext =
    'connection_can_monitor_session_id_next';

/// === BZ5 Physical Model (v5) ===
///
/// Калибровочные константы из реверс-инжиниринга 30 апреля - 1 мая 2026.
class Bz5Model {
  /// Scale для 0B00 charge counter — 1 unit ≈ 460 Wh.
  /// ⚠ DEPRECATED as of v0.1.26+11. Charge counter 0x0B00 has been
  /// confirmed empirically NOT to be a linear energy counter:
  ///
  /// Test 2026-05-20 (livelog session 22):
  ///   - 5-minute AC charge at constant 2.85 kW (station readout)
  ///   - SOC progression was perfectly linear: +0.10% every ~83 sec
  ///     (consistent with 2.83 kW into pack — ~99% AC efficiency)
  ///   - Counter behaviour was wildly nonlinear:
  ///     · first ~30 sec: ~1 unit / 2 sec (precharge / initial burst)
  ///     · middle phase: ~1 unit / 9 sec
  ///     · steady-state: ~1 unit / 30 sec
  ///     · saturation:   ~1 unit / 60+ sec
  ///   - Implied "Wh per unit" varied from 2.6 to 32+ within ONE session
  ///     at constant input power
  ///
  /// Interpretation: 0x0B00 increments on internal OBC/BMS state-machine
  /// events (precharge ticks, sync pulses, balance cycles), not on
  /// integrated energy. Treating it as energy gave numbers 5-150× off.
  ///
  /// Replacement strategy:
  ///   - For energy:  ΔSOC × batteryCapacityKwh (precise, slow refresh)
  ///   - For power:   d(SOC)/dt × batteryCapacityKwh (slow but accurate)
  ///   - For detection ONLY: counter rate change (still ideal — counter
  ///     IS rock-stable in parked state and IS rising during any charge)
  ///
  /// This constant is kept around with value preserved so existing
  /// references don't break the build during the transition; all
  /// production code paths are migrating off it. New code MUST NOT
  /// reference it. Remove entirely in v0.1.27 once UI is verified.
  @Deprecated('0x0B00 is not a linear energy counter — use ΔSOC × batteryCapacityKwh instead')
  static const double chargeCounterWh = 460.0;

  /// Pack capacity, kWh. BZ5 has two known variants:
  ///   - 65.28 kWh (smaller pack — verified on this vehicle)
  ///   - 73.984 kWh (larger pack — owner-reported)
  ///
  /// Used for ALL energy/power calculations on the charging side via
  /// ΔSOC × batteryCapacityKwh / 100. Also used as backstop for
  /// trip-side energy-from-SOC when no charging session is active.
  ///
  /// 65.28 kWh value подтверждена ETA-калькуляцией приборки (13ч 26м при
  /// 2.8 кВт от 46% = 35.25 кВт·ч до полной → ёмкость 65.3 кВт·ч).
  ///
  /// TODO v0.1.27 — auto-detect pack variant from 740/0105 part number
  /// or 1FFD low16 fingerprint (BZ5 = 0x3B09 across both variants per
  /// observation, so part-number lookup will be required).
  static const double batteryCapacityKwh = 65.28;

  /// Pack voltage scale: DID 0x0015, raw × 0.02 V.
  /// Подтверждено на стоянке: на 100% SOC raw=18077 → 361.5 V (норма LFP),
  /// в поездке raw=17445-18077 → 348.9-361.5 V.
  ///
  /// ⚠ NB! v6.1: замер 2026-05-03 в Ready+AC при 82% SOC показал raw≈13600 → 272 V,
  /// что физически несовместимо с замером при 50% SOC ≈ 334 V. Гипотеза: 0x0015
  /// возвращает разную семантику в разных режимах (resting OCV vs derated estimate).
  /// Использовать pack voltage как charging-detection signal пока нельзя.
  /// TODO: расследовать после внедрения in-app diagnostic.
  static const double packVoltageScale = 0.02;

  /// Pack voltage "no data" sentinel.
  static const int packVoltageInvalidRaw = 0xFFFF;

  /// Средний расход BZ5 по приборке = 14.4 кВт·ч / 100 км = 144 Wh/km
  static const double avgConsumptionWhKm = 144.0;
}

/// Snapshot одного чтения charge counter 0x0B00.
/// Используется для rolling-window charging detection в [ConnectionService].
class _B00Sample {
  final DateTime time;
  final int value;
  const _B00Sample(this.time, this.value);
}

/// v0.1.26: одна точка истории во время DC/AC зарядки.
///
/// Накапливается в [ConnectionService._chargingHistory] раз в ~5 секунд пока
/// [ConnectionService.isCharging] == true. Используется графиками на
/// ChargingViewWide (power, cell V, battery temp vs time) и расчётом ETA
/// до 100% SOC через регрессию по последним N точкам SOC.
///
/// Все поля nullable: если конкретный DID не успел прочитаться в момент
/// записи sample, value будет null и точка просто пропускается на графике
/// — это лучше чем синтетическая нулевая точка, которая дала бы ложный
/// провал на chart'е.
class ChargingSample {
  final DateTime time;
  final double? powerKw;
  final double? socPct;
  final double? hvBusV;
  final int? cellMinMv;
  final int? cellMaxMv;
  final double? tempC;
  final int? counter;
  const ChargingSample({
    required this.time,
    this.powerKw,
    this.socPct,
    this.hvBusV,
    this.cellMinMv,
    this.cellMaxMv,
    this.tempC,
    this.counter,
  });

  int? get spreadMv =>
      (cellMinMv != null && cellMaxMv != null) ? cellMaxMv! - cellMinMv! : null;
}

/// v0.1.26: фазы DC-зарядки для индикатора на ChargingViewWide.
enum ChargingPhase {
  /// Идёт зарядка но фаза ещё не определена (мало данных).
  unknown,
  /// Constant Current — пик мощности, max cell V держится далеко от cutoff.
  cc,
  /// Constant Voltage — мощность падает, max cell V подобрался к уставке.
  cv,
  /// SOC ≥ 95% или power < 3 кВт — почти готово.
  almostDone,
}

class ConnectionService extends ChangeNotifier {
  final AppDatabase db;
  Elm327Ble? _ble;
  Elm327Client? _client;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  String? _statusMessage;
  String? _adapterAddress;

  bool _polling = false;
  PollMode _pollMode = PollMode.full;

  final Map<String, Map<String, DecodedValue>> _latestValues = {};

  // === v6.1: Rolling-window charging detection ===
  // === v0.1.26+3: добавлен fast-path для DC чтобы детектировать за ~60 сек ===
  //
  // История значений 0x0B00 за последние ~20 минут. Используется для надёжной
  // детекции зарядки через монотонный рост в окне (не одиночные delta).
  //
  // Корни проблемы (verified эмпирически 2026-05-02..03):
  //  • На выключенной машине counter монотонно убывает ~1 unit/95s.
  //  • В Ready+AC counter колеблется ±1 unit без выраженного тренда:
  //    33-минутный sweep дал 12 положительных delta, 10 отрицательных,
  //    суммарный диапазон всего 3 значения.
  //  • Старая логика "delta > 0 → charging" ловила любой одиночный glitch
  //    и зажигала banner на 15 минут. Banner мог висеть сутками
  //    (постоянно перезажигаясь от очередного шумового +1).
  //
  // === Two-track detection ===
  //
  // Fast path (DC ≥80 кВт case): за последние 60 секунд ≥3 положительных
  // increment'а без единого отрицательного delta. Это срабатывает только
  // при rate ≥1 unit / 20 с = ≥83 кВт — никакая AC, никакой шум счётчика
  // в Ready такого не дают (там rate ~1 delta / 90 с по данным sweep'а).
  // Дает срабатывание через 30–60 сек после plug-in.
  //
  // Slow path (AC 7+ кВт и слабый DC): окно 10 минут, net delta ≥2 +
  // нет отрицательных delta в окне. Это catches случай когда rate
  // недостаточен для fast path, но всё равно настоящая зарядка.
  // Время до срабатывания: ~3–10 мин в зависимости от мощности.
  //
  // isCharging = fastPath || slowPath
  //
  // На зарядке (любой мощности) counter растёт строго монотонно; глитчей
  // вниз не наблюдается. На стоянке и в Ready всегда есть отрицательные
  // delta в любом окне ≥10 минут — фильтр "no negatives" их режет.
  //
  // Trade-off:
  //  • DC ≥80 кВт: 30–60 сек до срабатывания (fast path).
  //  • DC <80 кВт / AC 7–22 кВт: 3–10 мин (slow path с окном 10 мин).
  //  • AC 2.8 кВт: ~20 мин (на грани — counter инкрементится раз в ~10 мин,
  //    нужно 2 в окне). Это был known-edge-case ещё в v6.1.
  final List<_B00Sample> _b00History = [];
  static const Duration _b00HistoryMaxAge = Duration(minutes: 20);
  // Slow path: длинное окно для catch'а отрицательных delta в Ready+AC.
  // Сокращено с 15 → 10 мин в v0.1.26+3 — это снижает время до slow
  // detection на 33%, при этом за 10 мин в Ready+AC всё равно набегает
  // 6–7 delta (среднее), и шанс что все они positive — (12/22)^6 ≈ 3%.
  // Acceptable false-positive rate.
  static const Duration _chargingDetectionSlowWindow = Duration(minutes: 10);
  static const int _chargingDetectionMinNetDelta = 2;
  // Fast path: короткое окно + минимум 3 положительных transition'а.
  // Cutoff 3 inc / 60 sec эквивалентен мощности ≥83 кВт — никакая AC и
  // никакой шум counter в Ready такого rate не достигают.
  static const Duration _chargingDetectionFastWindow = Duration(seconds: 60);
  static const int _chargingDetectionFastMinPositiveTransitions = 3;

  // v0.1.26: rolling-window charging history for ChargingViewWide charts
  // (power / cell V / temp / SOC vs time) and ETA-to-full extrapolation.
  //
  // Captured every _chargingHistoryInterval seconds while [isCharging]==true.
  // Cleared on charging→idle transition so a fresh session starts blank.
  // Bounded by _chargingHistoryMaxAge — at 5 s/sample that's ~720 entries,
  // negligible RAM but plenty of resolution for a 1-2 h charging session.
  final List<ChargingSample> _chargingHistory = [];
  static const Duration _chargingHistoryMaxAge = Duration(minutes: 60);
  static const Duration _chargingHistoryInterval = Duration(seconds: 5);
  bool _wasCharging = false;
  DateTime? _lastChargingSampleAt;
  DateTime? _chargingSessionStartedAt;
  int? _chargingSessionStartCounter;
  double? _chargingSessionStartSocPct;

  /// Минимальный интервал между записями в _b00History если значение не
  /// поменялось. При flat counter добавляем snapshot раз в 10 секунд —
  /// этого достаточно для интерполяции значения в произвольный момент окна,
  /// но не раздувает историю в RAM (~120 entries за 20 мин).
  static const Duration _b00FlatSampleInterval = Duration(seconds: 10);

  /// Мгновенная мощность зарядки в кВт.
  /// Считается по последнему положительному инкременту 0x0B00.
  /// На дисплее отображается только когда [isCharging] true (UI gating).
  double _instantaneousChargingPowerKw = 0.0;

  int? _currentTripId;
  DateTime? _tripStartedAt;          // v0.1.9 in-memory for duration getter

  // v0.1.29+43: trip segmentation by parking. A drive ends when the car
  // sits in P for longer than _kParkCloseThreshold; the next shift into D
  // starts a fresh trip (via the existing _maybeStartTrip). Without this,
  // every drive folded into one ever-growing trip because a new trip was
  // only created on a new poll session, not on park/stop (Друг 2: all
  // drives accreted into client_trip_id=1).
  //
  // Robustness: 791/0009 (gear) can misread momentarily, so P must hold
  // for _kParkConfirmDuration of wall-clock time before the park clock
  // starts — a single spurious P frame won't arm it. Time-based (not
  // cycle-count) because poll-cycle length varies with bus load. The
  // actual close reuses _finalizeTripFromLastKnown (the same path as a
  // clean end), so aggregates are computed identically and the existing
  // null-guards make a later BLE-drop finalize a harmless no-op (no
  // double close).
  DateTime? _parkConfirmStart;       // first P read of the current P streak
  DateTime? _parkedSince;            // when P was confirmed stable
  static const Duration _kParkConfirmDuration = Duration(seconds: 30);
  static const Duration _kParkCloseThreshold = Duration(minutes: 10);
  int _samplesInTrip = 0;
  double? _tripStartSoc;
  double? _tripStartOdo;
  int? _tripStartB00;

  // v0.1.9: rolling trip aggregates (computed during polling, written at endTrip).
  // All min/max trackers update on each cycle's relevant DID read.
  double? _tripMinTempC;
  double? _tripMaxTempC;
  double? _tripMaxCellSpreadMv;
  double? _tripMinSoc;
  double? _tripMaxSoc;
  double? _tripPeakSpeedKmh;     // v0.1.21: populated from 740/0x0008 speed
  double? _tripPeakPowerKw;      // 791/0x0038 magnitude
  double? _tripPeakRegenKw;      // most-negative power (regen)
  double? _tripRegenEnergyKwh;   // integrated regen power over time (estimate)

  // v0.1.21 trip aggregates — enabled by 740/0x0008 speed discovery
  // and 790/0x1FFD precise SOC discovery (both verified 2026-05-19).
  //
  // Speed is sampled once per poll cycle. Moving = speed > 1.0 km/h
  // (debounce gate, avoids creep+drift counting as movement). Idle =
  // everything else with the car still in Ready. Sum-of-speed-samples
  // / moving-samples gives a sample-weighted average, which is biased
  // toward periods where cycle time is consistent (poll cycle varies
  // 1.2–8 s depending on DID count, but speed lives in the fast lane).
  double _tripSpeedSum = 0;     // for averaging
  int _tripSpeedSamples = 0;    // count of moving samples (speed > 1.0)
  // v0.1.29+55: changed from seconds to milliseconds. Previously the
  // per-cycle dt was integer-divided by 1000 (secs = attribMs ~/ 1000),
  // which silently dropped sub-second contributions on every tick;
  // since typical cycle was 50 ms, that meant ALL ticks contributed 0
  // unless one happened to fall just past a 1000 ms boundary. The
  // accumulators only registered movement during the long iterations
  // (slow tasks like _pollCells, recovery). Net effect: history showed
  // moving/idle totals that didn't match distance / avg_moving math.
  // Storing milliseconds and converting once at endTrip avoids all
  // integer-division loss.
  int _tripMovingMs = 0;        // accumulated moving time in milliseconds
  int _tripIdleMs = 0;          // accumulated idle (Ready, not moving) ms
  // v0.1.29+55: dedicated timestamp updated ONLY when a fresh 740/0008
  // sample actually arrives in _pollSpeedOnly (i.e. the BLE read
  // succeeded and decode passed sanity). The old _lastSpeedSampleAt
  // was updated every poll-loop iteration, conflating cycle ticks
  // with sample arrivals.
  DateTime? _lastSpeedFreshAt;
  DateTime? _lastSpeedSampleAt; // v0.1.29+55: retained, no longer used by accounting
  double? _tripStartSocPrecise; // first precise SOC captured at trip start

  // v0.1.24: EMA window for trip-aware Range. Expanded from 2 min to
  // 5 min based on real-world feedback that 2-min mean was too jittery
  // — Range visibly jumped on minor accel/decel.
  //
  // Also switched from arithmetic mean to **rolling median**: median
  // is robust to outliers, so brief hard accels (which spike sample
  // to 30-40 kWh/100km for 2-3 cycles) don't yank the displayed Range.
  // The median pulls toward the "typical" driving regime of the last
  // 5 minutes.
  //
  // Minimum sample count bumped 5 → 20 so a few early samples can't
  // dominate the median during the first ~30 s of a trip.
  final List<(DateTime, double)> _consumptionWindow = [];
  static const Duration _consumptionWindowDuration = Duration(minutes: 5);
  static const int _consumptionWindowMinSamples = 20;

  // v0.1.26+10: HV-bus-sag power heuristic — fallback peak_power/regen
  // estimation while we haven't found a direct pack-current DID.
  //
  // Theory: peak motor draw causes the HV bus voltage to sag below its
  // open-circuit baseline by `ΔV = I × R_pack`. Solving for power:
  //   P_kW = V_terminal × ΔV / (1000 × R_pack)
  //
  // Calibration anchors (from livelog 18 trip 14, 2026-05-20):
  //   cycle 185 saw HV bus drop to 354.1 V from baseline ~400 V
  //     (Δ = 45.9 V) — user reported "hard acceleration" then
  //   cycle 59 saw HV bus rise to 428.8 V from baseline ~400 V
  //     (Δ = 28.8 V) — user reported "hard regen" then
  //   With BZ5 motor rated 200 kW peak / regen typically 60-70 kW
  //   capped by LFP charge acceptance, the only R that satisfies
  //   both observations is ~0.18 Ω:
  //     accel:  354.1 × 45.9 / 0.18 / 1000 = 90 kW (city drive, not peak)
  //     regen:  428.8 × 28.8 / 0.18 / 1000 = 69 kW (matches regen cap)
  //
  // V_oc is approximated by a rolling average of recent "near-idle"
  // HV bus samples — defined as samples where cell spread ≤ 5 mV
  // (low spread = balanced pack = low current = near OC). Rolling
  // rather than fixed-at-start because:
  //   - V_oc drifts ~10-20 V over the SOC range used in one trip
  //   - HV bus 790/0x0015 may be measured post-DC-DC, adding bias
  //     that changes with vehicle electrical load
  //
  // Accuracy: ±20-30 %. Acceptable for the trip-stats badge until we
  // wire a real current DID. UI must mark these values as "estimated"
  // (e.g. "~95 kW est.") so they aren't confused with measured peaks
  // when a direct DID is later found.
  static const double _packResistanceOhm = 0.18;
  static const int _idleSpreadThresholdMv = 5;
  static const int _idleHvBusWindowSize = 60; // last ~60 samples ≈ 30 sec
  final List<double> _recentIdleHvBus = [];
  bool _peakPowerFromHeuristic = false;
  bool _peakRegenFromHeuristic = false;

  // v0.1.9: snapshot writer state.
  // Снимок пишется в БД раз в 2 мин во время поездки, раз в 10 мин вне поездки.
  // Это позволяет строить долговременные графики (24h/7d/30d/year) без
  // утопания в гигабайтных таблицах Samples.
  DateTime? _lastSnapshotAt;
  static const Duration _snapshotIntervalInTrip = Duration(minutes: 2);
  static const Duration _snapshotIntervalIdle = Duration(minutes: 10);

  // v4: deferred trip creation
  bool _wantTripCreation = false;
  int _pollCyclesSinceStart = 0;

  // v5: rolling cell spread for stable display
  final List<int> _cellSpreadHistory = [];
  static const int _cellSpreadHistoryMax = 10;

  List<int> _liveCells = [];

  // === v0.1.3: Extra DIDs not in registry ===
  //
  // Эти DID-ы поллятся напрямую через _pollExtraDids() — они не входят в
  // EcuSpec реестр и не имеют формальных decoder'ов. Раскладка:
  //  - 740/0x0022 = filtered pack voltage (×0.025 V) — основной источник pack V
  //  - 740/0x0014 = instant pack voltage (×0.025 V) — для будущей diag-карточки
  //  - 790/0x002C = global min cell index (0..135) — какая ячейка самая низкая
  //  - 790/0x002E = global max cell index (0..135)
  //  - 790/0x0B03 = pack cell count (0x88 = 136) — читается один раз
  //  - 790/0x0A07 = pack module count (0x0A = 10) — читается один раз
  //
  // v0.1.6: добавлены 790/0x002B и 790/0x002D (cell V min/max in mV).
  // Эти DID-ы есть в registry с category=DidCategory.cells, но _pollEcu
  // пропускает все cell-категории (строка ~536), а _pollCells читает только
  // массив 0x016D-0x01B7. В результате 0x002B/0x002D никогда не читаются —
  // Pack Extremes UI висит в "loading…" вечно. Чтобы не править registry/
  // poll архитектуру (рискованно), читаем напрямую тут.
  //
  // v0.1.8: добавлен 790/0x0015 (HV bus voltage). Registry на старте имел
  // scale=0.02 — это была неверная интерпретация (думали что это pack V).
  // Реверс 2026-05-15 в Ready показал что правильный scale = 0.025
  // (× 0.025 → 429 V в Ready, что совпадает с ожидаемым ~448 V pack V
  // минус ~20 V на main contactor + фильтры).
  //
  // v0.1.8 cleanup: scale в registry поправлен на 0.025 + name → 'HV bus'.
  // Поэтому 0x0015 теперь читается ТОЛЬКО через registry (_pollEcu),
  // hvBusV getter использует readNumeric('790', '0015'). Дублирование
  // через _pollExtraDids убрано.
  //
  // Найдено в реверсе 2026-05-03 (см. README/findings).
  double? _packVoltageFilteredV;     // 740/0x0022
  double? _packVoltageInstantV;      // 740/0x0014
  int? _globalMinCellIndex;          // 790/0x002C
  int? _globalMaxCellIndex;          // 790/0x002E
  int? _globalMinCellMv;             // 790/0x002B (v0.1.6)
  int? _globalMaxCellMv;             // 790/0x002D (v0.1.6)
  int? _packCellCount;               // 790/0x0B03
  int? _packModuleCount;             // 790/0x0A07

  /// v0.1.29+30: fast-cadence pack voltage estimate derived from a
  /// min/max-cell sub-poll, in volts. Updated ~1 Hz by
  /// [_pollCellExtremesOnly] (slotted in _pollLoop alongside the speed
  /// and HV-bus sub-polls). This is a STALE-GAP FILLER: the primary
  /// user-facing pack voltage is [packVoltageFromCells] (full 20-value
  /// module average), but that only refreshes every ~6 s because
  /// _pollCells runs on cycle%2. Between those full refreshes the
  /// dashboard had a frozen number; this gives it a live value computed
  /// from (min+max)/2 × cellCount, which tracks load transients without
  /// the per-module read cost.
  ///
  /// Null until the first successful extremes sub-poll. The getter
  /// [packVoltageFromCells] prefers the full-cell average when the cell
  /// snapshot is fresh and only falls back to this between refreshes.
  double? _subPollPackV;
  DateTime? _subPollPackVAt;

  /// v0.1.29+33: fast-cadence pack current (amps), read from 790/0009 in
  /// the SAME sub-poll as pack voltage (790/0015) so V and I are sampled
  /// ~one read apart — close enough to treat as simultaneous for an
  /// instantaneous P = V × I. Updated at the fast-lane cadence (~2 Hz),
  /// same as voltage and speed.
  ///
  /// Sign convention (confirmed C31/C32, runs 3+4): offset-encoded, the
  /// raw value is ALWAYS positive and sits around a zero-point; values
  /// above zero = discharge (current OUT of pack), below = charge/regen
  /// (current INTO pack). We store amps with discharge POSITIVE.
  ///
  /// CALIBRATION — PROVISIONAL. Cross-validated across 4 ECUs on AC
  /// charging (C31: ~7-9 A all agreeing) and bidirectional on drive
  /// (C32: regen<charge<cruise<accel ordering, 790/0009↔791/0039
  /// r≈0.83). But the exact zero-point and amps-per-LSB are bracketed,
  /// not pinned — they need one DC-charge anchor point (known station
  /// current) to fix precisely. Until then we DO NOT surface a hard
  /// ampere figure in the UI; we use this only for power (V×I, where a
  /// scale error is a proportional, not catastrophic, bias) and for
  /// flow DIRECTION (sign is exact regardless of scale). See
  /// _kPackCurrentZeroRaw / _kPackCurrentAmpsPerLsb.
  double? _packCurrentA;
  DateTime? _packCurrentAt;

  // ── v0.1.29+51: pack-current polling observability (read-only) ──
  //
  // The owner reports that on a real BZ5 the Power/Regen card on the
  // dashboard can flicker to '—' for stretches under heavy throttle —
  // sometimes a minute. v0.1.29+50 covers the visible part with hold-
  // last-value. These counters cover the *diagnostic* part: they let
  // us see, after a drive, what the polling layer actually did.
  //
  // None of them change behaviour. No new timers, no extra reads, no
  // touching the 2-second stale-gate on the getter below. They are
  // pure observers, updated at the only two points that already exist:
  //   ingest:  successful raw decode in _runFastSubPoll (the moment a
  //            fresh 790/0009 value lands in _packCurrentA);
  //   getter:  packCurrentA accessor — counts how many calls UI made
  //            and how many of them returned null (either because no
  //            value is cached or because the stale-gate rejected it).
  //
  // The "max gap" in particular is the number that diagnoses the
  // owner's "—-for-a-minute" report: if it climbs past 10000 ms the
  // 2-second stale-gate is the proximate cause; if it stays small
  // but the getter null-rate is high then it's something else
  // (initialisation, race, UI-side bug).
  //
  // Reset boundary: counters accumulate since process start. The UI
  // exposes a manual reset button in PollingDiagnosticsScreen so the
  // owner can frame a particular drive.
  int _packCurrentReadOkCount = 0;
  DateTime? _packCurrentPrevSuccessAt;
  int _packCurrentMaxGapMs = 0;
  int _packCurrentGetterCalls = 0;
  int _packCurrentGetterNulls = 0;

  /// Total successful raw reads of 790/0009 since process start (or
  /// last manual reset via [resetPackCurrentObservers]).
  int get packCurrentReadOkCount => _packCurrentReadOkCount;

  /// Largest observed gap, in milliseconds, between two consecutive
  /// successful raw reads. Tracks the worst spike — useful for
  /// diagnosing whether the field complaint of "'—' for a minute"
  /// is the 2 s stale-gate rejecting late samples or something else.
  int get packCurrentMaxGapMs => _packCurrentMaxGapMs;

  /// Milliseconds since the most recent successful raw read, or null
  /// if no read has happened this session. Computed live on access.
  int? get packCurrentCurrentGapMs {
    final t = _packCurrentAt;
    if (t == null) return null;
    return DateTime.now().difference(t).inMilliseconds;
  }

  /// Number of times [packCurrentA] has been called this session.
  int get packCurrentGetterCalls => _packCurrentGetterCalls;

  /// Number of those calls that returned null (no cached value, or
  /// stale-gate rejected). The ratio nulls/calls is the user-
  /// observable "how often was Power '—'" rate.
  int get packCurrentGetterNulls => _packCurrentGetterNulls;

  /// Zero out the four counters. Does NOT clear the cached value —
  /// just the statistics. Called from the diagnostics screen so
  /// the owner can scope numbers to a single drive.
  void resetPackCurrentObservers() {
    _packCurrentReadOkCount = 0;
    _packCurrentPrevSuccessAt = null;
    _packCurrentMaxGapMs = 0;
    _packCurrentGetterCalls = 0;
    _packCurrentGetterNulls = 0;
    notifyListeners();
  }

  /// v0.1.29+33: decode constants for 790/0009 pack current.
  /// raw is u16 big-endian. amps = (raw - zero) * ampsPerLsb, discharge
  /// positive, charge (current INTO pack) negative.
  ///
  /// v0.1.29+39: ZERO was refined from 4800 → 5024 from a parked-car
  /// stat-fit. See git history for the standstill-phantom explanation.
  ///
  /// v0.1.29+47: BOTH constants now calibrated from a real DC fast-charge
  /// session — research repo C33 (cycles/033-dc-charge-calibration).
  /// LiveLog with 790/0009 + 790/0015 + 791/0038 during charge from
  /// 10.7% SOC; station current/voltage at three timestamps used as
  /// ground truth. Least-squares over 4 anchor points (incl. t0 = 0 A,
  /// independently confirmed by flat raw 5019 before current flowed):
  ///
  ///   t0 (no current)   raw 5019  →   +0.1 A  (vs station   0 A; Δ=+0.1)
  ///   t1 (-181 A / 86 kW) raw 3213 → -184.3 A  (vs station -181;  Δ=-3.3)
  ///   t2 (-186 A / 90 kW) raw 3205 → -185.1 A  (vs station -186;  Δ=+0.9)
  ///   t3 (-198 A / 96 kW) raw 3101 → -195.8 A  (vs station -198;  Δ=+2.2)
  ///
  /// Residuals ≤ 3.3 A across 0–198 A. The new 0.1021 A/LSB is 2.04×
  /// the prior provisional 0.05 — exactly matching the field
  /// observation "90 km/h shows 8-9 kW vs real ~15 kW".
  ///
  /// Cross-check against C32 drive-raw archive: full-throttle raw
  /// 0x26E1 = 9953 → (9953-5018) × 0.1021 ≈ 503 A → ≈ 200 kW at the
  /// measured ~400 V bus. Physically sane for BZ5 peak; cruise and
  /// regen raws straddle the zero coherently with the C32 sign rule
  /// (discharge raw > zero, regen/charge raw < zero).
  ///
  /// 791/0038 is NOT a charge cross-check — it's VCU/motor power and
  /// the motor is idle during DC charge (raw sat constant at 806 the
  /// whole session). It's fine on drive; on charge the only meaningful
  /// cross-check is the station readout.
  static const double _kPackCurrentZeroRaw = 5018.0;
  static const double _kPackCurrentAmpsPerLsb = 0.1021;

  /// v0.1.29+30: speed sub-poll diagnostics. The owner observed a trip
  /// with zero 740/0008 speed samples ("No speed data for this trip")
  /// while BMS signals (SOC, temp) recorded normally — pointing at the
  /// PDU (740) read path, not a global polling stall. These counters
  /// classify WHY a _pollSpeedOnly invocation didn't produce a stored
  /// sample, so a screenshot of the diagnostic panel pinpoints the
  /// cause instead of guessing. Reset at each BLE-session start.
  ///   - _spdOk:          read succeeded AND a sample was stored
  ///   - _spdOkNoTrip:    read succeeded but _currentTripId == null
  ///                      (value updated for UI, but NOT persisted —
  ///                      this is the prime suspect for empty history)
  ///   - _spdNullPayload: ECU returned null/short (timeout / EMPTY /
  ///                      negative response)
  ///   - _spdSanity:      raw > 3000 (decode produced impossible speed)
  ///   - _spdException:   readDid threw (timeout or BLE error)
  int _spdOk = 0;
  int _spdOkNoTrip = 0;
  int _spdNullPayload = 0;
  int _spdSanity = 0;
  int _spdException = 0;

  /// v0.1.29+30: expose speed sub-poll diagnostics for the on-screen
  /// _LayoutDiagnostic panel. Format: "ok/noTrip/null/sanity/exc".
  String get speedSubPollDiag =>
      '$_spdOk/$_spdOkNoTrip/$_spdNullPayload/$_spdSanity/$_spdException';

  // v0.1.21 NOTE: precise SOC (790/0x1FFD) and vehicle speed (740/0x0008)
  // do NOT need separate private fields — they flow through the normal
  // registry polling path into _latestValues and are read by the
  // [socPrecisePct] / [vehicleSpeedKmh] getters (see definitions below).

  // v0.1.20: counter for cell min/max sanity-guard drops. Each driving
  // session typically sees ~3.6% of frames with max<min or spread>100mV
  // due to ELM stream misalignment that v0.1.16 frame-alignment doesn't
  // catch. UI may expose this in Diagnostics for transparency.
  int _cellPairDropCount = 0;
  int get cellPairDropCount => _cellPairDropCount;

  // v0.1.24: user preference — show speed scaled by 1.05 to match the
  // car's analog/digital speedometer (which by UN R39 reads ~5% higher
  // than true wheel speed). Loaded from SharedPreferences asynchronously
  // at startup and refreshed when user toggles in Settings.
  //
  // The multiplier is applied at the getter [displaySpeedKmh], which the
  // Driver view uses. The raw [vehicleSpeedKmh] remains the true value
  // (used for trip aggregates, livelog, and any future computation).
  bool _matchSpeedometer = false;
  bool get matchSpeedometer => _matchSpeedometer;

  /// v0.1.24: re-read the speedometer-match preference from disk and
  /// notify listeners so the Driver view redraws with new multiplier.
  /// Called by Settings page when the toggle is flipped.
  Future<void> refreshSpeedometerPref() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool('match_speedometer') ?? false;
    if (v != _matchSpeedometer) {
      _matchSpeedometer = v;
      notifyListeners();
    }
  }

  /// v0.1.24: speed value to **display** on the Driver view. Either the
  /// true wheel speed from [vehicleSpeedKmh] or that value × 1.05 if the
  /// user enabled the speedometer-match toggle in Settings.
  ///
  /// IMPORTANT: do not use this for trip aggregates, livelog, or any
  /// computation — only for human display. Trip metrics should always
  /// use the unscaled [vehicleSpeedKmh] so the data layer stays honest.
  double? get displaySpeedKmh {
    final v = vehicleSpeedKmh;
    if (v == null) return null;
    return _matchSpeedometer ? v * 1.05 : v;
  }

  ConnectionService(this.db) {
    // v0.1.16: fire auto-connect attempt asynchronously so the constructor
    // returns immediately (Provider construction stays synchronous).
    // tryAutoConnect is a no-op if the user hasn't opted in via Settings
    // or if no last_adapter is saved.
    //
    // Slight delay lets the splash/main widget tree settle before BLE scan
    // starts, otherwise the status banner flickers between connecting and
    // an unrelated initial state.
    Future.delayed(const Duration(milliseconds: 800), () {
      tryAutoConnect();
    });
    // v0.1.24: load speedometer-match preference at startup so the
    // Driver view shows the user's preferred mode immediately on first
    // poll cycle (not just after they open Settings).
    refreshSpeedometerPref();
  }

  ConnectionStatus get status => _status;
  String? get statusMessage => _statusMessage;
  String? get adapterAddress => _adapterAddress;
  int? get currentTripId => _currentTripId;
  bool get isPolling => _polling;

  /// True iff a UDS-capable BLE client is currently live. Added v0.1.29+17
  /// for BridgeDiagService Turn B to pre-check before dispatching BLE
  /// commands — `adapterAddress` is set on first pairing and never cleared,
  /// so it can't be used as a "connected right now" signal.
  bool get isBleConnected => _client != null;

  PollMode get pollMode => _pollMode;
  Map<String, Map<String, DecodedValue>> get latestValues => _latestValues;
  List<int> get liveCells => _liveCells;

  /// Instantaneous charging power in kW, computed from SOC rate of change.
  ///
  /// v0.1.26+11: rewrote from broken 0x0B00 counter-rate approach to SOC-
  /// derived (linear, but slower refresh — SOC has finite granularity).
  ///
  /// v0.1.26+17: quantization-aware rework. Empirical 5-min test on AC
  /// 2.4 kW (station readout) on 2026-05-21 showed our app reported
  /// 4.4 kW vs the car's own dash 2.4 kW. Root cause: precise SOC from
  /// 790/0x1FFD turns out to quantize at roughly 0.1% steps on this
  /// firmware — not 0.01% as the BYD framework docs implied. With a
  /// 60-second integration window at 2.4 kW input we accumulate only
  /// ~0.06% of true SOC delta, but the observable delta is whatever
  /// quantum boundary the SOC tick happens to cross — usually 0 or
  /// 0.1%. When it lands on 0.1%, the formula
  ///     P = 0.1% × 65.28 kWh × 36 / 60 s = 3.92 kW
  /// — close to the 4.4 kW the user reported (rounding to nearest tick
  /// happens at slightly different phase across samples).
  ///
  /// Fix: require ≥3 observed SOC quanta of growth in the window before
  /// reporting a power figure. With 0.1% quantization that means waiting
  /// for ≥0.3% accumulated growth. At 2.4 kW that's ~7.5 min of charge;
  /// at 7 kW AC that's ~2.5 min; at 50 kW DC ~22 sec; at 100 kW DC ~11
  /// sec. Window extended to 600 s (10 min) to give 3 quanta room even
  /// at the slowest AC rates.
  ///
  /// Until the threshold is reached the getter returns 0 — UI should
  /// treat 0 during isCharging==true as "calculating, please wait" and
  /// display a hint rather than a misleading 4.4 kW. This is honest
  /// behaviour for an integer-derived signal.
  ///
  /// Refresh characteristics under the new policy:
  ///   - AC 2 kW:   first reliable reading after ~9 min, then every ~3 min
  ///   - AC 3 kW:   first ~6 min, then every ~2 min
  ///   - AC 7 kW:   first ~2.5 min, then every ~50 sec
  ///   - DC 50 kW:  first ~22 sec, then every ~7 sec
  ///   - DC 100 kW: first ~11 sec, then every ~3.5 sec
  double get chargingPowerKw {
    if (!isCharging) return 0.0;
    if (_chargingHistory.length < 2) return 0.0;

    final latest = _chargingHistory.last;
    final latestSoc = latest.socPct;
    if (latestSoc == null) return 0.0;

    // Try the freshest window first, fall back to older if not enough
    // delta has accumulated. The "min quanta" threshold rejects results
    // dominated by SOC quantization noise — see the docstring for the
    // empirical justification (0.1% quanta observed on BZ5 firmware,
    // need ≥0.3% to get within ±20% of true power).
    const double minDeltaPct = 0.3;
    const List<int> windowSeconds = [600, 300, 120];

    for (final winSec in windowSeconds) {
      final cutoff = latest.time.subtract(Duration(seconds: winSec));
      ChargingSample? anchor;
      // Walk from oldest forward — we want the OLDEST sample within
      // the window that has a lower SOC than latest. That maximises
      // dtSec which dampens quantization noise.
      for (final s in _chargingHistory) {
        if (s.time.isBefore(cutoff)) continue;
        if (s.socPct == null) continue;
        if (s.socPct! >= latestSoc) continue;
        anchor = s;
        break;
      }
      if (anchor == null) continue;

      final dSocPct = latestSoc - anchor.socPct!;
      if (dSocPct < minDeltaPct) continue;

      final dtSec =
          latest.time.difference(anchor.time).inMilliseconds / 1000.0;
      if (dtSec < 1.0) continue;

      // P[kW] = ΔSOC% × packKwh × 36 / dt_sec
      return dSocPct * Bz5Model.batteryCapacityKwh * 36.0 / dtSec;
    }

    // No window had ≥0.3% accumulated growth — return 0 so the UI
    // shows "calculating" rather than a noisy mis-estimate.
    return 0.0;
  }

  /// Cycle count from BMS DID 0B02 — likely full-charge equivalent cycles
  int? get cycleCount {
    final v = readNumeric('790', '0B02');
    return v?.toInt();
  }

  /// Pack voltage NOMINAL (platform constant ~450V on BZ5).
  ///
  /// **v0.1.20 finding:** 740/0x0022 is NOT live pack voltage. It is a
  /// hard-coded platform constant near 450V. Evidence (2026-05-18):
  ///   - 5-trip day, SOC 64→55%, HV bus swung 393→413V under load,
  ///     cells dropped 35 mV at peak draw: this value stayed at 450.0 ± 0.3
  ///   - Two parking sweeps 2 hours apart with driving in between:
  ///     byte-identical reads (4650 → 4650)
  ///   - On BZ3 (different pack topology, ~280V actual): same DID returns
  ///     ~450V → confirms platform constant, not pack measurement
  ///
  /// For live pack voltage use [hvBusV] (790/0x0015 × 0.025) which has a
  /// 46V swing during driving and is the only genuinely live V source.
  ///
  /// This getter is kept for backward compatibility:
  ///   - snapshot DB column `packVoltageV` (historical data preservation)
  ///   - "Nominal" badge in wide-dashboard hero panel
  ///   - Future "Vehicle Profile" abstraction (Phase 2) will use this
  ///     value as the platform-class identifier
  ///
  /// Sanity range 350..550 V kept — filters out garbled reads only,
  /// not load variations (because the value doesn't vary with load).
  double? get packVoltageV {
    final v = _packVoltageFilteredV;
    if (v == null) return null;
    if (v < 350 || v > 550) return null;
    return v;
  }

  /// Instant pack voltage (740/0x0014). Может отличаться от filtered под
  /// нагрузкой/во время regen. Не показывается на главном экране — для
  /// будущей diag-карточки.
  double? get packVoltageInstantV {
    final v = _packVoltageInstantV;
    if (v == null) return null;
    if (v < 350 || v > 550) return null;
    return v;
  }

  /// v0.1.27+2: PACK VOLTAGE FROM CELLS — the most reliable live pack V
  /// source we have.
  ///
  /// Computed as average(20 polled cell voltages) × N series cells,
  /// where N is the BMS-reported pack cell count (790/0x0B03; falls back
  /// to 136 for BZ5 if BMS hasn't reported yet).
  ///
  /// `_liveCells` holds [M1.min, M1.max, M2.min, M2.max, ..., M10.min, M10.max]
  /// — 20 mV values polled every 2 cycles via [_pollCells]. We don't have
  /// per-cell readings for the full 136 cells, but with a balanced pack
  /// (typical spread 3-10 mV) the average × N estimate is within ±1V of
  /// the true sum of N cells.
  ///
  /// Why this is better than the alternatives:
  ///   * `packVoltageV` (740/0x0022) is a platform constant ~450V that
  ///     doesn't change with SOC or load — confirmed across multiple
  ///     vehicles and sweep comparisons. Useless for live display.
  ///   * `hvBusV` (790/0x0015) is HV bus downstream of main contactor.
  ///     Empirically goes haywire during DC fast charging (charging session
  ///     2026-05-22: hvBus showed −83V below sum-of-cells at 76 kW peak —
  ///     physically impossible, indicates the DID has dual semantics or
  ///     poll-race issues under load).
  ///   * In standby with the contactor open, hvBus reads residual cap V
  ///     from the DC-DC side, not pack potential — sum-of-cells stays
  ///     correct regardless of contactor state.
  ///   * Sum-of-cells = the literal definition of pack voltage. Cells
  ///     in series → terminal V = Σ cell V.
  ///
  /// Accuracy bound: ±(spread × N / 1000) volts in the worst case.
  /// At typical 6 mV spread on BZ5 (N=136) that's ±0.82V; at 50 mV spread
  /// (heavily unbalanced) ±6.8V. Always more accurate than the alternatives.
  ///
  /// Returns null when:
  ///   * _liveCells is empty (BMS hasn't been polled yet)
  ///   * computed value falls outside 200..500V LFP envelope
  ///
  /// This is the value the dashboard hero panel should display as
  /// "PACK V". `packVoltageV` and `hvBusV` are kept around for the
  /// snapshot DB column (historical preservation) and for diagnostic
  /// purposes, but not as the primary user-facing number.
  double? get packVoltageFromCells {
    // v0.1.29+30: prefer the full 20-value module average when we have
    // a cell snapshot; this is the most accurate number. But _liveCells
    // only refreshes every ~6 s (_pollCells runs on cycle%2), so between
    // refreshes we fall through to the fast min/max-cell sub-poll
    // estimate [_subPollPackV] (updated ~1 Hz by _pollCellExtremesOnly).
    // This keeps the dashboard pack-voltage number live under load
    // instead of frozen for 6 s at a time — the original 1 Hz request
    // from the owner that +26 addressed for the wrong signal (hvBusV).
    final fromFull = _packVoltageFromFullCells();
    if (fromFull != null) {
      // If the full-cell snapshot is fresh (< 3 s old via _pollCells)
      // it's authoritative. We can't cheaply timestamp _liveCells here,
      // so the heuristic is: when both exist, the full average wins
      // EXCEPT the sub-poll value is newer than ~1.5 s — meaning a
      // sub-poll has happened since the last full refresh and better
      // reflects the current instant. This biases toward freshness
      // under load while keeping full-average accuracy at rest.
      final subAt = _subPollPackVAt;
      if (_subPollPackV != null &&
          subAt != null &&
          DateTime.now().difference(subAt).inMilliseconds < 1500) {
        return _subPollPackV;
      }
      return fromFull;
    }
    // No full-cell snapshot yet — use sub-poll estimate if present.
    return _subPollPackV;
  }

  /// Full 20-value module-average pack voltage. Extracted from the old
  /// [packVoltageFromCells] body so the getter can choose between this
  /// and the fast sub-poll estimate. Returns null if no cell snapshot.
  double? _packVoltageFromFullCells() {
    if (_liveCells.isEmpty) return null;
    // Defensive: filter out clearly-broken readings before averaging.
    // LFP single-cell physical envelope ≈ 2000-3700 mV; anything outside
    // this is a comm-glitch or sanity-fail that slipped through.
    final valid = _liveCells.where((v) => v >= 2000 && v <= 3700).toList();
    if (valid.isEmpty) return null;
    final avgMv = valid.reduce((a, b) => a + b) / valid.length;
    // Use BMS-reported series cell count; fall back to BZ5 default 136
    // if not yet polled. BZ3 (different pack topology) will read a
    // different value here automatically — no code change required.
    final seriesCells = _packCellCount ?? 136;
    final packV = avgMv * seriesCells / 1000.0;
    if (packV < 200 || packV > 500) return null;
    return packV;
  }

  /// HV bus voltage (downstream of main contactor).
  ///
  /// Source: 790/0x0015 × 0.025 V (read via registry — scale already
  /// applied by the decoder, see ecu_registry.dart for the DidSpec).
  ///
  /// v0.1.8 finding: scale was reverse-engineered as 0.025 (NOT 0.02 as
  /// originally assumed). Verification 2026-05-15 in Ready state at 77% SOC:
  ///   0x0015 = 0x42FE (17150) × 0.025 = 428.75 V
  /// Pack voltage at this SOC (from 740/0x0022) was ~448 V — difference of
  /// ~20 V matches the expected drop across main contactor + HV filter
  /// circuit, confirming this is HV bus measured DOWNSTREAM of contactors,
  /// not raw pack voltage.
  ///
  /// State-dependent behavior:
  ///   - Ignition OFF: residual capacitor charge slowly bleeding (~280-350V).
  ///   - Ignition ON, not Ready: precharge resistor active, bus ~95% of pack.
  ///   - Ready: main contactor closed, bus ≈ pack V − ~20V.
  ///   - Driving: drops under acceleration, rises during regen.
  ///
  /// Useful as a diagnostic indicator (precharge sequence, regen events)
  /// but NOT a substitute for pack V (use [packVoltageV] for that).
  double? get hvBusV {
    final v = readNumeric('790', '0015');
    if (v == null) return null;
    // Sanity: HV bus normally 200..500 V (lower at standby, max at full pack).
    if (v < 100 || v > 550) return null;
    return v;
  }

  /// @deprecated v0.1.8 — kept for backward compat. Use [hvBusV] instead.
  /// In v0.1.8 scale in the registry was corrected from 0.02 to 0.025, so
  /// this getter now returns the same value as [hvBusV]. Kept around in case
  /// any external code references it; new code should use [hvBusV] for the
  /// clearer name.
  @Deprecated('Use hvBusV — same value, clearer name')
  double? get secondaryBusV => hvBusV;

  /// v0.1.21: SOC with 0.01% resolution from 790/0x1FFD high16 / 100.
  ///
  /// Discovered 2026-05-19 by comparing 1FFD high16 to actual snapshot
  /// SOC across four time points (sweep_11 19:43=55.50% with snapshot
  /// SOC=56%; session 13 start 10:05=55.40% with snapshot SOC=55%;
  /// session 13 end 10:13=53.90% with snapshot SOC=54%; sweep_16 10:30
  /// =49.40% with snapshot SOC=49%). All four within ±0.5% rounding,
  /// confirming the layout. The integer SOC at 790/0x0005 is just this
  /// value rounded.
  ///
  /// Returns null if 1FFD hasn't been polled yet — UI should fall back
  /// to integer SOC via legacy readers in that case. Range-guarded to
  /// 0..100 to drop frame-misalignment artifacts.
  ///
  /// The value is decoded by the registry's [decodeDid] function which
  /// recognizes `category: DidCategory.soc && did == '1FFD'` and applies
  /// the `high16 / 100` rule rather than the default `raw * scale`.
  /// We just look up the already-decoded value in [_latestValues].
  double? get socPrecisePct {
    final v = _latestValues['790']?['1FFD']?.numeric;
    if (v == null) return null;
    if (v < 0 || v > 100) return null;
    return v;
  }

  /// v0.1.21: vehicle speed in km/h from 740/0x0008.
  /// Verified 2026-05-19 at cruise control 90 km/h: raw=1268 → 90.0 km/h.
  /// Returns 0.0 at standstill (raw=0 yields 0.0 km/h, not null).
  ///
  /// Scale comes from the registry (0.07097 ≈ 1/14.09). Range-guarded
  /// to 0..220 km/h to drop frame-misalignment artifacts (e.g. 0xFFFF
  /// would otherwise yield 4651 km/h).
  double? get vehicleSpeedKmh {
    final v = _latestValues['740']?['0008']?.numeric;
    if (v == null) return null;
    if (v < 0 || v > 220) return null;
    return v;
  }

  // NOTE: trip speed getters (tripPeakSpeedKmh, etc.) live further down
  // in this file in the trip-aggregates block. Moving/idle accumulators
  // are in the _updateTripAggregates() function. Trip avg moving speed is
  // computed at trip-end time from _tripSpeedSum / _tripSpeedSamples.

  /// v0.1.3: индекс ячейки с минимальным напряжением в пакете (0..135).
  /// Меняется в реальном времени по мере того как BMS пересортировывает
  /// слабую ячейку. Замеры 2026-05-03: 21:17 идекс=34, 23:58 индекс=30.
  int? get globalMinCellIndex => _globalMinCellIndex;

  /// v0.1.3: индекс ячейки с максимальным напряжением в пакете (0..135).
  int? get globalMaxCellIndex => _globalMaxCellIndex;

  /// v0.1.6: глобальный минимум напряжения по всем ~136 ячейкам, в mV.
  /// Источник 790/0x0x002B (2 байта big-endian). До v0.1.6 этот DID был в
  /// реестре с category=cells, но фильтр в _pollEcu его отбрасывал, а
  /// _pollCells работал только с per-module массивом 0x016D-0x01B7. Теперь
  /// читаем напрямую через _pollExtraDids — Pack Extremes UI наконец
  /// отображает данные вместо вечного loading.
  int? get globalMinCellMv => _globalMinCellMv;

  /// v0.1.6: глобальный максимум напряжения по всем ~136 ячейкам, в mV.
  /// Источник 790/0x002D.
  int? get globalMaxCellMv => _globalMaxCellMv;

  /// v0.1.3: общее количество ячеек в пакете (BMS reports 136).
  /// Читается один раз при подключении из 790/0x0B03.
  int? get packCellCount => _packCellCount;

  /// v0.1.3: количество модулей в пакете (BMS reports 10).
  /// Читается один раз при подключении из 790/0x0A07.
  int? get packModuleCount => _packModuleCount;

  /// Parking pawl engaged.
  ///
  /// v5: Direct DID 0x0007 на VCU.
  /// v0.1.6 fix: добавлен override "gear=P → engaged".
  ///
  /// Исходный DID 0x0007 имеет странное поведение: после перехода P→R он
  /// корректно выдаёт 0 (released), но при возврате R→P НЕ возвращается
  /// в 1 (engaged) до какого-то VCU-внутреннего события (вероятно
  /// требуется нажатие тормоза при повторном включении P, или порог
  /// скорости 0). Это создаёт ложную картину "pawl released" на стоянке.
  ///
  /// Compromise: если gear=1 (P, считывается из VCU/0x0009), то парковочная
  /// собачка ФИЗИЧЕСКИ зацеплена — это механика трансмиссии. Возвращаем
  /// engaged=true для gear=P независимо от 0x0007.
  /// Для gear≠P (R/N/D) полагаемся на 0x0007 как обычно — там значение
  /// корректно отражает реальность (released).
  bool? get parkingPawlEngaged {
    // Override: gear=P always means pawl engaged (transmission mechanics)
    final gear = readNumeric('791', '0009');
    if (gear != null && gear.toInt() == 1) {
      return true;
    }
    // Fallback to direct DID for non-P gears
    final raw = readNumeric('791', '0007');
    if (raw == null) return null;
    return raw.toInt() == 1;
  }

  /// v0.1.23 / v0.1.24: smoothed consumption (kWh/100km), **rolling
  /// median** over 5-minute window for Range estimation. Updated by
  /// _updateTripAggregates() each poll cycle.
  ///
  /// Returns null if fewer than 20 samples in the window — protects
  /// against early-trip noise dominating the displayed Range.
  ///
  /// v0.1.24: switched from arithmetic mean to median because user
  /// observed Range jumping visibly on minor accel/decel events. Median
  /// is robust to outliers — a brief 35 kWh/100km accel spike doesn't
  /// shift the central tendency. Mean was sensitive to any outlier.
  double? get smoothedConsumptionKwh100km {
    if (_consumptionWindow.length < _consumptionWindowMinSamples) return null;
    final vals = _consumptionWindow.map((e) => e.$2).toList()..sort();
    final n = vals.length;
    if (n.isEven) return (vals[n ~/ 2 - 1] + vals[n ~/ 2]) / 2.0;
    return vals[n ~/ 2];
  }

  /// Range estimation in km.
  ///
  /// v0.1.23: prefer trip-specific smoothed consumption when active trip
  /// is older than 5 minutes (gives enough samples for stable EMA). For
  /// short trips or no-trip idle, falls back to Bz5Model constant
  /// (14.4 kWh/100km nominal). This means after a stretch of highway
  /// efficient driving Range will read higher; after hill climbs lower.
  double? get rangeEstimateKm {
    final soc = readNumeric('790', '0005');
    if (soc == null) return null;
    final remainingKwh = Bz5Model.batteryCapacityKwh * soc / 100.0;

    // Trip-specific consumption: only after enough samples accumulated
    // (smoothedConsumptionKwh100km returns null otherwise). Also enforce
    // trip duration ≥ 5 min: shorter trips have noisy distance/energy
    // ratios that the EMA window can't fully smooth out.
    final tripAgeSec = _tripStartedAt != null
        ? DateTime.now().difference(_tripStartedAt!).inSeconds
        : 0;
    final smoothed = smoothedConsumptionKwh100km;
    if (smoothed != null && smoothed > 5 && smoothed < 50 && tripAgeSec > 300) {
      // smoothed is in kWh/100km → convert to range km
      return remainingKwh / smoothed * 100.0;
    }

    // Fallback: nominal constant (Bz5Model.avgConsumptionWhKm = 144 Wh/km)
    return remainingKwh * 1000 / Bz5Model.avgConsumptionWhKm;
  }

  /// v0.1.29+33: live pack current in amps, discharge POSITIVE, charge/
  /// regen NEGATIVE. Sourced from the fast-lane 790/0009 sub-poll
  /// ([_pollPackVoltageOnly] reads it right after voltage). Null until
  /// the first successful read, or if the last read is stale (>2 s).
  ///
  /// NOTE — PROVISIONAL magnitude. The sign is exact; the absolute amps
  /// depend on [_kPackCurrentZeroRaw]/[_kPackCurrentAmpsPerLsb] which are
  /// physics-bracketed, not anchor-calibrated. The UI deliberately does
  /// NOT show a hard ampere number from this yet (see dashboard). Use it
  /// for [instantPowerKw] and [powerFlowDirection], not for a precise
  /// "X amps" readout.
  double? get packCurrentA {
    // v0.1.29+51: track every getter call + every null outcome for
    // diagnostics. No behaviour change — same return values as before.
    _packCurrentGetterCalls++;
    final t = _packCurrentAt;
    if (_packCurrentA == null || t == null) {
      _packCurrentGetterNulls++;
      return null;
    }
    // v0.1.29+53: stale-gate widened 2 s → 8 s. Field data (+51
    // counters on a 40 min drive): null rate 40.7% at 2 s, fast-group
    // wall-clock period after +53 is ~700 ms per task. 8 s window
    // comfortably covers one full fast-cycle plus a transient stall.
    // +50 UI hold-window is also 8 s, so when the cached value is
    // dropped here, the UI _PowerCard hold-window has just expired
    // too — they fail in sync (no double-grace, no silent drift).
    if (DateTime.now().difference(t).inMilliseconds > 8000) {
      _packCurrentGetterNulls++;
      return null;
    }
    return _packCurrentA;
  }

  /// v0.1.29+33: instantaneous pack power in kW, computed P = V × I from
  /// the fast-lane voltage and current (sampled ~one read apart, so
  /// effectively simultaneous). Discharge POSITIVE (energy leaving the
  /// pack), regen/charge NEGATIVE.
  ///
  /// Voltage source priority mirrors the dashboard's own pack-voltage
  /// number: [packVoltageFromCells] (the user-facing live V). Returns
  /// null if either input is missing/stale.
  ///
  /// Magnitude inherits the PROVISIONAL current scale, so treat it as a
  /// good-but-not-yet-anchor-calibrated figure. The error is
  /// proportional (a scale factor), so trends, sign, and relative
  /// comparisons are trustworthy even pre-calibration.
  double? get instantPowerKw {
    final i = packCurrentA;
    final v = packVoltageFromCells;
    if (i == null || v == null) return null;
    return v * i / 1000.0;
  }

  /// v0.1.29+33: flow direction as a small enum-like int for the UI.
  ///   1  = discharging (power leaving pack — accel/cruise)
  ///  -1  = charging/regen (power into pack — regen brake or plugged in)
  ///   0  = near zero (within a small deadband)
  /// Null if current is unavailable. The sign is EXACT regardless of the
  /// provisional scale, so this is the safest current-derived signal to
  /// surface.
  int? get powerFlowDirection {
    final i = packCurrentA;
    if (i == null) return null;
    // Deadband ~1 kW-equivalent: with provisional scale ~0.05 A/LSB and
    // a ~2 A floor of decode noise, treat |I| < 3 A as "near zero".
    if (i > 3.0) return 1;
    if (i < -3.0) return -1;
    return 0;
  }

  /// v0.1.29+33: instantaneous consumption in Wh/km, the driver-facing
  /// "how hard am I drawing right now" number. = instantaneous power (W)
  /// / speed (km/h). Negative when regenerating (energy returning).
  ///
  /// Only meaningful while moving; returns null below ~3 km/h (the
  /// number blows up toward infinity as speed → 0, which is not useful
  /// on the dashboard — at a standstill there's no "per km" to speak of).
  /// Inherits the provisional power scale (proportional bias).
  double? get instantConsumptionWhKm {
    final p = instantPowerKw;
    final spd = vehicleSpeedKmh;
    if (p == null || spd == null) return null;
    if (spd < 3.0) return null;
    // P[kW] * 1000 = W; W / (km/h) = Wh/km.
    return p * 1000.0 / spd;
  }

  /// v0.1.26+11: trip-side energy delivered (positive = charged, negative = consumed).
  ///
  /// Previously this was computed from delta of 0x0B00 counter × 460 Wh/unit.
  /// That formula was wrong by 1-2 orders of magnitude (counter is a
  /// nonlinear OBC event signal, not energy — see [Bz5Model.chargeCounterWh]).
  ///
  /// Now uses ΔSOC × pack capacity, which is the same path used by the
  /// trip-detail "energy_from_soc" display and matches station meters
  /// within ~1% on AC charging tests.
  ///
  /// Returns null when no anchor (no trip yet), or SOC delta is non-positive.
  double? get chargedThisSessionKwh {
    if (_tripStartSocPrecise == null) return null;
    final cur = socPrecisePct ?? readNumeric('790', '0005');
    if (cur == null) return null;
    final deltaPct = cur - _tripStartSocPrecise!;
    if (deltaPct <= 0) return null;
    return deltaPct * Bz5Model.batteryCapacityKwh / 100.0;
  }

  /// v0.1.26+11: trip-side energy used (or gained) in kWh, signed.
  ///
  /// Positive value means charged, negative means consumed. Allows the
  /// trip card to show energy gain during charging session and energy
  /// loss during driving with the same field.
  double? get tripEnergyKwh {
    if (_tripStartSocPrecise == null) return null;
    final cur = socPrecisePct ?? readNumeric('790', '0005');
    if (cur == null) return null;
    final deltaPct = cur - _tripStartSocPrecise!;
    return deltaPct * Bz5Model.batteryCapacityKwh / 100.0;
  }

  int? get smoothedCellSpread {
    if (_cellSpreadHistory.isEmpty) return null;
    final sorted = List<int>.from(_cellSpreadHistory)..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// v0.1.2 (interpretation revised in v0.1.3): per-module data.
  /// Returns 10 entries (one per module). Each entry contains:
  ///   - cellA (= module MIN cell V), cellB (= module MAX cell V) in mV.
  ///     По данным реверса 2026-05-03 это НЕ две конкретные ячейки, а min
  ///     и max ячейки модуля из всех ~14 ячеек этого модуля. Используйте
  ///     cellMinmV/cellMaxmV для семантически верного доступа.
  ///   - temp1, temp2: °C (или null если BMS reports 0xFF — см. M6,
  ///     у которого нет температурных сенсоров by-design)
  ///   - temp1Reported, temp2Reported: false если BMS skipped this slot
  /// UI uses *Reported flags to display "no sensors" instead of "Invalid".
  ///
  /// v6.1 fix: cellA/cellB читаются из _liveCells (плоский список 20 значений
  /// cell voltages, заполняется в _pollCells). До v6.1 читались через
  /// readNumeric из _latestValues, где cells DID-ы никогда не появляются —
  /// из-за этого VOLT mV колонка всегда показывала прочерки.
  List<ModuleSnapshot> get moduleSnapshots {
    const baseCa = 0x016D;
    final result = <ModuleSnapshot>[];
    for (int i = 0; i < 10; i++) {
      final offset = i * 8;
      final didTemp1 = (baseCa + 4 + offset).toRadixString(16).toUpperCase().padLeft(4, '0');
      final didTemp2 = (baseCa + 6 + offset).toRadixString(16).toUpperCase().padLeft(4, '0');

      // Cell voltages: _liveCells = [M1.A, M1.B, M2.A, M2.B, ..., M10.A, M10.B]
      final cellAIdx = i * 2;
      final cellBIdx = i * 2 + 1;
      final cellA = (_liveCells.length > cellAIdx) ? _liveCells[cellAIdx] : null;
      final cellB = (_liveCells.length > cellBIdx) ? _liveCells[cellBIdx] : null;

      final t1Decoded = _latestValues['790']?[didTemp1];
      final t2Decoded = _latestValues['790']?[didTemp2];
      // Если decoder вернул DecodedValue без numeric (т.е. raw был 0xFF) —
      // это "not reported", BMS не пишет в этот слот.
      final t1Reported = t1Decoded != null && t1Decoded.numeric != null;
      final t2Reported = t2Decoded != null && t2Decoded.numeric != null;

      result.add(ModuleSnapshot(
        index: i + 1,
        cellAmV: cellA,
        cellBmV: cellB,
        temp1C: t1Reported ? t1Decoded.numeric : null,
        temp2C: t2Reported ? t2Decoded.numeric : null,
        temp1Reported: t1Reported,
        temp2Reported: t2Reported,
      ));
    }
    return result;
  }

  void setPollMode(PollMode m) {
    _pollMode = m;
    notifyListeners();
  }

  void _setStatus(ConnectionStatus s, {String? msg}) {
    _status = s;
    _statusMessage = msg;
    notifyListeners();
  }

  Future<List<ScanResult>> scanForAdapters() async {
    _setStatus(ConnectionStatus.scanning, msg: 'Поиск BLE...');
    try {
      final results = await Elm327Ble.scan();
      final filtered = results.where((r) {
        final name = r.advertisementData.advName.toLowerCase();
        final hasService = r.advertisementData.serviceUuids.any(
          (u) => Elm327Ble.knownServiceUuids.contains(u),
        );
        return hasService ||
            name.contains('vlink') ||
            name.contains('obd') ||
            name.contains('vgate') ||
            name.contains('icar') ||
            name.contains('elm');
      }).toList();
      _setStatus(ConnectionStatus.disconnected, msg: 'Найдено ${filtered.length}');
      return filtered.isNotEmpty ? filtered : results;
    } catch (e) {
      _setStatus(ConnectionStatus.error, msg: '$e');
      return [];
    }
  }

  Future<bool> connect(BluetoothDevice device, {bool autoStart = true}) async {
    _setStatus(ConnectionStatus.connecting, msg: 'Подключение...');
    Object? lastError;

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        _ble = Elm327Ble(device);
        // v0.1.16: hook BLE disconnect → status update.
        // Without this, the UI lies about being "connected" forever after
        // the adapter goes out of range or the car is powered off.
        _ble!.onDisconnected = _handleBleDisconnect;
        await _ble!.connect();
        _client = Elm327Client(_ble!);
        await _client!.initialize();
        _adapterAddress = device.remoteId.str;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_adapter', _adapterAddress!);
        _setStatus(ConnectionStatus.connected, msg: 'Подключено');
        if (autoStart) {
          Future.microtask(() => startPolling());
        }
        return true;
      } catch (e) {
        lastError = e;
        debugPrint('Connect attempt $attempt/3 failed: $e');

        try { await _ble?.disconnect(); } catch (_) {}
        _client = null;
        _ble = null;

        if (attempt < 3) {
          final delayMs = 500 * attempt;
          _setStatus(ConnectionStatus.connecting,
              msg: 'Повтор ${attempt + 1}/3 через ${delayMs}мс...');
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
    }

    _setStatus(ConnectionStatus.error,
        msg: 'Не удалось подключиться (3 попытки): $lastError');
    return false;
  }

  Future<void> disconnect() async {
    await stopPolling();
    try { await _ble?.disconnect(); } catch (_) {}
    _client = null;
    _ble = null;
    _setStatus(ConnectionStatus.disconnected, msg: 'Отключено');
  }

  /// v0.1.16: invoked by Elm327Ble.onDisconnected when the physical BLE
  /// link drops unexpectedly (out of range, car off, etc). Cleans up the
  /// stale client/ble references and updates public status so the UI no
  /// longer claims to be "connected".
  ///
  /// Manual user-initiated disconnect() doesn't go through this path —
  /// Elm327Ble.onDisconnected is guarded by wasConnected to avoid
  /// double-firing.
  void _handleBleDisconnect() {
    // stopPolling internally — but DON'T await, this fires from a stream
    // listener. Cancel polling flag, let loop exit naturally.
    _polling = false;

    // v0.1.21.1: close any active trip BEFORE clearing client/ble refs.
    //
    // Previously this method only stopped the poll flag and dropped
    // references, leaving the active trip in DB with endedAt=null and
    // all summary fields null. On next connection startPolling() reset
    // trip state and created a NEW trip — the old one was orphaned as
    // "perpetually active" in history, with all metrics showing "—".
    //
    // Now we finalize the trip with whatever rolling state we have. The
    // user lost some samples after the disconnect (BLE was already
    // dead), but at least startSoc / endSoc / distance / energyUsed are
    // computed from the last known good readings instead of being null.
    //
    // Fire-and-forget — _handleBleDisconnect is called from a stream
    // listener and can't be made async. The DB write completes on the
    // event loop. Any failure here is logged via debugPrint, never
    // propagated, because the BLE event must still update UI status.
    if (_currentTripId != null) {
      _finalizeTripFromLastKnown().catchError((e) {
        debugPrint('Trip finalize on BLE drop failed: $e');
      });
    }

    _client = null;
    _ble = null;
    _setStatus(ConnectionStatus.disconnected,
        msg: 'BLE отключился (вне зоны / адаптер выключен)');
  }

  /// v0.1.21.1: close the active trip using the last-known cached values
  /// from _latestValues (no fresh reads — BLE is already down).
  ///
  /// Same field math as the normal stopPolling() trip-end block, just
  /// reads from cache rather than trying live reads. Used by:
  ///   - _handleBleDisconnect (unexpected drop)
  ///   - any future "kill" path that loses BLE before stopPolling fires
  ///
  /// Safe to call even if no trip is active (no-op then).
  Future<void> _finalizeTripFromLastKnown() async {
    if (_currentTripId == null) return;
    final tripId = _currentTripId!;

    // v0.1.29+38: end values come from the _latestValues cache, but
    // 791/0026 (odometer) and sometimes 790/0005 (SOC) are missing from
    // it at trip end (791 times out once moving). Fall back to the last
    // numeric sample recorded in the DB for that DID, which is present
    // even when the cache is stale — otherwise end_odo/end_soc land NULL
    // and distance/energy never compute (observed trips #1/#13).
    var endSoc = _latestValues['790']?['0005']?.numeric;
    var endOdo = _latestValues['791']?['0026']?.numeric;
    endSoc ??= await db.lastNumericSampleForTrip(tripId, '790', '0005');
    endOdo ??= await db.lastNumericSampleForTrip(tripId, '791', '0026');

    double? distanceKm;
    if (_tripStartOdo != null && endOdo != null && endOdo > _tripStartOdo!) {
      distanceKm = endOdo - _tripStartOdo!;
    }
    double? energyUsedKwh;
    if (_tripStartSoc != null && endSoc != null && _tripStartSoc! > endSoc) {
      energyUsedKwh = (_tripStartSoc! - endSoc) * Bz5Model.batteryCapacityKwh / 100.0;
    }
    double? avgConsumption;
    if (distanceKm != null && energyUsedKwh != null && distanceKm > 0.1) {
      avgConsumption = (energyUsedKwh / distanceKm) * 100.0;
    }

    double? avgMovingSpeed;
    if (_tripSpeedSamples > 0) {
      avgMovingSpeed = _tripSpeedSum / _tripSpeedSamples;
    }

    double? energyFromSoc;
    final endSocPrecise = socPrecisePct;
    if (_tripStartSocPrecise != null &&
        endSocPrecise != null &&
        _tripStartSocPrecise! > endSocPrecise) {
      energyFromSoc = (_tripStartSocPrecise! - endSocPrecise) *
          Bz5Model.batteryCapacityKwh / 100.0;
    }

    try {
      // v0.1.29+37: freeze the speed-distribution histogram onto the trip
      // row so it survives a DB wipe + cloud restore (samples aren't
      // uploaded). Computed from the just-recorded 740/0008 samples;
      // null if none were captured (then extra stays absent). Best-effort
      // — a failure here must not block trip finalization.
      String? extraJson;
      try {
        extraJson = await db.computeSpeedHistogramJson(tripId);
      } catch (e) {
        debugPrint('Speed-histogram extra compute failed (non-fatal): $e');
      }
      await db.endTrip(
        tripId,
        endSoc: endSoc,
        endOdo: endOdo,
        sampleCount: _samplesInTrip,
        distanceKm: distanceKm,
        energyUsedKwh: energyUsedKwh,
        avgConsumptionKwh100km: avgConsumption,
        minBatteryTempC: _tripMinTempC,
        maxBatteryTempC: _tripMaxTempC,
        maxCellSpreadMv: _tripMaxCellSpreadMv,
        minSoc: _tripMinSoc,
        maxSoc: _tripMaxSoc,
        peakSpeedKmh: _tripPeakSpeedKmh,
        peakPowerKw: _tripPeakPowerKw,
        peakRegenKw: _tripPeakRegenKw,
        regenEnergyKwh: _tripRegenEnergyKwh,
        avgMovingSpeedKmh: avgMovingSpeed,
        movingSeconds: _tripMovingMs > 0 ? (_tripMovingMs ~/ 1000) : null,
        idleSeconds: _tripIdleMs > 0 ? (_tripIdleMs ~/ 1000) : null,
        energyFromSocKwh: energyFromSoc,
        extra: extraJson,
      );
      debugPrint('Trip #$tripId finalized on disconnect '
          '(distance=$distanceKm km, energy=$energyUsedKwh kWh)');
    } finally {
      // Always clear active trip ID even on DB error — otherwise we'd
      // leave _currentTripId pointing to a half-closed row.
      _currentTripId = null;
      _tripStartedAt = null;
    }
  }

  // v0.1.22: throttle auto-connect attempts to avoid spamming BLE scan
  // when the user repeatedly flips the app foreground/background while
  // adapter is still out of range. 30s minimum interval between attempts.
  DateTime? _lastAutoConnectAttempt;
  static const Duration _autoConnectMinInterval = Duration(seconds: 30);

  /// v0.1.16: auto-connect at app startup if user opted in and we have a
  /// remembered adapter ID. Returns true if connection succeeded.
  ///
  /// Tries scanning first (to ensure device is in range), then matches
  /// remote ID and connects. Silently no-ops if:
  ///   - feature disabled in prefs
  ///   - no remembered adapter
  ///   - device not found in scan
  ///   - last attempt was less than 30s ago (v0.1.22 throttle)
  ///   - already connected or connecting
  /// Errors during connect are surfaced via _setStatus.
  ///
  /// v0.1.22: also called by the AppLifecycle observer in main.dart
  /// whenever the app returns to foreground, so a user who opened the
  /// app at home (out of BLE range) gets a fresh attempt when they
  /// later open it again next to the car. Previously only fired once
  /// at app startup, then silently never retried.
  Future<bool> tryAutoConnect({Duration scanTimeout = const Duration(seconds: 6)}) async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('auto_connect_enabled') ?? false;
    if (!enabled) return false;
    final savedId = prefs.getString('last_adapter');
    if (savedId == null || savedId.isEmpty) return false;
    if (_status == ConnectionStatus.connected ||
        _status == ConnectionStatus.connecting ||
        _status == ConnectionStatus.scanning) {
      return false;
    }

    // v0.1.22: throttle. If the user flips app focus rapidly while the
    // adapter is still out of range, we'd otherwise queue 5+ scans
    // back-to-back. 30 s between attempts is fast enough to feel
    // responsive ("oh, I opened the app, it found the car") while not
    // burning battery on tight repeat scans.
    final now = DateTime.now();
    if (_lastAutoConnectAttempt != null &&
        now.difference(_lastAutoConnectAttempt!) < _autoConnectMinInterval) {
      return false;
    }
    _lastAutoConnectAttempt = now;

    _setStatus(ConnectionStatus.scanning,
        msg: 'Авто-подключение к $savedId...');
    try {
      final results = await Elm327Ble.scan(timeout: scanTimeout);
      BluetoothDevice? match;
      for (final r in results) {
        if (r.device.remoteId.str == savedId) {
          match = r.device;
          break;
        }
      }
      if (match == null) {
        _setStatus(ConnectionStatus.disconnected,
            msg: 'Сохранённый адаптер не найден (вне зоны?)');
        return false;
      }
      return await connect(match);
    } catch (e) {
      _setStatus(ConnectionStatus.error, msg: 'Авто-подключение: $e');
      return false;
    }
  }

  Future<void> startPolling({bool startTrip = true}) async {
    if (_client == null || _polling) return;
    _polling = true;

    // v0.1.21.1: clean up any orphaned trips from previous app runs
    // before creating a new one. Orphans accumulate when:
    //   - app process killed by OS while trip is active
    //   - BLE drop hit a code path that didn't finalize
    //   - older app versions (pre-v0.1.21.1) with no disconnect handler
    //
    // Force-close them with their last sample's timestamp as endedAt and
    // null summary fields. Better than leaving "ACTIVE 5h 8m" trips
    // visible in history.
    try {
      final orphans = await db.getOrphanedTrips();
      for (final t in orphans) {
        final endTs = await db.forceCloseTrip(t.id,
            batteryCapacityKwh: Bz5Model.batteryCapacityKwh);
        debugPrint('Closed orphaned Trip #${t.id} (started '
            '${t.startedAt}) → endedAt=$endTs');
      }
    } catch (e) {
      debugPrint('Orphan-trip cleanup failed (non-fatal): $e');
    }

    _samplesInTrip = 0;
    _tripStartB00 = null;
    _wantTripCreation = startTrip;
    _pollCyclesSinceStart = 0;
    _cellSpreadHistory.clear();
    // v6.1: reset rolling-window charging detection state
    _b00History.clear();
    _instantaneousChargingPowerKw = 0.0;
    // v0.1.26: reset charging-companion buffer + session anchors so a
    // fresh polling session doesn't show stale charging chart data.
    _chargingHistory.clear();
    _wasCharging = false;
    _lastChargingSampleAt = null;
    _chargingSessionStartedAt = null;
    _chargingSessionStartCounter = null;
    _chargingSessionStartSocPct = null;
    // v0.1.3.1: reset volatile pack-V и cell-index state.
    // _packCellCount / _packModuleCount НЕ сбрасываем — это константы
    // конкретной машины, не зависят от polling-сессии.
    _packVoltageFilteredV = null;
    _packVoltageInstantV = null;
    _globalMinCellIndex = null;
    _globalMaxCellIndex = null;
    // v0.1.6:
    _globalMinCellMv = null;
    _globalMaxCellMv = null;
    // v0.1.29+30: reset fast pack-voltage sub-poll estimate.
    _subPollPackV = null;
    _subPollPackVAt = null;
    // v0.1.29+30: reset speed sub-poll diagnostic counters.
    _spdOk = 0;
    _spdOkNoTrip = 0;
    _spdNullPayload = 0;
    _spdSanity = 0;
    _spdException = 0;
    // v0.1.20: reset cell-pair sanity drop counter for new session
    _cellPairDropCount = 0;
    // v0.1.9: reset trip aggregates and snapshot timer.
    // v0.1.26+6: extracted to _resetTripAggregates() so it can be called
    // both here (clean BLE-session start) AND from _maybeStartTrip()
    // (start of each new trip in long-running session).
    _resetTripAggregates();
    _tripStartedAt = null;
    _pollLoop();
    notifyListeners();
  }

  Future<void> stopPolling() async {
    _polling = false;
    if (_currentTripId != null) {
      final endSoc = _latestValues['790']?['0005']?.numeric ??
          await db.lastNumericSampleForTrip(_currentTripId!, '790', '0005');
      final endOdo = _latestValues['791']?['0026']?.numeric ??
          await db.lastNumericSampleForTrip(_currentTripId!, '791', '0026');

      // v0.1.9: compute final derived metrics from rolling state.
      double? distanceKm;
      if (_tripStartOdo != null && endOdo != null && endOdo > _tripStartOdo!) {
        distanceKm = endOdo - _tripStartOdo!;
      }
      double? energyUsedKwh;
      if (_tripStartSoc != null && endSoc != null && _tripStartSoc! > endSoc) {
        energyUsedKwh = (_tripStartSoc! - endSoc) * Bz5Model.batteryCapacityKwh / 100.0;
      }
      double? avgConsumption;
      if (distanceKm != null && energyUsedKwh != null && distanceKm > 0.1) {
        avgConsumption = (energyUsedKwh / distanceKm) * 100.0;
      }

      // v0.1.21: speed-based aggregates.
      double? avgMovingSpeed;
      if (_tripSpeedSamples > 0) {
        avgMovingSpeed = _tripSpeedSum / _tripSpeedSamples;
      }

      // v0.1.21: precise SOC-derived energy (cross-check against
      // power-integrator energyUsedKwh). Uses high-precision 1FFD
      // start vs end values to compute Δ%, then ×capacity.
      double? energyFromSoc;
      final endSocPrecise = socPrecisePct;
      if (_tripStartSocPrecise != null &&
          endSocPrecise != null &&
          _tripStartSocPrecise! > endSocPrecise) {
        energyFromSoc =
            (_tripStartSocPrecise! - endSocPrecise) *
                Bz5Model.batteryCapacityKwh /
                100.0;
      }

      // v0.1.29+37: freeze speed-distribution histogram (see disconnect
      // path for rationale). Best-effort; never blocks finalization.
      String? extraJson;
      try {
        extraJson = await db.computeSpeedHistogramJson(_currentTripId!);
      } catch (e) {
        debugPrint('Speed-histogram extra compute failed (non-fatal): $e');
      }

      await db.endTrip(
        _currentTripId!,
        endSoc: endSoc,
        endOdo: endOdo,
        sampleCount: _samplesInTrip,
        distanceKm: distanceKm,
        energyUsedKwh: energyUsedKwh,
        avgConsumptionKwh100km: avgConsumption,
        minBatteryTempC: _tripMinTempC,
        maxBatteryTempC: _tripMaxTempC,
        maxCellSpreadMv: _tripMaxCellSpreadMv,
        minSoc: _tripMinSoc,
        maxSoc: _tripMaxSoc,
        peakSpeedKmh: _tripPeakSpeedKmh,
        peakPowerKw: _tripPeakPowerKw,
        peakRegenKw: _tripPeakRegenKw,
        regenEnergyKwh: _tripRegenEnergyKwh,
        // v0.1.21:
        avgMovingSpeedKmh: avgMovingSpeed,
        movingSeconds: _tripMovingMs > 0 ? (_tripMovingMs ~/ 1000) : null,
        idleSeconds: _tripIdleMs > 0 ? (_tripIdleMs ~/ 1000) : null,
        energyFromSocKwh: energyFromSoc,
        extra: extraJson,
      );
      _currentTripId = null;
      _tripStartedAt = null;
    }
    _wantTripCreation = false;
    notifyListeners();
  }

  /// v0.1.9: active trip aggregate getters (for Active Trip live view).
  /// Each returns the rolling value updated each poll cycle, or null if
  /// not yet observed in this trip.
  double? get tripMinTempC => _tripMinTempC;
  double? get tripMaxTempC => _tripMaxTempC;
  double? get tripMaxCellSpreadMv => _tripMaxCellSpreadMv;
  double? get tripMinSoc => _tripMinSoc;
  double? get tripMaxSoc => _tripMaxSoc;
  double? get tripPeakPowerKw => _tripPeakPowerKw;
  double? get tripPeakRegenKw => _tripPeakRegenKw;
  // v0.1.26+10: true when the current peak value came from the
  // HV-bus-sag heuristic rather than a direct power DID. UI should
  // append "(est.)" or similar suffix so the user can tell estimated
  // values apart from measured ones when we eventually wire the real
  // pack-current DID.
  bool get peakPowerIsEstimated => _peakPowerFromHeuristic;
  bool get peakRegenIsEstimated => _peakRegenFromHeuristic;
  double? get tripPeakSpeedKmh => _tripPeakSpeedKmh;

  /// Trip distance so far (current odo − start odo). Null if not yet measurable.
  double? get tripDistanceKm {
    if (_tripStartOdo == null || _currentTripId == null) return null;
    final curOdo = readNumeric('791', '0026');
    if (curOdo == null || curOdo <= _tripStartOdo!) return null;
    return curOdo - _tripStartOdo!;
  }

  /// Trip energy used so far (from delta SOC × pack capacity). Null if no SOC drop.
  double? get tripEnergyUsedKwh {
    if (_tripStartSoc == null || _currentTripId == null) return null;
    final curSoc = readNumeric('790', '0005');
    if (curSoc == null || curSoc >= _tripStartSoc!) return null;
    return (_tripStartSoc! - curSoc) * Bz5Model.batteryCapacityKwh / 100.0;
  }

  /// v0.1.24: trip energy used from precise SOC (1FFD high16/100).
  ///
  /// Higher resolution than [tripEnergyUsedKwh] which uses integer SOC
  /// 0x0005 and only updates in steps of 1% (= 0.65 kWh chunks on
  /// 65.28 kWh pack). With precise SOC the value updates smoothly
  /// as small fractions of kWh accumulate over time — much better UX
  /// on Driver view "energy used" cell.
  ///
  /// Falls back to integer-SOC version when 1FFD start was never
  /// captured (e.g. trip resumed from old data before v0.1.21).
  double? get tripEnergyUsedPreciseKwh {
    if (_currentTripId == null) return null;
    final startSocP = _tripStartSocPrecise;
    final curSocP = socPrecisePct;
    if (startSocP != null && curSocP != null && curSocP < startSocP) {
      return (startSocP - curSocP) * Bz5Model.batteryCapacityKwh / 100.0;
    }
    // Fallback to integer-SOC-based.
    return tripEnergyUsedKwh;
  }

  /// v0.1.24: trip consumption from precise SOC + distance.
  /// Smoother than [tripAvgConsumptionKwh100km] because the numerator
  /// updates continuously instead of stepping by 0.65 kWh chunks.
  double? get tripAvgConsumptionPreciseKwh100km {
    final dist = tripDistanceKm;
    final energy = tripEnergyUsedPreciseKwh;
    if (dist == null || energy == null || dist < 0.1) return null;
    return (energy / dist) * 100.0;
  }

  /// Trip average consumption so far (kWh/100km). Null if distance < 100m.
  double? get tripAvgConsumptionKwh100km {
    final dist = tripDistanceKm;
    final energy = tripEnergyUsedKwh;
    if (dist == null || energy == null || dist < 0.1) return null;
    return (energy / dist) * 100.0;
  }

  /// Trip duration so far. Null if no trip.
  Duration? get tripDuration {
    if (_currentTripId == null || _tripStartedAt == null) return null;
    return DateTime.now().difference(_tripStartedAt!);
  }

  /// v0.1.23: live current-trip avg speed (moving samples only).
  /// Used by Driver view "avg moving" trip-metric cell. Null until
  /// the trip has at least one moving sample.
  double? get tripCurrentAvgMovingKmh {
    if (_currentTripId == null || _tripSpeedSamples == 0) return null;
    return _tripSpeedSum / _tripSpeedSamples;
  }

  List<EcuSpec> get _ecusToPoll {
    switch (_pollMode) {
      case PollMode.driving: return pollEcusDriving;
      case PollMode.charging: return pollEcusCharging;
      case PollMode.full: return pollEcusFull;
    }
  }

  /// v0.1.17: true while a poll cycle is mid-execution. Sweep/LiveLog/DTC
  /// use this to wait for the in-flight cycle to complete before issuing
  /// their own requests — without this, both can hit readDid concurrently
  /// and corrupt the BLE channel.
  bool _pollLoopActive = false;

  // ── v0.1.29+53: scheduler state for three-group polling ──
  //
  // Replaces the old "iterate ECUs once per cycle + sub-poll between
  // them" loop, which under load grew to 5-15 s per full cycle and
  // turned the Power card into a flicker show (field max gap 149 s on
  // a 40-min drive). New model: each iteration runs at most ONE fast
  // task + ONE medium task (if due) + ONE slow task (if due), with
  // ECU round-robin guarding the documented 790-chain quirk (5th
  // consecutive read to the same ECU returns EMPTY on this adapter).
  //
  // Periods are wall-clock, not cycle-count, so ELM stalls don't
  // de-sync the schedule (a 10 s stall just means medium/slow tasks
  // come up overdue and run on the next clean iteration).
  //
  // Task definitions live in [_buildSchedule], called once per
  // _startPolling. Each task wraps an existing read function
  // (_pollSpeedOnly, _pollPackVoltageOnly, _pollCellExtremesOnly,
  // _pollEcu-with-filter, _pollCells, _pollExtraDids) — no decoder
  // logic moved, no observability hooks (+51) relocated.
  static const _kFastInterval = Duration(milliseconds: 100);
  static const _kMediumInterval = Duration(seconds: 5);
  static const _kSlowInterval = Duration(seconds: 18);
  static const _kMaxConsecutiveSameEcu = 4;
  static const _kRecoveryGapThresholdMs = 15000;
  static const _kRecoveryCooldown = Duration(seconds: 60);

  final List<_PollTask> _fastTasks = [];
  final List<_PollTask> _mediumTasks = [];
  final List<_PollTask> _slowTasks = [];

  // ECU round-robin state: the 790-chain quirk on this adapter forces
  // us to never issue a 5th consecutive read to the same ECU. The
  // scheduler counts hits per ECU and, on the next pick within the
  // same group, prefers a candidate with a different ecuTx when the
  // counter approaches the limit. If only same-ECU candidates exist,
  // we still issue the read (better the quirk than blocking forever).
  String? _lastQueriedEcu;
  int _consecutiveSameEcuCount = 0;

  // Recovery state. Triggered when packCurrentMaxGap exceeds threshold
  // OR ≥5 consecutive ELM timeouts. Action: warm reset via the existing
  // _client.initialize() (which sends ATZ + reinit + clears the
  // header/rx-filter cache inside Elm327Client). Cooldown keeps us
  // from looping if the underlying problem isn't transient.
  DateTime? _lastRecoveryAt;
  int _recoveryRunsCount = 0;

  /// v0.1.29+53: counters exposed for the diagnostics screen so the
  /// owner can see whether recovery is firing.
  int get recoveryRunsCount => _recoveryRunsCount;
  DateTime? get lastRecoveryAt => _lastRecoveryAt;

  /// Build the three task lists from scratch. Called from _startPolling
  /// before [_pollLoop] starts so the scheduler has a complete plan.
  /// Re-buildable: clears the existing lists first so a stop-and-start
  /// cycle (e.g. reconnect) doesn't accumulate duplicate tasks.
  void _buildSchedule() {
    _fastTasks.clear();
    _mediumTasks.clear();
    _slowTasks.clear();

    // ── Fast group (every iteration, target ~1 Hz per task) ──
    // 740/0008 speed, 790/0015 voltage, 790/0009 current.
    // The latter two are paired physically (V × I = power), but the
    // scheduler hands them out one per iteration — by the time both
    // have updated, no more than ~700 ms have elapsed.
    _fastTasks.add(_PollTask(
      name: 'speed',
      ecuTx: '740',
      execute: _pollSpeedOnly,
    ));
    _fastTasks.add(_PollTask(
      name: 'packV+I',
      ecuTx: '790',
      execute: _pollPackVoltageOnly,
    ));

    // ── Medium group (every ~5 s) ──
    // Owner-prescribed list. _pollEcuFiltered reads only the listed
    // DIDs from the given ECU, instead of all of them as _pollEcu
    // did. This keeps the medium group from accidentally also
    // reading slow-group DIDs.
    _mediumTasks.add(_PollTask(
      name: 'soc',
      ecuTx: '790',
      execute: () => _pollEcuFiltered('790', ['0005']),
    ));
    _mediumTasks.add(_PollTask(
      name: 'battery_temp',
      ecuTx: '790',
      execute: () => _pollEcuFiltered('790', ['002F']),
    ));
    _mediumTasks.add(_PollTask(
      name: 'odometer',
      ecuTx: '791',
      execute: () => _pollEcuFiltered('791', ['0026']),
    ));
    _mediumTasks.add(_PollTask(
      name: 'pdu_temps',
      ecuTx: '740',
      execute: () => _pollEcuFiltered(
          '740', ['0010', '0011', '0012', '0013', '0014', '0015',
                  '0016', '0017']),
    ));

    // ── Slow group (every ~18 s) ──
    // SOH (owner-moved from medium), cell extremes, gear, precise SOC.
    _slowTasks.add(_PollTask(
      name: 'soh',
      ecuTx: '790',
      execute: () => _pollEcuFiltered('790', ['0029']),
    ));
    _slowTasks.add(_PollTask(
      name: 'cell_extremes',
      ecuTx: '790',
      execute: _pollCellExtremesOnly,
    ));
    _slowTasks.add(_PollTask(
      name: 'gear',
      ecuTx: '791',
      execute: () => _pollEcuFiltered('791', ['0009']),
    ));
    _slowTasks.add(_PollTask(
      name: 'soc_precise',
      ecuTx: '790',
      execute: () => _pollEcuFiltered('790', ['1FFD']),
    ));
    // Full-cell snapshot — atomic, large (~40 reads with internal
    // round-robin already inside _pollCells); slotted as a slow task
    // so it doesn't compete with the fast group.
    _slowTasks.add(_PollTask(
      name: 'full_cells',
      ecuTx: '790',
      execute: _pollCells,
    ));
    // _pollExtraDids — other registered DIDs that were on the
    // cycle%2==1 schedule. Same idea: atomic, low frequency.
    _slowTasks.add(_PollTask(
      name: 'extra',
      ecuTx: '791',  // mostly hits 791 (VCU misc) — used for round-robin
      execute: _pollExtraDids,
    ));
    // v0.1.29+54: catchall task — runs the legacy _pollEcu sweep over
    // ONE ECU per invocation, rotating through _ecusToPoll. This
    // restores reading of DIDs that aren't in any explicit fast/
    // medium/slow group — most importantly the 20 thermal DIDs
    // (0171..01BB, module temperatures) which the Battery Health
    // 'PDU + modules temp' card depends on. They were silently lost
    // in +53 when the for-each-ECU sweep was removed.
    //
    // Why rotate one ECU per call instead of all ECUs in one slow
    // task: a single _pollEcu(790) sweep is ~20+ reads to the same
    // ECU which would max out the 790-chain quirk badly. By yielding
    // back to the scheduler after each ECU, the fast group gets a
    // chance to interleave 740 reads, naturally breaking the chain.
    // With 18 s slow period and 3-4 ECUs, a full rotation completes
    // in ~60-70 s — fine for slowly-changing data like module
    // temperatures.
    //
    // ecuTx is left as 'rotation' (not a real ECU) so the round-
    // robin guard treats it as a different ECU from any real task
    // — it always counts as 'switch', resetting _consecutiveSameEcu
    // when it runs.
    _slowTasks.add(_PollTask(
      name: 'catchall',
      ecuTx: 'rotation',
      execute: _pollEcuCatchall,
    ));
  }

  /// v0.1.29+54: index into _ecusToPoll for the catchall task. Wraps
  /// when it reaches the end. Reset implicit on _buildSchedule (the
  /// field is reset to 0 below, the task list is cleared and rebuilt,
  /// so the rotation starts over fresh on each polling session).
  int _catchallEcuIndex = 0;

  /// Catchall sweep: reads ONE ECU's full DID list per invocation,
  /// rotating through _ecusToPoll. The underlying _pollEcu already
  /// excludes fast-lane DIDs (740/0008, 790/0009) and cells, so this
  /// won't shadow-write into the slots fast-lane owns. Other DIDs
  /// (thermal, bodywork, gauges) get refreshed; if they happen to
  /// duplicate a medium/slow explicit task, the overwrite is benign
  /// — same registry decoder, same _latestValues slot.
  Future<void> _pollEcuCatchall() async {
    final ecus = _ecusToPoll;
    if (ecus.isEmpty) return;
    final ecu = ecus[_catchallEcuIndex % ecus.length];
    _catchallEcuIndex++;
    await _pollEcu(ecu);
  }

  /// Pick the next task from [candidates], respecting ECU round-robin.
  /// If the last-used ECU has been hit [_kMaxConsecutiveSameEcu] times
  /// in a row, prefer a candidate whose ecuTx differs. If no such
  /// candidate exists, fall back to least-recently-run regardless.
  /// Within the eligible set, pick the one with the oldest [lastRunAt]
  /// (or null = highest priority).
  _PollTask? _pickWithRoundRobin(List<_PollTask> candidates) {
    if (candidates.isEmpty) return null;

    Iterable<_PollTask> eligible = candidates;
    if (_consecutiveSameEcuCount >= _kMaxConsecutiveSameEcu &&
        _lastQueriedEcu != null) {
      final different =
          candidates.where((t) => t.ecuTx != _lastQueriedEcu).toList();
      if (different.isNotEmpty) {
        eligible = different;
      }
      // else: all candidates are same-ECU; let the quirk happen
      // rather than block forever.
    }

    final sorted = eligible.toList()
      ..sort((a, b) {
        if (a.lastRunAt == null) return -1;
        if (b.lastRunAt == null) return 1;
        return a.lastRunAt!.compareTo(b.lastRunAt!);
      });
    return sorted.first;
  }

  /// Run [task], update its lastRunAt, and update ECU round-robin
  /// counters. Errors are caught inside the task (existing read
  /// functions already do this); we only track timing.
  Future<void> _runTask(_PollTask task) async {
    await task.execute();
    task.lastRunAt = DateTime.now();
    if (task.ecuTx == _lastQueriedEcu) {
      _consecutiveSameEcuCount++;
    } else {
      _lastQueriedEcu = task.ecuTx;
      _consecutiveSameEcuCount = 1;
    }
  }

  /// Check if a recovery is warranted, and run it if so. Triggers:
  ///   • packCurrentMaxGapMs in the current observation window has
  ///     exceeded [_kRecoveryGapThresholdMs] AND we're past cooldown
  ///     since the last recovery.
  /// Action:
  ///   • _client.initialize() — sends ATZ to the chip and replays the
  ///     init sequence (E0/L0/S0/H1/SP6/AT2 + warmup 0100). This also
  ///     resets the header/rx-filter cache inside Elm327Client.
  /// We deliberately do NOT touch the BLE link or reconnect — that's
  /// a heavier hammer and the owner specifically asked for soft reset
  /// only. The cooldown prevents oscillation if the warm reset isn't
  /// enough.
  Future<void> _maybeRunRecovery() async {
    if (_client == null) return;
    if (_packCurrentMaxGapMs <= _kRecoveryGapThresholdMs) return;

    final now = DateTime.now();
    final lastRec = _lastRecoveryAt;
    if (lastRec != null && now.difference(lastRec) < _kRecoveryCooldown) {
      return;
    }

    debugPrint('Recovery: max gap '
        '${_packCurrentMaxGapMs}ms exceeded threshold; warm reset');
    try {
      await _client!.initialize();
      _recoveryRunsCount++;
      _lastRecoveryAt = now;
      // Reset max gap so we don't immediately re-trigger; the next
      // big spike will refill it. Counters not affected by design
      // (resetPackCurrentObservers is the user-facing reset).
      _packCurrentMaxGapMs = 0;
      _packCurrentPrevSuccessAt = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Recovery failed: $e');
      // Don't update _lastRecoveryAt so cooldown doesn't gate a real
      // retry, but also don't loop tight — natural cycle delay below.
    }
  }

  Future<void> _pollLoop() async {
    int cycle = 0;
    _buildSchedule();
    while (_polling && _client != null) {
      _pollLoopActive = true;
      try {
        final now = DateTime.now();

        // v0.1.29+53: scheduler-driven. Each iteration may run at most
        // one fast, one medium (if due), and one slow (if due) task.
        // Total per iteration: 1-3 reads (~100-300 ms), down from
        // 60-100 reads (5-15 s) in the pre-+53 loop.

        // Slow group first — if a slow task is overdue, run it; it's
        // the heaviest single block (full_cells, extra) so we want to
        // get it out of the way while the fast group hasn't already
        // hit the round-robin limit.
        final slowDue = _slowTasks.where((t) =>
            t.lastRunAt == null ||
            now.difference(t.lastRunAt!) >= _kSlowInterval).toList();
        final slowPick = _pickWithRoundRobin(slowDue);
        if (slowPick != null) await _runTask(slowPick);

        // Medium group.
        final mediumDue = _mediumTasks.where((t) =>
            t.lastRunAt == null ||
            now.difference(t.lastRunAt!) >= _kMediumInterval).toList();
        final mediumPick = _pickWithRoundRobin(mediumDue);
        if (mediumPick != null) await _runTask(mediumPick);

        // Fast group — always run one. _kFastInterval is a soft floor;
        // if all fast tasks have been hit within the interval, the
        // round-robin still picks the least-recent one (so we don't
        // stall).
        final fastPick = _pickWithRoundRobin(_fastTasks);
        if (fastPick != null) await _runTask(fastPick);

        // Housekeeping (unchanged from pre-+53).
        _updatePowerCalculations();
        await _maybeStartTrip();
        await _maybeSegmentTripOnPark();
        _updateTripAggregates();
        await _maybeWriteSnapshot();

        // Soft recovery check after housekeeping so it doesn't block
        // a normal iteration's reads.
        await _maybeRunRecovery();
      } catch (e) {
        debugPrint('Poll error: $e');
      }
      _pollLoopActive = false;
      cycle++;
      _pollCyclesSinceStart++;
      // Short tick — most iterations are 1-3 reads, the delay keeps
      // the loop from monopolising the event queue and matches the
      // BLE adapter's typical inter-command quiet time. The fast
      // group naturally paces itself via ECU round-robin and the
      // task's own timeouts.
      await Future.delayed(const Duration(milliseconds: 50));
    }
    _pollLoopActive = false;
  }

  /// v0.1.29+53: read a specific subset of DIDs from one ECU. Used by
  /// medium/slow scheduler tasks to read only what their group is
  /// supposed to read, instead of the whole ECU. Mirrors the body of
  /// [_pollEcu] but filtered by the [allowed] list. Same error
  /// handling, same db write, same notifyListeners.
  Future<void> _pollEcuFiltered(String ecuTx, List<String> allowed) async {
    if (_client == null) return;
    // Find the matching EcuSpec to get rxId and the DidSpec entries.
    final ecu = _ecusToPoll.firstWhere(
      (e) => e.txId == ecuTx,
      orElse: () => _ecusToPoll.first,  // fallback shouldn't normally hit
    );
    if (ecu.txId != ecuTx) return;  // not in current poll set

    for (final spec in ecu.dids) {
      if (!allowed.contains(spec.did)) continue;
      if (spec.category == DidCategory.cells) continue;
      // Same exclusions as _pollEcu — these are owned by fast-lane.
      if (ecu.txId == '740' && spec.did == '0008') continue;
      if (ecu.txId == '790' && spec.did == '0009') continue;

      try {
        final r = await _client!.readDid(spec.did, tx: ecu.txId, rx: ecu.rxId)
            .timeout(const Duration(milliseconds: 1500));
        if (r == null || !r.isPositive) continue;

        final payload = r.payloadAfterUdsRead;
        if (payload == null) continue;

        final decoded = decodeDid(spec, payload);
        if (decoded == null) continue;

        _latestValues.putIfAbsent(ecu.txId, () => {})[spec.did] = decoded;

        if (_currentTripId != null) {
          await db.insertSample(
            tripId: _currentTripId,
            ecuTx: ecu.txId,
            did: spec.did,
            rawHex: r.rawHex,
            numeric: decoded.numeric,
            text: decoded.text,
          );
          _samplesInTrip++;
        }
      } catch (_) {
        // Per-DID error → continue to next DID. Same as _pollEcu.
      }
    }
    notifyListeners();
  }

  /// v0.1.29+26: read just 790/0x0015 (HV pack voltage) and update
  /// _latestValues. Slotted between heavier ECU polls in _pollLoop so
  /// the dashboard pack voltage refreshes at the sub-poll cadence (~1
  /// Hz) instead of waiting for a full cycle (~2-3 s).
  ///
  /// Mirrors [_pollSpeedOnly] in structure. Best-effort: any error is
  /// swallowed and the next invocation will retry. Notifies listeners
  /// on success so the UI rebuilds mid-cycle.
  ///
  /// Rationale: pack voltage swings 25-30% under load on this 136-cell
  /// 450V-nominal pack (Cycles 12a/b: 371.5..467.8 V observed). At the
  /// previous ~3 s cadence, regen-brake or hard-accel transients were
  /// often missed entirely. 1 Hz matches typical EV dashboard refresh
  /// and is well below the BLE channel's actual capacity (single
  /// readDid is ~50-150 ms, leaving headroom for the rest of the poll
  /// loop).
  ///
  /// Decode: u16 big-endian × 0.025 V (per registry / known_dids.md).
  /// Sanity bound 360-480 V — outside that we skip the update (BZ5
  /// pack physically can't be below 360 V even at 0% SOC and can't
  /// exceed 480 V at 100% SOC + regen).
  ///
  /// Should NOT be called during sweep/livelog (which pause polling
  /// anyway, so this is unreachable then).
  Future<void> _pollPackVoltageOnly() async {
    if (_client == null) return;
    try {
      final r = await _client!.readDid('0015', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 800));
      final p = r?.payloadAfterUdsRead;
      if (p == null || p.length < 2) return;
      final raw = (p[0] << 8) | p[1];
      final volts = raw * 0.025;
      // Sanity: BZ5 pack is 360-480 V range. Anything outside is a
      // misaligned frame or BLE corruption; skip silently.
      if (volts < 360.0 || volts > 480.0) return;
      _latestValues.putIfAbsent('790', () => {});
      _latestValues['790']!['0015'] =
          DecodedValue(numeric: volts, unit: 'V');
      // Mirror _pollSpeedOnly: also save to samples DB so trip
      // history retains the fast-cadence voltage readings instead
      // of just the slower full-cycle samples.
      if (_currentTripId != null) {
        await db.insertSample(
          tripId: _currentTripId,
          ecuTx: '790',
          did: '0015',
          rawHex: r!.rawHex,
          numeric: volts,
          text: null,
        );
        _samplesInTrip++;
      }
      notifyListeners();
    } catch (_) {
      // Ignore — next sub-poll attempt will retry.
    }

    // v0.1.29+33: read pack CURRENT (790/0009) right after voltage, in
    // the same sub-poll, so V and I are one read apart (~110 ms) — close
    // enough to treat as simultaneous for instantaneous power. This adds
    // a SECOND read to 790 per fast-lane iteration; combined with the
    // separate _pollCellExtremesOnly (002B + 002D) that's up to 4 reads
    // to 790 across the iteration, but they are not all consecutive
    // (voltage+current here, then a different ECU via _pollEcu, then
    // extremes), so we stay clear of the "5th consecutive same-ECU read
    // returns EMPTY" adapter quirk (see runLiveLog notes).
    try {
      final rI = await _client!.readDid('0009', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 800));
      final pI = rI?.payloadAfterUdsRead;
      if (pI != null && pI.length >= 2) {
        final raw = (pI[0] << 8) | pI[1];
        // Offset-signed decode, discharge positive (C31/C32). PROVISIONAL
        // scale — see _kPackCurrentZeroRaw / _kPackCurrentAmpsPerLsb.
        final amps =
            (raw - _kPackCurrentZeroRaw) * _kPackCurrentAmpsPerLsb;
        // Sanity: BZ5 peak ~200 kW / ~400 V ≈ 500 A discharge; regen
        // peak well under that. Bound generously and skip outliers
        // (misaligned frame / BLE corruption).
        if (amps >= -600.0 && amps <= 600.0) {
          // v0.1.29+51: observability. Update before assigning the
          // cached value so the gap is measured between the previous
          // _packCurrentAt and the new one — the actual transport-
          // level interval between successful raw decodes.
          final now = DateTime.now();
          final prev = _packCurrentPrevSuccessAt;
          if (prev != null) {
            final gapMs = now.difference(prev).inMilliseconds;
            if (gapMs > _packCurrentMaxGapMs) {
              _packCurrentMaxGapMs = gapMs;
            }
          }
          _packCurrentPrevSuccessAt = now;
          _packCurrentReadOkCount++;

          _packCurrentA = amps;
          _packCurrentAt = now;
          if (_currentTripId != null) {
            await db.insertSample(
              tripId: _currentTripId,
              ecuTx: '790',
              did: '0009',
              rawHex: rI!.rawHex,
              numeric: amps,
              text: null,
            );
            _samplesInTrip++;
          }
          notifyListeners();
        }
      }
    } catch (_) {
      // Ignore — next sub-poll attempt will retry.
    }
  }

  /// v0.1.29+30: fast min/max-cell sub-poll feeding [_subPollPackV].
  ///
  /// Reads 790/0x002B (global min cell mV) and 790/0x002D (global max
  /// cell mV) — two cheap single reads — and derives a pack voltage
  /// estimate as (min+max)/2 × cellCount. This is the fast-cadence
  /// stand-in for [packVoltageFromCells] between the slower full
  /// _pollCells refreshes, so the dashboard pack-voltage number tracks
  /// load transients at ~1 Hz instead of freezing for ~6 s.
  ///
  /// Why (min+max)/2 rather than a true average: on a healthy LFP pack
  /// the cell spread is <50 mV, so the midpoint of the extremes is
  /// within ~25 mV of the true mean — ×136 cells that's ~3.4 V of
  /// worst-case bias, well under the load-transient swings (25-30 V)
  /// we're trying to capture. When the full _pollCells refresh lands,
  /// [packVoltageFromCells] switches back to the exact average. Net:
  /// accurate at rest, responsive under load.
  ///
  /// Mirrors [_pollPackVoltageOnly] / [_pollSpeedOnly]: 800 ms timeout
  /// per read, all errors swallowed, listeners notified on success.
  /// Also updates the existing _globalMinCellMv / _globalMaxCellMv so
  /// the Pack Extremes UI refreshes at sub-poll cadence too (bonus —
  /// previously those only updated on cycle%2 via _pollExtraDids).
  Future<void> _pollCellExtremesOnly() async {
    if (_client == null) return;
    int? minMv;
    int? maxMv;
    try {
      final rMin = await _client!.readDid('002B', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 800));
      final pMin = rMin?.payloadAfterUdsRead;
      if (pMin != null && pMin.length >= 2) {
        final mv = (pMin[0] << 8) | pMin[1];
        if (mv >= 2000 && mv <= 3700) minMv = mv;
      }
    } catch (_) {}
    try {
      final rMax = await _client!.readDid('002D', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 800));
      final pMax = rMax?.payloadAfterUdsRead;
      if (pMax != null && pMax.length >= 2) {
        final mv = (pMax[0] << 8) | pMax[1];
        if (mv >= 2000 && mv <= 3700) maxMv = mv;
      }
    } catch (_) {}

    // Same pair-level guard as _pollExtraDids: only derive a voltage if
    // both came back and the spread is physically sane. Update the
    // individual extremes opportunistically (half a sample beats none).
    if (minMv != null) _globalMinCellMv = minMv;
    if (maxMv != null) _globalMaxCellMv = maxMv;

    if (minMv != null && maxMv != null) {
      final spread = maxMv - minMv;
      if (spread >= 0 && spread <= 100) {
        final midMv = (minMv + maxMv) / 2.0;
        final seriesCells = _packCellCount ?? 136;
        final packV = midMv * seriesCells / 1000.0;
        if (packV >= 200 && packV <= 500) {
          _subPollPackV = packV;
          _subPollPackVAt = DateTime.now();
          notifyListeners();
        }
      }
    }
  }

  /// v0.1.24: read just 740/0x0008 (speed) and update _latestValues.
  ///
  /// Slotted between heavier ECU polls in _pollLoop so the dashboard
  /// speed reading refreshes 2-3× per second instead of waiting for a
  /// full cycle. Best-effort: any error is swallowed and the next
  /// invocation will retry. Notifies listeners on success so the UI
  /// rebuilds mid-cycle.
  ///
  /// Should NOT be called during sweep/livelog (which pause polling
  /// anyway, so this is unreachable then).
  Future<void> _pollSpeedOnly() async {
    if (_client == null) return;
    try {
      final r = await _client!.readDid('0008', tx: '740', rx: '748')
          .timeout(const Duration(milliseconds: 800));
      final p = r?.payloadAfterUdsRead;
      if (p == null || p.length < 2) {
        // v0.1.29+30: PDU didn't answer (timeout / EMPTY / NRC). This
        // is the path that produces "No speed data" if 740 is silent
        // for a whole trip while BMS still answers.
        _spdNullPayload++;
        return;
      }
      // Decode locally rather than via registry to avoid round-trip;
      // 740/0x0008 is u16 big-endian, scale 0.07097.
      final raw = (p[0] << 8) | p[1];
      if (raw > 3000) {
        _spdSanity++; // v0.1.29+30
        return; // sanity: >213 km/h impossible for BZ5
      }
      final kmh = raw * 0.07097;
      // Write into _latestValues so the existing vehicleSpeedKmh getter
      // and the trip aggregator see the fresh value. We synthesise a
      // DecodedValue here matching what _pollEcu would produce.
      _latestValues.putIfAbsent('740', () => {});
      _latestValues['740']!['0008'] =
          DecodedValue(numeric: kmh, unit: 'km/h');

      // v0.1.29+55: trip-level speed aggregation moved here from
      // _updateTripAggregates. The aggregator must run on REAL sample
      // arrivals, not every 50 ms poll-loop tick — otherwise the
      // moving/idle dt accounting drowned in integer-division loss
      // (50 ms / 1000 → 0 sec). Now we update at the only point a
      // fresh 740/0008 actually lands. Peak/avg/samples are also
      // moved here so they count one entry per real read (was
      // counting one entry per cycle tick, biasing averages toward
      // whatever value was cached at iteration boundaries).
      if (_currentTripId != null && kmh < 250) {
        final now = DateTime.now();
        _tripPeakSpeedKmh = _tripPeakSpeedKmh == null
            ? kmh
            : (kmh > _tripPeakSpeedKmh! ? kmh : _tripPeakSpeedKmh);
        if (_lastSpeedFreshAt != null) {
          final dt = now.difference(_lastSpeedFreshAt!).inMilliseconds;
          if (dt > 0) {
            // v0.1.26+5 reasoning preserved: cap per-sample contribution
            // at 120 s so a single very late sample (BLE stall / sleep)
            // can't extrapolate forever, but DO accumulate the capped
            // portion so the trip's moving+idle total stays close to
            // wall-clock duration.
            const capMs = 120000;
            final attribMs = dt > capMs ? capMs : dt;
            if (kmh > 1.0) {
              _tripMovingMs += attribMs;
            } else {
              _tripIdleMs += attribMs;
            }
          }
        }
        _lastSpeedFreshAt = now;
        if (kmh > 1.0) {
          _tripSpeedSum += kmh;
          _tripSpeedSamples++;
        }
      }

      // v0.1.26+6: also save to samples DB so the in-trip speed history
      // is recorded. Previously _pollEcu(packMonitor) was the only writer
      // for 740/0008 → samples, but as of v0.1.26+6 we skip it there to
      // avoid clobbering _latestValues. Without this save, exported
      // trips would contain zero 740/0008 samples in their history,
      // which would make trip-detail speed charts and post-hoc trip
      // re-analysis impossible.
      if (_currentTripId != null) {
        await db.insertSample(
          tripId: _currentTripId,
          ecuTx: '740',
          did: '0008',
          rawHex: r!.rawHex,
          numeric: kmh,
          text: null,
        );
        _samplesInTrip++;
        _spdOk++; // v0.1.29+30
      } else {
        // v0.1.29+30: read OK but no active trip → value shown live on
        // the dashboard but NOT persisted to trip history. If this
        // counter is high for a trip that "should" have been active,
        // the bug is in trip detection (_maybeStartTrip / _currentTripId
        // lifecycle), not in the PDU read path.
        _spdOkNoTrip++;
      }
      notifyListeners();
    } catch (_) {
      _spdException++; // v0.1.29+30: timeout or BLE error
      // Ignore — next sub-poll attempt will retry.
    }
  }

  /// v0.1.17: wait until any in-flight poll cycle finishes. Used by
  /// sweep/liveLog/DTC handlers before issuing their first request, so we
  /// don't accidentally interleave with the polling loop's readDid calls
  /// on the single BLE channel.
  ///
  /// Waits up to [maxMs] (default 8000) for the flag to clear. Returns
  /// after the wait regardless — sweep/liveLog still try to proceed.
  Future<void> _waitForPollIdle({int maxMs = 8000}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: maxMs));
    while (_pollLoopActive && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// v0.1.29+43: end the current trip when the car has been parked (gear
  /// P) for longer than _kParkCloseThreshold, so the next shift into D
  /// begins a fresh trip. See the _parkedSince field comment for the full
  /// rationale. Called each poll cycle while a trip is active.
  ///
  /// Guards, in order:
  ///  - no active trip, or charging → do nothing (charging legitimately
  ///    sits in P for a long time and must NOT be read as end-of-trip).
  ///  - gear != P → not parked; reset the P debounce and clock, the trip
  ///    continues (a sub-10-min stop never splits a drive).
  ///  - gear == P but not yet held for _kParkConfirmDuration → still
  ///    debouncing a possibly-spurious P read; don't arm the clock.
  ///  - P confirmed and held past _kParkCloseThreshold → finalize via the
  ///    SAME path as a clean end (_finalizeTripFromLastKnown), then re-arm
  ///    _wantTripCreation so _maybeStartTrip makes a new trip on the next
  ///    D. The finalize path nulls _currentTripId, which makes any later
  ///    BLE-drop finalize a no-op (its own _currentTripId==null guard) —
  ///    so this never collides with the leave-the-car close path.
  Future<void> _maybeSegmentTripOnPark() async {
    if (_currentTripId == null || isCharging) {
      _parkConfirmStart = null;
      _parkedSince = null;
      return;
    }
    final gear = readNumeric('791', '0009');
    final inPark = gear != null && gear.toInt() == 1; // 1 = P

    if (!inPark) {
      // Moving / in D-R-N — trip continues; clear all park state.
      _parkConfirmStart = null;
      _parkedSince = null;
      return;
    }

    final now = DateTime.now();
    // Debounce: P must hold continuously before we trust it.
    _parkConfirmStart ??= now;
    if (now.difference(_parkConfirmStart!) < _kParkConfirmDuration) {
      return; // still confirming a stable P
    }
    // P confirmed stable — start (or continue) the park clock.
    _parkedSince ??= now;

    if (now.difference(_parkedSince!) >= _kParkCloseThreshold) {
      debugPrint('Trip #$_currentTripId: parked > '
          '${_kParkCloseThreshold.inMinutes} min → segmenting (close + arm new).');
      await _finalizeTripFromLastKnown(); // same path as a clean end
      // Re-arm so the next shift into D creates a fresh trip.
      _wantTripCreation = true;
      _parkConfirmStart = null;
      _parkedSince = null;
    }
  }

  Future<void> _maybeStartTrip() async {
    if (!_wantTripCreation) return;
    if (_currentTripId != null) return;
    if (_pollCyclesSinceStart < 2) return;
    final hasOBC = readNumeric('782', '0057') != null;
    final hasBMS = readNumeric('790', '0005') != null;
    if (!hasOBC && !hasBMS) return;

    if (isCharging) {
      _wantTripCreation = false;
      debugPrint('Polling started during charging — no Trip created.');
    } else {
      // v0.1.26+6: reset all rolling trip aggregates BEFORE allocating
      // the new trip_id. Without this the new trip inherits peak_speed,
      // peak_power, moving_seconds and other counters from the previous
      // trip. Observed in trips 11 & 12 from 2026-05-19/20 export: trip
      // 11 had all 25 of its 740/0008 speed samples = 0.0, yet
      // peak_speed_kmh = 80.9 — leaked from an even earlier session.
      _resetTripAggregates();
      // v0.1.26+8: capture trip-start anchors from already-populated
      // _latestValues BEFORE inserting the trip row, so the start_odometer
      // and start_soc columns get filled at creation time (not via a
      // later poll-cycle capture path that almost never fired — every
      // trip in the 2026-05-20 export had start_odometer = NULL despite
      // 791/0026 being readable, because _pollEcu's capture site sits
      // *after* _maybeStartTrip in the cycle and 791 silently times out
      // once the car is moving).
      _tripStartOdo = _latestValues['791']?['0026']?.numeric;
      _tripStartSoc = _latestValues['790']?['0005']?.numeric;
      _tripStartSocPrecise = socPrecisePct;
      _currentTripId = await db.startTrip(
        startSoc: _tripStartSoc,
        startOdo: _tripStartOdo,
      );
      _tripStartedAt = DateTime.now();
      _wantTripCreation = false;
      debugPrint('Trip #$_currentTripId created. start_odo='
          '${_tripStartOdo} start_soc=${_tripStartSoc}');
    }
    notifyListeners();
  }

  /// v0.1.26+6: extracted out of startPolling so a new trip created mid-session
  /// (e.g. user parked, walked away, came back, started driving again) gets
  /// clean aggregates instead of inheriting peak_speed / peak_power / moving
  /// counters from the previous trip. Previously _maybeStartTrip allocated a
  /// new trip_id but left _tripMovingSec, _tripPeakSpeedKmh, etc. populated
  /// from the prior session — directly visible in exported trip 11 where
  /// peak_speed=80.9 km/h was inherited despite all 740/0x0008 samples
  /// reading 0 within that trip.
  void _resetTripAggregates() {
    _tripMinTempC = null;
    _tripMaxTempC = null;
    _tripMaxCellSpreadMv = null;
    _tripMinSoc = null;
    _tripMaxSoc = null;
    _tripPeakSpeedKmh = null;
    _tripPeakPowerKw = null;
    _tripPeakRegenKw = null;
    _tripRegenEnergyKwh = null;
    _tripSpeedSum = 0;
    _tripSpeedSamples = 0;
    _tripMovingMs = 0;
    _tripIdleMs = 0;
    _lastSpeedSampleAt = null;
    _lastSpeedFreshAt = null;
    _tripStartSocPrecise = null;
    _tripStartSoc = null;
    _tripStartOdo = null;
    _samplesInTrip = 0;
    _tripStartB00 = null;
    _consumptionWindow.clear();
    _recentIdleHvBus.clear();
    _peakPowerFromHeuristic = false;
    _peakRegenFromHeuristic = false;
    _lastSnapshotAt = null;
  }

  /// v0.1.9: rolling aggregates updated each poll cycle.
  ///
  /// Only computes when a trip is active. Each metric is min/max-tracked
  /// across the trip duration. At endTrip, these values are written to the
  /// Trip row in DB (no need to re-scan Samples).
  ///
  /// Peak power / regen / speed metrics depend on DIDs not yet identified
  /// for BZ5 (TODO: incorporate after VCU 791 deep-sweep finishes).
  void _updateTripAggregates() {
    if (_currentTripId == null) return;

    final soc = readNumeric('790', '0005');
    if (soc != null) {
      _tripMinSoc = _tripMinSoc == null ? soc : (soc < _tripMinSoc! ? soc : _tripMinSoc);
      _tripMaxSoc = _tripMaxSoc == null ? soc : (soc > _tripMaxSoc! ? soc : _tripMaxSoc);
    }

    final temp = readNumeric('790', '002F');
    if (temp != null) {
      // v0.1.10 hotfix: registry decoder for 0x002F already applies offset -40.
      // Don't subtract again here — that caused live temp range to show
      // ~-22°C when real pack temp was ~18°C (40-degree shift).
      final tempC = temp;
      _tripMinTempC = _tripMinTempC == null ? tempC : (tempC < _tripMinTempC! ? tempC : _tripMinTempC);
      _tripMaxTempC = _tripMaxTempC == null ? tempC : (tempC > _tripMaxTempC! ? tempC : _tripMaxTempC);
    }

    final minMv = globalMinCellMv;
    final maxMv = globalMaxCellMv;
    if (minMv != null && maxMv != null) {
      final spread = (maxMv - minMv).toDouble();
      _tripMaxCellSpreadMv = _tripMaxCellSpreadMv == null
          ? spread
          : (spread > _tripMaxCellSpreadMv! ? spread : _tripMaxCellSpreadMv);
    }

    // Power-A from VCU 791/0x0038 — best-guess instantaneous power.
    // We don't yet know the exact semantics (whether it's bidirectional,
    // signed, or unsigned), so we treat it as magnitude. If/when we find
    // a signed regen value, peakRegenKw will be populated separately.
    //
    // v0.1.25+3: ignore precharge spike. When you press Start, the
    // pre-charge resistor connects → contactors close → inverter caps
    // charge up. That transient draws 60-80 kW for ~500 ms even though
    // the car isn't moving. Previously this was captured as the trip's
    // "peak power" and stuck there for the whole drive ("80.5 kW" with
    // 0 distance). Now we only sample power when:
    //   (1) trip has been running for at least 5 seconds, AND
    //   (2) vehicle is actually moving (speed > 0.5 km/h)
    // This drops the precharge moment and any other Ready-but-parked
    // electrical events (lights on, AC compressor cycling, etc.).
    final pwr = readNumeric('791', '0038');
    if (pwr != null && _tripStartedAt != null) {
      final tripAgeSec =
          DateTime.now().difference(_tripStartedAt!).inSeconds;
      final curSpeed = readNumeric('740', '0008') ?? 0;
      if (tripAgeSec >= 5 && curSpeed > 0.5) {
        final kw = pwr.abs(); // assume already in kW after scale=0.1
        _tripPeakPowerKw = _tripPeakPowerKw == null
            ? kw
            : (kw > _tripPeakPowerKw! ? kw : _tripPeakPowerKw);
        _peakPowerFromHeuristic = false;
      }
    }

    // v0.1.26+10: HV-bus-sag heuristic — fallback peak power/regen
    // estimation while we hunt the real pack-current DID.
    //
    // Only runs when we have all three inputs in this poll cycle:
    //   - HV bus voltage (790/0x0015)
    //   - Min cell voltage (790/0x002B) for spread calc
    //   - Max cell voltage (790/0x002D)
    //
    // We DO update peak_power even when the direct 791/0x0038 path
    // succeeded — the two estimates can coexist, and whichever yielded
    // the higher kW for the trip wins. But we mark which source the
    // current peak came from so the UI can show "(est.)" suffix when
    // heuristic dominates.
    final hvBus = readNumeric('790', '0015');
    final cellMin = readNumeric('790', '002B');
    final cellMax = readNumeric('790', '002D');
    if (hvBus != null &&
        cellMin != null &&
        cellMax != null &&
        _tripStartedAt != null) {
      final tripAgeSec =
          DateTime.now().difference(_tripStartedAt!).inSeconds;
      // Same gate as direct path — drop precharge transients.
      if (tripAgeSec >= 5) {
        final spread = cellMax - cellMin;

        // Update V_oc baseline from near-idle samples (low spread).
        // Pack is electrically calm → terminal V ≈ open-circuit V.
        if (spread <= _idleSpreadThresholdMv) {
          _recentIdleHvBus.add(hvBus);
          while (_recentIdleHvBus.length > _idleHvBusWindowSize) {
            _recentIdleHvBus.removeAt(0);
          }
        }

        // Need a few baseline samples before estimation makes sense.
        if (_recentIdleHvBus.length >= 3) {
          final vOc = _recentIdleHvBus.reduce((a, b) => a + b) /
              _recentIdleHvBus.length;
          final deltaV = vOc - hvBus;
          // Ignore tiny excursions — sub-3 V noise yields sub-7 kW
          // false positives that would clutter the badge.
          if (deltaV.abs() >= 3.0) {
            final estKw =
                (hvBus * deltaV.abs()) / (1000.0 * _packResistanceOhm);
            // Sanity ceiling — refuse estimates above 220 kW (BZ5 motor
            // is 200 kW rated; anything above is measurement glitch).
            if (estKw <= 220.0) {
              if (deltaV > 0) {
                // V dropped → discharging into motor.
                if (_tripPeakPowerKw == null ||
                    estKw > _tripPeakPowerKw!) {
                  _tripPeakPowerKw = estKw;
                  _peakPowerFromHeuristic = true;
                }
              } else {
                // V rose → regen charging the pack.
                if (_tripPeakRegenKw == null ||
                    estKw > _tripPeakRegenKw!) {
                  _tripPeakRegenKw = estKw;
                  _peakRegenFromHeuristic = true;
                }
              }
            }
          }
        }
      }
    }

    // v0.1.21: speed tracking was here. v0.1.29+55 moved peak/avg/
    // moving-idle/idle accumulators into _pollSpeedOnly itself — that's
    // the only place where a fresh 740/0008 sample actually lands, and
    // the old per-cycle code (called every 50 ms tick) was reading the
    // SAME cached value 20× per second between real reads. The dt-based
    // time accounting then drowned in integer-division truncation
    // (50 ms / 1000 = 0), and accumulated only on the rare long
    // iterations (slow tasks, recovery). Result on the field: 17.8 km
    // trip showed 51m / 18m moving/idle (math demands ~33m moving at
    // the reported 32 km/h avg). The fix is to drive time accounting
    // from the actual sample arrival in _pollSpeedOnly.

    // v0.1.21: capture precise SOC at trip start, for energy-from-SOC
    // calculation at trip end. Uses 1FFD high16 / 100. Once captured
    // the value is sticky for the trip duration (the BMS sometimes
    // refuses 1FFD requests mid-cycle; we don't want to overwrite the
    // starting value with a late successful read).
    if (_tripStartSocPrecise == null) {
      final socP = socPrecisePct;
      if (socP != null) _tripStartSocPrecise = socP;
    }

    // v0.1.23: sample current consumption into rolling 2-minute window.
    // Used by smoothedConsumptionKwh100km getter and trip-aware Range.
    //
    // We compute *trip-to-date* consumption (energy / distance) and feed
    // each sample into the window. That's noisier than ideal — a true
    // "instantaneous" consumption would use power × time over a short
    // recent slice — but we don't have a clean instantaneous power DID
    // yet. The 2-min window smooths most of the noise out anyway.
    if (_currentTripId != null &&
        _tripStartOdo != null &&
        _tripStartSoc != null) {
      final curSoc = readNumeric('790', '0005');
      final curOdo = readNumeric('791', '0026');
      if (curSoc != null && curOdo != null) {
        final dist = curOdo - _tripStartOdo!;
        final socDrop = _tripStartSoc! - curSoc;
        if (dist > 0.5 && socDrop > 0) {
          // kWh used so far = socDrop% × capacity / 100
          final kwhUsed = socDrop * Bz5Model.batteryCapacityKwh / 100.0;
          // kWh/100km = (kWhUsed / dist) × 100
          final consumption = (kwhUsed / dist) * 100.0;
          // Sanity gate: ignore obvious noise. >100 kWh/100km is hard
          // accel for sustained period (unlikely) and <2 is regen-heavy
          // descent (also unlikely as overall average).
          if (consumption > 2 && consumption < 100) {
            final now = DateTime.now();
            _consumptionWindow.add((now, consumption));
            // Prune old samples beyond the window.
            final cutoff = now.subtract(_consumptionWindowDuration);
            _consumptionWindow.removeWhere((e) => e.$1.isBefore(cutoff));
          }
        }
      }
    }

    // TODO: peakRegenKw + regenEnergyKwh once regen DID identified
  }

  /// v0.1.9: write a snapshot of current state to DB if enough time has passed.
  ///
  /// Cadence:
  ///   - 2 minutes when a trip is active (denser to capture trip shape)
  ///   - 10 minutes when not in a trip (light coverage for "weekly trends")
  ///
  /// All snapshot fields are nullable — if a DID isn't readable right now,
  /// it's saved as null and the chart will just have a gap. Better than
  /// inserting garbage.
  Future<void> _maybeWriteSnapshot() async {
    final now = DateTime.now();
    final interval = _currentTripId != null
        ? _snapshotIntervalInTrip
        : _snapshotIntervalIdle;
    if (_lastSnapshotAt != null && now.difference(_lastSnapshotAt!) < interval) {
      return;
    }
    _lastSnapshotAt = now;

    final soc = readNumeric('790', '0005');
    final soh = readNumeric('790', '0029');
    // v0.1.10 hotfix: registry already applies offset -40 — don't subtract again.
    final tempC = readNumeric('790', '002F');
    final cellMin = globalMinCellMv?.toDouble();
    final cellMax = globalMaxCellMv?.toDouble();
    final spread = (cellMin != null && cellMax != null) ? (cellMax - cellMin) : null;
    final odo = readNumeric('791', '0026');
    // v0.1.29+2: snapshot column `packVoltageV` now stores sum-of-cells
    // (the only physically-correct pack V we have). The historical content
    // of that column was 740/0x0022 = ~450V platform constant — visible in
    // 100% of AC session 2026-05-23 snapshots as garbage. We do NOT touch
    // existing rows; new writes are honest sum-of-cells, or null when cells
    // haven't been polled yet. hvBusV column unchanged.
    final packLive = packVoltageFromCells;
    final hvBus = hvBusV;
    final gearRaw = readNumeric('791', '0009');
    final gear = gearRaw?.toInt();
    final pawl = parkingPawlEngaged;
    final cycles = readNumeric('790', '0B02')?.toInt();

    try {
      await db.insertSnapshot(SnapshotsCompanion(
        capturedAt: Value(now),
        soc: Value(soc),
        soh: Value(soh),
        batteryTempC: Value(tempC),
        cellVoltageMin: Value(cellMin),
        cellVoltageMax: Value(cellMax),
        cellSpread: Value(spread),
        odometer: Value(odo),
        tripId: Value(_currentTripId),
        packVoltageV: Value(packLive),
        hvBusV: Value(hvBus),
        gear: Value(gear),
        pawlEngaged: Value(pawl),
        isCharging: Value(isCharging),
        chargingPowerKw: Value(chargingPowerKw),
        cycleCount: Value(cycles),
      ));
    } catch (e) {
      debugPrint('Snapshot write failed: $e');
    }
  }

  /// v0.1.26+11: обновление истории 0x0B00 (для charging detection)
  /// + maintenance _chargingHistory (для UI графиков).
  ///
  /// Counter-based power calculation REMOVED in v0.1.26+11. Empirical
  /// testing on 5-minute AC 2.85 kW session (livelog 22) showed counter
  /// is a nonlinear OBC state-machine event signal, not an energy
  /// integrator. See [Bz5Model.chargeCounterWh] doc for full evidence.
  /// Power is now derived from SOC rate of change in [chargingPowerKw]
  /// getter — accurate but slower (~80 sec refresh at AC 3 kW, ~2 sec
  /// at DC 100 kW).
  ///
  /// 0B00 counter still gets sampled here because it remains useful for:
  ///   - Charging detection (rate > 0 vs stable-in-idle) — see [isCharging]
  ///   - Future analysis when we identify what events it actually counts
  void _updatePowerCalculations() {
    final now = DateTime.now();
    final b00 = readNumeric('790', '0B00');
    if (b00 == null) return;
    final b00Int = b00.toInt();

    // Trip start anchor
    _tripStartB00 ??= b00Int;

    // Append to history if value changed OR enough time passed since last snapshot.
    final shouldAppend = _b00History.isEmpty
        || _b00History.last.value != b00Int
        || now.difference(_b00History.last.time) >= _b00FlatSampleInterval;
    if (shouldAppend) {
      _b00History.add(_B00Sample(now, b00Int));
    }

    // Trim entries older than maxAge (keep at least 1 to anchor the window).
    final cutoff = now.subtract(_b00HistoryMaxAge);
    while (_b00History.length > 1 && _b00History.first.time.isBefore(cutoff)) {
      _b00History.removeAt(0);
    }

    // Clear legacy cached value — chargingPowerKw getter now computes fresh.
    _instantaneousChargingPowerKw = 0.0;

    // v0.1.26: maintain rolling-window charging history for the
    // ChargingViewWide widget. Read isCharging via the getter so this
    // sees the same monotone-growth verdict as the rest of the app.
    _maintainChargingHistory(now, b00Int);
  }

  /// v0.1.26: append/trim _chargingHistory based on the current charging
  /// state. Called once per [_updatePowerCalculations] cycle.
  ///
  /// Behaviour:
  ///   - charging→idle transition: clear history + session anchors.
  ///   - idle→charging transition: capture session anchors (start time,
  ///     start SOC, start counter) for ETA / charged-so-far derivation.
  ///   - charging continues: append a [ChargingSample] every
  ///     [_chargingHistoryInterval] seconds; trim entries older than
  ///     [_chargingHistoryMaxAge].
  ///
  /// Note: isCharging is itself a getter that walks _b00History, so we
  /// call it once and cache. No-op if not charging and never was — the
  /// common case during driving / parking.
  void _maintainChargingHistory(DateTime now, int currentCounter) {
    final charging = isCharging;

    if (!charging) {
      if (_wasCharging) {
        // Session just ended — clear so the next session starts fresh.
        _chargingHistory.clear();
        _lastChargingSampleAt = null;
        _chargingSessionStartedAt = null;
        _chargingSessionStartCounter = null;
        _chargingSessionStartSocPct = null;
        _wasCharging = false;
      }
      return;
    }

    if (!_wasCharging) {
      // Just transitioned into charging — anchor session metadata.
      _chargingSessionStartedAt = now;
      _chargingSessionStartCounter = currentCounter;
      _chargingSessionStartSocPct = socPrecisePct ?? readNumeric('790', '0005');
      _wasCharging = true;
    }

    // Throttle samples to _chargingHistoryInterval.
    if (_lastChargingSampleAt != null &&
        now.difference(_lastChargingSampleAt!) < _chargingHistoryInterval) {
      return;
    }
    _lastChargingSampleAt = now;

    // v0.1.26+11: power is now SOC-derived via the chargingPowerKw getter,
    // which walks the EXISTING _chargingHistory window — but we're about
    // to append a new sample to that window. To avoid the getter using
    // the not-yet-added sample as anchor (latest), compute power BEFORE
    // append and treat 0/null as "still warming up" for early samples.
    final currentSoc = socPrecisePct ?? readNumeric('790', '0005');
    double? powerForSample;
    if (_chargingHistory.length >= 2 && currentSoc != null) {
      // Look back up to 60 sec for SOC delta
      final cutoffTime = now.subtract(const Duration(seconds: 60));
      ChargingSample? anchor;
      for (final s in _chargingHistory) {
        if (s.time.isBefore(cutoffTime)) continue;
        if (s.socPct == null) continue;
        if (s.socPct! < currentSoc) {
          anchor = s;
          break;
        }
      }
      if (anchor != null) {
        final dtSec = now.difference(anchor.time).inMilliseconds / 1000.0;
        final dSoc = currentSoc - (anchor.socPct ?? currentSoc);
        if (dtSec >= 1.0 && dSoc > 0) {
          powerForSample = dSoc * Bz5Model.batteryCapacityKwh * 36.0 / dtSec;
        }
      }
    }

    _chargingHistory.add(ChargingSample(
      time: now,
      powerKw: powerForSample,
      socPct: currentSoc,
      hvBusV: hvBusV,
      cellMinMv: globalMinCellMv,
      cellMaxMv: globalMaxCellMv,
      tempC: readNumeric('790', '002F'),
      counter: currentCounter,
    ));

    // Trim by age.
    final cutoff = now.subtract(_chargingHistoryMaxAge);
    while (_chargingHistory.isNotEmpty &&
        _chargingHistory.first.time.isBefore(cutoff)) {
      _chargingHistory.removeAt(0);
    }
  }

  Future<void> _pollEcu(EcuSpec ecu) async {
    if (_client == null) return;

    for (final spec in ecu.dids) {
      if (spec.category == DidCategory.cells) continue;
      // v0.1.26+6: skip 740/0x0008 here — it's polled exclusively by
      // _pollSpeedOnly (sub-poll between ECU iterations). Polling it
      // here too creates a race: _pollSpeedOnly writes a real kmh into
      // _latestValues, then this _pollEcu iteration overwrites with
      // whatever the next BLE read returns — and in trips 11/12 of the
      // 2026-05-19 export, every sample written here was raw 0x0000
      // while concurrent livelog reads on the same DID showed varied
      // non-zero values. Letting only _pollSpeedOnly own 0008 cuts
      // the contention and makes trip_aggregates see real speed.
      if (ecu.txId == '740' && spec.did == '0008') continue;

      // v0.1.29+39: skip 790/0x0009 (pack current) here for the SAME
      // reason as 740/0008 above. It's read by the fast-lane current
      // sub-poll (_pollFastLane) with the proper offset-signed decode
      // ((raw - zeroRaw) * ampsPerLsb → real amps). The generic path
      // here decodes it via the registry DidSpec, which has no scale/
      // offset, so it writes the RAW counts (~5023) into the same
      // 790/0009 sample stream as if they were amps. Export 2026-06-01
      // showed ~15% of 790/0009 samples were these raw values (5010-6700)
      // mixed in with real amps (~11) — the source of the dashboard
      // flicker/dashes and the absurd multi-thousand-kW power spikes.
      // Let the fast-lane own 0009 exclusively, exactly as _pollSpeedOnly
      // owns 0008.
      if (ecu.txId == '790' && spec.did == '0009') continue;

      try {
        final r = await _client!.readDid(spec.did, tx: ecu.txId, rx: ecu.rxId)
            .timeout(const Duration(milliseconds: 1500));
        if (r == null || !r.isPositive) continue;

        final payload = r.payloadAfterUdsRead;
        if (payload == null) continue;

        final decoded = decodeDid(spec, payload);
        if (decoded == null) continue;

        _latestValues.putIfAbsent(ecu.txId, () => {})[spec.did] = decoded;

        if (_currentTripId != null) {
          await db.insertSample(
            tripId: _currentTripId,
            ecuTx: ecu.txId,
            did: spec.did,
            rawHex: r.rawHex,
            numeric: decoded.numeric,
            text: decoded.text,
          );
          _samplesInTrip++;

          if (spec.did == '0005' && ecu.txId == '790' && _tripStartSoc == null) {
            _tripStartSoc = decoded.numeric;
            // v0.1.26+8: backfill DB row too (in-memory only would mean
            // the column stays NULL on disk).
            if (decoded.numeric != null) {
              await db.updateTripStartAnchors(
                _currentTripId!,
                startSoc: decoded.numeric,
              );
            }
          }
          if (spec.did == '0026' && ecu.txId == '791' && _tripStartOdo == null) {
            _tripStartOdo = decoded.numeric;
            if (decoded.numeric != null) {
              await db.updateTripStartAnchors(
                _currentTripId!,
                startOdo: decoded.numeric,
              );
            }
          }
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  static const _cellDids = [
    '016D','016F','0175','0177','017D','017F','0185','0187',
    '018D','018F','0195','0197','019D','019F',
    '01A5','01A7','01AD','01AF','01B5','01B7',
  ];

  Future<void> _pollCells() async {
    if (_client == null) return;
    final cells = <int>[];
    for (final did in _cellDids) {
      try {
        final r = await _client!.readDid(did, tx: '790', rx: '798')
            .timeout(const Duration(milliseconds: 1000));
        final p = r?.payloadAfterUdsRead;
        if (p != null && p.length >= 2) {
          cells.add((p[0] << 8) | p[1]);
        }
      } catch (_) {}
    }
    if (cells.isNotEmpty) {
      _liveCells = cells;
      final spread = cells.reduce((a, b) => a > b ? a : b)
                   - cells.reduce((a, b) => a < b ? a : b);
      _cellSpreadHistory.add(spread);
      while (_cellSpreadHistory.length > _cellSpreadHistoryMax) {
        _cellSpreadHistory.removeAt(0);
      }
      notifyListeners();
    }
  }

  /// v0.1.3: poll DID-ов которые не входят в EcuSpec реестр.
  ///
  /// Эти DID-ы найдены реверсом 2026-05-03 и пока не оформлены в registry —
  /// читаем напрямую тут. Позже стоит вынести в registry, но пока проще
  /// держать в одном месте чтобы не терять при пересборке проекта.
  ///
  /// Стратегия:
  ///  - 740/0x0022 и 740/0x0014 (pack voltage) — поллим каждый цикл,
  ///    нужны для realtime отображения.
  ///  - 790/0x002C и 790/0x002E (cell min/max indices) — каждый цикл,
  ///    используются на Cells screen.
  ///  - 790/0x0B03 и 790/0x0A07 (cell count, module count) — статичны,
  ///    поллим один раз при первом успехе и больше не повторяем.
  Future<void> _pollExtraDids() async {
    if (_client == null) return;

    // Pack voltage filtered (740/0x0022, ×0.025 V, sanity 350-550)
    try {
      final r = await _client!.readDid('0022', tx: '740', rx: '748')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final raw = (p[0] << 8) | p[1];
        _packVoltageFilteredV = raw * 0.025;
      }
    } catch (_) {}

    // Pack voltage instant (740/0x0014)
    try {
      final r = await _client!.readDid('0014', tx: '740', rx: '748')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final raw = (p[0] << 8) | p[1];
        _packVoltageInstantV = raw * 0.025;
      }
    } catch (_) {}

    // Global min cell index (790/0x002C). Sanity 0..253 — 0xFF reserved as
    // "no data" by BMS firmware convention. valid pack indices are 0..135
    // (we have 136 cells), но запас на случай если позже найдём что
    // BMS считает где-то с 1.
    try {
      final r = await _client!.readDid('002C', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.isNotEmpty && p[0] < 0xFE) {
        _globalMinCellIndex = p[0];
      }
    } catch (_) {}

    // Global max cell index (790/0x002E). Same sanity as above.
    try {
      final r = await _client!.readDid('002E', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.isNotEmpty && p[0] < 0xFE) {
        _globalMaxCellIndex = p[0];
      }
    } catch (_) {}

    // v0.1.6: Global min cell voltage (790/0x002B, 2 bytes big-endian, mV).
    // Despite being in the registry, this DID falls through cracks of the
    // poll loop — registry _pollEcu skips category=cells, _pollCells reads
    // only the per-module array. Read directly here so Pack Extremes works.
    //
    // v0.1.20: read min/max into locals and commit AS A PAIR only if pair
    // passes cross-validation. Without this guard ~3.6% of driving samples
    // get a max<min or |spread|>100mV due to ELM stream misalignment that
    // the v0.1.16 frame check doesn't fully catch. Previously this leaked
    // into snapshots (visible: 2026-05-18 snapshot id=26 spread=-2 mV).
    int? candidateMin;
    int? candidateMax;

    try {
      final r = await _client!.readDid('002B', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final mv = (p[0] << 8) | p[1];
        // Sanity: realistic LFP cell range 2000..3700 mV
        if (mv >= 2000 && mv <= 3700) candidateMin = mv;
      }
    } catch (_) {}

    // v0.1.6: Global max cell voltage (790/0x002D).
    try {
      final r = await _client!.readDid('002D', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final mv = (p[0] << 8) | p[1];
        if (mv >= 2000 && mv <= 3700) candidateMax = mv;
      }
    } catch (_) {}

    // v0.1.20: pair-level sanity guard. Commit only if both came back and
    // the pair makes physical sense. Otherwise drop both, keep previous
    // values so UI shows last-known-good instead of a momentary glitch.
    //
    // Drop conditions:
    //   - max < min (impossible by definition)
    //   - |spread| > 100 mV (LFP packs at any health typically <50 mV
    //     spread; >100 mV indicates a parsing artifact, not real data)
    //
    // If only one of the two reads succeeded, commit it solo — half a
    // sample is better than no sample, and the next cycle will get the
    // other half. This keeps the guard from masking a genuine BLE flake.
    if (candidateMin != null && candidateMax != null) {
      final spread = candidateMax - candidateMin;
      if (spread < 0 || spread.abs() > 100) {
        _cellPairDropCount++;
        // Don't overwrite known-good values
      } else {
        _globalMinCellMv = candidateMin;
        _globalMaxCellMv = candidateMax;
      }
    } else {
      if (candidateMin != null) _globalMinCellMv = candidateMin;
      if (candidateMax != null) _globalMaxCellMv = candidateMax;
    }

    // Note (v0.1.8): 790/0x0015 (HV bus voltage) is now read through the
    // normal _pollEcu loop — registry scale corrected to 0.025 in this
    // release. UI accesses it via the hvBusV getter which uses readNumeric.
    // No direct read here anymore.

    // Pack config — читаем один раз
    if (_packCellCount == null) {
      try {
        final r = await _client!.readDid('0B03', tx: '790', rx: '798')
            .timeout(const Duration(milliseconds: 1000));
        final p = r?.payloadAfterUdsRead;
        if (p != null && p.isNotEmpty && p[0] != 0xFF && p[0] != 0) {
          _packCellCount = p[0];
        }
      } catch (_) {}
    }
    if (_packModuleCount == null) {
      try {
        final r = await _client!.readDid('0A07', tx: '790', rx: '798')
            .timeout(const Duration(milliseconds: 1000));
        final p = r?.payloadAfterUdsRead;
        if (p != null && p.isNotEmpty && p[0] != 0xFF && p[0] != 0) {
          _packModuleCount = p[0];
        }
      } catch (_) {}
    }

    // Note (v0.1.21): 790/0x1FFD (precise SOC) and 740/0x0008 (vehicle
    // speed) are read through the normal _pollEcu loop because they
    // were added to the registry with categories `soc` and `dynamic`.
    // Their decoders (in ecu_registry.dart::decodeDid) handle the
    // unusual scales (high16/100 for 1FFD, raw/14.09 for speed).
    // Access via socPrecisePct and vehicleSpeedKmh getters which
    // look up _latestValues.

    notifyListeners();
  }

  double? readNumeric(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.numeric;

  String? readText(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.text;

  /// v0.1.26+17: hysteresis state for [isCharging]. Holds the last
  /// reported value plus a counter of consecutive "off" detections.
  /// Flips back to false only after [_chargingHysteresisOffThreshold]
  /// consecutive negative checks in a row.
  bool _isChargingHysteretic = false;
  int _isChargingConsecutiveOff = 0;
  static const int _chargingHysteresisOffThreshold = 3;

  /// v6.1 / v0.1.26+3: Детекция зарядки через rolling-window анализ 0x0B00.
  ///
  /// Two-track:
  ///   • fast path — 60-секундное окно с ≥3 положительными increment'ами
  ///     без единого отрицательного delta. Срабатывает только при
  ///     rate ≥ 83 кВт (только DC fast-charging).
  ///   • slow path — 10-минутное окно с net delta ≥2 и без отрицательных
  ///     delta. Срабатывает на DC <80 кВт и AC 7+ кВт.
  ///
  /// isCharging = _isChargingFast() || _isChargingSlow()
  ///
  /// Калибровка на реальных idle-данных (см. описание _b00History):
  ///  - Машина выключена, парковка: counter монотонно убывает; даже если
  ///    бы не убывал, отсутствие положительных delta даст false.
  ///  - Машина в Ready+AC: counter колеблется ±1 around point; за 10 мин
  ///    окна в среднем 6–7 delta, шанс что все положительные ≈ 3%
  ///    (приемлемый false-positive). Fast path при этом не срабатывает,
  ///    так как rate шума ~1 delta / 90 sec — нельзя получить 3 inc /
  ///    60 sec без отрицательных.
  ///  - На зарядке любой мощности: counter растёт строго монотонно.
  ///    DC ≥80 кВт ловится fast path'ом за 30–60 сек. AC и слабый DC —
  ///    slow path'ом за 3–10 мин.
  ///
  /// Latency:
  ///   • DC ≥80 кВт:    30–60 сек
  ///   • AC 7–22 кВт:   3–10 мин (slow path, 10-мин окно)
  ///   • AC 2.8 кВт:    ~20 мин (известный edge-case с v6.1)
  ///
  /// v0.1.26+17: hysteresis on the OFF transition. Field test showed
  /// the "CHARGING" label flickering off and on intermittently during
  /// a steady 2.4 kW AC session — likely the slow path momentarily
  /// dipping below its threshold when the 10-min window's anchor and
  /// head samples briefly tie. With hysteresis we require 3 consecutive
  /// off detections (each runs ~1× per poll cycle ≈ 1 sec) to genuinely
  /// flip OFF. Latency on the ON side is unchanged.
  bool get isCharging {
    final raw = _isChargingFast() || _isChargingSlow();
    if (raw) {
      _isChargingHysteretic = true;
      _isChargingConsecutiveOff = 0;
    } else if (_isChargingHysteretic) {
      _isChargingConsecutiveOff++;
      if (_isChargingConsecutiveOff >= _chargingHysteresisOffThreshold) {
        _isChargingHysteretic = false;
      }
    }
    return _isChargingHysteretic;
  }

  /// Fast-path detection — DC ≥80 кВт.
  ///
  /// Проверяет последние 60 секунд:
  ///   1. Есть ≥4 samples в окне (даёт ≥3 transitions для подсчёта).
  ///   2. Все consecutive delta non-negative — любой −1 даёт false.
  ///   3. Количество положительных transition'ов ≥3.
  ///
  /// Math gate: 3 inc / 60 сек = ≥1 unit / 20 сек = ≥83 кВт. Никакая AC
  /// и никакой шум counter в Ready+AC такого rate не достигают.
  bool _isChargingFast() {
    if (_b00History.length < 4) return false;

    final now = DateTime.now();
    final windowStart = now.subtract(_chargingDetectionFastWindow);

    // Filter samples within fast window. We don't require full window
    // coverage — fast path is forgiving on cold-start: as long as ≥4
    // samples landed in last 60s with the right shape, accept.
    final inWindow = <_B00Sample>[];
    for (final s in _b00History) {
      if (!s.time.isBefore(windowStart)) inWindow.add(s);
    }
    if (inWindow.length < 4) return false;

    int positiveTransitions = 0;
    for (int i = 1; i < inWindow.length; i++) {
      final delta = inWindow[i].value - inWindow[i - 1].value;
      if (delta < 0) return false; // any negative kills the signal
      if (delta > 0) positiveTransitions++;
    }
    return positiveTransitions >= _chargingDetectionFastMinPositiveTransitions;
  }

  /// Slow-path detection — AC 7+ кВт и слабый DC.
  ///
  /// Требует полное окно истории (10 мин) и проверяет:
  ///   1. Net growth от анкора (sample at-or-before windowStart) до now
  ///      ≥ [_chargingDetectionMinNetDelta] (2 units).
  ///   2. Нет ни одного отрицательного delta в окне.
  bool _isChargingSlow() {
    if (_b00History.length < 2) return false;

    final now = DateTime.now();
    final windowStart = now.subtract(_chargingDetectionSlowWindow);

    // Need history covering the entire window. If oldest sample is
    // younger than windowStart, we just started polling — wait.
    if (_b00History.first.time.isAfter(windowStart)) return false;

    // Find anchor value: last sample at or before windowStart.
    int? anchorValue;
    for (int i = _b00History.length - 1; i >= 0; i--) {
      if (!_b00History[i].time.isAfter(windowStart)) {
        anchorValue = _b00History[i].value;
        break;
      }
    }
    if (anchorValue == null) return false;

    final currentValue = _b00History.last.value;
    final netGrowth = currentValue - anchorValue;
    if (netGrowth < _chargingDetectionMinNetDelta) return false;

    // Verify monotone: no negative transitions inside the window.
    // (Glitches tend to be paired +1/-1, so any -1 means not real charging.)
    for (int i = 1; i < _b00History.length; i++) {
      final ev = _b00History[i];
      if (ev.time.isBefore(windowStart)) continue;
      final prev = _b00History[i - 1];
      if (ev.value < prev.value) return false;
    }

    return true;
  }

  // ──────────────── v0.1.26: Charging Companion getters ─────────────────

  /// Read-only view of recent charging samples (rolling window, last
  /// [_chargingHistoryMaxAge]). Empty list when not charging.
  List<ChargingSample> get chargingHistory =>
      List<ChargingSample>.unmodifiable(_chargingHistory);

  /// Wall-clock time the current charging session started, or null if
  /// not currently charging.
  DateTime? get chargingSessionStartedAt => _chargingSessionStartedAt;

  /// Energy delivered since the start of the current charging session,
  /// in kWh.
  ///
  /// v0.1.26+11: Computed from ΔSOC × pack capacity, NOT from the
  /// 0x0B00 counter (which was empirically shown to be a non-linear
  /// event counter, not an energy integrator — see [Bz5Model.chargeCounterWh]
  /// deprecation doc for evidence).
  ///
  /// Precision floor: 1FFD precise SOC has 0.01% resolution → 6.528 Wh
  /// per minimum step at 65.28 kWh pack. Below that resolution the
  /// reading shows zero gain even when energy is actually flowing.
  /// At AC 3 kW this means first non-zero reading appears ~8 sec after
  /// charging started; at DC 100 kW ~0.2 sec.
  ///
  /// Returns null when not in a charging session, or session anchor
  /// (start SOC) is missing, or current SOC reading is unavailable.
  double? get chargedThisChargingSessionKwh {
    if (_chargingSessionStartSocPct == null) return null;
    final cur = socPrecisePct ?? readNumeric('790', '0005');
    if (cur == null) return null;
    final deltaPct = cur - _chargingSessionStartSocPct!;
    if (deltaPct <= 0) return null;
    return deltaPct * Bz5Model.batteryCapacityKwh / 100.0;
  }

  /// SOC delta since the start of the current charging session, %.
  /// Uses precise SOC (790/0x1FFD) when available, else integer SOC.
  double? get socGainedThisChargingSessionPct {
    if (_chargingSessionStartSocPct == null) return null;
    final cur = socPrecisePct ?? readNumeric('790', '0005');
    if (cur == null) return null;
    final delta = cur - _chargingSessionStartSocPct!;
    if (delta <= 0) return null;
    return delta;
  }

  /// Phase of the active charging session based on max cell V and power.
  ///
  /// Heuristic (no manufacturer reference available — pure BYD Blade LFP
  /// behaviour from public data):
  ///   - max cell V < 3.40 V → CC phase (constant current, cells still
  ///     have headroom; power is whatever the station/OBC is delivering)
  ///   - max cell V ≥ 3.40 V AND power tapering (latest sample less than
  ///     80% of recent peak) → CV phase
  ///   - SOC ≥ 95% OR power < 3 kW → almostDone
  ///   - not enough data yet → unknown
  ///
  /// 3.40 V cut-off corresponds to roughly 95% SOC on a flat LFP curve;
  /// 3.45 V would also work but might miss the transition on a cool pack.
  ChargingPhase get chargingPhase {
    if (!isCharging) return ChargingPhase.unknown;
    if (_chargingHistory.length < 3) return ChargingPhase.unknown;

    final soc = socPrecisePct ?? readNumeric('790', '0005');
    // v0.1.26+11: use SOC-derived power (single source of truth)
    // instead of the deprecated _instantaneousChargingPowerKw cache.
    final powerKw = chargingPowerKw;
    final maxCellMv = globalMaxCellMv;

    if ((soc != null && soc >= 95) || (powerKw > 0 && powerKw < 3.0)) {
      return ChargingPhase.almostDone;
    }
    if (maxCellMv != null && maxCellMv >= 3400) {
      // Check tapering — recent power below 80% of peak in history.
      double peak = 0;
      for (final s in _chargingHistory) {
        final p = s.powerKw ?? 0;
        if (p > peak) peak = p;
      }
      if (peak > 0 && powerKw < peak * 0.8) return ChargingPhase.cv;
    }
    return ChargingPhase.cc;
  }

  /// ETA to 100% SOC in seconds, or null if the rate of SOC change can't
  /// be confidently extrapolated yet (too few samples, or SOC not rising).
  ///
  /// Uses simple linear regression on the last ~5 minutes of SOC samples
  /// in [_chargingHistory]. Falls back to null on degenerate input.
  ///
  /// CAVEAT: linear extrapolation overestimates remaining time in the CV
  /// taper region — real SOC vs time on LFP starts to curve below ~95%
  /// as current drops. UI labels this ETA as "~minutes" rather than
  /// pretending to be precise.
  int? get etaToFullSeconds {
    if (_chargingHistory.length < 6) return null;
    final soc = socPrecisePct ?? readNumeric('790', '0005');
    if (soc == null || soc >= 99.9) return null;

    // Use last 5 minutes of samples.
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final recent =
        _chargingHistory.where((s) => s.time.isAfter(cutoff) && s.socPct != null).toList();
    if (recent.length < 4) return null;

    final first = recent.first;
    final last = recent.last;
    final socDelta = (last.socPct ?? 0) - (first.socPct ?? 0);
    final dtSec = last.time.difference(first.time).inSeconds.toDouble();
    if (dtSec < 30 || socDelta <= 0.05) return null;

    final ratePctPerSec = socDelta / dtSec;
    final remainingPct = 100.0 - soc;
    return (remainingPct / ratePctPerSec).round();
  }

  /// v0.1.26: take a manual point-in-time snapshot of key BMS/VCU values
  /// into both the DB Snapshots table and a returned map (for clipboard
  /// JSON paste-into-notes). Bypasses the throttle that
  /// [_maybeWriteSnapshot] enforces — this is user-triggered, not
  /// time-based, so always writes.
  ///
  /// Returns the captured map even on DB failure, so the UI can still
  /// copy-to-clipboard. The map's keys are stable identifiers safe to
  /// grep in saved notes later.
  Future<Map<String, dynamic>> captureSnapshot() async {
    final now = DateTime.now();
    final soc = readNumeric('790', '0005');
    final socPrecise = socPrecisePct;
    final soh = readNumeric('790', '0029');
    final tempC = readNumeric('790', '002F');
    final cellMin = globalMinCellMv;
    final cellMax = globalMaxCellMv;
    final spread = (cellMin != null && cellMax != null)
        ? (cellMax - cellMin)
        : null;
    final odo = readNumeric('791', '0026');
    // v0.1.29+2: see [_maybeWriteSnapshot] for rationale. We keep both
    // `pack_v_nominal` (legacy 740/0x0022 constant) and `pack_v_live`
    // (sum-of-cells) in the clipboard/diag map for debug traceability;
    // the DB column gets the live value only.
    final packV = packVoltageV;
    final packLive = packVoltageFromCells;
    final hvBus = hvBusV;
    final gearRaw = readNumeric('791', '0009');
    final gear = gearRaw?.toInt();
    final pawl = parkingPawlEngaged;
    final cycles = readNumeric('790', '0B02')?.toInt();
    final counter = readNumeric('790', '0B00')?.toInt();
    final charging = isCharging;
    final chargingKw = chargingPowerKw;

    final map = <String, dynamic>{
      'capturedAt': now.toIso8601String(),
      'soc_pct': soc,
      'soc_precise_pct': socPrecise,
      'soh_pct': soh,
      'battery_temp_c': tempC,
      'cell_min_mv': cellMin,
      'cell_max_mv': cellMax,
      'cell_spread_mv': spread,
      'pack_v_nominal': packV,
      'pack_v_live': packLive,
      'hv_bus_v': hvBus,
      'charge_counter_raw_0B00': counter,
      'cycle_count_raw_0B02': cycles,
      'odometer_km': odo,
      'gear_raw_0009': gear,
      'pawl_engaged': pawl,
      'is_charging': charging,
      'charging_power_kw': chargingKw,
    };

    try {
      await db.insertSnapshot(SnapshotsCompanion(
        capturedAt: Value(now),
        soc: Value(soc),
        soh: Value(soh),
        batteryTempC: Value(tempC),
        cellVoltageMin: Value(cellMin?.toDouble()),
        cellVoltageMax: Value(cellMax?.toDouble()),
        cellSpread: Value(spread?.toDouble()),
        odometer: Value(odo),
        tripId: Value(_currentTripId),
        packVoltageV: Value(packLive),
        hvBusV: Value(hvBus),
        gear: Value(gear),
        pawlEngaged: Value(pawl),
        isCharging: Value(charging),
        chargingPowerKw: Value(chargingKw),
        cycleCount: Value(cycles),
      ));
    } catch (e) {
      debugPrint('Manual snapshot write failed: $e');
    }
    return map;
  }

  // ──────────────────────────── DTC scanning ─────────────────────────────
  //
  // v0.1.7: in-app DTC reader.
  // Walks 9 known ECUs (790, 791, 740, 744, 745, 752, 753, 782, 757),
  // enters extended diag session 1003, sends UDS service 0x19 sub 0x02
  // with two status masks (0x09 = active+confirmed, 0xFF = all DTCs).
  // Decodes 4-byte (3-byte code + 1-byte status) DTC records per SAE J2012.
  //
  // No write/clear operations — read-only by design (v0.1.7 scope).
  // Returns immutable snapshot for UI to display.

  static const _dtcEcus = [
    ('790', '798', 'BMS Master'),
    ('791', '799', 'VCU'),
    ('740', '748', 'PDU/HV Junction'),
    ('744', '74C', 'PDU 2'),
    ('745', '74D', 'PDU 3'),
    ('752', '75A', 'BMS Slave 1'),
    ('753', '75B', 'BMS Slave 2'),
    ('782', '78A', 'OBC'),
    ('757', '75F', 'GPS Asensing'),
  ];

  bool _dtcScanRunning = false;
  bool get dtcScanRunning => _dtcScanRunning;

  // ─────────────────────── v0.1.14: in-car DID sweep ─────────────────────
  //
  // Probes a range of DIDs on a given ECU and records each (DID, raw response)
  // tuple into SweepRuns + SweepResults DB tables. Pauses normal polling
  // for the duration. Cancellable mid-flight.
  //
  // Architecture mirrors runDtcScan:
  //   - one sweep at a time (gated by _sweepRunning)
  //   - cancellation via flag (_sweepCancelled) checked in the loop
  //   - progress callback fired on each probe for UI bar
  //   - results streamed to DB as we go (so cancel still keeps partial data)
  //
  // Per spec, sweep works in any car state (gear/Ready/etc.) — caller is
  // responsible for handing the device to a passenger if running in motion.

  bool _sweepRunning = false;
  bool _sweepCancelled = false;
  int? _currentSweepRunId;
  int _sweepDone = 0;
  int _sweepTotal = 0;
  String _sweepCurrentDid = '';

  /// v0.1.29+24: hard-kill signal for the sweep loop. Same pattern as
  /// [_liveLogKillSignal] (added in +22). Completed when the loop must
  /// abort immediately (cancel command, watchdog stall, BLE drop).
  /// Future.any races inside the loop body resolve the instant this
  /// fires, regardless of whether the underlying op (readDid, insert,
  /// delay) has completed. Cycle 9 (Motor1 sweep, 2026-05-25) proved
  /// that sweep is vulnerable to the same flutter_blue_plus
  /// _writeChar.write() platform-layer wedge that froze live-log in
  /// Cycles 2/3 — observed twice on identical NRC streams ($01
  /// GeneralReject), at probes 77 and 241 respectively.
  Completer<void>? _sweepKillSignal;

  /// v0.1.29+24: periodic watchdog mirroring [_liveLogWatchdogTimer].
  /// Fires kill signal if no sweep_result row has been written for
  /// 30+ seconds. Runs as a Timer.periodic, so it stays scheduled
  /// even when the loop coroutine is wedged on a BLE await (the
  /// failure mode we're defending against).
  Timer? _sweepWatchdogTimer;

  /// v0.1.29+24: wall-clock of last sweep_result successfully written.
  /// Watchdog input; null between sweeps.
  DateTime? _sweepLastProbeAt;

  /// v0.1.29+24: last reason the sweep loop broke. Surfaces in
  /// sweep_runs.notes for post-mortem (matches runLiveLog +21/+22
  /// convention). One of: completed / cancelled / max_duration /
  /// ble_dropped / watchdog_stall / loop_exception.
  String? _sweepExitReason;

  bool get sweepRunning => _sweepRunning;
  int? get currentSweepRunId => _currentSweepRunId;
  int get sweepDone => _sweepDone;
  int get sweepTotal => _sweepTotal;
  String get sweepCurrentDid => _sweepCurrentDid;
  double get sweepProgress =>
      _sweepTotal > 0 ? _sweepDone / _sweepTotal : 0.0;

  // ────── v0.1.29+28: CAN passive-monitor state ──────
  //
  // Mutually exclusive with sweep / livelog / DTC scan (single BLE channel).
  // Independent of all three otherwise: own kill-signal, own watchdog, own
  // DB tables. Failure modes are different from UDS modes — there's no
  // probe-by-probe progress, just a stream of frames over a fixed duration.
  // Watchdog here detects "adapter went silent" (no frames for N seconds
  // in a row) rather than "no DB writes".
  bool _canMonitorRunning = false;
  bool _canMonitorCancelled = false;
  int? _currentCanMonitorSessionId;
  int _canFrameCount = 0;
  final Set<String> _canSeenIds = {};
  DateTime? _canMonitorLastFrameAt;
  String? _canMonitorExitReason;
  Completer<void>? _canMonitorKillSignal;
  Timer? _canMonitorWatchdogTimer;

  bool get canMonitorRunning => _canMonitorRunning;
  int? get currentCanMonitorSessionId => _currentCanMonitorSessionId;
  int get canFrameCount => _canFrameCount;
  int get canUniqueIdCount => _canSeenIds.length;

  /// Cancel the active CAN monitor session. Loop exits at next event
  /// boundary (typically <100ms after this call). Fires kill signal so
  /// the duration-sleep and any in-flight BLE await return immediately,
  /// mirroring +22/+24 livelog/sweep cancel semantics.
  void cancelCanMonitor() {
    if (_canMonitorRunning) {
      _canMonitorCancelled = true;
      final ks = _canMonitorKillSignal;
      if (ks != null && !ks.isCompleted) ks.complete();
    }
  }

  /// Cancel an in-progress sweep. Safe to call even if no sweep is running.
  /// The sweep loop checks this flag between DIDs, so cancellation takes
  /// effect within ~one probe period (default 250ms).
  ///
  /// v0.1.29+24: also fires the kill signal so any in-flight await
  /// inside the loop (readDid, DB insert, inter-probe delay) returns
  /// immediately instead of waiting for its own timeout. Stop commands
  /// against a wedged sweep now react in milliseconds rather than
  /// staying stuck — the failure mode observed in Cycle 9.
  void cancelSweep() {
    if (_sweepRunning) {
      _sweepCancelled = true;
      final ks = _sweepKillSignal;
      if (ks != null && !ks.isCompleted) ks.complete();
    }
  }

  /// Run a DID sweep over [startDid] .. [endDid] (inclusive, hex strings
  /// like "0000".."1FFF") on the given ECU. Returns the SweepRun id created
  /// in DB so the caller can navigate to results.
  ///
  /// Results stream to SweepResults table as we go — useful if cancelled
  /// midway. SweepRun.endedAt is set on completion or cancellation.
  ///
  /// Pauses normal polling for the entire sweep duration.
  Future<int?> runSweep({
    required String txEcu,
    required String rxEcu,
    required String startDidHex,
    required String endDidHex,
    int periodMs = 250,
    String? carState,
    String? notes,
    void Function(int done, int total, String currentDid)? onProgress,
  }) async {
    if (_client == null) return null;
    if (_sweepRunning) return null;
    // v0.1.15: mutual exclusion with Live Log — both use the single BLE
    // channel via _client.readDid, concurrent invocations would interleave
    // requests/responses and corrupt both data streams.
    if (_liveLogRunning) return null;
    // Also exclude DTC scan for the same reason.
    if (_dtcScanRunning) return null;
    // v0.1.29+28: also exclude CAN passive monitor.
    if (_canMonitorRunning) return null;

    final start = int.tryParse(startDidHex, radix: 16);
    final end = int.tryParse(endDidHex, radix: 16);
    if (start == null || end == null || end < start) return null;
    if (end > 0xFFFF) return null;
    final total = end - start + 1;

    _sweepRunning = true;
    _sweepCancelled = false;
    _sweepDone = 0;
    _sweepTotal = total;
    _sweepCurrentDid = startDidHex.toUpperCase();

    // Pause normal polling
    final wasPolling = _polling;
    if (wasPolling) {
      _polling = false;
      // v0.1.17: wait until the in-flight poll cycle actually finishes.
      // Previously a hardcoded 400ms wait was used — fine for cycle gaps,
      // but a full polling cycle now takes 5-8s (30+ DIDs), so 400ms left
      // _pollEcu in the middle of its readDid chain. Result: live-log
      // readDid calls interleaved with polling readDid → both got EMPTY
      // responses because the BLE channel was effectively shared.
      await _waitForPollIdle();
    }

    // Create SweepRun row
    final runId = await db.insertSweepRun(SweepRunsCompanion(
      startedAt: Value(DateTime.now()),
      txEcu: Value(txEcu),
      rxEcu: Value(rxEcu),
      startDid: Value(startDidHex.toUpperCase()),
      endDid: Value(endDidHex.toUpperCase()),
      periodMs: Value(periodMs),
      carState: Value(carState),
      notes: Value(notes),
      totalProbes: Value(total),
    ));
    _currentSweepRunId = runId;
    notifyListeners();

    int validCount = 0;
    int sequence = 0;

    // v0.1.29+24: kill-signal infrastructure for the sweep loop. Mirrors
    // the +22 livelog hardening — see [_sweepKillSignal] doc. The
    // periodic watchdog timer fires the signal when no sweep_result has
    // been written for 30+ seconds. The signal is raced against every
    // awaited op inside the loop body via Future.any so a wedged op
    // can't block exit.
    _sweepLastProbeAt = DateTime.now();
    _sweepExitReason = null;
    final killSignal = Completer<void>();
    _sweepKillSignal = killSignal;
    _sweepWatchdogTimer?.cancel();
    // v0.1.29+27: sweep watchdog stall threshold = 180 s (was 30 s).
    //
    // Why bumped: 30 s was inherited from the +24 livelog port, where
    // it correctly bounds BLE wedge detection because healthy livelog
    // cycles are 2-5 s (10× margin). For sweep the math is different:
    // a sparse ECU returning NRC on every DID can take 200-400 ms per
    // probe (slow ECU-internal lookup before vendor reject). At 300 ms
    // worst-case, 30 s = ~100 probes, and the watchdog cuts large
    // ranges mid-stream even though the loop is making real progress.
    //
    // Cycles 19/21/22 (2026-05-27) confirmed this: ranges of 1024 DIDs
    // got truncated at 357/512/80 probes — all watchdog-stall, all
    // healthy-but-slow rather than wedged. 180 s ≈ 600 probes at the
    // 300 ms worst case, which covers a full 0x0001-0x00FF range plus
    // headroom for re-syncs. For real freezes the price is 150 extra
    // seconds before recovery — acceptable because (a) the loop is
    // still doing nothing during a freeze either way, and (b) the
    // owner can always cancelSweep() to force exit in ms.
    const int sweepStallThresholdSec = 180;
    _sweepWatchdogTimer = Timer.periodic(const Duration(seconds: 10), (t) {
      final last = _sweepLastProbeAt;
      if (last == null) return;
      final stallSec = DateTime.now().difference(last).inSeconds;
      if (stallSec >= sweepStallThresholdSec) {
        _sweepExitReason ??= 'watchdog_stall';
        debugPrint('runSweep: WATCHDOG_STALL fires kill signal after '
            '${stallSec}s with no sweep_result writes '
            '(done=$_sweepDone/$_sweepTotal valid=$validCount '
            'at $_sweepCurrentDid; threshold=${sweepStallThresholdSec}s)');
        if (!killSignal.isCompleted) killSignal.complete();
        t.cancel();
      }
    });

    try {
      for (int didInt = start; didInt <= end; didInt++) {
        if (_sweepCancelled || killSignal.isCompleted) break;
        // BLE link check — abort if disconnected mid-sweep.
        if (_ble != null && !_ble!.isConnected) {
          _sweepExitReason = 'ble_dropped';
          break;
        }

        final didHex = didInt.toRadixString(16).toUpperCase().padLeft(4, '0');
        _sweepCurrentDid = didHex;

        String? rawHex;
        String? errorCode;

        try {
          // v0.1.17: timeout: max(1500ms, periodMs*2). Matches _pollEcu's
          // empirical production value. Previous 1000ms floor was below
          // some ECUs' worst-case response latency on a loaded bus.
          //
          // v0.1.29+24: raced against killSignal via Future.any. The
          // .timeout(...) below provides the FAST-path bound; the race
          // provides the FAULT-path bound (in case the underlying
          // _writeChar.write() in elm327_ble.dart is wedged at the
          // platform layer — observed in Cycle 9 freezes).
          final timeoutMs = periodMs * 2 > 1500 ? periodMs * 2 : 1500;
          final readFuture = _client!
              .readDid(didHex, tx: txEcu, rx: rxEcu)
              .timeout(Duration(milliseconds: timeoutMs));
          // No-op error handler so an orphaned (kill-won) future doesn't
          // surface as an unhandled async error if it later throws.
          unawaited(readFuture.then((_) {}, onError: (Object _) {}));
          final raceResult = await Future.any<Object?>([
            readFuture.then<Object?>((v) => v),
            killSignal.future.then<Object?>((_) => _killedSentinel),
          ]);
          if (identical(raceResult, _killedSentinel) ||
              killSignal.isCompleted) {
            break;
          }
          final r = raceResult as EcuResponse?;
          if (r == null) {
            // v0.1.29+24: readDid returned null (not threw). Previously
            // this slipped through with no error code recorded; tag it
            // so research data shows the failure mode.
            errorCode = 'NULL_RESPONSE';
          } else {
            // Positive responses start with 62XXXX, where XXXX is the DID.
            // Negative responses start with 7F (NRC).
            // v0.1.15 bug fix: previously an empty/garbage rawHex (e.g. when
            // BLE link silently degraded) would slip past the 7F check and
            // be counted as valid. Sweep #4 of v0.1.14 reported 4083 valid
            // responses despite all 4095 rows in DB being empty.
            // Now requires rawHex to be non-empty and start with '62'.
            final raw = r.rawHex;
            final rawUp = raw.toUpperCase();
            if (rawUp.startsWith('7F')) {
              errorCode = raw;
            } else if (rawUp.startsWith('62') && raw.length >= 6) {
              // v0.1.16: validate echoed DID (see runLiveLog for rationale).
              final echoedDid = rawUp.substring(2, 6);
              if (echoedDid == didHex.toUpperCase()) {
                rawHex = raw;
                validCount++;
              } else {
                errorCode = 'MISALIGNED:$echoedDid≠$didHex';
              }
            } else {
              // Unexpected response shape — log it as error so we can debug,
              // don't count as valid.
              errorCode = raw.isEmpty ? 'EMPTY' : 'MALFORMED:$raw';
            }
          }
        } catch (e) {
          errorCode = 'TIMEOUT';
        }

        // v0.1.29+24: bounded + raced insert. Drift's sqflite serializes
        // writes; same hang surface as livelog's insertLiveLogEntry. 5s
        // timeout is the fast-path bound, killSignal race is the
        // fault-path bound.
        try {
          final insertFuture = db
              .insertSweepResult(SweepResultsCompanion(
                sweepRunId: Value(runId),
                did: Value(didHex),
                rawHex: Value(rawHex),
                errorCode: Value(errorCode),
                sequence: Value(sequence++),
              ))
              .timeout(const Duration(seconds: 5));
          unawaited(insertFuture.then((_) {}, onError: (Object _) {}));
          final raceResult = await Future.any<Object?>([
            insertFuture.then<Object?>((v) => v),
            killSignal.future.then<Object?>((_) => _killedSentinel),
          ]);
          if (identical(raceResult, _killedSentinel) ||
              killSignal.isCompleted) {
            break;
          }
          _sweepLastProbeAt = DateTime.now();
        } on TimeoutException {
          debugPrint('runSweep: insertSweepResult timeout for $didHex — '
              'sequence ${sequence - 1} dropped');
          // Intentionally do NOT update _sweepLastProbeAt so the
          // watchdog can detect a sustained DB stall and break.
        }

        _sweepDone++;
        onProgress?.call(_sweepDone, _sweepTotal, didHex);

        // Notify UI every 8 probes to avoid hammering the rebuild loop —
        // 8 * 250ms = 2s smooth-enough updates without thrash.
        if (_sweepDone % 8 == 0 || _sweepDone == _sweepTotal) {
          notifyListeners();
        }

        // Spacing between probes (period) — short delay to let BLE breathe.
        // We don't add the full periodMs as a separate delay because readDid
        // itself takes a bit of time and we already throttled with timeout.
        //
        // v0.1.29+24: raced against killSignal so a cancel/watchdog
        // doesn't have to wait out the 30ms.
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 30)),
          killSignal.future,
        ]);
      }
      _sweepExitReason ??=
          _sweepCancelled ? 'cancelled' : 'completed';
    } catch (e, st) {
      // v0.1.29+24: top-level safety net so the finally always runs and
      // restores polling, matching the +21 runLiveLog defense pattern.
      debugPrint('runSweep: unhandled exception in loop: $e\n$st');
      _sweepExitReason ??= 'loop_exception';
    } finally {
      // v0.1.29+24: tear down watchdog and kill-signal handle before
      // the final DB write. Orphaned BLE/insert futures settle in the
      // background.
      _sweepWatchdogTimer?.cancel();
      _sweepWatchdogTimer = null;
      _sweepKillSignal = null;

      // Close out the SweepRun — v0.1.29+24: bounded by timeout AND
      // wrapped in try/catch so a Drift hang here can't stop the
      // polling-restore below from running. Exit reason persisted into
      // sweep_runs.notes for post-mortem (mirrors livelog convention).
      try {
        final exitTag = _sweepExitReason ?? 'unknown';
        final finalNotes = notes != null
            ? '$notes | exit=$exitTag'
            : 'exit=$exitTag';
        await (db.update(db.sweepRuns)..where((s) => s.id.equals(runId)))
            .write(
              SweepRunsCompanion(
                endedAt: Value(DateTime.now()),
                validResponses: Value(validCount),
                notes: Value(finalNotes),
              ),
            )
            .timeout(const Duration(seconds: 10));
      } catch (e, st) {
        debugPrint('runSweep: failed to write final run row: $e\n$st');
      }

      _sweepRunning = false;
      _sweepCancelled = false;
      _sweepLastProbeAt = null;
      // Don't clear _currentSweepRunId — UI may want to navigate to results.
      if (wasPolling) {
        _polling = true;
        _pollLoop();
      }
      notifyListeners();
    }

    return runId;
  }

  // ─────────────────── v0.1.29+28: CAN passive monitor ───────────────────
  //
  // Listens to ALL CAN broadcast frames the adapter sees via `AT MA`.
  // Unlike runSweep / runLiveLog (UDS request/response), no DIDs are
  // probed — we just sniff. Primary use case: hunting for the CAN IDs
  // documented in BydDataCollect's VehicleData.conf (0x43D pack voltage,
  // 0x444 pack current+SOC, 0x46C MCU currents, 0x45B MCU voltage,
  // 0x121 vehicle speed) which are broadcast continuously rather than
  // exposed as UDS DIDs.
  //
  // First experiment goal: count unique CAN IDs observed in a parked
  // 30 sec window. If >50 unique IDs, OBD-II gateway is open and we can
  // directly decode pack current per VehicleData.conf. If 1-3, gateway
  // is whitelist-only and we need a different attack (head-unit-side
  // helper app).
  //
  // Safety: own mutex (_canMonitorRunning), exits cleanly via finally
  // even on BLE wedge (kill-signal + watchdog mirroring +22/+24 pattern).
  // Restores polling on exit.
  //
  // Caller: bridge_diag_service `bleStartCanMonitor` command.

  /// Run a CAN passive-monitor session for [durationSec] seconds.
  /// Returns the new CanMonitorSession id, or null if pre-conditions
  /// fail (no BLE, another op active, bad args).
  ///
  /// Frames are pushed to the can_frames table as they arrive. After the
  /// session ends, summary counts are written to can_monitor_sessions.
  Future<int?> runCanMonitor({
    required int durationSec,
    String? carState,
    String? notes,
    String? protocol,
    List<String>? filterCommands,
  }) async {
    if (_client == null || _ble == null) return null;
    if (_canMonitorRunning) return null;
    // Mutually exclusive with all other BLE-channel users.
    if (_sweepRunning) return null;
    if (_liveLogRunning) return null;
    if (_dtcScanRunning) return null;
    if (durationSec < 1 || durationSec > 600) return null;
    if (!_ble!.isConnected) return null;

    // v0.1.29+32: protocol + filter overrides for Path-A exploration.
    // C28 Phase A used only AT SP 6 (CAN 11-bit 500k) and saw 2 unique
    // IDs (mostly diagnostic 620 = UDS responses), which we tentatively
    // read as "gateway whitelist". But that's one config out of many.
    // BZ5 likely has multiple CAN buses on different OBD-II pins at
    // different bit-widths/speeds; broadcast frames on a 29-bit or 250k
    // bus would be invisible to SP 6. These params let Друг 2 sweep the
    // unexplored configs manually:
    //   protocol "6" 11-bit 500k (default, what C28 used)
    //   protocol "7" 29-bit 500k  ← powertrain broadcast often here
    //   protocol "8" 11-bit 250k  ← body/comfort CAN
    //   protocol "9" 29-bit 250k
    //   protocol "0" auto-detect  ← let the adapter decide
    // filterCommands: extra AT/ST setup lines sent verbatim BEFORE
    // AT MA, e.g. ["AT CAF0", "AT CM 000", "AT CF 000"] to drop receive
    // filtering, or ["ST I"] to probe for an STN chip. Each is sent via
    // sendRaw (prompt-mode) and its response logged to debugPrint.
    // Sanitised: only [A-Z0-9 ] allowed, max 16 chars, max 8 commands —
    // these are typed by a trusted operator but we still bound them so
    // a bad value can't wedge the adapter in an unexpected mode.
    final spArg = (protocol != null &&
            RegExp(r'^[0-9A]$').hasMatch(protocol.toUpperCase()))
        ? protocol.toUpperCase()
        : '6';
    final safeFilters = <String>[];
    if (filterCommands != null) {
      for (final c in filterCommands.take(8)) {
        final up = c.trim().toUpperCase();
        if (up.isNotEmpty &&
            up.length <= 16 &&
            RegExp(r'^[A-Z0-9 ]+$').hasMatch(up)) {
          safeFilters.add(up);
        }
      }
    }

    _canMonitorRunning = true;
    _canMonitorCancelled = false;
    _canFrameCount = 0;
    _canSeenIds.clear();
    _canMonitorLastFrameAt = DateTime.now();
    _canMonitorExitReason = null;

    // Pause normal polling so the BLE channel is ours alone.
    final wasPolling = _polling;
    if (wasPolling) _polling = false;

    // v0.1.29+29: assign client_session_id from SharedPreferences-
    // persisted monotonic counter, same pattern as runLiveLog. Bridge
    // requires this for UNIQUE(device_id, client_session_id) idempotency
    // on the can_monitor_sessions table (per
    // bridge-changes-for-drug1.md, commit c73f0fb). Persist AFTER the
    // insert so a failed insert doesn't burn an id.
    final nextId = await _nextCanMonitorSessionId();
    final sessionId = await db.insertCanMonitorSession(
      CanMonitorSessionsCompanion(
        id: Value(nextId),
        startedAt: Value(DateTime.now()),
        durationSec: Value(durationSec),
        carState: Value(carState),
        notes: Value(notes),
        // v0.1.29+32: record which CAN protocol this session used so
        // offline analysis can correlate "0 frames" vs protocol.
        protocol: Value(spArg),
      ),
    );
    await _persistCanMonitorSessionId(sessionId);
    _currentCanMonitorSessionId = sessionId;
    notifyListeners();

    // Kill-signal + watchdog mirroring +22 (livelog) / +24 (sweep).
    // Watchdog threshold here is "no frame received for 15 s" — typical
    // broadcast traffic on an open gateway produces dozens of frames/sec,
    // so 15 s of silence means the adapter wedged or the gateway closed
    // the bus. On a whitelist gateway we'll see 0 frames the whole
    // session and the watchdog will fire at 15 s — that's a valid
    // result, not a bug (it tells us gateway state).
    final killSignal = Completer<void>();
    _canMonitorKillSignal = killSignal;
    _canMonitorWatchdogTimer?.cancel();
    _canMonitorWatchdogTimer =
        Timer.periodic(const Duration(seconds: 5), (t) {
      final last = _canMonitorLastFrameAt;
      if (last == null) return;
      final silentSec = DateTime.now().difference(last).inSeconds;
      // No frame in 15s while in monitor mode = adapter silent. Could
      // be: gateway whitelist (legitimate), bus quiet (Ready OFF),
      // adapter wedge. Either way, no point waiting longer.
      if (silentSec >= 15 && _canFrameCount == 0) {
        _canMonitorExitReason ??= 'no_frames_15s';
        debugPrint('runCanMonitor: no frames in ${silentSec}s — bus silent '
            'or gateway whitelist. Exiting.');
        if (!killSignal.isCompleted) killSignal.complete();
        t.cancel();
      } else if (silentSec >= 30 && _canFrameCount > 0) {
        // Was receiving frames, now silent for 30s. Adapter wedged
        // mid-stream — defensive exit.
        _canMonitorExitReason ??= 'watchdog_stall';
        debugPrint('runCanMonitor: frame stream stalled after '
            '$_canFrameCount frames (${silentSec}s silent). Exiting.');
        if (!killSignal.isCompleted) killSignal.complete();
        t.cancel();
      }
    });

    StreamSubscription<String>? lineSub;

    try {
      // Step 1: prepare adapter for raw CAN monitoring.
      // v0.1.29+32: protocol now selectable (default "6" = ISO 15765-4
      // CAN 11-bit 500 kbps, what C28 used). See param doc for the full
      // menu. 29-bit protocols (7/9) produce 8-hex-digit IDs; our line
      // parser already handles both widths.
      // AT H1 = include header (CAN ID) in monitor output.
      // AT S0 = no spaces (more compact lines).
      //
      // Each command via standard sendRaw so we get prompt confirmation
      // — this is still request/response mode at this point.
      try {
        final spResp = await _ble!.sendRaw('AT SP $spArg',
            timeout: const Duration(seconds: 3));
        debugPrint('runCanMonitor: AT SP $spArg → $spResp');
        await _ble!.sendRaw('AT H1', timeout: const Duration(seconds: 2));
        await _ble!.sendRaw('AT S0', timeout: const Duration(seconds: 2));
        // v0.1.29+32: operator-supplied filter/setup commands, sent
        // verbatim after the base config and before AT MA. Used to drop
        // receive filtering (AT CAF0 / AT CM 000 / AT CF 000) or probe
        // the chip (ST I). Responses logged for offline review.
        for (final fc in safeFilters) {
          try {
            final resp = await _ble!
                .sendRaw(fc, timeout: const Duration(seconds: 2));
            debugPrint('runCanMonitor: filter "$fc" → $resp');
          } catch (e) {
            debugPrint('runCanMonitor: filter "$fc" failed: $e');
          }
        }
      } catch (e) {
        debugPrint('runCanMonitor: setup commands failed: $e');
        _canMonitorExitReason = 'setup_failed';
        return sessionId;
      }

      // Step 2: enter monitor mode on the Dart side and subscribe to
      // the line stream BEFORE sending AT MA. Order matters: if AT MA
      // starts streaming before we're listening, we lose the first
      // frames.
      _ble!.enterMonitorMode();
      final startedAt = DateTime.now();
      // v0.1.29+32: monotonic counter for raw-line rows, independent of
      // the frame counter (raw includes lines the parser rejects).
      int rawSeq = 0;
      lineSub = _ble!.monitorLines.listen((line) async {
        // v0.1.29+32: capture the RAW line FIRST, before any trimming,
        // whitespace-stripping, hex-validation or splitting. This is the
        // safety net for Path-A exploration: if a protocol/filter combo
        // returns data in a format the frame parser doesn't recognise
        // (STN timestamps, status strings, odd delimiters), it's still
        // recoverable offline from can_raw_lines. We decide `parsed`
        // below and record it so analysis can filter WHERE parsed = 0.
        final rawSnapshot = line;
        final thisRawSeq = rawSeq++;
        bool parsedOk = false;

        // Filter out adapter status lines (the only non-frame output
        // expected during AT MA is 'STOPPED' on ESC, or noise from a
        // mis-tuned bus). A CAN frame line looks like:
        //   "444 01 02 03 04 05 06 07 08"   (11-bit, with AT H1+S0
        //                                      it's "44401020304...")
        // With AT S0 (no spaces) the line is one long hex blob with
        // the first 3 chars being the ID. We accept any line that's
        // at least 3 hex chars and parses entirely as hex.
        final clean = line.replaceAll(RegExp(r'\s+'), '');
        if (clean.length >= 3 &&
            RegExp(r'^[0-9A-Fa-f]+$').hasMatch(clean)) {
          // Split ID and payload. 11-bit IDs are 3 hex chars; 29-bit are
          // 8. Heuristic: if first char is 0-7 and length is 3+even,
          // treat as 11-bit. Otherwise 29-bit.
          String canId;
          String payload;
          if (clean.length >= 11 &&
              clean.length % 2 == 0 &&
              int.tryParse(clean.substring(0, 8), radix: 16) != null &&
              // 29-bit IDs in ELM327 output are usually padded — if first
              // 5 chars are zeros it's almost certainly 29-bit.
              clean.startsWith('00')) {
            canId = clean.substring(0, 8).toUpperCase();
            payload = clean.substring(8).toUpperCase();
          } else {
            // 11-bit
            canId = clean.substring(0, 3).toUpperCase();
            payload = clean.substring(3).toUpperCase();
          }

          _canFrameCount++;
          _canSeenIds.add(canId);
          _canMonitorLastFrameAt = DateTime.now();
          parsedOk = true;

          try {
            await db
                .insertCanFrame(CanFramesCompanion(
                  monitorSessionId: Value(sessionId),
                  sequence: Value(_canFrameCount - 1),
                  tsMs: Value(DateTime.now()),
                  canId: Value(canId),
                  payloadHex: Value(payload),
                ))
                .timeout(const Duration(seconds: 5));
          } on TimeoutException {
            // Don't try to recover here — if Drift's stalling, the
            // watchdog will pick it up. Drop the frame.
            debugPrint('runCanMonitor: insert timeout, frame dropped '
                '(id=$canId)');
          } catch (e) {
            debugPrint('runCanMonitor: insert error: $e');
          }
        } else {
          // Unparsed line — still counts as adapter activity so the
          // watchdog doesn't think the bus went silent while real (just
          // unrecognised) data is flowing.
          _canMonitorLastFrameAt = DateTime.now();
        }

        // v0.1.29+32: persist the raw line regardless of parse outcome.
        // Length-guarded so a runaway line can't bloat a row; 512 chars
        // is far beyond any real ELM327/STN line (longest is ~30 with a
        // 29-bit ID + 8 payload bytes + timestamp prefix).
        final guarded = rawSnapshot.length > 512
            ? rawSnapshot.substring(0, 512)
            : rawSnapshot;
        try {
          await db
              .insertCanRawLine(CanRawLinesCompanion(
                monitorSessionId: Value(sessionId),
                sequence: Value(thisRawSeq),
                tsMs: Value(DateTime.now()),
                rawLine: Value(guarded),
                parsed: Value(parsedOk),
              ))
              .timeout(const Duration(seconds: 5));
        } on TimeoutException {
          debugPrint('runCanMonitor: raw-line insert timeout, dropped '
              '(seq=$thisRawSeq)');
        } catch (e) {
          debugPrint('runCanMonitor: raw-line insert error: $e');
        }

        // Notify UI every 32 frames — avoids hammering rebuilds at
        // 200+ frames/sec on a busy bus.
        if (_canFrameCount % 32 == 0) {
          notifyListeners();
        }
      }, onError: (Object e) {
        debugPrint('runCanMonitor: line stream error: $e');
      });

      // Step 3: send AT MA with no-wait. The adapter will now stream
      // until ESC.
      await _ble!.sendRawNoWait('AT MA\r');

      // Step 4: wait for whichever ends first:
      //   - the requested duration elapses
      //   - cancelCanMonitor() is called (killSignal completes)
      //   - watchdog fires (killSignal completes)
      //   - BLE drops
      final deadline = startedAt.add(Duration(seconds: durationSec));
      while (true) {
        if (_canMonitorCancelled) {
          _canMonitorExitReason ??= 'cancelled';
          break;
        }
        if (killSignal.isCompleted) {
          // exit reason already set by watchdog
          break;
        }
        if (_ble != null && !_ble!.isConnected) {
          _canMonitorExitReason ??= 'ble_dropped';
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          _canMonitorExitReason ??= 'completed';
          break;
        }

        // Sleep in small slices, raced against killSignal so cancel
        // reacts in <500ms.
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 500)),
          killSignal.future,
        ]);
      }
    } catch (e, st) {
      debugPrint('runCanMonitor: unhandled exception: $e\n$st');
      _canMonitorExitReason ??= 'loop_exception';
    } finally {
      // Step 5: robustly exit AT MA and confirm the adapter is back in
      // prompt mode. v0.1.29+31: the old teardown (single ESC +
      // exitMonitorMode + blind AT H0/S1) left the adapter stuck in MA
      // in the field — every subsequent UDS read failed until a manual
      // BLE reconnect. exitMonitorModeAndResync sends repeated ESC,
      // verifies a prompt returns, THEN restores AT H0/S1. Returns
      // false if it can't get the adapter back.
      try {
        await lineSub?.cancel();
      } catch (_) {}

      bool resynced = false;
      try {
        resynced = await _ble
                ?.exitMonitorModeAndResync()
                .timeout(const Duration(seconds: 8)) ??
            false;
      } catch (e) {
        debugPrint('runCanMonitor: exitMonitorModeAndResync threw: $e');
        resynced = false;
      }

      if (!resynced) {
        // Adapter is wedged in AT MA. A physical BLE reconnect is the
        // only reliable recovery (confirmed in C28). Force it so the
        // next poll/sweep/livelog starts from a clean adapter instead
        // of silently returning 0% valid responses.
        debugPrint('runCanMonitor: adapter did NOT resync after AT MA — '
            'forcing BLE reconnect to clear stuck monitor state.');
        _canMonitorExitReason =
            '${_canMonitorExitReason ?? "completed"}+stuck_reconnect';
        try {
          // Best-effort: tear down and let the existing reconnect path
          // bring it back. _handleBleDisconnect triggers the normal
          // auto-reconnect flow.
          await _ble?.disconnect();
        } catch (_) {}
      }

      // Cancel watchdog and clear handles.
      _canMonitorWatchdogTimer?.cancel();
      _canMonitorWatchdogTimer = null;
      _canMonitorKillSignal = null;

      // Finalize session row. Bounded by timeout so a stuck Drift
      // can't block the polling restart below.
      try {
        final exitTag = _canMonitorExitReason ?? 'unknown';
        final finalNotes = notes != null
            ? '$notes | exit=$exitTag'
            : 'exit=$exitTag';
        await (db.update(db.canMonitorSessions)
              ..where((s) => s.id.equals(sessionId)))
            .write(CanMonitorSessionsCompanion(
              endedAt: Value(DateTime.now()),
              frameCount: Value(_canFrameCount),
              uniqueCanIds: Value(_canSeenIds.length),
              notes: Value(finalNotes),
            ))
            .timeout(const Duration(seconds: 10));
      } catch (e, st) {
        debugPrint(
            'runCanMonitor: failed to write final session row: $e\n$st');
      }

      _canMonitorRunning = false;
      _canMonitorCancelled = false;
      _canMonitorLastFrameAt = null;
      // Note: _canSeenIds NOT cleared so getter still reports the final
      // count to the UI until the next session starts.

      // v0.1.29+31: only restart polling if the adapter is still
      // connected. If we forced a disconnect above (stuck-in-MA
      // recovery), the auto-reconnect path will re-establish polling on
      // its own — restarting it here against a dead link would just
      // spin _pollLoop against isConnected==false until reconnect.
      final stillConnected = _ble?.isConnected ?? false;
      if (wasPolling && stillConnected) {
        _polling = true;
        _pollLoop();
      }
      notifyListeners();
    }

    return sessionId;
  }

  // ─────────────────────── v0.1.15: Live Log ─────────────────────────
  //
  // Time-series polling of up to 7 user-selected DIDs over a fixed duration
  // (or until cancelled). Same pause-polling/wake-lock pattern as sweep.
  // Writes one LiveLogEntry per DID per cycle to the DB.
  //
  // Difference from sweep:
  //   - sweep:    each DID probed ONCE, range can be huge (8192)
  //   - liveLog:  small fixed set of DIDs probed repeatedly in cycles
  //
  // Cycle = one round of all selected DIDs. Period 250ms each probe, so
  // 5 DIDs → ~1.25s cycle (~0.8 Hz). 7 DIDs → ~1.75s cycle (~0.57 Hz).

  bool _liveLogRunning = false;
  bool _liveLogCancelled = false;
  int? _currentLiveLogSessionId;
  int _liveLogCycle = 0;
  /// Last value seen for each DID, keyed by "ecuTx/didHex" (e.g. "791/0038").
  /// Useful for the UI to show the most-recent reading per DID.
  final Map<String, String?> _liveLogLastRaw = {};

  /// v0.1.29+21: wall-clock of last DB row written for the active live-log
  /// session. Used by the watchdog inside [runLiveLog] (and exposed to
  /// the UI) so a "frozen" state can be detected even when the BLE link
  /// looks fine. `null` between sessions.
  DateTime? _liveLogLastEntryAt;

  /// v0.1.29+21: monotonic count of entries written into the DB for the
  /// active session (resets at session start). Differs from `entryCount`
  /// in the returned id only by also being readable while running.
  int _liveLogWrittenCount = 0;

  /// v0.1.29+21: last reason the loop broke out of its main while-loop.
  /// Surfaces in DB session.notes for post-mortem analysis.
  /// One of: cancelled / max_duration / ble_dropped / watchdog_stall /
  /// loop_exception / ble_dropped_mid_cycle / null (still running).
  String? _liveLogExitReason;

  /// v0.1.29+22: hard-kill signal for the live-log loop. Completed when
  /// the loop must abort RIGHT NOW (cancel command, watchdog stall, BLE
  /// drop). Every awaited operation inside the loop body races against
  /// this completer; whichever fires first wins. The +21 attempt relied
  /// on per-await `.timeout(...)` returning control to the top of the
  /// while-loop where a watchdog could fire — but Cycle 3 showed that
  /// some awaits inside `_writeChar.write(...)` (in protected
  /// elm327_ble.dart) can hang indefinitely WITHOUT the outer `.timeout`
  /// firing, leaving the loop stuck mid-cycle. This kill-signal pattern
  /// works around that: even if the underlying BLE write Future never
  /// completes, `Future.any([op, killSignal.future])` resolves the
  /// moment the signal fires, and the loop can exit and run finally.
  Completer<void>? _liveLogKillSignal;

  /// v0.1.29+22: periodic watchdog that fires the kill signal when
  /// `_liveLogLastEntryAt` is stale beyond a threshold. Runs as a
  /// `Timer.periodic` independent of the loop coroutine; relies only on
  /// the event-loop timer scheduler (which keeps working even when the
  /// loop is hung on a BLE await, as proven by uninterrupted heartbeats
  /// during the Cycle 2/3 freezes).
  Timer? _liveLogWatchdogTimer;

  bool get liveLogRunning => _liveLogRunning;
  int? get currentLiveLogSessionId => _currentLiveLogSessionId;
  int get liveLogCycle => _liveLogCycle;
  Map<String, String?> get liveLogLastRaw => Map.unmodifiable(_liveLogLastRaw);
  DateTime? get liveLogLastEntryAt => _liveLogLastEntryAt;
  int get liveLogWrittenCount => _liveLogWrittenCount;

  /// Cancel an active live log. Loop exits at the end of the current cycle
  /// (worst case ~2s wait for 7 DIDs).
  ///
  /// v0.1.29+22: also fires the kill signal so any in-flight await inside
  /// the loop (BLE read, DB insert) returns immediately instead of
  /// waiting for its own timeout/completion. This makes stop commands
  /// react in milliseconds instead of seconds — and works even when the
  /// underlying BLE write is wedged (which was the +21 unfixed case).
  void cancelLiveLog() {
    if (_liveLogRunning) {
      _liveLogCancelled = true;
      final ks = _liveLogKillSignal;
      if (ks != null && !ks.isCompleted) ks.complete();
    }
  }

  /// v0.1.29+23: compute the next monotonic `client_session_id` for a
  /// new LiveLogSession row. The returned value is used as the explicit
  /// `id` column at insert time so that the value Bridge sees in
  /// `_liveLogToJson` survives across:
  ///
  ///   - app process restart           (SharedPreferences persists)
  ///   - in-place APK update on phone  (SharedPreferences persists)
  ///
  /// It does NOT survive uninstall+install on the head unit (which
  /// wipes Drift / Keystore / SharedPreferences together) — that case
  /// still risks a bridge-side UNIQUE collision on (device_id,
  /// client_session_id) the first time the new install pushes session
  /// id=1. Documented gap, requires a server-side change (or a UUID
  /// migration) to close fully.
  ///
  /// Defence-in-depth: we take max(persisted_counter,
  /// max_id_in_local_db) + 1 so that if the SharedPreferences key were
  /// ever lost or rolled back independently of Drift, we still never
  /// reuse a local id.
  Future<int> _nextLiveLogSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getInt(_kLiveLogSessionIdNext) ?? 0;

    // Local DB max — cheap enough at ~hundreds of rows; no dedicated
    // helper added to the protected database.dart for this.
    int dbMax = 0;
    try {
      final all = await db.getAllLiveLogSessions();
      for (final s in all) {
        if (s.id > dbMax) dbMax = s.id;
      }
    } catch (e) {
      debugPrint('_nextLiveLogSessionId: getAllLiveLogSessions failed: $e');
      // Fall through with dbMax = 0; persisted counter alone will
      // suffice unless it's also missing, in which case we get id=1
      // which is fine for a fresh install.
    }

    final next = (persisted > dbMax ? persisted : dbMax) + 1;
    return next;
  }

  /// v0.1.29+23: persist the just-assigned LiveLogSession id so the
  /// next call to [_nextLiveLogSessionId] returns a higher value even
  /// across an app restart. Best-effort: if SharedPreferences write
  /// fails the session still has a valid local id; only the
  /// persistence guarantee is weakened (next launch will fall back to
  /// the dbMax safety check).
  Future<void> _persistLiveLogSessionId(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLiveLogSessionIdNext, id);
    } catch (e) {
      debugPrint('_persistLiveLogSessionId($id) failed: $e');
    }
  }

  /// v0.1.29+29: same pattern as [_nextLiveLogSessionId], for CAN
  /// monitor sessions. The bridge enforces UNIQUE(device_id,
  /// client_session_id) on `can_monitor_sessions`, so the row insert
  /// must carry a per-runtime monotonic value that survives app
  /// restart. dbMax safety check guards against a SharedPreferences
  /// rollback (e.g. user clears app data manually).
  Future<int> _nextCanMonitorSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getInt(_kCanMonitorSessionIdNext) ?? 0;

    int dbMax = 0;
    try {
      final all = await db.getAllCanMonitorSessions();
      for (final s in all) {
        if (s.id > dbMax) dbMax = s.id;
      }
    } catch (e) {
      debugPrint('_nextCanMonitorSessionId: getAllCanMonitorSessions '
          'failed: $e');
    }

    return (persisted > dbMax ? persisted : dbMax) + 1;
  }

  Future<void> _persistCanMonitorSessionId(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCanMonitorSessionIdNext, id);
    } catch (e) {
      debugPrint('_persistCanMonitorSessionId($id) failed: $e');
    }
  }

  /// Run a live-log session. [didSpecs] is a list of (txEcu, rxEcu, didHex)
  /// triples, max 10. Returns the LiveLogSession id created in DB.
  ///
  /// v0.1.29+25: bumped from 7 to 10. Empirical cycle time data
  /// (Cycles 4-11 production drives, 2026-05-25):
  ///   - 7 DIDs mixed-ECU (C10/C11): ~2.1 s/cycle
  ///   - 7 DIDs single-ECU (C4/C5):  ~4.2 s/cycle (adaptive same-ECU
  ///     gap schedule kicks in: 200→350→550→800ms)
  /// Adding 3 slots at mixed-ECU rate ≈ +1 s/cycle → ~3.1 s mixed,
  /// ~7 s single-ECU worst case. Still fast enough for steady-state
  /// signals (HV voltage, SOC, current averaged over 1s). Marginal
  /// for sub-second transients (regen brake pulse) but research
  /// focus is "what varies", not "instantaneous capture".
  ///
  /// Polling loops until [cancelLiveLog] is called, [maxDurationMs] elapses,
  /// or BLE disconnects. Each DID probed once per cycle; cycles repeat with
  /// minimal spacing.
  Future<int?> runLiveLog({
    required List<(String, String, String)> didSpecs,
    int? maxDurationMs,
    String? carState,
    String? notes,
    void Function(int cycle)? onCycle,
  }) async {
    if (_client == null) return null;
    if (_liveLogRunning) return null;
    // v0.1.15: mutual exclusion with sweep — see runSweep for rationale.
    if (_sweepRunning) return null;
    if (_dtcScanRunning) return null;
    // v0.1.29+28: also exclude CAN passive monitor.
    if (_canMonitorRunning) return null;
    if (didSpecs.isEmpty || didSpecs.length > 10) return null;

    _liveLogRunning = true;
    _liveLogCancelled = false;
    _liveLogCycle = 0;
    _liveLogLastRaw.clear();
    // v0.1.29+21: reset watchdog observables.
    _liveLogLastEntryAt = DateTime.now();
    _liveLogWrittenCount = 0;
    _liveLogExitReason = null;

    // Pause normal polling
    final wasPolling = _polling;
    if (wasPolling) {
      _polling = false;
      // v0.1.17: wait until the in-flight poll cycle actually finishes.
      // Previously a hardcoded 400ms wait was used — fine for cycle gaps,
      // but a full polling cycle now takes 5-8s (30+ DIDs), so 400ms left
      // _pollEcu in the middle of its readDid chain. Result: live-log
      // readDid calls interleaved with polling readDid → both got EMPTY
      // responses because the BLE channel was effectively shared.
      await _waitForPollIdle();
    }

    // Create LiveLogSession row
    final didListStr =
        didSpecs.map((s) => '${s.$1}/${s.$3.toUpperCase()}').join(',');
    // v0.1.29+23: assign client_session_id from a SharedPreferences-
    // persisted monotonic counter so it survives app restart and
    // in-place updates. See [_nextLiveLogSessionId] for the gap on
    // head-unit uninstall+install. We pass the value as an explicit
    // `id` so what bridge sees in `_liveLogToJson` (which uses
    // `s.id`) matches the monotonic counter. The persist call is
    // intentionally AFTER the insert so a failed insert doesn't
    // burn an id.
    final nextId = await _nextLiveLogSessionId();
    final sessionId = await db.insertLiveLogSession(LiveLogSessionsCompanion(
      id: Value(nextId),
      startedAt: Value(DateTime.now()),
      didList: Value(didListStr),
      carState: Value(carState),
      notes: Value(notes),
    ));
    await _persistLiveLogSessionId(sessionId);
    _currentLiveLogSessionId = sessionId;
    notifyListeners();

    int entryCount = 0;
    final startTime = DateTime.now();

    // v0.1.29+22: kill signal infrastructure. The completer is what
    // every awaited operation inside the loop races against. The Timer
    // fires the signal when the loop has stalled (no DB writes for
    // 30+ seconds), runs in its own event-loop tick, and therefore
    // works even when the loop coroutine is wedged on a hung BLE await.
    final killSignal = Completer<void>();
    _liveLogKillSignal = killSignal;
    _liveLogWatchdogTimer?.cancel();
    _liveLogWatchdogTimer = Timer.periodic(const Duration(seconds: 5), (t) {
      final last = _liveLogLastEntryAt;
      if (last == null) return;
      final stallSec = DateTime.now().difference(last).inSeconds;
      if (stallSec >= 30) {
        _liveLogExitReason ??= 'watchdog_stall';
        debugPrint('runLiveLog: WATCHDOG_STALL fires kill signal after '
            '${stallSec}s with no DB writes '
            '(cycle=$_liveLogCycle written=$_liveLogWrittenCount)');
        if (!killSignal.isCompleted) killSignal.complete();
        t.cancel();
      }
    });

    try {
      while (!_liveLogCancelled && !killSignal.isCompleted) {
        // BLE link check
        if (_ble != null && !_ble!.isConnected) {
          _liveLogExitReason = 'ble_dropped';
          break;
        }

        // Optional max duration cap
        if (maxDurationMs != null &&
            DateTime.now().difference(startTime).inMilliseconds >= maxDurationMs) {
          _liveLogExitReason = 'max_duration';
          break;
        }

        // v0.1.29+21: watchdog — if no DB entry has been written in the
        // last 30s, something is stuck (Drift lock contention, BLE
        // characteristic frozen mid-frame with the timeout race
        // somehow missed, etc.). Bail out so finally restores polling
        // and the trip detector can finalize the current trip
        // normally — otherwise live-log freezes ALSO freeze trip
        // aggregation, leaving dashes-everywhere rows in the UI.
        //
        // 30s threshold ≈ 2× worst-case healthy cycle:
        //   7 DIDs × (1500ms read timeout + 150ms retry + 800ms cap)
        //   = ~17s in 100%-timeout-but-still-progressing state.
        // Real production cycles are 3-5s.
        final lastEntry = _liveLogLastEntryAt;
        if (lastEntry != null &&
            DateTime.now().difference(lastEntry).inSeconds >= 30) {
          _liveLogExitReason = 'watchdog_stall';
          debugPrint('runLiveLog: WATCHDOG_STALL after '
              '${DateTime.now().difference(lastEntry).inSeconds}s with no DB writes '
              '(cycle=$_liveLogCycle written=$_liveLogWrittenCount)');
          break;
        }

        _liveLogCycle++;
        // v0.1.19: progressive same-ECU gap. Even with 200ms between
        // same-ECU requests, the 5th request consistently returns EMPTY
        // (reproduced in livelog 9/10 — 100% failure rate on position 5
        // when all 5 DIDs are on the same ECU). The ELM327 BLE adapter
        // appears to accumulate state across requests; each consecutive
        // request needs slightly more breathing room than the last.
        //
        // Schedule:
        //   different ECU → 80ms gap, counter resets
        //   1st repeat same ECU → 200ms
        //   2nd repeat same ECU → 350ms
        //   3rd repeat same ECU → 550ms (this is the problematic 5th DID
        //                                if started with all-same ECU)
        //   4th+ repeat → 800ms cap
        String? prevEcu;
        int sameEcuRun = 0;
        for (final spec in didSpecs) {
          if (_liveLogCancelled || killSignal.isCompleted) break;

          // v0.1.29+21: BLE check INSIDE the inner loop too. Previously
          // only at top of while — meant a mid-cycle BLE drop ground
          // through the remaining DIDs all timing out, costing ~10s of
          // wasted reads per cycle on a dead link.
          if (_ble != null && !_ble!.isConnected) {
            _liveLogExitReason = 'ble_dropped_mid_cycle';
            break;
          }

          final txEcu = spec.$1;
          final rxEcu = spec.$2;
          final did = spec.$3.toUpperCase();

          // Pre-request adaptive gap.
          if (prevEcu != null) {
            int gapMs;
            if (prevEcu != txEcu) {
              gapMs = 80;
              sameEcuRun = 0;
            } else {
              sameEcuRun++;
              // Schedule: 200, 350, 550, 800
              const schedule = [200, 350, 550, 800];
              gapMs = schedule[sameEcuRun - 1 < schedule.length
                  ? sameEcuRun - 1
                  : schedule.length - 1];
            }
            // v0.1.29+22: race the delay against kill signal so a cancel
            // command doesn't have to wait out a full 800ms gap.
            await Future.any<void>([
              Future<void>.delayed(Duration(milliseconds: gapMs)),
              killSignal.future,
            ]);
            if (killSignal.isCompleted) break;
          }
          prevEcu = txEcu;

          String? rawHex;
          String? errorCode;

          // v0.1.29+21: per-DID outer try/catch — a single bad iteration
          // (unexpected exception from readDid wrapper, sanity helper,
          // DB call, etc.) must not kill the whole session. Without
          // this we relied on the per-call try/catch inside the read
          // attempt loop, which doesn't cover the sanity helper or
          // the insert.
          try {
            // v0.1.17: retry up to twice on EMPTY response. ELM327 BLE
            // adapter under load (multi-DID polling) sometimes returns
            // empty frames — the request reaches the bus but the response
            // gets lost in the BLE characteristic queue. A short retry
            // after a 150ms breather recovers ~50% of these cases without
            // significantly impacting cycle time.
            //
            // Timeout 1500ms (was 1000ms) — matches _pollEcu's empirical
            // value which has proven reliable in production polling.
            //
            // v0.1.29+22: each readDid is also raced against killSignal
            // via Future.any. Cycle 3 (+21) proved that the outer
            // .timeout(1500ms) can fail to fire when the underlying
            // flutter_blue_plus _writeChar.write(...) (no internal
            // timeout, lives in protected elm327_ble.dart) is wedged at
            // the platform layer. The killSignal race guarantees the
            // await returns even in that case, so the loop can exit and
            // finally can run (restoring polling, finalizing the trip).
            for (int attempt = 0; attempt < 2; attempt++) {
              if (killSignal.isCompleted) break;
              try {
                final readFuture = _client!
                    .readDid(did, tx: txEcu, rx: rxEcu)
                    .timeout(const Duration(milliseconds: 1500));
                // Attach a no-op error handler so an orphaned (killed)
                // future doesn't surface as an unhandled async error.
                unawaited(
                    readFuture.then((_) {}, onError: (Object _) {}));
                final raceResult = await Future.any<Object?>([
                  readFuture.then<Object?>((v) => v),
                  killSignal.future.then<Object?>((_) => _killedSentinel),
                ]);
                if (identical(raceResult, _killedSentinel) ||
                    killSignal.isCompleted) {
                  break;
                }
                final r = raceResult as EcuResponse?;
                if (r == null) {
                  // v0.1.29+21: readDid completed with null instead of
                  // throwing. Previously the attempt loop fell through
                  // silently leaving BOTH rawHex AND errorCode null →
                  // the row was inserted with no signal of what
                  // happened. Tag the failure mode so research data
                  // surfaces it.
                  errorCode = 'NULL_RESPONSE';
                  if (attempt == 0) {
                    await Future.any<void>([
                      Future<void>.delayed(const Duration(milliseconds: 150)),
                      killSignal.future,
                    ]);
                    if (killSignal.isCompleted) break;
                    continue;
                  }
                  break;
                }
                final raw = r.rawHex;
                final rawUp = raw.toUpperCase();
                if (rawUp.startsWith('7F')) {
                  errorCode = raw;
                  rawHex = null;
                  break;
                } else if (rawUp.startsWith('62') && raw.length >= 6) {
                  // v0.1.16: validate the DID echo. ELM327 BLE adapter
                  // can mix up frames under load — return a previous
                  // request's response. If the echoed DID doesn't match,
                  // we'd attribute someone else's data to this DID and
                  // silently corrupt the analysis.
                  final echoedDid = rawUp.substring(2, 6);
                  if (echoedDid == did.toUpperCase()) {
                    rawHex = raw;
                    errorCode = null;
                    break;
                  } else {
                    errorCode = 'MISALIGNED:$echoedDid≠$did';
                    // mis-aligned frames are NOT retried — they indicate
                    // pipeline contamination that a retry won't fix.
                    break;
                  }
                } else if (raw.isEmpty) {
                  errorCode = 'EMPTY';
                  // Retry once after a short pause.
                  if (attempt == 0) {
                    await Future.any<void>([
                      Future<void>.delayed(const Duration(milliseconds: 150)),
                      killSignal.future,
                    ]);
                    if (killSignal.isCompleted) break;
                    continue;
                  }
                } else {
                  errorCode = 'MALFORMED:$raw';
                  break;
                }
              } catch (e) {
                errorCode = 'TIMEOUT';
                break;
              }
            }

            _liveLogLastRaw['$txEcu/$did'] = rawHex ?? errorCode;

            // v0.1.21: sanity-check raw value before recording. Two layers:
            //
            //   Layer 1 (per-DID): registry-driven sanity range. Catches
            //   0xFFFF "data not available" from BMS under heavy load
            //   (observed on 790/0x0015 during regen → 1638 V in graphs),
            //   ELM frame misalignment producing wildly wrong values, and
            //   garbled BLE responses that happen to parse as numbers.
            //
            //   Layer 2 (cell pair): cross-validation between 790/0x002B
            //   and 790/0x002D in the SAME cycle. If max < min or
            //   |spread| > 100 mV, both reads are flagged because we
            //   can't tell which one was the ELM misalignment victim.
            //   Without this, ~3.6% of driving samples leak negative
            //   spreads into the DB (verified in session 13: 27 / 159
            //   cycles).
            //
            // On guard hit we replace rawHex with null and set errorCode
            // to 'SANITY:*'. The entry is still inserted (so the cycle's
            // structure is preserved and you can see what was rejected),
            // but downstream parsing (livelog_wide.csv, trip aggregation)
            // treats it as missing data.
            if (rawHex != null && errorCode == null) {
              final guardError = _livelogSanityCheck(txEcu, did, rawHex);
              if (guardError != null) {
                errorCode = guardError;
                rawHex = null;
              }
            }

            // v0.1.29+21: hard timeout on the DB insert. Drift's sqflite
            // serializes writes; if CloudSyncService holds the writer
            // (or anything else deadlocks) we previously blocked here
            // indefinitely with no recovery — observed as session 1
            // freezing at cycle 5/004C on 2026-05-25 (33 entries then
            // 31 minutes of silence). 5s is generous: a healthy insert
            // is sub-millisecond on this device. Dropping a single
            // entry is preferable to grinding the whole drive.
            //
            // v0.1.29+22: also raced against killSignal so a watchdog
            // stall / cancel command unblocks the await even if Drift
            // is wedged. The insert future is allowed to settle in the
            // background (no-op error handler attached); we don't need
            // its result once the loop is exiting.
            try {
              final insertFuture = db
                  .insertLiveLogEntry(LiveLogEntriesCompanion(
                    sessionId: Value(sessionId),
                    timestamp: Value(DateTime.now()),
                    ecuTx: Value(txEcu),
                    did: Value(did),
                    rawHex: Value(rawHex),
                    errorCode: Value(errorCode),
                    cycle: Value(_liveLogCycle),
                  ))
                  .timeout(const Duration(seconds: 5));
              unawaited(
                  insertFuture.then((_) {}, onError: (Object _) {}));
              final raceResult = await Future.any<Object?>([
                insertFuture.then<Object?>((v) => v),
                killSignal.future.then<Object?>((_) => _killedSentinel),
              ]);
              if (identical(raceResult, _killedSentinel) ||
                  killSignal.isCompleted) {
                // killed — break out of the per-DID loop; entry NOT
                // counted, _liveLogLastEntryAt NOT updated.
                break;
              }
              entryCount++;
              _liveLogWrittenCount = entryCount;
              _liveLogLastEntryAt = DateTime.now();
            } on TimeoutException {
              debugPrint('runLiveLog: insertLiveLogEntry timeout for '
                  '$txEcu/$did cycle=$_liveLogCycle — entry dropped');
              // intentionally do NOT update _liveLogLastEntryAt so the
              // watchdog can detect a sustained DB stall and break.
            }
          } catch (e, st) {
            debugPrint('runLiveLog: per-DID block threw for $txEcu/$did: $e\n$st');
            // continue to the next DID — one bad DID must not kill
            // the whole session.
          }
        }

        // v0.1.21: cell pair cross-validation, performed AFTER the
        // whole cycle's DIDs have been written. Looks up the entries
        // we just wrote for 790/0x002B and 790/0x002D this cycle, and
        // if both passed Layer 1 but together fail the pair test,
        // post-update them to errorCode='SANITY:PAIR'.
        //
        // v0.1.29+21: bounded by an outer timeout. The guard has its
        // own try/catch but reads + updates Drift; if those calls
        // deadlock the whole loop deadlocked. 5s is plenty for a
        // cheap-query + at-most-2 updates path.
        //
        // v0.1.29+22: raced against killSignal so it can't outlast a
        // watchdog/cancel.
        try {
          final guardFuture = _livelogCellPairGuard(db, sessionId)
              .timeout(const Duration(seconds: 5));
          unawaited(
              guardFuture.then((_) {}, onError: (Object _) {}));
          await Future.any<void>([
            guardFuture,
            killSignal.future,
          ]);
        } catch (e) {
          debugPrint('runLiveLog: cell pair guard timeout/error: $e');
        }
        if (killSignal.isCompleted) break;

        onCycle?.call(_liveLogCycle);
        notifyListeners();

        // v0.1.17: 200ms inter-cycle gap — additional breather before
        // the next round of DIDs hits the bus. NOTE: the per-DID gap
        // moved to the TOP of each iteration in v0.1.18 (adaptive on
        // same-ECU vs different-ECU), so no post-DID gap needed here.
        //
        // v0.1.29+22: raced against killSignal so a cancel doesn't wait
        // out the 200ms.
        await Future.any<void>([
          Future<void>.delayed(const Duration(milliseconds: 200)),
          killSignal.future,
        ]);
      }
      // v0.1.29+21: if we exited via _liveLogCancelled (the stop
      // command path) and no other reason was recorded, attribute it.
      // v0.1.29+22: also handle killSignal-only exits (e.g., direct
      // call to cancelLiveLog which fires both flag and signal, or
      // watchdog_stall path which sets the reason itself).
      _liveLogExitReason ??=
          _liveLogCancelled ? 'cancelled' : 'unknown';
    } catch (e, st) {
      // v0.1.29+21: top-level safety net. If anything escapes the inner
      // try/catches we still want the finally to run cleanly so polling
      // resumes and the UI unsticks. Without this, an uncaught
      // exception here would skip the finally's _polling=true reset
      // and the user's dashboard would stay frozen.
      debugPrint('runLiveLog: unhandled exception in main loop: $e\n$st');
      _liveLogExitReason ??= 'loop_exception';
    } finally {
      // v0.1.29+22: stop the periodic watchdog and release the kill
      // signal handle BEFORE the final DB write. The signal is no
      // longer useful (we're already in cleanup) and any orphaned
      // BLE/DB futures will be allowed to settle in the background.
      _liveLogWatchdogTimer?.cancel();
      _liveLogWatchdogTimer = null;
      _liveLogKillSignal = null;

      // v0.1.29+21: finalize the session row defensively. Previously a
      // Drift hang here would propagate out of runLiveLog and the
      // .then() in BridgeDiagService would treat the session as
      // crashed — but worse, _polling and _pollLoop() never resumed,
      // so the trip detector and dashboard data stayed dead. Wrap in
      // try/timeout so the polling restore below always happens.
      try {
        final exitTag = _liveLogExitReason ?? 'unknown';
        final finalNotes = notes != null
            ? '$notes | exit=$exitTag'
            : 'exit=$exitTag';
        await (db.update(db.liveLogSessions)
              ..where((s) => s.id.equals(sessionId)))
            .write(LiveLogSessionsCompanion(
              endedAt: Value(DateTime.now()),
              cycleCount: Value(_liveLogCycle),
              entryCount: Value(entryCount),
              notes: Value(finalNotes),
            ))
            .timeout(const Duration(seconds: 10));
      } catch (e, st) {
        debugPrint('runLiveLog: failed to write final session row: $e\n$st');
        // Swallow — restoring polling below matters more than this row.
      }

      _liveLogRunning = false;
      _liveLogCancelled = false;
      _liveLogLastEntryAt = null;
      if (wasPolling) {
        _polling = true;
        _pollLoop();
      }
      notifyListeners();
    }

    return sessionId;
  }


  /// Run a one-shot DTC scan across all known ECUs.
  ///
  /// Pauses normal polling for the duration of the scan to avoid BLE
  /// bus contention. Resumes polling afterwards if it was active.
  ///
  /// Calls [onProgress] before each ECU is scanned (for UI progress bar).
  /// Returns one [DtcScanEcuResult] per ECU.
  Future<List<DtcScanEcuResult>> runDtcScan({
    void Function(int done, int total, String currentEcu)? onProgress,
  }) async {
    if (_client == null) {
      return _dtcEcus
          .map((e) => DtcScanEcuResult(
                tx: e.$1,
                rx: e.$2,
                name: e.$3,
                sessionOk: false,
                dtcs: const [],
                errors: const ['client not connected'],
              ))
          .toList();
    }
    if (_dtcScanRunning) {
      return [];
    }
    // v0.1.15: DTC scan also uses single BLE channel — refuse if sweep
    // or liveLog active. Returns empty list rather than null because
    // method signature is non-nullable.
    if (_sweepRunning || _liveLogRunning) {
      return [];
    }
    // v0.1.29+28: also exclude CAN passive monitor.
    if (_canMonitorRunning) {
      return [];
    }
    _dtcScanRunning = true;
    notifyListeners();

    final wasPolling = _polling;
    if (wasPolling) {
      _polling = false;
      // v0.1.17: wait until the in-flight poll cycle actually finishes.
      // Previously a hardcoded 400ms wait was used — fine for cycle gaps,
      // but a full polling cycle now takes 5-8s (30+ DIDs), so 400ms left
      // _pollEcu in the middle of its readDid chain. Result: live-log
      // readDid calls interleaved with polling readDid → both got EMPTY
      // responses because the BLE channel was effectively shared.
      await _waitForPollIdle();
    }

    final results = <DtcScanEcuResult>[];

    try {
      for (int i = 0; i < _dtcEcus.length; i++) {
        final (tx, rx, name) = _dtcEcus[i];
        onProgress?.call(i, _dtcEcus.length, '$tx $name');

        // v0.1.7.1: abort early if BLE link died during scan.
        // Without this, subsequent .query() calls throw obscure
        // "set notify value, device is disconnected" exceptions and
        // leave stale BLE state behind that prevents reconnection.
        if (_ble != null && !_ble!.isConnected) {
          results.add(DtcScanEcuResult(
            tx: tx,
            rx: rx,
            name: name,
            sessionOk: false,
            dtcs: const [],
            errors: const ['BLE link lost — scan aborted'],
          ));
          // Mark all remaining ECUs as not-scanned too, for clarity.
          for (int j = i + 1; j < _dtcEcus.length; j++) {
            final (jtx, jrx, jname) = _dtcEcus[j];
            results.add(DtcScanEcuResult(
              tx: jtx,
              rx: jrx,
              name: jname,
              sessionOk: false,
              dtcs: const [],
              errors: const ['skipped (link lost earlier)'],
            ));
          }
          break;
        }

        bool sessionOk = false;
        final dtcs = <DtcRecord>[];
        final errors = <String>[];

        try {
          // Enter extended diagnostic session (1003).
          final sess = await _client!
              .query('1003', txId: tx, rxId: rx)
              .timeout(const Duration(seconds: 2));
          sessionOk = sess.any((r) => r.rawHex.startsWith('5003'));
        } catch (e) {
          errors.add('session: $e');
        }

        // v0.1.7.1: small pause between session control and DTC read.
        // Some ECUs need a moment to transition into extended mode before
        // accepting further service requests (especially after NRC=78).
        await Future.delayed(const Duration(milliseconds: 80));

        // Try two status masks. Aggregate decoded DTCs without dups.
        for (final mask in const ['09', 'FF']) {
          if (_ble != null && !_ble!.isConnected) {
            errors.add('1902$mask: link lost during probe');
            break;
          }
          try {
            final resps = await _client!
                .query('1902$mask', txId: tx, rxId: rx)
                .timeout(const Duration(milliseconds: 2500));
            if (resps.isEmpty) {
              continue;
            }
            final r = resps.firstWhere(
              (x) => x.rxId == rx,
              orElse: () => resps.first,
            );
            final raw = r.rawHex;
            if (r.error != null && r.error!.contains('NEG')) {
              errors.add('1902$mask: ${r.error}');
              // Brief pause after NRC — 0x78 (responsePending) and others
              // sometimes leave the adapter in a sensitive state. Give it
              // 100ms to settle before the next request.
              await Future.delayed(const Duration(milliseconds: 100));
              continue;
            }
            if (!raw.toUpperCase().startsWith('5902')) {
              continue;
            }
            final decoded = _decodeDtcs(raw);
            for (final d in decoded) {
              if (!dtcs.any((existing) =>
                  existing.code == d.code && existing.status == d.status)) {
                dtcs.add(d);
              }
            }
          } catch (e) {
            errors.add('1902$mask: $e');
            // If the link is reported dead, abort early to prevent further
            // calls from piling up exception-on-disconnected-device errors.
            if (_ble != null && !_ble!.isConnected) break;
          }

          // Small pause between consecutive UDS reads on the same ECU.
          await Future.delayed(const Duration(milliseconds: 60));
        }

        results.add(DtcScanEcuResult(
          tx: tx,
          rx: rx,
          name: name,
          sessionOk: sessionOk,
          dtcs: List.unmodifiable(dtcs),
          errors: List.unmodifiable(errors),
        ));

        // v0.1.7.1: pause between ECUs gives the adapter time to switch
        // contexts (ATSH header change + filter reset). Without this the
        // BLE buffer can overflow on the cheap clones.
        await Future.delayed(const Duration(milliseconds: 150));
      }
      onProgress?.call(_dtcEcus.length, _dtcEcus.length, 'done');
    } catch (e) {
      // Any unexpected exception — log into a synthetic result row and let
      // the UI display it. Don't let one bad scan blow up the whole service.
      results.add(DtcScanEcuResult(
        tx: '—',
        rx: '—',
        name: 'scan error',
        sessionOk: false,
        dtcs: const [],
        errors: ['unhandled: $e'],
      ));
    } finally {
      _dtcScanRunning = false;

      // v0.1.7.1: if BLE died during the scan, mark service as disconnected
      // so the UI's "Adapter status" reflects reality and a reconnect can
      // be initiated by the user via Settings.
      if (_ble != null && !_ble!.isConnected) {
        _setStatus(ConnectionStatus.disconnected,
            msg: 'Адаптер отключился во время DTC скана');
        try {
          await _ble?.disconnect();
        } catch (_) {}
        _ble = null;
        _client = null;
        _polling = false;
      } else if (wasPolling) {
        _polling = true;
        _pollLoop();
      }
      notifyListeners();
    }

    return results;
  }

  /// Decode UDS 19/02 positive response payload into DTC records.
  ///
  /// Format per ISO 14229:
  ///   59 02 <statusAvailMask> {<b1><b2><b3><status>}*
  /// Each DTC is 4 bytes: 3 bytes code + 1 byte status.
  ///
  /// Code letter encoding (top 2 bits of b1):
  ///   00 → P (powertrain)
  ///   01 → C (chassis)
  ///   10 → B (body)
  ///   11 → U (network)
  static List<DtcRecord> _decodeDtcs(String rawHex) {
    final upper = rawHex.toUpperCase();
    if (upper.length < 6 || !upper.startsWith('5902')) return const [];
    final payload = upper.substring(6); // skip "5902XX"
    final result = <DtcRecord>[];
    for (int i = 0; i + 8 <= payload.length; i += 8) {
      final chunk = payload.substring(i, i + 8);
      final b1 = int.parse(chunk.substring(0, 2), radix: 16);
      final b2 = int.parse(chunk.substring(2, 4), radix: 16);
      final b3 = int.parse(chunk.substring(4, 6), radix: 16);
      final status = int.parse(chunk.substring(6, 8), radix: 16);
      // Skip all-zero padding entries
      if (b1 == 0 && b2 == 0 && b3 == 0 && status == 0) continue;

      final letterIdx = (b1 >> 6) & 0x03;
      final letter = 'PCBU'[letterIdx];
      final digitHigh = (b1 >> 4) & 0x03;
      final digitRest = b1 & 0x0F;
      final code =
          '$letter$digitHigh${digitRest.toRadixString(16).toUpperCase()}'
          '${b2.toRadixString(16).padLeft(2, '0').toUpperCase()}';
      final codeFull =
          '$code-${b3.toRadixString(16).padLeft(2, '0').toUpperCase()}';

      result.add(DtcRecord(
        code: code,
        codeFull: codeFull,
        rawHex: chunk,
        status: status,
      ));
    }
    return result;
  }

  // ===========================================================================
  // v0.1.21: Live-log sanity guards
  // ===========================================================================

  /// Layer 1: per-DID sanity check using registry-supplied ranges.
  ///
  /// Returns null on pass, or 'SANITY:*' tag on rejection.
  /// Expects [rawHex] in the format Claude/raw response uses:
  /// '62' + did + payload (e.g. '6200151234' → payload='1234').
  String? _livelogSanityCheck(String txEcu, String did, String rawHex) {
    // Find the DidSpec in registry (search across all known ECUs).
    // Note: EcuRegistryEntry.detailed is nullable — some entries are
    // bare label-only stubs without DID specs. Skip those.
    DidSpec? spec;
    for (final ecu in allBz5Ecus) {
      final detailed = ecu.detailed;
      if (detailed == null) continue;
      if (detailed.txId.toUpperCase() != txEcu.toUpperCase()) continue;
      for (final d in detailed.dids) {
        if (d.did.toUpperCase() == did.toUpperCase()) {
          spec = d;
          break;
        }
      }
      if (spec != null) break;
    }
    // No spec → no sanity rules → pass.
    if (spec == null) return null;
    if (spec.sanityRawMin == null &&
        spec.sanityRawMax == null &&
        spec.expectedBytes == null) {
      return null;
    }

    // Strip '62' + did header to get payload hex.
    final didLen = did.length;
    if (rawHex.length < 2 + didLen) return null;
    final payload = rawHex.substring(2 + didLen);

    // Need at least 1 byte to parse.
    if (payload.isEmpty) return null;

    int raw;
    try {
      raw = int.parse(payload, radix: 16);
    } catch (_) {
      return 'SANITY:UNPARSEABLE';
    }

    return spec.checkSanityRaw(raw);
  }

  /// Layer 2: cell-pair cross-validation.
  ///
  /// After a full livelog cycle is written, looks at the entries this
  /// cycle wrote for 790/0x002B (cell min) and 790/0x002D (cell max).
  /// If both passed Layer 1 and parse as numbers, but together fail
  /// physical sanity (max < min or |spread| > 100 mV), post-updates
  /// both entries to errorCode='SANITY:PAIR'.
  ///
  /// Why two layers: a single ELM frame can swap responses between two
  /// DIDs polled in the same cycle. A Layer-1 sanity range on each
  /// individually would still pass (both values are physically possible
  /// for cells in isolation), but the pair becomes impossible. Catching
  /// it requires looking at them together.
  ///
  /// Drop rate measured on session 13 driving data: 14 / 384 cycles
  /// (3.6%) — exactly matches the rate observed before any guards.
  Future<void> _livelogCellPairGuard(
      AppDatabase db, int sessionId) async {
    try {
      final cycle = _liveLogCycle;
      final entries = await db.getLiveLogEntriesForCycle(sessionId, cycle);

      LiveLogEntry? minEntry;
      LiveLogEntry? maxEntry;
      for (final e in entries) {
        if (e.ecuTx.toUpperCase() == '790' &&
            e.did.toUpperCase() == '002B' &&
            e.rawHex != null &&
            e.errorCode == null) {
          minEntry = e;
        }
        if (e.ecuTx.toUpperCase() == '790' &&
            e.did.toUpperCase() == '002D' &&
            e.rawHex != null &&
            e.errorCode == null) {
          maxEntry = e;
        }
      }
      if (minEntry == null || maxEntry == null) return;

      // Both raw hexes are like '62002B0CD8' — payload last 4 chars.
      final minMv = int.tryParse(minEntry.rawHex!.substring(6), radix: 16);
      final maxMv = int.tryParse(maxEntry.rawHex!.substring(6), radix: 16);
      if (minMv == null || maxMv == null) return;

      final spread = maxMv - minMv;
      if (spread < 0 || spread.abs() > 100) {
        await db.markLiveLogEntryError(minEntry.id, 'SANITY:PAIR:$spread');
        await db.markLiveLogEntryError(maxEntry.id, 'SANITY:PAIR:$spread');
      }
    } catch (_) {
      // Best-effort: a guard failure must never crash the livelog loop.
    }
  }
}

/// v0.1.7: Single DTC record decoded from UDS 19/02 response.
class DtcRecord {
  /// Standard 5-char code, e.g. "C1880", "U1018", "P0420".
  final String code;

  /// Same as [code] but with extension byte appended, e.g. "C1880-16".
  /// The extension byte is sometimes a "failure type" or sub-code per
  /// manufacturer convention. Kept for completeness.
  final String codeFull;

  /// The 8-hex-character raw chunk this DTC was decoded from.
  final String rawHex;

  /// 1-byte status mask per ISO 14229.
  ///   bit 0: testFailed (active failure RIGHT NOW)
  ///   bit 1: testFailedThisOperationCycle
  ///   bit 2: pendingDTC
  ///   bit 3: confirmedDTC (occurred at least once and confirmed)
  ///   bit 4: testNotCompletedSinceLastClear
  ///   bit 5: testFailedSinceLastClear
  ///   bit 6: testNotCompletedThisOperationCycle
  ///   bit 7: warningIndicatorRequested
  final int status;

  const DtcRecord({
    required this.code,
    required this.codeFull,
    required this.rawHex,
    required this.status,
  });

  /// True if any of the "real fault" status bits are set
  /// (testFailed OR confirmedDTC OR pendingDTC).
  /// False means the entry exists in firmware but isn't currently a fault
  /// (e.g. "test not yet completed since last clear" — bit 4 only).
  bool get isActiveFault =>
      (status & 0x01) != 0 || (status & 0x08) != 0 || (status & 0x04) != 0;

  /// Human-readable summary of the status byte.
  String get statusSummary {
    final parts = <String>[];
    if (status & 0x01 != 0) parts.add('testFailed');
    if (status & 0x02 != 0) parts.add('failedThisCycle');
    if (status & 0x04 != 0) parts.add('pending');
    if (status & 0x08 != 0) parts.add('confirmed');
    if (status & 0x10 != 0) parts.add('notCompleteSinceClear');
    if (status & 0x20 != 0) parts.add('failedSinceClear');
    if (status & 0x40 != 0) parts.add('notCompleteThisCycle');
    if (status & 0x80 != 0) parts.add('warningRequested');
    if (parts.isEmpty) return 'inactive';
    return parts.join(', ');
  }
}

/// v0.1.7: Result of DTC scan for one ECU.
class DtcScanEcuResult {
  final String tx;
  final String rx;
  final String name;
  final bool sessionOk;
  final List<DtcRecord> dtcs;
  final List<String> errors;

  const DtcScanEcuResult({
    required this.tx,
    required this.rx,
    required this.name,
    required this.sessionOk,
    required this.dtcs,
    required this.errors,
  });

  int get activeFaultCount => dtcs.where((d) => d.isActiveFault).length;
  int get totalDtcCount => dtcs.length;
  bool get isClean => dtcs.isEmpty && errors.isEmpty;
}

/// v0.1.2: Snapshot per battery module. Contains both cell voltages and
/// both temperature sensors. Sensors that BMS doesn't report (e.g. M6 returns
/// 0xFF for both temp slots) are signalled via *Reported flags.
///
/// v0.1.3 NOTE: cellAmV/cellBmV — это НЕ две отдельные ячейки, как
/// предполагалось ранее. По данным реверса 2026-05-03 это **min и max
/// напряжения внутри модуля**, рассчитываемые BMS из ~14 ячеек модуля
/// (136 ячеек / 10 модулей = 13.6 ячеек/модуль). Используйте `cellMinmV`
/// и `cellMaxmV` геттеры для семантически верного доступа.
class ModuleSnapshot {
  final int index;
  final int? cellAmV;
  final int? cellBmV;
  final double? temp1C;
  final double? temp2C;
  final bool temp1Reported;
  final bool temp2Reported;

  const ModuleSnapshot({
    required this.index,
    this.cellAmV,
    this.cellBmV,
    this.temp1C,
    this.temp2C,
    required this.temp1Reported,
    required this.temp2Reported,
  });

  /// v0.1.3: семантический алиас — это min напряжение в модуле.
  int? get cellMinmV {
    if (cellAmV == null && cellBmV == null) return null;
    if (cellAmV == null) return cellBmV;
    if (cellBmV == null) return cellAmV;
    return cellAmV! < cellBmV! ? cellAmV : cellBmV;
  }

  /// v0.1.3: семантический алиас — это max напряжение в модуле.
  int? get cellMaxmV {
    if (cellAmV == null && cellBmV == null) return null;
    if (cellAmV == null) return cellBmV;
    if (cellBmV == null) return cellAmV;
    return cellAmV! > cellBmV! ? cellAmV : cellBmV;
  }

  double? get avgTemp {
    if (temp1C != null && temp2C != null) return (temp1C! + temp2C!) / 2;
    return temp1C ?? temp2C;
  }

  int? get cellDelta {
    if (cellAmV == null || cellBmV == null) return null;
    return (cellBmV! - cellAmV!).abs();
  }

  bool get hasAnyTemp => temp1Reported || temp2Reported;
}

/// v0.1.29+53: scheduler task descriptor. One instance per (DID or
/// DID-group, ECU) read job. Owned by ConnectionService via the three
/// task lists (_fastTasks/_mediumTasks/_slowTasks). Mutable lastRunAt
/// is updated by [ConnectionService._runTask] after each execution;
/// the scheduler uses it both to gate medium/slow tasks (lastRunAt +
/// period <= now ⇒ overdue) and as a tiebreaker in round-robin
/// (oldest run wins). ecuTx is used by the ECU round-robin guard —
/// scheduler avoids picking a candidate with the same ecuTx as the
/// last 4 reads when alternatives exist.
class _PollTask {
  /// Short human label for debugging / future diagnostics. Not used
  /// for scheduling logic.
  final String name;

  /// The ECU tx address this task reads from (e.g. '790', '740').
  /// Used ONLY for the round-robin guard. If a task internally reads
  /// from multiple ECUs (e.g. _pollExtraDids), set this to the
  /// dominant ECU — the round-robin guard is heuristic, not airtight.
  final String ecuTx;

  /// The function that does the actual read(s). Must catch its own
  /// errors (existing _pollSpeedOnly / _pollPackVoltageOnly /
  /// _pollCellExtremesOnly already do; _pollEcuFiltered does too).
  final Future<void> Function() execute;

  /// Last wall-clock time this task completed (or null if never run
  /// this session). Updated by [ConnectionService._runTask].
  DateTime? lastRunAt;

  _PollTask({
    required this.name,
    required this.ecuTx,
    required this.execute,
  });
}
