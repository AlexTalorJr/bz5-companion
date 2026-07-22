// v0.1.52+151 «Замеры» — the third History tab. Table of per-band
// consumption + U1 range line, U2 bar chart above the table, the 0–100
// block, and the U3 archive with A/B comparison. HU-only by placement
// (history.dart hides the tab when !canUseHal). SPEC v1.2.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/locale_service.dart';
import '../services/speed_profile_service.dart';

class SpeedProfileScreen extends StatefulWidget {
  const SpeedProfileScreen({super.key});

  @override
  State<SpeedProfileScreen> createState() => _SpeedProfileScreenState();
}

class _SpeedProfileScreenState extends State<SpeedProfileScreen> {
  /// U3 comparison picker: indices into the archive list. When exactly
  /// two are ticked the «Сравнить А/Б» button lights up.
  final Set<int> _compareSel = {};

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final svc = context.watch<SpeedProfileService>();
    final s = svc.session;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _StatusCard(svc: svc, onStop: () => _onStop(context, svc)),
        if (s != null) ...[
          const SizedBox(height: 12),
          _BandBarCard(session: s),
          const SizedBox(height: 12),
          _BandTableCard(session: s),
          if (s.maturingBands.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MaturingCard(session: s),
          ],
          const SizedBox(height: 12),
          _ZeroTo100Card(session: s),
          // TEMP DIAG (+153): tick-gate counters — REMOVE after the
          // field diagnosis, the user never needs raw gate numbers.
          const SizedBox(height: 8),
          _TickDiagRow(diag: s.diag),
        ],
        const SizedBox(height: 12),
        _buildArchive(context, svc),
        const SizedBox(height: 8),
        // Honest platform limitation, spelled out (spec §5): a sleeping
        // head unit measures nothing — same physics as the AC night.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            S.of('measure.sleep_note'),
            style: TextStyle(
                fontSize: 12, color: Colors.white.withOpacity(0.4)),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ─────────────────────────── Стоп → save ───────────────────────────

  Future<void> _onStop(
      BuildContext context, SpeedProfileService svc) async {
    await svc.stop();
    if (!context.mounted) return;
    await _showSaveDialog(context, svc);
  }

  Future<void> _showSaveDialog(
      BuildContext context, SpeedProfileService svc) async {
    final nameCtl = TextEditingController(text: svc.autoName());
    final noteCtl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('measure.save_q')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration:
                  InputDecoration(labelText: S.of('measure.save_name')),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtl,
              decoration:
                  InputDecoration(labelText: S.of('measure.save_note')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of('common.save')),
          ),
        ],
      ),
    );
    if (saved != true || !context.mounted) return;

    var evict = false;
    if (svc.archiveFull) {
      // Eviction is never silent (U3) — the oldest session leaves only
      // after an explicit yes.
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.of('measure.evict_q')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(S.of('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(S.of('common.ok')),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      evict = true;
    }
    await svc.saveToArchive(nameCtl.text, noteCtl.text,
        evictOldest: evict);
    // p.3 of the +151 review: the archive just mutated (append and
    // possibly a mid-list eviction) — stale A/B indices would silently
    // point at DIFFERENT sessions. Same rule as delete: any archive
    // mutation clears the picker.
    if (mounted) setState(_compareSel.clear);
  }

  // ───────────────────────────── archive ─────────────────────────────

  Widget _buildArchive(BuildContext context, SpeedProfileService svc) {
    final items = svc.archive;
    final children = <Widget>[
      Row(
        children: [
          Expanded(
            child: Text(S.of('measure.archive_title'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          if (_compareSel.length == 2)
            TextButton.icon(
              icon: const Icon(Icons.compare_arrows, size: 18),
              label: Text(S.of('measure.compare')),
              onPressed: () {
                final sel = _compareSel.toList()..sort();
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _CompareScreen(
                    a: items[sel[0]],
                    b: items[sel[1]],
                  ),
                ));
              },
            ),
        ],
      ),
      const SizedBox(height: 4),
    ];
    if (items.isEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(S.of('measure.archive_empty'),
            style: TextStyle(color: Colors.white.withOpacity(0.5))),
      ));
    }
    for (var i = 0; i < items.length; i++) {
      final a = items[i];
      final selected = _compareSel.contains(i);
      children.add(Card(
        child: ListTile(
          dense: true,
          leading: Checkbox(
            value: selected,
            onChanged: (v) => setState(() {
              if (v == true) {
                if (_compareSel.length < 2) _compareSel.add(i);
              } else {
                _compareSel.remove(i);
              }
            }),
          ),
          title: Row(children: [
            Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis)),
            if (a.session.coldPack)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.ac_unit,
                    size: 15, color: Colors.lightBlue.shade200),
              ),
          ]),
          subtitle: a.note.isEmpty ? null : Text(a.note),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => _ArchivedDetailScreen(entry: a),
            ));
          },
          onLongPress: () => _confirmDelete(context, svc, i),
        ),
      ));
    }
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Future<void> _confirmDelete(
      BuildContext context, SpeedProfileService svc, int index) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.of('measure.delete_q')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.of('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.of('common.ok')),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(_compareSel.clear);
      await svc.deleteArchived(index);
    }
  }
}

