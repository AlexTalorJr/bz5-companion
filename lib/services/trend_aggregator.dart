import '../data/database.dart';

/// v0.1.29+35: pure aggregation layer behind the rebuilt Trends tab.
///
/// Trends used to draw six flat line charts straight off the Snapshots
/// table (2-min cadence). On that cadence most of them barely moved —
/// odometer and cycle-count were monotone ramps, SOC a sawtooth with no
/// context. This layer instead derives *trip-level* aggregates that
/// actually change in a meaningful way over a long window:
///
///   • Period totals   — distance, energy, money spent, energy regened.
///   • Cumulative      — running odometer (a curve whose shape means
///                        something, unlike the raw monotone reading).
///   • Per-month bars  — money spent per calendar month (seasonality).
///   • Behaviour       — average consumption per trip + a smoothed
///                        (moving-average) trend line over those points,
///                        and regen share (% of energy returned).
///   • Health          — SOH and a computed real-range-per-100% figure
///                        that tracks degradation in km rather than an
///                        abstract %.
///
/// Everything here is null-safe by necessity: regenEnergyKwh and the
/// precise SOC delta only exist from schema v2 / v5 onward, so historic
/// trips may have nulls. The rule throughout is *skip nulls, never coerce
/// to zero* — a zero would silently understate a period total or drag a
/// trend line to the floor. A period with no usable data reports null /
/// empty so the UI can say "no data" instead of drawing a lie.
///
/// This file has no Flutter / DB-query dependencies beyond the generated
/// `Trip` row class, which keeps it unit-testable in isolation.

/// A single (x, y) sample for a chart. [x] is encoded as
/// epoch-milliseconds-as-double so fl_chart can place it on a numeric
/// axis without us threading DateTime through the widget layer.
class TrendPoint {
  final double x;
  final double y;
  const TrendPoint(this.x, this.y);
}

/// One calendar bucket (a month, for the per-month bar chart).
class PeriodBar {
  final DateTime start; // first instant of the bucket
  final double value;
  const PeriodBar(this.start, this.value);
}

/// Everything the Trends tab needs for one selected window, computed in
/// a single pass so the widget layer stays dumb.
class TrendAggregate {
  // ── Period totals (section 1) ──
  final double totalDistanceKm;
  final double totalEnergyKwh;
  final double totalCostMoney; // in user currency units; 0 if not configured
  final double totalRegenKwh;
  final int tripCount;

  // ── Cumulative + per-period (section 2) ──
  final List<TrendPoint> cumulativeOdometer; // running distance over window
  final List<PeriodBar> costPerMonth;

  // ── Behaviour (section 3) ──
  final List<TrendPoint> consumptionPerTrip; // raw dots, kWh/100km
  final List<TrendPoint> consumptionTrendLine; // smoothed (moving average)
  final List<TrendPoint> regenSharePct; // % regened of energy used, per trip

  // ── Health (section 3) ──
  final List<TrendPoint> soh; // % from trips that carry it (rare) — see note
  final List<TrendPoint> realRangePer100; // km per 100% SOC, computed

  const TrendAggregate({
    required this.totalDistanceKm,
    required this.totalEnergyKwh,
    required this.totalCostMoney,
    required this.totalRegenKwh,
    required this.tripCount,
    required this.cumulativeOdometer,
    required this.costPerMonth,
    required this.consumptionPerTrip,
    required this.consumptionTrendLine,
    required this.regenSharePct,
    required this.soh,
    required this.realRangePer100,
  });

  bool get isEmpty => tripCount == 0;

  static const empty = TrendAggregate(
    totalDistanceKm: 0,
    totalEnergyKwh: 0,
    totalCostMoney: 0,
    totalRegenKwh: 0,
    tripCount: 0,
    cumulativeOdometer: [],
    costPerMonth: [],
    consumptionPerTrip: [],
    consumptionTrendLine: [],
    regenSharePct: [],
    soh: [],
    realRangePer100: [],
  );
}

/// Minimum |ΔSOC| (percentage points) a trip must cover before we trust
/// its derived range/consumption. Short hops produce wild km-per-%
/// figures (drive 200 m on a 1% tick → "20000 km range"), so we filter
/// them out of the behaviour/health curves. They still count toward
/// period *totals*, which are robust to it.
const double kMinSocDeltaForRange = 5.0;

/// v0.1.29+45: companion floor on raw distance for the real-range curve.
/// The SOC-delta filter alone lets through trips with a real short
/// distance and a real moderate ΔSOC (e.g. a 1 km hop that happened to
/// straddle a 5% tick at the start), which yields plausibly-looking but
/// wildly low km/100% values (saw 2.4 km/100% in the field on a 7-day
/// window). 3 km is the smallest distance that still produces a number
/// whose noise floor is below the signal — short of that, BMS SOC
/// quantization dominates the answer.
const double kMinDistForRangeKm = 3.0;

/// Window over which the consumption trend line is smoothed, in trips.
/// Centered moving average; odd number keeps it symmetric.
const int kConsumptionSmoothingWindow = 5;

