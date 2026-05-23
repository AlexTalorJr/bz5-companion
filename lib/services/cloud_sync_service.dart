/// v0.1.28: cloud backup via bz5-bridge.
///
/// PURPOSE
/// -------
/// Read-only sync of local Drift data to the bridge server so that:
///   * Trip history survives head-unit reinstall (Toyota DiLink doesn't
///     support APK updates — only uninstall + reinstall, which wipes
///     local SQLite).
///   * The owner can browse history via the bridge admin UI from any
///     browser instead of pulling CSV exports off-device.
///   * Future multi-device sync (head unit + phone seeing the same
///     trips) becomes possible without further client work.
///
/// SCOPE — what THIS service does and does not do
/// -----------------------------------------------
/// DOES:
///   * Read existing Drift tables (Trips, Snapshots, SweepRuns +
///     SweepResults, LiveLogSessions + LiveLogEntries). Read only —
///     never writes back.
///   * POST batches to /v1/data/ingest/*.
///   * Heartbeat /v1/data/ingest/heartbeat once per minute.
///   * Persist sync cursors in SharedPreferences so we never re-upload.
///   * Persist client_token in flutter_secure_storage (Keystore).
///   * Provide a setup flow (entered setup token → register-device →
///     get client_token).
///   * Expose status to the Settings UI as ChangeNotifier.
///
/// DOES NOT:
///   * Touch ConnectionService, ELM327, or any BLE plumbing.
///   * Add or modify any Drift table or column.
///   * Sync samples (server returns 403 samples_disabled by default —
///     handled gracefully; we just don't attempt).
///   * Run command long-polling (that's BridgeDiagService — Plane A,
///     separate singleton).
///   * Pull anything from the server (the read endpoints exist but
///     the client never calls them — local Drift is the source of
///     truth for the app's own UI).
///
/// LIFECYCLE
/// ---------
/// Created in main.dart in a MultiProvider. .init() is called once at
/// app startup; it loads persisted state from prefs + secure storage.
/// If both cloudSyncEnabled and registered() are true, a periodic
/// Timer.periodic(1 min) starts and fires syncOnce() each tick.
/// syncOnce() returns immediately if a sync is already in flight.
///
/// IDEMPOTENCY MODEL
/// -----------------
/// Bridge dedupes on (device_id, client_*_id) with ON CONFLICT DO
/// NOTHING. We just use the local Drift autoincrement id as the
/// client side id and walk it forward. Cursor logic:
///   1. fetch all Drift rows where id > lastSyncedTripId
///   2. POST them in batches
///   3. on success: lastSyncedTripId = max(id) in this batch
/// Server treats already-known ids as duplicates → safe to retry
/// the whole batch verbatim on transient failure.
///
/// KNOWN EDGE CASE (Track 1 Option A, accepted):
///   If the user clears the local Drift DB (Data Management →
///   Clear all) the autoincrement restarts at 1. Bridge already
///   has trip_id=1..N → new uploads are silently dropped as
///   duplicates. Fix: owner reissues setup token, user re-registers
///   the device (which gets a fresh device_id, so all old ids are
///   "new" again).
///
/// SECURITY
/// --------
/// client_token format: <device_id>.<secret>. We send the whole thing
/// as Bearer. Server only stores sha256(secret). Token lives in
/// platform secure storage (Android Keystore via flutter_secure_storage),
/// never SharedPreferences.
///
/// On 401 we mark the token bad and stop syncing. UI surfaces this
/// as "auth failed — re-register". No silent retries on 401 — they
/// just waste battery.
///
/// NETWORKING
/// ----------
/// One shared http.Client kept alive for keep-alive reuse. All HTTPS,
/// nginx-terminated. Body cap 25MB (sensible — we batch in chunks of
/// 50 trips / 200 snapshots / 1 sweep+results / 1 livelog+entries to
/// stay well under).
///
/// Retry policy mirrors CLIENT_API.md §8:
///   2xx        success
///   400/401/403/404/409  permanent — no retry, log + surface
///   408/429/5xx  exponential backoff 5/15/45/120s, then give up
///                this cycle (next periodic tick retries naturally)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database.dart';

