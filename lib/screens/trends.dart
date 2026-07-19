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
///   3. Efficiency & health— v0.1.31+130 (Trends v2): weighted consumption
///                           and regen-share BARS per calendar bucket
///                           (day for the 30d window, month for 1y/all),
///                           SOH combo (pale BMS line + Ah-method dots
///                           from the soh_history table), cell-voltage
///                           spread per trip.
///
/// Period totals & per-period charts come from the Trips table (via
/// TrendAggregator); BMS SOH still comes from Snapshots, the Ah-method
/// SOH series from soh_history. Money uses CostSettings — hidden
/// entirely if not configured.
///
/// Charts stay touch-free (BarTouchData(enabled: false)) — the +44/+45
/// lesson: fl_chart 0.68 tooltip API blanked cards in release builds on
/// the head unit. Values live in static footers instead.
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
              // v0.1.31+130: bucket granularity follows the window — a
              // 30-day span reads as daily bars, a year+ as monthly.
              final bucket = _window == _Window.d30
                  ? TrendBucket.day
                  : TrendBucket.month;
              // v0.1.49+148 (K4): the aggregate is built from snapshots
              // too (odometer/SOC walks), so they are awaited BEFORE the
              // build — the honest figures can't render without them.
              // SOH history still pops in lazily as before.
              return FutureBuilder<List<Snapshot>>(
                future: svc.db.getSnapshotsInRange(from, now),
                builder: (context, snapSnap) {
                  if (!snapSnap.hasData) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  final snapshots = snapSnap.data!;
                  final agg = TrendAggregator.build(
                    trips,
                    costPerKwh: cost.costPerKwh,
                    bucket: bucket,
                    snapshots: snapshots,
                  );

                  if (agg.isEmpty) {
                    return _emptyState();
                  }

                  return FutureBuilder<List<SohHistoryData>>(
                    future: svc.db.getSohHistoryInRange(from, now),
                    builder: (context, sohSnap) {
                      final sohHistory =
                          sohSnap.data ?? const <SohHistoryData>[];
                      return _buildSections(context, agg, trips, snapshots,
                          sohHistory, cost, bucket);
                    },
                  );
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
    List<Trip> trips,
    List<Snapshot> snapshots,
    List<SohHistoryData> sohHistory,
    CostSettings cost,
    TrendBucket bucket,
  ) {
    final isWide = LayoutBreakpoints.useHeadUnitLayout(context);

    // BMS-reported SOH straight off snapshots — the pale context line of
    // the v0.1.31+130 SOH combo card.
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

    // v0.1.31+130: Ah-method (coulomb-counted) SOH points from the
    // append-only soh_history — the foreground dots of the combo card.
    final ahPoints = <FlSpot>[
      for (final h in sohHistory)
        FlSpot(h.computedAt.millisecondsSinceEpoch.toDouble(), h.sohAhPct),
    ];

    // v0.1.31+130: cell voltage spread per trip. Slow-moving pack-health
    // quantity, so a line over per-trip values is honest (unlike the old
    // per-trip consumption). Null / non-positive values are skipped.
    final cellSpreadPts = <TrendPoint>[
      for (final t in trips)
        if (t.maxCellSpreadMv != null && t.maxCellSpreadMv! > 0)
          TrendPoint(t.startedAt.millisecondsSinceEpoch.toDouble(),
              t.maxCellSpreadMv!),
    ];

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
    // missing. v0.1.31+130: the derived full-charge range (estRangeKm)
    // rides along in the same footer — deliberately a number, not a chart.
    final avgCons = (agg.totalDistanceKm > 0 && agg.totalEnergyKwh > 0)
        ? agg.totalEnergyKwh / agg.totalDistanceKm * 100
        : null;
    final estRange = agg.estRangeKm;
    final consFooter = avgCons == null
        ? '—'
        : S
                .of('trends.avg_cons_period_fmt')
                .replaceFirst('{x}', avgCons.toStringAsFixed(1)) +
            (estRange == null
                ? ''
                : ' · ${S.of('trends.est_range_fmt').replaceFirst('{n}', '${estRange.round()}')}');

    final avgRegen = agg.regenSharePerPeriod.isEmpty
        ? null
        : agg.regenSharePerPeriod
                .map((p) => p.value)
                .reduce((a, b) => a + b) /
            agg.regenSharePerPeriod.length;
    // v0.1.49+148 (K4): regen is the one figure still summed from TRIP
    // rows (snapshots don't know it), so its footer carries the coverage
    // marker — "одометр X · записано Y (Z%)" — telling the reader what
    // share of the real (odometer) distance those trips actually saw.
    // Null coverage (legacy trips-only fallback) omits the marker.
    final coverage = agg.tripCoveragePct;
    final coverageSuffix = coverage == null
        ? ''
        : ' · ${S.of('trends.coverage_fmt').replaceFirst('{x}', _fmtKm(agg.totalDistanceKm)).replaceFirst('{y}', _fmtKm(agg.recordedTripDistanceKm)).replaceFirst('{z}', coverage.toStringAsFixed(0))}';
    final regenFooter = (avgRegen == null
            ? '—'
            : S
                .of('trends.avg_regen_period_fmt')
                .replaceFirst('{x}', avgRegen.toStringAsFixed(1))
                .replaceFirst('{n}', '${agg.regenSharePerPeriod.length}')) +
        coverageSuffix;

    // v0.1.31+130 SOH combo footer: Ah-method "was → now" when the history
    // has points, "accumulating" until the first qualifying session; the
    // current BMS figure always closes the line ('—' if no snapshots).
    final bmsNow =
        sohPoints.isEmpty ? '—' : sohPoints.last.y.toStringAsFixed(1);
    final sohFooter = ahPoints.isEmpty
        ? S.of('trends.soh_accumulating').replaceFirst('{c}', bmsNow)
        : S
            .of('trends.soh_combo_fmt')
            .replaceFirst('{a}', ahPoints.first.y.toStringAsFixed(1))
            .replaceFirst('{b}', ahPoints.last.y.toStringAsFixed(1))
            .replaceFirst('{n}', '${ahPoints.length}')
            .replaceFirst('{c}', bmsNow);

    // v0.1.29+45 / v0.1.31+130: SOH y-axis bounds over BOTH series.
    // Hardcoding 95-100% would make a 95% pack "off-screen"; floating
    // with the data would make 0.5% wobble look catastrophic. Adaptive:
    // floor at min(measured, 95), ceiling at max(measured, 100).
    double? sohMinY, sohMaxY;
    if (sohPoints.isNotEmpty || ahPoints.isNotEmpty) {
      var measuredMin = double.infinity;
      var measuredMax = double.negativeInfinity;
      for (final p in sohPoints) {
        if (p.y < measuredMin) measuredMin = p.y;
        if (p.y > measuredMax) measuredMax = p.y;
      }
      for (final p in ahPoints) {
        if (p.y < measuredMin) measuredMin = p.y;
        if (p.y > measuredMax) measuredMax = p.y;
      }
      sohMinY = measuredMin < 95.0 ? measuredMin - 0.5 : 95.0;
      sohMaxY = measuredMax > 100.0 ? measuredMax + 0.5 : 100.0;
    }

    // v0.1.32+131: the Y axis is capped at p95×1.3 so one spike cannot
    // crush the series — the true maximum therefore moves into the footer
    // ("· peak N mV") where it stays visible as a number.
    double spreadPeak = 0;
    for (final pnt in cellSpreadPts) {
      if (pnt.y > spreadPeak) spreadPeak = pnt.y;
    }
    final spreadFooter = cellSpreadPts.isEmpty
        ? '—'
        : S
                .of('trends.cell_spread_fmt')
                .replaceFirst('{a}', cellSpreadPts.first.y.toStringAsFixed(1))
                .replaceFirst('{b}', cellSpreadPts.last.y.toStringAsFixed(1))
                .replaceFirst('{n}', '${cellSpreadPts.length}') +
            S
                .of('trends.cell_spread_peak')
                .replaceFirst('{p}', spreadPeak.toStringAsFixed(0));

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
          // v0.1.32+131: curved. _LineCard draws with
          // preventCurveOverShooting + 0.25 smoothness, so a monotone
          // series stays monotone — the daily "staircase" softens into
          // the smooth climb the field photos asked for.
          curved: true,
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
            // Cost is ALWAYS monthly (money per day is noise) — the axis
            // and text fallback keep month labels regardless of window.
            bucket: TrendBucket.month,
            footer: costFooter,
          ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3: efficiency (v0.1.31+130: period bars) ──
      _SectionLabel(S.of('trends.sec_efficiency')),
      _chartGrid(isWide, [
        _BarCard(
          title: S.of('trends.cons_by_period'),
          subtitle: S.of('trends.cons_by_period_sub'),
          bars: agg.consumptionPerPeriod,
          color: Colors.tealAccent,
          unit: S.of('trends.kwh100'),
          bucket: bucket,
          footer: consFooter,
        ),
        _BarCard(
          title: S.of('trends.regen_by_period'),
          subtitle: S.of('trends.regen_by_period_sub'),
          bars: agg.regenSharePerPeriod,
          color: Colors.greenAccent,
          unit: '%',
          bucket: bucket,
          footer: regenFooter,
        ),
      ]),
      const SizedBox(height: 20),

      // ── Section 3b: battery health (v0.1.31+130: combo + spread) ──
      _SectionLabel(S.of('trends.sec_health')),
      _chartGrid(isWide, [
        _SohComboCard(
          bmsPoints: sohPoints,
          ahPoints: ahPoints,
          footer: sohFooter,
          forcedMinY: sohMinY,
          forcedMaxY: sohMaxY,
        ),
        // v0.1.32+131: dots + rolling median instead of the +130
        // dot-to-dot line. Raw per-trip maxima are honest but noisy (load
        // transients are physics); the window-3 MEDIAN is robust to a
        // single spike — unlike the moving average removed in +130 — so
        // the trend line stays put when one trip latches an outlier.
        _SpreadCard(
          title: S.of('trends.cell_spread'),
          subtitle: S.of('trends.cell_spread_sub'),
          points: cellSpreadPts,
          color: Colors.orangeAccent,
          footer: spreadFooter,
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
      // v0.1.33+132: 58 dp was NOT enough — Card carries a default 4 dp
      // margin on every side (usable height 50), while the content needs
      // ~62 (8+16 header + 4 gap + ~26 value line + 8). The 19 pt values
      // painted straight across the bottom rounded edge (field photo
      // 2026-07-12). Margin is zeroed (the Row's 10 dp SizedBox already
      // spaces the cards), padding trimmed 10→8, height 58→64.
      return Row(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(child: SizedBox(height: 64, child: cards[i])),
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
      // v0.1.33+132: no implicit margin — the wide Row spaces cards itself
      // and the phone GridView has its own crossAxisSpacing; the default
      // 4 dp margin only ate fixed-height budget (see the Row above).
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
  // v0.1.31+130: draw a marker on every point (cell-spread card — the
  // per-trip samples are sparse enough that dots stay readable and make
  // clear where the real measurements are on the interpolated line).
  final bool showDots;
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
    this.showDots = false,
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
                    dotData: showDots
                        ? FlDotData(
                            show: true,
                            getDotPainter: (spot, pct, bar, i) =>
                                FlDotCirclePainter(
                              radius: 2.5,
                              color: color,
                              strokeWidth: 0,
                            ),
                          )
                        : const FlDotData(show: false),
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

/// v0.1.32+131: cell-spread card — raw per-trip maxima as DOTS with a
/// window-3 rolling MEDIAN drawn as the trend line.
///
/// Why not the +130 dot-to-dot line: per-trip max values are legitimately
/// noisy (load transients), and one latched outlier (the 195 mV artefact,
/// see halCellSpreadMv's pair gate) dragged both the line and the whole Y
/// scale. Here:
///   - dots show every real measurement, honestly;
///   - the median-3 line is robust to a single spike (a moving average —
///     removed in +130 — is not);
///   - the Y axis is capped at max(p95 × 1.3, 50 mV): a spike-dot renders
///     pinned to the top edge instead of crushing the series, and its true
///     value lives in the footer ("· peak N mV").
/// The median is display-only, computed here — it does NOT belong in the
/// aggregator (nothing downstream consumes it).
class _SpreadCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final List<TrendPoint> points;
  final Color color;
  final String footer;
  const _SpreadCard({
    required this.title,
    required this.subtitle,
    required this.points,
    required this.color,
    required this.footer,
  });

  /// Rolling median, window 3 (edges fall back to the raw value — a
  /// 1-point "median" is the value itself and keeps ends anchored).
  static List<double> _median3(List<double> ys) {
    if (ys.length < 3) return List.of(ys);
    final out = List<double>.filled(ys.length, 0);
    out[0] = ys[0];
    out[ys.length - 1] = ys[ys.length - 1];
    for (var i = 1; i < ys.length - 1; i++) {
      final a = ys[i - 1], b = ys[i], c = ys[i + 1];
      // median of three without allocating a sort.
      out[i] = a > b
          ? (b > c ? b : (a > c ? c : a))
          : (a > c ? a : (b > c ? c : b));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final n = points.length;
    final body = n < 2
        ? _notEnough(n)
        : Builder(builder: (context) {
            final ys = [for (final p in points) p.y];
            // p95 by rank on a sorted copy (n is small — trips in window).
            // v0.1.33+132: at n ≤ 11 the rank-p95 index IS the maximum, so
            // a single spike still owned the axis (the exact failure this
            // cap exists to prevent). With ≥ 4 points the axis reference
            // is capped at the SECOND-largest value — one outlier can
            // never set the scale; two independent high readings can,
            // which is no longer an outlier but a trend.
            final sorted = List<double>.from(ys)..sort();
            var rank = (0.95 * (sorted.length - 1)).round();
            if (sorted.length >= 4 && rank > sorted.length - 2) {
              rank = sorted.length - 2;
            }
            final p95 = sorted[rank];
            final maxY = (p95 * 1.3) > 50.0 ? (p95 * 1.3) : 50.0;

            // Raw dots, clamped to the axis cap so an outlier renders
            // pinned to the top edge (its number is in the footer).
            final rawSpots = [
              for (final p in points)
                FlSpot(p.x, p.y > maxY ? maxY : p.y),
            ];
            final med = _median3(ys);
            final medSpots = [
              for (var i = 0; i < n; i++)
                FlSpot(points[i].x, med[i] > maxY ? maxY : med[i]),
            ];

            return LineChart(
              LineChartData(
                minY: 0,
                maxY: maxY,
                gridData: const FlGridData(show: false),
                titlesData: _chartTitles(
                  bottom: _timeSideTitles(
                    minX: points.first.x,
                    maxX: points.last.x,
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // Median trend — the line the eye follows.
                  LineChartBarData(
                    spots: medSpots,
                    isCurved: false,
                    color: color,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: color.withValues(alpha: 0.08),
                    ),
                  ),
                  // Raw measurements — dots only (the connecting line is
                  // fully transparent; fl_chart has no line-less series).
                  LineChartBarData(
                    spots: rawSpots,
                    isCurved: false,
                    color: Colors.transparent,
                    barWidth: 1,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, pct, bar, i) =>
                          FlDotCirclePainter(
                        radius: 2.5,
                        color: color.withValues(alpha: 0.85),
                        strokeWidth: 0,
                      ),
                    ),
                  ),
                ],
              ),
            );
          });

    return _ChartCardShell(
      title: title,
      subtitle: subtitle,
      color: color,
      footer: footer,
      body: body,
    );
  }
}

/// v0.1.31+130: SOH combo card — the pale BMS-reported line from
/// snapshots as slow context, with the coulomb-counted (Ah-method)
/// estimates from soh_history drawn as full-opacity dots on top. The BMS
/// figure updates every snapshot but is the pack's own self-report; the
/// Ah points are rare (one per qualifying charge session) but
/// independent — seeing them against the BMS line is the whole point.
/// A SINGLE Ah point still renders (dots need no line), unlike _LineCard
/// which falls back to text below 2 points.
class _SohComboCard extends StatelessWidget {
  final List<FlSpot> bmsPoints;
  final List<FlSpot> ahPoints;
  final String footer;
  final double? forcedMinY;
  final double? forcedMaxY;
  const _SohComboCard({
    required this.bmsPoints,
    required this.ahPoints,
    required this.footer,
    this.forcedMinY,
    this.forcedMaxY,
  });

  @override
  Widget build(BuildContext context) {
    const color = Colors.lightGreenAccent;
    // Time axis spans BOTH series.
    double minX = double.infinity, maxX = double.negativeInfinity;
    for (final p in bmsPoints) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
    }
    for (final p in ahPoints) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
    }
    final hasBmsLine = bmsPoints.length >= 2;
    final hasAnything = bmsPoints.isNotEmpty || ahPoints.isNotEmpty;

    return _ChartCardShell(
      title: 'SOH',
      subtitle: S.of('trends.soh_combo_sub'),
      color: color,
      footer: footer,
      body: !hasAnything
          ? _notEnough(0)
          : LineChart(
              LineChartData(
                minY: forcedMinY,
                maxY: forcedMaxY,
                gridData: const FlGridData(show: false),
                titlesData: _chartTitles(
                  bottom: _timeSideTitles(minX: minX, maxX: maxX),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  // BMS context line: pale, no markers. Needs ≥2 points
                  // to be a line at all; a lone BMS sample adds nothing.
                  if (hasBmsLine)
                    LineChartBarData(
                      spots: bmsPoints,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      curveSmoothness: 0.25,
                      color: color.withValues(alpha: 0.25),
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  // Ah-method estimates: invisible line, visible points —
                  // same dots-only trick the old scatter card used.
                  if (ahPoints.isNotEmpty)
                    LineChartBarData(
                      spots: ahPoints,
                      isCurved: false,
                      barWidth: 0,
                      color: color.withValues(alpha: 0.0),
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (s, _, __, ___) =>
                            FlDotCirclePainter(
                          radius: 3.5,
                          color: color,
                          strokeWidth: 0,
                        ),
                      ),
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
  // v0.1.31+130: the card is no longer money-only. Exactly one of
  // [currency] (prefix, cost card — behaviour identical to before) or
  // [unit] (suffix, consumption / regen bars) should be provided; both
  // null renders a bare number.
  final String? currency;
  final String? unit;
  // v0.1.31+130: bucket granularity — drives the axis / text-fallback
  // label format (day → dd.MM, month → the original month logic).
  final TrendBucket bucket;
  // v0.1.29+45: footer composed by the caller.
  final String footer;
  const _BarCard({
    required this.title,
    required this.subtitle,
    required this.bars,
    required this.color,
    this.currency,
    this.unit,
    required this.bucket,
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
          bottom: _periodBarSideTitles(bars, bucket),
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
                // v0.1.32+131: bottom-to-top gradient instead of the flat
                // fill — same hue, softer body.
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [color.withValues(alpha: 0.55), color],
                ),
                // v0.1.32+131: stepped width. The old `>12 ? 5 : 9` drew
                // matchsticks on a 13-day window; the ladder keeps bars
                // readable across every window the UI offers.
                width: bars.length <= 8
                    ? 14
                    : bars.length <= 16
                        ? 10
                        : bars.length <= 31
                            ? 6
                            : 4,
                borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4)),
                // v0.1.32+131: faint full-height track behind each rod —
                // sparse bars stop floating in empty space.
                backDrawRodData: BackgroundBarChartRodData(
                  show: true,
                  toY: maxV * 1.1 + 0.1,
                  color: Colors.white.withValues(alpha: 0.04),
                ),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _textFallback() {
    // v0.1.31+130: label follows the bucket (dd.MM for day bars), value
    // follows the card kind — currency prefixes (unchanged for cost),
    // unit suffixes (consumption / regen).
    final labelFmt = bucket == TrendBucket.day
        ? DateFormat('dd.MM').format
        : _fmtMonthRu;
    String valueText(double v) {
      if (currency != null) return '$currency ${v.toStringAsFixed(1)}';
      if (unit != null) return '${v.toStringAsFixed(1)} $unit';
      return v.toStringAsFixed(1);
    }

    final lines = <Widget>[
      for (final b in bars)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(labelFmt(b.start),
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade400)),
              Text(valueText(b.value),
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
/// v0.1.31+130: generalized to both bucket kinds — day buckets label as
/// "dd.MM", month buckets keep the original month / MM.yy logic.
SideTitles _periodBarSideTitles(List<PeriodBar> bars, TrendBucket bucket) {
  if (bars.isEmpty) return const SideTitles(showTitles: false);
  final n = bars.length;
  final step = ((n + 3) / 4).floor().clamp(1, n);
  final String Function(DateTime) fmt;
  if (bucket == TrendBucket.day) {
    final f = DateFormat('dd.MM');
    fmt = f.format;
  } else {
    // If the bars span more than one calendar year, drop the year in too.
    final firstY = bars.first.start.year;
    final lastY = bars.last.start.year;
    if (firstY == lastY) {
      fmt = _fmtMonthRu;
    } else {
      final f = DateFormat('MM.yy');
      fmt = f.format;
    }
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
