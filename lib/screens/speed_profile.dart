// v0.1.64+163 «Замеры по контракту, заход A» — the «Замеры» screen
// rebuilt to canon 1.2 §7.1 / §7.4 (mockups 2a/2b/2d · 3a/3b/3d).
//
// What left with +163 (решения владельца, окно 26.07): the Старт /
// Стоп / Сброс buttons, the session archive with A/B comparison, the
// diag dump (now Настройки → Расширенное) and the tick-diag row.
// Recording runs always; the status chip §6.2 is the only state
// indicator.
//
// DATA SOURCE: band cards and the chart read the ATLAS LEDGER — the
// number on a card is the number that will land in the atlas. The
// session overlay survives underneath for 0–100, the temp passport,
// totalDistKm and diag only; it never reaches this screen anymore
// («Полоса 60» meant four different numbers at once — разбор 26.07 §1).
// The card set is anchored to the DISPLAY window (latched on
// standstill): bands with an atlas measurement there plus bands
// accumulating live — stable in motion (И1).

import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/atlas_projection.dart';
import '../data/database.dart';
import '../l10n/strings.dart';
import '../services/cloud_sync_service.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import '../widgets/atlas_grid.dart'
    show AtlasGhostCell, atlasCountsLabel, atlasMonthNames;
import '../widgets/band_card.dart';
import '../widgets/responsive.dart';
import 'atlas.dart';
import 'settings.dart' show CloudServicesScreen;
import 'wide/atlas_wide.dart';

class SpeedProfileScreen extends StatefulWidget {
  const SpeedProfileScreen({super.key});

  @override
  State<SpeedProfileScreen> createState() => _SpeedProfileScreenState();
}

class _SpeedProfileScreenState extends State<SpeedProfileScreen> {
  // ── +160 (§2.1): parking summary card — P + speed 0 held 5 s ──
  // The hold timer lives in SCREEN state (per spec); any movement or
  // gear change resets it AND hides the card — the condition is live,
  // not a latch. Discreteness is allowed: the card only ever appears
  // under P (стоянка = дискретность разрешена), никаких анимаций.
  static const int _kParkHoldMs = 5000;
  Timer? _parkPoll;
  int? _parkSinceMs;
  bool _cardVisible = false;
  bool _loadingReveals = false;
  List<AtlasRevealRow>? _cardReveals;

  /// v0.1.62+161 → +163: the parked flag now gates the summary card,
  /// the intention card and the status chip's P slot.
  bool _isParked = false;

  // ── +163: ONE grid read for the whole screen ──
  // Band cards (atlas line), the intention phrasing (new cell vs
  // refine) and the atlas entry card all read the same
  // AtlasGridData, re-read on the atlas revision (the +162
  // IndexedStack fix, precedent of the old entry-card loader).
  Future<AtlasGridData>? _gridFuture;
  int _loadedRevision = -1;

  @override
  void initState() {
    super.initState();
    _load();
    _parkPoll = Timer.periodic(const Duration(seconds: 1), (_) {
      _pollPark();
    });
  }

  void _load() {
    final db = context.read<ConnectionService>().db;
    final sp = context.read<SpeedProfileService>();
    _loadedRevision = sp.atlasRevision;
    _gridFuture = db
        .getAtlasSnapshotsForGrid(maxBand: kAtlasBandMaxKmh)
        .then((rows) => AtlasGridData.fromRows(rows,
            // +164 (BC7b): rows of the RUNNING session are provisional
            // chunks — §6.13 paints them, the grid must not count them.
            activeSessionUid: sp.atlasSessionUid));
  }

  @override
  void dispose() {
    _parkPoll?.cancel();
    super.dispose();
  }

