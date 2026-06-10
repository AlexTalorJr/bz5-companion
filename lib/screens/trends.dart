import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
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
  // v0.1.29+45: 30d is a saner default for new users with limited history
  // (a freshly-installed copy will have days of data, not a year). The
  // user can step up to 1y or all once history accrues. Previous default
  // (1y) is still one tap away.
  _Window _window = _Window.d30;

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
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
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
            Text(S.of('trends.empty_title'),
                style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 8),
            Text(
              S.of('trends.empty_hint'),
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
    // v0.1.29+44: keep x as absolute epoch-ms (was: subtracted t0 offset).
    // The date axis on bottomTitles below needs real wall-clock x values to
    // format as dates; the previous t0-relative offset would have produced
    // ms-since-first-snapshot, which formats as "1970-01-01" forever.
    final sohPoints = <FlSpot>[];
    if (snapshots.isNotEmpty) {
      for (final s in snapshots) {
        final v = s.soh;
        if (v == null) continue;
        sohPoints
            .add(FlSpot(s.capturedAt.millisecondsSinceEpoch.toDouble(), v));
      }
    }

    // v0.1.29+45: pre-compute the per-card footers so every chart shell
    // ends with one meaningful number ("итого N", "средн. X", "было →
    // сейчас") instead of the generic "N точек · min-max" template.
    // The shell still shows whatever string we hand it — these are just
    // composed at this layer where we have all the aggregate fields.
    final cumLast = agg.totalDistanceKm;
    final cumFooter = agg.cumulativeOdometer.isEmpty
        ? '—'
        : S
            .of('trends.total_fmt')
            .replaceFirst('{km}', _fmtKm(cumLast))
            .replaceFirst('{n}', '${agg.tripCount}');

    final costTotal = agg.costPerMonth.fold<double>(0, (a, b) => a + b.value);
    final costFooter = agg.costPerMonth.isEmpty
        ? '—'
        : S
            .of('trends.cost_total_fmt')
            .replaceFirst('{c}', cost.currencySymbol)
            .replaceFirst('{v}', costTotal.toStringAsFixed(1))
            .replaceFirst('{n}', '${agg.costPerMonth.length}');

    // Weighted average consumption: total energy / total distance × 100.
    // More honest than averaging per-trip consumption (which would
    // overweight short trips). Falls back to '—' when either total is
    // missing.
    final avgCons = (agg.totalDistanceKm > 0 && agg.totalEnergyKwh > 0)
        ? agg.totalEnergyKwh / agg.totalDistanceKm * 100
        : null;
    final consFooter = avgCons == null
        ? '—'
        : S
            .of('trends.avg_cons_fmt')
            .replaceFirst('{x}', avgCons.toStringAsFixed(1))
            .replaceFirst('{n}', '${agg.consumptionPerTrip.length}');

    final avgRegen = agg.regenSharePct.isEmpty
        ? null
        : agg.regenSharePct
                .map((p) => p.y)
                .reduce((a, b) => a + b) /
            agg.regenSharePct.length;
    final regenFooter = avgRegen == null
        ? '—'
        : S
            .of('trends.avg_regen_fmt')
            .replaceFirst('{x}', avgRegen.toStringAsFixed(1))
            .replaceFirst('{n}', '${agg.regenSharePct.length}');

    // SOH "было → сейчас": pulls the chronological first and last SOH
    // sample from the snapshot stream. Both are non-null here because
    // sohPoints is built by filtering out nulls upstream.
    final sohWas = sohPoints.isEmpty ? null : sohPoints.first.y;
    final sohNow = sohPoints.isEmpty ? null : sohPoints.last.y;
    final sohFooter = (sohWas == null || sohNow == null)
        ? '—'
        : S
            .of('trends.soh_fmt')
            .replaceFirst('{a}', sohWas.toStringAsFixed(1))
            .replaceFirst('{b}', sohNow.toStringAsFixed(1))
            .replaceFirst('{n}', '${sohPoints.length}');

    // v0.1.29+45: SOH y-axis bounds. Hardcoding 95-100% would make a
    // 95% pack "off-screen"; floating with the data would make 0.5%
    // wobble look catastrophic. Adaptive: floor at min(measured, 95),
    // ceiling at max(measured, 100). A healthy pack lives in 95-100;
    // a worn one extends the chart downward without clipping.
    double? sohMinY, sohMaxY;
    if (sohPoints.isNotEmpty) {
      var measuredMin = double.infinity;
      var measuredMax = double.negativeInfinity;
      for (final p in sohPoints) {
        if (p.y < measuredMin) measuredMin = p.y;
        if (p.y > measuredMax) measuredMax = p.y;
      }
      sohMinY = measuredMin < 95.0 ? measuredMin - 0.5 : 95.0;
      sohMaxY = measuredMax > 100.0 ? measuredMax + 0.5 : 100.0;
    }

    final avgRange = agg.realRangePer100.isEmpty
        ? null
        : agg.realRangePer100.map((p) => p.y).reduce((a, b) => a + b) /
            agg.realRangePer100.length;
    final lastRange = agg.realRangePer100.isEmpty
        ? null
        : agg.realRangePer100.last.y;
    final rangeFooter = (avgRange == null || lastRange == null)
        ? '—'
        : S
            .of('trends.range_fmt')
            .replaceFirst('{a}', '${avgRange.round()}')
            .replaceFirst('{b}', '${lastRange.round()}')
            .replaceFirst('{n}', '${agg.realRangePer100.length}');

    final children = <Widget>[
      // ── Section 1: period totals ──
      _SectionLabel(S.of('trends.sec_totals')),
      _TotalsGrid(agg: agg, cost: cost),
      const SizedBox(height: 20),

      // ── Section 2: cumulative & cost ──
      _SectionLabel(S.of('trends.sec_cumulative')),
      _chartGrid(isWide, [
        _LineCard(
          title: S.of('trends.cumulative_dist'),
          subtitle: S.of('trends.cumulative_dist_sub'),
          points: agg.cumulativeOdometer,
          color: Colors.lightBlueAccent,
          unit: S.of('trends.km'),
          // monotone by nature — no curve (overshoot would break monotonicity)
          curved: false,
          footer: cumFooter,
        ),
        if (cost.isConfigured)
          _BarCard(
            title: S.of('trends.cost_by_month'),
            subtitle: S
                .of('trends.cost_by_month_sub')
                .replaceFirst('{v}', cost.currencySymbol),
            bars: agg.costPerMonth,
            color: Colors.amberAccent,
            currency: cost.currencySymbol,
            footer: costFooter,
          ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3: efficiency ──
      _SectionLabel(S.of('trends.sec_efficiency')),
      _chartGrid(isWide, [
        _ScatterTrendCard(
          title: S.of('trends.avg_cons'),
          subtitle: S.of('trends.avg_cons_sub'),
          dots: agg.consumptionPerTrip,
          trend: agg.consumptionTrendLine,
          color: Colors.tealAccent,
          unit: S.of('trends.kwh100'),
          footer: consFooter,
        ),
        _LineCard(
          title: S.of('trends.regen_share'),
          subtitle: S.of('trends.regen_share_sub'),
          points: agg.regenSharePct,
          color: Colors.greenAccent,
          unit: '%',
          curved: true,
          footer: regenFooter,
        ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3b: battery health ──
      _SectionLabel(S.of('trends.sec_health')),
      _chartGrid(isWide, [
        _LineCard(
          title: 'SOH',
          subtitle: S.of('trends.soh_sub'),
          points: sohPoints
              .map((s) => TrendPoint(s.x, s.y))
              .toList(growable: false),
          color: Colors.lightGreenAccent,
          unit: '%',
          curved: true,
          footer: sohFooter,
          forcedMinY: sohMinY,
          forcedMaxY: sohMaxY,
        ),
        _LineCard(
          title: S.of('trends.real_range'),
          subtitle: S.of('trends.real_range_sub'),
          points: agg.realRangePer100,
          color: Colors.purpleAccent,
          unit: S.of('trends.km'),
          curved: true,
          footer: rangeFooter,
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
    final isWide = LayoutBreakpoints.useHeadUnitLayout(context);
    final cards = <Widget>[
      _metric(
          Icons.route,
          S.of('trends.m_dist'),
          S
              .of('trends.m_km_fmt')
              .replaceFirst('{n}', _fmt(agg.totalDistanceKm))),
      _metric(
          Icons.bolt,
          S.of('trends.m_energy'),
          S
              .of('trends.m_kwh_fmt')
              .replaceFirst('{n}', _fmt(agg.totalEnergyKwh))),
      if (cost.isConfigured)
        _metric(Icons.payments_outlined, S.of('trends.m_spent'),
            '${cost.currencySymbol} ${_fmt(agg.totalCostMoney)}'),
      _metric(
          Icons.eco_outlined,
          S.of('trends.m_regen'),
          S
              .of('trends.m_kwh_fmt')
              .replaceFirst('{n}', _fmt(agg.totalRegenKwh))),
    ];
    // v0.1.29+36: totals were a tall 2×2 grid with a lot of dead vertical
    // space (owner feedback). On head unit lay them out in ONE row; on
    // phone keep two columns but make the cells much flatter.
    if (isWide) {
      return Row(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(child: SizedBox(height: 58, child: cards[i])),
            if (i != cards.length - 1) const SizedBox(width: 10),
          ],
        ],
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 3.4,
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

  static String _fmt(double v) => _fmtKm(v);
}

/// v0.1.29+45: shared number formatter for footer strings and totals
/// alike. The same rule used to live as a static inside _TotalsGrid; we
/// hoist it to file scope so the new footer composition in _buildSections
/// can reach it without subclassing or threading. Behaviour identical:
/// ≥10000 → "12,345" (ru thousands sep), ≥100 → "147", else "12.3".
String _fmtKm(double v) {
  if (v >= 10000) return NumberFormat('#,###', 'ru').format(v.round());
  if (v >= 100) return v.round().toString();
  return v.toStringAsFixed(1);
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
  // v0.1.29+45: footer composed by the caller (e.g. "итого 199 км").
  // Old behaviour ("N точек · min-max") was generic and unhelpful with
  // a single useful number per chart.
  final String footer;
  // v0.1.29+45: optional fixed Y bounds. Used by SOH to lock the visual
  // range to 95-100% (adaptive: extends downward if a sample falls
  // below). Null → auto-bounds from data with the old padding rule.
  final double? forcedMinY;
  final double? forcedMaxY;
  const _LineCard({
    required this.title,
    required this.subtitle,
    required this.points,
    required this.color,
    required this.unit,
    required this.curved,
    required this.footer,
    this.forcedMinY,
    this.forcedMaxY,
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
    // Auto-bounds with proportional padding (5%). Forced bounds, when
    // supplied, override this — used by SOH to keep the visual range
    // stable across the typical 95-100% band.
    final autoMinY = minY - (maxY - minY).abs() * 0.05 - 0.1;
    final autoMaxY = maxY + (maxY - minY).abs() * 0.05 + 0.1;
    final effectiveMinY = forcedMinY ?? autoMinY;
    final effectiveMaxY = forcedMaxY ?? autoMaxY;

    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: spots.length < 2
          ? _notEnough(spots.length)
          : LineChart(
              LineChartData(
                minY: effectiveMinY,
                maxY: effectiveMaxY,
                gridData: const FlGridData(show: false),
                titlesData: _chartTitles(
                  bottom: _timeSideTitles(
                    minX: spots.first.x,
                    maxX: spots.last.x,
                  ),
                ),
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
  // v0.1.29+45: footer composed by the caller — see _LineCard for
  // the rationale. Same change.
  final String footer;
  const _ScatterTrendCard({
    required this.title,
    required this.subtitle,
    required this.dots,
    required this.trend,
    required this.color,
    required this.unit,
    required this.footer,
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
                titlesData: _chartTitles(
                  bottom: _timeSideTitles(
                    minX: dotSpots.first.x,
                    maxX: dotSpots.last.x,
                  ),
                ),
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
///
/// v0.1.29+45 redesign — the v0.1.29+44 attempt to round the default
/// fl_chart tooltip via barTouchData/BarTouchTooltipData rendered an
/// empty white card in production (the v44 build on real hardware
/// showed a blank box where the chart should be — root cause: tooltip
/// API in fl_chart 0.68.x has a quirky edge case that release-builds
/// trip over). The redesign drops the custom tooltip entirely and
/// surfaces the rounded value as a static label above each bar plus
/// in the footer. No touch handler, no fragile API contract.
class _BarCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<PeriodBar> bars;
  final Color color;
  final String currency;
  // v0.1.29+45: footer composed by the caller.
  final String footer;
  const _BarCard({
    required this.title,
    required this.subtitle,
    required this.bars,
    required this.color,
    required this.currency,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: _body(),
    );
  }

  Widget _body() {
    if (bars.isEmpty) return _notEnough(0);

    // v0.1.29+45: with one or two months a "bar chart" is just rectangles
    // with no comparison to make. Show the months as text instead — same
    // information, no fake graph. The bar chart re-engages at 3+ months,
    // where there's actually a shape to read.
    if (bars.length < 3) return _textFallback();

    double maxV = 0;
    for (final b in bars) {
      if (b.value > maxV) maxV = b.value;
    }

    // v0.1.29+45: bar chart is now built WITHOUT any BarTouchData or
    // BarTouchTooltipData. The v44 attempt to round the default tooltip
    // by supplying a custom BarTouchTooltipData rendered an empty white
    // card on the BZ5 head unit — the fl_chart 0.68 release-mode build
    // tripped over something in that code path. Per-bar value lives in
    // the footer ("итого Br 11.7") which is read-at-a-glance and needs
    // no tap. Touch is disabled outright so the same API surface is
    // never reached.
    return BarChart(
      BarChartData(
        maxY: maxV * 1.1 + 0.1,
        gridData: const FlGridData(show: false),
        titlesData: _chartTitles(
          bottom: _monthBarSideTitles(bars),
        ),
        borderData: FlBorderData(show: false),
        // v0.1.29+46: BarTouchData in fl_chart 0.68 has no const ctor —
        // CI release-build catches this where local analyze may not.
        // The instance is still effectively constant (no state), just
        // not literal-const. Leave 'enabled: false' as the only field
        // for the same reason as +45: never reach the tooltip API.
        barTouchData: BarTouchData(enabled: false),
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
    );
  }

  Widget _textFallback() {
    final lines = <Widget>[
      for (final b in bars)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmtMonthRu(b.start),
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade400)),
              Text('$currency ${b.value.toStringAsFixed(1)}',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: color)),
            ],
          ),
        ),
    ];
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: lines,
        ),
      ),
    );
  }
}

/// v0.1.29+49: belt-and-suspenders short month name in Russian.
/// main.dart initializes the 'ru' locale before runApp, so the intl
/// path is the normal one. But if a future change drops that init or
/// the intl data file is missing on some build flavour, the cost
/// card and year-window axis labels would silently render as blank
/// white boxes (LocaleDataException → release-mode ErrorWidget). The
/// try/catch with a hardcoded fallback guarantees a glyph either way.
const _ruMonthShort = [
  'янв', 'фев', 'мар', 'апр', 'май', 'июн',
  'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
];
// v0.1.29+60: English fallback mirrors the Russian one. intl's 'en'
// data is built in (no initializeDateFormatting needed), so the catch
// branch is nearly unreachable for en — kept for symmetry.
const _enMonthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
String _fmtMonthRu(DateTime d) {
  final ru = S.locale == 'ru';
  try {
    return DateFormat.MMM(ru ? 'ru' : 'en').format(d);
  } catch (_) {
    return (ru ? _ruMonthShort : _enMonthShort)[d.month - 1];
  }
}

// ── shared chart helpers ──

/// v0.1.29+44: was `_leftOnlyTitles` — now optionally accepts a bottom
/// axis. Bottom defaults to hidden (preserves the old behaviour for any
/// caller that doesn't have a meaningful x-axis to draw).
FlTitlesData _chartTitles({SideTitles? bottom}) => FlTitlesData(
      rightTitles:
          const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      bottomTitles: AxisTitles(
        sideTitles: bottom ?? const SideTitles(showTitles: false),
      ),
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

/// v0.1.29+44: date labels for a continuous time axis (x = epoch ms).
///
/// Picks ~3 evenly-spaced ticks across the visible range. We skip ticks
/// too close to the edges so they don't collide with the y-axis label
/// strip on the left or run past the right card edge. The label format
/// adapts to the span:
///   • ≤45 days  → "dd.MM"   (30-day window, individual days readable)
///   • ≤400 days → "MMM"     (year window, month name in ru locale)
///   • else      → "MM.yy"   (all-time, compact month+year)
///
/// Returns a no-label SideTitles when the span is degenerate (single
/// point or all-identical x); the chart still renders, just without
/// dates underneath — better than an interval of 0 crashing fl_chart.
SideTitles _timeSideTitles({required double minX, required double maxX}) {
  final span = maxX - minX;
  if (span <= 0) return const SideTitles(showTitles: false);
  // 3 interior ticks ⇒ partition into 4 segments. Step is the chart x
  // unit (epoch-ms) between consecutive ticks; fl_chart uses it for
  // `interval` directly.
  const ticks = 3;
  final step = span / (ticks + 1);
  // Choose format by visible span.
  final spanDays = span / 86400000.0;
  final String Function(DateTime) fmt;
  if (spanDays <= 45) {
    final f = DateFormat('dd.MM');
    fmt = f.format;
  } else if (spanDays <= 400) {
    fmt = _fmtMonthRu;
  } else {
    final f = DateFormat('MM.yy');
    fmt = f.format;
  }
  return SideTitles(
    showTitles: true,
    reservedSize: 20,
    interval: step,
    getTitlesWidget: (v, meta) {
      // Drop ticks that hug the extremes — those collide with the y-axis
      // numbers on the left and overflow the card on the right.
      if (v <= minX + step * 0.4 || v >= maxX - step * 0.4) {
        return const SizedBox.shrink();
      }
      final dt = DateTime.fromMillisecondsSinceEpoch(v.toInt());
      return SideTitleWidget(
        axisSide: meta.axisSide,
        space: 2,
        child: Text(
          fmt(dt),
          style: const TextStyle(fontSize: 9, color: Colors.grey),
        ),
      );
    },
  );
}

/// v0.1.29+44: month labels for the per-month bar chart. x is bucket
/// index (0..bars.length-1), so we look up `bars[i].start` to get the
/// real DateTime. Stride = ceil(n / 4) keeps the count of labels low
/// enough to fit on the narrow head-unit width without overlap; for
/// n ≤ 12 (year window) we still cap at 4 labels (March/June/Sep/Dec
/// pattern on a 12-bucket axis). Format adapts to multi-year ranges.
SideTitles _monthBarSideTitles(List<PeriodBar> bars) {
  if (bars.isEmpty) return const SideTitles(showTitles: false);
  final n = bars.length;
  final step = ((n + 3) / 4).floor().clamp(1, n);
  // If the bars span more than one calendar year, drop the year in too.
  final firstY = bars.first.start.year;
  final lastY = bars.last.start.year;
  final String Function(DateTime) fmt;
  if (firstY == lastY) {
    fmt = _fmtMonthRu;
  } else {
    final f = DateFormat('MM.yy');
    fmt = f.format;
  }
  return SideTitles(
    showTitles: true,
    reservedSize: 20,
    interval: 1.0,
    getTitlesWidget: (v, meta) {
      final i = v.round();
      if (i < 0 || i >= bars.length) return const SizedBox.shrink();
      if (i % step != 0) return const SizedBox.shrink();
      return SideTitleWidget(
        axisSide: meta.axisSide,
        space: 2,
        child: Text(
          fmt(bars[i].start),
          style: const TextStyle(fontSize: 9, color: Colors.grey),
        ),
      );
    },
  );
}

Widget _notEnough(int n) => Center(
      child: Text(
        n == 0
            ? S.of('common.no_data')
            : S.of('trends.not_enough').replaceFirst('{n}', '$n'),
        style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
      ),
    );
