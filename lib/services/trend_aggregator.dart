import '../data/database.dart';

/// v0.1.29+35: pure aggregation layer behind the rebuilt Trends tab.
/// v0.1.31+130 (Trends v2): per-trip scatter/line series replaced by
/// period BARS — the caller picks the bucket (day for the 30d window,
/// month for 1y/all) and every efficiency series is aggregated per
/// bucket instead of per trip. Rationale: per-trip dots were honest but
/// unreadably noisy past a few dozen trips, and a weighted per-period
/// figure is the number a driver actually reasons about ("what did
/// July cost me per 100 km"), not the variance of individual hops.
///
/// What this layer derives from the Trips table:
///
///   • Period totals    — distance, energy, money spent, energy regened.
///   • Cumulative       — running odometer (a curve whose shape means
///                         something, unlike the raw monotone reading).
///   • Per-month bars   — money spent per calendar month (seasonality).
///                         Always monthly regardless of bucket — money
///                         per day is noise, not signal.
///   • Per-bucket bars  — weighted consumption (Σ kWh / Σ km × 100),
///                         distance, regen share. A bucket with no
///                         qualifying trips is ABSENT from the list,
///                         never a zero bar (a zero would draw a lie).
///
/// Everything here is null-safe by necessity: regenEnergyKwh and the
/// precise SOC delta only exist from schema v2 / v5 onward, so historic
/// trips may have nulls. The rule throughout is *skip nulls, never coerce
/// to zero* — a zero would silently understate a period total or drag a
/// series to the floor. A period with no usable data reports null /
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

/// One calendar bucket (a day or a month, for the per-period bar charts).
class PeriodBar {
  final DateTime start; // first instant of the bucket
  final double value;
  const PeriodBar(this.start, this.value);
}

/// v0.1.31+130: calendar bucket granularity for the per-period bars.
/// The CALLER picks it from the selected window: 30d → day, 1y/all →
/// month. The aggregator itself has no opinion about windows.
enum TrendBucket { day, month }

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

  // ── Efficiency, per calendar bucket (section 3) ──
  /// Weighted consumption per bucket: Σ energyUsedKwh / Σ distanceKm × 100
  /// over the bucket's qualifying trips (dist ≥ kMinDistForConsumptionKm
  /// AND energy > 0 — the guard against "60 kWh/100km around the yard").
  final List<PeriodBar> consumptionPerPeriod;

  /// Σ distanceKm per bucket (any trip with dist > 0).
  final List<PeriodBar> distancePerPeriod;

  /// Regen share per bucket: Σ regen / Σ energy × 100, clamped 0–100.
  /// Only buckets where Σ energy > 0 appear.
  final List<PeriodBar> regenSharePerPeriod;

  const TrendAggregate({
    required this.totalDistanceKm,
    required this.totalEnergyKwh,
    required this.totalCostMoney,
    required this.totalRegenKwh,
    required this.tripCount,
    required this.cumulativeOdometer,
    required this.costPerMonth,
    required this.consumptionPerPeriod,
    required this.distancePerPeriod,
    required this.regenSharePerPeriod,
  });

  bool get isEmpty => tripCount == 0;

  /// v0.1.31+130: derived full-charge range for the consumption-card
  /// footer ("≈ N км на 100%"). Window totals over the usable capacity —
  /// no per-trip SOC bookkeeping, so none of the short-hop pathologies
  /// that killed the old realRangePer100 chart. Null when totals are
  /// empty. Footer-only: there is deliberately NO chart behind it.
  double? get estRangeKm => (totalDistanceKm > 0 && totalEnergyKwh > 0)
      ? totalDistanceKm / totalEnergyKwh * kUsableCapacityKwh
      : null;

  static const empty = TrendAggregate(
    totalDistanceKm: 0,
    totalEnergyKwh: 0,
    totalCostMoney: 0,
    totalRegenKwh: 0,
    tripCount: 0,
    cumulativeOdometer: <TrendPoint>[],
    costPerMonth: <PeriodBar>[],
    consumptionPerPeriod: <PeriodBar>[],
    distancePerPeriod: <PeriodBar>[],
    regenSharePerPeriod: <PeriodBar>[],
  );
}

/// Usable pack capacity of the BZ5, kWh. Duplicated from
/// `Bz5Model.batteryCapacityKwh` (connection.dart) on purpose — importing
/// ConnectionService here would drag Flutter dependencies into this
/// deliberately pure, unit-testable layer (same trade-off
/// HalTelemetryService made for batteryCapacityAh).
const double kUsableCapacityKwh = 65.28;

/// Minimum trip distance (km) before it participates in the weighted
/// per-bucket consumption. Sub-2-km hops produce wild kWh/100km figures
/// (HVAC warm-up dominating a 500 m crawl → "60 kWh/100km") that would
/// poison a whole day's bar. They still count toward period *totals*,
/// which are robust to it.
const double kMinDistForConsumptionKm = 2.0;

/// v0.1.32+131: minimum SUMMED qualifying distance (km) before a bucket
/// gets a consumption bar at all. The per-trip guard above cannot save a
/// day made ENTIRELY of short hops — three 1.5-km errand runs all pass
/// nothing to the bucket, but two 2.5-km ones pass 5 km of HVAC-dominated
/// crawling and still print a "60 kWh/100km" day bar (field photo
/// 2026-07-11, the 30d outlier). Below this floor the bucket is simply
/// absent (the "empty bucket is absent, not zero" rule) — period TOTALS
/// are untouched, this only gates the per-period bar.
const double kMinBucketDistKm = 5.0;

