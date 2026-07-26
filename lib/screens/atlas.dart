// v0.1.62+161 «Атлас» patch 3 — the atlas screen for the phone and the
// BZ3 head unit (SPEC.md v1.1 §7.2, mockups [1c] / [3c] / [5a]).
//
// The screen is READ-ONLY on every host: it draws atlas_snapshots and
// nothing else. No recording, no ledger, no reward engine — those stay
// exactly where +160 left them.
//
// Host differences (one screen, two hosts):
//   • phone — cells are tappable (→ detail §7.3), the export button
//     lives in the header, no fork inside a cell (§11);
//   • BZ3   — bigger type per §3, cells are DEAD («тап по ячейке на ГУ
//     ничего не открывает»), fork rendered inside the cell, and the
//     matrix is replaced by a muted «доступен на стоянке» panel while
//     the car is moving (§7.2 «только на стоянке»). Hiding content in
//     motion is the driving-safe direction of И1, not a violation of it.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/atlas_projection.dart';
import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import '../widgets/atlas_export.dart';
import '../widgets/atlas_grid.dart';
import '../widgets/responsive.dart';
import 'atlas_cell_detail.dart';

class AtlasScreen extends StatefulWidget {
  /// +162 ([5a] / §3.2): «Другая ячейка» opens the atlas in SELECTION
  /// mode — cells go quiet, frontier ghosts become the touch targets,
  /// and tapping one takes the intention and pops back.
  final bool selectGhostMode;

  const AtlasScreen({super.key, this.selectGhostMode = false});

  @override
  State<AtlasScreen> createState() => _AtlasScreenState();
}

class _AtlasScreenState extends State<AtlasScreen> {
  Future<AtlasGridData>? _future;
  int _tab = 0; // 0 = Атлас, 1 = Прогноз, 2 = Здоровье батареи ([1h])

