/// v0.1.27: per-trip cost settings.
///
/// Lightweight ChangeNotifier kept separate from ConnectionService
/// (3519-LOC god-object that CLAUDE.md says not to touch) and from
/// SettingsScreen state (which is local to that widget and not
/// observable from anywhere else).
///
/// Two persisted values:
///   * cost_per_kwh    — number (in user's currency units)
///   * currency_symbol — short string shown next to amounts ('$', '₽',
///                       '€', '¥', or any custom string up to 4 chars)
///
/// Default: cost_per_kwh = 0 (treated as "not configured" → all cost
/// UI is hidden so users who don't care never see the feature).
/// Default currency symbol: '$' (most universally recognisable).
///
/// Why not stash this in SharedPreferences and re-read on every build
/// from the UI:
///   1. Driver view re-reads currentTripId / svc fields on every
///      ConnectionService notify (poll cycle, 1Hz+). Re-reading prefs
///      that often is wasteful.
///   2. When the user edits cost in Settings and switches back to
///      Driver, we want the change to appear immediately, not after
///      next tab rebuild. Provider + notifyListeners handles that
///      cleanly: write triggers rebuild in every watcher.
///
/// Why not in ConnectionService:
///   * Per CLAUDE.md, ConnectionService stays untouched. Adding
///     fields/persistence/notify hooks there for an unrelated user
///     setting risks regressing the BLE flow.
///
/// The Trip class in the database is NOT changed — historic cost per
/// kWh is not snapshotted with each trip. After the user edits the
/// tariff, *all* historical trips re-compute cost at the new rate.
/// For a single-owner app that's a non-issue. If multi-tariff history
/// becomes a real need, that's a separate patch with a DB migration.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CostSettings extends ChangeNotifier {
  static const String _kCostPerKwh = 'cost_per_kwh';
  static const String _kCurrencySymbol = 'currency_symbol';

  double _costPerKwh = 0.0;
  String _currencySymbol = '\$';
  bool _loaded = false;

  /// Cost of 1 kWh in the user's currency. 0 = not configured (UI
  /// hides cost displays when this is 0 or null).
  double get costPerKwh => _costPerKwh;

  /// Short string prepended/appended to monetary amounts.
  String get currencySymbol => _currencySymbol;

  /// True once load() has completed at least once. UI can use this to
  /// distinguish "still loading from prefs" from "loaded and value is 0".
  bool get isLoaded => _loaded;

  /// True iff a non-zero cost is configured. Convenience for "should
  /// I render the cost cell at all" checks.
  bool get isConfigured => _costPerKwh > 0;

  /// Load both fields from SharedPreferences. Call once from the
  /// provider's create: callback in main.dart. Safe to call again —
  /// it will just refresh from disk.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _costPerKwh = prefs.getDouble(_kCostPerKwh) ?? 0.0;
    _currencySymbol = prefs.getString(_kCurrencySymbol) ?? '\$';
    _loaded = true;
    notifyListeners();
  }

  /// Update cost per kWh and persist. Clamps to non-negative.
  Future<void> setCostPerKwh(double v) async {
    final clamped = v < 0 ? 0.0 : v;
    if (_costPerKwh == clamped) return;
    _costPerKwh = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kCostPerKwh, clamped);
    notifyListeners();
  }

  /// Update currency symbol and persist. Empty → falls back to '$'.
  /// Truncates to 4 chars (enough for "USD" / "EUR" plus a space).
  Future<void> setCurrencySymbol(String s) async {
    final trimmed = s.trim();
    final normalized = trimmed.isEmpty
        ? '\$'
        : (trimmed.length <= 4 ? trimmed : trimmed.substring(0, 4));
    if (_currencySymbol == normalized) return;
    _currencySymbol = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrencySymbol, normalized);
    notifyListeners();
  }

  /// Format a monetary amount using the current symbol.
  ///
  /// Placement heuristic: symbols common in pre-amount position
  /// ($, €, £, ¥) go before the number with no space. Currency codes
  /// (USD, EUR, RUB) and symbols traditionally trailing (₽, ₸, kr)
  /// go after with a space. Tweak if needed — kept here so the
  /// formatting is consistent across all three UIs that display
  /// cost (Driver wide, trip_detail, future history aggregates).
  String formatAmount(double value) {
    final s = value < 10 ? value.toStringAsFixed(2) : value.toStringAsFixed(1);
    const leading = {'\$', '€', '£', '¥'};
    if (leading.contains(_currencySymbol)) {
      return '$_currencySymbol$s';
    }
    return '$s $_currencySymbol';
  }
}
