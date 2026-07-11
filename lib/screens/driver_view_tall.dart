// v0.1.29+108: BZ3 tall-portrait Driver screen (owner-approved "Variant A").
//
// Why this file exists
// --------------------
// The BZ3 head unit is a 720 × 1106 dp portrait tablet. Before +108 it fell
// through to `_PhoneHomeScreen` → `DashboardScreen` (the phone dashboard),
// which (a) looks sparse on a 2:3 portrait pane (content crammed in the top
// third) and (b) gated its trip section on `svc.currentTripId` — the OBD2
// trip id, which is null in halOnly without a dongle. Result: no trip ever
// showed on BZ3 even though the HAL trip machine was running fine.
//
// This screen is the BZ3 equivalent of the BZ5 landscape Driver
// (`wide/driver_view_wide.dart`) — same widget vocabulary, re-composed for a
// tall narrow viewport. It is the PRIMARY and ONLY instrument screen on BZ3
// (the old Dashboard tab is dropped from BZ3 navigation — owner decision).
//
// Layout difference vs the wide Driver
// ------------------------------------
// The wide Driver fills its pane with `Expanded(flex:)` rows inside a Column
// (bounded by the head-unit's fixed landscape height). That model does NOT
// work on a tall portrait screen rendered inside a scrollable column: an
// unbounded-height parent makes Flutter reject `Expanded`. So this screen
// composes FIXED-HEIGHT sections in a `ListView` instead (the contract the
// shared `driver_panels.dart` widgets call "compact: true").
//
// Shared widgets (`SpeedAndStatusStrip`, `TripMetricsPanel`, `HalExtrasPanel`)
// are REUSED from driver_panels.dart — they are StatelessWidgets with no
// shared mutable state, so reusing them here cannot affect the BZ5 Driver.
// The private cards/painters that live only in driver_view_wide.dart
// (`_PowerCard`, gear/SOC cards, the two power painters) are COPIED here as
// `_PowerCardTall` etc. rather than imported, because they are file-private
// in the wide screen and we must not edit that BZ5 file (AA: BZ5 untouched).
// The copy wraps the power card in a SizedBox so its internal Expanded()s
// get a bounded height inside this otherwise-unbounded column.
//
// Trip / Motor gating
// -------------------
// Same gate as the wide Driver: `hal.halDriveActive && hal.halTripActive`.
// In halOnly (BZ3's mode), `halDriveActive == halOnly && _running == true`,
// so the trip (6 values, TripMetricsPanel) and motor (7 values,
// HalExtrasPanel) blocks fill with real HAL data. No shared-widget gate is
// widened — BZ5 behaviour is identical.

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/soc_resolver.dart';
import '../services/locale_service.dart';
import '../widgets/driver_panels.dart';

/// Top-level BZ3 portrait Driver screen. Routed from home.dart when
/// `LayoutBreakpoints.useTallHeadUnit(context)` is true (BZ3 720×1106).
class DriverViewTallScreen extends StatelessWidget {
  const DriverViewTallScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const _TallDriverContent();
  }
}

class _TallDriverContent extends StatelessWidget {
  const _TallDriverContent();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    // v0.1.29+108: per-screen language subscription (the X4 rebuild
    // contract). The const home subtree blocks MaterialApp-level rebuilds,
    // so localized screens watch LocaleService themselves.
    context.watch<LocaleService>();

    // Same trip detection as wide/driver_view_wide.dart:104. In halOnly
    // (BZ3) halDriveActive is true while the stream runs, so the HAL trip
    // is a first-class trip and the trip/motor sections appear once the
    // gear/speed start path fires the trip machine.
    final hasObdTrip = svc.currentTripId != null;
    final halTrip = hal.halDriveActive && hal.halTripActive;
    final showBand = hasObdTrip || halTrip;

