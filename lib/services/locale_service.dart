import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/strings.dart';

/// v0.1.29+58: app language selection — System / Русский / English.
///
/// Persistence: SharedPreferences key 'app_locale' with values
/// 'system' | 'ru' | 'en'. Missing or unknown stored value → 'system'.
///
/// Resolution ('system' → concrete language):
///   PlatformDispatcher.instance.locale.languageCode == 'ru' → 'ru'
///   anything else (en, zh, de, …)                          → 'en'
/// The head unit's system locale is Chinese (zh-CN), so 'system'
/// resolves to English there — this is the agreed fallback design.
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
  static const Set<String> validModes = {'system', 'ru', 'en'};

  String _mode = 'system';

  /// Selected mode: 'system' | 'ru' | 'en'.
  String get mode => _mode;

  /// Resolved language for the current mode: 'ru' | 'en'.
  String get resolved => resolve(_mode);

  /// Pure resolution function (also exercised by the Python logic-port
  /// in tools/regress_plus35.py Part V — keep it trivial).
  static String resolve(String mode) {
    if (mode == 'ru' || mode == 'en') return mode;
    final lang =
        PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    return lang == 'ru' ? 'ru' : 'en';
  }

  /// Load persisted mode. Called (and awaited) in main() before runApp
  /// so the very first frame already renders in the right language —
  /// no en→ru flash on a Russian-configured install.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(prefsKey);
    if (stored != null && validModes.contains(stored)) {
      _mode = stored;
    }
    S.locale = resolve(_mode); // BEFORE notify — see class doc.
    notifyListeners();
  }

  Future<void> setMode(String mode) async {
    if (!validModes.contains(mode) || mode == _mode) return;
    _mode = mode;
    S.locale = resolve(_mode); // BEFORE notify — see class doc.
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, mode);
  }
}
