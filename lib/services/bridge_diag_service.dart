// Bridge Plane A — Diagnostic recon service.
//
// Independently of CloudSyncService, this service runs a long-poll
// loop on the bridge `/v1/commands/next` endpoint, picks up commands
// queued by the recon Claude (via the admin endpoint), executes them,
// and posts results back.
//
// Per CLIENT_API.md §0 + §10: two independent services that share
// only the HTTP client and the client_token, nothing else — separate
// flag (`bridge_diag_enabled`), no shared backoff, no shared cursors,
// no shared error buffers.
//
// v0.1.29+15 (Turn A): scaffold + long-poll loop only. No command
// handlers — every received command rejected with error_kind=unsupported.
//
// v0.1.29+17 (Turn B): BLE command handlers added. Three kinds wired:
//   - bleStartSweep: fire-and-forget, ConnectionService.runSweep()
//   - bleStartLiveLog: fire-and-forget, ConnectionService.runLiveLog()
//   - bleStopActiveOperation: synchronous, composes cancelSweep + cancelLiveLog
//
// "Fire-and-forget" because runSweep/runLiveLog can take minutes to hours;
// the command channel's 30s timeout doesn't fit the operation. The recon
// side correlates command -> run by timestamp + vehicle_id, and observes
// actual sweep/livelog results via Plane B (CloudSyncService push). A
// future bridge v1.1 will add command_id FK to sweep_runs/live_log_sessions
// for direct linkage in the admin UI.
//
// Turn C (later) will add native API command handlers (12 kinds) over
// NativeCarChannel. Not blocking anything; deferred until next scope ask.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'connection.dart';

// ─── Public enums / value objects ──────────────────────────────────

/// Coarse UI status. Settings card reads this directly.
enum BridgeDiagStatus {
  /// Toggle is off (default). No polling, no network activity.
  disabled,

  /// Toggle is on but device isn't registered yet (no client_token in
  /// secure storage). The user must finish CloudSyncService setup
  /// first — both services share the same registration. We don't
  /// expose a separate "register for diag" flow because that would
  /// burn two setup tokens for one device.
  notRegistered,

  /// Toggle is on, registered, currently waiting on a long-poll.
  /// This is the "normal idle" state — long-polls block up to 30s
  /// each, so we live here most of the time.
  polling,

  /// A command was received and is being executed.
  executing,

  /// Last poll returned an error (network, 5xx, etc.). Counted as a
  /// soft error; we back off and retry on the next loop iteration.
  error,

  /// 3+ consecutive 401s — token wiped, same semantics as CloudSyncService.
  authFailed,
}

/// Lightweight stats for the Settings card.
class BridgeDiagStats {
  final int commandsExecuted;
  final int commandsRejected;
  final DateTime? lastCommandAt;
  final String? lastCommandKind;
  const BridgeDiagStats({
    this.commandsExecuted = 0,
    this.commandsRejected = 0,
    this.lastCommandAt,
    this.lastCommandKind,
  });

  BridgeDiagStats copyWith({
    int? commandsExecuted,
    int? commandsRejected,
    DateTime? lastCommandAt,
    String? lastCommandKind,
  }) =>
      BridgeDiagStats(
        commandsExecuted: commandsExecuted ?? this.commandsExecuted,
        commandsRejected: commandsRejected ?? this.commandsRejected,
        lastCommandAt: lastCommandAt ?? this.lastCommandAt,
        lastCommandKind: lastCommandKind ?? this.lastCommandKind,
      );
}

// ─── Service ───────────────────────────────────────────────────────

class BridgeDiagService extends ChangeNotifier {
  BridgeDiagService({required ConnectionService svc}) : _svc = svc;

  /// The shared BLE/UDS service used to dispatch bleStart* commands.
  /// Plane A's whole purpose is to drive the car through the same
  /// channels ConnectionService already manages, so a logical
  /// dependency is natural here. Read-only — we never reach in and
  /// mutate ConnectionService state directly; only call its public
  /// methods (runSweep / runLiveLog / cancelSweep / cancelLiveLog)
  /// and read its public getters.
  final ConnectionService _svc;

  // Persistence keys. v0.1.29+15: only one persisted key for us —
  // the toggle. Everything else (token, base URL) is shared with
  // CloudSyncService via the same secure-storage / SharedPreferences
  // keys. We READ them; we don't WRITE.
  static const _kEnabled = 'bridge_diag_enabled';

