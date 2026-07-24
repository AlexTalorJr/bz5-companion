// v0.1.62+161 «Атлас» patch 3 — the read-side projection of
// atlas_snapshots into the grid model (SPEC.md v1.1 §7.2).
//
// WHY A SEPARATE FILE (documented deviation from the patch spec's file
// map, which put the projections into database.dart): the independent
// session count is `dedupSessionCount` from speed_profile_service.dart —
// the CONTRACT dedup port that regress AY5 pins. speed_profile_service
// imports database.dart, so importing it back from database.dart would
// close an import cycle. The projection sits one layer above both and
// imports each once; database.dart only gains the raw filtered selects.
//
// The grid reads atlas_snapshots DIRECTLY (never the prefs ledger), which
// is why a reinstall heals itself: cloud pull/restore refills the table
// and the grid comes back with it — no rehydration code anywhere.
//
// BAND CEILING (owner decision, 25.07): snapshots above 140 km/h are not
// shown — not in the matrix, not in the header counters, not in the year
// row, not in the export. The reward engine still records them until the
// cutoff lands in `_freeze` / `_generateReveal` (+162), so the ceiling is
// enforced here, at the single query that feeds every read surface.
import 'database.dart';
import '../services/speed_profile_service.dart'
    show SnapshotLite, dedupSessionCount, kAtlasWindowMinC, kAtlasWindowMaxC,
        kAtlasWindowStepC;

/// Collection bounds of the matrix: 11 bands × 12 windows = 132 cells.
const int kAtlasBandMinKmh = 40;
const int kAtlasBandMaxKmh = 140;
const int kAtlasBandStepKmh = 10;

/// Window class boundaries (§6.9): «редкое» ≤ 0 °C — that is the four
/// windows −20/−15/−10/−5 (each one's upper bound is ≤ 0); «жаркое»
/// > 25 °C — the three windows 25/30/35. The mockup [5g] tinted five
/// cold and two hot columns; the prose of §6.9 wins (spec §1.2).
const int kAtlasRareWindowMaxC = -5;
const int kAtlasHotWindowMinC = 25;

bool atlasWindowIsRare(int? w) => w != null && w <= kAtlasRareWindowMaxC;

bool atlasWindowIsHot(int? w) => w != null && w >= kAtlasHotWindowMinC;

/// All 11 band rows of the collection, ascending.
List<int> atlasAllBands() => [
      for (int b = kAtlasBandMinKmh; b <= kAtlasBandMaxKmh; b += kAtlasBandStepKmh)
        b,
    ];

/// All 12 window columns of the collection, ascending.
List<int> atlasAllWindows() => [
      for (int w = kAtlasWindowMinC; w <= kAtlasWindowMaxC; w += kAtlasWindowStepC)
        w,
    ];

/// Stable cell key. Mirrors the ledger's own `band:window` shape («u» for
/// the «t° неизвестна» reserve) so the two never disagree on identity.
String atlasCellKey(int band, int? window) => '$band:${window ?? 'u'}';

/// One open cell of the matrix.
class AtlasCellStat {
  final int band;
  final int? window;

  /// Median of the cell's snapshot values (even count → mean of the two
  /// middles). This is the number the cell shows.
  final double median;

  /// Fork = min…max over the cell's snapshots. With a single snapshot
  /// lo == hi and the fork is NOT rendered anywhere (owner decision,
  /// 25.07): «11.1–11.1» is noise, the star already says «1 session».
  final double lo;
  final double hi;

  final int snapshots;

  /// Independent logical sessions (CONTRACT dedup) — the star level.
  final int sessions;

  /// Σ steady seconds over the cell's snapshots. Owner's definition of
  /// «лучшая ячейка» (25.07): where the car actually spent the most
  /// steady time at this speed and this temperature — immune to the
  /// signed-consumption trap that a min-median rule would have hit
  /// (a regen-heavy descent can legitimately hold kwh100 ≤ 0).
  final double steadySeconds;

  final DateTime firstFrozenAt;
  final DateTime lastFrozenAt;

  const AtlasCellStat({
    required this.band,
    required this.window,
    required this.median,
    required this.lo,
    required this.hi,
    required this.snapshots,
    required this.sessions,
    required this.steadySeconds,
    required this.firstFrozenAt,
    required this.lastFrozenAt,
  });

