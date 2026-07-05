import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../data/trip_extra.dart';
import '../l10n/strings.dart';
import '../services/locale_service.dart';
import '../services/connection.dart';
import '../services/cost_settings.dart';

/// v0.1.9: Trip detail screen.
///
/// Shows full Trip info + per-DID charts built from Samples in this trip.
/// Charts: SOC vs time, battery temp vs time, cell spread vs time.
/// For active trips, refreshes automatically from svc updates.
class TripDetailScreen extends StatefulWidget {
  final int tripId;
  const TripDetailScreen({super.key, required this.tripId});

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
            S.of('trip.title').replaceFirst('{id}', '${widget.tripId}')),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: FutureBuilder<Trip?>(
        future: svc.db.getTrip(widget.tripId),
        builder: (context, tripSnap) {
          if (!tripSnap.hasData || tripSnap.data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final trip = tripSnap.data!;
          // v0.1.25+2: responsive 2-column layout on wide screens (head
          // display ≥840dp). Compact cards (summary, metrics, odometer,
          // donut, small charts) pair up in Row; wide-aspect cards
          // (speed histogram, SOC vs time) stay full width.
          //
          // Phone layout (<840dp) unchanged — single vertical ListView.
          // The LayoutBuilder picks layout based on actual available
          // width inside the IndexedStack content area, so behaviour is
          // identical whether opened from phone, rotated landscape phone,
          // or BZ5 15.6" head display.
          return LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 840;
              return isWide
                  ? _buildWideLayout(trip, svc)
                  : _buildNarrowLayout(trip, svc);
            },
          );
        },
      ),
    );
  }

  /// Single-column layout for phone and narrow contexts.
  /// Preserves exact pre-v0.1.25+2 behaviour for phone users.
  Widget _buildNarrowLayout(Trip trip, ConnectionService svc) {
    return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              TripSummaryCard(trip: trip, svc: svc),
              const SizedBox(height: 12),
              DerivedMetricsCard(trip: trip),
              const SizedBox(height: 12),
              // v0.1.25: Tesla-style trip stats panel — speed histogram,
              // odometer range, moving/idle breakdown. Visualises data
              // we already collect, sits between metrics and charts so
              // a user scrolling sees overview → distribution → curves.
              OdometerRangeCard(trip: trip),
              const SizedBox(height: 12),
              MovingIdleDonutCard(trip: trip),
              const SizedBox(height: 12),
              SpeedHistogramCard(tripId: trip.id, trip: trip),
              const SizedBox(height: 12),
              // v0.1.24: SOC chart switched from integer 0x0005 (which
              // steps in 1% chunks and looks jagged on short trips) to
              // precise 1FFD (high16/100, 0.01% resolution). Registry
              // decoder for 1FFD already returns the float percentage,
              // so no valueTransform needed.
              _ChartCard(
                title: S.of('trip.soc_vs_time'),
                tripId: trip.id,
                ecuTx: '790',
                did: '1FFD',
                halName: 'soc_precise|soc_display',
                snapshotField: 'soc',
                color: Colors.greenAccent,
                unit: '%',
                svc: svc,
              ),
              const SizedBox(height: 12),
              _ChartCard(
                title: S.of('trip.battery_temp'),
                tripId: trip.id,
                ecuTx: '790',
                did: '002F',
                halName: 'probe_highest_temp|battery_temp_bigdata',
                snapshotField: 'batteryTempC',
                color: Colors.orangeAccent,
                unit: '°C',
                // v0.1.26+9: NO valueTransform — the registry decoder for
                // 790/0x002F already applies offset -40, so numeric_value
                // in the samples table is already °C. Doing v-40 again
                // here was a double-offset bug that displayed batteries
                // sitting at ~18°C as ~-22°C with axis labels -24..-19
                // (matched user screenshot of trip 13 detail view).
                // Same fix mirrors _updateTripAggregates which figured
                // this out for trip min/max temp back in v0.1.10.
                svc: svc,
              ),
              const SizedBox(height: 12),
              _ChartCard(
                title: S.of('trip.pack_v_filtered'),
                tripId: trip.id,
                ecuTx: '740',
                did: '0022',
                halName: 'pack_voltage',
                snapshotField: 'packVoltageV',
                color: Colors.yellowAccent,
                unit: 'V',
                // No valueTransform — registry decoder already applies scale 0.025
                // (per v0.1.9 hotfix 2026-05-17). Values in Sample.numericValue
                // are already in volts.
                svc: svc,
              ),
              const SizedBox(height: 12),
              // v0.1.29+128: snapshot-only chart — appears only when the
              // trip's snapshot window recorded charging power (carries
              // its own bottom gap, zero footprint when hidden).
              _ChartCard(
                title: S.of('trip.charging_power'),
                tripId: trip.id,
                snapshotField: 'chargingPowerKw',
                hideWhenEmpty: true,
                color: Colors.cyanAccent,
                unit: 'kW',
                svc: svc,
              ),
              _PowerBarCard(trip: trip, svc: svc),
            ],
          );
  }

  /// v0.1.25+2: 2-column layout for wide screens (head display, landscape
  /// tablet). Stacking strategy:
  ///   Row 1:  Summary  |  Derived Metrics       — overview side-by-side
  ///   Row 2:  Odometer |  Time Breakdown donut  — compact stat cards
  ///   Row 3:  Speed Histogram (full width)      — needs horizontal room
  ///   Row 4:  SOC chart (full width)            — primary timeline chart
  ///   Row 5:  Battery temp | Pack voltage       — paired auxiliary charts
  ///   Row 6:  HV bus (full width)               — odd-one-out
  ///
  /// crossAxisAlignment: stretch on Row so cards in a pair end up the
  /// same height — looks cleaner than ragged-bottom card edges.
  Widget _buildWideLayout(Trip trip, ConnectionService svc) {
    Widget pair(Widget left, Widget right) => IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: left),
              const SizedBox(width: 12),
              Expanded(child: right),
            ],
          ),
        );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        pair(
          TripSummaryCard(trip: trip, svc: svc),
          DerivedMetricsCard(trip: trip),
        ),
        const SizedBox(height: 12),
        pair(
          OdometerRangeCard(trip: trip),
          MovingIdleDonutCard(trip: trip),
        ),
        const SizedBox(height: 12),
        SpeedHistogramCard(tripId: trip.id, trip: trip),
        const SizedBox(height: 12),
        _ChartCard(
          title: S.of('trip.soc_vs_time'),
          tripId: trip.id,
          ecuTx: '790',
          did: '1FFD',
          halName: 'soc_precise|soc_display',
          snapshotField: 'soc',
          color: Colors.greenAccent,
          unit: '%',
          svc: svc,
        ),
        const SizedBox(height: 12),
        pair(
          _ChartCard(
            title: S.of('trip.battery_temp'),
            tripId: trip.id,
            ecuTx: '790',
            did: '002F',
            halName: 'probe_highest_temp|battery_temp_bigdata',
            snapshotField: 'batteryTempC',
            color: Colors.orangeAccent,
            unit: '°C',
            // v0.1.26+9: see narrow-layout comment — registry already
            // applies offset -40, doing it again here was a double-offset.
            svc: svc,
          ),
          _ChartCard(
            title: S.of('trip.pack_v_filtered'),
            tripId: trip.id,
            ecuTx: '740',
            did: '0022',
            halName: 'pack_voltage',
            snapshotField: 'packVoltageV',
            color: Colors.yellowAccent,
            unit: 'V',
            svc: svc,
          ),
        ),
        const SizedBox(height: 12),
        // v0.1.29+128: snapshot-only charging-power chart (see the
        // narrow-layout comment). Zero footprint when hidden.
        _ChartCard(
          title: S.of('trip.charging_power'),
          tripId: trip.id,
          snapshotField: 'chargingPowerKw',
          hideWhenEmpty: true,
          color: Colors.cyanAccent,
          unit: 'kW',
          svc: svc,
        ),
        _PowerBarCard(trip: trip, svc: svc),
      ],
    );
  }
}

