// v0.1.62+161 «Атлас» patch 3 — the matrix widget, ONE implementation
// for all three hosts (SPEC.md v1.1 §7.2, §6.5, §6.9, mockup [5a]).
//
// Layout is WINDOW-MAJOR (a Row of per-window Columns) rather than the
// obvious row-of-rows: the window class tint of §6.9 is a property of the
// COLUMN, and a column-shaped widget can carry it as its own decoration
// instead of every cell repainting a slice of it.
//
// The band column is pinned OUTSIDE the horizontal scroll view (checklist
// п.5: «колонка скоростей закреплена при свайпе»); every vertical extent
// is a fixed dp so the two halves stay in lockstep without an
// intrinsic-size pass.
//
// Fog of war: axes come from [AtlasGridData] which already dropped every
// band / window that has neither a cell nor a ghost.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/atlas_projection.dart';
import '../l10n/strings.dart';
import '../theme/atlas_tokens.dart';

/// Per-host geometry. Sizes are the contract's (§3, §4, §6.5).
enum AtlasGridScale { phone, bz5, bz3 }

class _AtlasMetrics {
  final double cellW;
  final double cellH;
  final double radius;
  final double medianSize;

  /// Fork font size, or null where the fork is not rendered at all —
  /// the phone (§11: «вилка только в детализации»).
  final double? forkSize;
  final double starSize;
  final double gap;
  final double bandLabelW;
  final double bandLabelSize;
  final double headerSize;
  final double headerH;

  const _AtlasMetrics({
    required this.cellW,
    required this.cellH,
    required this.radius,
    required this.medianSize,
    required this.forkSize,
    required this.starSize,
    required this.gap,
    required this.bandLabelW,
    required this.bandLabelSize,
    required this.headerSize,
    required this.headerH,
  });

  static const _AtlasMetrics phone = _AtlasMetrics(
    cellW: 52,
    cellH: 44,
    radius: 8,
    medianSize: 14,
    forkSize: null,
    starSize: 14,
    gap: 5,
    bandLabelW: 34,
    bandLabelSize: 11,
    headerSize: 9.5,
    headerH: 20,
  );

  static const _AtlasMetrics bz5 = _AtlasMetrics(
    cellW: 104,
    cellH: 78,
    radius: 14,
    medianSize: 30,
    forkSize: 17,
    starSize: 22,
    gap: 8,
    bandLabelW: 58,
    bandLabelSize: 20,
    headerSize: 16,
    headerH: 30,
  );

  static const _AtlasMetrics bz3 = _AtlasMetrics(
    cellW: 86,
    cellH: 68,
    radius: 14,
    medianSize: 28,
    forkSize: 16,
    starSize: 20,
    gap: 6,
    bandLabelW: 48,
    bandLabelSize: 17,
    headerSize: 14,
    headerH: 26,
  );

  static _AtlasMetrics of(AtlasGridScale s) {
    switch (s) {
      case AtlasGridScale.bz5:
        return bz5;
      case AtlasGridScale.bz3:
        return bz3;
      case AtlasGridScale.phone:
        return phone;
    }
    // Unreachable (the switch is exhaustive over the enum) — kept so the
    // function provably returns on every SDK, not only on one that
    // recognises enum exhaustiveness. The gates do not compile Dart.
    // ignore: dead_code
    return phone;
  }
}

class AtlasGrid extends StatelessWidget {
  final AtlasGridData data;
  final AtlasGridScale scale;

  /// Cell tap → detail screen. Null on the head unit: «Тап по ячейке на
  /// ГУ ничего не открывает» (§7.2).
  final ValueChanged<AtlasCellStat>? onTapCell;

  /// +162: matured cells still waiting for the session to rotate. Drawn
  /// as «дозрела, ждёт конца поездки» — never counted as cells.
  final List<AtlasPending> pending;

  /// +162 (§3.2): the taken intention, marked with a flag.
  final String? intentKey;

