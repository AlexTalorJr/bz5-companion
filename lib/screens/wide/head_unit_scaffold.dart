import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';
import 'driver_view_wide.dart';
import 'dashboard_wide.dart';
import 'raw_data_wide.dart';
import 'history_wide.dart';
import 'settings_wide.dart';

/// v0.1.4: Top-level scaffold for head unit / tablet (≥840 dp wide).
///
/// v0.1.23: reorganised tabs. Driver view now first (default) — minimal
/// driver-facing layout with speed/gear hero, trip metrics, and status
/// strip. Old Dashboard demoted to "Analytics" tab (cells, modules,
/// pack extremes — for parked-car deep inspection).
///
/// 5 destinations on a left NavigationRail:
///   - Driver — speed/gear/SOC/PackV + 6 trip metrics + status strip
///   - Analytics — cells, modules, pack extremes (former Dashboard)
///   - Raw Data — ECU explorer with live DID table + diagnostics sweep
///   - History — trip log
///   - Settings — adapter / connection management
///
/// IndexedStack preserves screen state across switches (so a sweep
/// running on Raw Data doesn't get cancelled if the user briefly
/// switches to Driver).
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
class HeadUnitScaffold extends StatefulWidget {
  const HeadUnitScaffold({super.key});

  @override
  State<HeadUnitScaffold> createState() => _HeadUnitScaffoldState();
}

class _HeadUnitScaffoldState extends State<HeadUnitScaffold> {
  int _index = 0;

  static const _screens = [
    DriverViewWideScreen(),
    DashboardWideScreen(),
    RawDataWideScreen(),
    HistoryWideScreen(),
    SettingsWideScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.23: subtle "look here" indicator on Analytics tab when the
    // car is parked. Driver view is intentionally sparse in P (no trip
    // motion, no live speed) — Analytics has the rich data the user
    // probably wants to see in that idle moment.
    final gear = svc.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;

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
                  icon: Icon(Icons.directions_car_outlined),
                  selectedIcon: Icon(Icons.directions_car_filled),
                  label: Text('Driver'),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: isParked && _index != 1,
                    backgroundColor: Colors.greenAccent,
                    smallSize: 8,
                    child: const Icon(Icons.analytics_outlined),
                  ),
                  selectedIcon: const Icon(Icons.analytics),
                  label: const Text('Analytics'),
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
