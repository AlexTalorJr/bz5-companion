// v0.1.62+161 «Атлас» patch 3 — the BZ5 atlas (SPEC.md v1.1 §7.2,
// mockup [2c]). A pushed route, entered from the parked «Замеры» screen.
//
// Head-unit rules, all three from the contract: viewing only («тап по
// ячейке ничего не открывает»), parking only, and an explicit «детали на
// телефоне» line so the driver is never left hunting for a tap target
// that does not exist.
//
// ~9 windows fit at 2175 dp without scrolling; wider matrices swipe
// horizontally with the band column pinned (AtlasGrid does that itself).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/atlas_projection.dart';
import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/locale_service.dart';
import '../../services/speed_profile_service.dart';
import '../../theme/atlas_tokens.dart';
import '../../widgets/atlas_grid.dart';

class AtlasWideScreen extends StatefulWidget {
  const AtlasWideScreen({super.key});

  @override
  State<AtlasWideScreen> createState() => _AtlasWideScreenState();
}

class _AtlasWideScreenState extends State<AtlasWideScreen> {
  Future<AtlasGridData>? _future;

  /// +162: re-read when the atlas on disk moves (freeze / reveal / «Ок»).
  int _loadedRevision = -1;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final db = context.read<ConnectionService>().db;
    _loadedRevision = context.read<SpeedProfileService>().atlasRevision;
    _future = db
        .getAtlasSnapshotsForGrid(maxBand: kAtlasBandMaxKmh)
        .then((rows) => AtlasGridData.fromRows(rows));
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    // +162 (field verdict 25.07): no motion gate. The map holds nothing
    // live, so hiding it bought nothing and the blocking panel annoyed.
    final sp = context.watch<SpeedProfileService>();
    if (sp.atlasRevision != _loadedRevision) _reload();
    final pending = [
      for (final c in sp.atlasPendingCells())
        AtlasPending(band: c.band, window: c.window, kwh100: c.kwh100),
    ];
    final intent = sp.atlasIntent;

    return Scaffold(
      backgroundColor: AtlasTokens.bg,
      body: SafeArea(
        minimum: const EdgeInsets.only(top: 8),
        child: FutureBuilder<AtlasGridData>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Text('${S.of('atlas.load_failed')} ${snap.error}',
                    style: const TextStyle(color: AtlasTokens.t60)),
              );
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final data = snap.data!;
            return Padding(
              padding: const EdgeInsets.fromLTRB(26, 16, 26, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, size: 34),
                        color: AtlasTokens.t85,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Text(S.of('atlas.title_hu'),
                          style: const TextStyle(
                              fontSize: 34,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 2,
                              color: AtlasTokens.t100)),
                      const SizedBox(width: 26),
                      Text(
                        atlasCountsLabel(data.cellCount, data.bandCount),
                        style: const TextStyle(
                            fontSize: 22, color: AtlasTokens.t55),
                      ),
                      const Spacer(),
                      Text(S.of('atlas.view_only'),
                          style: const TextStyle(
                              fontSize: 20, color: AtlasTokens.t40)),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: ListView(
                      children: [
                        AtlasGrid(
                          data: data,
                          scale: AtlasGridScale.bz5,
                          pending: pending,
                          intentKey: intent?.key,
                          // Cells are dead by contract on the head unit.
                        ),
                        if (pending.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Text(S.of('atlas.pending_note'),
                              style: const TextStyle(
                                  fontSize: 18, color: AtlasTokens.t45)),
                        ],
                        const SizedBox(height: 20),
                        const AtlasMarkLegend(fontSize: 18),
                        const SizedBox(height: 18),
                        AtlasYearRow(data: data, scaleFactor: 1.7),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
