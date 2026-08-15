import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/export_service.dart' show ScreenGeometry;
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import '../widgets/charging_banner.dart';
import '../widgets/responsive.dart';
import 'atlas.dart';
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

  /// v0.1.94+193 — ГЕОМЕТРИЯ ЭКРАНА, ЗАМЕРЕННАЯ, А НЕ ВЫВЕДЕННАЯ.
  ///
  /// Одна строка при первой сборке, уезжает журналом приложения в
  /// диаг-дамп. Нужна затем, что плотность окна графика мощности считается
  /// от `devicePixelRatio`, а у BZ5 это число до сих пор ВЫВЕДЕНО из
  /// отношения 1920/2175, а не измерено. У BZ3 оно точное (1080/720 = 1.5).
  /// Ошибись вывод — и окно графика молча окажется другим.
  ///
  /// Печатается один раз на процесс: `build` зовут на каждом повороте и
  /// изменении размера, а строка нужна одна.
  static bool _metricsLogged = false;

  // ── ЗАМОК СНЯТ, ПОКА РАЗМЕР НЕ НАСТОЯЩИЙ. v0.1.98+197 ──
  //
  // +196 запирал замер после ПЕРВОГО кадра — и поле 07.08 привезло
  // `{"width_dp":0,"height_dp":0,"dpr":1.0}`: на первом кадре окно ещё
  // нулевого размера. Защита стояла от «ничего», а пришли нули, и в
  // экспорт уехал мусор, запертый навсегда.
  //
  // Теперь замок защёлкивается только на настоящем размере. Пока
  // ширина или высота нулевая — не пишем ничего и пробуем на следующем
  // кадре. Отсутствие ключа в metadata честнее нулей: «не измерили» и
  // «измерили ноль» — разные вещи.
  //
  // Страж стоит ВПЛОТНУЮ к замеру, без комментария между ними: гейт
  // CB7 смотрит окрестность, а вычищенный комментарий оставляет пустые
  // строки и отодвигает предмет проверки за край окна (та же ловушка,
  // что поймала CA7 в прошлом патче).
  static void _logScreenMetrics(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width.round();
    final h = mq.size.height.round();
    if (w <= 0 || h <= 0) return;
    if (_metricsLogged) return;
    _metricsLogged = true;
    debugPrint('Screen: ${w}x$h dp, dpr ${mq.devicePixelRatio}');
    // +196: те же три числа — в `metadata.json` экспорта. Строка выше
    // уезжает только отдельной кнопкой диаг-дампа и за два визита так
    // и не доехала; архив экспорта владелец присылает сам.
    ScreenGeometry.widthDp = w;
    ScreenGeometry.heightDp = h;
    ScreenGeometry.dpr = mq.devicePixelRatio;
  }

  @override
  Widget build(BuildContext context) {
    _logScreenMetrics(context);
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

  /// Index of «Замеры» — third on EVERY form factor (навигация вариант B,
  /// spatial memory transfers between the cars and the phone).
  static const int _kMeasureIndex = 2;

  // v0.1.62+161: 4 → 5 destinations. «Замеры» is third, `Icons.speed`,
  // identical position to the BZ5 rail and the BZ3 bar. In THIS patch the
  // item leads straight into the atlas (read-only viewer of what the head
  // unit collected); in +162 the viewing screen becomes the root and the
  // atlas moves one push deeper.
  static const _screens = [
    DashboardScreen(),
    CellsScreen(),
    AtlasScreen(),
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
    // v0.1.62+161: badge + plate need the gear. On a phone there is no
    // HAL and usually no dongle → gear stays null → both are absent by
    // expression, which is exactly the contract (§11: the summary numbers
    // live in the head unit's local state).
    final hal = context.watch<HalTelemetryService>();
    final gear = hal.useHalForGear
        ? hal.halGear
        : svc.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;
    final unrevealed =
        context.select<SpeedProfileService, int>((s) => s.unrevealedCount);
    return Scaffold(
      body: ChargingAwareBody(
        // Auto-push only when the user is on Dashboard (index 0).
        autoPushWhenVisible: _index == 0,
        showAtlasPlate: _index != _kMeasureIndex,
        onPlateTap: () => setState(() => _index = _kMeasureIndex),
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
            // v0.1.62+161: badge 14 dp + 2 dp outline (§5) — the same
            // expression as both head units, hidden while the tab is open.
            icon: MeasureBadge(
              visible: isParked &&
                  unrevealed > 0 &&
                  _index != _kMeasureIndex,
              surface: Theme.of(context).colorScheme.surface,
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
    // v0.1.61+160: живой бейдж «Замеров» (§64, AY4) — the same gear
    // resolution as the BZ5 rail (the isParked precedent; this
    // scaffold simply had no gear until the badge needed one).
    final hal = context.watch<HalTelemetryService>();
    final gear = hal.useHalForGear
        ? hal.halGear
        : svc.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;
    final unrevealed = context
        .select<SpeedProfileService, int>((s) => s.unrevealedCount);
    return Scaffold(
      body: ChargingAwareBody(
        // v0.2.7+206 (решение владельца 14.08): BZ3 — тоже головное
        // устройство; автопоказ экрана зарядки с ЛЮБОЙ вкладки, как на
        // BZ5. Телефонная проводка выше остаётся только с Dashboard.
        autoPushWhenVisible: true,
        // v0.1.62+161 (§6.11): sticky plate on every tab but «Замеры».
        showAtlasPlate: _index != 2,
        onPlateTap: () => setState(() => _index = 2),
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
            // v0.1.61+160: live badge (§64 контракта) — see the BZ5
            // rail note; in motion it does not exist by expression.
            // v0.1.62+161: 8 dp borderless → 14 dp with a 2 dp outline
            // (§5). The field verdict on the old dot was «физически не
            // виден»; that is also why the sticky plate exists.
            icon: MeasureBadge(
              visible: isParked && unrevealed > 0 && _index != 2,
              surface: Theme.of(context).colorScheme.surface,
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
