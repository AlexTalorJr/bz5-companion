import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: Text('Trip #${widget.tripId}'),
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
              _TripSummaryCard(trip: trip, svc: svc),
              const SizedBox(height: 12),
              _DerivedMetricsCard(trip: trip),
              const SizedBox(height: 12),
              // v0.1.25: Tesla-style trip stats panel — speed histogram,
              // odometer range, moving/idle breakdown. Visualises data
              // we already collect, sits between metrics and charts so
              // a user scrolling sees overview → distribution → curves.
              _OdometerRangeCard(trip: trip),
              const SizedBox(height: 12),
              _MovingIdleDonutCard(trip: trip),
              const SizedBox(height: 12),
              _SpeedHistogramCard(tripId: trip.id),
              const SizedBox(height: 12),
              // v0.1.24: SOC chart switched from integer 0x0005 (which
              // steps in 1% chunks and looks jagged on short trips) to
              // precise 1FFD (high16/100, 0.01% resolution). Registry
              // decoder for 1FFD already returns the float percentage,
              // so no valueTransform needed.
              _ChartCard(
                title: 'SOC vs time',
                tripId: trip.id,
                ecuTx: '790',
                did: '1FFD',
                color: Colors.greenAccent,
                unit: '%',
                svc: svc,
              ),
              const SizedBox(height: 12),
              _ChartCard(
                title: 'Battery temperature',
                tripId: trip.id,
                ecuTx: '790',
                did: '002F',
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
                title: 'Pack voltage (filtered)',
                tripId: trip.id,
                ecuTx: '740',
                did: '0022',
                color: Colors.yellowAccent,
                unit: 'V',
                // No valueTransform — registry decoder already applies scale 0.025
                // (per v0.1.9 hotfix 2026-05-17). Values in Sample.numericValue
                // are already in volts.
                svc: svc,
              ),
              const SizedBox(height: 12),
              _ChartCard(
                title: 'HV bus voltage',
                tripId: trip.id,
                ecuTx: '790',
                did: '0015',
                color: Colors.lightBlueAccent,
                unit: 'V',
                svc: svc,
              ),
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
          _TripSummaryCard(trip: trip, svc: svc),
          _DerivedMetricsCard(trip: trip),
        ),
        const SizedBox(height: 12),
        pair(
          _OdometerRangeCard(trip: trip),
          _MovingIdleDonutCard(trip: trip),
        ),
        const SizedBox(height: 12),
        _SpeedHistogramCard(tripId: trip.id),
        const SizedBox(height: 12),
        _ChartCard(
          title: 'SOC vs time',
          tripId: trip.id,
          ecuTx: '790',
          did: '1FFD',
          color: Colors.greenAccent,
          unit: '%',
          svc: svc,
        ),
        const SizedBox(height: 12),
        pair(
          _ChartCard(
            title: 'Battery temperature',
            tripId: trip.id,
            ecuTx: '790',
            did: '002F',
            color: Colors.orangeAccent,
            unit: '°C',
            // v0.1.26+9: see narrow-layout comment — registry already
            // applies offset -40, doing it again here was a double-offset.
            svc: svc,
          ),
          _ChartCard(
            title: 'Pack voltage (filtered)',
            tripId: trip.id,
            ecuTx: '740',
            did: '0022',
            color: Colors.yellowAccent,
            unit: 'V',
            svc: svc,
          ),
        ),
        const SizedBox(height: 12),
        _ChartCard(
          title: 'HV bus voltage',
          tripId: trip.id,
          ecuTx: '790',
          did: '0015',
          color: Colors.lightBlueAccent,
          unit: 'V',
          svc: svc,
        ),
      ],
    );
  }
}