    // v0.1.29+109: this screen has NO AppBar (it's a bare body in the tall
    // scaffold's IndexedStack), so on BZ3 720×1106 the ListView started flush
    // against the system status bar (clock/icons/车外 temp) and the top row
    // ("54 km/h") was clipped. SafeArea(top) drops the whole screen below the
    // status bar. Nothing is resized or repositioned — the entire layout just
    // shifts down. bottom:false because the NavigationBar owns the bottom
    // inset (and the last child already has trailing padding). Applied HERE,
    // not around the IndexedStack in home.dart, because the other tabs
    // (Cells/History/Settings) each have their own Scaffold+AppBar and a
    // body-level SafeArea would double-inset them.
    return SafeArea(
      bottom: false,
      child: ListView(
        // Horizontal 16 unchanged; a little extra top padding (below the
        // SafeArea inset) gives breathing room under the status bar as the
        // owner asked — "drop it down a bit". Sizes/positions untouched.
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        children: [
          // ── Top zone: speed (huge, left) + gear/SOC stack (right).
        // SpeedAndStatusStrip(compact:true) is content-sized (it skips
        // Expanded in compact mode), so it needs no SizedBox wrapper.
        // The gear/SOC stack is given a fixed height so its cards (which
        // use Expanded internally) have a bound.
        SizedBox(
          height: 210,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SpeedAndStatusStrip(compact: true, roomy: true),
                ),
              ),
              SizedBox(width: 12),
              Expanded(flex: 2, child: _GearAndSocStackTall()),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // ── Power / regen card — the screen signature (big kW + center-zero
        // bar + 60 s sparkline). Fixed height so the card's internal
        // Expanded()s resolve inside this scrollable (unbounded) column.
        const SizedBox(height: 190, child: _PowerCardTall()),

        // ── Trip (6 values) + Motor (7 values), shown while a trip runs.
        // Full TripMetricsPanel (NOT the compact 6→fewer cut — owner wants
        // all six). HalExtrasPanel is the HAL-exclusive 7-value motor grid.
        if (showBand) ...[
          const SizedBox(height: 12),
          const TripMetricsPanel(),
          const SizedBox(height: 12),
          const HalExtrasPanel(),
        ],

        const SizedBox(height: 12),
        // ── Ambient status. On 720 dp a single Row of 4 values overflows,
        // so this is a 2×2 grid (see _BottomStatusGridTall).
        const _BottomStatusGridTall(),
        const SizedBox(height: 8),
      ],
      ),
    );
  }
}

/// Gear card over SOC card, stretched to fill the fixed-height top-right
/// slot. Ported from driver_view_wide.dart `_GearAndSocStack`.
/// v0.1.29+119: merged gear+SOC card (owner request, BZ3 field feedback —
/// "шрифт SOC всё равно мелкий"). Replaces the former two-card stack
/// (_GearCardTall over _SocCardTall): the gear letter shrinks into the
/// card's top-right corner and the SOC digits inherit the ENTIRE former
/// gear-card height — roughly doubling their rendered size in the same
/// 210 dp top-right slot. Gear mapping/colors and the SOC/range/bar
/// content are carried over verbatim from the deleted cards.
class _GearAndSocStackTall extends StatelessWidget {
  const _GearAndSocStackTall();

  @override
  Widget build(BuildContext context) {
    return const _GearSocCardTall();
  }
}

class _GearSocCardTall extends StatelessWidget {
  const _GearSocCardTall();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();

    // ── Gear (mapping identical to the former _GearCardTall).
    final gear = (hal.useHalForGear
            ? hal.halGear
            : svc.readNumeric('791', '0009'))
        ?.toInt();
    final parking = svc.parkingPawlEngaged;
    final isCharging = svc.isCharging;
    final ({String label, Color color}) g;
    if (gear == 1 || parking == true) {
      g = (label: 'P', color: Colors.lightBlueAccent);
    } else if (gear == 2) {
      g = (label: 'R', color: Colors.redAccent);
    } else if (gear == 3) {
      g = (label: 'N', color: Colors.orangeAccent);
    } else if (gear == 4) {
      g = (label: 'D', color: Colors.greenAccent);
    } else if (isCharging) {
      g = (label: '⚡', color: Colors.amber);
    } else {
      g = (label: '—', color: Colors.grey);
    }

