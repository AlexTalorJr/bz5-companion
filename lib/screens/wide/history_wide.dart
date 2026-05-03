import 'package:flutter/material.dart';

import '../history.dart';

/// v0.1.4: Trip history screen for head unit.
///
/// Per product decision: leave existing HistoryScreen as-is for now.
/// When trip charts and statistics are added, this file will get a
/// dedicated wide layout (probably split-pane: list of trips on the
/// left, selected trip's chart/stats on the right).
///
/// For now we just embed the phone HistoryScreen — it works fine on
/// the wide screen, just looks under-utilized.
class HistoryWideScreen extends StatelessWidget {
  const HistoryWideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const HistoryScreen();
  }
}
