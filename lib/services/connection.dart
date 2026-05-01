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
  static const double chargeCounterWh = 460.0;

  /// Pack voltage scale: DID 0x0015, raw × 0.02 V.
  /// Подтверждено двумя способами: на 100% SOC raw=18077 → 361.5 V (норма LFP),
  /// в поездке raw=17445-18077 → 348.9-361.5 V (физически реалистичный диапазон).
  static const double packVoltageScale = 0.02;

  /// Pack voltage "no data" sentinel. BMS возвращает 0xFFFF если значение
  /// не успело обновиться или есть внутренняя ошибка. Игнорируем.
  static const int packVoltageInvalidRaw = 0xFFFF;

  /// Средний расход BZ5 по приборке = 14.4 кВт·ч / 100 км = 144 Wh/km
  static const double avgConsumptionWhKm = 144.0;
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

  // Tracking для charging power calculation
  int? _lastB00Value;
  DateTime? _lastB00Time;
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

  /// v5: Pack voltage realtime. DID 0x0015 на BMS, scale × 0.02 V.
  /// Возвращает null если raw = 0xFFFF (BMS no-data sentinel).
  double? get packVoltageV {
    final raw = readNumeric('790', '0015');
    if (raw == null) return null;
    final intRaw = raw.toInt();
    if (intRaw == Bz5Model.packVoltageInvalidRaw) return null;
    if (intRaw < 10000 || intRaw > 25000) return null; // sanity check
    return intRaw * Bz5Model.packVoltageScale;
  }

  /// v5: Parking pawl engaged. DID 0x0007 на VCU.
  /// Verified в gear-mapping тесте: 1 = engaged (P), 0 = released (R/N/D).
  bool? get parkingPawlEngaged {
    final raw = readNumeric('791', '0007');
    if (raw == null) return null;
    return raw.toInt() == 1;
  }

  /// Range estimate в км
  double? get rangeEstimateKm {
    final soc = readNumeric('790', '0005');
    if (soc == null) return null;
    final remainingKwh = Bz5Model.batteryCapacityKwh * soc / 100.0;
    return remainingKwh * 1000 / Bz5Model.avgConsumptionWhKm;
  }

  /// v5: Charged this session (kWh) — Δ от старта polling.
  /// Заменяет старый "Lifetime in" который был ненадёжный из-за неизвестной
  /// начальной точки счётчика 0x0B00.
  double? get chargedThisSessionKwh {
    if (_tripStartB00 == null) return null;
    final cur = readNumeric('790', '0B00');
    if (cur == null) return null;
    final delta = cur - _tripStartB00!;
    if (delta <= 0) return null;
    return delta * Bz5Model.chargeCounterWh / 1000.0;
  }

  /// Trip energy used (kWh) - based on B00 delta
  double? get tripEnergyKwh {
    if (_tripStartB00 == null) return null;
    final cur = readNumeric('790', '0B00');
    if (cur == null) return null;
    final delta = cur - _tripStartB00!;
    return delta * Bz5Model.chargeCounterWh / 1000.0;
  }

  /// v5: Smoothed cell spread (median of last 10 readings).
  /// Avoids flicker from instantaneous load spikes during driving.
  int? get smoothedCellSpread {
    if (_cellSpreadHistory.isEmpty) return null;
    final sorted = List<int>.from(_cellSpreadHistory)..sort();
    return sorted[sorted.length ~/ 2];
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
      _setStatus(ConnectionStatus.error, msg: '$e');
      _client = null;
      _ble = null;
      return false;
    }
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

  void _updatePowerCalculations() {
    final now = DateTime.now();
    final b00 = readNumeric('790', '0B00');
    if (b00 != null) {
      final b00Int = b00.toInt();
      if (_lastB00Value != null && _lastB00Time != null) {
        final dt = now.difference(_lastB00Time!).inMilliseconds / 1000.0;
        if (dt > 1.0) {
          final delta = b00Int - _lastB00Value!;
          _instantaneousChargingPowerKw =
              delta * Bz5Model.chargeCounterWh / dt * 3.6 / 1000.0;
          _lastB00Value = b00Int;
          _lastB00Time = now;
        }
      } else {
        _lastB00Value = b00Int;
        _lastB00Time = now;
      }
      _tripStartB00 ??= b00Int;
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
      // v5: track rolling spread for SOC-aware threshold display
      final spread = cells.reduce((a, b) => a > b ? a : b)
                   - cells.reduce((a, b) => a < b ? a : b);
      _cellSpreadHistory.add(spread);
      while (_cellSpreadHistory.length > _cellSpreadHistoryMax) {
        _cellSpreadHistory.removeAt(0);
      }
      notifyListeners();
    }
  }

  double? readNumeric(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.numeric;

  String? readText(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.text;

  bool get isCharging {
    final connState = readNumeric('782', '0057');
    if (connState != null && connState > 0) return true;
    return _instantaneousChargingPowerKw > 0.5;
  }
}