  void _pollPark() {
    if (!mounted) return;
    final hal = context.read<HalTelemetryService>();
    final conn = context.read<ConnectionService>();
    final sp = context.read<SpeedProfileService>();
    // P detection — the isParked precedent (the same gear resolution
    // the «Автомобиль» rail badge uses). No valid gear → no card at
    // all (дизайн-контракт §78: уходит на телефон, №3).
    final gear = hal.useHalForGear
        ? hal.halGear
        : conn.readNumeric('791', '0009');
    final isParked = gear != null && gear.toInt() == 1;
    // +161: the atlas entry follows the gear alone (no 5 s hold — it is
    // not a reveal, just a door), so it is latched here, before the
    // card's own early-outs.
    if (_isParked != isParked) {
      setState(() => _isParked = isParked);
    }
    // speed 0 — the on-change stream's last value; deceleration always
    // emits the terminal 0, so «стоит» is a real datum, not staleness.
    // +163 (разбор §5, «тупик плашка → пустой экран»): under a valid P
    // a NULL speed counts as standing — on a cold start at a kerb no
    // speed event has arrived yet, but the car physically cannot move
    // in P; the old null→false read left the plate glowing over a
    // card that could never appear.
    final v = hal.halSpeedKmh;
    final still = v == null || v < 0.5;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!(isParked && still)) {
      _parkSinceMs = null;
      if (_cardVisible) {
        setState(() {
          _cardVisible = false;
          _cardReveals = null;
        });
      }
      return;
    }
    _parkSinceMs ??= now;
    final held = now - _parkSinceMs! >= _kParkHoldMs;
    // §2.1 (принятое условие, вето Alex одним словом сводит к «только
    // unrevealedCount > 0»): невскрытые события ИЛИ прирост с
    // последнего «Ок» — микро-лут заслуживает карточку и без событий.
    final hasContent = sp.unrevealedCount > 0 || sp.atlasHasUnseenGain;
    if (held && hasContent && !_cardVisible && !_loadingReveals) {
      _loadingReveals = true;
      sp.unrevealedReveals().then((rows) {
        if (!mounted) return;
        _loadingReveals = false;
        setState(() {
          _cardReveals = rows;
          _cardVisible = true;
        });
      });
    } else if (_cardVisible && !hasContent) {
      setState(() {
        _cardVisible = false;
        _cardReveals = null;
      });
    }
  }

  Future<void> _onOkReveals(SpeedProfileService sp) async {
    await sp.acknowledgeReveals();
    if (!mounted) return;
    setState(() {
      _cardVisible = false;
      _cardReveals = null;
    });
  }

  // ── +163 UX: stable order in motion ──
  // The §2.4 sort rule (matured by band desc, maturing by accumulated
  // time desc) is applied only when the SET SIGNATURE changes — a band
  // appearing, or a stage flip. Plain timeS growth must not reshuffle
  // the list mid-drive: driving between two bands would swap their
  // cards every few seconds (И1 in spirit — nothing jumps in motion).
  List<int> _order = const [];
  String _orderSig = '';

  /// The card set + per-band models (решение 26.07 п.4, суженный
  /// вариант): bands with an atlas measurement in the DISPLAY window ∪
  /// bands with a live ledger cell. Stage and progress come from the
  /// band's deepest live cell; the atlas line from the grid.
  List<BandCardModel> _bandModels(
      SpeedProfileService svc, AtlasGridData? data) {
    final dw = svc.atlasDisplayWindow;
    final live = {for (final r in svc.atlasLiveBands()) r.band: r};
    final atlas = <int, AtlasCellStat>{};
    if (data != null) {
      for (final c in data.cells) {
        if (c.window == dw) atlas[c.band] = c;
      }
    }
    final bands = <int>{...live.keys, ...atlas.keys};
    final models = <BandCardModel>[
      for (final b in bands)
        BandCardModel(
          band: b,
          timeS: live[b]?.timeS ?? 0,
          // v0.1.98+197: подпись берёт АКТИВНОЕ окно — то самое, чью
          // клетку считает полоска. Набор карточек по-прежнему привязан
          // к display-окну (`dw` выше) и в движении не меняется, И1 цел.
          //
          // ОСТАТОЧНОЕ РАСХОЖДЕНИЕ, названное вслух при ревизии.
          // Строка «в атласе N за M поездок» читает display-окно, а
          // подпись с градусами — активное. Между сменой окна на ходу и
          // ближайшей остановкой они показывают РАЗНЫЕ окна: полоска и
          // градусы уже про новое, атлас ещё про старое.
          //
          // Не лечим сознательно. Перевести строку атласа на активное
          // окно значит менять состав карточек в движении, а это прямое
          // нарушение И1 («ничто не появляется и не исчезает на ходу»),
          // ради которого display-окно и заводили. Из двух зол выбрано
          // меньшее: расхождение живёт минуты и само сходится на первой
          // остановке, а мигающий набор карточек — постоянная беда.
          tempWindow: svc.atlasActiveWindow,
          kwh100: live[b]?.kwh100,
          atlasMean: atlas[b]?.mean,
          atlasDrives: atlas[b]?.sessions ?? 0,
        ),
    ];
    final sig = (models.toList()
          ..sort((a, b) => a.band.compareTo(b.band)))
        .map((m) => '${m.band}:${m.matured ? 1 : 0}')
        .join(',');
    if (sig != _orderSig) {
      models.sort((a, b) {
        if (a.matured != b.matured) return a.matured ? -1 : 1;
        if (a.matured) return b.band.compareTo(a.band);
        return b.timeS.compareTo(a.timeS);
      });
      _order = [for (final m in models) m.band];
      _orderSig = sig;
      return models;
    }
    models.sort((a, b) =>
        _order.indexOf(a.band).compareTo(_order.indexOf(b.band)));
    return models;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<LocaleService>();
    final svc = context.watch<SpeedProfileService>();
    if (svc.atlasRevision != _loadedRevision) {
      _load();
    }
    final bz3 = LayoutBreakpoints.useTallHeadUnit(context);

    return FutureBuilder<AtlasGridData>(
      future: _gridFuture,
      builder: (context, snap) {
        final data = snap.data;
        final models = _bandModels(svc, data);
        // +164 [2d/3d]: the first-entry screen. Criterion is the FIRST
        // CARD OF ANY STAGE, not the first matured one — a live cell is
        // born after kBandDwellS seconds in a band, long before 120 s,
        // and the literal reading of the spec would have hidden a card
        // the empty state had just promised. This is also what +163
        // already did (`models.isEmpty`); the wording changed, the
        // criterion did not.
        final firstEntry = models.isEmpty;

        // ── left column / portrait ribbon: the measurement itself ──
        final measurement = <Widget>[
          // +160 (§2.2): карточка итогов — сверху колонки полос, НЕ
          // оверлей. Появление на стоянке — обычный build по условию.
          if (_cardVisible && _cardReveals != null) ...[
            _RevealCard(
              svc: svc,
              reveals: _cardReveals!,
              onOk: () => _onOkReveals(svc),
            ),
            SizedBox(height: bz3 ? 16 : 20),
          ],
          // +162 (§6.10, макет [5c]) → +163 (решение 26.07 п.6):
          // намерение сформулировано через управляемое; переживает
          // «Ок», в движении не существует.
          _IntentCard(isParked: _isParked, bz3: bz3, grid: data),
          if (firstEntry)
            BandEmptyState(bz3: bz3)
          else
            for (final m in models) ...[
              // Keyed by band: when the order does change (stage flip /
              // standstill), Flutter moves the element instead of
              // rebuilding it — the crossfade state survives.
              BandCard(key: ValueKey('band_${m.band}'), model: m, bz3: bz3),
              SizedBox(height: bz3 ? 8 : 10),
            ],
        ];

        // The three cards that are NOT the measurement itself. They are
        // ordered differently per form factor, so build them once and
        // let each branch arrange them.
        final atlasEntry =
            _AtlasEntryCard(data: data, bz3: bz3, firstEntry: firstEntry);
        final syncCard = _SyncCard(bz3: bz3);
        final zeroTo100 =
            _ZeroTo100Card(session: svc.session, bz3: bz3,
                firstEntry: firstEntry);

        // ── BZ5 right column: atlas → 0–100 → sync ──
        // Owner's decision 27.07 (+165), superseding the 26.07 order:
        // the sync card is the only one of the three that comes and
        // goes with parking, so it belongs LAST — a card that appears
        // in the middle pushes the 0–100 block down under the driver.
        // The order is otherwise the SAME in every state.
        final aside = <Widget>[
          // +161 (§7.1): the door into the atlas — открыт всегда.
          atlasEntry,
          const SizedBox(height: 12),
          zeroTo100,
          if (_isParked) ...[
            const SizedBox(height: 12),
            syncCard,
          ],
        ];

        // ── BZ3 ribbon tail: 0–100 → atlas → sync ──
        // «Атлас сверху» is a statement about the BZ5 RIGHT COLUMN
        // (owner, 26.07) and is deliberately not applied here. Canon
        // §7.4 keeps 0–100 with the band cards — in a single portrait
        // ribbon it is part of the measurement, not a side door — and
        // the sync card sits after the atlas entry.
        final ribbonTail = <Widget>[
          zeroTo100,
          const SizedBox(height: 16),
          atlasEntry,
          const SizedBox(height: 16),
          if (_isParked) ...[
            syncCard,
            const SizedBox(height: 16),
          ],
        ];

        // Honest platform limitation, spelled out (spec §5): a sleeping
        // head unit measures nothing — same physics as the AC night.
        final sleepNote = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            S.of('measure.sleep_note'),
            style:
                TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4)),
          ),
        );

        // The chart lives at the BOTTOM of the left column on BZ5 (gap
        // 20) and as the LAST card of the ribbon on BZ3 (gap 16).
        final chart = _BandBarCard(data: data, bz3: bz3);

        if (bz3) {
          // BZ3 gets no columns — one portrait ribbon, canon §7.4.
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            children: [
              _ScreenHeader(isParked: _isParked, bz3: true),
              const SizedBox(height: 16),
              ...measurement,
              ...ribbonTail,
              chart,
              const SizedBox(height: 12),
              sleepNote,
              const SizedBox(height: 24),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(44, 28, 44, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ScreenHeader(isParked: _isParked, bz3: false),
              const SizedBox(height: 24),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column is FLEXIBLE. The mockup calls it
                    // «flex 1.5», but a lone Flexible in a Row has no
                    // one to weigh against — the number would be a dead
                    // literal. Expanded is the honest expression of
                    // «everything the fixed column leaves».
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          ...measurement,
                          const SizedBox(height: 20),
                          chart,
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    SizedBox(
                      width: 560,
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          ...aside,
                          const SizedBox(height: 16),
                          sleepNote,
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────── screen header: title + status chip §6.2 ─────────────────

class _ScreenHeader extends StatelessWidget {
  final bool isParked;
  final bool bz3;
  const _ScreenHeader({required this.isParked, required this.bz3});

  @override
  Widget build(BuildContext context) {
    final title = Text(
      bz3 ? S.of('nav.measure') : S.of('nav.measure').toUpperCase(),
      style: TextStyle(
        fontSize: bz3 ? 30 : 34,
        fontWeight: FontWeight.w500,
        letterSpacing: bz3 ? 0 : 2,
        color: AtlasTokens.t85,
      ),
    );
    return Row(
      children: [
        title,
        SizedBox(width: bz3 ? 16 : 28),
        if (bz3) const Spacer(),
        _StatusChip(isParked: isParked, bz3: bz3),
        if (!bz3) const Spacer(),
      ],
    );
  }
}

/// Status chip §6.2 — the ONLY recording indicator now. Two slots, the
/// content swaps, nothing appears or disappears (И1): in motion a
/// 10 dp `rec` dot + «Запись, {v} км/ч» + the «ровное время идёт»
/// tail; parked a `gearP` 700 «P» + «Стоянка, ровное время не идёт»
/// (решение владельца 26.07 п.7 — «запись остановлена» died with the
/// Стоп button it described).
class _StatusChip extends StatelessWidget {
  final bool isParked;
  final bool bz3;
  const _StatusChip({required this.isParked, required this.bz3});

  @override
  Widget build(BuildContext context) {
    final v = context.read<HalTelemetryService>().halSpeedKmh;
    final dotSize = bz3 ? 8.0 : 10.0;
    final mainSize = bz3 ? 12.0 : 13.0;
    final Widget lead;
    final Widget label;
    if (isParked) {
      lead = Text('P',
          style: TextStyle(
              fontSize: bz3 ? 13 : 16,
              fontWeight: FontWeight.w700,
              color: AtlasTokens.gearP));
      label = Text(S.of('measure.chip_parked'),
          style: TextStyle(
              fontSize: mainSize,
              color: bz3 ? const Color(0xCCFFFFFF) : AtlasTokens.t60));
    } else {
      lead = Container(
        width: dotSize,
        height: dotSize,
        decoration: const BoxDecoration(
            color: AtlasTokens.rec, shape: BoxShape.circle),
      );
      final rec = v == null
          ? S.of('measure.chip_rec_nv')
          : S.of('measure.chip_rec').replaceFirst('{v}', '${v.round()}');
      label = Text.rich(TextSpan(children: [
        TextSpan(
            text: rec,
            style: TextStyle(
                fontSize: mainSize,
                color:
                    bz3 ? const Color(0xCCFFFFFF) : AtlasTokens.t85)),
        if (!bz3)
          TextSpan(
              text: ', ${S.of('measure.chip_rec_tail')}',
              style: TextStyle(
                  fontSize: mainSize, color: AtlasTokens.t40)),
      ]));
    }
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(999),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(vertical: 5, horizontal: 12)
          : const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          lead,
          SizedBox(width: bz3 ? 6 : 8),
          label,
        ],
      ),
    );
  }
}

// ──────────────────── band bar chart (остаётся навсегда) ────────────────────

/// Bar chart of kWh/100km per matured band — the second projection of
/// the same ledger data the cards render (canon §0.1: карточки про
/// сессию, график про форму кривой). Survival rules of the Trends
/// _BarCard on the BZ5 head unit hold: NO BarTouchData whatsoever
/// (the +45 fl_chart 0.68 release-mode white card), text fallback
/// below 3 bands (rectangles without a shape to read are not a chart).
/// Consumption per speed band — the second projection of the atlas
/// (canon §0.1: «карточки про сессию, график про кривую»).
///
/// +164 [6d/6f/6g] — this is a REBUILD, not a move:
///   * source is the ATLAS GRID, not the live session. The subtitle
///     says «все поездки» and §7.1 asks for the shape of the whole
///     curve, which a single drive cannot draw;
///   * all eleven bands 40…140 are always present. A band with no
///     steady time is a grey stub, so the curve keeps its shape from
///     the very first cell and the <3-band text fallback is gone;
///   * the most economical EARNED band is highlighted — under a
///     `> 0.5` guard, because a regen-heavy descent can legitimately
///     hold kwh100 at or below zero and would otherwise win «самая
///     экономичная» forever. Same trap the canon already caught in the
///     «лучшая клетка» rule for the export.
///
/// Outer width is deliberately NOT pinned. The mockup's 1539 dp were
/// measured from the full 2175 dp panel, but `head_unit_scaffold`
/// spends 80 dp on the NavigationRail plus a 1 dp divider, so the real
/// content area is 2094 and the left column lands near 1422. The card
/// fills whatever the flexible left column gives it; only the internal
/// geometry is literal.
class _BandBarCard extends StatelessWidget {
  final AtlasGridData? data;
  final bool bz3;
  const _BandBarCard({required this.data, required this.bz3});

  /// Steady-weighted mean per band across ALL temperature windows —
  /// the same weighting `AtlasCellStat.mean` uses inside one cell, so
  /// the curve and the grid never disagree.
  Map<int, double> _byBand() {
    final num = <int, double>{};
    final den = <int, double>{};
    for (final c in data?.cells ?? const <AtlasCellStat>[]) {
      final w = c.steadySeconds;
      if (w <= 0) continue;
      num[c.band] = (num[c.band] ?? 0) + c.mean * w;
      den[c.band] = (den[c.band] ?? 0) + w;
    }
    return {
      for (final b in num.keys)
        if ((den[b] ?? 0) > 0) b: num[b]! / den[b]!,
    };
  }

  @override
  Widget build(BuildContext context) {
    final earned = _byBand();
    final bands = <int>[
      for (var b = kAtlasBandMinKmh;
          b <= kAtlasBandMaxKmh;
          b += kAtlasBandStepKmh)
        b
    ];

    // Highlight guard: minimum among cells above 0.5 kWh/100km only.
    int? bestBand;
    var best = double.infinity;
    earned.forEach((b, v) {
      if (v > 0.5 && v < best) {
        best = v;
        bestBand = b;
      }
    });

    final vals = earned.values.toList();
    final maxV = vals.isEmpty
        ? 1.0
        : vals.reduce((a, b) => a > b ? a : b);
    final minV = vals.isEmpty ? 0.0 : vals.reduce((a, b) => a < b ? a : b);
    final top = maxV * 1.15 + 0.1;
    final bottom = minV < 0 ? minV * 1.15 - 0.1 : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: bz3
          ? const EdgeInsets.all(12)
          : const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of('measure.chart_title'),
              style: TextStyle(
                  fontSize: bz3 ? 16 : 18,
                  fontWeight: FontWeight.w500,
                  color: AtlasTokens.t85)),
          SizedBox(height: bz3 ? 4 : 6),
          Text(S.of('measure.chart_sub'),
              style: TextStyle(
                  fontSize: bz3 ? 11 : 12, color: AtlasTokens.t40)),
          SizedBox(height: bz3 ? 12 : 14),
          SizedBox(
            height: bz3 ? 140 : 180,
            child: _chart(bands, earned, bestBand, top, bottom),
          ),
          SizedBox(height: bz3 ? 12 : 14),
          Text(
              // BZ3 drops the second sentence: at 668 dp it pushed the
              // card into an extra line for no new information.
              S.of(bz3 ? 'measure.chart_note_short' : 'measure.chart_note'),
              style: TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: AtlasTokens.t40)),
        ],
      ),
    );
  }

  Widget _chart(List<int> bands, Map<int, double> earned, int? bestBand,
      double top, double bottom) {
    // Three Y labels computed from the data range — never literals, or
    // a winter atlas would draw off the top of the card.
    final ticks = <double>[
      bottom,
      bottom + (top - bottom) / 2,
      top,
    ];
    return BarChart(
      BarChartData(
        maxY: top,
        minY: bottom,
        // The +45 head-unit survival rule: touch stays off.
        barTouchData: BarTouchData(enabled: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(
                color: AtlasTokens.line, width: bz3 ? 1.5 : 2),
            bottom: BorderSide(
                color: AtlasTokens.line, width: bz3 ? 1.5 : 2),
          ),
        ),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: bz3 ? 24 : 30,
              interval: (top - bottom) / 2,
              getTitlesWidget: (v, meta) {
                final shown =
                    ticks.any((t) => (t - v).abs() < (top - bottom) / 200);
                if (!shown) return const SizedBox.shrink();
                return Padding(
                  padding: EdgeInsets.only(right: bz3 ? 8 : 10),
                  child: Text(v.toStringAsFixed(0),
                      style: TextStyle(
                          fontSize: bz3 ? 10 : 11,
                          color: AtlasTokens.t35,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ])),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: bz3 ? 18 : 22,
              interval: 1,
              getTitlesWidget: (v, meta) {
                final i = v.toInt();
                if (v != i.toDouble() || i < 0 || i >= bands.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${bands[i]}',
                      style: TextStyle(
                          fontSize: bz3 ? 10 : 11,
                          color: AtlasTokens.t35,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ])),
                );
              },
            ),
          ),
        ),
        // Index-based x (the Trends _BarCard pattern) — band values as x
        // would make fl_chart interpolate ticks between the bars.
        barGroups: [
          for (var i = 0; i < bands.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                // A band with nothing collected still draws — a stub at
                // the axis, so the curve keeps its shape.
                toY: earned[bands[i]] ?? top * 0.06,
                width: bz3 ? 8 : 10,
                color: earned[bands[i]] == null
                    ? AtlasTokens.chartBarIdle
                    : (bands[i] == bestBand
                        ? AtlasTokens.progress
                        : AtlasTokens.chartBarEarned),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
              ),
            ]),
        ],
      ),
    );
  }
}

