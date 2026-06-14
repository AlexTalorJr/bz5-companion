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

import 'package:drift/drift.dart' show Value;
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
  /// v0.1.29+29: pending CAN monitor sessions awaiting upload.
  final int pendingCanMonitors;
  const CloudSyncStats({
    this.pendingTrips = 0,
    this.pendingSnapshots = 0,
    this.pendingSweeps = 0,
    this.pendingLiveLogs = 0,
    this.pendingCanMonitors = 0,
  });
  int get totalPending =>
      pendingTrips +
      pendingSnapshots +
      pendingSweeps +
      pendingLiveLogs +
      pendingCanMonitors;
}

/// v0.1.29+18: state machine for one restore operation (pull history
/// from the bridge into local Drift after a reinstall). Independent of
/// CloudSyncStatus — sync continues to push under the *new* identity
/// once the restore advances the cursors at the end.
enum CloudRestoreStatus {
  /// Not started, or completed and acknowledged.
  idle,

  /// Validating the candidate client_token (probe GET).
  preflight,

  /// Paginating server data + inserting into Drift.
  fetching,

  /// Finished successfully.
  done,

  /// User pressed Cancel mid-loop. Already-inserted rows are kept;
  /// re-running with the same token resumes via row-level dedup.
  cancelled,

  /// Network or HTTP error stopped the loop. Same resume semantics as
  /// cancelled — retry is safe.
  error,
}

/// v0.1.29+18: counters for the in-flight or last completed restore.
/// `*Inserted` = `*Fetched` − duplicates already present locally.
class CloudRestoreProgress {
  /// 'trips' / 'snapshots' / 'done' / null
  final String? phase;
  final int tripsFetched;
  final int tripsInserted;
  final int snapshotsFetched;
  final int snapshotsInserted;
  const CloudRestoreProgress({
    this.phase,
    this.tripsFetched = 0,
    this.tripsInserted = 0,
    this.snapshotsFetched = 0,
    this.snapshotsInserted = 0,
  });
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
  /// v0.1.29+29: cursor for `/v1/data/ingest/canmonitor` uploads.
  /// Strictly id-ordered, same semantics as livelog cursor.
  static const _kCursorCanMonitor = 'cloud_sync_cursor_canmonitor';
  static const _kLastSuccessAt = 'cloud_sync_last_success_at';
  static const _kLastError = 'cloud_sync_last_error';
  static const _kSamplesRejectedAt = 'cloud_sync_samples_rejected_at';

  // v0.1.29+20: per-row push tracking for trips. Trip rows in Drift
  // are MUTABLE (endTrip rewrites aggregates on close), unlike the
  // append-only snapshots/sweeps/livelogs tables. The old
  // `id > _cursorTrip` strategy pushed each trip exactly once at
  // insert time (with endedAt=NULL, all aggregates NULL), so the
  // server kept a half-baked row forever — fixed by paired changes:
  // server now UPSERTs (§P5.2 in ROADMAP), client now pushes a trip
  // only after it has been finalized (endedAt != null) AND remembers
  // which trip ids it has already pushed (this set). _cursorTrip is
  // retained for stats (pending count) but no longer gates push.
  static const _kPushedTripIds = 'cloud_sync_pushed_trip_ids';

  // v0.1.29+18: persisted restore state. Status is non-persistent (in
  // memory only — a restore in flight when the app is killed becomes
  // 'idle' on next launch, and the user re-runs it; dedup makes that
  // safe). The last-completion-time + last-error pair IS persisted so
  // Settings can show "last restore N min ago" across launches.
  static const _kLastRestoreAt = 'cloud_sync_last_restore_at';
  static const _kLastRestoreError = 'cloud_sync_last_restore_error';

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
  /// v0.1.29+29: cursor for CAN monitor session uploads. Same semantics
  /// as [_cursorLiveLog].
  int _cursorCanMonitor = 0;

  // v0.1.29+20: tracks which trip ids have been successfully pushed
  // since this device's registration. Loaded from SharedPrefs as a
  // JSON int list. See _kPushedTripIds doc above for rationale.
  final Set<int> _pushedTripIds = <int>{};

  DateTime? _lastSuccessAt;
  String? _lastError;
  DateTime? _samplesRejectedAt;

  // v0.1.29+18: restore state. _restoreCancelRequested is a one-shot
  // flag the fetch loops check between pages; cleared on each
  // startRestore entry.
  CloudRestoreStatus _restoreStatus = CloudRestoreStatus.idle;
  CloudRestoreProgress _restoreProgress = const CloudRestoreProgress();
  String? _restoreError;
  bool _restoreCancelRequested = false;
  DateTime? _lastRestoreAt;

  CloudSyncStatus _status = CloudSyncStatus.disconnected;
  CloudSyncStats _stats = const CloudSyncStats();
  bool _syncInProgress = false;
  bool _initialized = false;

  /// v0.1.29+9: per CLIENT_API.md §8 + §1, single 401s can be transient
  /// (clock skew on the server, intermittent token store glitch, race
  /// during owner-side admin maintenance). Per the spec, "a sustained
  /// run of 401s (e.g. 3 consecutive ingest 401s) is the signal" to
  /// wipe the token. We count consecutive 401s in memory only — a
  /// successful response of any kind resets to 0. Restart-the-app also
  /// resets to 0 (not persisted), which is what we want: a user who
  /// killed the app between 401s should get fresh attempts, not have
  /// the counter carry across.
  int _consecutiveAuthFailures = 0;

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

  // v0.1.29+18: restore observables.
  CloudRestoreStatus get restoreStatus => _restoreStatus;
  CloudRestoreProgress get restoreProgress => _restoreProgress;
  String? get restoreError => _restoreError;
  DateTime? get lastRestoreAt => _lastRestoreAt;
  bool get isRestoring =>
      _restoreStatus == CloudRestoreStatus.preflight ||
      _restoreStatus == CloudRestoreStatus.fetching;

  /// v0.1.29+18: expose the plaintext client_token to the UI so the
  /// owner can copy it into a password manager. Server stores only
  /// sha256(secret + pepper) per ADR-08 — once forgotten, only an
  /// admin-side rotation can produce a new working token. Letting
  /// the owner back it up themselves removes that round-trip from
  /// the routine head-unit reinstall workflow.
  ///
  /// This is the ONLY public read of `_clientToken`. Sync paths
  /// always use `_clientToken` directly through `_postIngest` /
  /// `_getJson`; this getter is purely for the "Backup client
  /// token" dialog in Settings.
  String? get clientTokenForBackup => _clientToken;

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
    _cursorCanMonitor = prefs.getInt(_kCursorCanMonitor) ?? 0;
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
    // v0.1.29+18: restore — only the cross-launch fields. _restoreStatus
    // stays idle on launch even if previous run was mid-fetch; user
    // must explicitly re-press the button.
    final lastRestoreTs = prefs.getInt(_kLastRestoreAt);
    if (lastRestoreTs != null) {
      _lastRestoreAt = DateTime.fromMillisecondsSinceEpoch(lastRestoreTs);
    }
    _restoreError = prefs.getString(_kLastRestoreError);

