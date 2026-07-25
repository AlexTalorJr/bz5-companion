// v0.1.62+161 «Атлас» patch 3 — cell detail (SPEC.md v1.1 §7.3, mockup
// [1d]). Phone only: the head unit is a viewer and its cells are dead by
// contract («тап по ячейке на ГУ ничего не открывает», §7.2).
//
// Everything here is read straight from atlas_snapshots — never from the
// prefs ledger. That is what makes a reinstall self-healing: the cloud
// refills the table and this screen comes back with it.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/atlas_projection.dart';
import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';
import '../theme/atlas_tokens.dart';
import '../widgets/atlas_grid.dart'
    show atlasSessionsWord, atlasSnapsWord;

class AtlasCellDetailScreen extends StatefulWidget {
  final AtlasCellStat cell;
  const AtlasCellDetailScreen({super.key, required this.cell});

  @override
  State<AtlasCellDetailScreen> createState() => _AtlasCellDetailScreenState();
}

class _AtlasCellDetailScreenState extends State<AtlasCellDetailScreen> {
  Future<List<AtlasSnapshotRow>>? _future;

  @override
  void initState() {
    super.initState();
    // Deferred to didChangeDependencies-free ground: context.read is
    // legal in initState for a provider that is already above us.
    final db = context.read<ConnectionService>().db;
    _future = db.getAtlasSnapshotsForCell(widget.cell.band, widget.cell.window);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final c = widget.cell;
    final title = S
        .of('atlas.cell_title')
        .replaceFirst('{v}', '${c.band}')
        .replaceFirst(
            '{w}',
            c.window == null
                ? S.of('atlas.window_unknown')
                : '${atlasWindowLabel(c.window!)}°');

    return Scaffold(
      backgroundColor: AtlasTokens.bg,
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<List<AtlasSnapshotRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${S.of('atlas.load_failed')} ${snap.error}',
                    style: const TextStyle(color: AtlasTokens.t60)),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = [...snap.data!]
            ..sort((a, b) => b.frozenAt.compareTo(a.frozenAt));
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SummaryCard(cell: c),
              const SizedBox(height: 10),
              _DistributionCard(rows: rows),
              const SizedBox(height: 10),
              _SnapshotList(rows: rows),
            ],
          );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final AtlasCellStat cell;
  const _SummaryCard({required this.cell});

  @override
  Widget build(BuildContext context) {
    final c = cell;
    final rare = atlasWindowIsRare(c.window);
    final hot = atlasWindowIsHot(c.window);
    // Range bar geometry: the fork occupies the whole track, the median
    // marker sits proportionally inside it. A degenerate fork (one
    // snapshot) draws the marker in the middle of a full track.
    final span = c.hi - c.lo;
    final pos = span.abs() < 1e-9 ? 0.5 : (c.median - c.lo) / span;

    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (c.hasFork)
                Text(c.lo.toStringAsFixed(1),
                    style: const TextStyle(
                        fontSize: 20,
                        color: AtlasTokens.t45,
                        fontFeatures: [FontFeature.tabularFigures()])),
              if (c.hasFork) const SizedBox(width: 10),
              Text(c.median.toStringAsFixed(1),
                  style: const TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      color: AtlasTokens.t100,
                      fontFeatures: [FontFeature.tabularFigures()])),
              if (c.hasFork) const SizedBox(width: 10),
              if (c.hasFork)
                Text(c.hi.toStringAsFixed(1),
                    style: const TextStyle(
                        fontSize: 20,
                        color: AtlasTokens.t45,
                        fontFeatures: [FontFeature.tabularFigures()])),
              const Spacer(),
              Icon(Icons.star,
                  size: 22, color: AtlasTokens.markColor(c.sessions)),
              const SizedBox(width: 6),
              Text(
                S
                    .of('atlas.cell_sessions')
                    .replaceFirst('{n}', '${c.sessions}')
                    .replaceFirst('{sessions}', atlasSessionsWord(c.sessions)),
                style: const TextStyle(fontSize: 12, color: AtlasTokens.t60),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            c.hasFork
                ? S.of('atlas.cell_sub')
                : S.of('atlas.cell_sub_single'),
            style: const TextStyle(fontSize: 11, color: AtlasTokens.t45),
          ),
          const SizedBox(height: 12),
          // Range track + median marker.
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              return SizedBox(
                height: 12,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0x591DE9B6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    Positioned(
                      left: (w - 3) * pos.clamp(0.0, 1.0),
                      top: 0,
                      bottom: 0,
                      child: Container(width: 3, color: AtlasTokens.progress),
                    ),
                  ],
                ),
              );
            },
          ),
          if (rare || hot) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(rare ? Icons.ac_unit : Icons.wb_sunny,
                    size: 14,
                    color:
                        rare ? AtlasTokens.rareWindow : AtlasTokens.hotWindow),
                const SizedBox(width: 6),
                Text(
                  S
                      .of(rare ? 'atlas.window_rare' : 'atlas.window_hot')
                      .replaceFirst('{w}', atlasWindowLabel(c.window!)),
                  style: const TextStyle(fontSize: 12, color: AtlasTokens.t60),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            S
                .of('atlas.cell_steady')
                .replaceFirst('{s}', '${c.steadySeconds.round()}')
                .replaceFirst('{n}', '${c.snapshots}')
                .replaceFirst('{snaps}', atlasSnapsWord(c.snapshots)),
            style: const TextStyle(fontSize: 11, color: AtlasTokens.t45),
          ),
        ],
      ),
    );
  }
}

