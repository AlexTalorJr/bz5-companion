import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/cost_settings.dart';
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
          // Top zone: speed + status strip (left) | gear + SOC stack (right).
          // flex 5 — gets most of the vertical real estate when trip is
          // active (drops slightly when trip-section hidden but we keep
          // ratio stable for layout calm).
          Expanded(
            flex: hasTrip ? 5 : 7,
            child: const Row(
              children: [
                Expanded(flex: 3, child: SpeedAndStatusStrip()),
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

    // v0.1.29+36: live power flow on the driver display (+33 data layer,
    // read-only). Discharge blue / regen green / near-zero grey; we show
    // kW magnitude (provisional scale, sign-exact) not raw amps. Falls
    // back to a dash when current is stale.
    final powerKw = svc.instantPowerKw;
    final flowDir = svc.powerFlowDirection;
    final Color powerColor = flowDir == -1
        ? Colors.greenAccent
        : flowDir == 1
            ? Colors.lightBlueAccent
            : Colors.white70;
    final String powerStr = powerKw != null
        ? '${flowDir == -1 ? S.of('drv.regen') : S.of('drv.power')} ${powerKw.abs().toStringAsFixed(1)} kW'
        : '${S.of('drv.power')} —';

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
            Text(powerStr, style: TextStyle(color: powerColor)),
            const _Sep(),
            Text(soh != null ? 'SOH ${soh.toInt()} %' : 'SOH —'),
            const _Sep(),
            Text(batTempStr),
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