    // v0.1.29+20: load pushed-trip-id set. Stored as JSON int list
    // (SharedPreferences supports List<String> natively but ints get
    // round-tripped through JSON to avoid String/int conversion noise).
    //
    // Note on first launch from a +17/+18/+19 upgrade: the key will be
    // absent and the set stays empty, so the next syncOnce will push
    // ALL locally-closed trips. Server-side UPSERT (§P5.2) absorbs
    // those as `{received:N, inserted:0, duplicates:N}` no-op merges
    // for trips already there, and as proper finalizes for trips that
    // +19 pushed prematurely with endedAt=NULL. Total cost is N HTTP
    // posts where N is the lifetime closed-trip count on this install
    // — acceptable in our scale, and avoids a subtle bug where the
    // migration would seed `pushed = closed-and-cursored` and then
    // skip the very re-push the +20 fix exists to enable.
    final pushedJson = prefs.getString(_kPushedTripIds);
    if (pushedJson != null) {
      try {
        final decoded = jsonDecode(pushedJson);
        if (decoded is List) {
          for (final v in decoded) {
            if (v is int) _pushedTripIds.add(v);
          }
        }
      } on FormatException {
        debugPrint('CloudSync: corrupted pushed-trip-ids json, ignoring');
      }
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
    await prefs.setInt(_kCursorCanMonitor, 0);  // v0.1.29+29
    // v0.1.29+20: pushed-trip-id set is identity-scoped; new device =
    // empty set = all closed trips will re-upload.
    await prefs.remove(_kPushedTripIds);
    await prefs.setBool(_kEnabled, true);

    _clientToken = token;
    _deviceId = newDeviceId;
    _vehicleId = vehicleId;
    _vehicleName = vehicleName;
    _cursorTrip = 0;
    _cursorSnapshot = 0;
    _cursorSweep = 0;
    _cursorLiveLog = 0;
    _cursorCanMonitor = 0;  // v0.1.29+29
    _pushedTripIds.clear();
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
    await prefs.remove(_kCursorCanMonitor);  // v0.1.29+29
    // v0.1.29+20: pushed-trip-id set is identity-scoped.
    await prefs.remove(_kPushedTripIds);
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
    _cursorCanMonitor = 0;  // v0.1.29+29
    _pushedTripIds.clear();
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
    await prefs.setInt(_kCursorCanMonitor, 0);  // v0.1.29+29
    // v0.1.29+20: "force full resync" means re-push everything; the
    // pushed-trip-id set is the main gate on trip push now.
    await prefs.remove(_kPushedTripIds);
    _cursorTrip = 0;
    _cursorSnapshot = 0;
    _cursorSweep = 0;
    _cursorLiveLog = 0;
    _cursorCanMonitor = 0;  // v0.1.29+29
    _pushedTripIds.clear();
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
      // v0.1.29+29: CAN passive monitor sessions (+ child frames).
      // Ordered last so a heavy sweep / livelog push doesn't starve
      // the bus monitor data, and so the bridge sees them after the
      // related livelog (rarely co-located on the same drive, but
      // we keep the convention).
      await _syncCanMonitors();
      _lastSuccessAt = DateTime.now();
      _lastError = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastSuccessAt, _lastSuccessAt!.millisecondsSinceEpoch);
      await prefs.remove(_kLastError);
      await _recomputeStats();
      _recomputeStatus();
    } on _AuthException {
      // v0.1.29+9: permanent auth failure (3+ consecutive 401s OR
      // explicit 409 already_revoked). Wipe the token from secure
      // storage so the next app start doesn't keep retrying with a
      // dead credential, and stop the timers — the user must run
      // the setup flow with a fresh setup token from the owner.
      _lastError = 'Auth failed — re-register required '
          '(token wiped after 3 consecutive 401s)';
      _status = CloudSyncStatus.authFailed;
      await _persistError(_lastError!);
      await _wipeTokenAndCursors();
      _periodicTimer?.cancel();
      _heartbeatTimer?.cancel();
    } on _TransientAuthException catch (e) {
      // v0.1.29+9: one or two 401s in a row — non-fatal. Surface a
      // soft error to UI but keep the token and let the next periodic
      // tick try again. The counter persists across syncOnce calls
      // (it's a field on this), so the third in-a-row across multiple
      // ticks will still flip to _AuthException.
      _lastError = e.toString();
      _status = CloudSyncStatus.error;
      await _persistError(_lastError!);
    } on _RetryableException catch (e) {
      // v0.1.29+9: 5xx/429/408 that survived the internal retry
      // budget. Don't touch the token; the next periodic tick will
      // try again with a fresh request.
      _lastError = e.toString();
      _status = CloudSyncStatus.error;
      await _persistError(_lastError!);
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

  /// v0.1.29+9: clear the credential and device-side cached identity
  /// when the server tells us we're done (3× 401 or explicit revoke).
  /// Keeps cursors so that if the user re-registers and the owner
  /// re-issues a token for the same device_id (rare but possible),
  /// we won't re-upload everything from scratch. If they re-register
  /// fresh (new device_id), the cursors are irrelevant because the
  /// server dedupes on (device_id, client_id).
  Future<void> _wipeTokenAndCursors() async {
    try {
      await _secureStorage.delete(key: _kTokenKey);
    } catch (e) {
      debugPrint('CloudSync: secure storage delete failed: $e');
    }
    _clientToken = null;
    // Leave _deviceId / _vehicleId in SharedPreferences for the UI
    // to display "Last registered as XYZ" if helpful. They're not
    // credentials.
  }

  Future<void> _syncTrips() async {
    // v0.1.29+20: changed semantics from id-cursor to finalize-gated
    // pushed-set. A Drift trip row is mutable (endTrip rewrites it on
    // close), so the previous "push exactly once at id > _cursorTrip"
    // strategy missed all finalize aggregates — server kept the open
    // start-only snapshot forever.
    //
    // New rule: push a trip only when (endedAt != null) AND (id not in
    // _pushedTripIds). After a successful batch POST, add the batched
    // ids to the set and persist. Server-side UPSERT (§P5.2) absorbs
    // any accidental re-push, so this is robust against partial
    // failures: a crash between POST and persist replays the batch,
    // and the server merges with no duplicate-row risk.
    //
    // _cursorTrip is still maintained as max(id seen) for the
    // pending-count stat in Settings; it no longer gates push.
    while (true) {
      final all = await _db.getAllTrips();
      final pending = all
          .where((t) => t.endedAt != null && !_pushedTripIds.contains(t.id))
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      if (pending.isEmpty) break;
      const batchSize = 50;
      final batch = pending.take(batchSize).toList();
      final body = {
        'items': batch.map(_tripToJson).toList(),
      };
      await _postIngest('/v1/data/ingest/trips', body);
      // Mark pushed only after POST succeeds. _postIngest throws on
      // any non-2xx (and the server-side UPSERT, once deployed,
      // guarantees a duplicate replay is a safe no-op).
      _pushedTripIds.addAll(batch.map((t) => t.id));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPushedTripIds,
          jsonEncode(_pushedTripIds.toList()));
      // Keep _cursorTrip in sync with max trip id for the pending-
      // count stat. Use max(local trip id seen), not just batch.last —
      // open trips are tracked too because they still represent
      // "pending" work, just gated by their own finalize.
      final maxAllId =
          all.isEmpty ? 0 : all.map((t) => t.id).reduce((a, b) => a > b ? a : b);
      if (maxAllId > _cursorTrip) {
        _cursorTrip = maxAllId;
        await prefs.setInt(_kCursorTrip, _cursorTrip);
      }
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
      // v0.1.29+22: do NOT push live log sessions while they are still
      // active (endedAt == null). Rationale and history:
      //
      // Cycle 3 (+21 verify, 2026-05-25): session id=3 froze mid-flight
      // at cycle 13/000A after writing 90 entries. ~1.5s before the
      // freeze, CloudSync's 60s tick had picked the session up here and
      // POSTed all 90 entries as a snapshot of an "in-progress"
      // session. The freeze happened immediately after. We could not
      // disprove that the cloud push (which competes for HTTP and the
      // sqflite isolate) was a contributing factor.
      //
      // Pushing partial sessions also has no functional value: bridge
      // already has the session metadata via the next sync after the
      // session ends, and partial-entries snapshots get rewritten
      // anyway. Skipping active sessions removes CloudSync as a
      // suspect for live-log freezes AND avoids re-pushing the same
      // session repeatedly while it grows.
      //
      // We `return` (not `continue`) on the first active session so
      // the cursor doesn't leapfrog past it. The next sync will pick
      // up where we left off — sessions are processed strictly in
      // id-order.
      if (session.endedAt == null) {
        return;
      }
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

  /// v0.1.29+29: push CAN monitor sessions (+ child frames) to bridge.
  ///
  /// Wire contract per bridge-changes-for-drug1.md (bridge commit c73f0fb):
  ///   - Endpoint: POST /v1/data/ingest/canmonitor
  ///   - Envelope: `{items: [<session>]}` — same as livelog
  ///   - Idempotency: bridge uses UNIQUE(device_id, client_session_id);
  ///     re-uploading the same session is a no-op with
  ///     `inserted=0, duplicates=1` in the response
  ///   - Empty frames array is valid (e.g. exit=no_frames_15s)
  ///
  /// Mirrors _syncLiveLogs' behaviour exactly:
  ///   - Don't push active sessions (endedAt == null) — bridge cursor
  ///     advances strictly in id order, so an active session in the
  ///     middle would block later finished sessions. Wait for the
  ///     finally-block in runCanMonitor to stamp endedAt + counts
  ///     before we push.
  ///   - Cursor-based: `_cursorCanMonitor` tracks the highest pushed
  ///     session id, persisted to SharedPreferences after each
  ///     successful POST.
  ///   - Single-POST per session: a 30s monitor at ~50 fps gives
  ///     ~1500 frames, JSON-encodes to ~150KB — well under bridge's
  ///     25M nginx cap. We don't yet split. If we ever hit a session
  ///     with 10000+ frames (e.g. extended drive sniff after Path A
  ///     proven open), revisit chunking analogous to the livelog
  ///     5000-entry guard.
  Future<void> _syncCanMonitors() async {
    final all = await _db.getAllCanMonitorSessions();
    final pending = all.where((s) => s.id > _cursorCanMonitor).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (pending.isEmpty) return;
    for (final session in pending) {
      // Skip sessions still running. Same reasoning as livelog (see
      // _syncLiveLogs cycle-3 note).
      if (session.endedAt == null) {
        return;
      }
      final frames = await _db.getCanFrames(session.id);
      // v0.1.29+32: also ship the raw (pre-parse) line capture so
      // offline analysis can recover frames in formats the on-device
      // parser didn't recognise.
      final rawLines = await _db.getCanRawLines(session.id);
      final body = {
        'items': [_canMonitorToJson(session, frames, rawLines)]
      };
      await _postIngest('/v1/data/ingest/canmonitor', body);
      _cursorCanMonitor = session.id;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kCursorCanMonitor, _cursorCanMonitor);
    }
  }

  Future<void> _sendHeartbeat() async {
    if (!_enabled || !isRegistered) return;
    try {
      await _postIngest('/v1/data/ingest/heartbeat',
          {'client_version': await _readAppVersion()});
    } catch (e) {
      // Heartbeat failure is non-fatal; just log. Note: if this hits
      // a 401, _postIngest still increments _consecutiveAuthFailures,
      // so a heartbeat-induced auth storm will eventually trip the
      // 3-strike rule in the next syncOnce. We intentionally don't
      // re-handle the wipe path here — it would race with syncOnce.
      debugPrint('CloudSync: heartbeat failed: $e');
    }
  }

  // ─── Restore (Plane B pull) ──────────────────────────────────────
  //
  // After a reinstall, flutter_secure_storage is wiped → the next
  // register-device call mints a fresh device_id and the cloud
  // archive under the previous device_id becomes invisible to the
  // app (client tokens are scoped to their own device_id per
  // CLIENT_API.md §4). Restore recovers from this by accepting the
  // previous device's client_token (out-of-band from the bridge
  // owner) and pulling trips+snapshots back into local Drift.
  //
  // Strategy: re-arm this client as the previous device — write
  // the old token to secure storage, set _deviceId to the value
  // parsed from the token's <device_id>.<secret> prefix, then
  // GET-paginate /v1/data/trips and /v1/data/snapshots through the
  // standard scoped read endpoints (no server-side admin help
  // required). Dedup at the row level by (started_at, distance_km)
  // for trips and captured_at for snapshots — re-running with the
  // same token after a partial restore safely resumes.
  //
  // Scope limitation (v0.1.29+18): sweeps and live-log sessions are
  // NOT restored. They have nested children and rarer use cases;
  // a follow-up patch can extend if needed. The cloud archive for
  // those still exists under the old device — owner-side admin
  // inspection works regardless.
  //
  // Local-id collision note: if the user accumulated trips locally
  // BETWEEN reinstall and Restore (i.e. cloud sync was active under
  // the NEW device_id for a while), those local trips occupy low
  // autoincrement ids that may collide with the restored data's
  // server-side (old_device_id, client_trip_id=1..N) keys when
  // push resumes. The cursor advancement at the end of a successful
  // restore (set to max local id) ensures we don't blindly re-push
  // them; the pre-Restore local trips therefore remain in the app
  // but are NOT synced under the restored identity. The UI dialog
  // warns about this.

  /// v0.1.29+18: validate a candidate client_token against the
  /// server before committing to a restore. Hits GET /v1/data/trips
  /// with limit=1 — cheapest read that exercises authorisation.
  /// Returns the device_id parsed from the token's prefix (the
  /// server expects <device_id>.<secret> per CLIENT_API.md §1).
  ///
  /// Throws _BridgeException on bad format, 401, or non-200.
  Future<String> probeRestoreToken(String token) async {
    final trimmed = token.trim();
    if (!trimmed.contains('.')) {
      throw const _BridgeException(
          'Token format must be <device_id>.<secret>');
    }
    final deviceId = trimmed.split('.').first;
    if (deviceId.isEmpty) {
      throw const _BridgeException('Token has empty device_id prefix');
    }
    final uri = Uri.parse('$_baseUrl/v1/data/trips')
        .replace(queryParameters: {'limit': '1'});
    final resp = await _http.get(uri, headers: {
      'Authorization': 'Bearer $trimmed',
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      throw const _BridgeException(
          'Token rejected (HTTP 401) — check with the bridge owner');
    }
    if (resp.statusCode != 200) {
      throw _BridgeException('Probe failed (HTTP ${resp.statusCode}): '
          '${_briefBody(resp.body)}');
    }
    return deviceId;
  }

  /// v0.1.29+18: replace the active client_token with [oldClientToken]
  /// and pull trips+snapshots from the server into local Drift with
  /// row-level dedup. After successful completion the push cursors are
  /// advanced past max local id so the next sync cycle doesn't replay
  /// restored rows.
  ///
  /// All errors land in _restoreError + _restoreStatus = error; the
  /// method itself never throws. Safe to retry with the same token —
  /// already-inserted rows are skipped by dedup.
  Future<void> startRestore({required String oldClientToken}) async {
    if (isRestoring) return;

    _restoreCancelRequested = false;
    _restoreStatus = CloudRestoreStatus.preflight;
    _restoreError = null;
    _restoreProgress = const CloudRestoreProgress(phase: 'trips');
    notifyListeners();

    final trimmed = oldClientToken.trim();
    final String newDeviceId;
    try {
      newDeviceId = await probeRestoreToken(trimmed);
    } catch (e) {
      _restoreError = e.toString();
      _restoreStatus = CloudRestoreStatus.error;
      notifyListeners();
      return;
    }

    // Probe succeeded. Atomically replace credentials before entering
    // the fetch loop, so a 401 inside _getJson can't happen mid-page
    // with stale state.
    try {
      await _secureStorage.write(key: _kTokenKey, value: trimmed);
    } catch (e) {
      _restoreError = 'Secure storage write failed: $e';
      _restoreStatus = CloudRestoreStatus.error;
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDeviceId, newDeviceId);
    _clientToken = trimmed;
    _deviceId = newDeviceId;
    _consecutiveAuthFailures = 0;

    _restoreStatus = CloudRestoreStatus.fetching;
    notifyListeners();

    // Pause periodic push while pull is in flight — avoids racing
    // a (now stale-cursor) push against the pull. Restart at end if
    // _enabled is true (see finally block).
    _periodicTimer?.cancel();
    _heartbeatTimer?.cancel();

    var tripsFetched = 0, tripsInserted = 0;
    var snapshotsFetched = 0, snapshotsInserted = 0;
    final tripIdMap = <int, int>{}; // serverClientTripId → newLocalId

    try {
      // ── Phase 1: trips ──
      String? cursor;
      while (true) {
        if (_restoreCancelRequested) {
          _restoreStatus = CloudRestoreStatus.cancelled;
          return;
        }
        final resp = await _getJson('/v1/data/trips', query: {
          'limit': '100',
          if (cursor != null) 'cursor': cursor,
        });
        final items = (resp['items'] as List?) ?? const [];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          tripsFetched++;
          final clientTripId = raw['client_trip_id'];
          if (clientTripId is! int) continue;
          final startedAtStr = raw['started_at'];
          if (startedAtStr is! String) continue;
          final startedAt = DateTime.parse(startedAtStr).toLocal();
          final distanceKm = (raw['distance_km'] as num?)?.toDouble();

          // Dedup: (started_at, distance_km) is the contract from
          // ROADMAP §P1.5 design. Multiple .where() calls AND together
          // in Drift — matches the existing pattern in database.dart
          // (getSamplesForTrip). Treat null distance_km as wildcard
          // match against null in DB via .isNull().
          //
          // v0.1.29+19: was previously written using the `&` operator
          // on Expression<bool>; that operator is defined through an
          // extension in 'package:drift/drift.dart' which we don't
          // import in full (only 'show Value'). Build failed in
          // kernel_snapshot. Multiple .where() is the idiomatic
          // Drift style and avoids the broader import.
          final query = _db.select(_db.trips)..limit(1);
          query.where((t) => t.startedAt.equals(startedAt));
          if (distanceKm != null) {
            query.where((t) => t.distanceKm.equals(distanceKm));
          } else {
            query.where((t) => t.distanceKm.isNull());
          }
          final existing = await query.getSingleOrNull();

          if (existing != null) {
            tripIdMap[clientTripId] = existing.id;
            continue;
          }

          final newLocalId = await _db
              .into(_db.trips)
              .insert(_tripCompanionFromJson(raw));
          tripIdMap[clientTripId] = newLocalId;
          tripsInserted++;
        }
        _restoreProgress = CloudRestoreProgress(
          phase: 'trips',
          tripsFetched: tripsFetched,
          tripsInserted: tripsInserted,
        );
        notifyListeners();

        final nextCursor = resp['next_cursor'];
        if (nextCursor is! String) break;
        cursor = nextCursor;
      }

      // ── Phase 2: snapshots ──
      _restoreProgress = CloudRestoreProgress(
        phase: 'snapshots',
        tripsFetched: tripsFetched,
        tripsInserted: tripsInserted,
      );
      notifyListeners();

      cursor = null;
      while (true) {
        if (_restoreCancelRequested) {
          _restoreStatus = CloudRestoreStatus.cancelled;
          return;
        }
        final resp = await _getJson('/v1/data/snapshots', query: {
          'limit': '200',
          if (cursor != null) 'cursor': cursor,
        });
        final items = (resp['items'] as List?) ?? const [];
        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          snapshotsFetched++;
          final capturedAtStr = raw['captured_at'];
          if (capturedAtStr is! String) continue;
          final capturedAt = DateTime.parse(capturedAtStr).toLocal();

          final existing = await (_db.select(_db.snapshots)
                ..where((s) => s.capturedAt.equals(capturedAt))
                ..limit(1))
              .getSingleOrNull();
          if (existing != null) continue;

          final rawTripId = raw['client_trip_id'];
          final mappedTripId =
              rawTripId is int ? tripIdMap[rawTripId] : null;

          await _db.into(_db.snapshots).insert(
              _snapshotCompanionFromJson(raw, tripId: mappedTripId));
          snapshotsInserted++;
        }
        _restoreProgress = CloudRestoreProgress(
          phase: 'snapshots',
          tripsFetched: tripsFetched,
          tripsInserted: tripsInserted,
          snapshotsFetched: snapshotsFetched,
          snapshotsInserted: snapshotsInserted,
        );
        notifyListeners();

        final nextCursor = resp['next_cursor'];
        if (nextCursor is! String) break;
        cursor = nextCursor;
      }

      // ── Cursor advancement ──
      // After restore, push cursors must skip everything currently
      // in Drift, including (a) newly inserted restored rows and
      // (b) any pre-existing rows that were on this device before
      // Restore. Otherwise the next push would replay them under
      // the restored identity, and the server would dedupe most
      // (old_device_id, client_*_id) collisions silently.
      final allTrips = await _db.getAllTrips();
      final allSnapsRecent = await _db.getRecentSnapshots(limit: 1);
      final maxTripId = allTrips.isEmpty
          ? 0
          : allTrips.map((t) => t.id).reduce((a, b) => a > b ? a : b);
      final maxSnapId =
          allSnapsRecent.isEmpty ? 0 : allSnapsRecent.first.id;
      _cursorTrip = maxTripId;
      _cursorSnapshot = maxSnapId;
      await prefs.setInt(_kCursorTrip, _cursorTrip);
      await prefs.setInt(_kCursorSnapshot, _cursorSnapshot);

      // v0.1.29+20: restored trips with endedAt != null are already on
      // the server (the restore loop fetched them from there) and
      // would be duplicates if re-pushed. Add to the pushed set so
      // _syncTrips skips them. Trips with endedAt == null are the
      // half-finalized ones we WANT to re-push once the client
      // recomputes aggregates (e.g. via _finalizeTripFromLastKnown);
      // leaving them out of the set ensures that future re-push.
      for (final t in allTrips) {
        if (t.endedAt != null) {
          _pushedTripIds.add(t.id);
        }
      }
      await prefs.setString(_kPushedTripIds,
          jsonEncode(_pushedTripIds.toList()));

      _restoreStatus = CloudRestoreStatus.done;
      _restoreProgress = CloudRestoreProgress(
        phase: 'done',
        tripsFetched: tripsFetched,
        tripsInserted: tripsInserted,
        snapshotsFetched: snapshotsFetched,
        snapshotsInserted: snapshotsInserted,
      );
      _lastRestoreAt = DateTime.now();
      await prefs.setInt(
          _kLastRestoreAt, _lastRestoreAt!.millisecondsSinceEpoch);
      await prefs.remove(_kLastRestoreError);
      _restoreError = null;

      // v0.1.29+18: head-unit reinstall path — Restore was the
      // entry point from a disconnected state (no prior Setup),
      // so _enabled is still false and periodic sync wouldn't
      // start. Flip it on; matches the post-Setup behaviour. If
      // restore ran from an already-registered state (rare —
      // someone wanting to merge histories), _enabled was true
      // anyway and this is a no-op write.
      _enabled = true;
      await prefs.setBool(_kEnabled, true);
      _lastError = null;
      await prefs.remove(_kLastError);
      _recomputeStatus();
    } catch (e) {
      _restoreError = e.toString();
      _restoreStatus = CloudRestoreStatus.error;
      try {
        await prefs.setString(_kLastRestoreError, _restoreError!);
      } catch (_) {
        // prefs write failure during error path — already bad, just log.
        debugPrint('CloudSync: could not persist restore error');
      }
    } finally {
      _restoreCancelRequested = false;
      // v0.1.29+18: was `wasEnabled && isRegistered` — after the
      // success-path `_enabled = true` flip above, this is now the
      // same condition used everywhere else (`isRegistered && _enabled`).
      // On error / cancel from a previously-disconnected restore,
      // _enabled was never flipped, so timers stay off — we don't
      // chase a possibly-half-committed identity.
      if (isRegistered && _enabled) {
        _restartTimers();
      }
      await _recomputeStats();
      notifyListeners();
    }
  }

  /// v0.1.29+18: request cancellation of an in-flight restore. The
  /// fetch loops check the flag between pages and exit cleanly.
  /// Already-inserted rows are preserved (idempotent dedup makes
  /// resume on the next Restore press safe).
  void cancelRestore() {
    if (!isRestoring) return;
    _restoreCancelRequested = true;
    notifyListeners();
  }

  /// v0.1.29+18: focused GET-with-retries helper. Smaller than
  /// _postIngest because read endpoints have a tighter error surface
  /// (no samples_disabled 403, no already_revoked 409), but follows
  /// the same 401 / 408 / 429 / 5xx semantics from CLIENT_API.md §8.
  /// Reuses _retryBackoff and _consecutiveAuthFailures for spec
  /// consistency with the push side.
  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
  }) async {
    final token = _clientToken;
    if (token == null) {
      throw const _AuthException();
    }
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    final headers = {'Authorization': 'Bearer $token'};

    var attempt = 0;
    while (true) {
      attempt++;
      http.Response resp;
      try {
        resp = await _http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        final delay = _retryBackoff[attempt - 1];
        if (delay == null) {
          throw const _RetryableException(408, 'client timeout');
        }
        await Future<void>.delayed(delay);
        continue;
      } on SocketException {
        final delay = _retryBackoff[attempt - 1];
        if (delay == null) rethrow;
        await Future<void>.delayed(delay);
        continue;
      }

      final code = resp.statusCode;
      if (code >= 200 && code < 300) {
        if (_consecutiveAuthFailures > 0) {
          _consecutiveAuthFailures = 0;
        }
        if (resp.body.isEmpty) return const {};
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map<String, dynamic>) return decoded;
          throw _BridgeException(
              'Unexpected JSON shape from $path: '
              '${_briefBody(resp.body)}');
        } on FormatException {
          throw _BridgeException(
              'Malformed JSON from $path: ${_briefBody(resp.body)}');
        }
      }
      if (code == 401) {
        _consecutiveAuthFailures++;
        if (_consecutiveAuthFailures >= 3) {
          throw const _AuthException();
        }
        throw _TransientAuthException(_consecutiveAuthFailures);
      }
      // 408 / 429 / 5xx → retry with backoff (same schedule as push).
      if (code == 408 || code == 429 || code >= 500) {
        final delay =
            _retryAfterDelay(resp) ?? _retryBackoff[attempt - 1];
        if (delay == null) {
          throw _RetryableException(code, _briefBody(resp.body));
        }
        await Future<void>.delayed(delay);
        continue;
      }
      // 400 / 403 / 404 / 409 / other 4xx → permanent client error.
      throw _BridgeException(
          'HTTP $code on $path: ${_briefBody(resp.body)}');
    }
  }

  /// v0.1.29+18: build TripsCompanion from a server-returned JSON
  /// item. Server JSON shape mirrors the POST upload shape
  /// (snake_case) per CLIENT_API.md §3.1. Defensively typed —
  /// missing or wrong-typed fields fall through to null / 0.
  TripsCompanion _tripCompanionFromJson(Map<String, dynamic> j) {
    DateTime parseDt(Object? v) =>
        v is String ? DateTime.parse(v).toLocal() : DateTime.now();
    Value<DateTime?> parseDtN(Object? v) => v is String
        ? Value(DateTime.parse(v).toLocal())
        : const Value(null);
    Value<double?> parseRealN(Object? v) =>
        v is num ? Value(v.toDouble()) : const Value(null);
    Value<int?> parseIntN(Object? v) =>
        v is int ? Value(v) : const Value(null);
    Value<String?> parseStrN(Object? v) =>
        v is String ? Value(v) : const Value(null);
    return TripsCompanion(
      startedAt: Value(parseDt(j['started_at'])),
      endedAt: parseDtN(j['ended_at']),
      startSoc: parseRealN(j['start_soc']),
      endSoc: parseRealN(j['end_soc']),
      startOdometer: parseRealN(j['start_odometer']),
      endOdometer: parseRealN(j['end_odometer']),
      sampleCount: j['sample_count'] is int
          ? Value(j['sample_count'] as int)
          : const Value(0),
      notes: parseStrN(j['notes']),
      distanceKm: parseRealN(j['distance_km']),
      energyUsedKwh: parseRealN(j['energy_used_kwh']),
      avgConsumptionKwh100km: parseRealN(j['avg_consumption_kwh_100km']),
      minBatteryTempC: parseRealN(j['min_battery_temp_c']),
      maxBatteryTempC: parseRealN(j['max_battery_temp_c']),
      maxCellSpreadMv: parseRealN(j['max_cell_spread_mv']),
      minSoc: parseRealN(j['min_soc']),
      maxSoc: parseRealN(j['max_soc']),
      peakSpeedKmh: parseRealN(j['peak_speed_kmh']),
      peakPowerKw: parseRealN(j['peak_power_kw']),
      peakRegenKw: parseRealN(j['peak_regen_kw']),
      regenEnergyKwh: parseRealN(j['regen_energy_kwh']),
      avgMovingSpeedKmh: parseRealN(j['avg_moving_speed_kmh']),
      movingSeconds: parseIntN(j['moving_seconds']),
      idleSeconds: parseIntN(j['idle_seconds']),
      energyFromSocKwh: parseRealN(j['energy_from_soc_kwh']),
      // v0.1.29+37: server stores extra as jsonb (object). Re-encode to
      // the local string column. This is the whole point — on a restore
      // after a wipe, the speed histogram comes back so the Speed
      // Distribution chart renders even though raw samples are gone.
      extra: _encodeExtraOrAbsent(j['extra']),
    );
  }

  /// v0.1.29+37: server's jsonb extra (a Map/List) → local string column.
  /// Absent value leaves the column untouched; anything present is
  /// re-serialized verbatim.
  Value<String?> _encodeExtraOrAbsent(dynamic serverExtra) {
    if (serverExtra == null) return const Value.absent();
    try {
      return Value(jsonEncode(serverExtra));
    } catch (_) {
      return const Value.absent();
    }
  }

  /// v0.1.29+18: build SnapshotsCompanion from a server JSON item.
  /// tripId is supplied externally — the server's client_trip_id
  /// references the OLD device's autoincrement, which the caller
  /// has already remapped to a fresh local id via tripIdMap.
  SnapshotsCompanion _snapshotCompanionFromJson(
    Map<String, dynamic> j, {
    int? tripId,
  }) {
    DateTime parseDt(Object? v) =>
        v is String ? DateTime.parse(v).toLocal() : DateTime.now();
    Value<double?> parseRealN(Object? v) =>
        v is num ? Value(v.toDouble()) : const Value(null);
    Value<int?> parseIntN(Object? v) =>
        v is int ? Value(v) : const Value(null);
    Value<bool?> parseBoolN(Object? v) =>
        v is bool ? Value(v) : const Value(null);
    return SnapshotsCompanion(
      capturedAt: Value(parseDt(j['captured_at'])),
      soc: parseRealN(j['soc']),
      soh: parseRealN(j['soh']),
      batteryTempC: parseRealN(j['battery_temp_c']),
      cellVoltageMin: parseRealN(j['cell_voltage_min']),
      cellVoltageMax: parseRealN(j['cell_voltage_max']),
      cellSpread: parseRealN(j['cell_spread']),
      odometer: parseRealN(j['odometer']),
      tripId: Value(tripId),
      packVoltageV: parseRealN(j['pack_voltage_v']),
      hvBusV: parseRealN(j['hv_bus_v']),
      gear: parseIntN(j['gear']),
      pawlEngaged: parseBoolN(j['pawl_engaged']),
      isCharging: parseBoolN(j['is_charging']),
      chargingPowerKw: parseRealN(j['charging_power_kw']),
      cycleCount: parseIntN(j['cycle_count']),
    );
  }

  // ─── HTTP wrapper ───────────────────────────────────────────────

  /// v0.1.29+9: backoff schedule from CLIENT_API.md §8 for retryable
  /// errors (408/429/5xx). Five entries → up to four retries before
  /// giving up; the final entry of `null` is the sentinel for "no
  /// more sleeping, give up now". The first attempt does not consume
  /// a slot — slot N is the sleep BEFORE attempt N+1.
  ///
  /// Total worst-case wall time per call: 5 + 15 + 45 + 120 = 185 s
  /// of sleeps plus 5 × (request RTT, capped at 30 s timeout each) =
  /// up to ~5 minutes. The next periodic tick (1 min) won't fire
  /// while syncOnce is in flight (the in-progress guard at line ~498
  /// blocks it), so this is safe — we won't pile up requests.
  static const List<Duration?> _retryBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
    Duration(seconds: 120),
    null, // give up
  ];

  Future<Map<String, dynamic>> _postIngest(
      String path, Map<String, dynamic> body) async {
    final token = _clientToken;
    if (token == null) {
      throw const _AuthException();
    }
    final uri = Uri.parse('$_baseUrl$path');
    final encodedBody = jsonEncode(body);
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    int attempt = 0;
    while (true) {
      attempt++;
      http.Response resp;
      try {
        resp = await _http
            .post(uri, headers: headers, body: encodedBody)
            .timeout(const Duration(seconds: 30));
      } on TimeoutException {
        // Treat client-side timeout like 408: retryable per CLIENT_API
        // §8 (408/429/5xx → backoff 5/15/45/120s).
        final delay = _retryBackoff[attempt - 1];
        if (delay == null) {
          throw const _RetryableException(408, 'client timeout');
        }
        debugPrint('CloudSync: timeout on $path attempt $attempt, '
            'sleeping ${delay.inSeconds}s');
        await Future<void>.delayed(delay);
        continue;
      } on SocketException catch (e) {
        // Same treatment — transient network error, backoff and retry.
        final delay = _retryBackoff[attempt - 1];
        if (delay == null) {
          // Bubble up to syncOnce, which will catch SocketException
          // separately and mark the error without wiping the token.
          rethrow;
        }
        debugPrint(
            'CloudSync: network error on $path attempt $attempt: ${e.message}, '
            'sleeping ${delay.inSeconds}s');
        await Future<void>.delayed(delay);
        continue;
      }

      final code = resp.statusCode;

      // v0.1.29+9: any 2xx clears the consecutive auth counter — a
      // single successful response is proof the token is valid.
      if (code >= 200 && code < 300) {
        if (_consecutiveAuthFailures > 0) {
          debugPrint('CloudSync: auth recovered after '
              '$_consecutiveAuthFailures consecutive 401s');
          _consecutiveAuthFailures = 0;
        }
        if (resp.body.isEmpty) return const {};
        try {
          return jsonDecode(resp.body) as Map<String, dynamic>;
        } catch (_) {
          return const {};
        }
      }

      // v0.1.29+9: 401 handling per CLIENT_API.md §1.
      // Threshold is exactly 3 consecutive — the spec uses "e.g. 3" as
      // the canonical example. Until then, treat as transient: the
      // outer syncOnce records a non-fatal error and the next periodic
      // tick will retry on a fresh request.
      if (code == 401) {
        _consecutiveAuthFailures++;
        debugPrint('CloudSync: 401 on $path '
            '(consecutive=$_consecutiveAuthFailures of 3)');
        if (_consecutiveAuthFailures >= 3) {
          throw const _AuthException();
        }
        throw _TransientAuthException(_consecutiveAuthFailures);
      }

      // 403 handling unchanged from v0.1.28+1 baseline: silently
      // remember samples_disabled, log other 403s. Not retryable.
      if (code == 403) {
        final errCode = _parseErrorCode(resp.body);
        if (path.contains('/samples') && errCode == 'samples_disabled') {
          await _markSamplesRejected();
          throw _BridgeException('Samples ingest disabled on server');
        }
        throw _BridgeException(
            'Forbidden (${errCode ?? 'no code'}) on $path: ${resp.body}');
      }

      // v0.1.29+9: 409 codes per CLIENT_API.md §8 are all "permanent"
      // (already_finished, already_revoked, not_cancellable, device
      // revoked variants). For ingest endpoints the only realistically
      // reachable one is already_revoked (the owner revoked us in the
      // admin UI). Treat as permanent auth failure — wipe and stop —
      // because retrying would just hit the same 401-storm sequence.
      // already_finished / not_cancellable apply to command endpoints
      // (Plane A, BridgeDiagService — not us); for safety we still
      // surface them as _BridgeException rather than _AuthException.
      if (code == 409) {
        final errCode = _parseErrorCode(resp.body);
        if (errCode == 'already_revoked' || errCode == 'device_revoked') {
          debugPrint('CloudSync: device revoked by owner — '
              'wiping token, requesting re-registration');
          throw const _AuthException();
        }
        throw _BridgeException(
            'Conflict (${errCode ?? 'no code'}) on $path: '
            '${_briefBody(resp.body)}');
      }

      // 400 / 404 / other 4xx — permanent client error, no retry.
      // (CLIENT_API §8: 400/401/403/404/409 → no retry.)
      if (code >= 400 && code < 500) {
        throw _BridgeException(
            'HTTP $code on $path: ${_briefBody(resp.body)}');
      }

      // 408 / 429 / 5xx — retryable. Honour Retry-After if the server
      // sent it (HTTP/1.1 standard header; the bridge doesn't currently
      // emit one but might in the future). Otherwise use our schedule.
      if (code == 408 || code == 429 || code >= 500) {
        final delay = _retryAfterDelay(resp) ?? _retryBackoff[attempt - 1];
        if (delay == null) {
          throw _RetryableException(code, _briefBody(resp.body));
        }
        debugPrint('CloudSync: HTTP $code on $path attempt $attempt, '
            'sleeping ${delay.inSeconds}s');
        await Future<void>.delayed(delay);
        continue;
      }

      // 1xx / 3xx / anything weird — shouldn't happen via the bridge,
      // but be defensive: don't loop, surface as a bridge error.
      throw _BridgeException(
          'Unexpected HTTP $code on $path: ${_briefBody(resp.body)}');
    }
  }

  /// Parse Retry-After header per RFC 7231 §7.1.3. Two formats:
  ///   - Integer seconds: "Retry-After: 5"
  ///   - HTTP date: "Retry-After: Wed, 21 Oct 2026 07:28:00 GMT"
  /// We only honour the seconds form — the date form is rare in
  /// modern APIs and the bridge spec doesn't promise it.
  Duration? _retryAfterDelay(http.Response resp) {
    final header = resp.headers['retry-after'];
    if (header == null) return null;
    final seconds = int.tryParse(header.trim());
    if (seconds == null || seconds < 0) return null;
    // Cap at 5 minutes — refusing to obey "sleep for an hour" is the
    // right move for a foreground app.
    final capped = seconds > 300 ? 300 : seconds;
    return Duration(seconds: capped);
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
    // v0.1.29+20: trips pendingCount = closed (endedAt != null) trips
    // not yet in _pushedTripIds. Open trips are intentionally not
    // counted as pending — they're not eligible for push yet.
    // snapshots/sweeps/livelogs are append-only and use the old
    // max(id) - cursor approximation.
    try {
      final allTrips = await _db.getAllTrips();
      final snapshots = await _db.getRecentSnapshots(limit: 1);
      final sweeps = await _db.getAllSweepRuns();
      final logs = await _db.getAllLiveLogSessions();
      final canMonitors = await _db.getAllCanMonitorSessions();
      final pendingTrips = allTrips
          .where((t) => t.endedAt != null && !_pushedTripIds.contains(t.id))
          .length;
      final maxSnap = snapshots.isEmpty ? 0 : snapshots.first.id;
      final maxSweep =
          sweeps.isEmpty ? 0 : sweeps.map((s) => s.id).reduce((a, b) => a > b ? a : b);
      final maxLog =
          logs.isEmpty ? 0 : logs.map((s) => s.id).reduce((a, b) => a > b ? a : b);
      // v0.1.29+29: same max-id approximation as livelog.
      final maxCanMon = canMonitors.isEmpty
          ? 0
          : canMonitors.map((s) => s.id).reduce((a, b) => a > b ? a : b);
      _stats = CloudSyncStats(
        pendingTrips: pendingTrips,
        pendingSnapshots: (maxSnap - _cursorSnapshot).clamp(0, 1 << 30),
        pendingSweeps: (maxSweep - _cursorSweep).clamp(0, 1 << 30),
        pendingLiveLogs: (maxLog - _cursorLiveLog).clamp(0, 1 << 30),
        pendingCanMonitors:
            (maxCanMon - _cursorCanMonitor).clamp(0, 1 << 30),
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
      // v0.1.29+37: derived aggregates (speed histogram). Stored locally
      // as a JSON string; the bridge column is jsonb, so decode to an
      // object here. Guard against a malformed local blob — on any parse
      // failure send null rather than a broken string.
      'extra': _decodeExtraOrNull(t.extra),
    };
  }

  /// v0.1.29+37: turn the locally-stored extra JSON string into an object
  /// for the jsonb column, or null if absent/malformed.
  dynamic _decodeExtraOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
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

  /// v0.1.29+29: serialize a CAN monitor session for the bridge.
  ///
  /// Schema per bridge-changes-for-drug1.md §"Ingest request shape":
  ///
  ///   {
  ///     client_session_id, started_at, ended_at, duration_sec,
  ///     car_state, notes, frame_count, unique_can_ids,
  ///     frames: [{sequence, ts_ms, can_id, payload_hex}, ...]
  ///   }
  ///
  /// `ts_ms` is **milliseconds since the session's started_at** (per
  /// the bridge example showing `ts_ms: 0` for the first frame), not
  /// a Unix epoch ms. We compute it client-side from the absolute
  /// DateTime stored in [CanFrame.tsMs]. This keeps the wire
  /// representation compact (BIGINT ~ low millions, not 13-digit
  /// epochs) and matches the bridge ingest expectation.
  ///
  /// `client_session_id` is the Drift row id, which was set explicitly
  /// at insert time from the SharedPreferences-backed monotonic
  /// counter (see ConnectionService._nextCanMonitorSessionId).
  Map<String, dynamic> _canMonitorToJson(
      CanMonitorSession s, List<CanFrame> frames, List<CanRawLine> rawLines) {
    final startMs = s.startedAt.millisecondsSinceEpoch;
    return {
      'client_session_id': s.id,
      'started_at': s.startedAt.toUtc().toIso8601String(),
      'ended_at': s.endedAt?.toUtc().toIso8601String(),
      'duration_sec': s.durationSec,
      'car_state': s.carState,
      'notes': s.notes,
      // v0.1.29+32: which CAN protocol this session used (AT SP arg).
      'protocol': s.protocol,
      'frame_count': s.frameCount,
      'unique_can_ids': s.uniqueCanIds,
      'frames': frames
          .map((f) => {
                'sequence': f.sequence,
                'ts_ms': f.tsMs.millisecondsSinceEpoch - startMs,
                'can_id': f.canId,
                'payload_hex': f.payloadHex,
              })
          .toList(),
      // v0.1.29+32: raw pre-parse line capture. Bridge may not have a
      // column for these yet — that's fine, an unknown field is ignored
      // by the ingest endpoint (additive contract). When the bridge
      // adds storage, this data is already flowing. `parsed=false` rows
      // are the interesting ones (formats the device parser rejected).
      'raw_lines': rawLines
          .map((r) => {
                'sequence': r.sequence,
                'ts_ms': r.tsMs.millisecondsSinceEpoch - startMs,
                'raw': r.rawLine,
                'parsed': r.parsed,
              })
          .toList(),
    };
  }

  /// Read app version from the static value baked into the build.
  /// We don't have package_info_plus as a dep — pubspec-version is
  /// hardcoded here. Update when bumping. Off-by-one tolerated.
  Future<String> _readAppVersion() async => '0.1.29+72';
}

