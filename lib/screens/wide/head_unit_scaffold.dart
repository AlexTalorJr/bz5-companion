import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/hal_telemetry_service.dart';
import '../../services/locale_service.dart';
import '../../widgets/charging_banner.dart';
import 'driver_view_wide.dart';
import 'dashboard_wide.dart';
import '../speed_profile.dart';
import 'history_wide.dart';
import 'settings_wide.dart';

/// v0.1.4: Top-level scaffold for head unit / tablet (≥840 dp wide).
///
/// v0.1.23: reorganised tabs. Driver view now first (default) — minimal
/// driver-facing layout with speed/gear hero, trip metrics, and status
/// strip. Old Dashboard demoted to "Analytics" tab (cells, modules,
/// pack extremes — for parked-car deep inspection).
///
/// 4 destinations on a left NavigationRail (v0.1.29+58 — Raw Data went
/// to Settings → Advanced in +56, HAL Explorer followed in +58):
///   - Driver — speed/gear/SOC/PackV + 6 trip metrics + status strip
///   - Analytics — cells, modules, pack extremes (former Dashboard)
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
///
/// v0.1.27: added Native API destination as the 6th tab. Required moving
/// `_screens` from `static const` to instance state because
/// `NativeExplorerWide` needs a shared `NativeDetector` injected via
/// constructor. The detector is created in initState() and probes the
/// BYD framework class once on startup; on phones (where the class is
/// absent) it stays in `isOnHeadUnit=false` and the screen renders a
/// friendly "BLE mode only" notice. No behavioural change for the first
/// 5 destinations.
///
/// v0.1.26+13: hotfix — the first v0.1.27 cut accidentally reverted the
/// scaffold to the v0.1.4 layout (4 tabs: Dashboard/RawData/History/Settings),
/// stripping the Driver and Analytics tabs that landed in v0.1.23. This
/// version restores the full 5-tab layout and adds Native API on the end.
class HeadUnitScaffold extends StatefulWidget {
  const HeadUnitScaffold({super.key});

  @override
  State<HeadUnitScaffold> createState() => _HeadUnitScaffoldState();
}

class _HeadUnitScaffoldState extends State<HeadUnitScaffold> {
  int _index = 0;

  // v0.1.29+58: HAL Explorer moved off the rail into Settings →
  // Advanced (owner: research workbench, hide it). With it went the
  // NativeDetector this state used to own — the pushed route in
  // settings.dart (_HalExplorerRoute) now manages the detector
  // lifecycle itself. Rail is 4 destinations, the list is const again
  // (v0.1.27 made it instance-level solely for the detector injection).
  // v0.1.59+158 (навигация вариант B): «Замеры» promoted from a History
  // tab to its own third section — the time axis «сейчас еду →
  // состояние → измеряю → прошлое → сервис», identical position on
  // every form factor (spatial memory transfers between cars and the
  // phone). The screen moves AS IS (the SPEC.md redesign is patch
  // №2/№3 scope — documented decision).
  static const List<Widget> _screens = [
    DriverViewWideScreen(),
    DashboardWideScreen(),
    SpeedProfileScreen(),
    HistoryWideScreen(),
    SettingsWideScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+58: rebuild rail labels on language switch (the const
    // home subtree blocks MaterialApp-level rebuilds).
    context.watch<LocaleService>();
    // v0.1.23: subtle "look here" indicator on Analytics tab when the
    // car is parked. Driver view is intentionally sparse in P (no trip
    // motion, no live speed) — Analytics has the rich data the user
    // probably wants to see in that idle moment.
    // v0.1.29+66: same gear resolution as the cards (HAL when fresh).
    final hal = context.watch<HalTelemetryService>();
    final gear = hal.useHalForGear
        ? hal.halGear
        : svc.readNumeric('791', '0009');
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
                NavigationRailDestination(
                  icon: const Icon(Icons.directions_car_outlined),
                  selectedIcon: const Icon(Icons.directions_car_filled),
                  label: Text(S.of('nav.driving')),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: isParked && _index != 1,
                    backgroundColor: Colors.greenAccent,
                    smallSize: 8,
                    child: const Icon(Icons.analytics_outlined),
                  ),
                  selectedIcon: const Icon(Icons.analytics),
                  label: Text(S.of('nav.vehicle')),
                ),
                NavigationRailDestination(
                  // v0.1.59+158: the badge is a SKELETON — per the UI
                  // contract it exists ONLY at «P + unrevealed reveals»
                  // (never in motion, инвариант И1). Reveal generation
                  // lands in patch №2; until then the queue is empty by
                  // construction (regress AX6), so the dot physically
                  // never renders. The rec-dot from the old History tab
                  // is deliberately NOT carried over — recording state
                  // lives inside the screen (documented decision).
                  icon: Badge(
                    isLabelVisible: false, // №2: isParked && unrevealed>0
                    backgroundColor: Colors.greenAccent,
                    smallSize: 8,
                    child: const Icon(Icons.speed_outlined),
                  ),
                  selectedIcon: const Icon(Icons.speed),
                  label: Text(S.of('nav.measure')),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.timeline_outlined),
                  selectedIcon: const Icon(Icons.timeline),
                  label: Text(S.of('nav.history')),
                ),
                NavigationRailDestination(
                  icon: Badge(
                    isLabelVisible: svc.status != ConnectionStatus.connected,
                    backgroundColor: Colors.red,
                    child: const Icon(Icons.settings_outlined),
                  ),
                  selectedIcon: const Icon(Icons.settings),
                  label: Text(S.of('nav.settings')),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(
              // v0.1.29+56: charging banner shows above the active tab
              // while a session runs; auto-push fires only from the
              // Driver tab (index 0). See charging_banner.dart.
              child: ChargingAwareBody(
                autoPushWhenVisible: _index == 0,
                child: IndexedStack(
                  index: _index,
                  children: _screens,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
