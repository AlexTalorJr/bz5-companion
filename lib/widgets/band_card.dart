// v0.1.64+163 «Замеры по контракту, заход A» — the band card of the
// «Замеры» screen (canon 1.2 §6.1, mockups 1i-A / 2a / 3a).
//
// Three stages, ONE card:
//   • тихая    — the band is not in the set; the card is not built at
//                all (no empty slots — the set is decided by the caller);
//   • зреющая  — «Полоса 60» + «зреет», the 0…120 s bar, «96 с из 120»;
//   • дозревшая— «Полоса 50» + «дозрела · замер этой поездки», the big
//                number + «кВт·ч/100» + «≈ 430 км».
// The maturing → matured transition is an AnimatedCrossFade ≤ 300 мс.
//
// DATA SOURCE (+163, решение владельца 26.07 п.1): the card renders the
// LEDGER, never the session overlay — the number on the card is the
// number that will land in the atlas. The atlas line («в атласе 12.6 ·
// 3 поездки») rides on BOTH stages whenever the cell already has a
// measurement in the display window: after a parked rotation the
// matured card collapses into a fresh maturing round, and the number
// the driver cares about stays on screen — already weight-updated.
//
// Every dimension below is a literal from DESIGN_extract_plus163.md
// (макеты are drawn at native dp) — the design gate checks them
// verbatim, «примерно так же» is a regression.

import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/speed_profile_service.dart';
import '../theme/atlas_tokens.dart';
import 'atlas_grid.dart' show atlasPlural;

/// The ONE place range is derived from consumption (regress BB4):
/// 65.28 ÷ расход × 100, rounded to 5 km (canon §6.1 / §8). Every
/// surface — band cards, the summary card — calls this helper.
int atlasRangeKm(double kwh100) =>
    ((SpeedProfileService.packCapacityKwh / kwh100 * 100.0) / 5.0)
        .round() *
    5;

/// Everything one band card needs, resolved by the screen: the live
/// side (stage + progress + this-drive number) and the atlas side
/// (weighted mean + independent drives in the display window).
class BandCardModel {
  final int band;

  /// Steady seconds of the band's deepest live cell (0 when the band
  /// is in the set only through its atlas measurement).
  final double timeS;

  /// This drive's consumption — the deepest live cell's kwh100; null
  /// until the cell has any distance.
  final double? kwh100;

  /// Atlas line: the cell's weighted mean in the display window, null
  /// when the cell has no snapshot there yet.
  final double? atlasMean;

  /// Independent drives behind [atlasMean] (contract dedup count).
  final int atlasDrives;

  const BandCardModel({
    required this.band,
    required this.timeS,
    required this.kwh100,
    required this.atlasMean,
    required this.atlasDrives,
  });

  bool get matured => timeS >= kBandMinSeconds;
}

class BandCard extends StatelessWidget {
  final BandCardModel model;

  /// BZ3 (720×1106) renders the 3a numbers; BZ5 the 1i-A numbers.
  final bool bz3;

  const BandCard({super.key, required this.model, required this.bz3});