  /// +162: the atlas revision this future was built from. A freeze or a
  /// reveal bumps it and the screen re-reads — without this, a grid left
  /// open on a parked head unit never noticed the session rotating.
  int _loadedRevision = -1;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final db = context.read<ConnectionService>().db;
    final sp = context.read<SpeedProfileService>();
    _loadedRevision = sp.atlasRevision;
    _future = db
        .getAtlasSnapshotsForGrid(maxBand: kAtlasBandMaxKmh)
        .then((rows) => AtlasGridData.fromRows(rows,
            // +164 (BC7b): rows of the RUNNING session are provisional
            // chunks — §6.13 paints them, the grid must not count them.
            activeSessionUid: sp.atlasSessionUid));
  }

  Future<void> _refresh() async {
    setState(_reload);
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    // Three form factors, not two: the intention picker is pushed from
    // the BZ5 «Замеры» screen too, and before this it rendered 52 dp
    // phone cells on a 2175 dp panel.
    final wide = LayoutBreakpoints.useHeadUnitLayout(context);
    final bz3 = LayoutBreakpoints.useTallHeadUnit(context);
    final scale = wide
        ? AtlasGridScale.bz5
        : (bz3 ? AtlasGridScale.bz3 : AtlasGridScale.phone);
    final onHu = wide || bz3;
    final hal = context.watch<HalTelemetryService>();
    // «Только телефон» for the share button = «not a head unit». The
    // phone cannot know a gear, so the parking clause of §6.12 has no
    // phone-side meaning; the honest reading of the contract line is
    // «этой кнопки нет на ГУ».
    final onHeadUnit = hal.canUseHal;
    // +162 (field verdict 25.07): the atlas is NO LONGER hidden while
    // the car moves. It carries no live information, nobody looks at it
    // in motion — but a full-screen «доступен на стоянке» panel in place
    // of the map was actively irritating. Nothing appears in motion
    // (И1 holds); something simply stops disappearing.
    final sp = context.watch<SpeedProfileService>();
    if (sp.atlasRevision != _loadedRevision) _reload();
    final pending = [
      for (final c in sp.atlasPendingCells())
        AtlasPending(band: c.band, window: c.window, kwh100: c.kwh100),
    ];
    final intent = sp.atlasIntent;
    final k = wide ? 1.7 : (bz3 ? 1.35 : 1.0);

    return Scaffold(
      backgroundColor: AtlasTokens.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<AtlasGridData>(
            future: _future,
            builder: (context, snap) {
              if (snap.hasError) {
                return ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text('${S.of('atlas.load_failed')} ${snap.error}',
                        style: const TextStyle(color: AtlasTokens.t60)),
                  ],
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snap.data!;
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(20, 8 * k, 20, 24),
                children: [
                  _Header(
                    data: data,
                    scaleFactor: k,
                    // A picker is a picker: no sharing from inside it.
                    showExport: !onHeadUnit && !widget.selectGhostMode,
                  ),
                  SizedBox(height: 4 * k),
                  if (!widget.selectGhostMode) ...[
                    _SeasonLine(data: data, scaleFactor: k),
                    SizedBox(height: 12 * k),
                    _TabPills(
                      index: _tab,
                      scaleFactor: k,
                      onChanged: (i) => setState(() => _tab = i),
                    ),
                  ],
                  SizedBox(height: 16 * k),
                  if (_tab != 0)
                    _StubCard(scaleFactor: k)
                  else ...[
                    if (widget.selectGhostMode) ...[
                      Text(S.of('atlas.select_hint'),
                          style: TextStyle(
                              fontSize: 12 * k,
                              height: 1.5,
                              color: AtlasTokens.info)),
                      SizedBox(height: 10 * k),
                    ],
                    AtlasGrid(
                      data: data,
                      scale: scale,
                      pending: pending,
                      intentKey: intent?.key,
                      selectMode: widget.selectGhostMode,
                      onTapGhost: widget.selectGhostMode
                          ? (band, window) {
                              sp.takeAtlasIntent(band, window);
                              Navigator.of(context).maybePop();
                            }
                          : null,
                      onTapCell: onHu
                          ? null
                          : (cell) => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      AtlasCellDetailScreen(cell: cell),
                                ),
                              ),
                    ),
                    if (pending.isNotEmpty) ...[
                      SizedBox(height: 10 * k),
                      Text(S.of('atlas.pending_note'),
                          style: TextStyle(
                              fontSize: 11 * k,
                              height: 1.5,
                              color: AtlasTokens.t45)),
                    ],
                    // A picker is a picker: the legend, the prose and the
                    // year row are noise while choosing a goal.
                    if (!widget.selectGhostMode) ...[
                      SizedBox(height: 14 * k),
                      AtlasMarkLegend(fontSize: 11 * k),
                      SizedBox(height: 10 * k),
                      Text(
                        S.of('atlas.grid_note'),
                        style: TextStyle(
                            fontSize: 11 * k,
                            height: 1.55,
                            color: AtlasTokens.t45),
                      ),
                      if (onHeadUnit) ...[
                        SizedBox(height: 8 * k),
                        Text(S.of('atlas.view_only'),
                            style: TextStyle(
                                fontSize: 11 * k, color: AtlasTokens.t40)),
                      ],
                      SizedBox(height: 16 * k),
                      AtlasYearRow(data: data, scaleFactor: k),
                    ],
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AtlasGridData data;
  final double scaleFactor;
  final bool showExport;
  const _Header({
    required this.data,
    required this.scaleFactor,
    required this.showExport,
  });

  @override
  Widget build(BuildContext context) {
    final k = scaleFactor;
    // On the BZ3 this screen is a PUSHED route (entered from the parked
    // «Замеры» card), and a head unit cannot be relied on to have a system
    // back gesture — so the header grows its own arrow whenever there is
    // something to pop. As a phone TAB canPop is false and nothing shows.
    final canPop = Navigator.of(context).canPop();
    return Row(
      children: [
        if (canPop) ...[
          IconButton(
            icon: Icon(Icons.arrow_back, size: 22 * k),
            color: AtlasTokens.t85,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          SizedBox(width: 12 * k),
        ],
        Text(S.of('atlas.title'),
            style: TextStyle(
                fontSize: 22 * k,
                fontWeight: FontWeight.w500,
                color: AtlasTokens.t100)),
        const Spacer(),
        // Counter is CUMULATIVE («сколько накоплено»), never a remainder
        // — a remainder would be a completion percentage (И2).
        Text(
          atlasCountsLabel(data.cellCount, data.bandCount),
          style: TextStyle(fontSize: 11.5 * k, color: AtlasTokens.t50),
        ),
        if (showExport) ...[
          SizedBox(width: 6 * k),
          IconButton(
            icon: Icon(Icons.ios_share, size: 20 * k),
            color: AtlasTokens.t60,
            tooltip: S.of('export.share'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AtlasExportScreen(data: data),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SeasonLine extends StatelessWidget {
  final AtlasGridData data;
  final double scaleFactor;
  const _SeasonLine({required this.data, required this.scaleFactor});

  @override
  Widget build(BuildContext context) {
    final month = atlasMonthNamesFull()[DateTime.now().month - 1];
    final lo = data.seasonLoC;
    final hi = data.seasonHiC;
    final text = (lo == null || hi == null)
        ? S.of('atlas.season_ctx_nr').replaceFirst('{month}', month)
        : S
            .of('atlas.season_ctx')
            .replaceFirst('{month}', month)
            .replaceFirst('{lo}', '$lo')
            .replaceFirst('{hi}', '$hi');
    return Text(text,
        style: TextStyle(
            fontSize: 11.5 * scaleFactor, color: AtlasTokens.t50));
  }
}

class _TabPills extends StatelessWidget {
  final int index;
  final double scaleFactor;
  final ValueChanged<int> onChanged;
  const _TabPills({
    required this.index,
    required this.scaleFactor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final k = scaleFactor;
    final labels = [
      S.of('atlas.tab_atlas'),
      S.of('atlas.tab_forecast'),
      S.of('atlas.tab_arc'),
    ];
    return Row(
      children: [
        for (int i = 0; i < labels.length; i++) ...[
          if (i > 0) SizedBox(width: 6 * k),
          InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => onChanged(i),
            child: Container(
              decoration: BoxDecoration(
                color: i == index ? AtlasTokens.cardActive : null,
                borderRadius: BorderRadius.circular(999),
              ),
              padding: EdgeInsets.symmetric(
                  horizontal: 16 * k, vertical: 6 * k),
              child: Text(labels[i],
                  style: TextStyle(
                    fontSize: 12.5 * k,
                    fontWeight:
                        i == index ? FontWeight.w500 : FontWeight.w400,
                    color: i == index ? AtlasTokens.t100 : AtlasTokens.t50,
                  )),
            ),
          ),
        ],
      ],
    );
  }
}

/// «Прогноз» / «Арка пака» — frames only ([1h], second priority).
class _StubCard extends StatelessWidget {
  final double scaleFactor;
  const _StubCard({required this.scaleFactor});

  @override
  Widget build(BuildContext context) {
    final k = scaleFactor;
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.cardMuted,
        borderRadius: BorderRadius.circular(16 * k),
      ),
      padding: EdgeInsets.symmetric(horizontal: 18 * k, vertical: 22 * k),
      child: Text(S.of('atlas.stub'),
          style: TextStyle(
              fontSize: 12 * k, height: 1.5, color: AtlasTokens.t45)),
    );
  }
}
