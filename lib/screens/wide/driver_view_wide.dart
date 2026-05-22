import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';
import '../../services/cost_settings.dart';

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
          Text('Адаптер не подключен',
              style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 12),
          Text('Перейдите в Settings и нажмите «Найти адаптер»',
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
          // Top zone: speed + status strip (left) | gear + SOC stack (right).
          // flex 5 — gets most of the vertical real estate when trip is
          // active (drops slightly when trip-section hidden but we keep
          // ratio stable for layout calm).
          Expanded(
            flex: hasTrip ? 5 : 7,
            child: const Row(
              children: [
                Expanded(flex: 3, child: _SpeedAndStatusStrip()),
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
              child: _TripMetricsPanel(),
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

// ─────────────────────── TOP-LEFT: Speed + status strip ──────────────────────

class _SpeedAndStatusStrip extends StatelessWidget {
  const _SpeedAndStatusStrip();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.24: read display speed (which is true wheel speed × 1.05 if
    // user enabled "match speedometer" toggle in Settings, otherwise
    // raw true speed). Trip aggregates still use the unscaled value.
    final speed = svc.displaySpeedKmh ?? 0.0;
    final hvBus = svc.hvBusV;
    final batTemp = svc.readNumeric('790', '002F');
    final pdu1 = svc.readNumeric('740', '0010');
    final pdu2 = svc.readNumeric('740', '0011');

    // Pack V severity color: red when sag below 390 V suggests heavy load
    final hvColor = (hvBus != null && hvBus < 390)
        ? Colors.redAccent
        : Colors.white70;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SPEED',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            // Huge speed number — the single most important reading on
            // a driving dashboard. FittedBox lets it shrink if the column
            // gets narrow (e.g. small tablet), but at 12.3" head unit
            // there's plenty of room for full size.
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      speed.toStringAsFixed(0),
                      // v0.1.24: weight bumped from w200 → w400 and size
                      // 220 → 180 per user feedback that "Tesla-style"
                      // ultrathin was too hard to glance-read at speed.
                      // Slightly smaller numbers + medium weight read
                      // significantly better at 1m driver-seat distance.
                      style: const TextStyle(
                          fontSize: 180,
                          fontWeight: FontWeight.w400,
                          color: Colors.white,
                          height: 0.85),
                    ),
                    const SizedBox(width: 8),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 28),
                      child: Text('km/h',
                          style: TextStyle(
                              fontSize: 28,
                              color: Colors.grey,
                              fontWeight: FontWeight.w300)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Status strip: Pack V (live HV bus) + Battery temp + PDU temps.
            // All in a single line, secondary tone, ~22-24 pt.
            // Pack V goes red on sag (load warning).
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  const Icon(Icons.bolt,
                      size: 18, color: Colors.yellowAccent),
                  const SizedBox(width: 4),
                  Text(
                      hvBus != null
                          ? '${hvBus.toStringAsFixed(1)} V'
                          : '— V',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          color: hvColor)),
                  const SizedBox(width: 24),
                  const Icon(Icons.thermostat,
                      size: 18, color: Colors.orangeAccent),
                  const SizedBox(width: 4),
                  Text(
                      batTemp != null
                          ? 'Bat ${batTemp.toInt()}°'
                          : 'Bat —',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          color: Colors.white70)),
                  const SizedBox(width: 24),
                  const Icon(Icons.device_thermostat,
                      size: 18, color: Colors.deepOrangeAccent),
                  const SizedBox(width: 4),
                  Text(
                      'PDU ${_t(pdu1)}°/${_t(pdu2)}°',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w400,
                          color: Colors.white70)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _t(double? v) => v != null ? v.toInt().toString() : '—';
}

// ─────────────────────── TOP-RIGHT: Gear + SOC stack ─────────────────────────

class _GearAndSocStack extends StatelessWidget {
  const _GearAndSocStack();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 4, child: _GearCard()),
        SizedBox(height: 12),
        Expanded(flex: 6, child: _SocCard()),
      ],
    );
  }
}