// ──────────────── maturing bands («полоса зреет») ────────────────

/// Permanent progress UX (+153): bands that are accumulating but have
/// not yet earned their table row. Without this the first hour of use
/// looks dead — the user must SEE that steady driving is being
/// counted, and how far each band is from materialising.
class _MaturingCard extends StatelessWidget {
  final SpeedProfileSession session;
  const _MaturingCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final maturing = session.maturingBands;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('measure.maturing'),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.6))),
            const SizedBox(height: 8),
            for (final b in maturing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                      width: 44,
                      child: Text('$b',
                          style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.6)))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (session.bands[b]!.timeS / kBandMinSeconds)
                            .clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: Colors.white.withOpacity(0.08),
                        color:
                            Colors.tealAccent.shade400.withOpacity(0.55),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${session.bands[b]!.timeS.floor()} ${S.of('measure.of')} ${kBandMinSeconds.floor()} ${S.of('measure.s')}',
                    style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.5)),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────── TEMP DIAG (+153): tick-gate counters ───────────────

/// REMOVE after the field diagnosis. Raw first-failing-gate counters:
/// «тик · безΔv · |a|> · вне · V/I · P≤0 · ✓». One drive with these
/// numbers names the gate that starves the bands.
class _TickDiagRow extends StatelessWidget {
  final TickDiag diag;
  const _TickDiagRow({required this.diag});

  @override
  Widget build(BuildContext context) {
    final d = diag;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        'diag: тик ${d.total} · прогрев ${d.warming}'
        ' · вне ${d.outOfBand} · V/I ${d.powerStale}'
        ' · ✓ ${d.qualified} (из них P≤0 ${d.negPower})'
        ' · вирт ${d.virtualTicks} · дроп ${d.gapDrops}'
        ' (макс ${d.maxGapS.toStringAsFixed(1)}с)',
        style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: Colors.white.withOpacity(0.35)),
      ),
    );
  }
}

// ─────────────────────────── status card ───────────────────────────

class _StatusCard extends StatelessWidget {
  final SpeedProfileService svc;
  final VoidCallback onStop;
  const _StatusCard({required this.svc, required this.onStop});

  // TEMP DIAG (+153): remove with the counters.
  Future<void> _onDump(
      BuildContext context, SpeedProfileService svc) async {
    final res = await svc.dumpDiag();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(res == null
          ? S.of('measure.dump_fail')
          : '${S.of('measure.dump_ok')} ${res.path}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = svc.session;
    final String status;
    if (svc.active && s != null) {
      final bands = s.visibleBands.length;
      status =
          '${S.of('measure.status_running')} · ${svc.sessionMinutes} ${S.of('measure.min')} · $bands ${S.of('measure.bands')}';
    } else if (s != null) {
      status = S.of('measure.status_stopped');
    } else {
      status = S.of('measure.status_idle');
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                svc.active
                    ? Icons.fiber_manual_record
                    : Icons.speed_outlined,
                size: 18,
                color: svc.active ? Colors.redAccent : Colors.white54,
              ),
              const SizedBox(width: 8),
              Expanded(
                  child:
                      Text(status, style: const TextStyle(fontSize: 14))),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(S.of('measure.start')),
                onPressed: svc.active ? null : () => svc.start(),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.stop, size: 18),
                label: Text(S.of('measure.stop')),
                onPressed: svc.active ? onStop : null,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.replay, size: 18),
                label: Text(S.of('measure.reset')),
                onPressed: svc.session == null ? null : () => svc.reset(),
              ),
              // TEMP DIAG (+153): dump the session JSON into
              // bz5_companion_diag.md (Downloads → USB, the Native
              // Explorer diary workflow). Remove with the counters.
              OutlinedButton.icon(
                icon: const Icon(Icons.save_alt, size: 18),
                label: Text(S.of('measure.dump')),
                onPressed: svc.session == null
                    ? null
                    : () => _onDump(context, svc),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────── U2: band bar chart ────────────────────────

/// Bar chart of kWh/100km per band, ABOVE the table (U2). Follows the
/// Trends _BarCard survival rules for the BZ5 head unit: NO
/// BarTouchData whatsoever (the +45 fl_chart 0.68 release-mode white
/// card), text fallback below 3 bands (rectangles without a shape to
/// read are not a chart). Bands with no data simply don't exist here.
class _BandBarCard extends StatelessWidget {
  final SpeedProfileSession session;
  const _BandBarCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final bands = session.visibleBands;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('measure.chart_title'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (bands.isEmpty)
              Text(S.of('measure.no_data'),
                  style: TextStyle(color: Colors.white.withOpacity(0.5)))
            else if (bands.length < 3)
              _textFallback(bands)
            else
              SizedBox(height: 160, child: _chart(bands)),
          ],
        ),
      ),
    );
  }

  Widget _textFallback(List<int> bands) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in bands)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '$b → ${session.bands[b]!.consumptionKwh100!.toStringAsFixed(1)} ${S.of('measure.kwh100')}',
              style: const TextStyle(fontSize: 14),
            ),
          ),
      ],
    );
  }

  Widget _chart(List<int> bands) {
    double maxV = 0;
    double minV = 0;
    for (final b in bands) {
      final c = session.bands[b]!.consumptionKwh100 ?? 0;
      if (c > maxV) maxV = c;
      if (c < minV) minV = c;
    }
    // Index-based x (the Trends _BarCard pattern) — band values as x
    // would make fl_chart title interpolated ticks between the bars.
    return BarChart(
      BarChartData(
        maxY: maxV * 1.15 + 0.1,
        minY: minV < 0 ? minV * 1.15 - 0.1 : 0,
        barTouchData: BarTouchData(enabled: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: 1,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (v != i.toDouble() || i < 0 || i >= bands.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${bands[i]}',
                      style: const TextStyle(fontSize: 11)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < bands.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: session.bands[bands[i]]!.consumptionKwh100 ?? 0,
                width: 14,
                color: Colors.tealAccent.shade400,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
              ),
            ]),
        ],
      ),
    );
  }
}

