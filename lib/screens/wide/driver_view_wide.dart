
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../services/power_history_service.dart';
import '../../services/connection.dart';
import '../../services/cost_settings.dart';
import '../../services/hal_telemetry_service.dart';
import '../../services/soc_resolver.dart';
import '../../services/locale_service.dart';
import '../../widgets/driver_panels.dart';

/// v0.1.23: Driver-first head-unit view.
///
/// Layout principles (designed against automotive HMI norms):
///   - Top-left zone (closest to driver's quick glance from steering)
///     contains the largest, most-referenced numbers: speed.
///   - Top-right shows gear and SOC + range — also high-priority but
///     less frequently scanned than speed.
///   - Middle band: this-trip metrics, the "interesting" data that
///     justifies the EV-companion app's existence.
///   - Bottom band: ambient status (SOH, battery temp range, odometer,
///     cell spread) — readable but never visually loud.
///
/// Sections gated:
///   - Trip metric block: hidden entirely when no active trip
///   - "Consumption" cell shows "— calculating…" for first 2 min
///   - Pack V turns red when < 390 V (load-induced sag warning)
///   - Range km uses trip-specific consumption (EMA over 2 min)
///     when trip is older than 5 min, otherwise constant fallback.
///
/// Phone version is unaffected — this is wide-only (≥840 dp).
class DriverViewWideScreen extends StatelessWidget {
  const DriverViewWideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    // Крупное число и цвет потока остаются событийными — раз в секунду
    // главная цифра на приборе обновляться не должна.
    final hist = context.watch<PowerHistoryService>();
    // v0.1.29+60: language switch re-renders this tab (const home
    // subtree blocks MaterialApp-level rebuilds — see LocaleService).
    context.watch<LocaleService>();
    final connected = svc.status == ConnectionStatus.connected;
    // v0.1.29+83 startup-gate: a halOnly session on the head unit drives
    // this screen from HAL with no BLE dongle. Block only when OBD2 is
    // genuinely required (not a live HAL-capable halOnly session).
    final halActive = hal.canUseHal && hal.mode == HalSourceMode.halOnly;
    if (!connected && !halActive) {
      return _NotConnectedHero(
          halDead: hal.mode == HalSourceMode.halOnly && !hal.running);
    }
    return const _DriverContent();
  }
}

class _NotConnectedHero extends StatelessWidget {
  // v0.1.29+83: see dashboard_wide — halDead means halOnly is selected but
  // the HAL stream isn't running, so the BT prompt would be misleading.
  const _NotConnectedHero({this.halDead = false});
  final bool halDead;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(halDead ? Icons.sync_disabled : Icons.bluetooth_disabled,
              size: 96, color: Colors.grey),
          const SizedBox(height: 24),
          Text(
              halDead
                  ? S.of('settings.datasource.hal_unavailable')
                  : S.of('common.not_connected_title'),
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(
              halDead
                  ? S.of('datasource.hal_dead_hint')
                  : S.of('common.not_connected_hint'),
              style: Theme.of(context)
                  .textTheme
                  .bodyLarge
                  ?.copyWith(color: Colors.grey)),
        ],
      ),
    );
  }
}

class _DriverContent extends StatelessWidget {
  const _DriverContent();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    final hasObdTrip = svc.currentTripId != null;
    // v0.1.29+85 (Design C): a live HAL trip (halOnly, stream up, tracker
    // started) is now a first-class trip for this band. We want it to look
    // identical to an OBD2 trip — the split layout from trip #41: left the
    // shared TripMetricsPanel (now HAL-sourced via invisible substitution),
    // right the HAL-exclusive HalExtrasPanel.
    final halTrip = hal.halDriveActive && hal.halTripActive;
    final hasTrip = hasObdTrip || halTrip;
    // Split layout (TripMetrics | HalExtras) when EITHER an OBD2 trip with
    // a held HAL trip_a (the +75 case) OR a live HAL trip (Design C). In
    // obd2Only the band stays full-width TripMetrics, unchanged.
    final halSplit = hal.useHalForTripA || halTrip;
    final showBand = hasTrip;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top zone: speed + status (left) | power card (centre, the
          // empty band the owner circled) | gear + SOC stack (right, back
          // to its pre-+67 compact form).
          Expanded(
            flex: showBand ? 5 : 7,
            child: const Row(
              children: [
                Expanded(flex: 3, child: SpeedAndStatusStrip()),
                SizedBox(width: 16),
                Expanded(flex: 2, child: _PowerCard()),
                SizedBox(width: 16),
                Expanded(flex: 2, child: _GearAndSocStack()),
              ],
            ),
          ),
          if (showBand) ...[
            const SizedBox(height: 12),
            // Middle zone: trip metrics. obd2Only → full-width
            // TripMetricsPanel (6 cells + cost). HAL trip (or OBD2 trip
            // with a held HAL trip_a) → split: left TripMetricsPanel (same
            // shared widget; HAL-sourced via invisible substitution), right
            // the HAL-exclusive drive panel — the trip #41 layout.
            // flex:3 band height is unchanged.
            Expanded(
              flex: 3,
              child: halSplit
                  ? const Row(
                      children: [
                        Expanded(child: TripMetricsPanel()),
                        SizedBox(width: 12),
                        Expanded(child: HalExtrasPanel()),
                      ],
                    )
                  : const TripMetricsPanel(),
            ),
          ],
          const SizedBox(height: 12),
          // Bottom strip: ambient status (lightweight).
          const _BottomStatusStrip(),
        ],
      ),
    );
  }
}
class _GearAndSocStack extends StatelessWidget {
  const _GearAndSocStack();

