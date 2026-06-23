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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/cost_settings.dart';
import '../services/hal_telemetry_service.dart';

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
    // v0.1.29+64/+66: HAL overlapping. The displayed speedo and Pack V
    // prefer HAL when its stream is live & fresh and the source mode
    // permits it; otherwise each falls back to OBD2 independently. The
    // swap is invisible (same gauge, same strip). vehicleSpeedKmh (and
    // trip aggregates) stay pure OBD2 — see HalTelemetryService.
    final hal = context.watch<HalTelemetryService>();
    // v0.1.24: display speed = true wheel speed × 1.05 if user enabled
    // the "match speedometer" toggle in Settings; else raw true speed.
    final bool usingHal = hal.useHalForSpeed;
    final double? rawSpeed =
        usingHal ? hal.halSpeedKmh : svc.vehicleSpeedKmh;
    final double speed = rawSpeed == null
        ? 0.0
        : (svc.matchSpeedometer ? rawSpeed * 1.05 : rawSpeed);
    // Pack V: HAL pack_voltage is a direct measurement off the charging
    // device (445–454 V live-verified 2026-06-11) — preferred over the
    // OBD2 sum-of-cells reconstruction when fresh.
    final packFromCells = hal.useHalForPackV
        ? hal.halPackVoltage
        : svc.packVoltageFromCells;
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

    // v0.1.29+78: brake-light indicator. The real stop-lamp state
    // (0x33100012) is UNREACHABLE for our uid (recon p086: class_not_found
    // + permission not granted + binder null), so this is DERIVED, not the
    // lamp wire. HalTelemetryService.brakeRegenActive encapsulates the
    // rule: motor_torque < −50 Nm AND pack_current < −60 A (charging) —
    // both required so it tracks "braking hard enough on regen that the
    // stop lamps are lit per ECE R13H" without twitching at the coast/regen
    // boundary. HAL-only by nature: in OBD2-only mode neither signal is
    // available so the bar never appears (honest); a stale HAL stream also
    // clears it rather than freezing it red.
    final bool brakeRegenActive = hal.brakeRegenActive;
    // Fixed-height slot so the bar never shifts the speed/status layout;
    // only its opacity animates between hidden and lit.
    final double barSlotHeight = compact ? 4.0 : 6.0;
    final brakeBar = SizedBox(
      height: barSlotHeight,
      child: AnimatedOpacity(
        opacity: brakeRegenActive ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFF3B30),
            borderRadius: BorderRadius.circular(barSlotHeight / 2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80FF3B30),
                blurRadius: 8,
                spreadRadius: 0.5,
              ),
            ],
          ),
        ),
      ),
    );

    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('drv.speed'),
                style: TextStyle(
                    fontSize: compact ? 10 : 12,
                    letterSpacing: compact ? 1.0 : 1.5,
                    color: Colors.grey)),
            // v0.1.29+66: the temporary +64 HAL·OBD2 dual-readout is gone —
            // HAL speed was confirmed against both OBD2 and the cluster on
            // live drives (tracks the cluster, 1–3 km/h truer than OBD2).
            // Source comparison now lives where it belongs: HAL Test.
            SizedBox(height: compact ? 2 : 4),
            // Compact mode runs inside an unbounded-height ListView
            // (via SizedBox parent). Expanded() would assert. In wide
            // mode the outer Expanded(flex: 3) gives us bounded height
            // and Expanded(child: speedRow) here lets the FittedBox
            // grow into available vertical room.
            if (compact) speedRow else Expanded(child: speedRow),
            // v0.1.29+78: red regen-brake bar, directly under the speed.
            const SizedBox(height: 6),
            brakeBar,
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
    // v0.1.29+60: while a trip is active but no movement happened yet,
    // tripDistanceKm is still null — show an honest 0.0 instead of a
    // floating dash (owner field photo: '— km' looked broken).
    final distStr = dist != null
        ? dist.toStringAsFixed(1)
        : (svc.currentTripId != null ? '0.0' : '—');
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

    // v0.1.29+13: compact font bumps per BZ3 owner field feedback
    // ("очень мелкий шрифт"). cellFontSize stays at 22 — the big
    // numbers were readable. labels and units bumped:
    //   labelFontSize 9  → 11 ("distance", "consumption", "avg moving")
    //   unitFontSize  11 → 13 ("km", "kWh", "km/h", "calculating…")
    // Wide (non-compact) sizes unchanged.
    final cellFontSize = compact ? 22.0 : 36.0;
    final labelFontSize = compact ? 11.0 : 11.0;
    final unitFontSize = compact ? 13.0 : 14.0;
    final padding = compact
        ? const EdgeInsets.fromLTRB(14, 10, 14, 10)
        : const EdgeInsets.fromLTRB(20, 14, 20, 14);

    final row1 = Row(
      children: [
        Expanded(
          child: TripCell(
              value: distStr,
              unit: 'km',
              label: S.of('drv.cell.distance'),
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
              label: S.of('drv.cell.energy'),
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
              unit: tripAgeSec < 120 ? S.of('drv.calculating') : 'kWh/100km',
              label: S.of('drv.cell.consumption'),
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
              label: S.of('drv.cell.duration'),
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
              label: S.of('drv.cell.peak'),
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
              label: S.of('drv.cell.avg_moving'),
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
                Text(S.of('drv.this_trip'),
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
                  Text(S.of('drv.trip_cost'),
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
            // v0.1.29+16: on compact mode (BZ3 tall portrait) row1
            // and row2 use Expanded too — earlier they were natural-
            // sized and visually overlapped with only a 10dp Divider
            // between them. Inside a bounded SizedBox(height: 200)
            // parent from dashboard.dart, Expanded distributes the
            // remaining vertical space equally between rows, giving
            // ~80dp per row with the divider acting as a clear
            // separator. Wide mode (driver_view_wide.dart) already
            // had Expanded — unchanged.
            Expanded(child: row1),
            Divider(height: compact ? 16 : 16, color: Colors.white24),
            Expanded(child: row2),
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
          // v0.1.29+60: value + unit sit on a shared text BASELINE.
          // The previous CrossAxisAlignment.end + Padding(bottom: 6)
          // hack approximated baseline alignment for normal digits but
          // fell apart when value == '—': the em-dash glyph floats at
          // mid x-height of a 36px line while the 14px unit hugged the
          // bottom, reading as two misaligned lines with a hole under
          // them (owner field photo, BZ5 driver view). True baseline
          // alignment is correct for every glyph, digit or dash, in
          // both wide and compact modes.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
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
                Text(unit,
                    style: TextStyle(
                        fontSize: unitFontSize,
                        color: isCalculating
                            ? Colors.grey.shade600
                            : Colors.grey,
                        fontStyle: isCalculating
                            ? FontStyle.italic
                            : FontStyle.normal)),
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

/// v0.1.29+75: HAL-exclusive drive panel — the right half of the driver
/// middle band when the source is pinned to HAL (halOnly). Shows HAL-only
/// drive-side data that has no place in the OBD2 trip panel:
///
///   trip A · trip B        (cluster trip meters, HAL-only)
///   motor rpm · torque     (BYDAutoEngineDevice)
///   motor power            (BYDAutoEngineDevice, signed kW)
///   motor temp · inverter  (distinct drive-side sensors, promoted +72)
///
/// Layout (v0.1.29+77): a COMPACT 3-COLUMN × 3-ROW grid of stacked cells
/// (value on top, small label under). History: +75 used four Expanded
/// TripCell rows — in the narrow split half each row got ~half the height
/// it needed and bottom labels overlapped the next value's row ("дизайн
/// секции поехал"). +76 switched to content-sized 2-column cells (no
/// overlap) but seven signals made FOUR rows, and the real device band is
/// shorter than the nominal flex:3 (the power graph in the top zone eats
/// into it), so the bottom three values fell under a scroll. +77 drops to
/// THREE rows by going 3-wide (3+3+1) and shrinks the value font 24→18 dp
/// with tighter vertical padding, so all seven fit WITHOUT scrolling on
/// the 1280×800 head unit. Cells stay content-sized (no Expanded height),
/// so they still cannot overlap; the value uses a FittedBox so a long
/// number (e.g. trip B "2985.7") shrinks rather than pushing the layout,
/// and the label ellipsises if too wide for the ~80 dp column. The scroll
/// view is kept only as a last-resort guard (should never trigger now).
///
/// Honesty: a value held past its freshness window
/// (HalTelemetryService.isStale) is DIMMED rather than blanked — the panel
/// stays populated so HAL feels like a complete interface, but an ageing
/// reading is visibly greyed. A value with no held reading shows '—'.
///
/// Does NOT touch TripMetricsPanel (shared with the dashboard).
class HalExtrasPanel extends StatelessWidget {
  const HalExtrasPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final hal = context.watch<HalTelemetryService>();

    // (value text, dim) for a held HAL signal. value null → '—', not
    // dimmed (nothing held to age). Otherwise dim iff isStale(name).
    ({String text, bool dim}) v(
            String name, double? value, String Function(double) fmt) =>
        value == null
            ? (text: '—', dim: false)
            : (text: fmt(value), dim: hal.isStale(name));

    // One compact stacked cell: value·unit on top, label beneath. Content-
    // sized (the Column rows below do NOT stretch it), so cells can never
    // overlap however short the band is. Returned wrapped in Expanded so
    // the cells in a row share the half's width evenly. Fonts are sized for
    // the 3-wide grid (~80 dp columns): value 18, unit 10, label 10.
    Widget cell(
        String labelKey, ({String text, bool dim}) d, String unit) {
      final valueColor = d.dim ? Colors.grey.shade600 : Colors.white;
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(d.text,
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w300,
                          color: valueColor)),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: 2),
                    Text(unit,
                        style: TextStyle(
                            fontSize: 10,
                            color:
                                d.dim ? Colors.grey.shade700 : Colors.grey)),
                  ],
                ],
              ),
            ),
            Text(S.of(labelKey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10, color: Colors.grey, letterSpacing: 0.2)),
          ],
        ),
      );
    }

    // Build a row of up to three cells, padding empty trailing slots so
    // columns stay aligned. 10 dp gutter between columns.
    Widget gridRow(List<Widget> cells) {
      final slots = <Widget>[];
      for (var i = 0; i < 3; i++) {
        if (i > 0) slots.add(const SizedBox(width: 10));
        slots.add(i < cells.length
            ? cells[i]
            : const Expanded(child: SizedBox.shrink()));
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: slots,
        ),
      );
    }

    final tripA =
        cell('drv.cell.trip_a',
            v('trip_a', hal.halTripAKm, (x) => x.toStringAsFixed(1)), 'km');
    final tripB = cell('drv.cell.trip_b',
        v('trip_b', hal.halTripBKm, (x) => x.toStringAsFixed(1)), 'km');
    final rpm = cell('drv.cell.motor_rpm',
        v('motor_rpm', hal.halMotorRpm, (x) => x.toStringAsFixed(0)), 'rpm');
    final torque = cell(
        'drv.cell.motor_torque',
        v('motor_torque', hal.halMotorTorqueNm, (x) => x.toStringAsFixed(0)),
        'Nm');
    final mPower = cell(
        'drv.cell.motor_power',
        v('motor_power', hal.halMotorPowerKw, (x) => x.toStringAsFixed(0)),
        'kW');
    final motorTemp = cell('drv.cell.motor_temp',
        v('motor_temp', hal.halMotorTempC, (x) => x.toStringAsFixed(0)), '°C');
    final invTemp = cell(
        'drv.cell.inverter_temp',
        v('inverter_temp', hal.halInverterTempC,
            (x) => x.toStringAsFixed(0)),
        '°C');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.electric_bolt, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text(S.of('drv.hal_extras'),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 4),
            // Scroll guard: if the band is ever shorter than the rows, the
            // grid scrolls instead of overflowing/overlapping.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    gridRow([tripA, tripB, rpm]),
                    const Divider(height: 1, color: Colors.white12),
                    gridRow([torque, mPower, motorTemp]),
                    const Divider(height: 1, color: Colors.white12),
                    gridRow([invTemp]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