// ───────────────────────── U1: band table ─────────────────────────

class _BandTableCard extends StatelessWidget {
  final SpeedProfileSession session;
  const _BandTableCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final bands = session.visibleBands;
    if (bands.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in bands)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _bandRow(b, session.bands[b]!),
              ),
          ],
        ),
      ),
    );
  }

  /// «100 · 16.3 кВт·ч/100км · ≈ 400 км на заряде · 4м 12с» — the U1
  /// range translation (capacity / consumption × 100) is the whole
  /// point of the number: "drive 110 or 130 to the charger". Time in
  /// band = how much to trust the row.
  Widget _bandRow(int band, SpeedBandAgg agg) {
    final cons = agg.consumptionKwh100;
    if (cons == null) return const SizedBox.shrink();
    // +155: energy is signed — a long descent can legitimately push a
    // band near or below zero. The range translation only makes sense
    // for a meaningful positive draw; below that show the number alone.
    final String line;
    if (cons > 0.5) {
      final rangeKm =
          SpeedProfileService.packCapacityKwh / cons * 100.0;
      line =
          '${cons.toStringAsFixed(1)} ${S.of('measure.kwh100')} · ≈ ${rangeKm.round()} ${S.of('measure.range_suffix')}';
    } else {
      line = '${cons.toStringAsFixed(1)} ${S.of('measure.kwh100')}';
    }
    final mins = (agg.timeS / 60).floor();
    final secs = (agg.timeS % 60).floor();
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text('$band',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(
            line,
            style: const TextStyle(fontSize: 14),
          ),
        ),
        Text('$mins${S.of('measure.m')} $secs${S.of('measure.s')}',
            style: TextStyle(
                fontSize: 12, color: Colors.white.withOpacity(0.5))),
      ],
    );
  }
}

// ─────────────────────────── 0–100 card ───────────────────────────

class _ZeroTo100Card extends StatelessWidget {
  final SpeedProfileSession session;
  const _ZeroTo100Card({required this.session});