// ─────────────────────────── 0–100 block §6.6 ───────────────────────────

/// Utility card, mockup 2a numbers. Collapses into ONE line while there
/// are no runs (решение владельца 26.07 п.14) — the field showed the
/// full block advertising an empty list forever (runs: [] после 32 км:
/// city driving structurally cannot produce a clean 0→real-100).
class _ZeroTo100Card extends StatelessWidget {
  final SpeedProfileSession? session;
  final bool bz3;

  /// +164 [2d/3d]: on the first-entry screen this card is the ONLY
  /// action on the whole screen, so it explains itself in full instead
  /// of the one-word readiness line.
  final bool firstEntry;
  const _ZeroTo100Card(
      {required this.session, required this.bz3, this.firstEntry = false});

  /// «11 июл» — the 2a mockup form. Locale-aware short months from the
  /// ONE l10n key the atlas year row already uses (a private RU-only
  /// list here would show Russian months on the EN locale).
  String _fmtDay(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${atlasMonthNames()[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final runs = session?.runs ?? const <ZeroTo100Run>[];
    final titleRow = <Widget>[
      Icon(Icons.timer_outlined,
          size: bz3 ? 18 : 22, color: AtlasTokens.info),
      SizedBox(width: bz3 ? 8 : 10),
      Text(S.of('measure.z100_title'),
          style: TextStyle(
              fontSize: bz3 ? 14 : 16,
              fontWeight: FontWeight.w500,
              color: bz3 ? const Color(0xB3FFFFFF) : AtlasTokens.t85)),
    ];
    final Widget content;
    if (runs.isEmpty && firstEntry) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: titleRow),
          SizedBox(height: bz3 ? 8 : 10),
          Text(S.of('measure.empty_z100'),
              style: TextStyle(
                  fontSize: bz3 ? 11 : 12,
                  height: 1.4,
                  color: AtlasTokens.t50)),
        ],
      );
    } else if (runs.isEmpty) {
      // +165 (§2.4): the readiness line moved UNDER the title. It used
      // to sit in the same Row behind a Spacer, and Spacer(flex 1) +
      // Flexible(flex 1) split the free space in half — on the head
      // unit the sentence got half the remainder and wrapped into a
      // four-line column pinned to the right edge. Second line, like
      // every other card in this column.
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: titleRow),
          SizedBox(height: bz3 ? 6 : 8),
          Text(S.of('measure.z100_ready'),
              style: TextStyle(
                  fontSize: bz3 ? 11 : 12, color: AtlasTokens.t50)),
        ],
      );
    } else {
      final best = session!.bestZeroTo100!;
      final last = runs.last;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: titleRow),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(best.toStringAsFixed(1),
                  style: TextStyle(
                      fontSize: bz3 ? 24 : 32,
                      fontWeight: FontWeight.w700,
                      color: AtlasTokens.t100,
                      fontFeatures: const [
                        FontFeature.tabularFigures()
                      ])),
              SizedBox(width: bz3 ? 6 : 8),
              Text(S.of('measure.z100_sec'),
                  style: TextStyle(
                      fontSize: bz3 ? 13 : 16, color: AtlasTokens.t50)),
              const Spacer(),
              Text('${S.of('measure.z100_last')}, ${_fmtDay(last.tsMs)}',
                  style: TextStyle(
                      fontSize: bz3 ? 11 : 12, color: AtlasTokens.t40)),
            ],
          ),
          SizedBox(height: bz3 ? 6 : 8),
          Text(S.of('measure.z100_ready'),
              style: TextStyle(
                  fontSize: bz3 ? 11 : 12, color: AtlasTokens.t50)),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: bz3 ? AtlasTokens.cardMuted : AtlasTokens.card,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: bz3
          ? const EdgeInsets.all(12)
          : const EdgeInsets.all(14),
      child: content,
    );
  }
}

