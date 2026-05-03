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
  int _samplesInTrip = 0;
  double? _tripStartSoc;
  double? _tripStartOdo;
  int? _tripStartB00;

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
  // Найдено в реверсе 2026-05-03 (см. README/findings).
  double? _packVoltageFilteredV;     // 740/0x0022
  double? _packVoltageInstantV;      // 740/0x0014
  int? _globalMinCellIndex;          // 790/0x002C
  int? _globalMaxCellIndex;          // 790/0x002E
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

  /// Secondary bus voltage (790/0x0015 × 0.02). Что ИМЕННО это — пока
  /// неизвестно: на 81% SOC выдаёт 281-291 В, на 50% SOC — 334 В.
  /// Возможно: precharge sense / DC link / OBC side. Не используется
  /// в основном UI; оставлен на случай если позже расшифруем.
  /// TODO: monitor этого DID при precharge / contactor close / Ready / charging.
  double? get secondaryBusV {
    final v = readNumeric('790', '0015');
    if (v == null) return null;
    if (v < 100 || v > 500) return null;
    return v;
  }

  /// v0.1.3: индекс ячейки с минимальным напряжением в пакете (0..135).
  /// Меняется в реальном времени по мере того как BMS пересортировывает
  /// слабую ячейку. Замеры 2026-05-03: 21:17 идекс=34, 23:58 индекс=30.
  int? get globalMinCellIndex => _globalMinCellIndex;

  /// v0.1.3: индекс ячейки с максимальным напряжением в пакете (0..135).
  int? get globalMaxCellIndex => _globalMaxCellIndex;

  /// v0.1.3: общее количество ячеек в пакете (BMS reports 136).
  /// Читается один раз при подключении из 790/0x0B03.
  int? get packCellCount => _packCellCount;

  /// v0.1.3: количество модулей в пакете (BMS reports 10).
  /// Читается один раз при подключении из 790/0x0A07.
  int? get packModuleCount => _packModuleCount;

  /// v5: Parking pawl engaged. DID 0x0007 на VCU.
  bool? get parkingPawlEngaged {
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
    _pollLoop();
    notifyListeners();
  }

  Future<void> stopPolling() async {
    _polling = false;
    if (_currentTripId != null) {
      final endSoc = _latestValues['790']?['0005']?.numeric;
      final endOdo = _latestValues['791']?['0026']?.numeric;
      await db.endTrip(_currentTripId!,
          endSoc: endSoc, endOdo: endOdo, sampleCount: _samplesInTrip);
      _currentTripId = null;
    }
    _wantTripCreation = false;
    notifyListeners();
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
      _wantTripCreation = false;
      debugPrint('Trip #$_currentTripId created.');
    }
    notifyListeners();
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