  bool get hasFork => snapshots > 1 && (hi - lo).abs() > 1e-9;

  String get key => atlasCellKey(band, window);
}

/// A frontier ghost — one dashed outline, never a cell.
class AtlasGhost {
  final int band;
  final int? window;
  const AtlasGhost(this.band, this.window);

  String get key => atlasCellKey(band, window);
}

/// Everything the almanac screens need, computed once per rebuild.
class AtlasGridData {
  final List<AtlasCellStat> cells;
  final Map<String, AtlasCellStat> byKey;

  /// Axis keys actually rendered (fog of war: a band / window with
  /// neither a cell nor a ghost does not exist on screen).
  final List<int> bands;
  final List<int?> windows;

  final List<AtlasGhost> ghosts;
  final Set<String> ghostKeys;

  /// Cells opened within the last 24 h — `cardActive` + outline (§6.5).
  final Set<String> newKeys;

  /// Months (1…12) of the CURRENT year with at least one frozen snapshot.
  final Set<int> monthsTouched;

  final DateTime? firstEver;
  final DateTime? lastEver;

  /// Σ steady-time champion, null on an empty atlas.
  final AtlasCellStat? best;

  /// Earliest-opened cell — the hero line of an early export.
  final AtlasCellStat? firstCell;

  /// Pack-temperature span of the current month, in window bounds
  /// («15–25°»); null when this month has no snapshot with a window.
  final int? seasonLoC;
  final int? seasonHiC;

  const AtlasGridData({
    required this.cells,
    required this.byKey,
    required this.bands,
    required this.windows,
    required this.ghosts,
    required this.ghostKeys,
    required this.newKeys,
    required this.monthsTouched,
    required this.firstEver,
    required this.lastEver,
    required this.best,
    required this.firstCell,
    required this.seasonLoC,
    required this.seasonHiC,
  });

  bool get isEmpty => cells.isEmpty;

  int get cellCount => cells.length;

  int get bandCount => {for (final c in cells) c.band}.length;

  /// «Собрано за {n} дней» — calendar days from the first snapshot,
  /// inclusive, never below 1.
  int daysCollected({DateTime? now}) {
    final f = firstEver;
    if (f == null) return 0;
    final n = now ?? DateTime.now();
    final a = DateTime(f.year, f.month, f.day);
    final b = DateTime(n.year, n.month, n.day);
    return b.difference(a).inDays + 1;
  }

