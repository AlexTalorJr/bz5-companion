// Shared driver/trip widgets used by:
//   - lib/screens/wide/driver_view_wide.dart (BZ5 head unit, landscape)
//   - lib/screens/dashboard.dart (BZ3 tall portrait — useTallLayout branch)
//
// Extracted in v0.1.29+8 to consolidate the speed/Pack V/temps strip and
// the trip metrics panel into one place. Before this patch the two
// dashboards each had their own slightly-different implementations:
//
//   - driver_view_wide.dart had private _SpeedAndStatusStrip,
//     _TripMetricsPanel, _TripCell, _consumptionColor.
//   - dashboard.dart had its own minimal _TallDriverSection (limited
//     compared to the wide version — missing cost, missing efficiency
//     colour, missing energy-used) introduced in v0.1.29+1.
//
// Each widget here supports two modes via the `compact` boolean:
//
//   - compact: false (default) — BZ5 wide head unit. The widget assumes
//     it sits inside an Expanded() inside a Row/Column (bounded by the
//     parent's flex) and uses Expanded() inside its own Column to fill
//     vertical room. Font sizes are large (180px speed, 36px trip cells).
//
//   - compact: true — BZ3 tall portrait. The widget assumes it sits
//     inside a SizedBox(height: N) inside a ListView (bounded by a
//     fixed height, NOT by flex). It must NOT use Expanded() inside
//     its own Column because the outer parent is also unbounded above
//     the SizedBox — Flutter rejects that. Font sizes are reduced
//     (80px speed, 22px trip cells) to fit the portrait pane.
//
// Why two modes and not one auto-detecting widget: LayoutBuilder could
// detect the parent's constraints, but it's invoked at layout time
// not build time and would complicate Card padding decisions. Explicit
// flag is simpler, less surprising, and matches the call sites which
// know which mode they want anyway.

import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';
import '../services/cost_settings.dart';

/// Speed (huge) + status strip (Pack V / Bat / PDU temps).
///
/// Pack V text shows `packVoltageFromCells` (the only physically
/// correct pack voltage we have — see v0.1.29+2/+4 commits). Its
/// colour stays driven by `hvBusV` so the < 390 V load-sag warning
/// still fires when the bus actually dips — that's the load-side
/// observable, which is what we want to alert on regardless of which
/// number we display.
class SpeedAndStatusStrip extends StatelessWidget {
  /// `true` → BZ3 tall portrait sizing. See file header.
  final bool compact;
  const SpeedAndStatusStrip({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.24: display speed = true wheel speed × 1.05 if user enabled
    // the "match speedometer" toggle in Settings; else raw true speed.
    final speed = svc.displaySpeedKmh ?? 0.0;
    final packFromCells = svc.packVoltageFromCells;
    final hvBus = svc.hvBusV;
    final batTemp = svc.readNumeric('790', '002F');
    final pdu1 = svc.readNumeric('740', '0010');
    final pdu2 = svc.readNumeric('740', '0011');

    final hvColor = (hvBus != null && hvBus < 390)
        ? Colors.redAccent
        : Colors.white70;

    final speedFontSize = compact ? 80.0 : 180.0;
    final unitFontSize = compact ? 14.0 : 28.0;
    final statusFontSize = compact ? 14.0 : 22.0;
    final iconSize = compact ? 14.0 : 18.0;
    final padding = compact
        ? const EdgeInsets.fromLTRB(14, 10, 14, 10)
        : const EdgeInsets.fromLTRB(24, 20, 24, 16);

    final speedRow = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            speed.toStringAsFixed(0),
            // v0.1.24: w400 + 180 read better at driver-seat distance
            // than w200 + 220 (the original Tesla-style ultrathin was
            // too hard to glance-read).
            style: TextStyle(
                fontSize: speedFontSize,
                fontWeight: FontWeight.w400,
                color: Colors.white,
                height: 0.85),
          ),
          SizedBox(width: compact ? 4 : 8),
          Padding(
            padding: EdgeInsets.only(bottom: compact ? 6 : 28),
            child: Text('km/h',
                style: TextStyle(
                    fontSize: unitFontSize,
                    color: Colors.grey,
                    fontWeight: FontWeight.w300)),
          ),
        ],
      ),
    );

    final statusRow = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(Icons.bolt, size: iconSize, color: Colors.yellowAccent),
          SizedBox(width: compact ? 3 : 4),
          Text(
              packFromCells != null
                  ? '${packFromCells.toStringAsFixed(1)} V'
                  : hvBus != null
                      ? '${hvBus.toStringAsFixed(1)} V*'
                      : '— V',
              style: TextStyle(
                  fontSize: statusFontSize,
                  fontWeight: FontWeight.w400,
                  color: hvColor)),
          SizedBox(width: compact ? 12 : 24),
          Icon(Icons.thermostat, size: iconSize, color: Colors.orangeAccent),
          SizedBox(width: compact ? 3 : 4),
          Text(
              batTemp != null
                  ? 'Bat ${batTemp.toInt()}°'
                  : 'Bat —',
              style: TextStyle(
                  fontSize: statusFontSize,
                  fontWeight: FontWeight.w400,
                  color: Colors.white70)),
          SizedBox(width: compact ? 12 : 24),
          Icon(Icons.device_thermostat,
              size: iconSize, color: Colors.deepOrangeAccent),
          SizedBox(width: compact ? 3 : 4),
          Text(
              pdu1 != null && pdu2 != null
                  ? 'PDU ${pdu1.toInt()}°/${pdu2.toInt()}°'
                  : pdu1 != null
                      ? 'PDU ${pdu1.toInt()}°/—'
                      : 'PDU —',
              style: TextStyle(
                  fontSize: statusFontSize,
                  fontWeight: FontWeight.w400,
                  color: Colors.white70)),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SPEED',
                style: TextStyle(
                    fontSize: compact ? 10 : 12,
                    letterSpacing: compact ? 1.0 : 1.5,
                    color: Colors.grey)),
            SizedBox(height: compact ? 2 : 4),
            // Compact mode runs inside an unbounded-height ListView
            // (via SizedBox parent). Expanded() would assert. In wide
            // mode the outer Expanded(flex: 3) gives us bounded height
            // and Expanded(child: speedRow) here lets the FittedBox
            // grow into available vertical room.
            if (compact) speedRow else Expanded(child: speedRow),
            const SizedBox(height: 8),
            statusRow,
          ],
        ),
      ),
    );
  }
}

