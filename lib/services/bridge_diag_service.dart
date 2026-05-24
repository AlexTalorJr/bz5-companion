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
// handlers are implemented yet — every received command is rejected
// with `{ok:false, error_kind:"unsupported"}`. The point of this turn
// is to prove the long-poll mechanics work end-to-end. Turn B adds
// BLE handlers; Turn C adds native ones.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
  BridgeDiagService();

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
  /// Turn A (v0.1.29+15): every command is rejected as unsupported.
  /// Turn B adds BLE handlers (bleStartSweep, bleStartLiveLog,
  /// bleStopActiveOperation). Turn C adds native handlers.
  Future<void> _handleCommand(Map<String, dynamic> cmd) async {
    final id = cmd['id'];
    final kind = cmd['kind'] as String? ?? '<missing>';
    debugPrint('BridgeDiag: received command id=$id kind=$kind');

    _status = BridgeDiagStatus.executing;
    notifyListeners();

    final started = DateTime.now().toUtc();
    // Turn A: no command handlers yet. Reject as unsupported.
    final result = {
      'ok': false,
      'error': 'Command kind not implemented in this client yet '
          '(BridgeDiagService is in Turn A — long-poll scaffold only)',
      'error_kind': 'unsupported',
      'started_at': started.toIso8601String(),
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    };

    await _postResult(id, result, kind);
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
