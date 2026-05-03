import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';
import '../widgets/responsive.dart';
import 'dashboard.dart';
import 'cells.dart';
import 'history.dart';
import 'ecu_explorer.dart';
import 'settings.dart';
import 'wide/head_unit_scaffold.dart';

/// v0.1.4: HomeScreen now picks layout based on screen width.
///   - <840 dp → phone layout (NavigationBar at bottom, 5 destinations)
///   - ≥840 dp → head unit layout (NavigationRail on left, 4 destinations,
///                                 multi-pane content)
///
/// The decision is re-evaluated on every rebuild so the app reacts to
/// orientation changes / window resizing on tablets.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (LayoutBreakpoints.useHeadUnitLayout(context)) {
      return const HeadUnitScaffold();
    }
    return const _PhoneHomeScreen();
  }
}

/// Original phone layout — preserved 1:1 from pre-v0.1.4.
class _PhoneHomeScreen extends StatefulWidget {
  const _PhoneHomeScreen();

  @override
  State<_PhoneHomeScreen> createState() => _PhoneHomeScreenState();
}

class _PhoneHomeScreenState extends State<_PhoneHomeScreen> {
  int _index = 0;

  static const _screens = [
    DashboardScreen(),
    CellsScreen(),
    HistoryScreen(),
    EcuExplorerScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Scaffold(
      body: _screens[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          const NavigationDestination(
            icon: Icon(Icons.battery_4_bar_outlined),
            selectedIcon: Icon(Icons.battery_4_bar),
            label: 'Cells',
          ),
          const NavigationDestination(
            icon: Icon(Icons.timeline_outlined),
            selectedIcon: Icon(Icons.timeline),
            label: 'History',
          ),
          const NavigationDestination(
            icon: Icon(Icons.memory_outlined),
            selectedIcon: Icon(Icons.memory),
            label: 'ECUs',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: svc.status != ConnectionStatus.connected,
              backgroundColor: Colors.red,
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: const Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