  @override
  Widget build(BuildContext context) {
    // v0.1.29+70: back to the compact gear-over-SOC pair. The power card
    // moved out to its own centre column (the band the owner circled) —
    // it never belonged squeezed into this narrow right stack.
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 2, child: _GearCard()),
        SizedBox(height: 12),
        Expanded(flex: 3, child: _SocCard()),
      ],
    );
  }
}

/// v0.1.29+67: Tesla-style live power card — big kW number, a center-zero
/// horizontal bar (right = discharge up to +200 kW, left = regen down to
/// −100 kW, scales chosen by the owner against the confirmed 223 kW
/// electrical peak), and a bar chart whose window follows the pane
/// width (v0.1.94+193 — it was a fixed 60 s on every form factor).
///
/// DISPLAY-ONLY: samples the resolved power (HAL preferred, OBD2
/// fallback — same resolver as everywhere) on a 500 ms timer into a local
/// ring buffer. Nothing is recorded; connection.dart untouched. The
/// buffer lives in widget state — the IndexedStack in head_unit_scaffold
/// keeps this subtree alive across tab switches, so history survives
/// navigation and only resets on app restart.
class _PowerCard extends StatefulWidget {
  const _PowerCard();

  @override
  State<_PowerCard> createState() => _PowerCardState();
}

class _PowerCardState extends State<_PowerCard> {
  // v0.1.94+193 — КОЛЬЦО, ТАКТ И МАСШТАБЫ ПЕРЕЕХАЛИ В СЕРВИС.
  //
  // Здесь стояла вторая копия того же буфера, что и на вертикальном
  // экране: `_hist` на 120 отсчётов, `Timer.periodic` на 500 мс и обе
  // половины шкалы. Копия жила в состоянии карточки и умирала с ней —
  // уход с экрана «Вождение» обнулял историю. Теперь этим владеет
  // `PowerHistoryService`, один на приложение, выше навигатора.
  //
  // Окно графика больше не константа в 60 секунд: слотов столько, сколько
  // влезает по два физических пикселя, поэтому широкая полоса ГУ показывает
  // минуты, а не ту же минуту, что узкая.

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    final powerKw =
        hal.useHalForPower ? hal.halPowerKw : svc.instantPowerKw;
    final flowDir =
        hal.useHalForPower ? hal.halFlowDir : svc.powerFlowDirection;