  @override
  Widget build(BuildContext context) {
    final m = model;
    return Container(
      constraints: bz3 ? null : const BoxConstraints(minHeight: 96),
      decoration: BoxDecoration(
        color: AtlasTokens.card,
        borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(vertical: 26, horizontal: 28)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 36),
      child: bz3
          // 3a (720 wide): stacked — title block, then the stage body
          // full-width beneath (the bar needs a bounded width).
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _leftBlock(),
                const SizedBox(height: 12),
                _crossFade(),
              ],
            )
          // 1i-A: two-block row, the stage body flushed right.
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: 200, child: _leftBlock()),
                const SizedBox(width: 32),
                Expanded(child: _crossFade()),
              ],
            ),
    );
  }

  Widget _crossFade() {
    return AnimatedCrossFade(
      duration: const Duration(milliseconds: 280),
      crossFadeState: model.matured
          ? CrossFadeState.showSecond
          : CrossFadeState.showFirst,
      firstChild: _maturingRight(),
      secondChild: _maturedRight(),
      alignment: bz3 ? Alignment.centerLeft : Alignment.centerRight,
    );
  }

  Widget _leftBlock() {
    final m = model;
    final stage = m.matured
        ? S.of('measure.stage_matured')
        : S.of('measure.stage_maturing');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${S.of('measure.band')} ${m.band}',
            style: TextStyle(
                fontSize: bz3 ? 24 : 27,
                fontWeight: FontWeight.w500,
                color: AtlasTokens.t85)),
        const SizedBox(height: 2),
        Text(stage,
            style: TextStyle(
                fontSize: bz3 ? 17 : 20, color: AtlasTokens.t40)),
        // Atlas line (решение 26.07 п.3, расширено на обе стадии): the
        // collected number stays visible through a fresh maturing round.
        if (m.atlasMean != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              S
                  .of('measure.in_atlas')
                  .replaceFirst('{x}', m.atlasMean!.toStringAsFixed(1))
                  .replaceFirst('{n}', '${m.atlasDrives}')
                  .replaceFirst(
                      '{trips}',
                      atlasPlural(
                          m.atlasDrives,
                          S.of('measure.trip_one'),
                          S.of('measure.trip_few'),
                          S.of('measure.trip_many'))),
              style: TextStyle(
                  fontSize: bz3 ? 17 : 20, color: AtlasTokens.t40),
            ),
          ),
      ],
    );
  }

  /// Maturing stage: the 0…120 s bar + «96 с из 120» under it. The bar
  /// crawls smoothly, never changes colour, never pulses at the finish
  /// (canon §6.1).
  Widget _maturingRight() {
    final m = model;
    final barH = bz3 ? 12.0 : 14.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(barH / 2),
          child: LinearProgressIndicator(
            value: (m.timeS / kBandMinSeconds).clamp(0.0, 1.0),
            minHeight: barH,
            backgroundColor: AtlasTokens.progressTrack,
            color: AtlasTokens.progress,
          ),
        ),
        SizedBox(height: bz3 ? 12 : 10),
        Text(
          S
              .of('measure.of_120')
              .replaceFirst('{s}', '${m.timeS.floor()}')
              .replaceFirst('{m}', '${kBandMinSeconds.floor()}'),
          style: TextStyle(fontSize: bz3 ? 17 : 20, color: AtlasTokens.t40),
        ),
      ],
    );
  }

  /// Matured stage: baseline-aligned number row, right-flushed. BZ3
  /// drops the range line (canon §7.4 — no derived range on the narrow
  /// head unit). A regen-heavy band (kwh100 ≤ 0.5) shows the number
  /// without a range — «≈ −65280 км» would be arithmetic, not truth.
  Widget _maturedRight() {
    final m = model;
    final cons = m.kwh100;
    final numText = cons == null ? '—' : cons.toStringAsFixed(1);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(numText,
            style: TextStyle(
                fontSize: bz3 ? 52 : 64,
                fontWeight: FontWeight.w700,
                color: AtlasTokens.t100,
                fontFeatures: const [FontFeature.tabularFigures()])),
        SizedBox(width: bz3 ? 10 : 16),
        Text(S.of('measure.kwh100'),
            style: TextStyle(
                fontSize: bz3 ? 19 : 24, color: AtlasTokens.t50)),
        if (!bz3 && cons != null && cons > 0.5) ...[
          const SizedBox(width: 24),
          Text(
              S
                  .of('measure.range_est')
                  .replaceFirst('{km}', '${atlasRangeKm(cons)}'),
              style:
                  const TextStyle(fontSize: 24, color: AtlasTokens.t60)),
        ],
      ],
    );
  }
}

/// The 2d / 3d empty state: icon → title → a ghost band card at
/// opacity .4 with its explaining caption. No tutorials, no buttons.
class BandEmptyState extends StatelessWidget {
  final bool bz3;
  const BandEmptyState({super.key, required this.bz3});

  @override
  Widget build(BuildContext context) {
    final ghost = Container(
      width: bz3 ? double.infinity : 780,
      decoration: BoxDecoration(
        color: AtlasTokens.cardMuted,
        borderRadius: BorderRadius.circular(bz3 ? 22 : 24),
      ),
      padding: bz3
          ? const EdgeInsets.symmetric(vertical: 24, horizontal: 28)
          : const EdgeInsets.symmetric(vertical: 26, horizontal: 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${S.of('measure.band')} 60',
              style: TextStyle(
                  fontSize: bz3 ? 22 : 26,
                  fontWeight: FontWeight.w500,
                  color: AtlasTokens.t85)),
          SizedBox(height: bz3 ? 10 : 12),
          Text(
              S
                  .of('measure.of_120')
                  .replaceFirst('{s}', '96')
                  .replaceFirst('{m}', '${kBandMinSeconds.floor()}'),
              style: TextStyle(
                  fontSize: bz3 ? 17 : 20, color: AtlasTokens.t60)),
          SizedBox(height: bz3 ? 10 : 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(bz3 ? 6 : 7),
            child: LinearProgressIndicator(
              value: 0.8,
              minHeight: bz3 ? 12 : 14,
              backgroundColor: const Color(0x1AFFFFFF),
              color: const Color(0x801DE9B6),
            ),
          ),
          SizedBox(height: bz3 ? 10 : 12),
          Text(S.of('measure.empty_ghost'),
              style: TextStyle(
                  fontSize: bz3 ? 16 : 19, color: AtlasTokens.t50)),
        ],
      ),
    );
    return Column(
      children: [
        SizedBox(height: bz3 ? 24 : 32),
        Icon(Icons.speed, size: bz3 ? 64 : 80, color: AtlasTokens.t22),
        SizedBox(height: bz3 ? 32 : 40),
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: bz3 ? 40 : 0),
          child: Text(S.of('measure.empty_title'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: bz3 ? 26 : 32,
                  height: 1.4,
                  // white .75 — the 2d/3d mockup value; deliberately a
                  // local literal, .75 is not a rung of the §2 ladder.
                  color: const Color(0xBFFFFFFF))),
        ),
        SizedBox(height: bz3 ? 32 : 40),
        Center(child: Opacity(opacity: 0.4, child: ghost)),
      ],
    );
  }
}
