/// v0.1.29+124 (C2 + C6): account layer — email OTP auth per
/// CLIENT_API.md §1.1 + device management §1.3.
///
/// The *account* (phone-side) credential is fully separate from the
/// device token: device tokens keep authorizing all ingest/diag traffic
/// (CloudSyncService / BridgeDiagService untouched); the account JWT
/// authorizes only `/v2/*` account endpoints. Per the §0/§10 project
/// rule this is an independent singleton: own flag-free lifecycle, own
/// error state, own backoff — shares nothing with the other services.
///
/// Token model (§1.1):
///   * access JWT — 15 min, **memory only**, sent as Bearer on account
///     endpoints. Never persisted, never used for ingest.
///   * refresh token — opaque, single-use rotating, persisted in
///     flutter_secure_storage. Every refresh returns a brand-new pair;
///     the presented token is dead the moment the server answers.
///
/// Rotation discipline (the part that bites if done sloppily):
///   1. The NEW refresh token is written to secure storage BEFORE the
///      new access token is exposed to callers — a crash between the
///      two leaves us with a valid persisted refresh, never a dead one.
///   2. A refresh POST is never retried with the same value after a
///      2xx/4xx was received. Network-level failures (nothing received)
///      are safe to retry — the server hasn't rotated.
///   3. `401 refresh_reused` = the server saw a replay and revoked the
///      whole session (theft heuristic). Wipe both tokens, sign out,
///      surface "log in again". `invalid_refresh` — same wipe, softer
///      wording.
///
/// C6 (graceful 401, account plane): [authorizedGetJson] /
/// [authorizedPostJson] attach a valid access token (refreshing
/// proactively when < 2 min of life remain), and on a 401 response run
/// exactly ONE refresh + ONE retry; a second 401 signs out locally
/// instead of looping.
///
/// Anti-enumeration (§1.1): `POST /v2/auth/otp/request` returns 200
/// whether or not the address is permitted — the UI copy must stay
/// neutral ("if the address is allowed, a code was sent") and point at
/// the spam folder. Only the freshest code is alive, so the resend
/// button carries a cooldown ([resendCooldown]) and a "new code voids
/// the old one" note.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum AccountAuthStatus {
  /// No session. Also the landing state after any forced sign-out.
  signedOut,

  /// OTP requested; waiting for the user to type the emailed code.
  codeSent,

  /// Refresh token on file — account calls available.
  signedIn,

  /// Server answered 503 auth_not_configured — accounts don't exist
  /// on this bridge yet (OWNER_EMAIL / JWT_SECRET unset).
  authNotConfigured,
}

/// One row of GET /v2/devices (§1.3).
class AccountDevice {
  final String id;
  final String? vehicleId;
  final String? kind;
  final String? displayName;
  final String? lastClientVersion;
  final DateTime? lastHeartbeatAt;
  final DateTime? revokedAt;

  const AccountDevice({
    required this.id,
    this.vehicleId,
    this.kind,
    this.displayName,
    this.lastClientVersion,
    this.lastHeartbeatAt,
    this.revokedAt,
  });

  static AccountDevice fromJson(Map<String, dynamic> j) {
    DateTime? dt(dynamic v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    return AccountDevice(
      id: '${j['id']}',
      vehicleId: j['vehicle_id'] as String?,
      kind: j['kind'] as String?,
      displayName: j['display_name'] as String?,
      lastClientVersion: j['last_client_version'] as String?,
      lastHeartbeatAt: dt(j['last_heartbeat_at']),
      revokedAt: dt(j['revoked_at']),
    );
  }
}

class AccountAuthService extends ChangeNotifier {
  static const _defaultBaseUrl = 'https://carbridge.neardo.work';

  /// Same prefs key CloudSyncService uses for its base URL — read-only
  /// convenience so a custom bridge host applies to both planes. No
  /// other state is shared (§0/§10 rule).
  static const _kBaseUrlPref = 'cloud_sync_base_url';

  static const _kRefreshKey = 'account_refresh_token';
  static const _kEmailPref = 'account_email';

  /// §1.1: only the freshest OTP code is alive — a resend voids the
  /// previous one. Cooldown keeps users from racing themselves.
  static const Duration resendCooldown = Duration(seconds: 60);

  /// Client-side lock after a 429 rate_limited (5/hour per email).
  static const Duration rateLimitLock = Duration(seconds: 120);