// ─────────────── intention card §6.10 (решение 26.07 п.6) ───────────────

/// The goal, phrased through the controllable: «Подержи 50 км/ч ещё
/// полторы минуты». The temperature is context in the caption, never a
/// condition («на погоду я влиять не могу» — замечание владельца
/// 26.07); the candidate is already pinned to the ACTIVE window, so
/// the advice is reachable today by construction. Opening a new cell
/// and refining an existing one are different rewards — the card says
/// which one this drive buys.
class _IntentCard extends StatelessWidget {
  final bool isParked;
  final bool bz3;
  final AtlasGridData? grid;
  const _IntentCard(
      {required this.isParked, required this.bz3, required this.grid});

  /// Coarse humanised remainder — deliberately not a countdown («ещё
  /// 24 с» would be a counter; «ещё минуту» is advice).
  static String _holdPhrase(double remainS) {
    if (remainS <= 40) return S.of('measure.t_half');
    if (remainS <= 75) return S.of('measure.t_one');
    if (remainS <= 105) return S.of('measure.t_onehalf');
    return S.of('measure.t_two');
  }

  @override
  Widget build(BuildContext context) {
    if (!isParked) return const SizedBox.shrink();
    final sp = context.watch<SpeedProfileService>();
    final taken = sp.atlasIntent;
    final k = bz3 ? 0.88 : 1.0;

    if (taken != null) {
      // Взятое состояние — приглушённая полоска [5c], без кнопок.
      return Padding(
        padding: EdgeInsets.only(top: 12 * k),
        child: Container(
          decoration: BoxDecoration(
            color: AtlasTokens.cardMuted,
            borderRadius: BorderRadius.circular(12 * k),
          ),
          padding: EdgeInsets.symmetric(
              horizontal: 18 * k, vertical: 14 * k),
          child: Row(
            children: [
              Icon(Icons.flag, size: 18 * k, color: AtlasTokens.t35),
              SizedBox(width: 12 * k),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S
                          .of('measure.intent_taken')
                          .replaceFirst('{v}', '${taken.band}')
                          .replaceFirst('{w}', _windowWord(taken.window)),
                      style: TextStyle(
                          fontSize: 13 * k, color: AtlasTokens.t85),
                    ),
                    Text(S.of('measure.intent_taken_note'),
                        style: TextStyle(
                            fontSize: 11 * k, color: AtlasTokens.t40)),
                  ],
                ),
              ),
              TextButton(
                onPressed: sp.clearAtlasIntent,
                child: Text(S.of('measure.intent_drop'),
                    style: TextStyle(
                        fontSize: 12 * k, color: AtlasTokens.t50)),
              ),
            ],
          ),
        ),
      );
    }

    final cand = sp.atlasIntentCandidate();
    if (cand == null) return const SizedBox.shrink();

    // What this drive buys: a NEW cell (no measurement in the atlas for
    // this band × window yet) or a REFINED one. The grid answers.
    final isNew =
        grid?.byKey[atlasCellKey(cand.band, cand.window)] == null;
    final remain =
        kBandMinSeconds - sp.atlasCellTimeS(cand.band, cand.window);
    final t = sp.currentPackTempC;

    return Padding(
      padding: EdgeInsets.only(top: 12 * k),
      child: Container(
        decoration: BoxDecoration(
          color: AtlasTokens.card,
          borderRadius: BorderRadius.circular(12 * k),
        ),
        padding: EdgeInsets.all(14 * k),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag, size: 20 * k, color: AtlasTokens.info),
                SizedBox(width: 10 * k),
                Text(S.of('measure.intent_title'),
                    style: TextStyle(
                        fontSize: 14 * k,
                        fontWeight: FontWeight.w500,
                        color: AtlasTokens.t100)),
              ],
            ),
            SizedBox(height: 12 * k),
            Text(
              S
                  .of('measure.intent_hold')
                  .replaceFirst('{v}', '${cand.band}')
                  .replaceFirst(
                      '{t}', _holdPhrase(remain.clamp(0.0, 999.0).toDouble())),
              style: TextStyle(
                  fontSize: 17 * k,
                  fontWeight: FontWeight.w700,
                  color: AtlasTokens.t100,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            SizedBox(height: 8 * k),
            Text(
                isNew
                    ? S.of('measure.intent_new')
                    : S.of('measure.intent_refine'),
                style: TextStyle(
                    fontSize: 12 * k, color: AtlasTokens.t50)),
            if (t != null)
              Padding(
                padding: EdgeInsets.only(top: 4 * k),
                child: Text(
                    S
                        .of('measure.intent_ctx')
                        .replaceFirst('{t}', '${t.round()}'),
                    style: TextStyle(
                        fontSize: 12 * k, color: AtlasTokens.t40)),
              ),
            SizedBox(height: 14 * k),
            Row(
              children: [
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AtlasTokens.progress,
                    foregroundColor: AtlasTokens.onProgress,
                    shape: const StadiumBorder(),
                    padding: EdgeInsets.symmetric(
                        horizontal: 20 * k, vertical: 9 * k),
                  ),
                  onPressed: () =>
                      sp.takeAtlasIntent(cand.band, cand.window),
                  child: Text(S.of('measure.intent_take'),
                      style: TextStyle(
                          fontSize: 13 * k, fontWeight: FontWeight.w500)),
                ),
                SizedBox(width: 8 * k),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0x2EFFFFFF)),
                    foregroundColor: AtlasTokens.t60,
                    shape: const StadiumBorder(),
                    padding: EdgeInsets.symmetric(
                        horizontal: 20 * k, vertical: 9 * k),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          const AtlasScreen(selectGhostMode: true),
                    ),
                  ),
                  child: Text(S.of('measure.intent_other'),
                      style: TextStyle(fontSize: 13 * k)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _windowWord(int? w) => w == null
      ? S.of('atlas.window_unknown')
      : '${atlasWindowLabel(w)}°';
}