  // Read-only references to CloudSyncService persistence keys, so
  // that this service uses whatever the user registered with. Defined
  // here as constants (not imported) because CloudSyncService's keys
  // are private — duplicating prevents an undesirable cross-service
  // import that would create a coupling.
  static const _kSharedTokenKey = 'cloud_sync_client_token';
  static const _kSharedBaseUrl = 'cloud_sync_base_url';
  static const _defaultBaseUrl = 'https://carbridge.neardo.work';

  // ── state (loaded by init()) ──
  bool _enabled = false;
  bool _initialized = false;
  String _baseUrl = _defaultBaseUrl;
  String? _clientToken;

  BridgeDiagStatus _status = BridgeDiagStatus.disabled;
  BridgeDiagStats _stats = const BridgeDiagStats();
  String? _lastError;

  /// 3-strike auth counter, in-memory only — same semantics as
  /// CloudSyncService._consecutiveAuthFailures (CLIENT_API §1).
  int _consecutiveAuthFailures = 0;

  /// Active long-poll loop. Set when the toggle is enabled; cancelled
  /// when disabled or when the service is disposed.
  Future<void>? _loop;
  bool _loopShouldRun = false;

  final http.Client _http = http.Client();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // ── getters for UI ──
  bool get isEnabled => _enabled;
  bool get isRegistered => _clientToken != null;
  BridgeDiagStatus get status => _status;
  BridgeDiagStats get stats => _stats;
  String? get lastError => _lastError;

  // ── lifecycle ──

  /// Read flag + token, start loop if enabled and registered.
  /// Fire-and-forget from main.dart; UI uses status to know when ready.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _baseUrl = prefs.getString(_kSharedBaseUrl) ?? _defaultBaseUrl;
    try {
      _clientToken = await _secureStorage.read(key: _kSharedTokenKey);
    } catch (e) {
      debugPrint('BridgeDiag: secure storage read failed: $e');
      _clientToken = null;
    }
    _initialized = true;
    _recomputeStatus();
    if (_enabled && isRegistered) {
      _startLoop();
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (!_initialized) return;
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
    if (value && isRegistered) {
      _startLoop();
    } else {
      _stopLoop();
    }
    _recomputeStatus();
    notifyListeners();
  }

  /// Called externally (e.g. after CloudSyncService finishes setup) to
  /// refresh our view of the shared token. CloudSyncService doesn't
  /// know about us, so we don't get notified automatically; the
  /// Settings UI calls this when the user enables the toggle, and
  /// init() does it on app start.
  Future<void> refreshTokenFromSharedStorage() async {
    try {
      _clientToken = await _secureStorage.read(key: _kSharedTokenKey);
    } catch (e) {
      debugPrint('BridgeDiag: secure storage read failed: $e');
      _clientToken = null;
    }
    _recomputeStatus();
    // If we just gained a token and the toggle is on, start polling.
    if (_enabled && isRegistered && _loop == null) {
      _startLoop();
    }
    // If we just lost it, the next poll will get 401 and stop itself.
    notifyListeners();
  }

  @override
  void dispose() {
    _stopLoop();
    _http.close();
    super.dispose();
  }

  // ── long-poll loop ──

  void _startLoop() {
    if (_loop != null) return;
    _loopShouldRun = true;
    _loop = _runLoop();
  }

  void _stopLoop() {
    _loopShouldRun = false;
    // The loop checks _loopShouldRun between iterations and exits
    // gracefully. An in-flight request will complete normally first
    // (max 30s) — we don't force-cancel because that would leak the
    // server-side claim until the command's own timeout sweeper fires.
    _loop = null;
  }