  /// Refresh proactively when less than this much access life remains.
  static const Duration _refreshMargin = Duration(minutes: 2);

  final http.Client _http = http.Client();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  String _baseUrl = _defaultBaseUrl;
  AccountAuthStatus _status = AccountAuthStatus.signedOut;
  String? _email;
  String? _accessToken; // memory only — never persisted
  DateTime? _accessExpiresAt;
  String? _lastErrorCode; // server error code or 'network'
  bool _busy = false;
  bool _initialized = false;
  DateTime? _resendAvailableAt;
  DateTime? _lockedUntil; // 429 lockout
  Future<bool>? _refreshInFlight; // single-flight guard

  List<AccountDevice> _devices = const [];
  bool _devicesLoading = false;
  String? _devicesError;

  // ── public getters ──
  AccountAuthStatus get status => _status;
  String? get email => _email;
  String? get lastErrorCode => _lastErrorCode;
  bool get busy => _busy;
  bool get isInitialized => _initialized;
  bool get isSignedIn => _status == AccountAuthStatus.signedIn;
  DateTime? get accessExpiresAt => _accessExpiresAt;
  List<AccountDevice> get devices => _devices;
  bool get devicesLoading => _devicesLoading;
  String? get devicesError => _devicesError;

  int get resendSecondsLeft => _secondsLeft(_resendAvailableAt);
  int get lockSecondsLeft => _secondsLeft(_lockedUntil);

  int _secondsLeft(DateTime? t) {
    if (t == null) return 0;
    final d = t.difference(DateTime.now()).inSeconds;
    return d > 0 ? d : 0;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_kBaseUrlPref) ?? _defaultBaseUrl;
    _email = prefs.getString(_kEmailPref);
    String? refresh;
    try {
      refresh = await _secureStorage.read(key: _kRefreshKey);
    } catch (e) {
      debugPrint('AccountAuth: secure read failed: $e');
    }
    if (refresh != null && refresh.isNotEmpty) {
      // Session on file. Access token is minted lazily on the first
      // account call (or proactively by the screen) — no network here.
      _status = AccountAuthStatus.signedIn;
    }
    _initialized = true;
    debugPrint('AccountAuth: init — status=${_status.name}'
        '${_email != null ? ' email=$_email' : ''}');
    notifyListeners();
  }

  // ─── OTP flow ─────────────────────────────────────────────────────