    // ── SOC + range (identical to the former _SocCardTall).
    final socInt = svc.readNumeric('790', '0005');
    // v0.1.32+131: user-selected SOC source (display / precise).
    final displaySoc = resolveUiSocPct(hal, svc) ?? socInt;
    final rangeKm = hal.useHalForRange ? hal.halRangeKm : svc.rangeEstimateKm;

    final pct = displaySoc ?? 0;
    final color = pct < 20
        ? Colors.redAccent
        : pct < 50
            ? Colors.orangeAccent
            : Colors.greenAccent;

    // v0.1.32+131: shared FP-safe split; integral → no fractional suffix.
    final (big, small) = splitSocDigits(displaySoc);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: SOC label left, compact gear letter right. The
            // gear is a fixed 44 pt — legible at arm's length but ceding
            // the vertical budget to the SOC digits below.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.of('drv.soc'),
                    style: const TextStyle(
                        fontSize: 12, letterSpacing: 1.5, color: Colors.grey)),
                const Spacer(),
                Text(
                  g.label,
                  style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w400,
                      color: g.color,
                      height: 1.0),
                ),
              ],
            ),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(big,
                        // Ceiling raised 104 → 150: the FittedBox still
                        // scales down to the slot, but the slot itself is
                        // now the merged card's full height, so the digits
                        // land ~2× the +115 size instead of hitting the
                        // old ceiling early.
                        style: TextStyle(
                            fontSize: 150,
                            fontWeight: FontWeight.w300,
                            color: color,
                            height: 1.0)),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(small,
                          style: TextStyle(
                              fontSize: 72,
                              fontWeight: FontWeight.w300,
                              color: color,
                              height: 1.0)),
                    ),
                    const SizedBox(width: 4),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('%',
                          style:
                              TextStyle(fontSize: 26, color: Colors.grey)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 6,
                backgroundColor: Colors.grey.shade800,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
            const SizedBox(height: 6),
            if (rangeKm != null)
              Row(
                children: [
                  const Icon(Icons.route, size: 15, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text('~ ${rangeKm.toInt()} km',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: Colors.white70)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Ported copy of driver_view_wide.dart `_PowerCard` (StatefulWidget with a
/// 500 ms sample timer). The wide file stays untouched (AA: BZ5 untouched);
/// this copy is identical in behaviour. It lives inside the tall scaffold's
/// IndexedStack, so the ring buffer survives tab switches and the timer is
/// created once. `dispose()` cancels the timer.
class _PowerCardTall extends StatefulWidget {
  const _PowerCardTall();

  @override
  State<_PowerCardTall> createState() => _PowerCardTallState();
}

class _PowerCardTallState extends State<_PowerCardTall> {
  static const _sampleEvery = Duration(milliseconds: 500);
  static const _historyLen = 120; // × 500 ms = 60 s window

  static const _dischargeFloorKw = 10.0;
  static const _dischargeCeilKw = 200.0;
  static const _regenFloorKw = 10.0;
  static const _regenCeilKw = 100.0;
  static const _scaleEase = 0.15;

  double _dischargeScale = _dischargeFloorKw;
  double _regenScale = _regenFloorKw;

  final List<double?> _hist =
      List<double?>.filled(_historyLen, null, growable: false);
  int _head = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_sampleEvery, (_) => _sample());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sample() {
    if (!mounted) return;
    final hal = context.read<HalTelemetryService>();
    final svc = context.read<ConnectionService>();
    final p = hal.useHalForPower ? hal.halPowerKw : svc.instantPowerKw;
    _hist[_head] = p;
    _head = (_head + 1) % _historyLen;
    _recomputeScales();
    setState(() {});
  }

  void _recomputeScales() {
    double maxDis = 0, maxReg = 0;
    for (final s in _hist) {
      if (s == null) continue;
      if (s > maxDis) maxDis = s;
      if (-s > maxReg) maxReg = -s;
    }
    final disTarget =
        (maxDis * 1.2).clamp(_dischargeFloorKw, _dischargeCeilKw);
    final regTarget = (maxReg * 1.2).clamp(_regenFloorKw, _regenCeilKw);
    _dischargeScale += (disTarget - _dischargeScale) * _scaleEase;
    _regenScale += (regTarget - _regenScale) * _scaleEase;
  }

  List<double?> get _ordered => [
        ..._hist.sublist(_head),
        ..._hist.sublist(0, _head),
      ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    final powerKw = hal.useHalForPower ? hal.halPowerKw : svc.instantPowerKw;
    final flowDir =
        hal.useHalForPower ? hal.halFlowDir : svc.powerFlowDirection;

    final Color powerColor = flowDir == -1
        ? Colors.greenAccent
        : flowDir == 1
            ? Colors.lightBlueAccent
            : Colors.white70;
    final String dirLabel =
        flowDir == -1 ? S.of('drv.regen') : S.of('drv.power');
    final String scaleLabel =
        '+${_dischargeScale.round()} / −${_regenScale.round()} kW';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(dirLabel.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
                Text(scaleLabel,
                    style: const TextStyle(
                        fontSize: 10,
                        color: Colors.grey,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 2),
            Expanded(
              flex: 4,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      powerKw != null
                          ? powerKw.abs().toStringAsFixed(1)
                          : '—',
                      style: TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w400,
                          color: powerColor,
                          height: 0.95),
                    ),
                    const SizedBox(width: 6),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 7),
                      child: Text('kW',
                          style:
                              TextStyle(fontSize: 18, color: Colors.grey)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 8,
              child: CustomPaint(
                size: const Size.fromHeight(8),
                painter: _PowerBarPainterTall(
                  kw: powerKw,
                  dischargeFull: _dischargeScale,
                  regenFull: _regenScale,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 5,
              child: CustomPaint(
                size: Size.infinite,
                painter: _PowerBarsPainterTall(
                  samples: _ordered,
                  dischargeFull: _dischargeScale,
                  regenFull: _regenScale,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ported copy of driver_view_wide.dart `_PowerBarPainter`.
class _PowerBarPainterTall extends CustomPainter {
  final double? kw;
  final double dischargeFull;
  final double regenFull;
  _PowerBarPainterTall(
      {required this.kw,
      required this.dischargeFull,
      required this.regenFull});

  @override
  void paint(Canvas canvas, Size size) {
    final zeroX = size.width * (regenFull / (regenFull + dischargeFull));
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final r =
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(r, track);

    final v = kw;
    if (v != null && v.abs() > 0.05) {
      final fill = Paint()
        ..color = v >= 0 ? Colors.lightBlueAccent : Colors.greenAccent;
      if (v >= 0) {
        final w = (v / dischargeFull).clamp(0.0, 1.0) * (size.width - zeroX);
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(zeroX, 0, w, size.height),
                const Radius.circular(4)),
            fill);
      } else {
        final w = (v.abs() / regenFull).clamp(0.0, 1.0) * zeroX;
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(zeroX - w, 0, w, size.height),
                const Radius.circular(4)),
            fill);
      }
    }

    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(zeroX, -1), Offset(zeroX, size.height + 1), tick);
  }

  @override
  bool shouldRepaint(_PowerBarPainterTall old) =>
      old.kw != kw ||
      old.dischargeFull != dischargeFull ||
      old.regenFull != regenFull;
}

/// Ported copy of driver_view_wide.dart `_PowerBarsPainter`.
class _PowerBarsPainterTall extends CustomPainter {
  final List<double?> samples;
  final double dischargeFull;
  final double regenFull;
  _PowerBarsPainterTall(
      {required this.samples,
      required this.dischargeFull,
      required this.regenFull});

  double _y(double kw, Size size) {
    final span = dischargeFull + regenFull;
    return ((dischargeFull - kw) / span).clamp(0.0, 1.0) * size.height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    final zeroY = _y(0, size);
    final zeroPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), zeroPaint);

    final pitch = size.width / samples.length;
    final barW = (pitch * 0.7).clamp(1.5, 6.0);

    final discharge = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.85);
    final regen = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.greenAccent.withValues(alpha: 0.85);

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (s == null) continue;
      final yVal = _y(s, size);
      final cx = i * pitch + pitch / 2;
      final top = s >= 0 ? yVal : zeroY;
      final bot = s >= 0 ? zeroY : yVal;
      final h = (bot - top).clamp(1.0, size.height);
      final rect = Rect.fromLTWH(cx - barW / 2, top, barW, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        s >= 0 ? discharge : regen,
      );
    }
  }

  @override
  bool shouldRepaint(_PowerBarsPainterTall old) => true;
}

/// 2×2 status grid (SOH · Bat / Odo · spread). The wide Driver lays these
/// out as a single Row with spaceBetween, but on a 720 dp portrait pane
/// four texts in one row overflow — so this is a 2×2 grid. Values resolve
/// through the same HAL-preferred resolvers as the wide _BottomStatusStrip.
class _BottomStatusGridTall extends StatelessWidget {
  const _BottomStatusGridTall();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();

    // SOH precedence (mirrors wide _BottomStatusStrip / +105):
    // HAL coulomb Ah → HAL BigData 0x02D3 → OBD2 BMS (tagged).
    final double? sohAh = hal.halSohAhPct ?? svc.sohAhPct;
    final double? sohHal = hal.useHalForSoh ? hal.halSoh : null;
    final double? sohBms = svc.readNumeric('790', '0029');
    final String sohDisplay = sohAh != null
        ? 'SOH ${sohAh.round()} %'
        : (sohHal != null
            // v0.1.29+119: tag the live BMS-reported SOH the same way the
            // UDS BMS value is tagged — an untagged value must mean OUR
            // coulomb-counted estimate, nothing else. On BZ3 the untagged
            // live value was indistinguishable from a corrected one.
            ? 'SOH ${sohHal.toInt()} % (BMS)'
            : (sohBms != null ? 'SOH ${sohBms.toInt()} % (BMS)' : 'SOH —'));

    final odo = hal.useHalForOdometer
        ? hal.halOdometerKm
        : svc.readNumeric('791', '0026');

    final double? spread = hal.useHalForCellSpread
        ? hal.halCellSpreadMv
        : (svc.globalMaxCellMv != null && svc.globalMinCellMv != null)
            ? (svc.globalMaxCellMv! - svc.globalMinCellMv!).toDouble()
            : null;

    final hasTrip = svc.currentTripId != null;
    final batTempStr = (() {
      if (hal.useHalForBatteryTemp && hal.halBatteryTempC != null) {
        return 'Bat ${hal.halBatteryTempC!.toInt()}°C';
      }
      if (hasTrip && svc.tripMinTempC != null && svc.tripMaxTempC != null) {
        final lo = svc.tripMinTempC!.toInt();
        final hi = svc.tripMaxTempC!.toInt();
        if (lo == hi) return 'Bat $lo°C';
        return 'Bat $lo–$hi°C';
      }
      final cur = svc.readNumeric('790', '002F');
      return cur != null ? 'Bat ${cur.toInt()}°C' : 'Bat —';
    })();

    final odoStr = odo != null
        ? '${S.of('drv.odo')} ${odo.toStringAsFixed(1)} km'
        : '${S.of('drv.odo')} —';
    final spreadStr = spread != null
        ? '${S.of('drv.cell_spread')} ${spread.abs().round()} mV'
        : '${S.of('drv.cell_spread')} —';

    Widget cell(String text) => Text(
          text,
          style: const TextStyle(
              fontSize: 15,
              color: Colors.white70,
              fontWeight: FontWeight.w400),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: cell(sohDisplay)),
              const SizedBox(width: 12),
              Expanded(child: cell(batTempStr)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: cell(odoStr)),
              const SizedBox(width: 12),
              Expanded(child: cell(spreadStr)),
            ],
          ),
        ],
      ),
    );
  }
}
