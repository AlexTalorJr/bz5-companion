import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';
import '../widgets/responsive.dart';

/// v0.1.9: Trends screen — long-term charts of key metrics over selectable time windows.
///
/// Data source: Snapshots table, populated by ConnectionService._maybeWriteSnapshot
/// at 2-min cadence during trips and 10-min cadence otherwise. This means:
///   - First trends will appear after ~2 minutes of app usage
///   - "24 hours" window starts being useful after ~1 day of regular use
///   - "Year" only after the user has had the app for ~weeks/months
///
/// The screen uses real-time width estimation to decide how many data points
/// to show vs aggregate. Fl_chart handles the rendering.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

enum _Window { realtime, h24, d7, d30, y1, all }

class _TrendsScreenState extends State<TrendsScreen> {
  _Window _window = _Window.h24;

  Duration _windowDuration() {
    switch (_window) {
      case _Window.realtime: return const Duration(hours: 1);
      case _Window.h24: return const Duration(hours: 24);
      case _Window.d7: return const Duration(days: 7);
      case _Window.d30: return const Duration(days: 30);
      case _Window.y1: return const Duration(days: 365);
      case _Window.all: return const Duration(days: 3650);
    }
  }

  String _windowLabel() {
    switch (_window) {
      case _Window.realtime: return 'Last 1h';
      case _Window.h24: return '24 h';
      case _Window.d7: return '7 d';
      case _Window.d30: return '30 d';
      case _Window.y1: return '1 y';
      case _Window.all: return 'all';
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final now = DateTime.now();
    final from = now.subtract(_windowDuration());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<_Window>(
            segments: const [
              ButtonSegment(value: _Window.realtime, label: Text('1h')),
              ButtonSegment(value: _Window.h24, label: Text('24h')),
              ButtonSegment(value: _Window.d7, label: Text('7d')),
              ButtonSegment(value: _Window.d30, label: Text('30d')),
              ButtonSegment(value: _Window.y1, label: Text('1y')),
              ButtonSegment(value: _Window.all, label: Text('all')),
            ],
            selected: {_window},
            onSelectionChanged: (s) => setState(() => _window = s.first),
            showSelectedIcon: false,
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Snapshot>>(
            future: svc.db.getSnapshotsInRange(from, now),
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final snapshots = snap.data!;
              if (snapshots.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.timeline,
                            size: 56, color: Colors.grey.shade600),
                        const SizedBox(height: 16),
                        const Text('Нет данных за этот период',
                            style: TextStyle(fontSize: 15)),
                        const SizedBox(height: 8),
                        Text(
                          'Snapshot пишется в БД раз в 2 минуты во время поездки '
                          'и раз в 10 минут вне поездки. Сделайте поездку или '
                          'подключите адаптер на время — Trends заполнится.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                );
              }
              // v0.1.10: 2-column grid on head unit (landscape ≥840dp wide),
              // 1-column ListView on phone. Each chart has a fixed aspect
              // ratio so it doesn't stretch absurdly wide on large displays.
              final charts = <Widget>[
                _TrendChart(
                  title: 'State of charge',
                  snapshots: snapshots,
                  valuePicker: (s) => s.soc,
                  color: Colors.greenAccent,
                  unit: '%',
                  windowLabel: _windowLabel(),
                ),
                _TrendChart(
                  title: 'Battery temperature',
                  snapshots: snapshots,
                  valuePicker: (s) => s.batteryTempC,
                  color: Colors.orangeAccent,
                  unit: '°C',
                  windowLabel: _windowLabel(),
                ),
                _TrendChart(
                  title: 'State of health',
                  snapshots: snapshots,
                  valuePicker: (s) => s.soh,
                  color: Colors.lightGreenAccent,
                  unit: '%',
                  windowLabel: _windowLabel(),
                ),
                _TrendChart(
                  title: 'Cell spread',
                  snapshots: snapshots,
                  valuePicker: (s) => s.cellSpread,
                  color: Colors.cyanAccent,
                  unit: 'mV',
                  windowLabel: _windowLabel(),
                ),
                _TrendChart(
                  title: 'Cycle count',
                  snapshots: snapshots,
                  valuePicker: (s) => s.cycleCount?.toDouble(),
                  color: Colors.pinkAccent,
                  unit: '',
                  windowLabel: _windowLabel(),
                ),
                _TrendChart(
                  title: 'Odometer',
                  snapshots: snapshots,
                  valuePicker: (s) => s.odometer,
                  color: Colors.lightBlueAccent,
                  unit: 'km',
                  windowLabel: _windowLabel(),
                ),
              ];

              final isWide = LayoutBreakpoints.useHeadUnitLayout(context);
              if (isWide) {
                return GridView.count(
                  crossAxisCount: 2,
                  padding: const EdgeInsets.all(8),
                  childAspectRatio: 2.4,    // wide-ish charts so values readable
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  children: charts,
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: charts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => charts[i],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TrendChart extends StatelessWidget {
  final String title;
  final List<Snapshot> snapshots;
  final double? Function(Snapshot) valuePicker;
  final Color color;
  final String unit;
  final String windowLabel;
  const _TrendChart({
    required this.title,
    required this.snapshots,
    required this.valuePicker,
    required this.color,
    required this.unit,
    required this.windowLabel,
  });

  @override
  Widget build(BuildContext context) {
    final points = <FlSpot>[];
    final t0 = snapshots.first.capturedAt;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final s in snapshots) {
      final v = valuePicker(s);
      if (v == null) continue;
      final x = s.capturedAt.difference(t0).inSeconds.toDouble();
      points.add(FlSpot(x, v));
      if (v < minY) minY = v;
      if (v > maxY) maxY = v;
    }

    // v0.1.10: in a GridView the cell already has fixed dimensions (via
    // childAspectRatio), so the chart fills it via Expanded. In a phone
    // ListView each chart needs its own height — 180dp is comfortable.
    // We detect grid context: a chart inside GridView gets bounded constraints
    // top-down. The simplest robust solution is wrap with SizedBox in the
    // ListView builder, but here we just give Card a max height when not
    // bounded.
    final isWide = LayoutBreakpoints.useHeadUnitLayout(context);

    final card = Card(
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
                      color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Text(title.toUpperCase(),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        color: Colors.grey)),
                const Spacer(),
                Text(windowLabel,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: points.length < 2
                  ? Center(
                      child: Text(
                          '${points.length} точка(и) — недостаточно для графика',
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 11)),
                    )
                  : LineChart(
                      LineChartData(
                        minY: minY - (maxY - minY).abs() * 0.05 - 0.1,
                        maxY: maxY + (maxY - minY).abs() * 0.05 + 0.1,
                        gridData: const FlGridData(show: false),
                        titlesData: FlTitlesData(
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 40,
                              getTitlesWidget: (v, _) => Text(
                                v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey),
                              ),
                            ),
                          ),
                          bottomTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
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
                              color: color.withValues(alpha: 0.08),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Text(
              '${points.length} samples · ' +
                  (points.isNotEmpty
                      ? '${minY.toStringAsFixed(1)} – ${maxY.toStringAsFixed(1)} $unit'
                      : ''),
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );

    // Phone in a ListView: ListView gives unbounded height to children, so
    // the Expanded inside Card would crash. Constrain to a fixed height.
    // Head unit in a GridView: the cell is already bounded by childAspectRatio,
    // so Card lays out fine without a wrapper.
    if (!isWide) {
      return SizedBox(height: 180, child: card);
    }
    return card;
  }
}