  Future<void> _runLoop() async {
    debugPrint('BridgeDiag: loop started');
    while (_loopShouldRun) {
      try {
        await _pollOnce();
      } catch (e, st) {
        // Defensive — _pollOnce handles its own errors. If something
        // unexpected slips through, log it and pause a few seconds so
        // we don't busy-loop on a persistent bug.
        debugPrint('BridgeDiag: loop caught $e\n$st');
        _lastError = 'Loop exception: $e';
        _status = BridgeDiagStatus.error;
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    }
    debugPrint('BridgeDiag: loop exited');
  }

  /// One iteration of the long-poll. Returns when:
  ///   - 204 (poll timed out with no command) → loop again immediately
  ///   - 200 (got command) → executed + result posted → loop again
  ///   - 401 / 5xx / network → counter / backoff handled here; loop again
  Future<void> _pollOnce() async {
    final token = _clientToken;
    if (token == null) {
      // Lost the token between iterations — stop the loop politely.
      _loopShouldRun = false;
      _recomputeStatus();
      notifyListeners();
      return;
    }

    if (_status != BridgeDiagStatus.polling) {
      _status = BridgeDiagStatus.polling;
      notifyListeners();
    }

    final uri = Uri.parse('$_baseUrl/v1/commands/next?wait=30');
    final headers = {'Authorization': 'Bearer $token'};

    http.Response resp;
    try {
      // Per CLIENT_API §7.1: server blocks up to `wait` seconds (30).
      // We give ourselves +5s of slack to read the response before
      // declaring a client-side timeout.
      resp = await _http.get(uri, headers: headers)
          .timeout(const Duration(seconds: 35));
    } on TimeoutException {
      // Client timed out before the server returned anything. This is
      // unusual (the server's own timeout is 30s) — could indicate a
      // proxy or connectivity hiccup. Brief backoff, then retry.
      _lastError = 'Long-poll client timeout';
      _status = BridgeDiagStatus.error;
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
      return;
    } on SocketException catch (e) {
      _lastError = 'Network: ${e.message}';
      _status = BridgeDiagStatus.error;
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
      return;
    }

    final code = resp.statusCode;

    // 204 — no command waiting. This is the most common response.
    // Immediately loop again; no backoff, no notify (status is already
    // .polling and stays there).
    if (code == 204) {
      // Successful contact → reset auth counter just in case it was
      // ticking up from a stale token in another path.
      if (_consecutiveAuthFailures > 0) {
        _consecutiveAuthFailures = 0;
      }
      return;
    }

    if (code == 401) {
      _consecutiveAuthFailures++;
      debugPrint('BridgeDiag: 401 from /v1/commands/next '
          '(consecutive=$_consecutiveAuthFailures of 3)');
      if (_consecutiveAuthFailures >= 3) {
        // Permanent. Stop the loop and surface to UI.
        _loopShouldRun = false;
        _status = BridgeDiagStatus.authFailed;
        _lastError = 'Auth failed — 3 consecutive 401s. '
            'Re-register the device via Cloud backup setup.';
        // Do NOT wipe the token here — CloudSyncService owns the
        // token lifecycle. It will detect the same 401-storm on its
        // own ingest path and wipe. We just stop polling.
        notifyListeners();
        return;
      }
      // Transient — back off briefly, loop again. Next response is
      // either another 401 (counter to 3 → wipe via CloudSync), or
      // 204/200 (recovery → counter reset).
      _lastError = 'Auth blip (#$_consecutiveAuthFailures of 3)';
      _status = BridgeDiagStatus.error;
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 5));
      return;
    }

    if (code == 200) {
      // Got a command. Reset auth counter, then execute and post result.
      _consecutiveAuthFailures = 0;
      Map<String, dynamic> cmd;
      try {
        cmd = jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (e) {
        debugPrint('BridgeDiag: malformed command JSON: $e');
        _lastError = 'Malformed command JSON';
        _status = BridgeDiagStatus.error;
        notifyListeners();
        await Future<void>.delayed(const Duration(seconds: 5));
        return;
      }
      await _handleCommand(cmd);
      return;
    }

    // 5xx / 408 / 429 / anything else — backoff and retry.
    _lastError = 'HTTP $code from /v1/commands/next';
    _status = BridgeDiagStatus.error;
    notifyListeners();
    debugPrint('BridgeDiag: HTTP $code on /v1/commands/next, '
        'sleeping 5s before retry');
    await Future<void>.delayed(const Duration(seconds: 5));
  }

