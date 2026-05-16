import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/elm327_ble.dart';
import '../ble/elm327_client.dart';
import '../data/ecu_registry.dart';
import '../data/database.dart';

enum ConnectionStatus { disconnected, scanning, connecting, connected, error }
enum PollMode { driving, charging, full }

/// === BZ5 Physical Model (v5) ===
///
/// Калибровочные константы из реверс-инжиниринга 30 апреля - 1 мая 2026.
class Bz5Model {
  /// Паспортная ёмкость батареи (кВт·ч).
  /// Подтверждена ETA-калькуляцией приборки (13ч 26м при 2.8 кВт от 46% =
  /// 35.25 кВт·ч до полной → ёмкость 65.3 кВт·ч).
  static const double batteryCapacityKwh = 65.28;

  /// Scale для 0B00 charge counter — 1 unit ≈ 460 Wh.
  /// Откалибровано на полной зарядной сессии 48% → 100%:
  /// ΔSOC × ёмкость = 33.95 кВт·ч, Δ0x0B00 = +79 единиц
  /// 33950 / 79 ≈ 430 Wh/unit (DC-side), с учётом OBC efficiency ~88% AC-side ≈ 489 Wh/unit
  /// Усреднённое значение 460 Wh/unit ±10%.
  ///
  /// ⚠ NB! v6.1: idle sweeps на стоянке (2026-05-02) и в Ready+AC (2026-05-03)
  /// показали что counter НЕ ведёт себя как чистый cumulative energy counter:
  /// на стоянке убывает ~1 unit/95s (соответствовало бы фейковой нагрузке 17 кВт),
  /// в Ready колеблется в пределах ±1 unit без чёткого тренда.
  /// Калибровка 460 Wh/unit подтверждена только на зарядной сессии и сейчас
  /// используется только для дисплея энергии в trip-сессии. См. TODO ниже.
  static const double chargeCounterWh = 460.0;

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
  // Новая логика — окно `_chargingDetectionWindow`:
  //   isCharging =
  //     value(now) - value(now - window) ≥ _chargingDetectionMinNetDelta
  //     AND все промежуточные delta в окне неотрицательные
  //
  // На зарядке (любой мощности) counter растёт строго монотонно; глитчей
  // вниз не наблюдается. На стоянке и в Ready всегда есть отрицательные
  // delta в любом окне ≥10 минут — фильтр "no negatives" их режет.
  //
  // Trade-off: при slow AC charging 2.8 кВт первое срабатывание через
  // ~15-20 мин после plug-in (counter инкрементится ~раз в 10 мин при этой
  // мощности; нужно 2 инкремента в окне). На AC 7+ кВт и DC — почти сразу.
  final List<_B00Sample> _b00History = [];
  static const Duration _b00HistoryMaxAge = Duration(minutes: 20);
  static const Duration _chargingDetectionWindow = Duration(minutes: 15);
  static const int _chargingDetectionMinNetDelta = 2;

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
  double? _tripPeakSpeedKmh;     // will populate once speed DID identified
  double? _tripPeakPowerKw;      // 791/0x0038 magnitude
  double? _tripPeakRegenKw;      // most-negative power (regen)
  double? _tripRegenEnergyKwh;   // integrated regen power over time (estimate)

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

  ConnectionService(this.db);

  ConnectionStatus get status => _status;
  String? get statusMessage => _statusMessage;
  String? get adapterAddress => _adapterAddress;
  int? get currentTripId => _currentTripId;
  bool get isPolling => _polling;
  PollMode get pollMode => _pollMode;
  Map<String, Map<String, DecodedValue>> get latestValues => _latestValues;
  List<int> get liveCells => _liveCells;

  double get chargingPowerKw => _instantaneousChargingPowerKw;

  /// Cycle count from BMS DID 0B02 — likely full-charge equivalent cycles
  int? get cycleCount {
    final v = readNumeric('790', '0B02');
    return v?.toInt();
  }

  /// Pack voltage realtime. v0.1.3: источник переключён с 790/0x0015 на 740/0x0022.
  ///
  /// Старый источник (790/0x0015 × 0.02) физически некорректный — выдавал
  /// 272-291 В на 81-82% SOC, что для 136-ячеечного LFP пакета невозможно
  /// (теор. 136 × 3.326 mV ≈ 452 V). См. логи sweep 2026-05-03 23:34
  /// и расчёты в conversation history.
  ///
  /// Новый источник (740/0x0022 × 0.025) проверен sweep'ом Pack Monitor:
  /// 18000 raw → 450.0 V — точно соответствует теории. Это filtered pack V
  /// (среднее за период). Дополнительно есть instant 740/0x0014 — может
  /// понадобиться для будущей диагностической карточки.
  ///
  /// Sanity range 350..550 V покрывает любой режим: charging-end ~470,
  /// resting LFP 80% ~452, deep discharge 10% ~410.
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