// ─── Internal exceptions ────────────────────────────────────────────

class _BridgeException implements Exception {
  final String message;
  const _BridgeException(this.message);
  @override
  String toString() => message;
}

/// Permanent auth failure: 3+ consecutive 401s, OR a single 409
/// already_revoked. Causes the service to wipe the stored client_token,
/// mark the device as needing re-registration, and stop the periodic
/// timers. The user must start the setup flow again with a fresh
/// setup token from the owner.
class _AuthException implements Exception {
  const _AuthException();
  @override
  String toString() => 'Authentication failed';
}

/// v0.1.29+9: transient auth blip — a single 401 (or 1-2 consecutive).
/// CLIENT_API.md §1 explicitly tolerates this: "a sustained run of
/// 401s (e.g. 3 consecutive ingest 401s) is the signal" — so a one-off
/// shouldn't wipe the token. We treat this like any other transient
/// network error: log it, surface a non-fatal error to UI, retry on
/// the next periodic tick.
class _TransientAuthException implements Exception {
  final int consecutiveCount;
  const _TransientAuthException(this.consecutiveCount);
  @override
  String toString() =>
      'Auth blip (#$consecutiveCount of 3 — retrying next cycle)';
}

/// v0.1.29+9: server returned 408/429/5xx after the inner retry budget
/// was exhausted. The outer syncOnce should NOT mark the token bad,
/// just record the error and let the next periodic tick try again.
class _RetryableException implements Exception {
  final int statusCode;
  final String body;
  const _RetryableException(this.statusCode, this.body);
  @override
  String toString() => 'Retryable HTTP $statusCode: $body';
}