  /// Execute one command and post the result.
  ///
  /// Turn A (v0.1.29+15): every command rejected as unsupported.
  /// Turn B (v0.1.29+17): bleStartSweep / bleStartLiveLog / bleStopActiveOperation
  /// dispatched to ConnectionService. Other kinds still unsupported.
  /// Turn C (later): native API kinds via NativeCarChannel.
  Future<void> _handleCommand(Map<String, dynamic> cmd) async {
    final id = cmd['id'];
    final kind = cmd['kind'] as String? ?? '<missing>';
    final args = (cmd['args'] is Map)
        ? Map<String, dynamic>.from(cmd['args'] as Map)
        : <String, dynamic>{};
    debugPrint('BridgeDiag: received command id=$id kind=$kind');

    _status = BridgeDiagStatus.executing;
    notifyListeners();

    final started = DateTime.now().toUtc();
    Map<String, dynamic> body;
    try {
      switch (kind) {
        case 'bleStartSweep':
          body = _handleBleStartSweep(args);
          break;
        case 'bleStartLiveLog':
          body = _handleBleStartLiveLog(args);
          break;
        case 'bleStopActiveOperation':
          body = _handleBleStopActiveOperation(args);
          break;
        default:
          body = _err('unsupported',
              'Command kind "$kind" not implemented in this client yet. '
              'BridgeDiagService Turn B supports BLE only '
              '(bleStartSweep / bleStartLiveLog / bleStopActiveOperation). '
              'Native handlers come in Turn C.');
      }
    } catch (e, st) {
      // Defensive: handler threw unexpectedly. Don't crash the loop.
      debugPrint('BridgeDiag: handler for $kind threw: $e\n$st');
      body = _err('unknown', 'Handler threw: $e');
    }

    final result = <String, dynamic>{
      ...body,
      'started_at': started.toIso8601String(),
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };

    await _postResult(id, result, kind);
  }

  // ─── Command handlers (Turn B — BLE) ─────────────────────────────

  /// Error result shape per CLIENT_API.md §7.2 + agreed error_kind
  /// whitelist (busy / not_connected / parse / validation / unsupported
  /// / unknown). Caller adds started_at/finished_at.
  Map<String, dynamic> _err(String kind, String msg) => {
        'ok': false,
        'error': msg,
        'error_kind': kind,
      };

  /// Whether any BLE-channel operation is currently in progress.
  /// Sweep/livelog/dtc-scan are mutually exclusive in ConnectionService
  /// (they share the single ELM327 BLE channel); from our perspective
  /// they're all "busy" for purposes of starting a new sweep/livelog.
  bool get _bleBusy =>
      _svc.sweepRunning || _svc.liveLogRunning || _svc.dtcScanRunning;

  /// bleStartSweep: fire-and-forget. Validates args, checks state,
  /// then kicks off ConnectionService.runSweep() WITHOUT awaiting —
  /// the sweep can take hours. Returns ok=true with started:true,
  /// recon Claude correlates the resulting SweepRun (visible via
  /// Plane B sync) by timestamp + vehicle_id.
  ///
  /// Args contract per CLIENT_API.md §7.3:
  ///   {tx_ecu, rx_ecu, start_did, end_did, period_ms}
  /// All hex strings uppercase canonical (we accept lowercase too and
  /// normalize), period_ms optional (default 250).
  Map<String, dynamic> _handleBleStartSweep(Map<String, dynamic> args) {
    // 1. Parse required string args.
    final txEcu = args['tx_ecu'];
    final rxEcu = args['rx_ecu'];
    final startDid = args['start_did'];
    final endDid = args['end_did'];
    if (txEcu is! String || rxEcu is! String ||
        startDid is! String || endDid is! String) {
      return _err('parse',
          'Missing or non-string required args: '
          'tx_ecu, rx_ecu, start_did, end_did must all be strings');
    }

    // 2. Hex validation (case-insensitive parse; we'll uppercase later).
    final startInt = int.tryParse(startDid, radix: 16);
    final endInt = int.tryParse(endDid, radix: 16);
    if (startInt == null || endInt == null) {
      return _err('parse',
          'start_did/end_did not valid hex: '
          'got start_did=$startDid end_did=$endDid');
    }
    if (startInt < 0 || endInt > 0xFFFF) {
      return _err('validation',
          'DID range out of bounds (must fit 0000..FFFF), '
          'got $startDid..$endDid');
    }
    if (endInt < startInt) {
      return _err('validation',
          'end_did < start_did ($endDid < $startDid)');
    }

    // 3. Optional period_ms.
    final periodRaw = args['period_ms'];
    final int periodMs;
    if (periodRaw == null) {
      periodMs = 250;
    } else if (periodRaw is int) {
      periodMs = periodRaw;
    } else if (periodRaw is num) {
      periodMs = periodRaw.toInt();
    } else {
      return _err('parse',
          'period_ms must be an integer if provided, got $periodRaw');
    }
    if (periodMs < 50 || periodMs > 60000) {
      return _err('validation',
          'period_ms out of reasonable range [50..60000], got $periodMs');
    }

    // 4. State pre-check.
    if (!_svc.isBleConnected) {
      return _err('not_connected',
          'No live BLE link to ELM327; pair the adapter first');
    }
    if (_bleBusy) {
      return _err('busy',
          'Another BLE operation in progress '
          '(sweep=${_svc.sweepRunning} '
          'livelog=${_svc.liveLogRunning} '
          'dtc=${_svc.dtcScanRunning})');
    }

    // 5. Normalize hex to canonical uppercase per agreed contract.
    final txU = txEcu.toUpperCase();
    final rxU = rxEcu.toUpperCase();
    final startU = startDid.toUpperCase().padLeft(4, '0');
    final endU = endDid.toUpperCase().padLeft(4, '0');

    // 6. Fire-and-forget. Capture errors in a debug log; the future
    // outlives this method call by minutes-to-hours. The recon side
    // sees the SweepRun via Plane B push when CloudSyncService runs.
    unawaited(_svc
        .runSweep(
      txEcu: txU,
      rxEcu: rxU,
      startDidHex: startU,
      endDidHex: endU,
      periodMs: periodMs,
      notes: 'started via bridge command',
    )
        .then((runId) {
      debugPrint('BridgeDiag: bleStartSweep finished, '
          'run_id=$runId (null=cancelled or aborted)');
    }).catchError((Object e, StackTrace st) {
      debugPrint('BridgeDiag: bleStartSweep threw: $e\n$st');
    }));

    return {
      'ok': true,
      'result': {'started': true, 'kind': 'sweep'},
    };
  }