class _TripSummaryCard extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _TripSummaryCard({required this.trip, required this.svc});

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
                  const Text('COMPLETED',
                      style: TextStyle(
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
                  (isActive ? ' (running)' : ' total'),
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

class _DerivedMetricsCard extends StatelessWidget {
  final Trip trip;
  const _DerivedMetricsCard({required this.trip});

  @override
  Widget build(BuildContext context) {
    final dist = trip.distanceKm ??
        ((trip.endOdometer != null && trip.startOdometer != null)
            ? (trip.endOdometer! - trip.startOdometer!)
            : null);
    final socUsed = (trip.endSoc != null && trip.startSoc != null)
        ? (trip.startSoc! - trip.endSoc!)
        : null;

    final rows = <Widget>[
      _MetricRow('Distance',
          dist != null ? '${dist.toStringAsFixed(2)} km' : '—'),
      _MetricRow('Energy used',
          trip.energyUsedKwh != null
              ? '${trip.energyUsedKwh!.toStringAsFixed(2)} kWh'
              : '—'),
      _MetricRow('Avg consumption',
          trip.avgConsumptionKwh100km != null
              ? '${trip.avgConsumptionKwh100km!.toStringAsFixed(1)} kWh/100km'
              : '—'),
      _MetricRow('SOC',
          (trip.startSoc != null && trip.endSoc != null)
              ? '${trip.startSoc!.toStringAsFixed(0)}% → ${trip.endSoc!.toStringAsFixed(0)}%'
                  '${socUsed != null && socUsed > 0 ? ' (-${socUsed.toStringAsFixed(0)}%)' : ''}'
              : '—'),
      _MetricRow('SOC range during trip',
          (trip.minSoc != null && trip.maxSoc != null)
              ? '${trip.minSoc!.toStringAsFixed(0)}–${trip.maxSoc!.toStringAsFixed(0)}%'
              : '—'),
      _MetricRow('Battery temp range',
          (trip.minBatteryTempC != null && trip.maxBatteryTempC != null)
              ? '${trip.minBatteryTempC!.toStringAsFixed(1)}–${trip.maxBatteryTempC!.toStringAsFixed(1)} °C'
              : '—'),
      _MetricRow('Max cell spread',
          trip.maxCellSpreadMv != null
              ? '${trip.maxCellSpreadMv!.toStringAsFixed(0)} mV'
              : '—'),
      _MetricRow('Peak power',
          trip.peakPowerKw != null
              ? '${trip.peakPowerKw!.toStringAsFixed(1)} kW'
              : '— (DID not identified)'),
      _MetricRow('Peak regen',
          trip.peakRegenKw != null
              ? '${trip.peakRegenKw!.toStringAsFixed(1)} kW'
              : '— (DID not identified)'),
      // v0.1.26+10: peak_power_kw / peak_regen_kw are now populated by
      // an HV-bus-sag heuristic (R_pack ≈ 0.18 Ω) when the direct
      // 791/0x0038 DID is silent — which is the common case during
      // motion. Accuracy is ±20-30 %.
      const Padding(
        padding: EdgeInsets.fromLTRB(0, 4, 0, 4),
        child: Text(
          '↑ peak values estimated from HV-bus sag (±20-30%) until pack-current DID is identified',
          style: TextStyle(fontSize: 10, color: Colors.grey, fontStyle: FontStyle.italic),
        ),
      ),
      // v0.1.22: peak speed now actually populated (740/0x0008 verified).
      // Remove the "DID not identified" placeholder when value present.
      _MetricRow('Peak speed',
          trip.peakSpeedKmh != null
              ? '${trip.peakSpeedKmh!.toStringAsFixed(0)} km/h'
              : '—'),
      // v0.1.22: new trip metrics enabled by speed DID + precise SOC.
      _MetricRow('Avg moving speed',
          trip.avgMovingSpeedKmh != null
              ? '${trip.avgMovingSpeedKmh!.toStringAsFixed(0)} km/h'
              : '—'),
      _MetricRow('Time moving / idle',
          (trip.movingSeconds != null || trip.idleSeconds != null)
              ? '${_fmtDur(trip.movingSeconds)} / ${_fmtDur(trip.idleSeconds)}'
              : '—'),
      // Energy from precise SOC: independent of integer-SOC-based
      // energyUsedKwh above. When both present, comparing the two gives
      // an idea of measurement noise (typically ±5%).
      _MetricRow('Energy (precise SOC)',
          trip.energyFromSocKwh != null
              ? '${trip.energyFromSocKwh!.toStringAsFixed(2)} kWh'
              : '—'),
      _MetricRow('Samples logged', '${trip.sampleCount}'),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('TRIP METRICS',
                style: TextStyle(
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
class _OdometerRangeCard extends StatelessWidget {
  final Trip trip;
  const _OdometerRangeCard({required this.trip});

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
                  const Text('ODOMETER',
                      style: TextStyle(
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
class _MovingIdleDonutCard extends StatelessWidget {
  final Trip trip;
  const _MovingIdleDonutCard({required this.trip});

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
                  const Text('TIME BREAKDOWN',
                      style: TextStyle(
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
                      Text('Moving  ${_fmtDur(movSec)}',
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
                      Text('Idle    ${_fmtDur(idleSec)}',
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
class _SpeedHistogramCard extends StatefulWidget {
  final int tripId;
  const _SpeedHistogramCard({required this.tripId});

  @override
  State<_SpeedHistogramCard> createState() => _SpeedHistogramCardState();
}

class _SpeedHistogramCardState extends State<_SpeedHistogramCard> {
  late Future<List<Sample>> _samples;

  @override
  void initState() {
    super.initState();
    _samples = _loadSamples();
  }

  Future<List<Sample>> _loadSamples() async {
    final db = Provider.of<ConnectionService>(context, listen: false).db;
    return db.getSamplesForTrip(widget.tripId, ecuTx: '740', did: '0008');
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SPEED DISTRIBUTION',
                style: TextStyle(
                    fontSize: 11, letterSpacing: 1.2, color: Colors.grey)),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: FutureBuilder<List<Sample>>(
                future: _samples,
                builder: (ctx, snap) {
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final samples = snap.data!;
                  if (samples.isEmpty) {
                    return const Center(
                      child: Text(
                        'No speed data for this trip',
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  // Bin into 10 km/h buckets, skip zero bucket (stopped)
                  // and cap at 150 km/h (very few samples above).
                  const binSize = 10;
                  const binCount = 15; // 0..149
                  final counts = List<int>.filled(binCount, 0);
                  for (final s in samples) {
                    final v = s.numericValue;
                    if (v == null || v < 1) continue; // exclude stopped
                    final binIdx = (v / binSize).floor();
                    if (binIdx >= 0 && binIdx < binCount) {
                      counts[binIdx]++;
                    }
                  }
                  final total = counts.fold<int>(0, (a, b) => a + b);
                  if (total == 0) {
                    return const Center(
                      child: Text(
                        'All samples were at 0 km/h (idle trip)',
                        style: TextStyle(color: Colors.grey),
                      ),
                    );
                  }

                  // Identify max bin and second-max for color hierarchy.
                  final maxCount = counts.reduce((a, b) => a > b ? a : b);
                  final percents =
                      counts.map((c) => 100.0 * c / total).toList();

                  // Find rightmost non-zero bin for clipping the X-axis
                  int rightmost = 0;
                  for (int i = 0; i < binCount; i++) {
                    if (counts[i] > 0) rightmost = i;
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
                              if (counts[idx] >= maxCount * 0.8) {
                                labelColor = Colors.redAccent;
                              } else if (counts[idx] >= maxCount * 0.5) {
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
                        if (counts[i] >= maxCount * 0.8) {
                          barColor = Colors.redAccent;
                        } else if (counts[i] >= maxCount * 0.5) {
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
                              width: 14,
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
  final String ecuTx;
  final String did;
  final Color color;
  final String unit;
  final double Function(double)? valueTransform;
  final ConnectionService svc;
  const _ChartCard({
    required this.title,
    required this.tripId,
    required this.ecuTx,
    required this.did,
    required this.color,
    required this.unit,
    required this.svc,
    this.valueTransform,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
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
                const Spacer(),
                Text('$ecuTx/0x$did',
                    style: const TextStyle(
                        fontSize: 10,
                        color: Colors.grey,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: FutureBuilder<List<Sample>>(
                future: svc.db.getSamplesForTrip(tripId, ecuTx: ecuTx, did: did),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2));
                  }
                  final samples = snap.data!;
                  if (samples.isEmpty) {
                    return Center(
                      child: Text('Нет данных',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 12)),
                    );
                  }
                  return _buildChart(samples);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChart(List<Sample> samples) {
    final points = <FlSpot>[];
    final t0 = samples.first.timestamp;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final s in samples) {
      if (s.numericValue == null) continue;
      final x = s.timestamp.difference(t0).inSeconds.toDouble();
      final y = valueTransform != null
          ? valueTransform!(s.numericValue!)
          : s.numericValue!;
      points.add(FlSpot(x, y));
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    if (points.length < 2) {
      return Center(
        child: Text('Только ${points.length} точка(и)',
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