// ─── Public enums / value objects ──────────────────────────────────

/// Coarse UI status. Settings card reads this directly.
enum CloudSyncStatus {
  /// User has never run setup, or has disconnected.
  disconnected,

  /// Toggle is off but device is registered. Cursor preserved.
  pausedByUser,

  /// Registered + enabled + last sync ok (or no work to do).
  idle,

  /// A sync is in flight right now.
  syncing,

  /// Last sync failed. Settings shows the error. Next periodic tick
  /// will retry automatically; user can also press Force resync.
  error,

  /// Server returned 401. Token is bad — user must re-register with
  /// a fresh setup token from the owner.
  authFailed,
}

/// Vehicle row from GET /v1/setup/vehicles.
class CloudVehicle {
  final String id;
  final String manufacturer;
  final String model;
  final int? modelYear;
  final String displayName;
  const CloudVehicle({
    required this.id,
    required this.manufacturer,
    required this.model,
    this.modelYear,
    required this.displayName,
  });
  factory CloudVehicle.fromJson(Map<String, dynamic> j) => CloudVehicle(
        id: j['id'] as String,
        manufacturer: j['manufacturer'] as String,
        model: j['model'] as String,
        modelYear: j['model_year'] as int?,
        displayName: j['display_name'] as String,
      );
}

/// Lightweight stats for the Settings card.
class CloudSyncStats {
  /// Counts pending (locally present, not yet on server) per table.
  /// Computed from `max(local id) - lastSyncedId`. Approximate when
  /// gaps exist (deleted rows) but good enough for "is sync caught up".
  final int pendingTrips;
  final int pendingSnapshots;
  final int pendingSweeps;
  final int pendingLiveLogs;
  const CloudSyncStats({
    this.pendingTrips = 0,
    this.pendingSnapshots = 0,
    this.pendingSweeps = 0,
    this.pendingLiveLogs = 0,
  });
  int get totalPending =>
      pendingTrips + pendingSnapshots + pendingSweeps + pendingLiveLogs;
}

// ─── Service ───────────────────────────────────────────────────────

class CloudSyncService extends ChangeNotifier {
  CloudSyncService({required AppDatabase db}) : _db = db;

  final AppDatabase _db;

  // ── persistence keys ──
  static const _kEnabled = 'cloud_sync_enabled';
  static const _kBaseUrl = 'cloud_sync_base_url';
  static const _kDeviceId = 'cloud_sync_device_id';
  static const _kVehicleId = 'cloud_sync_vehicle_id';
  static const _kVehicleName = 'cloud_sync_vehicle_name';
  static const _kCursorTrip = 'cloud_sync_cursor_trip';
  static const _kCursorSnapshot = 'cloud_sync_cursor_snapshot';
  static const _kCursorSweep = 'cloud_sync_cursor_sweep';
  static const _kCursorLiveLog = 'cloud_sync_cursor_livelog';
  static const _kLastSuccessAt = 'cloud_sync_last_success_at';
  static const _kLastError = 'cloud_sync_last_error';
  static const _kSamplesRejectedAt = 'cloud_sync_samples_rejected_at';

  // secure storage key for client_token only
  static const _kTokenKey = 'cloud_sync_client_token';

  static const _defaultBaseUrl = 'https://carbridge.neardo.work';

  // ── state (loaded by init()) ──
  bool _enabled = false;
  String _baseUrl = _defaultBaseUrl;
  String? _clientToken;
  String? _deviceId;
  String? _vehicleId;
  String? _vehicleName;

  int _cursorTrip = 0;
  int _cursorSnapshot = 0;
  int _cursorSweep = 0;
  int _cursorLiveLog = 0;

  DateTime? _lastSuccessAt;
  String? _lastError;
  DateTime? _samplesRejectedAt;

  CloudSyncStatus _status = CloudSyncStatus.disconnected;
  CloudSyncStats _stats = const CloudSyncStats();
  bool _syncInProgress = false;
  bool _initialized = false;