  /// bleStartLiveLog: fire-and-forget. Same shape as bleStartSweep.
  ///
  /// Args contract per CLIENT_API.md §7.3 + decision 2 with Friend 2:
  ///   {did_list: [{tx_ecu, rx_ecu, did}, ...],
  ///    duration_sec,
  ///    period_ms (optional, IGNORED — ConnectionService.runLiveLog
  ///               has no period parameter, the loop runs with
  ///               minimal spacing)}
  ///
  /// max 10 DIDs (ConnectionService limit, see runLiveLog gate).
  /// v0.1.29+25: was 7, bumped to 10. See runLiveLog doc for cycle-time
  /// trade-off rationale.
  /// If period_ms is present, response includes ignored_args:["period_ms"].
  Map<String, dynamic> _handleBleStartLiveLog(Map<String, dynamic> args) {
    // 1. Parse did_list.
    final didListRaw = args['did_list'];
    if (didListRaw is! List) {
      return _err('parse',
          'did_list missing or not a list');
    }

    final didSpecs = <(String, String, String)>[];
    for (var i = 0; i < didListRaw.length; i++) {
      final item = didListRaw[i];
      if (item is! Map) {
        return _err('parse',
            'did_list[$i] is not an object');
      }
      final tx = item['tx_ecu'];
      final rx = item['rx_ecu'];
      final did = item['did'];
      if (tx is! String || rx is! String || did is! String) {
        return _err('parse',
            'did_list[$i] must have string tx_ecu/rx_ecu/did');
      }
      if (int.tryParse(did, radix: 16) == null) {
        return _err('parse',
            'did_list[$i].did "$did" not valid hex');
      }
      // Normalize to uppercase per agreed contract; pad DID to 4 hex.
      didSpecs.add((
        tx.toUpperCase(),
        rx.toUpperCase(),
        did.toUpperCase().padLeft(4, '0'),
      ));
    }

    if (didSpecs.isEmpty) {
      return _err('validation', 'did_list must contain at least 1 entry');
    }
    if (didSpecs.length > 10) {
      return _err('validation',
          'did_list must have at most 10 entries, got ${didSpecs.length}');
    }

    // 2. Parse duration_sec.
    final durationRaw = args['duration_sec'];
    if (durationRaw is! num) {
      return _err('parse',
          'duration_sec missing or not numeric');
    }
    final durationSec = durationRaw.toInt();
    if (durationSec <= 0 || durationSec > 24 * 3600) {
      return _err('validation',
          'duration_sec must be in (0..86400], got $durationSec');
    }

    // 3. Track ignored args. period_ms is the known one; if recon
    // sends other unknown args we silently accept them (not in
    // contract — would be future-extensible field).
    final ignored = <String>[];
    if (args.containsKey('period_ms')) ignored.add('period_ms');

    // 4. State pre-check.
    if (!_svc.isBleConnected) {
      return _err('not_connected',
          'No live BLE link to ELM327; pair the adapter first');
    }
    if (_bleBusy) {
      return _err('busy',
          'Another BLE operation in progress '
          '(sweep=${_svc.sweepRunning} '
          'livelog=${_svc.liveLogRunning} '
          'dtc=${_svc.dtcScanRunning})');
    }

    // 5. Fire-and-forget.
    unawaited(_svc
        .runLiveLog(
      didSpecs: didSpecs,
      maxDurationMs: durationSec * 1000,
      notes: 'started via bridge command',
    )
        .then((sessionId) {
      debugPrint('BridgeDiag: bleStartLiveLog finished, '
          'session_id=$sessionId (null=cancelled or aborted)');
    }).catchError((Object e, StackTrace st) {
      debugPrint('BridgeDiag: bleStartLiveLog threw: $e\n$st');
    }));

    final result = <String, dynamic>{
      'started': true,
      'kind': 'livelog',
    };
    if (ignored.isNotEmpty) {
      result['ignored_args'] = ignored;
    }
    return {'ok': true, 'result': result};
  }

