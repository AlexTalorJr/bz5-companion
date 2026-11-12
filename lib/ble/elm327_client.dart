import 'dart:async';
import 'elm327_ble.dart';

class EcuResponse {
  final String txId;
  final String rxId;
  final String rawHex;
  final String? error;

  EcuResponse({
    required this.txId,
    required this.rxId,
    required this.rawHex,
    this.error,
  });

  bool get isPositive => error == null && rawHex.isNotEmpty && !rawHex.startsWith('7F');

  /// Извлечь payload из положительного ответа на UDS service 0x22 (ReadDataByIdentifier).
  /// Формат: 62 <DID-hi> <DID-lo> <data...>
  List<int>? get payloadAfterUdsRead {
    if (!rawHex.startsWith('62') || rawHex.length < 6) return null;
    return _hexToBytes(rawHex.substring(6));
  }

  static List<int> _hexToBytes(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    final padded = clean.length % 2 == 0 ? clean : '0$clean';
    final out = <int>[];
    for (int i = 0; i < padded.length; i += 2) {
      out.add(int.parse(padded.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}

class AdapterInfo {
  String version = '';
  String protocolNumber = '';
  String protocolName = '';
  String voltage = '';

  @override
  String toString() => 'Adapter(v=$version, proto=$protocolName, $voltage)';
}

class Elm327Client {
  final Elm327Ble transport;
  final AdapterInfo info = AdapterInfo();

  String? _currentHeader;
  String? _currentRxFilter;

  /// v0.2.31+230 — 12 В АДАПТЕРА (ATRV) В ОБЩЕМ МЕТОДЕ ЗАПРОСА.
  ///
  /// Все запросы UDS — опрос, Live Log, свип, DTC — идут через [query].
  /// Здесь, перед запросом, раз в [atrvEvery] уходит ATRV. `sendRaw`
  /// возвращается только после ответа адаптера целиком, поэтому ATRV
  /// никогда не попадает внутрь многокадровой передачи ISO-TP. AT CV не
  /// трогаем: калибровку адаптера не меняем. Число разбирается до `V`;
  /// ответ без числа или вне 5…20 В — отсчёт пропускается. Без
  /// подписчика [onAdapterVoltage] ATRV не шлётся вовсе.
  static const Duration atrvEvery = Duration(seconds: 5);
  final Stopwatch _atrvClock = Stopwatch();
  void Function(double volts)? onAdapterVoltage;

  Elm327Client(this.transport);

  /// Разбор ответа ATRV: `12.6V`, `13.8 V`, с мусором до числа. null —
  /// ответа нет или число вне здравого коридора 5…20 В.
  static double? parseAtrv(String raw) {
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*V', caseSensitive: false)
        .firstMatch(raw);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v < 5 || v > 20) return null;
    return v;
  }

  Future<void> _maybeAtrv() async {
    final cb = onAdapterVoltage;
    if (cb == null) return;
    if (_atrvClock.isRunning && _atrvClock.elapsed < atrvEvery) return;
    _atrvClock
      ..reset()
      ..start();
    final v = parseAtrv(await transport.sendRaw('ATRV'));
    if (v != null) cb(v);
  }

  /// v0.2.35+234: одна команда ATRV адаптеру, без UDS — для режима
  /// «только ATRV» (ConnectionService.runAtrvOnly): запросы UDS будят
  /// шлюз, шину и DC-DC, и точку «машина спит» с ними не снять.
  Future<double?> readAdapterVoltage() async =>
      parseAtrv(await transport.sendRaw('ATRV'));

  // ---------------- Initialization ----------------
  Future<AdapterInfo> initialize({String forceProtocol = '6'}) async {
    info.version = await transport.sendRaw('ATZ', timeout: const Duration(seconds: 5));

    for (final cmd in ['ATE0', 'ATL0', 'ATS0', 'ATH1']) {
      await transport.sendRaw(cmd);
    }

    await transport.sendRaw('ATSP$forceProtocol');
    await transport.sendRaw('ATAT2'); // aggressive timing

    // Триггерный запрос — может вернуть NO DATA, это ок
    try {
      await transport.sendRaw('0100', timeout: const Duration(seconds: 4));
    } catch (_) {}

    info.protocolNumber = await transport.sendRaw('ATDPN');
    info.protocolName = await transport.sendRaw('ATDP');
    info.voltage = await transport.sendRaw('ATRV');

    return info;
  }

  // ---------------- Headers ----------------
  Future<void> setHeader(String txId) async {
    if (_currentHeader == txId) return;
    await transport.sendRaw('ATSH$txId');
    _currentHeader = txId;
  }

  Future<void> setRxFilter(String? rxId) async {
    if (rxId == null) {
      if (_currentRxFilter != null) {
        await transport.sendRaw('ATAR');
        _currentRxFilter = null;
      }
      return;
    }
    if (_currentRxFilter == rxId) return;
    await transport.sendRaw('ATCRA$rxId');
    _currentRxFilter = rxId;
  }

  // ---------------- Query ----------------
  Future<List<EcuResponse>> query(
    String serviceData, {
    String? txId,
    String? rxId,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await _maybeAtrv();
    if (txId != null) await setHeader(txId);
    if (rxId != null) await setRxFilter(rxId);

    final raw = await transport.sendRaw(serviceData, timeout: timeout);
    return _parse(raw, expectedTx: txId);
  }

  /// Удобный шорткат для UDS Read DID (mode 0x22)
  Future<EcuResponse?> readDid(String did, {required String tx, required String rx}) async {
    final resps = await query('22${did.toUpperCase()}', txId: tx, rxId: rx);
    if (resps.isEmpty) return null;
    return resps.firstWhere(
      (r) => r.rxId == rx,
      orElse: () => resps.first,
    );
  }

  // ---------------- Parser (порт _parse из elm327.py) ----------------
  static final _re11bit = RegExp(r'^([0-9A-F]{3})([0-9A-F]+)$');
  static final _re29bit = RegExp(r'^([0-9A-F]{8})([0-9A-F]+)$');

  List<EcuResponse> _parse(String raw, {String? expectedTx}) {
    final upper = raw.toUpperCase().trim();
    if (upper.isEmpty) return [];

    if (upper.contains('NO DATA')) {
      return [EcuResponse(txId: expectedTx ?? '', rxId: '', rawHex: '', error: 'NO DATA')];
    }
    if (upper.contains('CAN ERROR') || upper.contains('BUS INIT')) {
      return [EcuResponse(txId: expectedTx ?? '', rxId: '', rawHex: '', error: upper)];
    }
    if (upper == '?' || upper == 'OK') {
      return [EcuResponse(txId: expectedTx ?? '', rxId: '', rawHex: '', error: upper)];
    }

    // Группируем строки по rx_id
    final groups = <String, List<String>>{};
    for (final line in upper.split('\n')) {
      final clean = line.replaceAll(RegExp(r'\s'), '');
      if (clean.isEmpty) continue;

      String? rxId;
      String? body;

      if (clean.length >= 10 && clean.startsWith('18')) {
        final m = _re29bit.firstMatch(clean);
        if (m != null) {
          rxId = m.group(1);
          body = m.group(2);
        }
      }

      if (rxId == null) {
        final m = _re11bit.firstMatch(clean);
        if (m != null && m.group(1)!.length == 3) {
          rxId = m.group(1);
          body = m.group(2);
        }
      }

      if (rxId == null || body == null) continue;
      groups.putIfAbsent(rxId, () => []).add(body);
    }

    final results = <EcuResponse>[];
    groups.forEach((rxId, frames) {
      // v0.2.20+219: a slow ECU first answers `7F <svc> 78`
      // (responsePending) and the real answer follows as a further frame
      // under the same RX. _assembleIsoTp reads only the first single
      // frame, so the pending notice used to be recorded and the real
      // answer thrown away. Drop leading pending frames while another
      // frame follows; a pending frame with nothing after it stays and is
      // recorded as 7FXX78.
      while (frames.length > 1 && _isPendingFrame(frames.first)) {
        frames.removeAt(0);
      }
      final assembled = _assembleIsoTp(frames);
      String? err;
      if (assembled.startsWith('7F') && assembled.length >= 6) {
        err = 'NEG 7F ${assembled.substring(2, 4)} NRC=${assembled.substring(4, 6)}';
      }
      results.add(EcuResponse(
        txId: expectedTx ?? '',
        rxId: rxId,
        rawHex: assembled,
        error: err,
      ));
    });
    return results;
  }

  /// v0.2.20+219: true for a single ISO-TP frame carrying a negative
  /// response with NRC 0x78 (requestCorrectlyReceived-ResponsePending):
  /// PCI `03`, then `7F`, service byte, `78`.
  static bool _isPendingFrame(String frame) =>
      frame.length >= 8 &&
      frame.startsWith('03') &&
      frame.substring(2, 4) == '7F' &&
      frame.substring(6, 8) == '78';

  static String _assembleIsoTp(List<String> frames) {
    if (frames.isEmpty) return '';
    final first = frames[0];
    if (first.length < 2) return '';

    final pciHigh = first.substring(0, 1);

    if (pciHigh == '0') {
      // Single frame: 0L <data>
      final length = int.parse(first.substring(1, 2), radix: 16);
      return first.substring(2, 2 + length * 2 > first.length ? first.length : 2 + length * 2);
    }

    if (pciHigh == '1') {
      // First frame: 1L LL <data...>
      final totalLen = int.parse(first.substring(1, 4), radix: 16);
      var data = first.substring(4);
      for (int i = 1; i < frames.length; i++) {
        final cf = frames[i];
        if (cf.length < 2) continue;
        if (cf.substring(0, 1) != '2') continue;
        data += cf.substring(2);
      }
      final maxLen = totalLen * 2;
      return data.length > maxLen ? data.substring(0, maxLen) : data;
    }

    return frames.join();
  }
}
