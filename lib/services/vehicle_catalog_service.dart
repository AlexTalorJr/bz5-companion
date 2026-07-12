/// v0.1.36+135: server vehicle catalog — background fetch, prefs cache
/// with a version gate, silent fallback to the built-in seed.
///
/// Deliberately a SEPARATE lightweight ChangeNotifier and NOT a
/// CloudSyncService member (that class is 2800+ lines and owns a
/// different plane: authenticated device sync). The catalog endpoint
/// is public (`GET /v2/meta/vehicle-catalog`, no auth, outside
/// APPROVAL_GATE), read-only, and purely a UI convenience — pair/start
/// and the "Other" free-form path never depend on it.
///
/// Failure philosophy (server SPEC §2): ANY violation — non-200,
/// timeout, malformed JSON, limit breach — is a single debugPrint line
/// (which lands in the AppDiagLog ring buffer for on-device reading)
/// and a silent stay on the previous state. The UI never sees an
/// error, never blocks, never shows a spinner for this.
///
/// Version gate: a response with version ≤ the cached one refreshes
/// only `fetched_at` (so the 24-hour gate keeps protecting the server
/// from re-fetch storms) without rewriting the body; only a strictly
/// greater version replaces the cache and notifies listeners.
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/dilink_vehicles.dart';

class VehicleCatalogService extends ChangeNotifier {
  VehicleCatalogService({required String Function() baseUrl})
      : _baseUrl = baseUrl;

  /// Reads CloudSyncService.baseUrl at call time — a callback, never an
  /// import-level dependency, so a custom base URL from settings is
  /// respected without coupling the two services' lifecycles.
  final String Function() _baseUrl;

  static const _kJson = 'vehicle_catalog_json';
  static const _kVersion = 'vehicle_catalog_version';
  static const _kFetchedAt = 'vehicle_catalog_fetched_at'; // ms epoch

  static const _staleAfter = Duration(hours: 24);
  static const _fetchTimeout = Duration(seconds: 5);

  VehicleCatalog? _catalog;
  int _cachedVersion = 0;
  DateTime? _fetchedAt;
  bool _fetchInFlight = false;

  /// Parsed server catalog, or null when running on the built-in seed.
  VehicleCatalog? get catalog => _catalog;

  /// Diag observability (app_diag `_cloudCard`): cached version and
  /// fetch time; 0 / null while on seed.
  int get cachedVersion => _cachedVersion;
  DateTime? get fetchedAt => _fetchedAt;

  /// UI-facing list of makes. The picker never learns the source.
  List<String> get makes => _catalog?.makes ?? kDiLinkMakes;

  /// UI-facing models for [make]; empty list for an unknown make.
  List<String> modelsFor(String make) => _catalog != null
      ? (_catalog!.models[make] ?? const [])
      : (kDiLinkModels[make] ?? const []);

  /// Load the prefs cache. A malformed cache (e.g. written by a newer
  /// build with different limits) is deleted and we stay on the seed —
  /// same silent-fallback rule as the network path.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final body = prefs.getString(_kJson);
      final version = prefs.getInt(_kVersion);
      final fetchedMs = prefs.getInt(_kFetchedAt);
      if (body == null || version == null) return;
      final parsed = VehicleCatalog.tryParse(body);
      if (parsed == null || parsed.version != version) {
        await prefs.remove(_kJson);
        await prefs.remove(_kVersion);
        await prefs.remove(_kFetchedAt);
        debugPrint('VehicleCatalog: malformed cache dropped, using seed');
        return;
      }
      _catalog = parsed;
      _cachedVersion = version;
      _fetchedAt = fetchedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(fetchedMs);
      notifyListeners();
    } catch (e) {
      debugPrint('VehicleCatalog: cache load failed ($e), using seed');
    }
  }

  /// Background refresh with a 24-hour gate. Fire-and-forget from the
  /// picker's initState (covers both the pairing screen and the
  /// "My vehicle" dialog — same widget). Never throws, never blocks,
  /// never surfaces an error to the UI.
  Future<void> refreshIfStale() async {
    if (_fetchInFlight) return;
    _fetchInFlight = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_kFetchedAt);
      if (lastMs != null) {
        final age = DateTime.now()
            .difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
        if (age < _staleAfter) return; // fresh enough — no network
      }
      http.Response resp;
      try {
        resp = await http
            .get(Uri.parse('${_baseUrl()}/v2/meta/vehicle-catalog'))
            .timeout(_fetchTimeout);
      } catch (e) {
        debugPrint('VehicleCatalog: fetch failed ($e), staying on '
            '${_catalog == null ? 'seed' : 'v$_cachedVersion'}');
        return;
      }
      if (resp.statusCode != 200) {
        debugPrint('VehicleCatalog: HTTP ${resp.statusCode}, staying on '
            '${_catalog == null ? 'seed' : 'v$_cachedVersion'}');
        return;
      }
      final body = resp.body;
      final parsed = VehicleCatalog.tryParse(body);
      if (parsed == null) {
        debugPrint('VehicleCatalog: malformed/over-limit response, '
            'staying on ${_catalog == null ? 'seed' : 'v$_cachedVersion'}');
        return;
      }
      final now = DateTime.now();
      if (parsed.version <= _cachedVersion) {
        // Same or older catalog — refresh the timestamp only, so the
        // 24-hour gate keeps holding, but never rewrite the body.
        await prefs.setInt(_kFetchedAt, now.millisecondsSinceEpoch);
        _fetchedAt = now;
        debugPrint('VehicleCatalog: fetch → version=${parsed.version} '
            '≤ cached v$_cachedVersion, timestamp refreshed');
        return;
      }
      await prefs.setString(_kJson, body);
      await prefs.setInt(_kVersion, parsed.version);
      await prefs.setInt(_kFetchedAt, now.millisecondsSinceEpoch);
      _catalog = parsed;
      _cachedVersion = parsed.version;
      _fetchedAt = now;
      debugPrint('VehicleCatalog: fetch → version=${parsed.version}, '
          '${parsed.makes.length} makes, cache written');
      notifyListeners();
    } catch (e) {
      // Belt-and-braces: nothing in here may ever reach the UI.
      debugPrint('VehicleCatalog: refresh error ($e)');
    } finally {
      _fetchInFlight = false;
    }
  }
}
