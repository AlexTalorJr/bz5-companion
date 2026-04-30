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

/// === BZ5 Physical Model ===
/// Калибровочные константы из реверс-инжиниринга
class Bz5Model {
  /// Паспортная ёмкость батареи (кВт·ч)
  static const double batteryCapacityKwh = 65.28;

  /// Scale для 0B00 charge counter — 1 unit = 0.0456 кВт·ч
  /// Откалибровано на 2.1 кВт зарядке: за 469 сек прирост = 6 единиц
  static const double chargeCounterWh = 45.6;

  /// Scale для 0009 discharge counter — 1 unit = ? Wh
  /// (нужна калибровка от поездки)
  static const double dischargeCounterWh = 0.07;  // оценка, может корректироваться

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
  
  // Tracking для discharge rate (drive)
  int? _last0009Value;
  DateTime? _last0009Time;
  double _instantaneousDrivePowerKw = 0.0;

  int? _currentTripId;
  int _samplesInTrip = 0;
  double? _tripStartSoc;
  double? _tripStartOdo;
  int? _tripStartCnt9;
  int? _tripStartB00;

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
  double get drivePowerKw => _instantaneousDrivePowerKw;

  /// Lifetime energy charged (kWh) since manufacturing
  double? get lifetimeChargedKwh {
    final b00 = readNumeric('790', '0B00');
    if (b00 == null) return null;
    return b00 * Bz5Model.chargeCounterWh / 1000.0;
  }

  /// Lifetime discharge counter raw (тоже накопитель но scale TBD)
  double? get lifetimeDischargeRaw {
    return readNumeric('790', '0009');
  }

  /// Range estimate в км
  double? get rangeEstimateKm {
    final soc = readNumeric('790', '0005');
    if (soc == null) return null;
    final remainingKwh = Bz5Model.batteryCapacityKwh * soc / 100.0;
    return remainingKwh * 1000 / Bz5Model.avgConsumptionWhKm;
  }

  /// Energy used this trip (kWh) — based on B00 delta
  double? get tripEnergyKwh {
    if (_tripStartB00 == null) return null;
    final cur = readNumeric('790', '0B00');
    if (cur == null) return null;
    return (cur - _tripStartB00!) * Bz5Model.chargeCounterWh / 1000.0;
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

  Future<bool> connect(BluetoothDevice device) async {
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
    _tripStartCnt9 = null;
    if (startTrip) _currentTripId = await db.startTrip();
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
      } catch (e) {
        debugPrint('Poll error: $e');
      }
      cycle++;
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  void _updatePowerCalculations() {
    final now = DateTime.now();
    
    // Charging power from 0B00
    final b00 = readNumeric('790', '0B00');
    if (b00 != null) {
      final b00Int = b00.toInt();
      if (_lastB00Value != null && _lastB00Time != null) {
        final dt = now.difference(_lastB00Time!).inMilliseconds / 1000.0;
        if (dt > 1.0) {  // обновляем не чаще раз в секунду
          final delta = b00Int - _lastB00Value!;
          // delta units × 45.6 Wh/unit ÷ dt seconds × 3600 / 1000 = kW
          _instantaneousChargingPowerKw = delta * Bz5Model.chargeCounterWh / dt * 3.6 / 1000.0;
          _lastB00Value = b00Int;
          _lastB00Time = now;
        }
      } else {
        _lastB00Value = b00Int;
        _lastB00Time = now;
      }
      _tripStartB00 ??= b00Int;
    }
    
    // Drive power from 0009
    final cnt9 = readNumeric('790', '0009');
    if (cnt9 != null) {
      final cnt9Int = cnt9.toInt();
      if (_last0009Value != null && _last0009Time != null) {
        final dt = now.difference(_last0009Time!).inMilliseconds / 1000.0;
        if (dt > 1.0) {
          final delta = cnt9Int - _last0009Value!;
          // С учётом приближённого scale 0.07 Wh/unit при 21.6/sec ≈ 1.5 W (не реалистично)
          // В реальности нужен scale ~0.5-1 Wh для получения kW
          // Используем для индикации только направления
          _instantaneousDrivePowerKw = delta > 0 ? delta * 0.5 / dt : 0;  // approx
          _last0009Value = cnt9Int;
          _last0009Time = now;
        }
      } else {
        _last0009Value = cnt9Int;
        _last0009Time = now;
      }
      _tripStartCnt9 ??= cnt9Int;
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
      notifyListeners();
    }
  }

  double? readNumeric(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.numeric;

  String? readText(String ecuTx, String did) =>
      _latestValues[ecuTx]?[did]?.text;

  double? get packVoltage {
    final v1 = readNumeric('740', '0014');
    final v2 = readNumeric('740', '0016');
    if (v1 == null && v2 == null) return null;
    if (v1 != null && v2 != null) return v1 + v2;
    return (v1 ?? v2)! * 2;
  }

  bool get isCharging {
    // Если кабель подключён ИЛИ B00 растёт
    final connState = readNumeric('782', '0057');
    if (connState != null && connState > 0) return true;
    return _instantaneousChargingPowerKw > 0.5;
  }
}