  /// +162: selection mode ([5a] «тапабельны только фронтир-призраки»).
  /// Cells go quiet, ghosts become the only touch targets.
  final bool selectMode;
  final void Function(int band, int? window)? onTapGhost;

  const AtlasGrid({
    super.key,
    required this.data,
    required this.scale,
    this.onTapCell,
    this.pending = const [],
    this.intentKey,
    this.selectMode = false,
    this.onTapGhost,
  });

  @override
  Widget build(BuildContext context) {
    final m = _AtlasMetrics.of(scale);
    if (data.bands.isEmpty || data.windows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          S.of('atlas.empty'),
          style: TextStyle(fontSize: m.bandLabelSize, color: AtlasTokens.t45),
        ),
      );
    }

    // Band label — white .55 when the row carries at least one real
    // cell, white .22 when it only holds ghosts (§7.2 headers rule).
    final liveBands = {for (final c in data.cells) c.band};
    final liveWindows = {for (final c in data.cells) c.window};

    // +162: a pending cell may sit outside the ghost ring, so the axes
    // are widened for it here rather than inside the projection (which
    // must stay a pure function of the database).
    final pendingByKey = {for (final p in pending) p.key: p};
    final bands = <int>{...data.bands, for (final p in pending) p.band}
        .toList()
      ..sort();
    final hasNullWindow = data.windows.contains(null) ||
        pending.any((p) => p.window == null);
    final windows = <int?>[
      ...(<int>{
        for (final w in data.windows)
          if (w != null) w,
        for (final p in pending)
          if (p.window != null) p.window!,
      }.toList()
        ..sort()),
      if (hasNullWindow) null,
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── pinned band column ──
        SizedBox(
          width: m.bandLabelW,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: m.headerH),
              for (final b in bands) ...[
                SizedBox(height: m.gap),
                SizedBox(
                  height: m.cellH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$b',
                      style: TextStyle(
                        fontSize: m.bandLabelSize,
                        fontWeight: liveBands.contains(b)
                            ? FontWeight.w500
                            : FontWeight.w400,
                        color: liveBands.contains(b)
                            ? AtlasTokens.t55
                            : AtlasTokens.t22,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // ── scrollable matrix ──
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final w in windows)
                  Padding(
                    padding: EdgeInsets.only(right: m.gap),
                    child: _WindowColumn(
                      data: data,
                      bands: bands,
                      window: w,
                      metrics: m,
                      live: liveWindows.contains(w),
                      onTapCell: onTapCell,
                      pendingByKey: pendingByKey,
                      intentKey: intentKey,
                      selectMode: selectMode,
                      onTapGhost: onTapGhost,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _WindowColumn extends StatelessWidget {
  final AtlasGridData data;
  final List<int> bands;
  final int? window;
  final _AtlasMetrics metrics;
  final bool live;
  final ValueChanged<AtlasCellStat>? onTapCell;
  final Map<String, AtlasPending> pendingByKey;
  final String? intentKey;
  final bool selectMode;
  final void Function(int band, int? window)? onTapGhost;

  const _WindowColumn({
    required this.data,
    required this.bands,
    required this.window,
    required this.metrics,
    required this.live,
    required this.onTapCell,
    required this.pendingByKey,
    required this.intentKey,
    required this.selectMode,
    required this.onTapGhost,
  });

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final rare = atlasWindowIsRare(window);
    final hot = atlasWindowIsHot(window);
    final label = window == null
        ? S.of('atlas.window_unknown')
        : '${atlasWindowLabel(window!)}°';

    return Container(
      width: m.cellW,
      decoration: BoxDecoration(
        color: rare
            ? AtlasTokens.rareTint
            : (hot ? AtlasTokens.hotTint : null),
        borderRadius: BorderRadius.circular(m.radius),
        border: rare
            ? Border.all(color: AtlasTokens.rareOutline, width: 1)
            : null,
      ),
      child: Column(
        children: [
          SizedBox(
            height: m.headerH,
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (rare)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(Icons.ac_unit,
                          size: 11, color: AtlasTokens.rareWindow),
                    ),
                  if (hot)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Icon(Icons.wb_sunny,
                          size: 11, color: AtlasTokens.hotWindow),
                    ),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: m.headerSize,
                        fontWeight: live ? FontWeight.w500 : FontWeight.w400,
                        color: live ? AtlasTokens.t55 : AtlasTokens.t22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final b in bands) ...[
            SizedBox(height: m.gap),
            _CellSlot(
              cell: data.byKey[atlasCellKey(b, window)],
              ghost: data.ghostKeys.contains(atlasCellKey(b, window)),
              isNew: data.newKeys.contains(atlasCellKey(b, window)),
              pending: pendingByKey[atlasCellKey(b, window)],
              intent: intentKey != null && intentKey == atlasCellKey(b, window),
              metrics: m,
              onTapCell: onTapCell,
              selectMode: selectMode,
              onTapGhost: onTapGhost,
              band: b,
              window: window,
            ),
          ],
        ],
      ),
    );
  }
}

class _CellSlot extends StatelessWidget {
  final AtlasCellStat? cell;
  final bool ghost;
  final bool isNew;
  final AtlasPending? pending;
  final bool intent;
  final _AtlasMetrics metrics;
  final ValueChanged<AtlasCellStat>? onTapCell;
  final bool selectMode;
  final void Function(int band, int? window)? onTapGhost;
  final int band;
  final int? window;

  const _CellSlot({
    required this.cell,
    required this.ghost,
    required this.isNew,
    required this.pending,
    required this.intent,
    required this.metrics,
    required this.onTapCell,
    required this.selectMode,
    required this.onTapGhost,
    required this.band,
    required this.window,
  });

  @override
  Widget build(BuildContext context) {
    final m = metrics;
    final c = cell;
    if (c == null) {
      final pend = pending;
      if (pend != null) {
        // +162: matured, waiting for the session to end. Dashed outline
        // (it is not a cell yet) over a muted fill (it is no longer
        // empty), the live value in white .5, no star — the star counts
        // sessions and this one has not been counted.
        return SizedBox(
          width: m.cellW,
          height: m.cellH,
          child: CustomPaint(
            painter: _GhostPainter(radius: m.radius, fill: AtlasTokens.cardMuted),
            child: Center(
              child: Text(
                pend.kwh100.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: m.medianSize * 0.72,
                  fontWeight: FontWeight.w500,
                  color: AtlasTokens.t50,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        );
      }
      // Ghost — dashed outline, EMPTY inside: no numbers, no progress,
      // no «?» (§7.2). Not a cell in any counter.
      if (!ghost) return SizedBox(width: m.cellW, height: m.cellH);
      final ghostBox = SizedBox(
        width: m.cellW,
        height: m.cellH,
        child: CustomPaint(
          painter: _GhostPainter(
            radius: m.radius,
            fill: selectMode ? AtlasTokens.cardMuted : null,
            stroke: intent ? AtlasTokens.info : null,
          ),
          child: intent
              ? Center(
                  child: Icon(Icons.flag,
                      size: m.starSize, color: AtlasTokens.info))
              : null,
        ),
      );
      final tapGhost = onTapGhost;
      if (!selectMode || tapGhost == null) return ghostBox;
      return InkWell(
        borderRadius: BorderRadius.circular(m.radius),
        onTap: () => tapGhost(band, window),
        child: ghostBox,
      );
    }

    final content = Container(
      width: m.cellW,
      height: m.cellH,
      decoration: BoxDecoration(
        color: isNew ? AtlasTokens.cardActive : AtlasTokens.card,
        borderRadius: BorderRadius.circular(m.radius),
        border: isNew
            ? Border.all(color: AtlasTokens.newCellOutline, width: 1)
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            c.median.toStringAsFixed(1),
            style: TextStyle(
              fontSize: m.medianSize,
              fontWeight: FontWeight.w700,
              color: AtlasTokens.t100,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          // Fork: head unit only, and only when there is a real spread
          // (owner decision 25.07 — a single snapshot renders no fork).
          if (m.forkSize != null && c.hasFork)
            Text(
              '${c.lo.toStringAsFixed(1)}–${c.hi.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: m.forkSize,
                color: AtlasTokens.t45,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          SizedBox(height: m.starSize * 0.15),
          Icon(Icons.star,
              size: m.starSize, color: AtlasTokens.markColor(c.sessions)),
        ],
      ),
    );

    final tap = onTapCell;
    if (tap == null || selectMode) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(m.radius),
      onTap: () => tap(c),
      child: content,
    );
  }
}

/// 1 dp dashed rounded rect, `ghostFrontier`. Flutter has no dashed
/// border, so the outline is walked with PathMetrics — 4 dp dash, 3 dp
/// gap reads as a dotted frontier at 8 dp radius without shimmering on
/// the head unit's low-DPI panel.
class _GhostPainter extends CustomPainter {
  final double radius;

  /// +162: optional fill — a pending cell is no longer empty, and in
  /// selection mode a tappable ghost has to look tappable.
  final Color? fill;

  /// +162: optional stroke override — the intended cell outlines in
  /// `info` so the flag is not the only cue.
  final Color? stroke;

  const _GhostPainter({required this.radius, this.fill, this.stroke});

  static const double _dash = 4;
  static const double _gap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final f = fill;
    if (f != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Offset.zero & size, Radius.circular(radius)),
        Paint()..color = f,
      );
    }
    final paint = Paint()
      ..color = stroke ?? AtlasTokens.ghostFrontier
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var pos = 0.0;
      while (pos < metric.length) {
        final end = math.min(pos + _dash, metric.length);
        canvas.drawPath(metric.extractPath(pos, end), paint);
        pos = end + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_GhostPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.fill != fill ||
      oldDelegate.stroke != stroke;
}

/// Twelve FULL month names — for prose («идёт июль», «атлас · июль
/// 2026»). +162: the year row's own axis keeps the short forms, but
/// everywhere a month is spoken in a sentence the abbreviation read as a
/// bug («июл начат»).
List<String> atlasMonthNamesFull() {
  final parts = S.of('atlas.months_full').split(',');
  if (parts.length == 12) return parts;
  return atlasMonthNames();
}

/// «замер / замера / замеров».
String atlasSnapsWord(int n) => atlasPlural(n, S.of('atlas.snap_one'),
    S.of('atlas.snap_few'), S.of('atlas.snap_many'));

/// Twelve short month names from ONE l10n key (both maps). A 12-element
/// list of keys would be twelve chances to desync the two maps.
List<String> atlasMonthNames() {
  final parts = S.of('atlas.months').split(',');
  if (parts.length == 12) return parts;
  // Never let a malformed override blank the year row.
  return const [
    'янв', 'фев', 'мар', 'апр', 'май', 'июн',
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
  ];
}

/// Russian needs three plural forms and the very first thing the field
/// shows is n = 1 («1 ячеек» would be the first word of the feature).
/// Non-Russian locales fall back to the simple two-form rule.
String atlasPlural(int n, String one, String few, String many) {
  if (S.locale != 'ru') return n == 1 ? one : many;
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 14) return many;
  final mod10 = n % 10;
  if (mod10 == 1) return one;
  if (mod10 >= 2 && mod10 <= 4) return few;
  return many;
}

/// «{n} ячеек · {m} полос» with agreement, optionally + «· просмотр»
/// (the head-unit register — viewing only). Cumulative counters, never a
/// remainder: a remainder would be a completion percentage (И2).
String atlasCountsLabel(int cells, int bands, {bool view = false}) {
  return S
      .of(view ? 'atlas.counts_view' : 'atlas.counts')
      .replaceFirst('{n}', '$cells')
      .replaceFirst(
          '{cells}',
          atlasPlural(cells, S.of('atlas.cell_one'), S.of('atlas.cell_few'),
              S.of('atlas.cell_many')))
      .replaceFirst('{m}', '$bands')
      .replaceFirst(
          '{bands}',
          atlasPlural(bands, S.of('atlas.band_one'), S.of('atlas.band_few'),
              S.of('atlas.band_many')));
}

/// «день / дня / дней» — used by the year row and by both export heroes.
String atlasDaysWord(int n) => atlasPlural(n, S.of('atlas.day_one'),
    S.of('atlas.day_few'), S.of('atlas.day_many'));

/// «независимая сессия / независимые сессии / независимых сессий».
String atlasSessionsWord(int n) => atlasPlural(
    n,
    S.of('atlas.session_one'),
    S.of('atlas.session_few'),
    S.of('atlas.session_many'));

/// Mandatory legend under the matrix (§6.4): star levels 1 / 5 / 15 and
/// what they mean. NO progress toward the next level anywhere (И2).
class AtlasMarkLegend extends StatelessWidget {
  final double fontSize;
  const AtlasMarkLegend({super.key, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    final iconSize = fontSize + 3;
    Widget item(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star, size: iconSize, color: color),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(fontSize: fontSize, color: AtlasTokens.t50)),
          ],
        );
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        item(AtlasTokens.markOne, S.of('atlas.legend_one')),
        item(AtlasTokens.markFive, S.of('atlas.legend_five')),
        item(AtlasTokens.markFifteen, S.of('atlas.legend_fifteen')),
        Text(S.of('atlas.legend_marks'),
            style: TextStyle(fontSize: fontSize, color: AtlasTokens.t50)),
      ],
    );
  }
}

