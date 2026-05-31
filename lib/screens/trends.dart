import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../services/connection.dart';
import '../services/cost_settings.dart';
import '../services/trend_aggregator.dart';
import '../widgets/responsive.dart';

/// v0.1.29+35: Trends tab — rebuilt from the ground up.
///
/// The old version drew six flat line charts straight off the 2-min
/// Snapshots table (SOC / temp / SOH / cell spread / cycle count /
/// odometer). On that data most of them barely moved: cycle count and
/// odometer were monotone ramps, SOC a context-free sawtooth. The useful
/// long-term questions a driver actually opens this tab to answer —
/// "how far have I driven this year, how much have I spent, am I driving
/// more efficiently, how is the pack ageing" — weren't answered at all.
///
/// New structure, three sections (see TrendAggregator for the maths):
///   1. Period totals      — distance / energy / money / regen as numbers.
///   2. Cumulative & cost  — running distance curve + per-month cost bars.
///   3. Efficiency & health— consumption-per-trip with a smoothed trend
///                           line, regen share, SOH, real range per 100%.
///
/// Period totals & per-period charts come from the Trips table (via
/// TrendAggregator); SOH still comes from Snapshots (it has no home on
/// Trips). Money uses CostSettings — hidden entirely if not configured.
///
/// Smoothing: slow health/efficiency lines use fl_chart's curve with
/// preventCurveOverShooting (so a Bézier can't dip a non-negative
/// quantity below its real floor). The per-trip consumption scatter is
/// smoothed with a moving average computed in the aggregator rather than
/// a render flag, because the sawtooth there is real trip-to-trip
/// variance, not a rendering artefact.
class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

enum _Window { d30, y1, all }

class _TrendsScreenState extends State<TrendsScreen> {
  // v0.1.29+35: long-term genre → default to a year, not 24h.
  _Window _window = _Window.y1;