// ─────────────────────── atlas entry card §7.1 ───────────────────────

/// v0.1.62+161 → +163 → +165 — entry into the atlas from the «Замеры»
/// screen. One line: grid_view 22 `info`, «Атлас: {n} клеток,
/// {m} скоростей» 16, chevron 20 t40. The 2a mockup's 30/24/28 were
/// drawn on a canvas that assumed a 150 px rail; +165 put the card on
/// the app's own ladder, and «просмотр» left the counter (it names
/// the atlas SCREEN's mode, not the count — atlas.view_only says it
/// where it belongs). Открыт всегда (канон 1.2 §0.1 — блокировка в
/// движении отменена); the grid data arrives from the screen's
/// shared loader.
class _AtlasEntryCard extends StatelessWidget {
  final AtlasGridData? data;
  final bool bz3;

  /// +164 [2d/3d]: «куда копится» — четыре пустые клетки и одна фраза
  /// вместо счётчика, которого ещё не существует.
  final bool firstEntry;
  const _AtlasEntryCard(
      {required this.data, required this.bz3, this.firstEntry = false});

  @override
  Widget build(BuildContext context) {
    final counts = data == null
        ? '—'
        : atlasCountsLabel(data!.cellCount, data!.bandCount, view: true);
    // +162: открыт всегда. Блокировка в движении убрана по полевому
    // вердикту 25.07 — карта не несёт живой информации, но заглушка
    // «доступен на стоянке» на весь экран раздражала.
    final enabled = data != null;
    final body = Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: bz3
          ? const EdgeInsets.all(12)
          : const EdgeInsets.all(14),
      child: firstEntry
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.grid_view,
                        size: bz3 ? 18 : 22, color: AtlasTokens.info),
                    SizedBox(width: bz3 ? 8 : 10),
                    Text(S.of('atlas.title'),
                        style: TextStyle(
                            fontSize: bz3 ? 14 : 16,
                            fontWeight: FontWeight.w500,
                            color: AtlasTokens.t85)),
                  ],
                ),
                SizedBox(height: bz3 ? 10 : 12),
                Row(
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) SizedBox(width: bz3 ? 8 : 10),
                      AtlasGhostCell(
                          size: bz3 ? 38 : 44, radius: bz3 ? 12 : 14),
                    ],
                  ],
                ),
                SizedBox(height: bz3 ? 10 : 12),
                Text(S.of('measure.empty_atlas'),
                    style: TextStyle(
                        fontSize: bz3 ? 11 : 12,
                        height: 1.4,
                        color: AtlasTokens.t50)),
              ],
            )
          : Row(
              children: [
                Icon(Icons.grid_view,
                    size: bz3 ? 18 : 22, color: AtlasTokens.info),
                SizedBox(width: bz3 ? 8 : 10),
                Expanded(
                  child: Text(
                    '${S.of('atlas.title')}: $counts',
                    style: TextStyle(
                        fontSize: bz3 ? 13 : 16, color: AtlasTokens.t85),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(width: bz3 ? 8 : 10),
                Icon(Icons.chevron_right,
                    size: bz3 ? 18 : 20, color: AtlasTokens.t40),
              ],
            ),
    );
    if (!enabled) return Opacity(opacity: 0.55, child: body);
    return InkWell(
      // Совпадает с радиусом тела карточки (+165): иначе рябь
      // скругляется по своему углу и вылезает за карточку.
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              bz3 ? const AtlasScreen() : const AtlasWideScreen(),
        ));
      },
      child: body,
    );
  }
}