/// The «ГОД» row (§7.2, §2.4 of the patch spec): twelve month segments,
/// touched ones in `progressGhost`. No percentages, no «осталось N» (И2).
class AtlasYearRow extends StatelessWidget {
  final AtlasGridData data;
  final double scaleFactor;
  const AtlasYearRow({
    super.key,
    required this.data,
    this.scaleFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final k = scaleFactor;
    final days = data.daysCollected();
    // One key, twelve short names — intl is not reached from here on
    // purpose (trends.dart owns the DateFormat path and its own
    // fallback; the year row must render a glyph even if intl data is
    // missing on some build flavour).
    final months = atlasMonthNames();
    final now = DateTime.now();
    final summary = S
        .of('atlas.year_summary')
        .replaceFirst('{n}', '$days')
        .replaceFirst('{days}', atlasDaysWord(days))
        .replaceFirst('{month}', atlasMonthNamesFull()[now.month - 1]);

    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.cardMuted,
        borderRadius: BorderRadius.circular(12 * k),
      ),
      padding: EdgeInsets.symmetric(horizontal: 14 * k, vertical: 12 * k),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of('atlas.year_title'),
              style: TextStyle(
                  fontSize: 11 * k,
                  color: AtlasTokens.t50,
                  letterSpacing: 0.5)),
          SizedBox(height: 7 * k),
          Row(
            children: [
              for (int mo = 1; mo <= 12; mo++) ...[
                if (mo > 1) SizedBox(width: 3 * k),
                Expanded(
                  child: Container(
                    height: 16 * k,
                    decoration: BoxDecoration(
                      color: data.monthsTouched.contains(mo)
                          ? AtlasTokens.progressGhost
                          : AtlasTokens.progressTrack,
                      borderRadius: BorderRadius.circular(3 * k),
                    ),
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: 7 * k),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(months[0],
                  style:
                      TextStyle(fontSize: 9 * k, color: AtlasTokens.t35)),
              Text(months[6],
                  style:
                      TextStyle(fontSize: 9 * k, color: AtlasTokens.t35)),
              Text(months[11],
                  style:
                      TextStyle(fontSize: 9 * k, color: AtlasTokens.t35)),
            ],
          ),
          SizedBox(height: 7 * k),
          Text(summary,
              style: TextStyle(fontSize: 11 * k, color: AtlasTokens.t55)),
        ],
      ),
    );
  }
}