  /// bleStopActiveOperation: synchronous. Cancels whichever BLE
  /// operations are running and reports back. No args.
  ///
  /// Idempotent: stopping with nothing active returns
  /// {ok:true, result:{stopped:[]}} — success, not an error.
  ///
  /// dtcScan is currently not exposed via Plane A (no startDtcScan
  /// command kind), so we don't cancel it here. If recon Claude
  /// needs to stop a DTC scan it goes through the UI or a future
  /// command kind.
  Map<String, dynamic> _handleBleStopActiveOperation(
      Map<String, dynamic> args) {
    final stopped = <String>[];
    if (_svc.sweepRunning) {
      _svc.cancelSweep();
      stopped.add('sweep');
    }
    if (_svc.liveLogRunning) {
      _svc.cancelLiveLog();
      stopped.add('livelog');
    }
    debugPrint('BridgeDiag: bleStopActiveOperation cancelled: $stopped');
    return {
      'ok': true,
      'result': {'stopped': stopped},
    };
  }

  /// Post the command result. Failures here are non-fatal — server
  /// will mark the command as timed-out by its own sweeper if our
  /// post never lands. We log and move on.
  Future<void> _postResult(
      dynamic id, Map<String, dynamic> result, String kind) async {
    final token = _clientToken;
    if (token == null) return; // lost token mid-execution
    final uri = Uri.parse('$_baseUrl/v1/commands/$id/result');
    try {
      final resp = await _http
          .post(uri,
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(result))
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        _stats = _stats.copyWith(
          commandsExecuted: (result['ok'] == true)
              ? _stats.commandsExecuted + 1
              : _stats.commandsExecuted,
          commandsRejected: (result['ok'] == true)
              ? _stats.commandsRejected
              : _stats.commandsRejected + 1,
          lastCommandAt: DateTime.now(),
          lastCommandKind: kind,
        );
        _lastError = null;
      } else if (resp.statusCode == 409) {
        // already_finished — server probably timed out and we raced.
        // Not an error from our perspective.
        debugPrint('BridgeDiag: result POST 409 already_finished for id=$id');
      } else {
        debugPrint('BridgeDiag: result POST HTTP ${resp.statusCode}: '
            '${resp.body}');
        _lastError = 'Result POST HTTP ${resp.statusCode}';
      }
    } catch (e) {
      // Network failure posting result. The server's timeout sweeper
      // will mark the command timed-out eventually; we don't retry.
      debugPrint('BridgeDiag: result POST failed: $e');
      _lastError = 'Result POST failed: $e';
    }
    notifyListeners();
  }

  // ── status recompute ──

  void _recomputeStatus() {
    if (!_enabled) {
      _status = BridgeDiagStatus.disabled;
      return;
    }
    if (!isRegistered) {
      _status = BridgeDiagStatus.notRegistered;
      return;
    }
    // If loop is running, polling/executing/error states are set by
    // the loop itself. If not, we're transitioning.
    if (_loop == null) {
      _status = BridgeDiagStatus.polling;
    }
  }
}
