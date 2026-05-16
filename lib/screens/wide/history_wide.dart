import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/database.dart';
import '../../services/connection.dart';
import '../trends.dart';

/// v0.1.9: Wide layout for History on head unit.
///
/// Layout strategy:
///   - When trip is active: dedicated full-width Active Trip view with
///     large live metrics + sparkline. Past trips collapse to a thin
///     drawer on the left, accessible by tapping a tab.
///   - When no active trip: split-pane — past trips list left (~35%),
///     selected trip detail + charts on the right (~65%).
///   - Trends mode: full-width screen with all charts in a grid.
///
/// Read-only by design: head unit users see data, don't manipulate.
class HistoryWideScreen extends StatefulWidget {
  const HistoryWideScreen({super.key});

  @override
  State<HistoryWideScreen> createState() => _HistoryWideScreenState();
}

enum _Tab { trips, trends }

class _HistoryWideScreenState extends State<HistoryWideScreen> {
  _Tab _tab = _Tab.trips;
  int? _selectedTripId;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top tab control + title
          Row(
            children: [
              const Text('HISTORY',
                  style: TextStyle(
                      fontSize: 14,
                      letterSpacing: 2.0,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey)),
              const SizedBox(width: 16),
              SegmentedButton<_Tab>(
                segments: const [
                  ButtonSegment(
                      value: _Tab.trips,
                      label: Text('Trips'),
                      icon: Icon(Icons.route, size: 16)),
                  ButtonSegment(
                      value: _Tab.trends,
                      label: Text('Trends'),
                      icon: Icon(Icons.show_chart, size: 16)),
                ],
                selected: {_tab},
                onSelectionChanged: (s) =>
                    setState(() => _tab = s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _tab == _Tab.trips
                ? _TripsBody(
                    selectedTripId: _selectedTripId,
                    onSelectTrip: (id) => setState(() => _selectedTripId = id),
                  )
                : const TrendsScreen(),
          ),
        ],
      ),
    );
  }
}

class _TripsBody extends StatelessWidget {
  final int? selectedTripId;
  final ValueChanged<int> onSelectTrip;
  const _TripsBody({required this.selectedTripId, required this.onSelectTrip});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return FutureBuilder<List<Trip>>(
      future: svc.db.getRecentTrips(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final trips = snap.data!;
        if (trips.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.route_outlined,
                      size: 80, color: Colors.grey.shade600),
                  const SizedBox(height: 20),
                  const Text('Поездок пока нет',
                      style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  Text(
                    'Подключитесь к адаптеру и поезжайте — '
                    'история начнёт заполняться автоматически.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          );
        }
        final active = trips.firstWhere((t) => t.endedAt == null,
            orElse: () => trips.first);
        final hasActive = active.endedAt == null;

        // If there's an active trip, dedicated wide layout for it
        if (hasActive) {
          return _ActiveTripWideView(trip: active, svc: svc);
        }

        // Else: split-pane (past trips list + selected detail)
        final selectedId = selectedTripId ?? trips.first.id;
        final selectedTrip =
            trips.firstWhere((t) => t.id == selectedId, orElse: () => trips.first);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left: trips list (~32%)
            SizedBox(
              width: 380,
              child: _TripsListColumn(
                trips: trips,
                selectedId: selectedTrip.id,
                onSelect: onSelectTrip,
              ),
            ),
            const SizedBox(width: 16),
            // Right: selected trip detail + charts
            Expanded(
              child: _SelectedTripDetail(trip: selectedTrip, svc: svc),
            ),
          ],
        );
      },
    );
  }
}

