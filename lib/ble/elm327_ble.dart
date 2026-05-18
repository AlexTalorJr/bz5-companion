import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Транспорт к ELM327 BLE-адаптеру.
/// Автодетект GATT-схемы, поддерживает Vgate iCar Pro и аналоги.
class Elm327Ble {
  static final List<Guid> knownServiceUuids = [
    Guid('0000ffe0-0000-1000-8000-00805f9b34fb'),
    Guid('0000fff0-0000-1000-8000-00805f9b34fb'),
    Guid('000018f0-0000-1000-8000-00805f9b34fb'),
    Guid('0000ffe5-0000-1000-8000-00805f9b34fb'),
  ];

  final BluetoothDevice device;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  final List<int> _rxBuffer = [];
  final _promptCompleter = StreamController<bool>.broadcast();
  bool _hasPrompt = false;

  /// v0.1.7.1: tracks whether the underlying BLE link has dropped.
  /// Set asynchronously by _stateSub when device.connectionState becomes
  /// disconnected. sendRaw checks this before each write so we fail fast
  /// instead of throwing the cryptic "set notify value, device is
  /// disconnected" PlatformException.
  bool _disconnected = false;
  bool get isConnected => !_disconnected && _writeChar != null;

  /// v0.1.16: invoked when the BLE link drops (adapter out of range, car
  /// turned off, etc). ConnectionService subscribes to update its public
  /// status from "connected" → "disconnected" so the UI doesn't lie.
  /// Called at most once per connect() call.
  void Function()? onDisconnected;

  static const _prompt = 0x3E; // '>'
  static const _chunkSize = 20;

  Elm327Ble(this.device);

  // ---------------- Discovery ----------------
  static Future<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 6)}) async {
    final results = <ScanResult>[];
    final sub = FlutterBluePlus.scanResults.listen((r) {
      results.clear();
      results.addAll(r);
    });

    await FlutterBluePlus.startScan(timeout: timeout);
    await Future.delayed(timeout);
    await FlutterBluePlus.stopScan();
    await sub.cancel();

    results.sort((a, b) => b.rssi.compareTo(a.rssi));
    return results;
  }

  // ---------------- Connect / detect layout ----------------
  Future<void> connect() async {
    await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);

    // v0.1.7.1: subscribe to connection-state changes so we know
    // immediately if the BLE link drops (e.g., adapter went into deep sleep
    // after a long UDS responsePending). Without this, writes to a dead
    // characteristic throw cryptic "set notify value, device is disconnected"
    // and the whole client object becomes a zombie that fails reconnects.
    _disconnected = false;
    _stateSub?.cancel();
    _stateSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        final wasConnected = !_disconnected;
        _disconnected = true;
        // v0.1.16: notify listeners (e.g. ConnectionService) so UI status
        // can be updated. Guarded by wasConnected so manual disconnect()
        // doesn't double-fire (it sets _disconnected=true first).
        if (wasConnected) {
          try { onDisconnected?.call(); } catch (_) {}
        }
      }
    });

    // Запрашиваем больший MTU для скорости
    try {
      await device.requestMtu(247);
    } catch (_) {}

    final services = await device.discoverServices();

    BluetoothService? matched;
    for (final s in services) {
      if (knownServiceUuids.contains(s.uuid)) {
        matched = s;
        break;
      }
    }

    matched ??= _fallbackPickAnyService(services);

    if (matched == null) {
      throw Exception('Не найден подходящий GATT-сервис');
    }

    final picked = _pickCharacteristics(matched.characteristics);
    if (picked == null) {
      throw Exception('Не найдены write+notify характеристики');
    }

    _writeChar = picked.$1;
    _notifyChar = picked.$2;

    await _notifyChar!.setNotifyValue(true);
    _notifySub = _notifyChar!.lastValueStream.listen(_onNotify);
  }

  static BluetoothService? _fallbackPickAnyService(List<BluetoothService> services) {
    for (final s in services) {
      if (_pickCharacteristics(s.characteristics) != null) return s;
    }
    return null;
  }

  static (BluetoothCharacteristic, BluetoothCharacteristic)? _pickCharacteristics(
      List<BluetoothCharacteristic> chars) {
    BluetoothCharacteristic? wc;
    BluetoothCharacteristic? nc;
    for (final c in chars) {
      final p = c.properties;
      if ((p.write || p.writeWithoutResponse) && wc == null) wc = c;
      if ((p.notify || p.indicate) && nc == null) nc = c;
    }
    if (wc != null && nc != null) return (wc, nc);
    return null;
  }

  Future<void> disconnect() async {
    _disconnected = true;
    try {
      await _stateSub?.cancel();
      _stateSub = null;
    } catch (_) {}
    try {
      await _notifySub?.cancel();
      await _notifyChar?.setNotifyValue(false);
    } catch (_) {}
    try {
      await device.disconnect();
    } catch (_) {}
    _writeChar = null;
    _notifyChar = null;
  }

  // ---------------- I/O ----------------
  void _onNotify(List<int> data) {
    _rxBuffer.addAll(data);
    if (data.contains(_prompt)) {
      _hasPrompt = true;
      _promptCompleter.add(true);
    }
  }

  Future<String> sendRaw(String payload, {Duration timeout = const Duration(seconds: 4)}) async {
    // v0.1.7.1: fail fast if BLE link is gone — otherwise the write throws
    // a confusing "set notify value, device is disconnected" platform
    // exception and leaves stale state behind.
    if (_disconnected) throw Exception('BLE link disconnected');
    if (_writeChar == null) throw Exception('Not connected');

    _rxBuffer.clear();
    _hasPrompt = false;

    final cmd = '${payload.trim()}\r';
    final bytes = Uint8List.fromList(cmd.codeUnits);

    for (int i = 0; i < bytes.length; i += _chunkSize) {
      final end = (i + _chunkSize > bytes.length) ? bytes.length : i + _chunkSize;
      await _writeChar!.write(bytes.sublist(i, end), withoutResponse: true);
    }

    try {
      await _waitForPrompt(timeout);
    } on TimeoutException {
      // Может быть в SEARCHING — ждём ещё столько же
      final raw = String.fromCharCodes(_rxBuffer);
      if (raw.contains('SEARCHING') && !_hasPrompt) {
        await _waitForPrompt(timeout * 2);
      } else {
        rethrow;
      }
    }

    var raw = String.fromCharCodes(_rxBuffer);
    raw = raw.split('>').first;
    final lines = raw
        .replaceAll('\r', '\n')
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && s != payload.trim())
        .toList();
    return lines.join('\n');
  }

  Future<void> _waitForPrompt(Duration timeout) async {
    if (_hasPrompt) return;
    final completer = Completer<void>();
    final sub = _promptCompleter.stream.listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }
}