  double? get rangeEstimateKm {
    final soc = readNumeric('790', '0005');
    if (soc == null) return null;
    final remainingKwh = Bz5Model.batteryCapacityKwh * soc / 100.0;
    return remainingKwh * 1000 / Bz5Model.avgConsumptionWhKm;
  }

  double? get chargedThisSessionKwh {
    if (_tripStartB00 == null) return null;
    final cur = readNumeric('790', '0B00');
    if (cur == null) return null;
    final delta = cur - _tripStartB00!;
    if (delta <= 0) return null;
    return delta * Bz5Model.chargeCounterWh / 1000.0;
  }

  double? get tripEnergyKwh {
    if (_tripStartB00 == null) return null;
    final cur = readNumeric('790', '0B00');
    if (cur == null) return null;
    final delta = cur - _tripStartB00!;
    return delta * Bz5Model.chargeCounterWh / 1000.0;
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

  Future<void> startPolling({bool startTrip = true}) async {
    if (_client == null || _polling) return;
    _polling = true;
    _samplesInTrip = 0;
    _tripStartB00 = null;
    _wantTripCreation = startTrip;
    _pollCyclesSinceStart = 0;
    _cellSpreadHistory.clear();
    // v6.1: reset rolling-window charging detection state
    _b00History.clear();
    _instantaneousChargingPowerKw = 0.0;
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
    // v0.1.9: reset trip aggregates and snapshot timer.
    _tripMinTempC = null;
    _tripMaxTempC = null;
    _tripMaxCellSpreadMv = null;
    _tripMinSoc = null;
    _tripMaxSoc = null;
    _tripPeakSpeedKmh = null;
    _tripPeakPowerKw = null;
    _tripPeakRegenKw = null;
    _tripRegenEnergyKwh = null;
    _lastSnapshotAt = null;
    _tripStartedAt = null;
    _pollLoop();
    notifyListeners();
  }

  Future<void> stopPolling() async {
    _polling = false;
    if (_currentTripId != null) {
      final endSoc = _latestValues['790']?['0005']?.numeric;
      final endOdo = _latestValues['791']?['0026']?.numeric;

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

  List<EcuSpec> get _ecusToPoll {
    switch (_pollMode) {
      case PollMode.driving: return pollEcusDriving;
      case PollMode.charging: return pollEcusCharging;
      case PollMode.full: return pollEcusFull;
    }
  }

  Future<void> _pollLoop() async {
    int cycle = 0;
    while (_polling && _client != null) {
      try {
        for (final ecu in _ecusToPoll) {
          await _pollEcu(ecu);
        }
        if (cycle % 2 == 0) await _pollCells();
        // v0.1.3: extra DIDs (pack V from 740, cell indices, pack config).
        // Каждый второй цикл — частоты обновления pack V раз в ~500 мс
        // достаточно, не надо мучить шину.
        if (cycle % 2 == 1) await _pollExtraDids();
        _updatePowerCalculations();
        await _maybeStartTrip();
        // v0.1.9: rolling trip aggregates + periodic snapshot to DB.
        _updateTripAggregates();
        await _maybeWriteSnapshot();
      } catch (e) {
        debugPrint('Poll error: $e');
      }
      cycle++;
      _pollCyclesSinceStart++;
      await Future.delayed(const Duration(milliseconds: 250));
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
      _currentTripId = await db.startTrip();
      _tripStartedAt = DateTime.now();
      _wantTripCreation = false;
      debugPrint('Trip #$_currentTripId created.');
    }
    notifyListeners();
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
      // 0x002F is offset −40
      final tempC = temp - 40;
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
    final pwr = readNumeric('791', '0038');
    if (pwr != null) {
      final kw = pwr.abs(); // assume already in kW after scale=0.1
      _tripPeakPowerKw = _tripPeakPowerKw == null ? kw : (kw > _tripPeakPowerKw! ? kw : _tripPeakPowerKw);
    }

    // TODO: peakSpeedKmh once speed DID identified
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
    final tempRaw = readNumeric('790', '002F');
    final tempC = tempRaw != null ? tempRaw - 40 : null;
    final cellMin = globalMinCellMv?.toDouble();
    final cellMax = globalMaxCellMv?.toDouble();
    final spread = (cellMin != null && cellMax != null) ? (cellMax - cellMin) : null;
    final odo = readNumeric('791', '0026');
    final packV = packVoltageV;
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
        packVoltageV: Value(packV),
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

  /// v6.1: обновление истории 0x0B00 + расчёт мгновенной мощности зарядки.
  ///
  /// Старая версия v6 использовала единственное значение `_lastB00Value` и
  /// мгновенный delta; любой stale-read давал false-positive (бесконечный
  /// banner "Charging Connected" на стоянке). Новая версия:
  ///  - ведёт rolling history последних 20 минут
  ///  - дописывает snapshot при изменении значения ИЛИ раз в 10 секунд
  ///  - мгновенная мощность считается из последнего положительного delta
  ///  - сама детекция зарядки делегирована getter'у [isCharging]
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

    // Instantaneous charging power: based on last positive transition only.
    if (_b00History.length >= 2) {
      final cur = _b00History[_b00History.length - 1];
      final prev = _b00History[_b00History.length - 2];
      final delta = cur.value - prev.value;
      final dt = cur.time.difference(prev.time).inMilliseconds / 1000.0;
      if (delta > 0 && dt > 1.0) {
        _instantaneousChargingPowerKw =
            delta * Bz5Model.chargeCounterWh / dt * 3.6 / 1000.0;
      } else {
        _instantaneousChargingPowerKw = 0.0;
      }
    }
  }

  Future<void> _pollEcu(EcuSpec ecu) async {
    if (_client == null) return;

    for (final spec in ecu.dids) {
      if (spec.category == DidCategory.cells) continue;

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
          }
          if (spec.did == '0026' && ecu.txId == '791' && _tripStartOdo == null) {
            _tripStartOdo = decoded.numeric;
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
    try {
      final r = await _client!.readDid('002B', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final mv = (p[0] << 8) | p[1];
        // Sanity: realistic LFP cell range 2000..3700 mV
        if (mv >= 2000 && mv <= 3700) _globalMinCellMv = mv;
      }
    } catch (_) {}

    // v0.1.6: Global max cell voltage (790/0x002D).
    try {
      final r = await _client!.readDid('002D', tx: '790', rx: '798')
          .timeout(const Duration(milliseconds: 1000));
      final p = r?.payloadAfterUdsRead;
      if (p != null && p.length >= 2) {
        final mv = (p[0] << 8) | p[1];
        if (mv >= 2000 && mv <= 3700) _globalMaxCellMv = mv;
      }
    } catch (_) {}

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

    notifyListeners();
  }

  double? readNumeric(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.numeric;

  String? readText(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.text;

  /// v6.1: Детекция зарядки через rolling-window анализ 0x0B00.
  ///
  /// Условие: за последние [_chargingDetectionWindow] минут счётчик вырос
  /// строго монотонно (без отрицательных delta) на ≥ [_chargingDetectionMinNetDelta].
  ///
  /// Калибровка на реальных idle-данных (см. описание _b00History):
  ///  - Машина выключена, парковка: counter монотонно убывает; даже если
  ///    бы не убывал, отсутствие положительных delta даст false.
  ///  - Машина в Ready+AC: counter колеблется ±1 around point; в любом
  ///    окне ≥10 мин найдутся отрицательные delta → false.
  ///  - На зарядке любой мощности: counter растёт строго монотонно →
  ///    окно содержит только положительные/нулевые delta, net growth ≥ 2
  ///    достигается за 10-20 мин (slow AC) или быстрее.
  ///
  /// Latency на slow AC ~2.8 кВт: первое срабатывание через ~15-20 минут
  /// после plug-in. Это приемлемо для ночной домашней зарядки и сильно
  /// лучше чем "banner висит сутками на стоящей машине".
  bool get isCharging {
    if (_b00History.length < 2) return false;

    final now = DateTime.now();
    final windowStart = now.subtract(_chargingDetectionWindow);

    // Need history covering the entire window. If oldest sample is younger
    // than windowStart, we just started polling — wait.
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
    ('740', '748', 'Pack Monitor'),
    ('744', '74C', 'Pack Monitor 2'),
    ('745', '74D', 'Pack Monitor 3'),
    ('752', '75A', 'BMS Slave 1'),
    ('753', '75B', 'BMS Slave 2'),
    ('782', '78A', 'OBC'),
    ('757', '75F', 'GPS Asensing'),
  ];

  bool _dtcScanRunning = false;
  bool get dtcScanRunning => _dtcScanRunning;

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
    _dtcScanRunning = true;
    notifyListeners();

    final wasPolling = _polling;
    if (wasPolling) {
      _polling = false;
      // Give any in-flight poll a moment to finish before we hammer the bus.
      await Future.delayed(const Duration(milliseconds: 400));
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
