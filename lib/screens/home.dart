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
import 'driver_view_tall.dart';
import 'speed_profile.dart';
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
    // v0.1.29+108: tall portrait head unit (BZ3 720×1106) gets its own
    // scaffold — a Driver-first bottom-nav layout (not the phone dashboard,
    // which is sparse on a 2:3 pane and gated trip on the OBD2 trip id).
    // Evaluated AFTER useHeadUnitLayout so wide landscape BZ5 is never
    // caught here.
    if (LayoutBreakpoints.useTallHeadUnit(context)) {
      return const _TallHomeScreen();
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

/// v0.1.29+108: Tall portrait head-unit layout (BZ3 720×1106).
///
/// Mirrors [_PhoneHomeScreen] (bottom NavigationBar + IndexedStack +
/// ChargingAwareBody) but with two BZ3-specific differences (owner-approved):
///   1. DRIVER FIRST — `DriverViewTallScreen` is index 0, not the dashboard.
///   2. DASHBOARD DROPPED — the old phone dashboard is removed from BZ3
///      navigation entirely; the tall Driver replaces it as the main screen.
///
/// The phone layout (`_PhoneHomeScreen`) keeps Dashboard first and is not
/// affected — this is a separate scaffold reached only via useTallHeadUnit.
///
/// IndexedStack keeps the Driver subtree alive across tab switches, so the
/// _PowerCardTall ring buffer / sample timer survive navigation (same
/// rationale as the wide HeadUnitScaffold).
class _TallHomeScreen extends StatefulWidget {
  const _TallHomeScreen();

  @override
  State<_TallHomeScreen> createState() => _TallHomeScreenState();
}

class _TallHomeScreenState extends State<_TallHomeScreen> {
  int _index = 0;

  // v0.1.59+158 (навигация вариант B): «Замеры» third — identical
  // position and icon on BZ5 / BZ3 / phone-to-come (spatial memory).
  // The portrait layout already fits BZ3 (the screen lived in the
  // phone History tab); IndexedStack keeps the bands alive across tab
  // switches.
  static const _screens = [
    DriverViewTallScreen(),
    CellsScreen(),
    SpeedProfileScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    context.watch<LocaleService>();
    return Scaffold(
      body: ChargingAwareBody(
        // Auto-push charging view only when on the Driver tab (index 0) —
        // the BZ3 equivalent of "sitting on the main screen when the cable
        // goes in".
        autoPushWhenVisible: _index == 0,
        child: IndexedStack(
          index: _index,
          children: _screens,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.directions_car_outlined),
            selectedIcon: const Icon(Icons.directions_car_filled),
            label: S.of('nav.driving'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.battery_4_bar_outlined),
            selectedIcon: const Icon(Icons.battery_4_bar),
            label: S.of('nav.cells'),
          ),
          NavigationDestination(
            // v0.1.59+158: skeleton badge — see the BZ5 rail note.
            icon: Badge(
              isLabelVisible: false, // №2: isParked && unrevealed>0
              backgroundColor: Colors.greenAccent,
              smallSize: 8,
              child: const Icon(Icons.speed_outlined),
            ),
            selectedIcon: const Icon(Icons.speed),
            label: S.of('nav.measure'),
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