  Duration _windowDuration() {
    switch (_window) {
      case _Window.d30:
        return const Duration(days: 30);
      case _Window.y1:
        return const Duration(days: 365);
      case _Window.all:
        return const Duration(days: 3650);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final cost = context.watch<CostSettings>();
    final now = DateTime.now();
    final from = now.subtract(_windowDuration());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<_Window>(
            segments: const [
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
          child: FutureBuilder<List<Trip>>(
            future: svc.db.getTripsInRange(from, now),
            builder: (context, tripSnap) {
              if (!tripSnap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final trips = tripSnap.data!;
              final agg = TrendAggregator.build(
                trips,
                costPerKwh: cost.costPerKwh,
              );

              if (agg.isEmpty) {
                return _emptyState();
              }

              // SOH comes from snapshots, separately — fetch them too and
              // merge the SOH curve in once both futures resolve.
              return FutureBuilder<List<Snapshot>>(
                future: svc.db.getSnapshotsInRange(from, now),
                builder: (context, snapSnap) {
                  final snapshots = snapSnap.data ?? const <Snapshot>[];
                  return _buildSections(context, agg, snapshots, cost);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.insights, size: 56, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            const Text('Нет поездок за этот период',
                style: TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Text(
              'Trends строится по завершённым поездкам. Сделайте поездку '
              'с подключённым адаптером — итоги, расход и графики появятся '
              'здесь.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSections(
    BuildContext context,
    TrendAggregate agg,
    List<Snapshot> snapshots,
    CostSettings cost,
  ) {
    final isWide = LayoutBreakpoints.useHeadUnitLayout(context);

    // SOH curve straight off snapshots (the one metric with no Trips home).
    final sohPoints = <FlSpot>[];
    if (snapshots.isNotEmpty) {
      final t0 = snapshots.first.capturedAt.millisecondsSinceEpoch.toDouble();
      for (final s in snapshots) {
        final v = s.soh;
        if (v == null) continue;
        sohPoints
            .add(FlSpot(s.capturedAt.millisecondsSinceEpoch.toDouble() - t0, v));
      }
    }

    final children = <Widget>[
      // ── Section 1: period totals ──
      _SectionLabel('Итоги за период'),
      _TotalsGrid(agg: agg, cost: cost),
      const SizedBox(height: 20),

      // ── Section 2: cumulative & cost ──
      _SectionLabel('Накопительно'),
      _chartGrid(isWide, [
        _LineCard(
          title: 'Пробег накопительно',
          subtitle: 'км нарастающим итогом',
          points: agg.cumulativeOdometer,
          color: Colors.lightBlueAccent,
          unit: 'км',
          // monotone by nature — no curve (overshoot would break monotonicity)
          curved: false,
        ),
        if (cost.isConfigured)
          _BarCard(
            title: 'Затраты по месяцам',
            subtitle: '${cost.currencySymbol} за энергию',
            bars: agg.costPerMonth,
            color: Colors.amberAccent,
            currency: cost.currencySymbol,
          ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3: efficiency ──
      _SectionLabel('Эффективность вождения'),
      _chartGrid(isWide, [
        _ScatterTrendCard(
          title: 'Средний расход',
          subtitle: 'кВт·ч/100км · точка = поездка, линия = среднее',
          dots: agg.consumptionPerTrip,
          trend: agg.consumptionTrendLine,
          color: Colors.tealAccent,
          unit: 'кВт·ч/100км',
        ),
        _LineCard(
          title: 'Доля рекуперации',
          subtitle: '% возвращённой энергии',
          points: agg.regenSharePct,
          color: Colors.greenAccent,
          unit: '%',
          curved: true,
        ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3b: battery health ──
      _SectionLabel('Здоровье батареи'),
      _chartGrid(isWide, [
        _LineCard(
          title: 'SOH',
          subtitle: '% ёмкости · медленная деградация',
          points: sohPoints
              .map((s) => TrendPoint(s.x, s.y))
              .toList(growable: false),
          color: Colors.lightGreenAccent,
          unit: '%',
          curved: true,
        ),
        _LineCard(
          title: 'Реальный запас на 100% (вычисл.)',
          subtitle: 'км/SOC% × 100 · короткие поездки отфильтрованы',
          points: agg.realRangePer100,
          color: Colors.purpleAccent,
          unit: 'км',
          curved: true,
        ),
      ]),
    ];

    return ListView(
      padding: const EdgeInsets.all(12),
      children: children,
    );
  }

  /// 2-column grid on head unit, single column on phone. Mirrors the
  /// cascade the old Trends used; kept identical so the three form factors
  /// stay consistent with the rest of the app.
  Widget _chartGrid(bool isWide, List<Widget> cards) {
    if (isWide) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.0,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: cards,
      );
    }
    return Column(
      children: [
        for (final c in cards) ...[
          SizedBox(height: 190, child: c),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade500)),
    );
  }
}

class _TotalsGrid extends StatelessWidget {
  final TrendAggregate agg;
  final CostSettings cost;
  const _TotalsGrid({required this.agg, required this.cost});

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      _metric(Icons.route, 'Пробег',
          '${_fmt(agg.totalDistanceKm)} км'),
      _metric(Icons.bolt, 'Энергия',
          '${_fmt(agg.totalEnergyKwh)} кВт·ч'),
      if (cost.isConfigured)
        _metric(Icons.payments_outlined, 'Потрачено',
            '${cost.currencySymbol} ${_fmt(agg.totalCostMoney)}'),
      _metric(Icons.eco_outlined, 'Рекуперировано',
          '${_fmt(agg.totalRegenKwh)} кВт·ч'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.6,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      children: cards,
    );
  }

  Widget _metric(IconData icon, String label, String value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: Colors.grey.shade500),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  static String _fmt(double v) {
    if (v >= 10000) return NumberFormat('#,###', 'ru').format(v.round());
    if (v >= 100) return v.round().toString();
    return v.toStringAsFixed(1);
  }
}

/// Shared chart-card chrome: title row + window/unit footer + body.
class _ChartCardShell extends StatelessWidget {
  final String title;
  final String subtitle;
  final Color color;
  final String footer;
  final Widget body;
  const _ChartCardShell({
    required this.title,
    required this.subtitle,
    required this.color,
    required this.footer,
    required this.body,
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
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 1),
              child: Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ),
            const SizedBox(height: 8),
            Expanded(child: body),
            const SizedBox(height: 4),
            Text(footer,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}

/// A smooth (or monotone) line chart over a list of TrendPoints whose x is
/// epoch-ms. Used for cumulative distance, regen share, SOH, real range.
class _LineCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<TrendPoint> points;
  final Color color;
  final String unit;
  final bool curved;
  const _LineCard({
    required this.title,
    required this.subtitle,
    required this.points,
    required this.color,
    required this.unit,
    required this.curved,
  });

  @override
  Widget build(BuildContext context) {
    final spots =
        points.map((p) => FlSpot(p.x, p.y)).toList(growable: false);
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    final footer = points.isEmpty
        ? '—'
        : '${points.length} точек · ${minY.toStringAsFixed(1)}–${maxY.toStringAsFixed(1)} $unit';

    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: spots.length < 2
          ? _notEnough(spots.length)
          : LineChart(
              LineChartData(
                minY: minY - (maxY - minY).abs() * 0.05 - 0.1,
                maxY: maxY + (maxY - minY).abs() * 0.05 + 0.1,
                gridData: const FlGridData(show: false),
                titlesData: _leftOnlyTitles(),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: curved,
                    // Bézier can overshoot below the data floor; for
                    // non-negative quantities (km, %, range) that would
                    // draw an impossible dip. Prevent it.
                    preventCurveOverShooting: true,
                    curveSmoothness: 0.25,
                    color: color,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: color.withValues(alpha: 0.08),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Scatter of per-trip values (dots) with a smoothed moving-average line
/// on top. The dots stay honest (each is a real trip); the line conveys
/// the trend without faking smoothness on the underlying data.
class _ScatterTrendCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<TrendPoint> dots;
  final List<TrendPoint> trend;
  final Color color;
  final String unit;
  const _ScatterTrendCard({
    required this.title,
    required this.subtitle,
    required this.dots,
    required this.trend,
    required this.color,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final dotSpots = dots.map((p) => FlSpot(p.x, p.y)).toList(growable: false);
    final trendSpots =
        trend.map((p) => FlSpot(p.x, p.y)).toList(growable: false);
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final p in dots) {
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
    }
    final footer = dots.isEmpty
        ? '—'
        : '${dots.length} поездок · ${minY.toStringAsFixed(1)}–${maxY.toStringAsFixed(1)} $unit';

    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: dotSpots.isEmpty
          ? _notEnough(0)
          : LineChart(
              LineChartData(
                minY: minY - (maxY - minY).abs() * 0.08 - 0.1,
                maxY: maxY + (maxY - minY).abs() * 0.08 + 0.1,
                gridData: const FlGridData(show: false),
                titlesData: _leftOnlyTitles(),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // Dots: invisible line, visible points.
                  LineChartBarData(
                    spots: dotSpots,
                    isCurved: false,
                    barWidth: 0,
                    color: color.withValues(alpha: 0.0),
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (s, _, __, ___) => FlDotCirclePainter(
                        radius: 2.2,
                        color: color.withValues(alpha: 0.55),
                        strokeWidth: 0,
                      ),
                    ),
                  ),
                  // Moving-average trend line on top.
                  if (trendSpots.length >= 2)
                    LineChartBarData(
                      spots: trendSpots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      curveSmoothness: 0.25,
                      color: color,
                      barWidth: 2.5,
                      dotData: const FlDotData(show: false),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Per-month bar chart (cost). bars are PeriodBar; x is bucket index.
class _BarCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<PeriodBar> bars;
  final Color color;
  final String currency;
  const _BarCard({
    required this.title,
    required this.subtitle,
    required this.bars,
    required this.color,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    double maxV = 0;
    for (final b in bars) {
      if (b.value > maxV) maxV = b.value;
    }
    final total = bars.fold<double>(0, (a, b) => a + b.value);
    final footer = bars.isEmpty
        ? '—'
        : '${bars.length} мес · итого $currency ${total.round()}';

    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: bars.isEmpty
          ? _notEnough(0)
          : BarChart(
              BarChartData(
                maxY: maxV * 1.1 + 0.1,
                gridData: const FlGridData(show: false),
                titlesData: _leftOnlyTitles(),
                borderData: FlBorderData(show: false),
                barGroups: [
                  for (var i = 0; i < bars.length; i++)
                    BarChartGroupData(x: i, barRods: [
                      BarChartRodData(
                        toY: bars[i].value,
                        color: color,
                        width: bars.length > 12 ? 5 : 9,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(2)),
                      ),
                    ]),
                ],
              ),
            ),
    );
  }
}

// ── shared chart helpers ──

FlTitlesData _leftOnlyTitles() => FlTitlesData(
      rightTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 40,
          getTitlesWidget: (v, _) => Text(
            v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ),
      ),
    );

Widget _notEnough(int n) => Center(
      child: Text(
        n == 0 ? 'Нет данных' : '$n точка — мало для графика',
        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
      ),
    );
