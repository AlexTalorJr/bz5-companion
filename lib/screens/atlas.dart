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
import '../theme/atlas_tokens.dart';
import '../widgets/atlas_export.dart';
import '../widgets/atlas_grid.dart';
import '../widgets/responsive.dart';
import 'atlas_cell_detail.dart';

class AtlasScreen extends StatefulWidget {
  const AtlasScreen({super.key});

  @override
  State<AtlasScreen> createState() => _AtlasScreenState();
}

class _AtlasScreenState extends State<AtlasScreen> {
  Future<AtlasGridData>? _future;
  int _tab = 0; // 0 = Атлас, 1 = Прогноз, 2 = Арка пака (заготовки [1h])

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final db = context.read<ConnectionService>().db;
    _future = db
        .getAtlasSnapshotsForGrid(maxBand: kAtlasBandMaxKmh)
        .then((rows) => AtlasGridData.fromRows(rows));
  }

  Future<void> _refresh() async {
    setState(_reload);
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final bz3 = LayoutBreakpoints.useTallHeadUnit(context);
    final hal = context.watch<HalTelemetryService>();
    final conn = context.watch<ConnectionService>();
    // «Только телефон» for the share button = «not a head unit». The
    // phone cannot know a gear, so the parking clause of §6.12 has no
    // phone-side meaning; the honest reading of the contract line is
    // «этой кнопки нет на ГУ».
    final onHeadUnit = hal.canUseHal;
    final gear =
        hal.useHalForGear ? hal.halGear : conn.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;
    final k = bz3 ? 1.35 : 1.0;

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
                    showExport: !onHeadUnit,
                  ),
                  SizedBox(height: 4 * k),
                  _SeasonLine(data: data, scaleFactor: k),
                  SizedBox(height: 12 * k),
                  _TabPills(
                    index: _tab,
                    scaleFactor: k,
                    onChanged: (i) => setState(() => _tab = i),
                  ),
                  SizedBox(height: 16 * k),
                  if (_tab != 0)
                    _StubCard(scaleFactor: k)
                  else if (onHeadUnit && !isParked)
                    _ParkedOnlyCard(scaleFactor: k)
                  else ...[
                    AtlasGrid(
                      data: data,
                      scale:
                          bz3 ? AtlasGridScale.bz3 : AtlasGridScale.phone,
                      onTapCell: bz3
                          ? null
                          : (cell) => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      AtlasCellDetailScreen(cell: cell),
                                ),
                              ),
                    ),
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
    final months = atlasMonthNames();
    final month = months[DateTime.now().month - 1];
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

/// Head unit, car moving: the matrix is not a driving surface.
class _ParkedOnlyCard extends StatelessWidget {
  final double scaleFactor;
  const _ParkedOnlyCard({required this.scaleFactor});

  @override
  Widget build(BuildContext context) {
    final k = scaleFactor;
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.cardMuted,
        borderRadius: BorderRadius.circular(16 * k),
      ),
      padding: EdgeInsets.symmetric(horizontal: 18 * k, vertical: 22 * k),
      child: Row(
        children: [
          Icon(Icons.grid_view, size: 18 * k, color: AtlasTokens.t22),
          SizedBox(width: 10 * k),
          Expanded(
            child: Text(S.of('atlas.parked_only'),
                style: TextStyle(fontSize: 13 * k, color: AtlasTokens.t50)),
          ),
        ],
      ),
    );
  }
}
