import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';
import 'dashboard.dart';
import 'cells.dart';
import 'history.dart';
import 'ecu_explorer.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
