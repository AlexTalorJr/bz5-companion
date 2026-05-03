import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';
import 'dashboard_wide.dart';
import 'raw_data_wide.dart';
import 'history_wide.dart';
import 'settings_wide.dart';

/// v0.1.4: Top-level scaffold for head unit / tablet (≥840 dp wide).
///
/// 4 destinations on a left NavigationRail:
///   - Dashboard — single-page realtime view, all critical stats visible
///   - Raw Data — ECU explorer with live DID table + diagnostics sweep
///   - History — trip log (placeholder for now)
///   - Settings — adapter / connection management
///
/// IndexedStack preserves screen state across switches (so a sweep
/// running on Raw Data doesn't get cancelled if the user briefly
/// switches to Dashboard).
class HeadUnitScaffold extends StatefulWidget {
  const HeadUnitScaffold({super.key});

  @override
  State<HeadUnitScaffold> createState() => _HeadUnitScaffoldState();
}

class _HeadUnitScaffoldState extends State<HeadUnitScaffold> {
  int _index = 0;

  static const _screens = [
    DashboardWideScreen(),
    RawDataWideScreen(),
    HistoryWideScreen(),
    SettingsWideScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            // labelType.all показывает текст под иконкой постоянно — на 15"
            // экране места достаточно, текст помогает водителю не вглядываться.
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
    );
  }
}