  Future<void> requestOtp(String email) async {
    if (_busy || lockSecondsLeft > 0) return;
    final trimmed = email.trim();
    if (trimmed.isEmpty || !trimmed.contains('@')) {
      _lastErrorCode = 'bad_email';
      notifyListeners();
      return;
    }
    _busy = true;
    _lastErrorCode = null;
    notifyListeners();
    try {
      final resp = await _http
          .post(Uri.parse('$_baseUrl/v2/auth/otp/request'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': trimmed}))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        // 200 is deliberately uninformative (anti-enumeration): it does
        // NOT mean a mail was sent — only that the request was accepted.
        _email = trimmed;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kEmailPref, trimmed);
        _status = AccountAuthStatus.codeSent;
        _resendAvailableAt = DateTime.now().add(resendCooldown);
        debugPrint('AccountAuth: otp requested (neutral 200)');
      } else {
        _applyErrorResponse(resp, context: 'otp/request');
      }
    } catch (e) {
      _lastErrorCode = 'network';
      debugPrint('AccountAuth: otp/request network error: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> verifyOtp(String code) async {
    if (_busy || _email == null) return;
    _busy = true;
    _lastErrorCode = null;
    notifyListeners();
    try {
      final resp = await _http
          .post(Uri.parse('$_baseUrl/v2/auth/otp/verify'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': _email, 'code': code.trim()}))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        await _adoptTokenPair(j);
        _status = AccountAuthStatus.signedIn;
        debugPrint('AccountAuth: signed in as $_email');
      } else {
        _applyErrorResponse(resp, context: 'otp/verify');
      }
    } catch (e) {
      _lastErrorCode = 'network';
      debugPrint('AccountAuth: otp/verify network error: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Back from the code step to the email step (user mistyped address).
  void restartEmailStep() {
    if (_status == AccountAuthStatus.codeSent) {
      _status = AccountAuthStatus.signedOut;
      _lastErrorCode = null;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    // Best effort server-side revoke; local wipe happens regardless.
    try {
      final access = await _validAccessToken(allowNull: true);
      if (access != null) {
        await _http.post(Uri.parse('$_baseUrl/v2/auth/logout'), headers: {
          'Authorization': 'Bearer $access',
        }).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('AccountAuth: logout best-effort failed: $e');
    }
    await _wipeSession(reason: 'logout');
  }

  // ─── refresh rotation ─────────────────────────────────────────────

  /// Single-flight refresh. Returns true when a fresh access token is
  /// in memory afterwards.
  Future<bool> _refresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final f = _refreshInner().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = f;
    return f;
  }

  Future<bool> _refreshInner() async {
    String? stored;
    try {
      stored = await _secureStorage.read(key: _kRefreshKey);
    } catch (e) {
      debugPrint('AccountAuth: secure read failed: $e');
      return false;
    }
    if (stored == null || stored.isEmpty) return false;
    http.Response resp;
    try {
      resp = await _http
          .post(Uri.parse('$_baseUrl/v2/auth/refresh'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': stored}))
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      // Nothing was received — the server did not rotate. Retrying the
      // SAME stored value later is safe (and is the only retry that is).
      debugPrint('AccountAuth: refresh network error (safe to retry): $e');
      return false;
    }
    if (resp.statusCode == 200) {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      await _adoptTokenPair(j);
      debugPrint('AccountAuth: refresh rotated ok '
          '(access expires ${_accessExpiresAt?.toIso8601String()})');
      notifyListeners();
      return true;
    }
    final code = _errorCode(resp);
    if (resp.statusCode == 401) {
      // refresh_reused → server revoked the whole session (replay =
      // theft heuristic). invalid_refresh → unknown/expired/revoked.
      // Either way this refresh token is dead — NEVER retried.
      debugPrint('AccountAuth: refresh rejected ($code) — signing out');
      await _wipeSession(
          reason: code == 'refresh_reused' ? 'refresh_reused' : 'session');
      return false;
    }
    debugPrint('AccountAuth: refresh failed HTTP ${resp.statusCode} ($code)');
    return false;
  }

  /// Persist order matters: the NEW refresh token hits secure storage
  /// FIRST; only then is the new access token exposed in memory. A
  /// crash in between leaves a valid persisted refresh — never a
  /// rotated-away one.
  Future<void> _adoptTokenPair(Map<String, dynamic> j) async {
    final refresh = j['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      await _secureStorage.write(key: _kRefreshKey, value: refresh);
    }
    final access = j['access_token'];
    final expiresIn = j['expires_in'];
    _accessToken = access is String ? access : null;
    _accessExpiresAt = DateTime.now()
        .add(Duration(seconds: expiresIn is int ? expiresIn : 900));
  }

  Future<String?> _validAccessToken({bool allowNull = false}) async {
    if (_status != AccountAuthStatus.signedIn) return null;
    final exp = _accessExpiresAt;
    final fresh = _accessToken != null &&
        exp != null &&
        exp.difference(DateTime.now()) > _refreshMargin;
    if (fresh) return _accessToken;
    final ok = await _refresh();
    if (ok) return _accessToken;
    return allowNull ? _accessToken : null;
  }

  Future<void> _wipeSession({required String reason}) async {
    try {
      await _secureStorage.delete(key: _kRefreshKey);
    } catch (e) {
      debugPrint('AccountAuth: secure delete failed: $e');
    }
    _accessToken = null;
    _accessExpiresAt = null;
    _devices = const [];
    _devicesError = null;
    _status = AccountAuthStatus.signedOut;
    _lastErrorCode = reason == 'logout' ? null : reason;
    debugPrint('AccountAuth: session wiped ($reason)');
    notifyListeners();
  }

  // ─── C6: authorized calls — one refresh + one retry on 401 ────────

  Future<http.Response?> _authorizedSend(
      Future<http.Response> Function(String access) send) async {
    var access = await _validAccessToken();
    if (access == null) return null;
    var resp = await send(access);
    if (resp.statusCode != 401) return resp;
    // Exactly one recovery attempt: refresh, retry, and if the server
    // still says 401 — sign out locally instead of looping.
    final ok = await _refresh();
    if (!ok) return resp; // _refresh already wiped on 401
    access = _accessToken;
    if (access == null) return resp;
    resp = await send(access);
    if (resp.statusCode == 401) {
      await _wipeSession(reason: 'session');
    }
    return resp;
  }

  // ─── §1.2 pairing claim (phone side) ──────────────────────────────

  /// v0.1.29+127 (C3): approve a device's pairing request by typing the
  /// short user_code it displays. Returns null on success, an error
  /// code otherwise ('pairing_invalid', 'no_vehicle', 'session',
  /// 'network', 'bad_code'). vehicle_id is omitted — a single-vehicle
  /// account defaults to it server-side.
  Future<String?> claimPairing(String userCode) async {
    final code = userCode.trim().toUpperCase();
    if (code.isEmpty) return 'bad_code';
    try {
      final resp = await _authorizedSend((access) => _http
          .post(Uri.parse('$_baseUrl/v2/pair/claim'),
              headers: {
                'Authorization': 'Bearer $access',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'user_code': code}))
          .timeout(const Duration(seconds: 15)));
      if (resp == null) return 'session';
      if (resp.statusCode == 200) {
        debugPrint('AccountAuth: pairing claimed');
        unawaited(fetchDevices());
        return null;
      }
      return _errorCode(resp);
    } catch (e) {
      debugPrint('AccountAuth: pair/claim failed: $e');
      return 'network';
    }
  }

  // ─── §1.3 devices ─────────────────────────────────────────────────

  Future<void> fetchDevices() async {
    if (_devicesLoading || !isSignedIn) return;
    _devicesLoading = true;
    _devicesError = null;
    notifyListeners();
    try {
      final resp = await _authorizedSend((access) => _http.get(
          Uri.parse('$_baseUrl/v2/devices'),
          headers: {
            'Authorization': 'Bearer $access'
          }).timeout(const Duration(seconds: 15)));
      if (resp == null) {
        _devicesError = 'session';
      } else if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body);
        _devices = (j is List)
            ? j
                .whereType<Map<String, dynamic>>()
                .map(AccountDevice.fromJson)
                .toList()
            : const [];
        debugPrint('AccountAuth: devices fetched (${_devices.length})');
      } else {
        _devicesError = _errorCode(resp);
      }
    } catch (e) {
      _devicesError = 'network';
      debugPrint('AccountAuth: devices fetch failed: $e');
    } finally {
      _devicesLoading = false;
      notifyListeners();
    }
  }

  /// §1.3: revoke marks the device token revoked; the device then 401s
  /// and (per C6, device plane) keeps its LOCAL data — revoke is about
  /// access, not history.
  Future<bool> revokeDevice(String id) async {
    try {
      final resp = await _authorizedSend((access) => _http.post(
          Uri.parse('$_baseUrl/v2/devices/$id/revoke'),
          headers: {
            'Authorization': 'Bearer $access'
          }).timeout(const Duration(seconds: 15)));
      if (resp != null && resp.statusCode == 200) {
        debugPrint('AccountAuth: device $id revoked');
        await fetchDevices();
        return true;
      }
      _devicesError = resp == null ? 'session' : _errorCode(resp);
    } catch (e) {
      _devicesError = 'network';
      debugPrint('AccountAuth: revoke failed: $e');
    }
    notifyListeners();
    return false;
  }

  // ─── error plumbing ───────────────────────────────────────────────

  void _applyErrorResponse(http.Response resp, {required String context}) {
    final code = _errorCode(resp);
    switch (resp.statusCode) {
      case 429:
        _lastErrorCode = 'rate_limited';
        _lockedUntil = DateTime.now().add(rateLimitLock);
      case 503:
        _lastErrorCode = 'auth_not_configured';
        _status = AccountAuthStatus.authNotConfigured;
      default:
        _lastErrorCode = code;
    }
    debugPrint(
        'AccountAuth: $context HTTP ${resp.statusCode} code=$_lastErrorCode');
  }

  /// §8: error body is `{"error":{code,…}}`, possibly wrapped one level
  /// as `{"detail":{"error":{…}}}` by FastAPI — unwrap both shapes.
  String _errorCode(http.Response resp) {
    try {
      dynamic j = jsonDecode(resp.body);
      if (j is Map<String, dynamic> && j['detail'] != null) j = j['detail'];
      if (j is Map<String, dynamic> && j['error'] is Map<String, dynamic>) {
        final c = (j['error'] as Map<String, dynamic>)['code'];
        if (c is String && c.isNotEmpty) return c;
      }
    } catch (_) {}
    return 'http_${resp.statusCode}';
  }

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}