// ─────────────────── sync card §6.8 [2b / 3b] (+164) ───────────────────

/// «Синхронизация с телефоном» — the parked-only door into the cloud
/// settings. Geometry is the right column's shared card shape on BZ5
/// and block 3b on BZ3.
///
/// Clickable: `CloudServicesScreen` is already a public route pushed the
/// same way from `settings.dart`. Safe on the head unit because the card
/// only exists at standstill — nothing can pull the driver off the
/// screen mid-drive.
/// §6.8 — «Синхронизация с телефоном».
///
/// UX-ревизия +164: the subtitle states «Облако подключено» as a fact,
/// so the card may only exist when that is true. Rendering it on a
/// fresh install — the exact state a head unit is in right after the
/// reinstall this patch exists to survive — would have the screen
/// assert a connection the app does not have. Canon §6.8 honesty rule:
/// «карточка существует только когда данные реально текут». Not
/// registered or switched off → SizedBox.shrink(), no placeholder, no
/// greyed-out variant: there is nothing to offer and nothing to fix
/// from this screen.
class _SyncCard extends StatelessWidget {
  final bool bz3;
  const _SyncCard({required this.bz3});

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<CloudSyncService>();
    if (!cloud.isRegistered || !cloud.enabled) return const SizedBox.shrink();
    const radius = 12.0;
    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CloudServicesScreen()),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AtlasTokens.card,
          borderRadius: BorderRadius.circular(radius),
        ),
        padding: bz3
            ? const EdgeInsets.all(12)
            : const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.cloud_done,
                size: bz3 ? 18 : 22, color: AtlasTokens.info),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('measure.sync_title'),
                      style: TextStyle(
                          fontSize: bz3 ? 14 : 16,
                          fontWeight: FontWeight.w500,
                          color: AtlasTokens.t85)),
                  SizedBox(height: bz3 ? 4 : 6),
                  Text(S.of('measure.sync_sub'),
                      style: TextStyle(
                          fontSize: bz3 ? 11 : 12, color: AtlasTokens.t40),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right,
                size: bz3 ? 18 : 20, color: AtlasTokens.t40),
          ],
        ),
      ),
    );
  }
}