  /// The projection itself. [rows] must already be band-filtered by the
  /// DAO; the assertion-free re-filter here is a cheap second lock.
  factory AtlasGridData.fromRows(List<AtlasSnapshotRow> rows,
      {DateTime? now}) {
    final n = now ?? DateTime.now();
    final grouped = <String, List<AtlasSnapshotRow>>{};
    DateTime? firstEver;
    DateTime? lastEver;
    final months = <int>{};
    int? seasonLo;
    int? seasonHi;

    for (final r in rows) {
      if (r.bandKmh < kAtlasBandMinKmh || r.bandKmh > kAtlasBandMaxKmh) {
        continue;
      }
      grouped.putIfAbsent(atlasCellKey(r.bandKmh, r.tempWindowC), () => [])
          .add(r);
      if (firstEver == null || r.frozenAt.isBefore(firstEver)) {
        firstEver = r.frozenAt;
      }
      if (lastEver == null || r.frozenAt.isAfter(lastEver)) {
        lastEver = r.frozenAt;
      }
      if (r.frozenAt.year == n.year) {
        months.add(r.frozenAt.month);
        if (r.frozenAt.month == n.month) {
          final w = r.tempWindowC;
          if (w != null) {
            if (seasonLo == null || w < seasonLo) seasonLo = w;
            final hi = w + kAtlasWindowStepC;
            if (seasonHi == null || hi > seasonHi) seasonHi = hi;
          }
        }
      }
    }

    final cells = <AtlasCellStat>[];
    grouped.forEach((key, list) {
      final vals = [for (final r in list) r.kwh100]..sort();
      final mid = vals.length ~/ 2;
      final median = vals.length.isOdd
          ? vals[mid]
          : (vals[mid - 1] + vals[mid]) / 2.0;
      var steady = 0.0;
      for (final r in list) {
        steady += r.steadySeconds;
      }
      final lites = [
        for (final r in list)
          SnapshotLite(
            sessionUid: r.sessionUid,
            source: r.source,
            startedAtMs: r.startedAt.millisecondsSinceEpoch,
            frozenAtMs: r.frozenAt.millisecondsSinceEpoch,
          ),
      ];
      var first = list.first.frozenAt;
      var last = list.first.frozenAt;
      for (final r in list) {
        if (r.frozenAt.isBefore(first)) first = r.frozenAt;
        if (r.frozenAt.isAfter(last)) last = r.frozenAt;
      }
      cells.add(AtlasCellStat(
        band: list.first.bandKmh,
        window: list.first.tempWindowC,
        median: median,
        lo: vals.first,
        hi: vals.last,
        snapshots: list.length,
        sessions: dedupSessionCount(lites),
        steadySeconds: steady,
        firstFrozenAt: first,
        lastFrozenAt: last,
      ));
    });

    final byKey = {for (final c in cells) c.key: c};

    // Frontier: ONE ring of the cross 4-neighbourhood of open cells —
    // the neighbouring window of the same band and the neighbouring band
    // of the same window. No diagonals, no second ring, never a cell
    // that is already open. The «t° неизвестна» reserve column has no
    // temperature neighbours by construction, so it only radiates along
    // the band axis (documented: the column is a reserve for cars
    // without a pack-temp sensor, it is not part of the 12-window axis).
    final ghosts = <AtlasGhost>[];
    final ghostKeys = <String>{};
    void addGhost(int band, int? window) {
      if (band < kAtlasBandMinKmh || band > kAtlasBandMaxKmh) return;
      if (window != null &&
          (window < kAtlasWindowMinC || window > kAtlasWindowMaxC)) {
        return;
      }
      final k = atlasCellKey(band, window);
      if (byKey.containsKey(k) || ghostKeys.contains(k)) return;
      ghostKeys.add(k);
      ghosts.add(AtlasGhost(band, window));
    }

    for (final c in cells) {
      addGhost(c.band - kAtlasBandStepKmh, c.window);
      addGhost(c.band + kAtlasBandStepKmh, c.window);
      if (c.window != null) {
        addGhost(c.band, c.window! - kAtlasWindowStepC);
        addGhost(c.band, c.window! + kAtlasWindowStepC);
      }
    }

    // Rendered axes = union of cells and ghosts (fog of war §7.2).
    final bandSet = <int>{
      for (final c in cells) c.band,
      for (final g in ghosts) g.band,
    };
    final hasNullWindow = cells.any((c) => c.window == null) ||
        ghosts.any((g) => g.window == null);
    final windowSet = <int>{
      for (final c in cells)
        if (c.window != null) c.window!,
      for (final g in ghosts)
        if (g.window != null) g.window!,
    };
    final bands = bandSet.toList()..sort();
    final windows = <int?>[...(windowSet.toList()..sort())];
    if (hasNullWindow) windows.add(null);

    AtlasCellStat? best;
    AtlasCellStat? firstCell;
    for (final c in cells) {
      if (best == null ||
          c.steadySeconds > best.steadySeconds ||
          (c.steadySeconds == best.steadySeconds &&
              c.snapshots > best.snapshots)) {
        best = c;
      }
      if (firstCell == null ||
          c.firstFrozenAt.isBefore(firstCell.firstFrozenAt)) {
        firstCell = c;
      }
    }

    final freshFrom = n.subtract(const Duration(hours: 24));
    final newKeys = <String>{
      for (final c in cells)
        if (c.firstFrozenAt.isAfter(freshFrom)) c.key,
    };

    return AtlasGridData(
      cells: cells,
      byKey: byKey,
      bands: bands,
      windows: windows,
      ghosts: ghosts,
      ghostKeys: ghostKeys,
      newKeys: newKeys,
      monthsTouched: months,
      firstEver: firstEver,
      lastEver: lastEver,
      best: best,
      firstCell: firstCell,
      seasonLoC: seasonLo,
      seasonHiC: seasonHi,
    );
  }
}

/// Window label of the contract: «15–20», «≤ −20» for the bottom clamp,
/// «+40» is only ever an axis caption in the export (§6.12).
String atlasWindowLabel(int w) =>
    w <= kAtlasWindowMinC ? '≤ −20' : '$w–${w + kAtlasWindowStepC}';