    final Color powerColor = flowDir == -1
        ? Colors.greenAccent
        : flowDir == 1
            ? Colors.lightBlueAccent
            : Colors.white70;
    final String dirLabel =
        flowDir == -1 ? S.of('drv.regen') : S.of('drv.power');
    // Current scale readout so the auto-zoom stays honest — the driver
    // can always see what full-deflection means right now.
    final String scaleLabel =
        '+${hist.dischargeScale.round()} / −${hist.regenScale.round()} kW';

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
            // Center-zero bar: regen grows left (green), discharge grows
            // right (blue). Scales auto-zoom (see _recomputeScales).
            SizedBox(
              height: 8,
              child: CustomPaint(
                size: const Size.fromHeight(8),
                painter: _PowerBarPainter(
                  kw: powerKw,
                  dischargeFull: hist.dischargeScale,
                  regenFull: hist.regenScale,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 5,
              // Слоты считаются от ФАКТИЧЕСКОЙ ширины полосы: она внутри
              // карточки с отступами, и на 2175 dp разница заметна.
              child: LayoutBuilder(builder: (ctx, box) {
                final dpr = MediaQuery.of(ctx).devicePixelRatio;
                final slots = powerSlotsFor(box.maxWidth, dpr);
                return CustomPaint(
                  size: Size.infinite,
                  painter: _PowerBarsPainter(
                    samples: hist.tail(slots),
                    dischargeFull: hist.dischargeScale,
                    regenFull: hist.regenScale,
                    dpr: dpr,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal center-zero power bar. Zero sits where the regen/discharge
/// scales meet (regenFull left of it, dischargeFull right of it), so the
/// pixel-per-kW density differs per side — deliberate: full-left always
/// means "max regen", full-right "max discharge".
class _PowerBarPainter extends CustomPainter {
  final double? kw;
  final double dischargeFull;
  final double regenFull;
  _PowerBarPainter(
      {required this.kw,
      required this.dischargeFull,
      required this.regenFull});

  @override
  void paint(Canvas canvas, Size size) {
    final zeroX =
        size.width * (regenFull / (regenFull + dischargeFull));
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final r = RRect.fromRectAndRadius(
        Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(r, track);

    final v = kw;
    if (v != null && v.abs() > 0.05) {
      final fill = Paint()
        ..color = v >= 0 ? Colors.lightBlueAccent : Colors.greenAccent;
      if (v >= 0) {
        final w =
            (v / dischargeFull).clamp(0.0, 1.0) * (size.width - zeroX);
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

    // Zero tick on top of the fill.
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1.5;
    canvas.drawLine(
        Offset(zeroX, -1), Offset(zeroX, size.height + 1), tick);
  }

  @override
  bool shouldRepaint(_PowerBarPainter old) =>
      old.kw != kw ||
      old.dischargeFull != dischargeFull ||
      old.regenFull != regenFull;
}

/// Power history chart. Zero line at the regen/discharge boundary
/// (same asymmetric vertical scale as the bar: top = +dischargeFull,
/// bottom = −regenFull). Discharge above the line in blue, regen below
/// in green; null samples leave gaps.
/// v0.1.29+73: power history drawn as discrete vertical bars rather
/// than a connected line. The source (HAL ~2.2 Hz / OBD2 slower) doesn't
/// produce a value on every 500 ms tick, and a polyline tears at every
/// gap. Bars sidestep this entirely: each sample is its own bar from the
/// zero line to its value (discharge up = blue, regen down = green), and
/// a missing sample is just a missing bar — invisible at this density
/// (120 bars across the width). The fill reads like the instrument
/// cluster's own power graph.
class _PowerBarsPainter extends CustomPainter {
  final List<double?> samples;
  final double dischargeFull;
  final double regenFull;
  final double dpr;
  _PowerBarsPainter(
      {required this.samples,
      required this.dischargeFull,
      required this.regenFull,
      required this.dpr});

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

    // Bar pitch: divide the width evenly across all slots; keep a hairline
    // gap so adjacent bars stay legible. Bars are at least ~2 px wide.
    // Пиксельная сетка, а не зажим по dp: см. близнеца в
    // driver_view_tall.dart. Прежний `clamp(1.5, 6.0)` делал столбик шире
    // шага и столбики налезали друг на друга.
    final scale = dpr <= 0 ? 1.0 : dpr;
    final pitchPx = size.width * scale / samples.length;
    final barPx = powerBarWidthFor(scale) * scale;

    final discharge = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.85);
    final regen = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.greenAccent.withValues(alpha: 0.85);

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      if (s == null) continue; // missing bar — no neighbour effect
      final yVal = _y(s, size);
      final leftPx = (i * pitchPx).roundToDouble();
      // Bar spans between the zero line and the value; min 1 px so a
      // near-zero reading still shows a sliver.
      final top = s >= 0 ? yVal : zeroY;
      final bot = s >= 0 ? zeroY : yVal;
      final h = (bot - top).clamp(1.0, size.height);
      final rect =
          Rect.fromLTWH(leftPx / scale, top, barPx / scale, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        s >= 0 ? discharge : regen,
      );
    }
  }

  @override
  bool shouldRepaint(_PowerBarsPainter old) => true;
}

class _GearCard extends StatelessWidget {
  const _GearCard();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+66: gear prefers the HAL gear_enum push (~3.4 Hz, same
    // 1=P/2=R/4=D encoding live-verified) over the OBD2 poll when fresh.
    final hal = context.watch<HalTelemetryService>();
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

    return Card(
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            g.label,
            style: TextStyle(
                fontSize: 140,
                fontWeight: FontWeight.w300,
                color: g.color,
                height: 1.0),
          ),
        ),
      ),
    );
  }
}

class _SocCard extends StatelessWidget {
  const _SocCard();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+66: prefer HAL soc_display (instrument-cluster %, live-
    // verified) when fresh; then precise OBD2 (1FFD); then integer 0x0005.
    final hal = context.watch<HalTelemetryService>();
    final socInt = svc.readNumeric('790', '0005');
    // v0.1.32+131: user-selected SOC source (display / precise).
    final displaySoc = resolveUiSocPct(hal, svc) ?? socInt;
    // v0.1.29+102: EV range — HAL hybrid when SOC available via HAL, else OBD2.
    final rangeKm = hal.useHalForRange ? hal.halRangeKm : svc.rangeEstimateKm;

    // Same threshold band used elsewhere in the app for consistency.
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
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('drv.soc'),
                style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            const SizedBox(height: 4),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(big,
                        style: TextStyle(
                            fontSize: 96,
                            fontWeight: FontWeight.w300,
                            color: color,
                            height: 1.0)),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(small,
                          style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.w300,
                              color: color,
                              height: 1.0)),
                    ),
                    const SizedBox(width: 4),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Text('%',
                          style: TextStyle(
                              fontSize: 26, color: Colors.grey)),
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
            const SizedBox(height: 8),
            if (rangeKm != null)
              Row(
                children: [
                  const Icon(Icons.route, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text('~ ${rangeKm.toInt()} km',
                      style: const TextStyle(
                          fontSize: 18,
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
class _BottomStatusStrip extends StatelessWidget {
  const _BottomStatusStrip();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final hal = context.watch<HalTelemetryService>();
    // v0.1.29+90: SOH — HAL BigData 0x02D3 b[10] when available (halOnly,
    // no dongle → OBD2 790/0029 is blank), else OBD2. Invisible source
    // substitution, same widget, no HAL label (like speed/SOC).
    // v0.1.29+104: SOH precedence — independent coulomb-counted estimate
    // (svc.sohAhPct, bare %) first; else HAL BigData 0x02D3 b[10] (bare %,
    // unchanged); else OBD2 BMS 0x0029 tagged "(BMS)".
    // v0.1.29+105: HAL coulomb-counted SOH (dongle-free) preferred ahead of
    // the UDS coulomb estimate, then HAL BigData (0x02D3) SOH, then BMS.
    final double? sohAh = hal.halSohAhPct ?? svc.sohAhPct;
    final double? sohHal = hal.useHalForSoh ? hal.halSoh : null;
    final double? sohBms = svc.readNumeric('790', '0029');
    final String sohDisplay = sohAh != null
        ? 'SOH ${sohAh.round()} %'
        : (sohHal != null
            ? 'SOH ${sohHal.toInt()} %'
            : (sohBms != null ? 'SOH ${sohBms.toInt()} % (BMS)' : 'SOH —'));
    // v0.1.43+142 §2: subtitle date, same ladder as the percent (date from
    // the source whose value is shown); HAL-BigData / BMS fallback → none.
    final DateTime? sohDate = hal.halSohAhPct != null
        ? hal.halSohComputedAt
        : (svc.sohAhPct != null ? svc.sohComputedAt : null);
    final String? sohSub = sohDate == null
        ? null
        : S.of('soh.computed_at').replaceFirst('{age}', _relTime(sohDate));
    // v0.1.43+142 §2: one-shot "SOH recomputed" SnackBar (variant A).
    _maybeShowSohSnack(context, hal, svc);
    final odo = hal.useHalForOdometer ? hal.halOdometerKm : svc.readNumeric('791', '0026');
    // v0.1.29+84: cell spread — HAL BigData cell_v pair when available
    // (halOnly drive, no OBD2 cells), else OBD2 global min/max. Invisible
    // substitution, same widget/unit, no HAL label (like speed/SOC).
    final double? spread = hal.useHalForCellSpread
        ? hal.halCellSpreadMv
        : (svc.globalMaxCellMv != null && svc.globalMinCellMv != null)
            ? (svc.globalMaxCellMv! - svc.globalMinCellMv!).toDouble()
            : null;

    // v0.1.29+67: power moved out of this strip into its own _PowerCard
    // (gear/power/SOC stack) — a 14 pt line was unreadable at driver
    // distance and the card adds the flow bar + the power bar chart.

    // Battery temp: HAL probe_highest_temp (verified = battery temp) when
    // fresh, else OBD2 — trip range if active, single 790/002F if idle.
    final hasTrip = svc.currentTripId != null;
    final batTempStr = (() {
      if (hal.useHalForBatteryTemp && hal.halBatteryTempC != null) {
        return 'Bat ${hal.halBatteryTempC!.toInt()}°C';
      }
      if (hasTrip &&
          svc.tripMinTempC != null &&
          svc.tripMaxTempC != null) {
        final lo = svc.tripMinTempC!.toInt();
        final hi = svc.tripMaxTempC!.toInt();
        if (lo == hi) return 'Bat $lo°C';
        return 'Bat $lo–$hi°C';
      }
      final cur = svc.readNumeric('790', '002F');
      return cur != null ? 'Bat ${cur.toInt()}°C' : 'Bat —';
    })();
    // v0.1.29+75: motor / inverter temps moved OUT of this ambient strip
    // into HalExtrasPanel (the HAL trip-split half). Bat stays here — it is
    // the one temperature available in BOTH sources, so it is cross-mode.

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
            fontSize: 14, color: Colors.white70, fontWeight: FontWeight.w400),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // v0.1.43+142 §2: SOH cell grows a tiny sub line when an Ah
            // estimate date exists. mainAxisSize.min keeps the strip
            // auto-sized; the strip is a non-Expanded child of a Column
            // with flex zones above, so +~11dp just cedes from those.
            sohSub == null
                ? Text(sohDisplay)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sohDisplay),
                      Text(sohSub,
                          style: TextStyle(
                              fontSize: 9, color: Colors.grey.shade600)),
                    ],
                  ),
            const _Sep(),
            Text(batTempStr),
            const _Sep(),
            Text(odo != null
                ? '${S.of('drv.odo')} ${odo.toStringAsFixed(1)} km'
                : '${S.of('drv.odo')} —'),
            const _Sep(),
            Text(spread != null
                ? '${S.of('drv.cell_spread')} ${spread.abs().round()} mV'
                : '${S.of('drv.cell_spread')} —'),
          ],
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) {
    return const Text('·',
        style: TextStyle(fontSize: 14, color: Colors.grey));
  }
}

/// v0.1.25: efficiency-band color for consumption (kWh/100km).
/// Calibrated against the BZ5's 65.28 kWh LFP pack and typical city +
/// trasse mix observed in our livelog data:
///
///   < 13   → excellent (greenAccent) — pure eco crawl or steep regen
///   13-17  → typical (white) — most mixed city/highway driving
///   17-22  → spirited (yellowAccent) — hard accel, cold, or strong wind
///   > 22   → poor (orangeAccent) — climate-on or aggressive city
///
/// The thresholds align with our anchor data point: 16.7 kWh/100km on
/// the 32 km mixed-city trip on 2026-05-19, which felt normal — so 17
/// is the lower bound of "spirited".

/// v0.1.43+142 §2: private relative-time formatter — the 12-line duplicate
/// precedent (+139/settings), rel.* keys shared.
String _relTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) {
    return S.of('rel.s_ago').replaceFirst('{n}', '${diff.inSeconds}');
  }
  if (diff.inMinutes < 60) {
    return S.of('rel.m_ago').replaceFirst('{n}', '${diff.inMinutes}');
  }
  if (diff.inHours < 24) {
    return S.of('rel.h_ago').replaceFirst('{n}', '${diff.inHours}');
  }
  return S.of('rel.d_ago').replaceFirst('{n}', '${diff.inDays}');
}

/// v0.1.43+142 §2: one-shot "SOH recomputed" SnackBar — same contract as
/// the dashboard.dart copy (synchronous silent take in build so the
/// IndexedStack twin can't double-fire; snack shown post-frame).
void _maybeShowSohSnack(BuildContext context, HalTelemetryService hal,
    ConnectionService svc) {
  final halFresh = hal.takeSohFreshlyComputedAt();
  final udsFresh = svc.takeSohFreshlyComputedAt();
  if (halFresh == null && udsFresh == null) return;
  final double? pct = hal.halSohAhPct ?? svc.sohAhPct;
  if (pct == null) return;
  final msg = S
      .of('soh.recomputed_snack')
      .replaceFirst('{pct}', pct.toStringAsFixed(1));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  });
}
