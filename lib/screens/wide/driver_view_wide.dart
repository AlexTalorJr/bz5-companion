import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/cost_settings.dart';
import '../../services/hal_telemetry_service.dart';
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
    // v0.1.29+60: language switch re-renders this tab (const home
    // subtree blocks MaterialApp-level rebuilds — see LocaleService).
    context.watch<LocaleService>();
    final connected = svc.status == ConnectionStatus.connected;
    if (!connected) {
      return const _NotConnectedHero();
    }
    return const _DriverContent();
  }
}

class _NotConnectedHero extends StatelessWidget {
  const _NotConnectedHero();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bluetooth_disabled, size: 96, color: Colors.grey),
          const SizedBox(height: 24),
          Text(S.of('common.not_connected_title'),
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text(S.of('common.not_connected_hint'),
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
    final hasTrip = svc.currentTripId != null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top zone: speed + status (left) | power card (centre, the
          // empty band the owner circled) | gear + SOC stack (right, back
          // to its pre-+67 compact form).
          Expanded(
            flex: hasTrip ? 5 : 7,
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
          if (hasTrip) ...[
            const SizedBox(height: 12),
            // Middle zone: 6 trip metrics in a 2×3 grid.
            const Expanded(
              flex: 3,
              child: TripMetricsPanel(),
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
/// electrical peak), and a ~60 s sparkline.
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
  static const _sampleEvery = Duration(milliseconds: 500);
  static const _historyLen = 120; // × 500 ms = 60 s window

  // v0.1.29+70: auto-zoom scales (owner-chosen "variant B"). A fixed
  // ±200/100 kW scale made city driving (±2-30 kW) a flat line. Instead
  // each side of the scale tracks the max |power| seen in the visible
  // window × 1.2 headroom, with a floor so it doesn't twitch on parked
  // noise and a ceiling at the physical limits. The scale eases toward
  // its target rather than snapping, so the graph never jumps.
  static const _dischargeFloorKw = 10.0;
  static const _dischargeCeilKw = 200.0; // confirmed electrical peak ~223
  static const _regenFloorKw = 10.0;
  static const _regenCeilKw = 100.0;
  static const _scaleEase = 0.15; // per-tick approach to the target

  double _dischargeScale = _dischargeFloorKw;
  double _regenScale = _regenFloorKw;

  // Ring buffer of the last [_historyLen] samples; null = no data at
  // that tick (BLE+HAL both stale) → rendered as a gap.
  final List<double?> _hist =
      List<double?>.filled(_historyLen, null, growable: false);
  int _head = 0; // next write position
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
    final svc = context.read<ConnectionService>();
    final hal = context.read<HalTelemetryService>();
    final p = hal.useHalForPower ? hal.halPowerKw : svc.instantPowerKw;
    // v0.1.29+73: the sparkline is now drawn as discrete vertical bars
    // (see _PowerBarsPainter), so a missing sample is simply a missing
    // bar — invisible against its neighbours. No carry-forward needed;
    // we record the true value (or null) each tick.
    _hist[_head] = p;
    _head = (_head + 1) % _historyLen;
    _recomputeScales();
    // The card also rebuilds via watch() below; this setState keeps the
    // sparkline scrolling even when both providers are quiet.
    setState(() {});
  }

  /// Ease both half-scales toward (window max × 1.2), clamped to
  /// [floor, ceil]. Discharge and regen scale independently so a long
  /// coast doesn't shrink the discharge axis and vice-versa.
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

  /// Oldest-first copy of the ring for painting.
  List<double?> get _ordered => [
        ..._hist.sublist(_head),
        ..._hist.sublist(0, _head),
      ];

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
            // Center-zero bar: regen grows left (green), discharge grows
            // right (blue). Scales auto-zoom (see _recomputeScales).
            SizedBox(
              height: 8,
              child: CustomPaint(
                size: const Size.fromHeight(8),
                painter: _PowerBarPainter(
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
                painter: _PowerBarsPainter(
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

/// ~60 s power sparkline. Zero line at the regen/discharge boundary
/// (same asymmetric vertical scale as the bar: top = +dischargeFull,
/// bottom = −regenFull). Discharge above the line in blue, regen below
/// in green; null samples leave gaps.
/// v0.1.29+73: 60 s power history drawn as discrete vertical bars rather
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
  _PowerBarsPainter(
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

    // Bar pitch: divide the width evenly across all slots; keep a hairline
    // gap so adjacent bars stay legible. Bars are at least ~2 px wide.
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
      if (s == null) continue; // missing bar — no neighbour effect
      final yVal = _y(s, size);
      final cx = i * pitch + pitch / 2;
      // Bar spans between the zero line and the value; min 1 px so a
      // near-zero reading still shows a sliver.
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
    final displaySoc = (hal.useHalForSoc ? hal.halSocPct : svc.socPrecisePct)
        ?? socInt;
    final rangeKm = svc.rangeEstimateKm;

    // Same threshold band used elsewhere in the app for consistency.
    final pct = displaySoc ?? 0;
    final color = pct < 20
        ? Colors.redAccent
        : pct < 50
            ? Colors.orangeAccent
            : Colors.greenAccent;

    // FP-safe one-decimal split.
    String big = '—', small = '';
    if (displaySoc != null) {
      final r = (displaySoc * 10).round() / 10;
      big = r.truncate().toString();
      small = '.${((r - r.truncate()) * 10).round()}';
    }

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
    final soh = svc.readNumeric('790', '0029');
    final odo = svc.readNumeric('791', '0026');
    final spread = (svc.globalMaxCellMv != null && svc.globalMinCellMv != null)
        ? svc.globalMaxCellMv! - svc.globalMinCellMv!
        : null;

    // v0.1.29+67: power moved out of this strip into its own _PowerCard
    // (gear/power/SOC stack) — a 14 pt line was unreadable at driver
    // distance and the card adds the flow bar + 60 s sparkline.

    // Battery temp: HAL probe_highest_temp (verified = battery temp) when
    // fresh, else OBD2 — trip range if active, single 790/002F if idle.
    final hasTrip = svc.currentTripId != null;
    final hal = context.watch<HalTelemetryService>();
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
    // Motor / inverter temps are HAL-only (no OBD2 source) — show "—"
    // when the HAL stream is stale (honesty rule).
    final motorTempStr = (hal.useHalForMotorTemp && hal.halMotorTempC != null)
        ? 'Mot ${hal.halMotorTempC!.toInt()}°C'
        : 'Mot —';
    final invTempStr =
        (hal.useHalForInverterTemp && hal.halInverterTempC != null)
            ? 'Inv ${hal.halInverterTempC!.toInt()}°C'
            : 'Inv —';

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
            Text(soh != null ? 'SOH ${soh.toInt()} %' : 'SOH —'),
            const _Sep(),
            Text(batTempStr),
            const _Sep(),
            Text(motorTempStr),
            const _Sep(),
            Text(invTempStr),
            const _Sep(),
            Text(odo != null
                ? '${S.of('drv.odo')} ${odo.toStringAsFixed(1)} km'
                : '${S.of('drv.odo')} —'),
            const _Sep(),
            Text(spread != null
                ? '${S.of('drv.cell_spread')} ${spread.abs()} mV'
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
