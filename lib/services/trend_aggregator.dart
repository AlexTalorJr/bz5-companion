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

  // ── v0.1.49+148 (K4 honest trends) ──
  /// Σ distanceKm over TRIP rows — what the app actually *recorded* as
  /// trips. When [distanceFromOdometer] is true this is the "записано Y"
  /// half of the coverage marker; totalDistanceKm is the odometer truth.
  final double recordedTripDistanceKm;

  /// True when totals/bars come from the snapshot odometer/SOC walks;
  /// false = legacy trips-only fallback (no usable snapshots in window).
  final bool distanceFromOdometer;

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
    this.recordedTripDistanceKm = 0,
    this.distanceFromOdometer = false,
  });

  /// v0.1.49+148 (K4): what share of the odometer distance the recorded
  /// trips cover — the honesty valve for the trips-sourced figures
  /// (regen). Null when the walk didn't run (legacy fallback) so the UI
  /// simply omits the marker.
  double? get tripCoveragePct =>
      (distanceFromOdometer && totalDistanceKm > 0)
          ? (recordedTripDistanceKm / totalDistanceKm * 100)
              .clamp(0.0, 100.0)
              .toDouble()
          : null;

  bool get isEmpty => tripCount == 0 && totalDistanceKm <= 0;

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

/// v0.1.49+148 (K4): sanity ceiling for a single odometer step between two
/// consecutive snapshots. The odometer is monotone, so a negative delta is
/// a data glitch (skip); a step above this is a corrupt reading, not a
/// coverage hole (the June holes were ~380 km).
const double kMaxWalkStepKm = 2000.0;

/// v0.1.49+148 (K4): pairs of snapshots further apart than this are a
/// COVERAGE HOLE. Their deltas still count toward window totals (that is
/// the whole point — the odometer doesn't lie across app downtime) and the
/// cumulative curve (a running total jumping over a hole is truthful), but
/// they are NOT attributed to a per-bucket bar: painting a 380-km June
/// hole as one huge "day" bar would trade one lie for another.
const Duration kMaxWalkPairGap = Duration(hours: 6);