/// «РАСПРЕДЕЛЕНИЕ СНИМКОВ» — a mini histogram: modal bin in `progress`,
/// the rest white .14–.2. No axis, no numbers: the shape is the message.
class _DistributionCard extends StatelessWidget {
  final List<AtlasSnapshotRow> rows;
  const _DistributionCard({required this.rows});

  static const int _bins = 8;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final vals = [for (final r in rows) r.kwh100]..sort();
    final lo = vals.first;
    final hi = vals.last;
    final counts = List<int>.filled(_bins, 0);
    if ((hi - lo).abs() < 1e-9) {
      counts[_bins ~/ 2] = vals.length;
    } else {
      for (final v in vals) {
        var idx = ((v - lo) / (hi - lo) * _bins).floor();
        if (idx >= _bins) idx = _bins - 1;
        if (idx < 0) idx = 0;
        counts[idx]++;
      }
    }
    final maxCount = counts.reduce((a, b) => a > b ? a : b);

    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of('atlas.cell_dist'),
              style: const TextStyle(
                  fontSize: 11,
                  color: AtlasTokens.t50,
                  letterSpacing: 0.5)),
          const SizedBox(height: 12),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < _bins; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: maxCount == 0
                          ? 2
                          : (4 + 52 * counts[i] / maxCount),
                      decoration: BoxDecoration(
                        color: counts[i] == maxCount && counts[i] > 0
                            ? AtlasTokens.progress
                            : const Color(0x33FFFFFF),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotList extends StatelessWidget {
  final List<AtlasSnapshotRow> rows;
  const _SnapshotList({required this.rows});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd.MM HH:mm');
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of('atlas.cell_snapshots'),
              style: const TextStyle(
                  fontSize: 11,
                  color: AtlasTokens.t50,
                  letterSpacing: 0.5)),
          for (final r in rows) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Divider(height: 1, color: Color(0x0DFFFFFF)),
            ),
            Row(
              children: [
                SizedBox(
                  width: 92,
                  child: Text(fmt.format(r.frozenAt),
                      style: const TextStyle(
                          fontSize: 12,
                          color: AtlasTokens.t60,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                Expanded(
                  child: Text(r.kwh100.toStringAsFixed(1),
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AtlasTokens.t100,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                SizedBox(
                  width: 62,
                  child: Text('${r.steadySeconds.round()} ${S.of('measure.s')}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: AtlasTokens.t60,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                      r.packTempAvgC == null
                          ? '—'
                          : '${r.packTempAvgC!.round()}°',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AtlasTokens.t60,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
