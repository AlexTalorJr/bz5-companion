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
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _TripSummaryCard(trip: trip, svc: svc),
              const SizedBox(height: 12),
              _DerivedMetricsCard(trip: trip),
              const SizedBox(height: 12),
              _ChartCard(
                title: 'SOC vs time',
                tripId: trip.id,
                ecuTx: '790',
                did: '0005',
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
                valueTransform: (v) => v - 40,
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
        },
      ),
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
      _MetricRow('Peak speed',
          trip.peakSpeedKmh != null
              ? '${trip.peakSpeedKmh!.toStringAsFixed(0)} km/h'
              : '— (DID not identified)'),
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