// ───────────────────── parking summary card §6.3 ─────────────────────

class _RevealCard extends StatelessWidget {
  final SpeedProfileService svc;
  final List<AtlasRevealRow> reveals;
  final VoidCallback onOk;
  const _RevealCard({
    required this.svc,
    required this.reveals,
    required this.onOk,
  });

  // Токены §2 дизайн-контракта.
  static const Color _bg = Color(0xFF141F1A); // revealBg
  static const Color _border = Color(0x405CE85C); // rgba(92,232,92,.25)
  static const Color _success = Color(0xFF5CE85C); // check_circle
  static const Color _info = Color(0xFF81D4FA); // grid_view (cell_new)
  static const Color _silver = Color(0xFFB9C4CE);
  static const Color _gold = Color(0xFFE9C46A);
  static const Color _progress = Color(0xFF1DE9B6); // кнопка «Ок»
  static const Color _onProgress = Color(0xFF00251C);

  static int _typeRank(String t) =>
      t == 'band_matured' ? 0 : (t == 'star_up' ? 1 : 2);

  /// Окно как в атласе: «5–10», «≤ −20» (клампы контракта §105).
  static String _windowLabel(int w) =>
      w <= -20 ? '≤ −20' : '$w–${w + 5}';

  // +163 (BB4): the range helper lives in band_card.dart —
  // atlasRangeKm is the ONE place 65.28 ÷ x × 100 is computed.