class _GearCard extends StatelessWidget {
  const _GearCard();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final gear = svc.readNumeric('791', '0009')?.toInt();
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
    // Prefer precise SOC (1FFD). Fall back to integer (0x0005).
    final socInt = svc.readNumeric('790', '0005');
    final displaySoc = svc.socPrecisePct ?? socInt;
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
            const Text('STATE OF CHARGE',
                style: TextStyle(
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

// ─────────────────────────── MIDDLE: Trip metrics ────────────────────────────

class _TripMetricsPanel extends StatelessWidget {
  const _TripMetricsPanel();

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.27: also watch cost settings so the cost cell rebuilds
    // reactively when the user edits the tariff or currency in
    // Settings and returns to this view.
    final cost = context.watch<CostSettings>();

    // Live trip metrics (rolling, not yet written to DB).
    final dist = svc.tripDistanceKm;
    // v0.1.24: prefer precise-SOC-based energy/consumption (1FFD-derived).
    // The integer-SOC versions step in 0.65 kWh chunks because 1% × 65.28 =
    // 0.6528 kWh, which made the Driver view display feel frozen on short
    // trips (energy stays at "0.65 kWh" until next 1% drop). With precise
    // SOC, energy and consumption update each poll cycle smoothly.
    final energyUsed = svc.tripEnergyUsedPreciseKwh;
    final consumption = svc.tripAvgConsumptionPreciseKwh100km;
    final dur = svc.tripDuration;
    final peakKmh = svc.tripPeakSpeedKmh;
    // Avg moving speed during current trip — computed inline from
    // the service's internal rolling sums (exposed via getter).
    final avgMovingKmh = svc.tripCurrentAvgMovingKmh;

    // First 2 min: hide consumption (too noisy).
    final tripAgeSec = dur?.inSeconds ?? 0;
    final consumptionStr = tripAgeSec < 120
        ? '— calculating…'
        : (consumption != null
            ? '${consumption.toStringAsFixed(1)} kWh/100km'
            : '—');

    // v0.1.27: trip cost — only shown when the tariff is configured.
    // Cost = (live energy used) × (configured cost per kWh). Uses the
    // precise-SOC-derived energyUsed so the value updates each poll
    // cycle smoothly (the integer-SOC version stair-steps in 0.65 kWh
    // chunks — visually ugly for a primary metric).
    final showCost = cost.isConfigured && energyUsed != null;
    final tripCostStr = showCost
        ? cost.formatAmount(energyUsed * cost.costPerKwh)
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.timeline,
                    size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                const Text('THIS TRIP',
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
                const SizedBox(width: 10),
                Text('#${svc.currentTripId ?? "—"}',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey)),
                const Spacer(),
                // v0.1.27: live trip cost — primary user-facing metric
                // requested by the owner. Shown as a large amber figure
                // so it reads at a glance from the driver's seat, with
                // a tiny "TRIP COST" caption above it for context.
                //
                // Visibility rules:
                //   * Hidden entirely when cost_per_kwh is 0 (not
                //     configured) — users who don't care never see it.
                //   * Hidden when tripEnergyUsedPreciseKwh is null
                //     (first few poll cycles after trip start, before
                //     the integration window establishes itself).
                //
                // Format: uses CostSettings.formatAmount which picks
                // leading vs trailing symbol placement automatically
                // ($1.45 vs 145 ₽).
                if (tripCostStr != null) ...[
                  const Text('TRIP COST',
                      style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.2,
                          color: Colors.grey)),
                  const SizedBox(width: 8),
                  Text(
                    tripCostStr,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                      color: Colors.amberAccent,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _TripCell(
                        value: dist != null
                            ? dist.toStringAsFixed(1)
                            : '—',
                        unit: 'km',
                        label: 'distance'),
                  ),
                  Expanded(
                    child: _TripCell(
                        value: energyUsed != null
                            ? energyUsed.toStringAsFixed(2)
                            : '—',
                        unit: 'kWh',
                        label: 'energy used'),
                  ),
                  Expanded(
                    child: _TripCell(
                        value: tripAgeSec < 120
                            ? '—'
                            : (consumption != null
                                ? consumption.toStringAsFixed(1)
                                : '—'),
                        unit: tripAgeSec < 120
                            ? 'calculating…'
                            : 'kWh/100km',
                        label: 'consumption',
                        isCalculating: tripAgeSec < 120,
                        // v0.1.25: color by efficiency band. Calibrated
                        // for BZ5 with 65.28 kWh pack:
                        //   < 13   kWh/100km → excellent (eco trip, easy
                        //                       cruise downhill / mild)
                        //   13-17  kWh/100km → typical city + mixed
                        //   17-22  kWh/100km → spirited or cold weather
                        //   > 22   kWh/100km → aggressive or heater on
                        //
                        // Skipped while "calculating…" (first 2 min) so
                        // the user doesn't see a flashing red number
                        // because of early-trip noise.
                        valueColor: tripAgeSec < 120 || consumption == null
                            ? null
                            : _consumptionColor(consumption)),
                  ),
                ],
              ),
            ),
            const Divider(height: 16, color: Colors.white12),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _TripCell(
                        value: dur != null ? _fmtDur(dur) : '—',
                        unit: '',
                        label: 'duration'),
                  ),
                  Expanded(
                    child: _TripCell(
                        value: peakKmh != null
                            ? peakKmh.toStringAsFixed(0)
                            : '—',
                        unit: 'km/h',
                        label: 'peak speed'),
                  ),
                  Expanded(
                    child: _TripCell(
                        value: avgMovingKmh != null
                            ? avgMovingKmh.toStringAsFixed(0)
                            : '—',
                        unit: 'km/h',
                        label: 'avg moving'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDur(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}

class _TripCell extends StatelessWidget {
  final String value;
  final String unit;
  final String label;
  final bool isCalculating;
  /// v0.1.25: optional color override for the main value text.
  /// When null (default), uses white (or grey if isCalculating).
  /// Used for consumption efficiency banding — see _consumptionColor.
  final Color? valueColor;
  const _TripCell({
    required this.value,
    required this.unit,
    required this.label,
    this.isCalculating = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: isCalculating ? 22 : 36,
                      fontWeight: FontWeight.w300,
                      color: isCalculating
                          ? Colors.grey
                          : (valueColor ?? Colors.white),
                      fontStyle: isCalculating
                          ? FontStyle.italic
                          : FontStyle.normal)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(unit,
                      style: TextStyle(
                          fontSize: 14,
                          color: isCalculating
                              ? Colors.grey.shade600
                              : Colors.grey,
                          fontStyle: isCalculating
                              ? FontStyle.italic
                              : FontStyle.normal)),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.5,
                color: Colors.grey)),
      ],
    );
  }
}

// ─────────────────────────── BOTTOM: Status strip ────────────────────────────

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

    // Battery temp: trip range if active, single value if idle.
    final hasTrip = svc.currentTripId != null;
    final batTempStr = (() {
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
            Text(odo != null
                ? 'Odo ${odo.toStringAsFixed(1)} km'
                : 'Odo —'),
            const _Sep(),
            Text(spread != null
                ? 'Cell spread ${spread.abs()} mV'
                : 'Cell spread —'),
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
Color _consumptionColor(double kwh100km) {
  if (kwh100km < 13) return Colors.greenAccent;
  if (kwh100km < 17) return Colors.white;
  if (kwh100km < 22) return Colors.yellowAccent;
  return Colors.orangeAccent;
}
