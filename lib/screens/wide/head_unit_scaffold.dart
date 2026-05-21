import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';
import '../../services/native_detector.dart';
import 'dashboard_wide.dart';
import 'raw_data_wide.dart';
import 'history_wide.dart';
import 'settings_wide.dart';
import 'native_explorer_wide.dart';

/// v0.1.4: Top-level scaffold for head unit / tablet (≥840 dp wide).
///
/// 5 destinations on a left NavigationRail:
///   - Dashboard — single-page realtime view, all critical stats visible
///   - Raw Data — ECU explorer with live DID table + diagnostics sweep
///   - History — trip log
///   - Settings — adapter / connection management
///   - Native API — head-unit native HAL probe (v0.1.27)
///
/// IndexedStack preserves screen state across switches (so a sweep
/// running on Raw Data doesn't get cancelled if the user briefly
/// switches to Dashboard).
///
/// v0.1.13: top inset handling changed from hardcoded Padding(top: 48) to
/// SafeArea. Earlier we observed Toyota BZ5 launcher overlay covering
/// app content at the top — but after a Toyota system update the overlay
/// behaviour changed (status icons now render onto the app's own canvas
/// rather than on a translucent strip above it). The fixed 48dp padding
/// then became visible empty grey space.
///
/// SafeArea reads MediaQuery.padding.top, which the Android system fills
/// with the real status-bar inset. When the launcher doesn't overlay
/// anything (the new behaviour) the inset is small (~24dp) and our content
/// touches the top edge cleanly. When the overlay returns, the inset
/// auto-expands.
///
/// v0.1.27: added Native API destination. Required moving `_screens` from
/// `static const` to instance state because `NativeExplorerWide` needs a
/// shared `NativeDetector` injected via constructor. The detector is
/// created in initState() and probes the BYD framework class once on
/// startup; on phones (where the class is absent) it stays in
/// `isOnHeadUnit=false` and the screen renders a friendly "BLE mode
/// only" notice. No behavioural change for the first 4 destinations.
class HeadUnitScaffold extends StatefulWidget {
  const HeadUnitScaffold({super.key});

  @override
  State<HeadUnitScaffold> createState() => _HeadUnitScaffoldState();
}

class _HeadUnitScaffoldState extends State<HeadUnitScaffold> {
  int _index = 0;

  // v0.1.27: instance-level (was `static const` in v0.1.4..v0.1.26).
  // NativeExplorerWide needs `NativeDetector` constructor-injected, which
  // can't live in a const list. The other 4 screens remain const.
  late final NativeDetector _nativeDetector;
  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _nativeDetector = NativeDetector();
    // Fire-and-forget probe — the ChangeNotifier wakes up the explorer
    // screen when the answer is back. Detection is cheap (one
    // Class.forName + optional VIN reflection); we don't await here so
    // the first frame paints immediately even if the platform side is
    // slow.
    _nativeDetector.detect();
    _screens = [
      const DashboardWideScreen(),
      const RawDataWideScreen(),
      const HistoryWideScreen(),
      const SettingsWideScreen(),
      NativeExplorerWide(detector: _nativeDetector),
    ];
  }

  @override
  void dispose() {
    _nativeDetector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      body: SafeArea(
        // SafeArea reads MediaQuery.padding from the system (Toyota launcher
        // reports its own top inset on the head unit). The `minimum` ensures
        // a small breathing room even when the system reports zero — useful
        // for phones in landscape and edge cases where the launcher under-
        // reports the status bar height.
        minimum: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              minWidth: 80,
              useIndicator: true,
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: Text('Dashboard'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.table_rows_outlined),
                  selectedIcon: Icon(Icons.table_rows),
                  label: Text('Raw Data'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.timeline_outlined),
                  selectedIcon: Icon(Icons.timeline),
                  label: Text('History'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: svc.status != ConnectionStatus.connected,
                    backgroundColor: Colors.red,
                    child: const Icon(Icons.settings_outlined),
                  ),
                  selectedIcon: const Icon(Icons.settings),
                  label: const Text('Settings'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.bug_report_outlined),
                  selectedIcon: Icon(Icons.bug_report),
                  label: Text('Native API'),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: _screens,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