class TrendAggregator {
  /// Build the full aggregate for [trips] (assumed already filtered to the
  /// window and sorted ascending by startedAt — getTripsInRange does both).
  ///
  /// v0.1.49+148 (K4 honest trends): [snapshots] (same window, ascending
  /// by capturedAt — getSnapshotsInRange does both) now drive distance,
  /// energy, money and consumption via odometer/SOC WALKS. Trips missed
  /// the field audit badly (17.07: odometer 1619 km vs Σtrips 680 km, 42%)
  /// — app downtime, zombie trips and null-finalizations all silently
  /// shrink the trip sum, while the odometer cannot lie. Regen stays
  /// trips-sourced (snapshots don't know it) with a coverage marker
  /// (tripCoveragePct) as the honesty valve. Empty/unusable snapshots →
  /// legacy trips-only behaviour, marker absent.
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
    List<Snapshot> snapshots = const <Snapshot>[],
  }) {
    if (trips.isEmpty && snapshots.isEmpty) return TrendAggregate.empty;

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

    // Regen share per bucket. v0.1.45+144: denominator corrected.
    //
    // bucketEnergy = energyUsedKwh = (startSoc − endSoc) × capacity, i.e.
    // the NET drop in battery state — regen has ALREADY been subtracted
    // from it (regen slowed the SOC fall). Dividing GROSS regen by that
    // net figure overstates the share badly: heavy regen shrinks the
    // denominator while inflating the numerator, so city drives with
    // hills spiked to 60-73% (physically impossible — that would imply
    // recovering most of the traction energy). The .clamp below was
    // papering over the symptom.
    //
    // Correct "regen share" = returned / gross-drawn, where
    //   gross_drawn = net_used + regen
    // (you pulled net_used + regen out of the pack for motion, then got
    // regen back). This is always < 100% by construction and reads as a
    // sane 20-40% in mixed driving. Still an estimate (regen is an
    // integrated-power figure, net_used is ΔSOC×capacity — different
    // provenance), but honest in magnitude. Clamp kept as a backstop.
    final regenBars = <PeriodBar>[
      for (final e in bucketEnergy.entries)
        PeriodBar(
            e.key,
            (() {
              final regen = bucketRegen[e.key] ?? 0.0;
              final gross = e.value + regen;
              if (gross <= 0) return 0.0;
              return (regen / gross * 100).clamp(0.0, 100.0).toDouble();
            })()),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // ── v0.1.49+148 (K4): snapshot walks ──
    //
    // Odometer walk: Σ of positive per-pair deltas = the distance the CAR
    // says it drove, immune to app downtime. SOC walk: Σ of per-pair SOC
    // drops × capacity = energy drawn, with charging excluded (a rising
    // SOC pair without the flag — charging inside a coverage hole —
    // yields drop ≤ 0 and is skipped too; note that such a hole MASKS the
    // consumption that happened around it, which is exactly what
    // tripCoveragePct exists to disclose). Pairs wider than
    // kMaxWalkPairGap feed totals + the cumulative curve but not the
    // per-bucket bars (see the constant's comment).
    //
    // v0.1.50+149: a pair is two consecutive NON-NULL readings of the
    // SAME signal, tracked by separate anchors — NOT two adjacent rows.
    // 12% of real snapshots carry SOC without an odometer (phone/OBD2
    // rows); adjacent-row pairing let each such row break TWO pairs and
    // silently drop the distance across it (20.07 field export: 152
    // broken pairs ate 838 of 1766 km — 47% of the month). Null rows are
    // now transparent to the other signal's walk.
    double walkDist = 0;
    double walkEnergy = 0;
    final walkDistBucket = <DateTime, double>{};
    final walkEnergyBucket = <DateTime, double>{};
    final walkMonthEnergy = <DateTime, double>{};
    final walkCumByBucket = <DateTime, double>{};
    Snapshot? odoAnchor;
    Snapshot? socAnchor;
    // v0.1.50+149: a charging row BETWEEN two SOC anchors must poison the
    // pair even when that row itself carries no SOC value — otherwise the
    // +148 endpoint rule (either end charging ⇒ excluded) would silently
    // weaken to "only endpoints checked".
    var chargedSinceSocAnchor = false;
    for (final s in snapshots) {
      if (s.isCharging ?? false) chargedSinceSocAnchor = true;

      final so = s.odometer;
      if (so != null) {
        final p = odoAnchor;
        odoAnchor = s;
        if (p != null) {
          final d = so - p.odometer!;
          if (d > 0 && d < kMaxWalkStepKm) {
            final gap = s.capturedAt.difference(p.capturedAt);
            final b = _bucketStart(s.capturedAt, bucket);
            walkDist += d;
            walkCumByBucket[b] = walkDist;
            if (gap <= kMaxWalkPairGap) {
              walkDistBucket[b] = (walkDistBucket[b] ?? 0) + d;
            }
          }
        }
      }

      final ssoc = s.soc;
      if (ssoc != null) {
        final p = socAnchor;
        final poisoned = chargedSinceSocAnchor;
        socAnchor = s;
        // "Since anchor" restarts here; the new anchor's own charging
        // state seeds the flag so an anchored charging row poisons the
        // NEXT pair too (endpoint semantics of +148 preserved).
        chargedSinceSocAnchor = s.isCharging ?? false;
        if (p != null && !poisoned) {
          final drop = p.soc! - ssoc;
          if (drop > 0 && drop <= 100) {
            final gap = s.capturedAt.difference(p.capturedAt);
            final b = _bucketStart(s.capturedAt, bucket);
            final e = drop * kUsableCapacityKwh / 100;
            walkEnergy += e;
            // Money is ALWAYS monthly and coarse — hole pairs stay in so
            // Σ(month bars) keeps equalling totals × tariff.
            final m = DateTime(s.capturedAt.year, s.capturedAt.month);
            walkMonthEnergy[m] = (walkMonthEnergy[m] ?? 0) + e;
            if (gap <= kMaxWalkPairGap) {
              walkEnergyBucket[b] = (walkEnergyBucket[b] ?? 0) + e;
            }
          }
        }
      }
    }

    // Source selection: each figure independently prefers its walk and
    // falls back to the trip sum when the walk yielded nothing (no/sparse
    // snapshots — e.g. a phone that never synced). Regen is ALWAYS trips.
    final useWalkDist = walkDist > 0;
    final useWalkEnergy = useWalkDist && walkEnergy > 0;

    final honestDistance = useWalkDist ? walkDist : totalDistance;
    final honestEnergy = useWalkEnergy ? walkEnergy : totalEnergy;

    final honestCumulative = useWalkDist
        ? (<TrendPoint>[
            for (final e in walkCumByBucket.entries)
              TrendPoint(
                  e.key.millisecondsSinceEpoch.toDouble(), e.value),
          ]..sort((a, b) => a.x.compareTo(b.x)))
        : cumulative;

    final honestCostMonths = useWalkEnergy
        ? (walkMonthEnergy.entries
            .map((e) => PeriodBar(e.key, e.value * costPerKwh))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start)))
        : costMonths;

    final honestDistanceBars = useWalkDist
        ? (<PeriodBar>[
            for (final e in walkDistBucket.entries)
              PeriodBar(e.key, e.value),
          ]..sort((a, b) => a.start.compareTo(b.start)))
        : distanceBars;

    // Consumption per bucket from the walks, same bucket floor as the
    // trips path (kMinBucketDistKm) — a bucket of yard-crawl noise stays
    // absent, not zero.
    final honestConsumptionBars = (useWalkDist && useWalkEnergy)
        ? (<PeriodBar>[
            for (final e in walkEnergyBucket.entries)
              if ((walkDistBucket[e.key] ?? 0) >= kMinBucketDistKm)
                PeriodBar(e.key, e.value / walkDistBucket[e.key]! * 100),
          ]..sort((a, b) => a.start.compareTo(b.start)))
        : consumptionBars;

    return TrendAggregate(
      totalDistanceKm: honestDistance,
      totalEnergyKwh: honestEnergy,
      totalCostMoney: honestEnergy * costPerKwh,
      totalRegenKwh: totalRegen,
      tripCount: trips.length,
      cumulativeOdometer: honestCumulative,
      costPerMonth: honestCostMonths,
      consumptionPerPeriod: honestConsumptionBars,
      distancePerPeriod: honestDistanceBars,
      regenSharePerPeriod: regenBars,
      recordedTripDistanceKm: totalDistance,
      distanceFromOdometer: useWalkDist,
    );
  }

  /// First instant of the calendar bucket containing [t].
  static DateTime _bucketStart(DateTime t, TrendBucket bucket) =>
      bucket == TrendBucket.day
          ? DateTime(t.year, t.month, t.day)
          : DateTime(t.year, t.month);
}
