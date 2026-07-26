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
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import '../widgets/atlas_grid.dart'
    show atlasCountsLabel, atlasMonthNames;
import '../widgets/band_card.dart';
import '../widgets/responsive.dart';
import 'atlas.dart';
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
    _loadedRevision = context.read<SpeedProfileService>().atlasRevision;
    _gridFuture = db
        .getAtlasSnapshotsForGrid(maxBand: kAtlasBandMaxKmh)
        .then((rows) => AtlasGridData.fromRows(rows));
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
        final maturedWithNumber = [
          for (final m in models)
            if (m.matured && m.kwh100 != null) m
        ];
        return ListView(
          padding: bz3
              ? const EdgeInsets.fromLTRB(24, 20, 24, 20)
              : const EdgeInsets.fromLTRB(44, 28, 44, 24),
          children: [
            _ScreenHeader(isParked: _isParked, bz3: bz3),
            // +160 (§2.2): карточка итогов — сверху колонки полос, НЕ
            // оверлей. Появление на стоянке — обычный build по условию.
            if (_cardVisible && _cardReveals != null) ...[
              SizedBox(height: bz3 ? 16 : 24),
              _RevealCard(
                svc: svc,
                reveals: _cardReveals!,
                onOk: () => _onOkReveals(svc),
              ),
            ],
            // +162 (§6.10, макет [5c]) → +163 (решение 26.07 п.6):
            // намерение сформулировано через управляемое; переживает
            // «Ок», в движении не существует.
            _IntentCard(isParked: _isParked, bz3: bz3, grid: data),
            SizedBox(height: bz3 ? 16 : 24),
            // ── карточки полос §6.1 / пустое состояние 2d·3d ──
            if (models.isEmpty)
              BandEmptyState(bz3: bz3)
            else
              for (final m in models) ...[
                // Keyed by band: when the order does change (stage
                // flip / standstill), Flutter moves the element instead
                // of rebuilding it — the crossfade state survives.
                BandCard(
                    key: ValueKey('band_${m.band}'),
                    model: m,
                    bz3: bz3),
                SizedBox(height: bz3 ? 16 : 20),
              ],
            // ── график по полосам — остаётся навсегда (канон §0.1) ──
            if (maturedWithNumber.isNotEmpty) ...[
              SizedBox(height: bz3 ? 0 : 4),
              _BandBarCard(
                bars: [
                  for (final m in maturedWithNumber
                    ..sort((a, b) => a.band.compareTo(b.band)))
                    (band: m.band, kwh100: m.kwh100!)
                ],
                bz3: bz3,
              ),
              SizedBox(height: bz3 ? 16 : 24),
            ] else
              SizedBox(height: bz3 ? 16 : 24),
            _ZeroTo100Card(session: svc.session, bz3: bz3),
            SizedBox(height: bz3 ? 16 : 24),
            // +161 (§7.1): the door into the atlas — открыт всегда.
            _AtlasEntryCard(data: data, bz3: bz3),
            SizedBox(height: bz3 ? 12 : 16),
            // Honest platform limitation, spelled out (spec §5): a
            // sleeping head unit measures nothing — same physics as the
            // AC night.
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
/// 16 dp `rec` dot + «Запись · {v} км/ч» + the «ровное время идёт»
/// tail; parked a `gearP` 700 «P» + «Стоянка · ровное время не идёт»
/// (решение владельца 26.07 п.7 — «запись остановлена» died with the
/// Стоп button it described).
class _StatusChip extends StatelessWidget {
  final bool isParked;
  final bool bz3;
  const _StatusChip({required this.isParked, required this.bz3});

  @override
  Widget build(BuildContext context) {
    final v = context.read<HalTelemetryService>().halSpeedKmh;
    final dotSize = bz3 ? 11.0 : 16.0;
    final mainSize = bz3 ? 18.0 : 24.0;
    final Widget lead;
    final Widget label;
    if (isParked) {
      lead = Text('P',
          style: TextStyle(
              fontSize: bz3 ? 20 : 26,
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
              text: ' · ${S.of('measure.chip_rec_tail')}',
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
          ? const EdgeInsets.symmetric(vertical: 8, horizontal: 18)
          : const EdgeInsets.symmetric(vertical: 10, horizontal: 26),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          lead,
          SizedBox(width: bz3 ? 9 : 14),
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
class _BandBarCard extends StatelessWidget {
  final List<({int band, double kwh100})> bars;
  final bool bz3;
  const _BandBarCard({required this.bars, required this.bz3});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(vertical: 22, horizontal: 28)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(S.of('measure.chart_title'),
              style: TextStyle(
                  fontSize: bz3 ? 20 : 25,
                  fontWeight: FontWeight.w500,
                  color: AtlasTokens.t85)),
          SizedBox(height: bz3 ? 12 : 14),
          if (bars.length < 3)
            _textFallback()
          else
            SizedBox(height: 160, child: _chart()),
        ],
      ),
    );
  }

  Widget _textFallback() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in bars)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${b.band} → ${b.kwh100.toStringAsFixed(1)} ${S.of('measure.kwh100')}',
              style: TextStyle(
                  fontSize: bz3 ? 16 : 20, color: AtlasTokens.t60),
            ),
          ),
      ],
    );
  }

  Widget _chart() {
    double maxV = 0;
    double minV = 0;
    for (final b in bars) {
      if (b.kwh100 > maxV) maxV = b.kwh100;
      if (b.kwh100 < minV) minV = b.kwh100;
    }
    // Index-based x (the Trends _BarCard pattern) — band values as x
    // would make fl_chart title interpolated ticks between the bars.
    // Signed energy (+155): the axis survives a negative band.
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
                if (v != i.toDouble() || i < 0 || i >= bars.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${bars[i].band}',
                      style: const TextStyle(fontSize: 11)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < bars.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: bars[i].kwh100,
                width: 14,
                color: AtlasTokens.progress,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(3)),
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
  const _ZeroTo100Card({required this.session, required this.bz3});

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
          size: bz3 ? 28 : 30, color: AtlasTokens.info),
      SizedBox(width: bz3 ? 12 : 14),
      Text(S.of('measure.z100_title'),
          style: TextStyle(
              fontSize: bz3 ? 20 : 25,
              fontWeight: FontWeight.w500,
              color: bz3 ? const Color(0xB3FFFFFF) : AtlasTokens.t85)),
    ];
    final Widget content;
    if (runs.isEmpty) {
      // Collapsed: one line — title + readiness, nothing else.
      content = Row(
        children: [
          ...titleRow,
          const Spacer(),
          Flexible(
            child: Text(S.of('measure.z100_ready'),
                style: TextStyle(
                    fontSize: bz3 ? 16 : 22, color: AtlasTokens.t50)),
          ),
        ],
      );
    } else {
      final best = session!.bestZeroTo100!;
      final last = runs.last;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: titleRow),
          SizedBox(height: bz3 ? 16 : 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(best.toStringAsFixed(1),
                  style: TextStyle(
                      fontSize: bz3 ? 30 : 58,
                      fontWeight: FontWeight.w700,
                      color: AtlasTokens.t100,
                      fontFeatures: const [
                        FontFeature.tabularFigures()
                      ])),
              SizedBox(width: bz3 ? 8 : 14),
              Text(S.of('measure.z100_sec'),
                  style: TextStyle(
                      fontSize: bz3 ? 16 : 26, color: AtlasTokens.t50)),
              const Spacer(),
              Text('${S.of('measure.z100_last')} · ${_fmtDay(last.tsMs)}',
                  style: TextStyle(
                      fontSize: bz3 ? 16 : 22, color: AtlasTokens.t40)),
            ],
          ),
          SizedBox(height: bz3 ? 8 : 14),
          Text(S.of('measure.z100_ready'),
              style: TextStyle(
                  fontSize: bz3 ? 16 : 22, color: AtlasTokens.t50)),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: bz3 ? AtlasTokens.cardMuted : AtlasTokens.card,
        borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(vertical: 22, horizontal: 28)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 32),
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
            borderRadius: BorderRadius.circular(16 * k),
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
          borderRadius: BorderRadius.circular(16 * k),
        ),
        padding: EdgeInsets.all(18 * k),
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

