import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
import '../widgets/charging_banner.dart';
import '../widgets/responsive.dart';
import 'dashboard.dart';
import 'cells.dart';
import 'history.dart';
import 'settings.dart';
import 'wide/head_unit_scaffold.dart';

/// v0.1.4: HomeScreen now picks layout based on screen width.
///   - <840 dp → phone layout (NavigationBar at bottom)
///   - ≥840 dp landscape → head unit layout (NavigationRail on left)
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

/// Phone layout.
///
/// v0.1.29+56: navigation slimmed 5 → 4 destinations. The ECUs tab
/// (EcuExplorerScreen) moved to Settings → Advanced — it's a research
/// tool, not daily-driver functionality. Owner-approved cleanup.
///
/// Each tab body is wrapped in ChargingAwareBody: while a charging
/// session is active a sticky amber banner appears above the content
/// on every tab (tap → full-screen charging view). Auto-push fires
/// only from the Dashboard tab (the phone equivalent of "sitting on
/// the main screen when the cable goes in").
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
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+58: rebuild the bottom bar on language switch. The const
    // home subtree blocks MaterialApp-level rebuilds, so localized
    // widgets subscribe to LocaleService themselves.
    context.watch<LocaleService>();
    return Scaffold(
      body: ChargingAwareBody(
        // Auto-push only when the user is on Dashboard (index 0).
        autoPushWhenVisible: _index == 0,
        child: _screens[_index],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.dashboard_outlined),
            selectedIcon: const Icon(Icons.dashboard),
            label: S.of('nav.dashboard'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.battery_4_bar_outlined),
            selectedIcon: const Icon(Icons.battery_4_bar),
            label: S.of('nav.cells'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.timeline_outlined),
            selectedIcon: const Icon(Icons.timeline),
            label: S.of('nav.history'),
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: svc.status != ConnectionStatus.connected,
              backgroundColor: Colors.red,
              child: const Icon(Icons.settings_outlined),
            ),
            selectedIcon: const Icon(Icons.settings),
            label: S.of('nav.settings'),
          ),
        ],
      ),
    );
  }
}