  @override
  Widget build(BuildContext context) {
    final best = session.bestZeroTo100;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(S.of('measure.z100_title'),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (session.runs.isEmpty)
              Text(S.of('measure.z100_none'),
                  style: TextStyle(color: Colors.white.withOpacity(0.5)))
            else ...[
              Text(
                '${S.of('measure.z100_best')}: ${best!.toStringAsFixed(1)} ${S.of('measure.z100_sec')}',
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final r in session.runs.reversed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    '${_fmtTs(r.tsMs)} — ${r.seconds.toStringAsFixed(1)} ${S.of('measure.z100_sec')}',
                    style: TextStyle(
                        fontSize: 13,
                        color: r.seconds == best
                            ? Colors.tealAccent.shade400
                            : Colors.white.withOpacity(0.7)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtTs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

// ───────────────────── archived session detail ─────────────────────

class _ArchivedDetailScreen extends StatelessWidget {
  final ArchivedSession entry;
  const _ArchivedDetailScreen({required this.entry});

  @override
  Widget build(BuildContext context) {
    final s = entry.session;
    return Scaffold(
      appBar: AppBar(title: Text(entry.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (entry.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(entry.note,
                  style:
                      TextStyle(color: Colors.white.withOpacity(0.6))),
            ),
          if (s.tempMeanC != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _tempPassport(s),
                style: TextStyle(
                    fontSize: 13, color: Colors.white.withOpacity(0.6)),
              ),
            ),
          _BandBarCard(session: s),
          const SizedBox(height: 12),
          _BandTableCard(session: s),
          const SizedBox(height: 12),
          _ZeroTo100Card(session: s),
        ],
      ),
    );
  }

  String _tempPassport(SpeedProfileSession s) {
    final min = s.tempMinC?.round();
    final mean = s.tempMeanC?.round();
    final max = s.tempMaxC?.round();
    final cold =
        s.coldPack ? ' · ${S.of('measure.cold_pack')}' : '';
    return '${S.of('measure.temp_passport')}: $min° / $mean° / $max°$cold';
  }
}

// ──────────────────── U3: A/B comparison screen ────────────────────

class _CompareScreen extends StatelessWidget {
  final ArchivedSession a;
  final ArchivedSession b;
  const _CompareScreen({required this.a, required this.b});

  static const Color _colA = Colors.tealAccent;
  static const Color _colB = Colors.orangeAccent;

  @override
  Widget build(BuildContext context) {
    final bandsUnion = <int>{
      ...a.session.visibleBands,
      ...b.session.visibleBands,
    }.toList()
      ..sort();
    return Scaffold(
      appBar: AppBar(title: Text(S.of('measure.compare_title'))),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _header(),
          const SizedBox(height: 12),
          if (bandsUnion.length >= 2)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(
                    height: 180, child: _groupedChart(bandsUnion)),
              ),
            ),
          const SizedBox(height: 12),
          _deltaTable(bandsUnion),
        ],
      ),
    );
  }

  /// «А: 28° · Б: −2°» — both temperature passports up top (U4): the
  /// comparison is what the archive exists for, and the pack temps are
  /// the context that explains the deltas.
  Widget _header() {
    String line(String label, ArchivedSession e, Color c) {
      final t = e.session.tempMeanC;
      final temp = t == null ? '' : ' · ${t.round()}°';
      final cold = e.session.coldPack
          ? ' · ${S.of('measure.cold_pack')}'
          : '';
      return '$label: ${e.name}$temp$cold';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line('А', a, _colA),
            style: const TextStyle(fontSize: 14, color: _colA)),
        const SizedBox(height: 2),
        Text(line('Б', b, _colB),
            style: const TextStyle(fontSize: 14, color: _colB)),
      ],
    );
  }

  Widget _groupedChart(List<int> bands) {
    double maxV = 0;
    for (final band in bands) {
      final ca = a.session.bands[band]?.consumptionKwh100 ?? 0;
      final cb = b.session.bands[band]?.consumptionKwh100 ?? 0;
      if (ca > maxV) maxV = ca;
      if (cb > maxV) maxV = cb;
    }
    return BarChart(
      BarChartData(
        maxY: maxV * 1.15 + 0.1,
        barTouchData: BarTouchData(enabled: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 26,
              interval: 1,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (v != i.toDouble() || i < 0 || i >= bands.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${bands[i]}',
                      style: const TextStyle(fontSize: 11)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < bands.length; i++)
            BarChartGroupData(x: i, barsSpace: 2, barRods: [
              BarChartRodData(
                toY: a.session.bands[bands[i]]?.consumptionKwh100 ?? 0,
                width: 8,
                color: _colA,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(2)),
              ),
              BarChartRodData(
                toY: b.session.bands[bands[i]]?.consumptionKwh100 ?? 0,
                width: 8,
                color: _colB,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(2)),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _deltaTable(List<int> bands) {
    String fmt(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(children: [
              SizedBox(
                  width: 52,
                  child: Text(S.of('measure.band'),
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600))),
              const Expanded(
                  child: Text('А',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _colA))),
              const Expanded(
                  child: Text('Б',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _colB))),
              Expanded(
                  child: Text('Δ',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600))),
            ]),
            const Divider(height: 12),
            for (final band in bands)
              Builder(builder: (_) {
                final ca = a.session.bands[band]?.consumptionKwh100;
                final cb = b.session.bands[band]?.consumptionKwh100;
                final d = (ca != null && cb != null) ? cb - ca : null;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(
                        width: 52,
                        child: Text('$band',
                            style: const TextStyle(fontSize: 14))),
                    Expanded(
                        child: Text(fmt(ca),
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 14))),
                    Expanded(
                        child: Text(fmt(cb),
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 14))),
                    Expanded(
                        child: Text(
                            d == null
                                ? '—'
                                : '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}',
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 14))),
                  ]),
                );
              }),
          ],
        ),
      ),
    );
  }
}