/// Trip metrics: 6 cells (distance, energy, consumption, duration,
/// peak speed, avg moving) + a "TRIP COST" header on the right when
/// cost settings are configured.
class TripMetricsPanel extends StatelessWidget {
  /// `true` → BZ3 tall portrait sizing. See file header.
  final bool compact;
  const TripMetricsPanel({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.27: watch cost settings so the cost cell rebuilds when the
    // user edits the tariff or currency.
    final cost = context.watch<CostSettings>();

    final dist = svc.tripDistanceKm;
    // v0.1.24: precise-SOC-based energy/consumption (1FFD-derived) so
    // values update each poll cycle smoothly. Integer SOC versions
    // step in 0.65 kWh chunks which made short trips look frozen.
    final energyUsed = svc.tripEnergyUsedPreciseKwh;
    final consumption = svc.tripAvgConsumptionPreciseKwh100km;
    final dur = svc.tripDuration;
    final peakKmh = svc.tripPeakSpeedKmh;
    final avgMovingKmh = svc.tripCurrentAvgMovingKmh;

    // First 2 min: consumption hidden (too noisy).
    final tripAgeSec = dur?.inSeconds ?? 0;

    // v0.1.27: cost only shown when tariff configured AND we have a
    // precise-SOC-derived energy figure. Hidden during the first few
    // poll cycles after trip start before the integration window
    // establishes itself.
    final showCost = cost.isConfigured && energyUsed != null;
    final tripCostStr = showCost
        ? cost.formatAmount(energyUsed * cost.costPerKwh)
        : null;

    final cellFontSize = compact ? 22.0 : 36.0;
    final labelFontSize = compact ? 9.0 : 11.0;
    final unitFontSize = compact ? 11.0 : 14.0;
    final padding = compact
        ? const EdgeInsets.fromLTRB(14, 10, 14, 10)
        : const EdgeInsets.fromLTRB(20, 14, 20, 14);

    final row1 = Row(
      children: [
        Expanded(
          child: TripCell(
              value: dist != null ? dist.toStringAsFixed(1) : '—',
              unit: 'km',
              label: 'distance',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize),
        ),
        Expanded(
          child: TripCell(
              value: energyUsed != null
                  ? energyUsed.toStringAsFixed(2)
                  : '—',
              unit: 'kWh',
              label: 'energy used',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize),
        ),
        Expanded(
          child: TripCell(
              value: tripAgeSec < 120
                  ? '—'
                  : (consumption != null
                      ? consumption.toStringAsFixed(1)
                      : '—'),
              unit: tripAgeSec < 120 ? 'calculating…' : 'kWh/100km',
              label: 'consumption',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize,
              isCalculating: tripAgeSec < 120,
              // v0.1.25: efficiency-band colour skipped during the
              // first 2 min "calculating…" window so the user doesn't
              // see a flashing red number from early-trip noise.
              valueColor: tripAgeSec < 120 || consumption == null
                  ? null
                  : consumptionColor(consumption)),
        ),
      ],
    );

    final row2 = Row(
      children: [
        Expanded(
          child: TripCell(
              value: dur != null ? _fmtDur(dur) : '—',
              unit: '',
              label: 'duration',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize),
        ),
        Expanded(
          child: TripCell(
              value: peakKmh != null
                  ? peakKmh.toStringAsFixed(0)
                  : '—',
              unit: 'km/h',
              label: 'peak speed',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize),
        ),
        Expanded(
          child: TripCell(
              value: avgMovingKmh != null
                  ? avgMovingKmh.toStringAsFixed(0)
                  : '—',
              unit: 'km/h',
              label: 'avg moving',
              valueFontSize: cellFontSize,
              labelFontSize: labelFontSize,
              unitFontSize: unitFontSize),
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.timeline,
                    size: compact ? 12 : 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text('THIS TRIP',
                    style: TextStyle(
                        fontSize: compact ? 10 : 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
                const SizedBox(width: 10),
                Text('#${svc.currentTripId ?? "—"}',
                    style: TextStyle(
                        fontSize: compact ? 10 : 11, color: Colors.grey)),
                const Spacer(),
                if (tripCostStr != null) ...[
                  Text('TRIP COST',
                      style: TextStyle(
                          fontSize: compact ? 9 : 10,
                          letterSpacing: 1.2,
                          color: Colors.grey)),
                  const SizedBox(width: 8),
                  Text(
                    tripCostStr,
                    style: TextStyle(
                      fontSize: compact ? 18 : 22,
                      fontWeight: FontWeight.w500,
                      color: Colors.amberAccent,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            if (compact) row1 else Expanded(child: row1),
            Divider(height: compact ? 10 : 16, color: Colors.white12),
            if (compact) row2 else Expanded(child: row2),
          ],
        ),
      ),
    );
  }

  static String _fmtDur(Duration d) {
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}

/// Single trip metric cell — big number + small unit + label below.
/// Font sizes parametrised so the same widget serves both layouts.
class TripCell extends StatelessWidget {
  final String value;
  final String unit;
  final String label;
  final bool isCalculating;
  /// Optional override for the value text colour. When null, defaults
  /// to white (or grey while calculating). Used by consumption cell to
  /// colour by efficiency band — see [consumptionColor].
  final Color? valueColor;
  final double valueFontSize;
  final double labelFontSize;
  final double unitFontSize;
  const TripCell({
    super.key,
    required this.value,
    required this.unit,
    required this.label,
    this.isCalculating = false,
    this.valueColor,
    this.valueFontSize = 36,
    this.labelFontSize = 11,
    this.unitFontSize = 14,
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
                      // During "calculating…" the number itself is "—"
                      // so we shrink it relative to its normal size to
                      // de-emphasise (the unit "calculating…" already
                      // conveys the state).
                      fontSize: isCalculating
                          ? valueFontSize * 0.62
                          : valueFontSize,
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
                          fontSize: unitFontSize,
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
            style: TextStyle(
                fontSize: labelFontSize,
                letterSpacing: 0.5,
                color: Colors.grey)),
      ],
    );
  }
}

/// v0.1.25: efficiency-band colour for consumption (kWh/100km).
/// Calibrated against BZ5's 65.28 kWh LFP pack and our mixed city /
/// trasse data:
///
///   < 13   → excellent (greenAccent) — pure eco crawl or steep regen
///   13–17  → typical (white)         — most mixed city/highway driving
///   17–22  → spirited (yellowAccent) — hard accel, cold, or strong wind
///   > 22   → poor (orangeAccent)     — climate-on or aggressive city
///
/// The thresholds align with our anchor: 16.7 kWh/100km on the 32 km
/// mixed-city trip on 2026-05-19, which felt normal — so 17 is the
/// lower bound of "spirited".
Color consumptionColor(double kwh100km) {
  if (kwh100km < 13) return Colors.greenAccent;
  if (kwh100km < 17) return Colors.white;
  if (kwh100km < 22) return Colors.yellowAccent;
  return Colors.orangeAccent;
}