/// v0.1.62+161 → +163 — entry into the atlas from the «Замеры» screen.
/// One line per the 2a mockup: grid_view 30 `info` → «Атлас · {n}
/// клеток · {m} скоростей · просмотр» 24 → chevron 28 t40. Открыт
/// всегда (канон 1.2 §0.1 — блокировка в движении отменена); the grid
/// data arrives from the screen's shared loader.
class _AtlasEntryCard extends StatelessWidget {
  final AtlasGridData? data;
  final bool bz3;
  const _AtlasEntryCard({required this.data, required this.bz3});

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
        borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(horizontal: 24, vertical: 20)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 32),
      child: Row(
        children: [
          Icon(Icons.grid_view,
              size: bz3 ? 24 : 30, color: AtlasTokens.info),
          SizedBox(width: bz3 ? 12 : 16),
          Expanded(
            child: Text(
              '${S.of('atlas.title')} · $counts',
              style: TextStyle(
                  fontSize: bz3 ? 18 : 24, color: AtlasTokens.t85),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: bz3 ? 12 : 16),
          Icon(Icons.chevron_right,
              size: bz3 ? 24 : 28, color: AtlasTokens.t40),
        ],
      ),
    );
    if (!enabled) return Opacity(opacity: 0.55, child: body);
    return InkWell(
      borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
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
        borderRadius: BorderRadius.circular(24),
      ),
      padding: EdgeInsets.symmetric(
          vertical: 26, horizontal: bz3 ? 28 : 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Строка поездки.
          Text(tripLine,
              style: TextStyle(
                  fontSize: 24, color: Colors.white.withOpacity(0.85))),
          // 2. Reveal-события 0…N.
          for (final r in sorted)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _iconFor(_payload(r), r.type),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(_lineFor(_payload(r), r.type),
                        style: const TextStyle(
                            fontSize: 25, color: Colors.white)),
                  ),
                ],
              ),
            ),
          // 3. Разделитель.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Divider(
                height: 1, color: Colors.white.withOpacity(0.08)),
          ),
          // 4. Микро-лут (всегда при видимой карточке, §138).
          Text(lootLine,
              style: TextStyle(
                  fontSize: 20, color: Colors.white.withOpacity(0.6))),
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
                      fontSize: 20,
                      color: Colors.white.withOpacity(0.4))),
            ),
          // 6. Кнопка «Ок» (pill, progress/onProgress, цель ≥48 dp).
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _progress,
                foregroundColor: _onProgress,
                shape: const StadiumBorder(),
                padding: EdgeInsets.symmetric(
                    vertical: 16, horizontal: bz3 ? 48 : 64),
              ),
              onPressed: onOk,
              child: Text(S.of('common.ok'),
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w600)),
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
