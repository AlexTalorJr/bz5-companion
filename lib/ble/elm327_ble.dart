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

  /// v0.1.29+28: monitor-mode infrastructure.
  ///
  /// Why this exists: `sendRaw` is request/response — sends a command,
  /// waits for the `>` prompt, returns the full buffered text. That
  /// model breaks for `AT MA` (Monitor All) which intentionally never
  /// emits `>` — the adapter streams CAN frames continuously until it
  /// receives ESC (0x1B). To capture that stream the caller needs
  /// (a) a way to send raw bytes without waiting for prompt, and
  /// (b) a way to read each notification line as it arrives.
  ///
  /// Contract:
  ///   - [enterMonitorMode] flips a flag so `_onNotify` ALSO splits the
  ///     incoming notification into `\r`-delimited lines and pushes
  ///     them into [_monitorLineCtrl]. Prompt detection is left intact
  ///     so an out-of-band `>` (e.g. from an ATWS reset) still wakes
  ///     any pending [_waitForPrompt].
  ///   - [sendRawNoWait] writes bytes and returns immediately; no
  ///     prompt waited for, no rxBuffer touched. Used for `AT MA` (which
  ///     never prompts) and ESC (which terminates the stream).
  ///   - [exitMonitorMode] flips the flag back and re-syncs the adapter
  ///     by reading and discarding any stale notifications until the
  ///     next prompt or a short quiet period.
  ///
  /// Existing `sendRaw` callers are not affected: when [_monitorMode] is
  /// false (the default), `_onNotify` behaviour is byte-identical to
  /// the pre-+28 implementation.
  bool _monitorMode = false;
  final _monitorLineCtrl = StreamController<String>.broadcast();
  final List<int> _monitorPartialLine = [];

  /// Broadcast stream of CAN frame lines emitted by the adapter while in
  /// monitor mode. Each event is one trimmed text line (no `\r\n`).
  /// Empty between sessions. Closed at [disconnect].
  Stream<String> get monitorLines => _monitorLineCtrl.stream;

  /// True iff `enterMonitorMode` has been called and `exitMonitorMode`
  /// has not yet. Callers should not call `sendRaw` while this is true —
  /// the adapter is streaming, not in request/response state.
  bool get inMonitorMode => _monitorMode;

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
    // v0.1.29+28: also wind down monitor-mode infrastructure if it was
    // active. Safe to close even if never used: a fresh
    // StreamController with no subscribers is closed silently.
    _monitorMode = false;
    _monitorPartialLine.clear();
    if (!_monitorLineCtrl.isClosed) {
      try {
        await _monitorLineCtrl.close();
      } catch (_) {}
    }
  }

  // ---------------- I/O ----------------
  void _onNotify(List<int> data) {
    _rxBuffer.addAll(data);
    if (data.contains(_prompt)) {
      _hasPrompt = true;
      _promptCompleter.add(true);
    }
    // v0.1.29+28: monitor-mode side-channel. We extract \r-delimited
    // lines from the byte stream and push them onto a broadcast Stream
    // for runCanMonitor to consume. This is purely additive — when
    // _monitorMode is false (the default and the state for every
    // sendRaw call), nothing below this point runs.
    if (_monitorMode) {
      for (final b in data) {
        // CR/LF are line terminators; prompt is also treated as a
        // line break (ELM327 emits "OK\r>" so the OK should still
        // flush).
        if (b == 0x0D || b == 0x0A || b == _prompt) {
          if (_monitorPartialLine.isNotEmpty) {
            final line = String.fromCharCodes(_monitorPartialLine).trim();
            _monitorPartialLine.clear();
            if (line.isNotEmpty && !_monitorLineCtrl.isClosed) {
              _monitorLineCtrl.add(line);
            }
          }
        } else {
          _monitorPartialLine.add(b);
        }
      }
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

  // ---------------- Monitor mode (v0.1.29+28) ----------------

  /// Enable streaming-line mode. After this call, every notification
  /// received from the adapter that contains a `\r`/`\n`/`>` will
  /// produce one or more events on [monitorLines]. Existing prompt
  /// detection still runs in parallel (so an unexpected `>` will still
  /// wake a `_waitForPrompt` waiter — that's a defence against the
  /// caller getting stuck if the adapter resets mid-stream).
  ///
  /// Idempotent: calling twice is a no-op.
  void enterMonitorMode() {
    _monitorMode = true;
    _monitorPartialLine.clear();
  }

  /// Disable streaming-line mode. Any bytes that were buffered as a
  /// partial line are discarded. After this returns, the next
  /// `sendRaw` call works exactly as it did before +28.
  ///
  /// Caller is responsible for having already terminated the adapter's
  /// monitor state (e.g. by sending ESC via [sendRawNoWait]) and
  /// drained any pending stream output.
  void exitMonitorMode() {
    _monitorMode = false;
    _monitorPartialLine.clear();
  }

  /// Write bytes to the adapter and return immediately. No prompt is
  /// waited for, no buffer is cleared. The chunk-size and BLE write
  /// mechanics are identical to `sendRaw`'s loop — same withoutResponse
  /// flag, same 20-byte chunking — to avoid behavioural drift.
  ///
  /// Use cases:
  ///   - Send `AT MA\r` (Monitor All) — the adapter will not prompt,
  ///     so a normal sendRaw call would hang until timeout.
  ///   - Send ESC (0x1B) to terminate `AT MA` mode. Some clones don't
  ///     emit a prompt on ESC either, so we don't try to wait.
  Future<void> sendRawNoWait(String payload) async {
    if (_disconnected) throw Exception('BLE link disconnected');
    if (_writeChar == null) throw Exception('Not connected');
    final bytes = Uint8List.fromList(payload.codeUnits);
    for (int i = 0; i < bytes.length; i += _chunkSize) {
      final end =
          (i + _chunkSize > bytes.length) ? bytes.length : i + _chunkSize;
      await _writeChar!.write(bytes.sublist(i, end), withoutResponse: true);
    }
  }

  /// Send a single ESC byte (0x1B). Convenience wrapper for terminating
  /// `AT MA` / `STM` style streaming commands.
  Future<void> sendEsc() => sendRawNoWait('\x1B');
}