class TrendAggregator {
  /// Build the full aggregate for [trips] (assumed already filtered to the
  /// window and sorted ascending by startedAt — getTripsInRange does both).
  ///
  /// [costPerKwh] is the user's tariff (0 ⇒ cost section reads as zero,
  /// which the UI hides when CostSettings.isConfigured is false).
  static TrendAggregate build(List<Trip> trips, {required double costPerKwh}) {
    if (trips.isEmpty) return TrendAggregate.empty;

    double totalDistance = 0;
    double totalEnergy = 0;
    double totalRegen = 0;

    final cumulative = <TrendPoint>[];
    final consumptionDots = <TrendPoint>[];
    final regenShare = <TrendPoint>[];
    final sohPts = <TrendPoint>[];
    final rangePts = <TrendPoint>[];
    final monthEnergy = <DateTime, double>{};

    double runningDistance = 0;

    for (final t in trips) {
      final x = t.startedAt.millisecondsSinceEpoch.toDouble();

      // ── Totals + cumulative (robust: any present field counts) ──
      final dist = t.distanceKm;
      if (dist != null && dist > 0) {
        totalDistance += dist;
        runningDistance += dist;
        cumulative.add(TrendPoint(x, runningDistance));
      }

      final energy = t.energyUsedKwh;
      if (energy != null && energy > 0) {
        totalEnergy += energy;
        // Per-month bucket keyed by first-of-month.
        final m = DateTime(t.startedAt.year, t.startedAt.month);
        monthEnergy[m] = (monthEnergy[m] ?? 0) + energy;
      }

      final regen = t.regenEnergyKwh;
      if (regen != null && regen > 0) {
        totalRegen += regen;
        if (energy != null && energy > 0) {
          // Regen as a share of energy drawn. Clamp to a sane ceiling —
          // a malformed trip with regen > used would otherwise spike.
          final share = (regen / energy * 100).clamp(0.0, 100.0);
          regenShare.add(TrendPoint(x, share));
        }
      }

      // ── Behaviour: consumption per trip (kWh/100km) ──
      // Prefer the stored aggregate; fall back to deriving it if both
      // distance and energy are present but the field wasn't populated
      // (older trips before avgConsumptionKwh100km existed).
      double? consumption = t.avgConsumptionKwh100km;
      if (consumption == null &&
          dist != null &&
          dist > 0 &&
          energy != null &&
          energy > 0) {
        consumption = energy / dist * 100;
      }
      if (consumption != null && consumption > 0 && consumption < 100) {
        consumptionDots.add(TrendPoint(x, consumption));
      }

      // ── Health: real range per 100% SOC ──
      // km / |ΔSOC| × 100, only for trips that moved enough SOC AND
      // enough distance to be meaningful (see kMinSocDeltaForRange and
      // kMinDistForRangeKm). v0.1.29+45 added the distance floor — the
      // SOC-delta gate alone was letting short hops with real ΔSOC
      // through (e.g. a 1 km hop straddling a SOC tick → 2.4 km/100%).
      final startSoc = t.startSoc;
      final endSoc = t.endSoc;
      if (dist != null &&
          dist >= kMinDistForRangeKm &&
          startSoc != null &&
          endSoc != null) {
        final socDelta = (startSoc - endSoc).abs();
        if (socDelta >= kMinSocDeltaForRange) {
          rangePts.add(TrendPoint(x, dist / socDelta * 100));
        }
      }
    }

    // SOH lives on the Snapshots table, not Trips — the widget passes it
    // in separately (see addSohPoints). We expose an empty list here and
    // let the caller merge; keeping the signature trip-only preserves
    // testability. (Left empty: callers that have snapshot SOH use the
    // dedicated snapshot path in the widget.)

    final smoothed = _movingAverage(consumptionDots, kConsumptionSmoothingWindow);

    final costMonths = monthEnergy.entries
        .map((e) => PeriodBar(e.key, e.value * costPerKwh))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    return TrendAggregate(
      totalDistanceKm: totalDistance,
      totalEnergyKwh: totalEnergy,
      totalCostMoney: totalEnergy * costPerKwh,
      totalRegenKwh: totalRegen,
      tripCount: trips.length,
      cumulativeOdometer: cumulative,
      costPerMonth: costMonths,
      consumptionPerTrip: consumptionDots,
      consumptionTrendLine: smoothed,
      regenSharePct: regenShare,
      soh: sohPts,
      realRangePer100: rangePts,
    );
  }

  /// Centered moving average over [points] with the given odd [window].
  /// Returns a smoothed line that never overshoots the data range (unlike
  /// a Bézier curve), so it's safe for quantities that can't go negative.
  /// Points keep their original x so the smoothed line aligns with dots.
  static List<TrendPoint> _movingAverage(List<TrendPoint> points, int window) {
    if (points.length < 2) return const [];
    final half = window ~/ 2;
    final out = <TrendPoint>[];
    for (var i = 0; i < points.length; i++) {
      final lo = (i - half) < 0 ? 0 : i - half;
      final hi = (i + half) >= points.length ? points.length - 1 : i + half;
      double sum = 0;
      for (var j = lo; j <= hi; j++) {
        sum += points[j].y;
      }
      out.add(TrendPoint(points[i].x, sum / (hi - lo + 1)));
    }
    return out;
  }
}