class TrendAggregator {
  /// Build the full aggregate for [trips] (assumed already filtered to the
  /// window and sorted ascending by startedAt — getTripsInRange does both).
  ///
  /// [costPerKwh] is the user's tariff (0 ⇒ cost section reads as zero,
  /// which the UI hides when CostSettings.isConfigured is false).
  ///
  /// [bucket] is the calendar granularity for the per-period bars,
  /// chosen by the caller from the selected window (30d → day,
  /// 1y/all → month). Cost bars ignore it — always monthly.
  static TrendAggregate build(
    List<Trip> trips, {
    required double costPerKwh,
    required TrendBucket bucket,
  }) {
    if (trips.isEmpty) return TrendAggregate.empty;

    double totalDistance = 0;
    double totalEnergy = 0;
    double totalRegen = 0;

    final cumulative = <TrendPoint>[];
    final monthEnergy = <DateTime, double>{};

    // Per-bucket accumulators. Keys are bucket-start DateTimes; map
    // iteration order doesn't matter — each list is sorted at the end.
    final bucketConsEnergy = <DateTime, double>{}; // Σ kWh, qualifying trips
    final bucketConsDist = <DateTime, double>{}; // Σ km, qualifying trips
    final bucketDist = <DateTime, double>{}; // Σ km, any dist > 0
    final bucketEnergy = <DateTime, double>{}; // Σ kWh, any energy > 0
    final bucketRegen = <DateTime, double>{}; // Σ kWh regened

    double runningDistance = 0;

    for (final t in trips) {
      final x = t.startedAt.millisecondsSinceEpoch.toDouble();
      final b = _bucketStart(t.startedAt, bucket);

      // ── Totals + cumulative (robust: any present field counts) ──
      final dist = t.distanceKm;
      if (dist != null && dist > 0) {
        totalDistance += dist;
        runningDistance += dist;
        cumulative.add(TrendPoint(x, runningDistance));
        bucketDist[b] = (bucketDist[b] ?? 0) + dist;
      }

      final energy = t.energyUsedKwh;
      if (energy != null && energy > 0) {
        totalEnergy += energy;
        // Per-month bucket keyed by first-of-month (cost is ALWAYS
        // monthly, independent of [bucket]).
        final m = DateTime(t.startedAt.year, t.startedAt.month);
        monthEnergy[m] = (monthEnergy[m] ?? 0) + energy;
        bucketEnergy[b] = (bucketEnergy[b] ?? 0) + energy;
      }

      final regen = t.regenEnergyKwh;
      if (regen != null && regen > 0) {
        totalRegen += regen;
        bucketRegen[b] = (bucketRegen[b] ?? 0) + regen;
      }

      // ── Weighted consumption inputs (guarded) ──
      if (dist != null &&
          dist >= kMinDistForConsumptionKm &&
          energy != null &&
          energy > 0) {
        bucketConsEnergy[b] = (bucketConsEnergy[b] ?? 0) + energy;
        bucketConsDist[b] = (bucketConsDist[b] ?? 0) + dist;
      }
    }

    final costMonths = monthEnergy.entries
        .map((e) => PeriodBar(e.key, e.value * costPerKwh))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    // Weighted consumption per bucket. A bucket is present only when it
    // has qualifying trips — empty buckets are absent, not zero.
    // v0.1.32+131: and only when those trips sum to a meaningful distance
    // (kMinBucketDistKm) — a bucket of nothing but short hops is noise,
    // not a consumption figure.
    final consumptionBars = <PeriodBar>[
      for (final e in bucketConsEnergy.entries)
        if ((bucketConsDist[e.key] ?? 0) >= kMinBucketDistKm)
          PeriodBar(e.key, e.value / bucketConsDist[e.key]! * 100),
    ]..sort((a, b) => a.start.compareTo(b.start));

    final distanceBars = <PeriodBar>[
      for (final e in bucketDist.entries) PeriodBar(e.key, e.value),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // Regen share per bucket — only where energy was actually drawn.
    // Clamp to a sane ceiling: a malformed trip with regen > used would
    // otherwise spike the bar past 100%.
    final regenBars = <PeriodBar>[
      for (final e in bucketEnergy.entries)
        PeriodBar(
            e.key,
            ((bucketRegen[e.key] ?? 0) / e.value * 100)
                .clamp(0.0, 100.0)
                .toDouble()),
    ]..sort((a, b) => a.start.compareTo(b.start));

    return TrendAggregate(
      totalDistanceKm: totalDistance,
      totalEnergyKwh: totalEnergy,
      totalCostMoney: totalEnergy * costPerKwh,
      totalRegenKwh: totalRegen,
      tripCount: trips.length,
      cumulativeOdometer: cumulative,
      costPerMonth: costMonths,
      consumptionPerPeriod: consumptionBars,
      distancePerPeriod: distanceBars,
      regenSharePerPeriod: regenBars,
    );
  }

  /// First instant of the calendar bucket containing [t].
  static DateTime _bucketStart(DateTime t, TrendBucket bucket) =>
      bucket == TrendBucket.day
          ? DateTime(t.year, t.month, t.day)
          : DateTime(t.year, t.month);
}