class _TripsListColumn extends StatelessWidget {
  final List<Trip> trips;
  final int selectedId;
  final ValueChanged<int> onSelect;
  const _TripsListColumn({
    required this.trips,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: trips.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final t = trips[i];
          final selected = t.id == selectedId;
          final duration =
              (t.endedAt ?? DateTime.now()).difference(t.startedAt);
          final dateStr = DateFormat('d MMM HH:mm').format(t.startedAt);
          final dist = t.distanceKm;
          return Container(
            color: selected
                ? Colors.lightBlueAccent.withValues(alpha: 0.1)
                : null,
            child: ListTile(
              dense: true,
              onTap: () => onSelect(t.id),
              title: Text(dateStr,
                  style: TextStyle(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 13)),
              subtitle: Text(
                '${_fmtDuration(duration)}'
                '${dist != null ? ' · ${dist.toStringAsFixed(1)} km' : ''}',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Text('#${t.id}',
                  style:
                      const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
          );
        },
      ),
    );
  }
}

class _SelectedTripDetail extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _SelectedTripDetail({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final duration =
        (trip.endedAt ?? DateTime.now()).difference(trip.startedAt);
    final dateStr = DateFormat('d MMMM y, HH:mm').format(trip.startedAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dateStr,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      Text(_fmtDuration(duration),
                          style: const TextStyle(
                              fontSize: 13, color: Colors.grey)),
                    ],
                  ),
                ),
                _bigMetric('DISTANCE',
                    trip.distanceKm != null
                        ? '${trip.distanceKm!.toStringAsFixed(1)} km'
                        : '—'),
                _bigMetric('ENERGY',
                    trip.energyUsedKwh != null
                        ? '${trip.energyUsedKwh!.toStringAsFixed(2)} kWh'
                        : '—'),
                _bigMetric('AVG',
                    trip.avgConsumptionKwh100km != null
                        ? '${trip.avgConsumptionKwh100km!.toStringAsFixed(1)}'
                        : '—',
                    unit: 'kWh/100'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _ChartCard(
                  title: 'SOC',
                  tripId: trip.id,
                  ecuTx: '790',
                  did: '0005',
                  color: Colors.greenAccent,
                  unit: '%',
                  svc: svc,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ChartCard(
                  title: 'Battery temp',
                  tripId: trip.id,
                  ecuTx: '790',
                  did: '002F',
                  color: Colors.orangeAccent,
                  unit: '°C',
                  valueTransform: (v) => v - 40,
                  svc: svc,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _ChartCard(
                  title: 'Pack voltage',
                  tripId: trip.id,
                  ecuTx: '740',
                  did: '0022',
                  color: Colors.yellowAccent,
                  unit: 'V',
                  valueTransform: (v) => v * 0.025,
                  svc: svc,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ChartCard(
                  title: 'HV bus',
                  tripId: trip.id,
                  ecuTx: '790',
                  did: '0015',
                  color: Colors.lightBlueAccent,
                  unit: 'V',
                  svc: svc,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bigMetric(String label, String value, {String? unit}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w300,
                  fontFeatures: [FontFeature.tabularFigures()])),
          if (unit != null)
            Text(unit,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}

/// v0.1.9: Active trip wide view — large live metrics + sparkline.
/// Shows on head unit during an ongoing trip.
class _ActiveTripWideView extends StatelessWidget {
  final Trip trip;
  final ConnectionService svc;
  const _ActiveTripWideView({required this.trip, required this.svc});

  @override
  Widget build(BuildContext context) {
    final duration =
        svc.tripDuration ?? DateTime.now().difference(trip.startedAt);
    final dateStr = DateFormat('d MMM, HH:mm').format(trip.startedAt);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top bar: ACTIVE + date + time
        Card(
          color: Colors.green.shade900.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Colors.greenAccent, width: 1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 12, height: 12,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent,
                  ),
                ),
                const SizedBox(width: 10),
                const Text('ACTIVE TRIP',
                    style: TextStyle(
                        fontSize: 14,
                        letterSpacing: 2.0,
                        fontWeight: FontWeight.w500,
                        color: Colors.greenAccent)),
                const SizedBox(width: 16),
                Text(dateStr,
                    style: const TextStyle(
                        fontSize: 18, color: Colors.white)),
                const Spacer(),
                Text('#${trip.id}',
                    style: const TextStyle(
                        fontSize: 14, color: Colors.grey)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 3-column big-metrics row 1
        Row(
          children: [
            Expanded(
                child: _HugeMetric(
                    label: 'TIME',
                    value: _fmtDuration(duration),
                    color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: 'DISTANCE',
                    value: svc.tripDistanceKm != null
                        ? svc.tripDistanceKm!.toStringAsFixed(1)
                        : '—',
                    unit: 'km',
                    color: Colors.white)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: 'ENERGY USED',
                    value: svc.tripEnergyUsedKwh != null
                        ? svc.tripEnergyUsedKwh!.toStringAsFixed(2)
                        : '—',
                    unit: 'kWh',
                    color: Colors.yellowAccent)),
          ],
        ),
        const SizedBox(height: 12),
        // 3-column big-metrics row 2
        Row(
          children: [
            Expanded(
                child: _HugeMetric(
                    label: 'AVG CONSUMPTION',
                    value: svc.tripAvgConsumptionKwh100km != null
                        ? svc.tripAvgConsumptionKwh100km!.toStringAsFixed(1)
                        : '—',
                    unit: 'kWh/100km',
                    color: Colors.greenAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: 'PEAK POWER',
                    value: svc.tripPeakPowerKw != null
                        ? svc.tripPeakPowerKw!.toStringAsFixed(1)
                        : '—',
                    unit: 'kW',
                    color: Colors.orangeAccent)),
            const SizedBox(width: 12),
            Expanded(
                child: _HugeMetric(
                    label: 'TEMP RANGE',
                    value: (svc.tripMinTempC != null && svc.tripMaxTempC != null)
                        ? '${svc.tripMinTempC!.toStringAsFixed(0)}–${svc.tripMaxTempC!.toStringAsFixed(0)}'
                        : '—',
                    unit: '°C',
                    color: Colors.lightBlueAccent)),
          ],
        ),
        const SizedBox(height: 16),
        // Mini SOC chart for active trip
        Expanded(
          child: _ChartCard(
            title: 'SOC over time',
            tripId: trip.id,
            ecuTx: '790',
            did: '0005',
            color: Colors.greenAccent,
            unit: '%',
            svc: svc,
            big: true,
          ),
        ),
      ],
    );
  }
}

class _HugeMetric extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color color;
  const _HugeMetric({
    required this.label,
    required this.value,
    this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.5,
                    color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 44,
                        fontWeight: FontWeight.w300,
                        color: color,
                        height: 1.0,
                        fontFeatures:
                            const [FontFeature.tabularFigures()])),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(unit!,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.grey)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline chart card shared between active and past trip views.
class _ChartCard extends StatelessWidget {
  final String title;
  final int tripId;
  final String ecuTx;
  final String did;
  final Color color;
  final String unit;
  final double Function(double)? valueTransform;
  final ConnectionService svc;
  final bool big;
  const _ChartCard({
    required this.title,
    required this.tripId,
    required this.ecuTx,
    required this.did,
    required this.color,
    required this.unit,
    required this.svc,
    this.valueTransform,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
            Expanded(
              child: FutureBuilder<List<Sample>>(
                future: svc.db
                    .getSamplesForTrip(tripId, ecuTx: ecuTx, did: did),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2));
                  }
                  return _buildChart(snap.data!);
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
    if (samples.isEmpty) {
      return Center(
        child: Text('Нет данных',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
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
        child: Text('Накопление данных...',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
      );
    }
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
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
                style: const TextStyle(
                    fontSize: big ? 12 : 10, color: Colors.grey),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) => Text(
                '${(v / 60).round()}m',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: false,
            color: color,
            barWidth: big ? 2.0 : 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.1),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes}m ${d.inSeconds % 60}s';
}
