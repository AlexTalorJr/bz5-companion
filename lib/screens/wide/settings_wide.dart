import 'package:flutter/material.dart';

import '../settings.dart';

/// v0.1.4: Settings screen for head unit.
///
/// Phone SettingsScreen works fine in wide mode — it's a simple ListView
/// with adapter management. On a 15.6" screen the rows stretch wider than
/// strictly necessary but stay readable; we don't constrain max width
/// because that would create an awkward "boxed app inside the head-unit
/// scaffold" look (Scaffold inside ConstrainedBox renders its own AppBar
/// at constrained width, leaving empty bands on either side).
///
/// Future enhancement: refactor SettingsScreen to take a maxContentWidth
/// parameter so we can constrain just the ListView, not the whole scaffold.
class SettingsWideScreen extends StatelessWidget {
  const SettingsWideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsScreen();
  }
}
