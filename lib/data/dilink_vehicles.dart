/// v0.1.35+134: catalog of vehicles known to ship DiLink 5.0-family
/// head units, for the self-service vehicle descriptor sent on
/// POST /v2/pair/start (contract addition, server head 0011).
///
/// Design notes:
///   * Presets exist for DATA QUALITY on the owner side — the vehicle
///     block is the main identity signal visible in the approval bot
///     (pairing is open for pending accounts, heartbeat is gated), so
///     a consistent nomenclature beats free-text zoo ("бз5", "тойота").
///   * The list is deliberately over-inclusive: it is a UI convenience,
///     not a gate — "Other" always allows free-form make/model, and the
///     server stores whatever the client sends verbatim.
///   * NO make is ever hardcoded into the request (server contract:
///     DiLink sits in Toyota bZ *and* BYD and others). The user always
///     sees and confirms the values before pairing.
library;

import 'dart:convert';

/// Preset makes, in display order. 'Other' is appended by the UI.
const List<String> kDiLinkMakes = ['Toyota', 'BYD', 'Denza'];

/// Preset models per make, display order. Toyota bZ family are the
/// FAW/GAC Toyota × BYD joint-venture cars this app is primarily
/// aimed at; BYD list covers DiLink 4/5-era e-Platform 3.0 models.
const Map<String, List<String>> kDiLinkModels = {
  'Toyota': [
    'bZ5',
    'bZ3',
    'bZ3X',
    'bZ4X',
    'bZ5X',
    'bZ7',
  ],
  'BYD': [
    'Seal',
    'Seal 05',
    'Seal 06',
    'Seal 07',
    'Han',
    'Tang',
    'Song Plus',
    'Song Pro',
    'Song L',
    'Qin Plus',
    'Qin L',
    'Yuan Plus (Atto 3)',
    'Yuan UP',
    'Dolphin',
    'Seagull',
    'Sea Lion 05',
    'Sea Lion 06',
    'Sea Lion 07',
    'e2',
  ],
  'Denza': [
    'D9',
    'N7',
    'N8',
    'Z9',
  ],
};

/// Best-effort make prefill from a VIN's WMI (first 3 chars).
/// Only mappings we are CONFIDENT about — everything else returns null
/// and the user picks manually. Never used silently: the picker shows
/// the prefilled chip selected, user confirms or changes it.
///   LFM — FAW Toyota (ground truth: the developer's own bZ5 VIN)
///   LGX / LC0 — BYD Auto / BYD Auto Industry
String? makeFromVin(String? vin) {
  if (vin == null || vin.length < 3) return null;
  switch (vin.substring(0, 3).toUpperCase()) {
    case 'LFM':
      return 'Toyota';
    case 'LGX':
    case 'LC0':
      return 'BYD';
    default:
      return null;
  }
}

/// v0.1.36+135: parsed + validated server catalog (S8,
/// GET /v2/meta/vehicle-catalog). Returns null on ANY violation —
/// the caller falls back to the built-in seed silently. Limits mirror
/// the server SPEC §2: body ≤ 32 KB, 1..20 makes, 1..60 models per
/// make, every string 1..80 chars, no duplicate makes or models,
/// version int > 0. The catalog is a UI hint only: pair/start and the
/// "Other" free-form path never depend on it.
class VehicleCatalog {
  final int version;

  /// Display order preserved exactly as the server sent it.
  final List<String> makes;
  final Map<String, List<String>> models;

  const VehicleCatalog(this.version, this.makes, this.models);

  /// Strict parse of the raw response body. Null on any violation;
  /// never throws. The size check runs BEFORE jsonDecode so an
  /// oversized body is rejected without paying the decode cost.
  static VehicleCatalog? tryParse(String body) {
    if (body.length > 32 * 1024) return null;
    Object? root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (root is! Map<String, dynamic>) return null;
    final version = root['version'];
    if (version is! int || version <= 0) return null;
    final rawMakes = root['makes'];
    if (rawMakes is! List || rawMakes.isEmpty || rawMakes.length > 20) {
      return null;
    }
    final makes = <String>[];
    final models = <String, List<String>>{};
    for (final entry in rawMakes) {
      if (entry is! Map<String, dynamic>) return null;
      final make = entry['make'];
      if (make is! String || make.isEmpty || make.length > 80) return null;
      if (models.containsKey(make)) return null; // duplicate make
      final rawModels = entry['models'];
      if (rawModels is! List || rawModels.isEmpty || rawModels.length > 60) {
        return null;
      }
      final list = <String>[];
      for (final m in rawModels) {
        if (m is! String || m.isEmpty || m.length > 80) return null;
        if (list.contains(m)) return null; // duplicate model within make
        list.add(m);
      }
      makes.add(make);
      models[make] = List.unmodifiable(list);
    }
    return VehicleCatalog(
        version, List.unmodifiable(makes), Map.unmodifiable(models));
  }
}