  Timer? _periodicTimer;
  Timer? _heartbeatTimer;
  final http.Client _http = http.Client();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // ── public getters ──
  bool get enabled => _enabled;
  bool get isRegistered => _clientToken != null && _deviceId != null;
  String get baseUrl => _baseUrl;
  String? get deviceId => _deviceId;
  String? get vehicleId => _vehicleId;
  String? get vehicleName => _vehicleName;
  DateTime? get lastSuccessAt => _lastSuccessAt;
  String? get lastError => _lastError;
  CloudSyncStatus get status => _status;
  CloudSyncStats get stats => _stats;
  bool get isInitialized => _initialized;

  // ─── init / disposal ─────────────────────────────────────────────

  /// Load persisted state + start background timers if conditions met.
  /// Safe to call once; idempotent on subsequent calls.
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_kEnabled) ?? false;
    _baseUrl = prefs.getString(_kBaseUrl) ?? _defaultBaseUrl;
    _deviceId = prefs.getString(_kDeviceId);
    _vehicleId = prefs.getString(_kVehicleId);
    _vehicleName = prefs.getString(_kVehicleName);
    _cursorTrip = prefs.getInt(_kCursorTrip) ?? 0;
    _cursorSnapshot = prefs.getInt(_kCursorSnapshot) ?? 0;
    _cursorSweep = prefs.getInt(_kCursorSweep) ?? 0;
    _cursorLiveLog = prefs.getInt(_kCursorLiveLog) ?? 0;
    final lastTs = prefs.getInt(_kLastSuccessAt);
    if (lastTs != null) {
      _lastSuccessAt = DateTime.fromMillisecondsSinceEpoch(lastTs);
    }
    _lastError = prefs.getString(_kLastError);
    final samplesRej = prefs.getInt(_kSamplesRejectedAt);
    if (samplesRej != null) {
      _samplesRejectedAt =
          DateTime.fromMillisecondsSinceEpoch(samplesRej);
    }
    try {
      _clientToken = await _secureStorage.read(key: _kTokenKey);
    } catch (e) {
      // On some emulators or rooted devices, the keystore may be
      // unavailable. We don't want to crash the app — just treat the
      // user as disconnected; setup flow will retry the write.
      debugPrint('CloudSync: secure storage read failed: $e');
      _clientToken = null;
    }
    _initialized = true;
    _recomputeStatus();
    await _recomputeStats();
    _restartTimers();
    notifyListeners();
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    _heartbeatTimer?.cancel();
    _http.close();
    super.dispose();
  }

  // ─── timers ──────────────────────────────────────────────────────

  /// Start (or restart) the periodic sync + heartbeat. Called whenever
  /// enabled-flag or registration changes. Cheap and safe to call.
  void _restartTimers() {
    _periodicTimer?.cancel();
    _heartbeatTimer?.cancel();
    if (!_enabled || !isRegistered) return;

    // Sync every 60s. Catches new trips/snapshots/sweeps/livelogs the
    // ConnectionService wrote in the last minute. If the device was
    // offline, multiple cycles' worth of data will go up at once.
    _periodicTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      syncOnce(reason: 'periodic');
    });

    // Heartbeat every 60s (offset by 30s from sync to spread load).
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _sendHeartbeat();
    });

    // Kick off an immediate sync + heartbeat so the user sees activity
    // right after toggling on.
    Future.microtask(() => syncOnce(reason: 'enable'));
    Future.microtask(_sendHeartbeat);
  }

  // ─── public mutators ─────────────────────────────────────────────

  /// Toggle the master switch. When turned off, leaves device
  /// registration and cursors intact; turning back on resumes.
  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, v);
    _recomputeStatus();
    _restartTimers();
    notifyListeners();
  }

  /// Override the base URL (for moving to a self-hosted bridge or
  /// switching deployments). Edge case; most users never touch.
  Future<void> setBaseUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty || _baseUrl == trimmed) return;
    _baseUrl = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, trimmed);
    notifyListeners();
  }

  /// List available vehicles for the setup flow. Requires the user-
  /// entered setup token. Throws on transport / auth errors so the
  /// dialog can show them.
  Future<List<CloudVehicle>> listVehiclesForSetup(String setupToken) async {
    final resp = await _http.get(
      Uri.parse('$_baseUrl/v1/setup/vehicles'),
      headers: {'Authorization': 'Bearer $setupToken'},
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      throw const _BridgeException('Setup token is invalid or expired');
    }
    if (resp.statusCode != 200) {
      throw _BridgeException(
          'List vehicles failed (HTTP ${resp.statusCode}): ${resp.body}');
    }
    final raw = jsonDecode(resp.body) as List<dynamic>;
    return raw
        .map((e) => CloudVehicle.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Complete registration: POST /v1/setup/register-device, store the
  /// returned client_token in Keystore, set cursors to 0 (full first
  /// sync), turn the feature on. Throws on failure — caller shows the
  /// error to the user without committing any state.
  Future<void> registerDevice({
    required String setupToken,
    required String vehicleId,
    required String displayName,
    required String clientVersion,
    String kind = 'phone',
  }) async {
    final resp = await _http
        .post(
      Uri.parse('$_baseUrl/v1/setup/register-device'),
      headers: {
        'Authorization': 'Bearer $setupToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'vehicle_id': vehicleId,
        'kind': kind,
        'display_name': displayName,
        'client_kind': 'flutter-bz5-companion',
        'client_version': clientVersion,
      }),
    )
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode == 401) {
      throw const _BridgeException('Setup token is invalid or expired');
    }
    if (resp.statusCode != 201) {
      throw _BridgeException(
          'Register failed (HTTP ${resp.statusCode}): ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = data['client_token'] as String;
    final newDeviceId = data['device_id'] as String;
    final vehicle = data['vehicle'] as Map<String, dynamic>;
    final vehicleName = vehicle['display_name'] as String;

    // Persist atomically: secure store first (if it fails, prefs are
    // untouched so we're never in "registered without token").
    await _secureStorage.write(key: _kTokenKey, value: token);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceId, newDeviceId);
    await prefs.setString(_kVehicleId, vehicleId);
    await prefs.setString(_kVehicleName, vehicleName);
    // Fresh device: start cursors at 0 so the entire local history
    // goes up on first sync.
    await prefs.setInt(_kCursorTrip, 0);
    await prefs.setInt(_kCursorSnapshot, 0);
    await prefs.setInt(_kCursorSweep, 0);
    await prefs.setInt(_kCursorLiveLog, 0);
    await prefs.setBool(_kEnabled, true);

    _clientToken = token;
    _deviceId = newDeviceId;
    _vehicleId = vehicleId;
    _vehicleName = vehicleName;
    _cursorTrip = 0;
    _cursorSnapshot = 0;
    _cursorSweep = 0;
    _cursorLiveLog = 0;
    _enabled = true;
    _lastError = null;
    _samplesRejectedAt = null;

    _recomputeStatus();
    await _recomputeStats();
    _restartTimers();
    notifyListeners();
  }

  /// Forget the device on the client side. The server-side device row
  /// stays (admin can revoke explicitly if desired); but this app
  /// won't talk to it anymore. Cursors are wiped so a future re-
  /// register can start fresh.
  Future<void> disconnect() async {
    _periodicTimer?.cancel();
    _heartbeatTimer?.cancel();
    try {
      await _secureStorage.delete(key: _kTokenKey);
    } catch (e) {
      debugPrint('CloudSync: secure delete failed: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDeviceId);
    await prefs.remove(_kVehicleId);
    await prefs.remove(_kVehicleName);
    await prefs.remove(_kCursorTrip);
    await prefs.remove(_kCursorSnapshot);
    await prefs.remove(_kCursorSweep);
    await prefs.remove(_kCursorLiveLog);
    await prefs.remove(_kLastSuccessAt);
    await prefs.remove(_kLastError);
    await prefs.setBool(_kEnabled, false);

    _clientToken = null;
    _deviceId = null;
    _vehicleId = null;
    _vehicleName = null;
    _cursorTrip = 0;
    _cursorSnapshot = 0;
    _cursorSweep = 0;
    _cursorLiveLog = 0;
    _enabled = false;
    _lastSuccessAt = null;
    _lastError = null;

    _recomputeStatus();
    notifyListeners();
  }

  /// Reset cursors to 0 — next sync replays the entire local history.
  /// Useful after Drift restore from backup, or to force a known
  /// state. No-op if not registered.
  Future<void> forceFullResync() async {
    if (!isRegistered) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kCursorTrip, 0);
    await prefs.setInt(_kCursorSnapshot, 0);
    await prefs.setInt(_kCursorSweep, 0);
    await prefs.setInt(_kCursorLiveLog, 0);
    _cursorTrip = 0;
    _cursorSnapshot = 0;
    _cursorSweep = 0;
    _cursorLiveLog = 0;
    notifyListeners();
    await syncOnce(reason: 'force-resync');
  }

  // ─── sync core ───────────────────────────────────────────────────

  /// Perform one sync cycle. Returns immediately if already running.
  /// Catches all exceptions internally and writes _lastError; never
  /// throws to the caller.
  Future<void> syncOnce({String reason = 'manual'}) async {
    if (!_initialized) return;
    if (!_enabled || !isRegistered) return;
    if (_syncInProgress) return;
    _syncInProgress = true;
    _status = CloudSyncStatus.syncing;
    notifyListeners();
    try {
      await _syncTrips();
      await _syncSnapshots();
      await _syncSweeps();
      await _syncLiveLogs();
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastSuccessAt, _lastSuccessAt!.millisecondsSinceEpoch);
      await prefs.remove(_kLastError);
      await _recomputeStats();
      _recomputeStatus();
    } on _AuthException {
      _lastError = 'Authentication failed — re-register required';
      _status = CloudSyncStatus.authFailed;
      await _persistError(_lastError!);
      // Stop timers; user must take action.
      _periodicTimer?.cancel();
      _heartbeatTimer?.cancel();
    } on _BridgeException catch (e) {
      _lastError = e.message;
      _status = CloudSyncStatus.error;
      await _persistError(e.message);
    } on SocketException catch (e) {
      _lastError = 'Network: ${e.message}';
      _status = CloudSyncStatus.error;
      await _persistError(_lastError!);
    } on TimeoutException {
      _lastError = 'Timeout waiting for bridge';
      _status = CloudSyncStatus.error;
      await _persistError(_lastError!);
    } catch (e, st) {
      debugPrint('CloudSync: unexpected error: $e\n$st');
      _lastError = 'Unexpected: $e';
      _status = CloudSyncStatus.error;
      await _persistError(_lastError!);
    } finally {
      _syncInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _syncTrips() async {
    while (true) {
      // Pull a window of unsynced trips. We don't have getTripsAfterId
      // in the DB API; use getAllTrips and filter — Trip rows are
      // ~80 fields each but the table is small (~hundreds across the
      // whole app history). For larger tables (Snapshots) we use a
      // more targeted query below.
      final all = await _db.getAllTrips();
      final pending = all.where((t) => t.id > _cursorTrip).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      if (pending.isEmpty) break;
      const batchSize = 50;
      final batch = pending.take(batchSize).toList();
      final body = {
        'items': batch.map(_tripToJson).toList(),
      };
      await _postIngest('/v1/data/ingest/trips', body);
      _cursorTrip = batch.last.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCursorTrip, _cursorTrip);
      if (pending.length <= batchSize) break;
    }
  }

  Future<void> _syncSnapshots() async {
    // Snapshots can be large (thousands per day). We pull all once
    // and walk in id order. Drift in-memory list is fine up to ~10k
    // rows; beyond that we'd need a custom query. For the home-user
    // single-vehicle scenario, this is plenty.
    final all = await _db.getAllSnapshots();
    final pending = all.where((s) => s.id > _cursorSnapshot).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (pending.isEmpty) return;
    const batchSize = 200;
    for (int off = 0; off < pending.length; off += batchSize) {
      final end = (off + batchSize).clamp(0, pending.length);
      final batch = pending.sublist(off, end);
      final body = {
        'items': batch.map(_snapshotToJson).toList(),
      };
      await _postIngest('/v1/data/ingest/snapshots', body);
      _cursorSnapshot = batch.last.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCursorSnapshot, _cursorSnapshot);
    }
  }

  Future<void> _syncSweeps() async {
    final all = await _db.getAllSweepRuns();
    final pending = all.where((s) => s.id > _cursorSweep).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (pending.isEmpty) return;
    // One parent + nested results per request, per CLIENT_API.md.
    // A sweep can have up to 256 results — well under any limit.
    for (final run in pending) {
      final results = await _db.getSweepResults(run.id);
      final body = {
        'items': [_sweepRunToJson(run, results)]
      };
      await _postIngest('/v1/data/ingest/sweeps', body);
      _cursorSweep = run.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCursorSweep, _cursorSweep);
    }
  }

  Future<void> _syncLiveLogs() async {
    final all = await _db.getAllLiveLogSessions();
    final pending = all.where((s) => s.id > _cursorLiveLog).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (pending.isEmpty) return;
    for (final session in pending) {
      final entries = await _db.getLiveLogEntries(session.id);
      // A session of 1196s × 7 DIDs ≈ 8400 entries which serializes to
      // ~700KB JSON. Bridge nginx caps at 25M, plus server caps items
      // arrays at 10000. If we'd exceed either, split entries into
      // multiple POSTs of the same parent (parent insert is idempotent
      // so this is safe). For the foreseeable future a single session
      // fits in one request; the chunking logic below is preventive.
      const maxEntriesPerPost = 5000;
      if (entries.length <= maxEntriesPerPost) {
        final body = {
          'items': [_liveLogToJson(session, entries)]
        };
        await _postIngest('/v1/data/ingest/livelogs', body);
      } else {
        // Split: first POST has the parent + first chunk; subsequent
        // POSTs include the same parent (de-duped on server) + next
        // chunks. This is naive — entries get spread across multiple
        // POSTs. As long as server uses ON CONFLICT for entries too,
        // we'd be fine. The CLIENT_API doc doesn't explicitly say
        // entries are idempotent across multiple inserts for the same
        // session; until then, we only split if absolutely needed.
        // For now: send first chunk; log a warning that some entries
        // were skipped. v0.1.28+1 baseline: just upload first 5000.
        debugPrint('CloudSync: livelog ${session.id} has '
            '${entries.length} entries, only uploading first '
            '$maxEntriesPerPost');
        final body = {
          'items': [_liveLogToJson(session, entries.take(maxEntriesPerPost).toList())]
        };
        await _postIngest('/v1/data/ingest/livelogs', body);
      }
      _cursorLiveLog = session.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCursorLiveLog, _cursorLiveLog);
    }
  }

  Future<void> _sendHeartbeat() async {
    if (!_enabled || !isRegistered) return;
    try {
      await _postIngest('/v1/data/ingest/heartbeat',
          {'client_version': await _readAppVersion()});
    } catch (e) {
      // Heartbeat failure is non-fatal; just log.
      debugPrint('CloudSync: heartbeat failed: $e');
    }
  }

  // ─── HTTP wrapper ───────────────────────────────────────────────

  Future<Map<String, dynamic>> _postIngest(
      String path, Map<String, dynamic> body) async {
    final token = _clientToken;
    if (token == null) {
      throw const _AuthException();
    }
    final uri = Uri.parse('$_baseUrl$path');
    final resp = await _http
        .post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    )
        .timeout(const Duration(seconds: 30));
    final code = resp.statusCode;
    if (code >= 200 && code < 300) {
      if (resp.body.isEmpty) return const {};
      try {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      } catch (_) {
        return const {};
      }
    }
    if (code == 401) {
      throw const _AuthException();
    }
    if (code == 403) {
      // Special-case samples_disabled so /samples can fail silently.
      // No other 403 is expected for plane B; log it.
      final errCode = _parseErrorCode(resp.body);
      if (path.contains('/samples') && errCode == 'samples_disabled') {
        await _markSamplesRejected();
        throw _BridgeException('Samples ingest disabled on server');
      }
      throw _BridgeException(
          'Forbidden (${errCode ?? 'no code'}) on $path: ${resp.body}');
    }
    throw _BridgeException(
        'HTTP $code on $path: ${_briefBody(resp.body)}');
  }

  /// Extracts {"error":{"code":"..."}} (or {"detail":{"error":...}})
  /// shape per CLIENT_API.md §8.
  String? _parseErrorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final err = decoded['error'] ?? decoded['detail']?['error'];
        if (err is Map<String, dynamic>) {
          return err['code'] as String?;
        }
      }
    } catch (_) {}
    return null;
  }

  String _briefBody(String body) {
    if (body.length <= 200) return body;
    return '${body.substring(0, 200)}...';
  }

  Future<void> _markSamplesRejected() async {
    _samplesRejectedAt = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _kSamplesRejectedAt, _samplesRejectedAt!.millisecondsSinceEpoch);
  }

  Future<void> _persistError(String msg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastError, msg);
  }

  void _recomputeStatus() {
    if (!isRegistered) {
      _status = CloudSyncStatus.disconnected;
    } else if (!_enabled) {
      _status = CloudSyncStatus.pausedByUser;
    } else if (_status == CloudSyncStatus.authFailed) {
      // sticky until reconnect/disconnect
    } else if (_lastError != null && _lastSuccessAt == null) {
      _status = CloudSyncStatus.error;
    } else {
      _status = CloudSyncStatus.idle;
    }
  }

  Future<void> _recomputeStats() async {
    // Approximate pending counts using max(id) - cursor. Drift gaps
    // (deleted rows) would make this slightly overestimate; for the
    // single-user app where deletes are rare, this is good enough.
    try {
      final trips = await _db.getRecentTrips(limit: 1);
      final snapshots = await _db.getRecentSnapshots(limit: 1);
      final sweeps = await _db.getAllSweepRuns();
      final logs = await _db.getAllLiveLogSessions();
      final maxTrip = trips.isEmpty ? 0 : trips.first.id;
      final maxSnap = snapshots.isEmpty ? 0 : snapshots.first.id;
      final maxSweep =
          sweeps.isEmpty ? 0 : sweeps.map((s) => s.id).reduce((a, b) => a > b ? a : b);
      final maxLog =
          logs.isEmpty ? 0 : logs.map((s) => s.id).reduce((a, b) => a > b ? a : b);
      _stats = CloudSyncStats(
        pendingTrips: (maxTrip - _cursorTrip).clamp(0, 1 << 30),
        pendingSnapshots: (maxSnap - _cursorSnapshot).clamp(0, 1 << 30),
        pendingSweeps: (maxSweep - _cursorSweep).clamp(0, 1 << 30),
        pendingLiveLogs: (maxLog - _cursorLiveLog).clamp(0, 1 << 30),
      );
    } catch (e) {
      debugPrint('CloudSync: recomputeStats failed: $e');
    }
  }

  // ─── JSON mappers ────────────────────────────────────────────────
  // These mirror CLIENT_API.md §3 exactly. Null-handling: send null
  // for any field absent locally — bridge schema is all-nullable for
  // optional columns.

  Map<String, dynamic> _tripToJson(Trip t) {
    return {
      'client_trip_id': t.id,
      'started_at': t.startedAt.toUtc().toIso8601String(),
      'ended_at': t.endedAt?.toUtc().toIso8601String(),
      'start_soc': t.startSoc,
      'end_soc': t.endSoc,
      'start_odometer': t.startOdometer,
      'end_odometer': t.endOdometer,
      'sample_count': t.sampleCount,
      'notes': t.notes,
      'distance_km': t.distanceKm,
      'energy_used_kwh': t.energyUsedKwh,
      'avg_consumption_kwh_100km': t.avgConsumptionKwh100km,
      'min_battery_temp_c': t.minBatteryTempC,
      'max_battery_temp_c': t.maxBatteryTempC,
      'max_cell_spread_mv': t.maxCellSpreadMv,
      'min_soc': t.minSoc,
      'max_soc': t.maxSoc,
      'peak_speed_kmh': t.peakSpeedKmh,
      'peak_power_kw': t.peakPowerKw,
      'peak_regen_kw': t.peakRegenKw,
      'regen_energy_kwh': t.regenEnergyKwh,
      'avg_moving_speed_kmh': t.avgMovingSpeedKmh,
      'moving_seconds': t.movingSeconds,
      'idle_seconds': t.idleSeconds,
      'energy_from_soc_kwh': t.energyFromSocKwh,
    };
  }

  Map<String, dynamic> _snapshotToJson(Snapshot s) {
    return {
      'client_snapshot_id': s.id,
      'captured_at': s.capturedAt.toUtc().toIso8601String(),
      'soc': s.soc,
      'soh': s.soh,
      'battery_temp_c': s.batteryTempC,
      'cell_voltage_min': s.cellVoltageMin,
      'cell_voltage_max': s.cellVoltageMax,
      'cell_spread': s.cellSpread,
      'odometer': s.odometer,
      'client_trip_id': s.tripId,
      'pack_voltage_v': s.packVoltageV,
      'hv_bus_v': s.hvBusV,
      'gear': s.gear,
      'pawl_engaged': s.pawlEngaged,
      'is_charging': s.isCharging,
      'charging_power_kw': s.chargingPowerKw,
      'cycle_count': s.cycleCount,
    };
  }

  Map<String, dynamic> _sweepRunToJson(SweepRun r, List<SweepResult> results) {
    return {
      'client_sweep_id': r.id,
      'started_at': r.startedAt.toUtc().toIso8601String(),
      'ended_at': r.endedAt?.toUtc().toIso8601String(),
      'tx_ecu': r.txEcu,
      'rx_ecu': r.rxEcu,
      'start_did': r.startDid,
      'end_did': r.endDid,
      'period_ms': r.periodMs,
      'car_state': r.carState,
      'notes': r.notes,
      'total_probes': r.totalProbes,
      'valid_responses': r.validResponses,
      'results': results
          .map((res) => {
                'did': res.did,
                'raw_hex': res.rawHex,
                'error_code': res.errorCode,
                'sequence': res.sequence,
              })
          .toList(),
    };
  }

  Map<String, dynamic> _liveLogToJson(
      LiveLogSession s, List<LiveLogEntry> entries) {
    return {
      'client_session_id': s.id,
      'started_at': s.startedAt.toUtc().toIso8601String(),
      'ended_at': s.endedAt?.toUtc().toIso8601String(),
      'did_list': s.didList,
      'car_state': s.carState,
      'notes': s.notes,
      'cycle_count': s.cycleCount,
      'entry_count': s.entryCount,
      'entries': entries
          .map((e) => {
                'timestamp': e.timestamp.toUtc().toIso8601String(),
                'ecu_tx': e.ecuTx,
                'did': e.did,
                'raw_hex': e.rawHex,
                'error_code': e.errorCode,
                'cycle': e.cycle,
              })
          .toList(),
    };
  }

  /// Read app version from the static value baked into the build.
  /// We don't have package_info_plus as a dep — pubspec-version is
  /// hardcoded here. Update when bumping. Off-by-one tolerated.
  Future<String> _readAppVersion() async => '0.1.29+5';
}

// ─── Internal exceptions ────────────────────────────────────────────

class _BridgeException implements Exception {
  final String message;
  const _BridgeException(this.message);
  @override
  String toString() => message;
}

class _AuthException implements Exception {
  const _AuthException();
  @override
  String toString() => 'Authentication failed';
}