  String _lineFor(Map<String, dynamic> p, String type) {
    final band = (p['band'] as num?)?.toInt() ?? 0;
    switch (type) {
      case 'band_matured':
        // +163 (решение 26.07 п.11): the card reads the cell LIVE at
        // display time — realtime correction kept running after the
        // crossing, and the card must match the band card beside it.
        // The payload value is the fallback for a cell that already
        // left the ledger (a parked rotation ran first).
        final w = (p['window'] as num?)?.toInt();
        final x = svc.atlasLiveCellKwh100(band, w) ??
            (p['kwh100'] as num?)?.toDouble() ??
            0;
        if (x > 0.5) {
          return S
              .of('measure.card_matured')
              .replaceFirst('{v}', '$band')
              .replaceFirst('{x}', x.toStringAsFixed(1))
              .replaceFirst('{km}', '${atlasRangeKm(x)}');
        }
        // Regen-heavy first maturity: an «≈ −65280 км» range would be
        // arithmetic, not truth — the no-range template keeps honesty.
        return S
            .of('measure.card_matured_nr')
            .replaceFirst('{v}', '$band')
            .replaceFirst('{x}', x.toStringAsFixed(1));
      case 'star_up':
        final lvl = p['level'] == 'gold'
            ? S.of('measure.card_star_gold')
            : S.of('measure.card_star_silver');
        return S
            .of('measure.card_star')
            .replaceFirst('{v}', '$band')
            .replaceFirst('{lvl}', lvl)
            .replaceFirst('{n}', '${(p['sessions'] as num?)?.toInt() ?? 0}');
      default: // cell_new
        final cw = (p['window'] as num?)?.toInt();
        if (cw == null) {
          return S.of('measure.card_cell_nt').replaceFirst('{v}', '$band');
        }
        return S
            .of('measure.card_cell')
            .replaceFirst('{v}', '$band')
            .replaceFirst('{w}', _windowLabel(cw));
    }
  }

  Widget _iconFor(Map<String, dynamic> p, String type) {
    switch (type) {
      case 'band_matured':
        return const Icon(Icons.check_circle, size: 28, color: _success);
      case 'star_up':
        return Icon(Icons.star,
            size: 28, color: p['level'] == 'gold' ? _gold : _silver);
      default:
        return const Icon(Icons.grid_view, size: 28, color: _info);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Порядок событий (§2.2 п.2): band_matured → star_up → cell_new,
    // внутри типа — новые сверху (DAO уже отдал createdAt desc).
    final sorted = [...reveals]..sort((a, b) {
        final r = _typeRank(a.type).compareTo(_typeRank(b.type));
        if (r != 0) return r;
        final c = b.createdAt.compareTo(a.createdAt);
        if (c != 0) return c;
        return b.id.compareTo(a.id);
      });

    final bz3 = LayoutBreakpoints.useTallHeadUnit(context);
    final loot = svc.atlasLootCell();
    final soonBand = svc.atlasAnticipationBand();
    final t = svc.currentPackTempC;
    final km = svc.atlasSessionDistKm.toStringAsFixed(1);
    final tripLine = t == null
        ? S.of('measure.card_trip_nt').replaceFirst('{km}', km)
        : S
            .of('measure.card_trip')
            .replaceFirst('{km}', km)
            .replaceFirst('{t}', '${t.round()}');
    final lootLine = loot != null
        ? S
            .of('measure.card_loot')
            .replaceFirst('{v}', '${loot.band}')
            .replaceFirst('{s}', '${loot.gainedS.round()}')
            .replaceFirst('{a}', '${loot.timeS.floor()}')
            .replaceFirst('{m}', '${kBandMinSeconds.floor()}')
        : S
            .of('measure.card_loot_flat')
            .replaceFirst('{s}', '${svc.atlasGainedTotalS.round()}');

    return Container(
      decoration: BoxDecoration(
        color: _bg,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: EdgeInsets.all(bz3 ? 12 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Строка поездки.
          Text(tripLine,
              style: TextStyle(
                  fontSize: 16, color: Colors.white.withOpacity(0.85))),
          // 2. Reveal-события 0…N.
          for (final r in sorted)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _iconFor(_payload(r), r.type),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_lineFor(_payload(r), r.type),
                        style: const TextStyle(
                            fontSize: 16, color: Colors.white)),
                  ),
                ],
              ),
            ),
          // 3. Разделитель.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(
                height: 1, color: Colors.white.withOpacity(0.08)),
          ),
          // 4. Микро-лут (всегда при видимой карточке, §138).
          Text(lootLine,
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withOpacity(0.6))),
          // 5. Предвкушение (white .4, если есть; грубое, без
          // чисел-целей — инвариант И2).
          if (soonBand != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  S
                      .of('measure.card_soon')
                      .replaceFirst('{v}', '$soonBand'),
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.4))),
            ),
          // 6. Кнопка «Ок» (pill, progress/onProgress, цель ≥48 dp).
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _progress,
                foregroundColor: _onProgress,
                shape: const StadiumBorder(),
                // vertical 16 НЕ уменьшается вместе с кеглем: канон
                // §6.3 требует цель нажатия ≥48 dp, а 13 pt при
                // отступе 10 дало бы 38.
                padding: EdgeInsets.symmetric(
                    vertical: 16, horizontal: bz3 ? 40 : 48),
              ),
              onPressed: onOk,
              child: Text(S.of('common.ok'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  static Map<String, dynamic> _payload(AtlasRevealRow r) {
    try {
      final p = jsonDecode(r.payloadJson);
      if (p is Map<String, dynamic>) return p;
    } catch (_) {}
    return const {};
  }
}
