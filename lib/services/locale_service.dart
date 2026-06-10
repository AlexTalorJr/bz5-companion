import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';

/// v0.1.29+58: app language selection.
/// v0.1.29+59: 'system' mode removed (owner decision) — the app is
/// English by default with an explicit switch to Russian. Two modes:
/// 'en' (default) | 'ru'. A 'system' value persisted by a +58 install
/// is simply no longer valid and falls back to the 'en' default.
///
/// Persistence: SharedPreferences key 'app_locale' ∈ {'en','ru'}.
///
/// Ordering contract (CRITICAL): `S.locale` is updated BEFORE
/// notifyListeners() in both load() and setMode(). Widgets rebuilt by
/// the notification call S.of() synchronously during build; if the
/// static were written after notify, the first frame after a switch
/// would render in the old language.
///
/// Rebuild model: MaterialApp's `home:` is a const widget, so a rebuild
/// at the MaterialApp level does NOT propagate into the const subtree
/// (Flutter skips identical const children). Localized screens must
/// therefore subscribe themselves via `context.watch<LocaleService>()`
/// in their build() — that re-runs exactly the screens that render
/// S.of() strings, without tearing down navigation or IndexedStack
/// state (a running sweep on the head unit survives a language switch).
class LocaleService extends ChangeNotifier {
  static const String prefsKey = 'app_locale';
  static const Set<String> validModes = {'ru', 'en'};

  String _mode = 'en';

  /// Selected language: 'en' (default) | 'ru'.
  String get mode => _mode;

  /// Load persisted mode. Called (and awaited) in main() before runApp
  /// so the very first frame already renders in the right language —
  /// no en→ru flash on a Russian-configured install.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(prefsKey);
    if (stored != null && validModes.contains(stored)) {
      _mode = stored;
    }
    S.locale = _mode; // BEFORE notify — see class doc.
    notifyListeners();
  }

  Future<void> setMode(String mode) async {
    if (!validModes.contains(mode) || mode == _mode) return;
    _mode = mode;
    S.locale = _mode; // BEFORE notify — see class doc.
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, mode);
  }
}