class TripSummaryCard extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const TripSummaryCard({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final isActive = trip.endedAt == null;
    final duration = (trip.endedAt ?? DateTime.now()).difference(trip.startedAt);
    final dateStr = DateFormat('d MMMM y, HH:mm').format(trip.startedAt);

    return Card(
      color: isActive
          ? Colors.green.shade900.withValues(alpha: 0.25)
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (isActive) ...[
                  Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('ACTIVE',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.greenAccent)),
                ] else ...[
                  const Icon(Icons.history, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(S.of('trip.completed'),
                      style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.grey)),
                ],
                const Spacer(),
                Text('#${trip.id}',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Text(dateStr,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(
              _fmtDuration(duration) +
                  (isActive
                      ? S.of('trip.running_suffix')
                      : S.of('trip.total_suffix')),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            if (trip.notes != null) ...[
              const SizedBox(height: 8),
              Text(trip.notes!,
                  style: const TextStyle(
                      fontSize: 12, fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
    );
  }
}

class DerivedMetricsCard extends StatelessWidget {
  final Trip trip;
  const DerivedMetricsCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    // v0.1.27: watch cost settings so the Total cost row rebuilds
    // reactively when the user edits cost_per_kwh in Settings.
    final cost = context.watch<CostSettings>();
    // v0.1.29+91: wall-clock trip duration for the overall-average-speed row.
    final tripDuration =
        (trip.endedAt ?? DateTime.now()).difference(trip.startedAt);

    final dist = trip.distanceKm ??
        ((trip.endOdometer != null && trip.startOdometer != null)
            ? (trip.endOdometer! - trip.startOdometer!)
            : null);
    final socUsed = (trip.endSoc != null && trip.startSoc != null)
        ? (trip.startSoc! - trip.endSoc!)
        : null;

    // v0.1.27: trip cost — only included when cost_per_kwh is
    // configured AND we have an energy figure to multiply by.
    final double? totalCost =
        (cost.isConfigured && trip.energyUsedKwh != null)
            ? trip.energyUsedKwh! * cost.costPerKwh
            : null;

    final rows = <Widget>[
      _MetricRow(S.of('trip.m_distance'),
          dist != null ? '${dist.toStringAsFixed(2)} km' : '—'),
      _MetricRow(S.of('trip.m_energy_used'),
          trip.energyUsedKwh != null
              ? '${trip.energyUsedKwh!.toStringAsFixed(2)} kWh'
              : '—'),
      // v0.1.27: Total cost row. Hidden when tariff is not configured
      // (showing "Total cost: —" would just be noise; users who
      // haven't set cost/kWh don't care about cost). Placed right
      // after Energy used because conceptually they're the same
      // metric in two units (kWh vs currency).
      if (totalCost != null)
        _MetricRow(S.of('trip.m_total_cost'), cost.formatAmount(totalCost)),
      _MetricRow(S.of('trip.m_avg_cons'),
          trip.avgConsumptionKwh100km != null
              ? '${trip.avgConsumptionKwh100km!.toStringAsFixed(1)} kWh/100km'
              : '—'),
      _MetricRow('SOC',
          (trip.startSoc != null && trip.endSoc != null)
              ? '${trip.startSoc!.toStringAsFixed(0)}% → ${trip.endSoc!.toStringAsFixed(0)}%'
                  '${socUsed != null && socUsed > 0 ? ' (-${socUsed.toStringAsFixed(0)}%)' : ''}'
              : '—'),
      _MetricRow(S.of('trip.m_soc_range'),
          (trip.minSoc != null && trip.maxSoc != null)
              ? '${trip.minSoc!.toStringAsFixed(0)}–${trip.maxSoc!.toStringAsFixed(0)}%'
              : '—'),
      _MetricRow(S.of('trip.m_temp_range'),
          (trip.minBatteryTempC != null && trip.maxBatteryTempC != null)
              ? '${trip.minBatteryTempC!.toStringAsFixed(1)}–${trip.maxBatteryTempC!.toStringAsFixed(1)} °C'
              : '—'),
      _MetricRow(S.of('trip.m_cell_spread'),
          trip.maxCellSpreadMv != null
              ? '${trip.maxCellSpreadMv!.toStringAsFixed(0)} mV'
              : '—'),
      // v0.1.27: removed Peak power / Peak regen rows and their
      // italic explanatory note. Peak power was an HV-bus-sag
      // heuristic with ±20-30% accuracy; Peak regen had no
      // identified DID at all. Showing rough/missing values gives a
      // false sense of precision in what's otherwise a well-derived
      // metrics card. They'll come back when the underlying DID is
      // identified (currently being calibrated through Native
      // Explorer + future bz5-bridge calibration sessions).
      // v0.1.22: peak speed now actually populated (740/0x0008 verified).
      // Remove the "DID not identified" placeholder when value present.
      _MetricRow(S.of('trip.m_peak_speed'),
          trip.peakSpeedKmh != null
              ? '${trip.peakSpeedKmh!.toStringAsFixed(0)} km/h'
              : '—'),
      // v0.1.22 / v0.1.29+91: overall average speed INCLUDING stops, computed
      // from the stored distance and wall-clock duration (distance ÷ elapsed).
      // The moving-only average (avgMovingSpeedKmh column) is no longer shown
      // here — the moving/idle split below already conveys time-in-motion.
      _MetricRow(S.of('trip.m_avg_speed'),
          (trip.distanceKm != null &&
                  trip.distanceKm! > 0 &&
                  tripDuration.inSeconds > 0)
              ? '${(trip.distanceKm! / tripDuration.inSeconds * 3600.0).toStringAsFixed(0)} km/h'
              : '—'),
      _MetricRow(S.of('trip.m_time_moving'),
          (trip.movingSeconds != null || trip.idleSeconds != null)
              ? '${_fmtDur(trip.movingSeconds)} / ${_fmtDur(trip.idleSeconds)}'
              : '—'),
      // Energy from precise SOC: independent of integer-SOC-based
      // energyUsedKwh above. When both present, comparing the two gives
      // an idea of measurement noise (typically ±5%).
      _MetricRow(S.of('trip.m_energy_precise'),
          trip.energyFromSocKwh != null
              ? '${trip.energyFromSocKwh!.toStringAsFixed(2)} kWh'
              : '—'),
      _MetricRow(S.of('trip.m_samples'), '${trip.sampleCount}'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('trip.metrics_hdr'),
                style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }
}

/// v0.1.25: simple odometer From → To card.
///
/// Tesla-style "51320 — 51332 km" display showing the bookend odometer
/// values of the trip. Complements the existing "Distance" metric (which
/// is the delta) by exposing the absolute readings — useful for sanity-
/// checking that the trip's odo readings make sense, and for users who
/// want to cross-reference with the car's own trip-meter.
class OdometerRangeCard extends StatelessWidget {
  final Trip trip;
  const OdometerRangeCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final start = trip.startOdometer;
    final end = trip.endOdometer;
    final delta = (start != null && end != null) ? end - start : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.speed_outlined, color: Colors.lightBlueAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('trip.odometer_hdr'),
                      style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.2,
                          color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(
                    start != null && end != null
                        ? '${start.toStringAsFixed(1)} — ${end.toStringAsFixed(1)} km'
                        : '—',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w400),
                  ),
                  if (delta != null) ...[
                    const SizedBox(height: 2),
                    Text('Δ ${delta.toStringAsFixed(2)} km',
                        style: const TextStyle(
                            fontSize: 13, color: Colors.grey)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.1.25: donut chart showing moving vs idle time breakdown.
///
/// Renders a SVG-like circular ring (via two Stack'd CircularProgress
/// indicators) sized to the proportion of moving vs idle seconds.
/// "Idle" here means: ignition Ready but speed ≤ 1 km/h (red lights,
/// traffic, drive-thru). "Moving" is everything > 1 km/h.
///
/// Useful for understanding trip character: a 30-min trip with 20 min
/// moving + 10 min idle reads very differently from a pure highway
/// 30-min trip with 1 min idle.
class MovingIdleDonutCard extends StatelessWidget {
  final Trip trip;
  const MovingIdleDonutCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final mov = trip.movingSeconds;
    final idle = trip.idleSeconds;

    if (mov == null && idle == null) {
      // No data yet — hide instead of showing an empty card.
      return const SizedBox.shrink();
    }

    final movSec = mov ?? 0;
    final idleSec = idle ?? 0;
    final total = movSec + idleSec;
    final movFrac = total > 0 ? movSec / total : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Donut: outer ring = moving (green), inner gap = idle (orange)
            SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Background ring (idle portion shown via what's NOT covered)
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      value: 1.0,
                      strokeWidth: 8,
                      valueColor:
                          AlwaysStoppedAnimation(Colors.orangeAccent.shade200),
                    ),
                  ),
                  // Moving overlay
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: CircularProgressIndicator(
                      value: movFrac,
                      strokeWidth: 8,
                      valueColor:
                          const AlwaysStoppedAnimation(Colors.greenAccent),
                    ),
                  ),
                  Text(
                    '${(movFrac * 100).round()}%',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('trip.time_breakdown'),
                      style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.2,
                          color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: const BoxDecoration(
                          color: Colors.greenAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                          S
                              .of('trip.moving_fmt')
                              .replaceFirst('{d}', _fmtDur(movSec)),
                          style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.shade200,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                          S
                              .of('trip.idle_fmt')
                              .replaceFirst('{d}', _fmtDur(idleSec)),
                          style: const TextStyle(fontSize: 14)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.1.25: speed histogram for the trip — Tesla-style bar chart.
///
/// Queries the speed samples (740/0x0008) for the trip from DB and bins
/// them into 10 km/h buckets (0-9, 10-19, ..., 140-149). The dominant
/// bucket gets red, neighbouring high-traffic ones get yellow, low-time
/// ones stay green. Quick visual: "where did this trip happen"?
///
/// Excluded: speed = 0 (stopped/idle) — those are in the donut card.
class SpeedHistogramCard extends StatefulWidget {
  final int tripId;
  // v0.1.29+37: the trip row, when available, carries `extra` — a
  // precomputed speed histogram used as a fallback when raw samples are
  // gone (e.g. after a cloud restore). Optional so existing call sites
  // that only have a tripId keep compiling; without it the card behaves
  // exactly as before (samples-only).
  final Trip? trip;
  const SpeedHistogramCard({required this.tripId, this.trip});

  @override
  State<SpeedHistogramCard> createState() => SpeedHistogramCardState();
}

class SpeedHistogramCardState extends State<SpeedHistogramCard> {
  // v0.1.29+93: raw speed VALUES (km/h), not OBD2 Sample rows, so the source
  // can be either the OBD2 `samples` 740/0008 series OR — for a HAL trip
  // (head unit, no dongle) that never wrote 740/0008 — the hal_samples
  // name='speed' series. The histogram is built from values alone, so it
  // doesn't care which table they came from.
  late Future<List<double?>> _samples;

  // v0.1.29+114: while the shown trip is still ACTIVE, refresh the speed
  // values every few seconds. +111 made the active trip auto-select the
  // instant it appears — at which point it has zero 740/0008 (or HAL speed)
  // rows, so the histogram cached "empty" and, because the tripId never
  // changed, didUpdateWidget never reloaded it: the distribution stayed
  // blank for the whole drive. A closed trip is immutable, so its data is
  // loaded exactly once (timer not armed / cancelled).
  Timer? _reload;

  bool get _tripActive => widget.trip == null || widget.trip!.endedAt == null;

  void _syncReload() {
    if (_tripActive && _reload == null) {
      _reload = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        setState(() => _samples = _loadSamples());
      });
    } else if (!_tripActive && _reload != null) {
      _reload!.cancel();
      _reload = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _samples = _loadSamples();
    _syncReload();
  }

  @override
  void dispose() {
    _reload?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SpeedHistogramCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // v0.1.26+16: when the parent (history_wide._SelectedTripDetail)
    // switches between trips, the widget gets a new `tripId` but the
    // State instance is reused. Without this hook the stale `_samples`
    // Future keeps resolving to the previously selected trip's data —
    // so the Speed Distribution chart kept showing samples from trip
    // 18:22 (29 min) even after the user selected the 1m 38s active
    // trip. Reload only when the actual id changed to avoid blowing
    // away an in-flight load on hot-reload or layout rebuilds.
    if (oldWidget.tripId != widget.tripId) {
      _samples = _loadSamples();
    }
    // v0.1.29+114: a switch to/from an active trip re-arms or cancels the
    // self-reload timer.
    _syncReload();
  }

  /// v0.1.29+93: speed values for the trip. Try the OBD2 740/0008 series
  /// first (dongle trips); if empty, fall back to the HAL speed series
  /// (hal_samples name='speed') so a HAL-only trip on the head unit also
  /// gets a distribution chart. Same physical quantity either way.
  Future<List<double?>> _loadSamples() async {
    final db = Provider.of<ConnectionService>(context, listen: false).db;
    final obd2 =
        await db.getSamplesForTrip(widget.tripId, ecuTx: '740', did: '0008');
    if (obd2.isNotEmpty) {
      return obd2.map((s) => s.numericValue).toList();
    }
    final hal = await db.getHalSpeedSamplesForTrip(widget.tripId);
    return hal.map((s) => s.numericValue).toList();
  }

  /// v0.1.29+30: when there are no 740/0008 speed samples, load a
  /// breakdown of what DID samples DID get recorded for this trip, so
  /// "No speed data" tells us WHY: was the whole trip un-sampled (then
  /// all counts are 0 → trip detection / polling issue), or just the
  /// PDU/740 path silent (then 790/* counts are non-zero but 740 is 0
  /// → PDU read path issue). Loaded lazily only on the empty branch.
  Future<Map<String, int>> _loadSampleBreakdown() async {
    final db = Provider.of<ConnectionService>(context, listen: false).db;
    final all = await db.getSamplesForTrip(widget.tripId);
    final byKey = <String, int>{};
    for (final s in all) {
      final key = '${s.ecuTx}/${s.did}';
      byKey[key] = (byKey[key] ?? 0) + 1;
    }
    return byKey;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('trip.speed_dist'),
                style: const TextStyle(
                    fontSize: 11, letterSpacing: 1.2, color: Colors.grey)),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: FutureBuilder<List<double?>>(
                future: _samples,
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final values = snap.data!;

                  // v0.1.29+37: resolve the histogram counts from raw
                  // samples when present, else fall back to the
                  // precomputed histogram in trip.extra (survives a
                  // cloud restore where samples are gone). Same 15×10km/h
                  // bins either way (shared binSpeed), so the chart is
                  // visually identical regardless of source.
                  // v0.1.29+93: `values` are raw speeds from EITHER the OBD2
                  // 740/0008 series or the HAL speed series — the builder
                  // doesn't care which.
                  const binSize = speedBinSize;
                  const binCount = speedBinCount;
                  List<int>? counts;
                  if (values.isNotEmpty) {
                    counts = buildSpeedHistogram(values);
                  } else {
                    final ex = TripExtra.parse(widget.trip?.extra);
                    if (ex.hasSpeedHistogram) {
                      counts = ex.speedHist;
                    }
                  }

                  if (counts == null) {
                    // No raw samples AND no restorable histogram → show
                    // the diagnostic breakdown (why is it empty?).
                    return Center(
                      child: FutureBuilder<Map<String, int>>(
                        future: _loadSampleBreakdown(),
                        builder: (c, bSnap) {
                          if (!bSnap.hasData) {
                            return Text(S.of('trip.no_speed_data'),
                                style: const TextStyle(color: Colors.grey));
                          }
                          final bd = bSnap.data!;
                          if (bd.isEmpty) {
                            return Text(
                                S.of('trip.no_samples'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey));
                          }
                          final has740 = bd.keys.any((k) => k.startsWith('740/'));
                          final lines = (bd.entries.toList()
                                ..sort((a, b) => b.value.compareTo(a.value)))
                              .take(6)
                              .map((e) => '${e.key}: ${e.value}')
                              .join('\n');
                          return Text(
                            'No 740/0008 speed samples'
                            '${has740 ? "" : " (PDU 740 silent all trip)"}.\n'
                            'Recorded DIDs:\n$lines',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 11),
                          );
                        },
                      ),
                    );
                  }

                  final total = counts.fold<int>(0, (a, b) => a + b);
                  // Non-nullable alias: counts is proven non-null above,
                  // but Dart won't promote a nullable through the closures
                  // below (getTitlesWidget / barGroups), so bind it here.
                  final List<int> bins = counts;
                  if (total == 0) {
                    return Center(
                      child: Text(
                        S.of('trip.all_idle'),
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  // Identify max bin and second-max for color hierarchy.
                  final maxCount = bins.reduce((a, b) => a > b ? a : b);
                  final percents =
                      bins.map((c) => 100.0 * c / total).toList();

                  // Find rightmost non-zero bin for clipping the X-axis
                  int rightmost = 0;
                  for (int i = 0; i < binCount; i++) {
                    if (bins[i] > 0) rightmost = i;
                  }
                  // At least show 0..70 km/h to keep chart proportions
                  // stable on short trips that never exceed urban speeds.
                  final visibleBins =
                      (rightmost + 1).clamp(7, binCount);

                  return BarChart(
                    BarChartData(
                      // v0.1.26+5: extra headroom on top so the in-axis
                      // value labels (from topTitles below) don't kiss the
                      // chart border.
                      maxY: percents.reduce((a, b) => a > b ? a : b) * 1.25,
                      barTouchData: BarTouchData(enabled: false),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        // v0.1.26+5: per-bar % label rendered ABOVE the
                        // bar (not as a tooltip overlay). The previous
                        // `showingTooltipIndicators` approach popped the
                        // raw fl_chart tooltip over each bar — at the
                        // chart's own scale that meant labels overlapped
                        // bars and showed raw double values like
                        // "44.44444444444". topTitles renders in the
                        // reserved axis strip above the plot, so labels
                        // never overlap bars.
                        topTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 20,
                            interval: 1,
                            getTitlesWidget: (v, _) {
                              final idx = v.toInt();
                              if (idx < 0 || idx >= visibleBins) {
                                return const SizedBox.shrink();
                              }
                              final pct = percents[idx];
                              // Drop tiny bars (<5%) to declutter — they
                              // were too small to be useful anyway.
                              if (pct < 5.0) return const SizedBox.shrink();
                              // Match label colour to bar colour so the
                              // value stays visually attached to its bar
                              // without an arrow / leader line.
                              Color labelColor;
                              if (bins[idx] >= maxCount * 0.8) {
                                labelColor = Colors.redAccent;
                              } else if (bins[idx] >= maxCount * 0.5) {
                                labelColor = Colors.yellowAccent.shade700;
                              } else {
                                labelColor = Colors.greenAccent.shade400;
                              }
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: Text(
                                  '${pct.toStringAsFixed(0)}%',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: labelColor,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        leftTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (v, _) {
                              final idx = v.toInt();
                              if (idx < 0 || idx >= visibleBins) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '${idx * binSize}',
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.grey),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: List.generate(visibleBins, (i) {
                        final pct = percents[i];
                        // Color hierarchy: dominant (>= 80% of max) red,
                        // strong (>= 50%) yellow, anything else green.
                        Color barColor;
                        if (bins[i] >= maxCount * 0.8) {
                          barColor = Colors.redAccent;
                        } else if (bins[i] >= maxCount * 0.5) {
                          barColor = Colors.yellowAccent.shade700;
                        } else {
                          barColor = Colors.greenAccent.shade400;
                        }
                        return BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: pct,
                              color: barColor,
                              // v0.1.26+16: thicker bars (was 14). On the
                              // BZ5 wide head-unit (~1400px chart area)
                              // 14px looked spindly and dwarfed by white
                              // space between bins; 26px reads as a proper
                              // bar chart. Still small enough that 14 bins
                              // (0-130 km/h) fit comfortably.
                              width: 26,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3)),
                            ),
                          ],
                        );
                      }),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            const Text('km/h',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetricRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final int tripId;
  // v0.1.29+128: nullable — a snapshot-only chart (charging power) has
  // no OBD2 series at all. All pre-existing call sites still pass both.
  final String? ecuTx;
  final String? did;
  final Color color;
  final String unit;
  final double Function(double)? valueTransform;
  final ConnectionService svc;
  /// v0.1.29+111: hal_samples fallback name(s) — see the wide _ChartCard
  /// twin in history_wide.dart for the long-form comment. '|' separates
  /// alternates tried in order; null → OBD2 only.
  final String? halName;
  /// v0.1.29+128: snapshot fallback — Snapshots column to chart when the
  /// trip has neither OBD2 nor hal_samples series (typical for a trip
  /// restored from cloud: samples are never uploaded, snapshots are).
  /// One of 'soc' | 'batteryTempC' | 'packVoltageV' | 'chargingPowerKw';
  /// null → no snapshot stage. Snapshot-sourced charts carry a source
  /// caption (~1/min cadence is visibly coarser than live samples).
  final String? snapshotField;
  /// v0.1.29+128: collapse to nothing instead of a "no data" card. Used
  /// by the charging-power chart, which only exists for trips whose
  /// snapshots actually recorded charging.
  final bool hideWhenEmpty;
  const _ChartCard({
    required this.title,
    required this.tripId,
    this.ecuTx,
    this.did,
    required this.color,
    required this.unit,
    required this.svc,
    this.valueTransform,
    this.halName,
    this.snapshotField,
    this.hideWhenEmpty = false,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<
        ({List<({DateTime ts, double? v})> pts, bool fromSnapshots})>(
      future: _loadPoints(),
      builder: (context, snap) {
        final data = snap.data;
        if (hideWhenEmpty && (data == null || data.pts.isEmpty)) {
          // Loading or genuinely absent — either way, no placeholder
          // frame (honesty rule: no widget without flowing data).
          return const SizedBox.shrink();
        }
        final card = Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(title.toUpperCase(),
                        style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: Colors.grey)),
                    // v0.1.29+128: source caption — only when the curve
                    // is built from snapshots, so live-sample charts look
                    // exactly as before.
                    if (data != null && data.fromSnapshots) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          S.of('trip.chart_src_snapshots'),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey.shade600),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 160,
                  child: data == null
                      ? const Center(
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : data.pts.isEmpty
                          ? Center(
                              child: Text(S.of('common.no_data'),
                                  style: TextStyle(
                                      color: Colors.grey.shade600,
                                      fontSize: 12)),
                            )
                          : _buildChart(data.pts),
                ),
              ],
            ),
          ),
        );
        // hideWhenEmpty charts are inserted without surrounding spacer
        // widgets (a hidden card must leave zero gap), so the visible
        // branch carries its own bottom margin.
        return hideWhenEmpty
            ? Padding(
                padding: const EdgeInsets.only(bottom: 12), child: card)
            : card;
      },
    );
  }

  /// v0.1.29+111: unified point loader — OBD2 first, hal_samples fallback
  /// for dongle-free trips. Twin of the loader in history_wide.dart.
  /// v0.1.29+128: third stage — snapshots by the trip's time window, for
  /// restored trips where both sample series are gone (never uploaded).
  Future<({List<({DateTime ts, double? v})> pts, bool fromSnapshots})>
      _loadPoints() async {
    final tx = ecuTx;
    final d = did;
    if (tx != null && d != null) {
      final obd = await svc.db.getSamplesForTrip(tripId, ecuTx: tx, did: d);
      if (obd.isNotEmpty) {
        return (
          pts: [for (final s in obd) (ts: s.timestamp, v: s.numericValue)],
          fromSnapshots: false
        );
      }
    }
    final names = halName;
    if (names != null) {
      for (final n in names.split('|')) {
        final hal = await svc.db.getHalSamplesForTripByName(tripId, n);
        if (hal.isNotEmpty) {
          return (
            pts: [
              for (final s in hal) (ts: s.timestamp, v: s.numericValue)
            ],
            fromSnapshots: false
          );
        }
      }
    }
    final field = snapshotField;
    if (field == null) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    final trip = await svc.db.getTrip(tripId);
    if (trip == null) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    // Time-window query, NOT snapshots.trip_id: restored snapshots keep
    // captured_at but their local FK linkage doesn't survive the wipe.
    final to = trip.endedAt ?? trip.lastAliveTs ?? DateTime.now();
    final snaps = await svc.db.getSnapshotsInRange(trip.startedAt, to);
    // chargingPowerKw is written as 0.0 (not NULL) whenever the car
    // isn't charging — verified against the snapshot writer in
    // connection.dart. Without this guard the charging chart would be
    // a flat zero line on EVERY trip and never hide. Real charging in
    // the window → keep the series whole (zero shoulders are the
    // honest curve shape); none → treat as "no data".
    if (field == 'chargingPowerKw') {
      final hasCharge = snaps.any((s) =>
          (s.isCharging ?? false) || ((s.chargingPowerKw ?? 0) > 0));
      if (!hasCharge) return (pts: const <({DateTime ts, double? v})>[], fromSnapshots: false);
    }
    final pts = <({DateTime ts, double? v})>[];
    for (final s in snaps) {
      final v = switch (field) {
        'soc' => s.soc,
        'batteryTempC' => s.batteryTempC,
        'packVoltageV' => s.packVoltageV,
        'chargingPowerKw' => s.chargingPowerKw,
        _ => null,
      };
      if (v != null) pts.add((ts: s.capturedAt, v: v));
    }
    return (pts: pts, fromSnapshots: pts.isNotEmpty);
  }

  Widget _buildChart(List<({DateTime ts, double? v})> samples) {
    final points = <FlSpot>[];
    final t0 = samples.first.ts;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final s in samples) {
      if (s.v == null) continue;
      final x = s.ts.difference(t0).inSeconds.toDouble();
      final y = valueTransform != null ? valueTransform!(s.v!) : s.v!;
      points.add(FlSpot(x, y));
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    // v0.1.29+113: one point is honest data for a slow event-driven
    // signal (battery temp sleeps at standstill). Duplicate it at the
    // last timestamp so fl_chart has a segment — a flat line, not
    // "no data". Zero points still falls through to the notice.
    if (points.length == 1) {
      final only = points.first;
      final lastX = samples.last.ts.difference(t0).inSeconds.toDouble();
      points.add(FlSpot(lastX > only.x ? lastX : only.x + 1, only.y));
    }
    if (points.length < 2) {
      return Center(
        child: Text(
            S.of('trip.only_n_points').replaceFirst('{n}', '${points.length}'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
    // Add ~5% padding to y range
    final ySpan = (maxY - minY).abs();
    final pad = ySpan > 0.5 ? ySpan * 0.05 : 0.5;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.grey.shade800,
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, _) => Text(
                value.toStringAsFixed(value.abs() < 10 ? 1 : 0),
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (value, _) {
                final mins = (value / 60).round();
                return Text('${mins}m',
                    style: const TextStyle(fontSize: 10, color: Colors.grey));
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: false,
            color: color,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.1),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Colors.black87,
            getTooltipItems: (spots) => spots
                .map((s) => LineTooltipItem(
                      '${s.y.toStringAsFixed(2)} $unit',
                      const TextStyle(color: Colors.white, fontSize: 11),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m ${d.inSeconds % 60}s';
}

/// v0.1.22: format an integer-seconds duration coming from Trip
/// columns (movingSeconds, idleSeconds). Returns `—` for null,
/// short form for sub-minute (avoids "0m 12s" for an idle blip).
String _fmtDur(int? seconds) {
  if (seconds == null || seconds <= 0) return '—';
  final d = Duration(seconds: seconds);
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

/// v0.1.29+113: Tesla-style trip power profile. Replaces the HV-bus voltage
/// chart (no HAL equivalent, low value). Loads the raw motor_power series
/// (signed kW: + traction, − regen) from hal_samples and bins it into narrow
/// bars over the trip's time span — each bar is the MEAN power in its bin
/// (bin width = span / barCount). Raw data is never smoothed; only the
/// display is binned, matching the "as in a Tesla" ask. Traction bars point
/// up (green), regen bars down (blue). Footer shows the frozen per-trip regen
/// energy and peak regen from the Trip row (+98) — not recomputed here.
class _PowerBarCard extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _PowerBarCard({required this.trip, required this.svc});

  static const int _barCount = 60;

  Future<List<double>> _bins() async {
    final rows = await svc.db.getHalSamplesForTripByName(trip.id, 'motor_power');
    if (rows.length < 2) return const [];
    final t0 = rows.first.timestamp;
    final spanSec =
        rows.last.timestamp.difference(t0).inSeconds.toDouble();
    if (spanSec <= 0) return const [];
    final sums = List<double>.filled(_barCount, 0);
    final counts = List<int>.filled(_barCount, 0);
    for (final r in rows) {
      final v = r.numericValue;
      if (v == null) continue;
      final frac = r.timestamp.difference(t0).inSeconds / spanSec;
      var idx = (frac * _barCount).floor();
      if (idx < 0) idx = 0;
      if (idx >= _barCount) idx = _barCount - 1;
      sums[idx] += v;
      counts[idx] += 1;
    }
    return [
      for (var i = 0; i < _barCount; i++)
        counts[i] == 0 ? 0.0 : sums[i] / counts[i]
    ];
  }

  @override
  Widget build(BuildContext context) {
    final regenKwh = trip.regenEnergyKwh;
    final peakRegen = trip.peakRegenKw;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bolt, size: 14, color: Colors.greenAccent),
                const SizedBox(width: 6),
                Text(S.of('trip.power_profile').toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
                const Spacer(),
                Text('kW',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: FutureBuilder<List<double>>(
                future: _bins(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2));
                  }
                  final bins = snap.data!;
                  if (bins.isEmpty) {
                    return Center(
                      child: Text(S.of('common.no_data'),
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12)),
                    );
                  }
                  double maxAbs = 1;
                  for (final b in bins) {
                    if (b.abs() > maxAbs) maxAbs = b.abs();
                  }
                  return BarChart(
                    BarChartData(
                      minY: -maxAbs,
                      maxY: maxAbs,
                      alignment: BarChartAlignment.spaceBetween,
                      barTouchData: BarTouchData(enabled: false),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: v == 0
                              ? Colors.grey.shade600
                              : Colors.grey.shade800,
                          strokeWidth: v == 0 ? 1 : 0.5,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 34,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(0),
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey),
                            ),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      barGroups: [
                        for (var i = 0; i < bins.length; i++)
                          BarChartGroupData(x: i, barRods: [
                            BarChartRodData(
                              toY: bins[i],
                              width: 3,
                              color: bins[i] >= 0
                                  ? Colors.greenAccent
                                  : Colors.lightBlueAccent,
                              borderRadius: BorderRadius.zero,
                            ),
                          ]),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.arrow_upward,
                    size: 12, color: Colors.greenAccent),
                Text(' ${S.of('trip.traction')}   ',
                    style: TextStyle(
                        fontSize: 10, color: Colors.grey.shade400)),
                const Icon(Icons.arrow_downward,
                    size: 12, color: Colors.lightBlueAccent),
                Text(' ${S.of('trip.regen')}',
                    style: TextStyle(
                        fontSize: 10, color: Colors.grey.shade400)),
                const Spacer(),
                if (regenKwh != null)
                  Text(
                    S
                        .of('trip.regen_recovered')
                        .replaceFirst('{kwh}', regenKwh.toStringAsFixed(2))
                        .replaceFirst(
                            '{peak}',
                            peakRegen != null
                                ? peakRegen.abs().toStringAsFixed(0)
                                : '—'),
                    style: const TextStyle(
                        fontSize: 11, color: Colors.lightBlueAccent),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
