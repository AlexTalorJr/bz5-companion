import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../services/connection.dart';
import '../../services/hal_telemetry_service.dart';
import '../../services/soc_resolver.dart';
import '../../services/locale_service.dart';

/// v0.1.26: Charging Companion view for the head-unit Driver tab.
///
/// Activated automatically by [DriverViewWideScreen] when
/// [ConnectionService.isCharging] returns true, so the user gets a
/// dedicated charging UI without manually switching tabs.
///
/// Layout (wide / 15.6" head display, ≥840 dp):
///   - Top hero row (flex 4):
///       · big power number (kW) on the left
///       · phase indicator + ETA + SOC delta stack on the right
///   - Middle row (flex 5): three side-by-side LineCharts —
///       · Power vs time
///       · Cell V min/max with spread overlay
///       · Battery temp
///   - Bottom strip (flex 1): session-summary numbers
///       (start SOC → current SOC, charged kWh, session duration,
///        raw 0x0B00 counter for scale calibration)
///
/// Data source for charts: [ConnectionService.chargingHistory], a
/// rolling 60-minute buffer populated every ~5 seconds while charging
/// is active. Charts gracefully render as "collecting…" when fewer
/// than 2 points are present (start of session).
///
/// Phase / ETA logic lives in [ConnectionService] (`chargingPhase`,
/// `etaToFullSeconds`) so the heuristics can be unit-tested separately
/// and reused later (e.g. in a status banner on the phone view).
/// v0.1.29+56: layout is adaptive. On wide (≥840 dp: BZ5 head unit)
/// the original three-row flex layout renders as designed. On narrow
/// (phone, BZ3 tall portrait at 720 dp) the same content reflows
/// vertically inside a scroll view: hero stack, then the three charts
/// stacked full-width (240 dp tall each), then the summary strip.
/// One widget tree, two arrangements — no duplicate screens.
// ══════════ v0.2.14+213: РАЗМЕРЫ ОТ ЗАМЕРЕННОГО ХОЛСТА ══════════
//
// ЧИСЛО ПРИЕХАЛО ИЗ `metadata.json` ЭКСПОРТА 26.08: 1280 x 656 dp, dpr 1.5.
// Это физические 1920 x 984 px. Канон в `responsive.dart` держал
// 2175 x 1224 dp — ширина завышена в 1.7 раза, высота почти вдвое. На том
// же неверном числе стоял и вывод dpr 0.875 из отношения 1920/2175:
// настоящее отношение 1920/1280 = 1.5, то есть та же плотность, что у BZ3.
//
// ПОЧЕМУ ВЫСОТЫ НЕ ЗАБИТЫ ЧИСЛАМИ. Присланный макет редизайна считал
// раскладку от 800 dp и дал сумму 782 — при настоящих 656 это перелёт на
// 126 dp, то есть обрезанный низ. Канон 2175 прожил месяцы и обманул всех,
// включая дизайнера. Поэтому высоты берутся из `LayoutBuilder`, а числа
// ниже задают только ДОЛЮ и НИЖНИЕ ПОРОГИ: ошибись замер снова — раскладка
// сожмётся, но не порвётся, а гейт CQ1 поймает расхождение арифметики.
//
// Доля 0.385 = 168 / (168 + 268) из пересчёта макета под 656 dp.
const double _kPadWide = 12;
const double _kGapWide = 12;
const double _kLogChipH = 48;
const double _kBottomStripH = 88;
const double _kHeroMinH = 150;
const double _kChartsMinH = 190;
const double _kHeroShare = 0.385;

/// Высота плитки герой-ряда в узкой ветке (BZ3 / телефон).
///
/// Там ветка живёт в прокрутке, высота не ограничена, а `Spacer` внутри
/// плитки требует границы — поэтому число явное, как у графиков рядом.
const double _kHeroTileNarrowH = 170;

class ChargingViewWide extends StatelessWidget {
  const ChargingViewWide({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    final wide = MediaQuery.of(context).size.width >= 840;

    if (wide) {
      return Padding(
        padding: const EdgeInsets.all(_kPadWide),
        child: LayoutBuilder(
          builder: (context, box) {
            // Гейт CQ1 смотрит окрестность этого счёта — комментарий держим
            // ВПЛОТНУЮ, без пустых строк между ним и предметом.
            final chip = svc.isBleConnected ? _kLogChipH : 0.0;
            final gaps = _kGapWide * (chip > 0 ? 3 : 2);
            final raw = box.maxHeight - chip - gaps - _kBottomStripH;
            final free = raw < 0 ? 0.0 : raw;
            // ПОРЯДОК ЗДЕСЬ НЕ КОСМЕТИКА. При холсте меньше суммы порогов
            // потолок `free - _kChartsMinH` опускается НИЖЕ порога
            // `_kHeroMinH`, а `clamp` с потолком ниже порога бросает
            // ArgumentError — то есть экран падает вместо того, чтобы
            // сжаться. Ревизия перед выдачей поймала это на расчёте:
            // ландшафтный телефон 900 x 420 dp даёт free 224 при сумме
            // порогов 340. В таком случае делим по доле, и оба ряда
            // сжимаются вместе.
            final hero = free <= (_kHeroMinH + _kChartsMinH)
                ? (free * _kHeroShare).clamp(0.0, free)
                : (free * _kHeroShare)
                    .clamp(_kHeroMinH, free - _kChartsMinH);
            final charts = free - hero;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (chip > 0) ...[
                  SizedBox(height: chip, child: _ChargingLogBar(svc: svc)),
                  const SizedBox(height: _kGapWide),
                ],
                SizedBox(
                    height: hero, child: _TopHeroRow(svc: svc, wide: true)),
                const SizedBox(height: _kGapWide),
                SizedBox(
                    height: charts, child: _ChartsRow(svc: svc, wide: true)),
                const SizedBox(height: _kGapWide),
                SizedBox(
                    height: _kBottomStripH,
                    child: _BottomSummaryStrip(svc: svc)),
              ],
            );
          },
        ),
      );
    }

    // Narrow (BZ3 portrait / phone): vertical scroll, charts stacked.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChargingLogBar(svc: svc),
          const SizedBox(height: 12),
          _TopHeroRow(svc: svc, wide: false),
          const SizedBox(height: 12),
          _ChartsRow(svc: svc, wide: false),
          const SizedBox(height: 12),
          _BottomSummaryStrip(svc: svc),
        ],
      ),
    );
  }
}

// ───────────────────── Charge-log control bar (+94) ─────────────────────

/// Manual start/stop for the per-module UDS charge log, plus a live status
/// readout. The button is the PRIMARY trigger — pressed BEFORE plugging in so
/// the baseline + pack_I sign-flip (recon's sync anchor) are captured; an
/// auto-start on the isCharging transition is a fallback that misses that
/// pre-onset window. While active, shows row count + measured per-block
/// cadence so it's obvious data is flowing before committing to the drive.
class _ChargingLogBar extends StatelessWidget {
  final ConnectionService svc;
  const _ChargingLogBar({required this.svc});

  @override
  Widget build(BuildContext context) {
    // v0.2.11+210: лог модулей — это UDS-опрос через донгл; на ГУ без
    // донгла карточка обещала запись, которой не будет («ИДЁТ ЗАПИСЬ ·
    // 0 строк» на фото 18.08). Без донгла её нет вовсе.
    if (!svc.isBleConnected) return const SizedBox.shrink();
    final active = svc.chargingLogActive;
    final rows = svc.chargingLogRowsWritten;
    final pass = svc.chargingBlockAvgPassSeconds;
    // v0.2.14+213: карточка тратила около 72 dp полного размера на
    // служебную функцию, и из-за неё высоты не хватало ни герой-ряду, ни
    // графикам. Тот же смысл умещается в чип высотой 48 dp.
    return Card(
      margin: EdgeInsets.zero,
      color: active ? Colors.green.shade900.withValues(alpha: 0.35) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Icon(
              active ? Icons.fiber_manual_record : Icons.battery_charging_full,
              size: 18,
              color: active ? Colors.greenAccent : Colors.grey,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    active
                        ? S.of('chg.log.active')
                        : S.of('chg.log.idle'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.greenAccent : null,
                    ),
                  ),
                  if (active)
                    Text(
                      S
                          .of('chg.log.stats')
                          .replaceFirst('{rows}', '$rows')
                          .replaceFirst(
                              '{pass}', pass?.toStringAsFixed(1) ?? '—'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.grey),
                    )
                  else
                    Text(
                      S.of('chg.log.hint'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.grey),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            active
                ? FilledButton.tonal(
                    onPressed: svc.stopChargingLog,
                    child: Text(S.of('chg.log.stop')),
                  )
                : FilledButton(
                    onPressed: () => svc.startChargingLog(),
                    child: Text(S.of('chg.log.start')),
                  ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────── Top hero row ───────────────────────────

/// Одна плитка герой-ряда с её долей ширины.
typedef _HeroSlot = ({int flex, Widget child});

/// Плитка герой-ряда: заголовок сверху, число в середине, подписи снизу.
///
/// v0.2.14+213. До этого патча фаза и ETA жили в `_PhaseEtaStack` — двух
/// карточках, сложенных ВЕРТИКАЛЬНО внутри той же доли высоты, что одна
/// карточка мощности. На замеренных 656 dp каждой доставалось около 90 dp
/// при потребности примерно 120, и подписи уходили под границу карточки:
/// на фото 24.08 срезаны строка под «анализ…» и строка под «ДО 100 %».
///
/// Здесь плитки стоят в ОДИН ряд, поэтому каждая получает полную высоту
/// герой-ряда, а не половину. Дополнительно: выравнивание сверху вместо
/// центрирования, каждая строка в одну строку с многоточием, шрифты не
/// ниже 13 dp (ниже с водительского места не читается).
class _HeroTile extends StatelessWidget {
  final String caption;
  final Color captionColor;
  final String value;
  final double valueSize;
  final Color valueColor;
  final String? unit;
  final List<String> notes;
  final Color? cardColor;
  final Widget? extra;
  const _HeroTile({
    required this.caption,
    required this.value,
    required this.valueSize,
    required this.valueColor,
    this.captionColor = Colors.grey,
    this.unit,
    this.notes = const [],
    this.cardColor,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14,
                    letterSpacing: 2,
                    color: captionColor,
                    fontWeight: FontWeight.w500)),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: valueSize,
                        height: 1,
                        fontWeight: FontWeight.w300,
                        color: valueColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 8),
                  Text(unit!,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: 22,
                          color: valueColor,
                          fontWeight: FontWeight.w300)),
                ],
              ],
            ),
            if (extra != null) ...[
              const SizedBox(height: 8),
              extra!,
            ],
            const Spacer(),
            for (final n in notes)
              Text(n,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
          ],
        ),
      ),
    );
  }
}

class _TopHeroRow extends StatelessWidget {
  final ConnectionService svc;
  final bool wide;
  const _TopHeroRow({required this.svc, required this.wide});

  @override
  Widget build(BuildContext context) {
    final hal = context.watch<HalTelemetryService>();
    final slots = _slots(context, hal);
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < slots.length; i++) ...[
            if (i > 0) const SizedBox(width: _kGapWide),
            Expanded(flex: slots[i].flex, child: slots[i].child),
          ],
        ],
      );
    }
    // Узкая ветка (BZ3 720 dp / телефон): плитки одна под другой, высота
    // явная — прокрутка не даёт границы, а `Spacer` внутри плитки её
    // требует. Тот же приём, что у графиков ниже.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < slots.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          SizedBox(height: _kHeroTileNarrowH, child: slots[i].child),
        ],
      ],
    );
  }

  List<_HeroSlot> _slots(BuildContext context, HalTelemetryService hal) {
    // v0.2.14+213: цепочка выбора мощности переехала в
    // `resolveChargePowerKw` — баннеру и фазе нужна ТА ЖЕ мощность, и три
    // копии одной цепочки дали бы три разных ответа на один вопрос.
    final power = resolveChargePowerKw(hal, svc);
    final kw = power.kw;
    final hv = svc.hvBusV ??
        hal.halValue('pack_voltage_fine') ??
        hal.halValue('pack_voltage');
    // v0.1.26+17: мощность держит 0 первые ~7 минут AC-сессии — точный SOC
    // растёт шагами по 0.1 %, и до трёх шагов роста числу верить нельзя.
    // Большое «—» без объяснения выглядит поломкой, поэтому подпись меняем.
    final isCalibrating = kw == 0 && (svc.isCharging || hal.halChargingActive);

    final phase = resolveChargingPhase(hal, svc);
    final phaseLabel = switch (phase) {
      ChargingPhase.unknown => S.of('chg.analyzing'),
      ChargingPhase.cc => S.of('chg.cc_phase'),
      ChargingPhase.cv => S.of('chg.cv_phase'),
      ChargingPhase.almostDone => S.of('chg.almost_done'),
    };
    final phaseColor = switch (phase) {
      ChargingPhase.unknown => Colors.grey,
      ChargingPhase.cc => Colors.greenAccent,
      ChargingPhase.cv => Colors.orangeAccent,
      ChargingPhase.almostDone => Colors.lightBlueAccent,
    };

    final soc = resolveUiSocPct(hal, svc) ?? svc.readNumeric('790', '0005');
    final gain =
        svc.socGainedThisChargingSessionPct ?? hal.halChargeSessionSocDeltaPct;
    final etaEff = svc.etaToFullSeconds ?? hal.halEtaToFullSeconds;
    final startSoc =
        svc.chargingSessionStartSocPct ?? hal.halChargeSessionStartSoc;

    final phaseNotes = <String>[
      if (gain != null)
        S.of('chg.gain_since').replaceFirst('{n}', gain.toStringAsFixed(2)),
    ];

    return [
      (
        flex: 34,
        child: _HeroTile(
          caption: S.of('chg.power_hdr'),
          captionColor: Colors.amberAccent,
          cardColor: Colors.amber.shade900.withValues(alpha: 0.12),
          value: kw > 0
              ? '${power.approx ? '≈' : ''}${kw.toStringAsFixed(1)}'
              : '—',
          // Макет просил 112 dp, но в плитку высотой около 168 dp при
          // отступах, заголовке и подписях столько не влезает — остаётся
          // примерно 80. Берём 76: число всё равно самое крупное на
          // экране, вторые по величине идут 32.
          valueSize: wide ? 76 : 64,
          valueColor: kw > 0 ? Colors.amberAccent : Colors.grey,
          unit: 'kW',
          notes: [
            hv != null ? 'HV bus ${hv.toStringAsFixed(1)} V' : 'HV bus —',
            isCalibrating
                ? S.of('chg.calc_note')
                : S.of('chg.power_formula'),
          ],
        ),
      ),
      (
        flex: 22,
        child: _HeroTile(
          caption: S.of('chg.phase'),
          value: phaseLabel,
          valueSize: 30,
          valueColor: phaseColor,
          notes: phaseNotes,
        ),
      ),
      (
        flex: 22,
        child: _HeroTile(
          caption: S.of('chg.eta100'),
          value: etaEff == null ? '— : —' : _formatEta(etaEff),
          valueSize: 30,
          valueColor: Colors.lightBlueAccent,
          notes: [
            etaEff == null ? S.of('chg.need5') : S.of('chg.eta_note'),
          ],
        ),
      ),
      // ЧЕСТНОСТЬ: плитка заряда существует только когда SOC реально идёт.
      // Пустая рамка с прочерком обещала бы данные, которых нет.
      if (soc != null)
        (
          flex: 22,
          child: _HeroTile(
            caption: S.of('chg.charge_hdr'),
            value: formatSocPct(soc, maxDecimals: soc < 100 ? 1 : 0),
            valueSize: 30,
            valueColor: Colors.white,
            unit: '%',
            extra: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (soc / 100).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: Colors.white24,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Colors.lightBlueAccent),
              ),
            ),
            notes: [
              startSoc != null
                  ? S
                      .of('chg.soc_start')
                      .replaceFirst('{n}', startSoc.toStringAsFixed(1))
                  : S.of('chg.soc_target'),
            ],
          ),
        ),
    ];
  }

  static String _formatEta(int seconds) {
    if (seconds < 60) return S.of('chg.lt1min');
    final m = seconds ~/ 60;
    if (m < 60) return S.of('chg.eta_m').replaceFirst('{m}', '$m');
    final h = m ~/ 60;
    final mm = m % 60;
    return '~${h}h ${mm}m';
  }
}

// ───────────────────────── Charts row ─────────────────────────

class _ChartsRow extends StatelessWidget {
  final ConnectionService svc;
  final bool wide;
  const _ChartsRow({required this.svc, required this.wide});

  @override
  Widget build(BuildContext context) {
    // v0.2.11+210: без донгла OBD-история пуста — графики строятся из
    // сессионной истории HAL (точка раз в >=60 с). Тот же класс точек,
    // переложение здесь: виджету можно читать оба сервиса, сервисам друг
    // друга — нет (AA2).
    var hist = svc.chargingHistory;
    if (hist.isEmpty) {
      final hal = context.watch<HalTelemetryService>();
      final hh = hal.halChargingHistory;
      if (hh.isNotEmpty) {
        hist = [
          for (final pnt in hh)
            ChargingSample(
              time: pnt.t,
              powerKw: pnt.kw,
              socPct: pnt.socPct,
              cellMinMv: pnt.cellMinMv,
              cellMaxMv: pnt.cellMaxMv,
              tempC: pnt.tempC,
            ),
        ];
      }
    }
    if (wide) {
      return Row(
        children: [
          Expanded(child: _PowerChart(history: hist)),
          const SizedBox(width: 12),
          Expanded(child: _CellVChart(history: hist)),
          const SizedBox(width: 12),
          Expanded(child: _TempChart(history: hist)),
        ],
      );
    }
    // Narrow (BZ3 720 dp portrait): three full-width charts stacked,
    // fixed 240 dp height each (they're inside a scroll view, so they
    // can't take height from flex — explicit SizedBox required).
    return Column(
      children: [
        SizedBox(height: 240, child: _PowerChart(history: hist)),
        const SizedBox(height: 12),
        SizedBox(height: 240, child: _CellVChart(history: hist)),
        const SizedBox(height: 12),
        SizedBox(height: 240, child: _TempChart(history: hist)),
      ],
    );
  }
}

/// Generic frame around a single chart card with title + chart body slot
/// and a 0-state fallback when there aren't enough points yet.
class _ChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final int sampleCount;
  final Widget Function() chartBuilder;
  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.sampleCount,
    required this.chartBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14, letterSpacing: 2, color: Colors.grey)),
            const SizedBox(height: 2),
            // v0.2.14+213: строка «накопление… (1 сэмплов)» рисовалась по
            // центру пустого графика и читалась как оторванный текст поверх
            // соседней карточки (фото 24.08). Её место — подзаголовок: она
            // отвечает на вопрос «почему пусто» ровно там, где обычно стоит
            // объяснение оси, и исчезает сама, когда график ожил.
            Text(
                sampleCount < 2
                    ? S
                        .of('chg.collecting_sub')
                        .replaceFirst('{n}', '$sampleCount')
                    : subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            Expanded(
              child:
                  sampleCount < 2 ? const _EmptyChartGrid() : chartBuilder(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Приглушённая сетка на месте графика, пока точек меньше двух.
///
/// v0.2.14+213. Пустая карточка выглядела сломанной, а центрированный текст
/// поверх неё — оторванным. Сетка сообщает «место занято, данные будут»,
/// ничего не обещая о значениях.
class _EmptyChartGrid extends StatelessWidget {
  const _EmptyChartGrid();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < 4; i++)
          Container(height: 1, color: Colors.white.withValues(alpha: 0.05)),
      ],
    );
  }
}

class _PowerChart extends StatelessWidget {
  final List<ChargingSample> history;
  const _PowerChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    if (history.isNotEmpty) {
      final t0 = history.first.time.millisecondsSinceEpoch.toDouble();
      for (final s in history) {
        final p = s.powerKw;
        if (p == null) continue;
        final x = (s.time.millisecondsSinceEpoch.toDouble() - t0) / 60000.0;
        spots.add(FlSpot(x, p));
      }
    }
    final maxKw = spots.isEmpty
        ? 1.0
        : spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    return _ChartCard(
      title: S.of('chg.power'),
      subtitle: S.of('chg.kw_vs_min'),
      sampleCount: spots.length,
      chartBuilder: () => LineChart(
        LineChartData(
          minY: 0,
          maxY: maxKw * 1.1 + 1,
          // v0.2.14+213: горизонтальная сетка и рамка слева-снизу — без них
          // значение не привязано ни к чему. Вертикальные линии не рисуем:
          // ось времени и так подписана снизу.
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.white.withValues(alpha: 0.05), strokeWidth: 1),
          ),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(
            show: true,
            border: Border(
              left: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
              bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: Colors.amberAccent,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.amberAccent.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CellVChart extends StatelessWidget {
  final List<ChargingSample> history;
  const _CellVChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final minSpots = <FlSpot>[];
    final maxSpots = <FlSpot>[];
    if (history.isNotEmpty) {
      final t0 = history.first.time.millisecondsSinceEpoch.toDouble();
      for (final s in history) {
        final x = (s.time.millisecondsSinceEpoch.toDouble() - t0) / 60000.0;
        if (s.cellMinMv != null) {
          minSpots.add(FlSpot(x, s.cellMinMv!.toDouble()));
        }
        if (s.cellMaxMv != null) {
          maxSpots.add(FlSpot(x, s.cellMaxMv!.toDouble()));
        }
      }
    }
    final all = [...minSpots.map((e) => e.y), ...maxSpots.map((e) => e.y)];
    final lo = all.isEmpty ? 3200.0 : all.reduce((a, b) => a < b ? a : b);
    final hi = all.isEmpty ? 3300.0 : all.reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo).abs() * 0.1 + 5;
    final spread = history.isNotEmpty
        ? history.last.spreadMv
        : null;

    return _ChartCard(
      title: 'CELL V min / max',
      subtitle: spread != null
          ? S.of('chg.mv_vs_min_spread').replaceFirst('{s}', '$spread')
          : S.of('chg.mv_vs_min'),
      sampleCount: minSpots.length,
      chartBuilder: () => LineChart(
        LineChartData(
          minY: lo - pad,
          maxY: hi + pad,
          // v0.2.14+213: горизонтальная сетка и рамка слева-снизу — без них
          // значение не привязано ни к чему. Вертикальные линии не рисуем:
          // ось времени и так подписана снизу.
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.white.withValues(alpha: 0.05), strokeWidth: 1),
          ),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(
            show: true,
            border: Border(
              left: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
              bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: minSpots,
              isCurved: false,
              color: Colors.lightBlueAccent,
              barWidth: 1.3,
              dotData: const FlDotData(show: false),
            ),
            LineChartBarData(
              spots: maxSpots,
              isCurved: false,
              color: Colors.redAccent,
              barWidth: 1.3,
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

class _TempChart extends StatelessWidget {
  final List<ChargingSample> history;
  const _TempChart({required this.history});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    if (history.isNotEmpty) {
      final t0 = history.first.time.millisecondsSinceEpoch.toDouble();
      for (final s in history) {
        final t = s.tempC;
        if (t == null) continue;
        final x = (s.time.millisecondsSinceEpoch.toDouble() - t0) / 60000.0;
        spots.add(FlSpot(x, t));
      }
    }
    final lo = spots.isEmpty
        ? 15.0
        : spots.map((e) => e.y).reduce((a, b) => a < b ? a : b);
    final hi = spots.isEmpty
        ? 35.0
        : spots.map((e) => e.y).reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo).abs() * 0.15 + 1;
    final latestC = history.isNotEmpty ? history.last.tempC : null;
    return _ChartCard(
      title: S.of('chg.bat_temp'),
      subtitle: latestC != null
          ? S
              .of('chg.c_vs_min_now')
              .replaceFirst('{t}', latestC.toStringAsFixed(1))
          : S.of('chg.c_vs_min'),
      sampleCount: spots.length,
      chartBuilder: () => LineChart(
        LineChartData(
          minY: lo - pad,
          maxY: hi + pad,
          // v0.2.14+213: горизонтальная сетка и рамка слева-снизу — без них
          // значение не привязано ни к чему. Вертикальные линии не рисуем:
          // ось времени и так подписана снизу.
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.white.withValues(alpha: 0.05), strokeWidth: 1),
          ),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(
            show: true,
            border: Border(
              left: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
              bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.10), width: 1),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: Colors.orangeAccent,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.orangeAccent.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

FlTitlesData _axisTitles({required String unit}) {
  return FlTitlesData(
    rightTitles:
        const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    // v0.2.14+213: место под метку было 38 dp при шрифте 10. Четырёхзначные
    // милливольты (3285, 3290) в него не влезали и лезли в поле данных — на
    // фото 24.08 ось наехала на линии. Сетки не было вовсе, поэтому
    // непонятно, к какому уровню относится значение. 54 dp при шрифте 13:
    // ниже 13 dp с водительского места не читается.
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 54,
        getTitlesWidget: (v, _) => Text(
          v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 24,
        getTitlesWidget: (v, _) => Text(
          v.toStringAsFixed(0),
          maxLines: 1,
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
      ),
    ),
  );
}

// ────────────────────── Bottom summary strip ──────────────────────

class _BottomSummaryStrip extends StatelessWidget {
  final ConnectionService svc;
  const _BottomSummaryStrip({required this.svc});

  // v0.1.29+56: below this width the 5-metric Row gets cramped
  // (~140 dp per column on BZ3's 720 dp). Wrap reflows to 2-3 rows.
  static const double _kRowMinWidth = 840;

  @override
  Widget build(BuildContext context) {
    // v0.2.11+210: те же величины без донгла считает HAL-трекер сессии —
    // синяя плитка дашборда живёт им с +143, экран теперь тоже.
    final hal = context.watch<HalTelemetryService>();
    final chargedKwh =
        svc.chargedThisChargingSessionKwh ?? hal.halChargedThisSessionKwh;
    final socGain =
        svc.socGainedThisChargingSessionPct ?? hal.halChargeSessionSocDeltaPct;
    // v0.2.13+212: выбор источника сессии сделан ОДИН раз. До этого рядом
    // стояли два независимых выражения — одно для якоря, другое для
    // подписи; они совпадали лишь по договорённости, и правка одного молча
    // разъехалась бы с другим (подпись про один якорь, цифры про другой).
    final bool svcOwnsSession = svc.chargingSessionStartedAt != null;
    final start = svcOwnsSession
        ? svc.chargingSessionStartedAt
        : hal.halChargeSessionStartedAt;
    final durationStr = start == null
        ? '—'
        : _fmtDuration(DateTime.now().difference(start));
    // v0.2.13+212 (развилка 2.4, решение владельца): живую сессию через
    // рестарт НЕ восстанавливаем — вместо этого подписываем суммы честно.
    // Спрашиваем ТОТ ЖЕ источник, что дал якорь выше (правило +209 «один
    // вопрос — один отвечающий»). Якоря нет вовсе → значения и так «—»,
    // подпись оставляем обычную.
    final bool fromStart = svcOwnsSession
        ? svc.chargingSessionFromStart
        : (hal.halChargeSessionStartedAt != null
            ? hal.halChargeSessionFromStart
            : true);
    final String sinceLaunchHint = S.of('chg.since_app_launch');
    final counterRaw = svc.readNumeric('790', '0B00')?.toInt();
    final maxCurrent = svc.readNumeric('782', '000C');

    final wide =
        MediaQuery.of(context).size.width >= _kRowMinWidth;
    final metrics = <Widget>[
      _Metric(
        label: S.of('chg.charged'),
        value: chargedKwh != null
            ? '${chargedKwh.toStringAsFixed(2)} kWh'
            : '—',
        hint: fromStart ? '' : sinceLaunchHint,
      ),
      _Metric(
        label: S.of('chg.soc_gain'),
        value: socGain != null
            ? '+${socGain.toStringAsFixed(2)}%'
            : '—',
        hint: fromStart ? S.of('chg.since_plugin') : sinceLaunchHint,
      ),
      _Metric(
        label: S.of('chg.session'),
        value: durationStr,
        hint: fromStart ? S.of('chg.session_sub') : sinceLaunchHint,
      ),
      // +210: счётчик 0B00 и лимит тока — величины UDS-опроса через донгл;
      // на ГУ они всегда «—», плиток без донгла нет вовсе.
      // v0.2.13+212 (2.6): к живому донглу добавлена память сессии. На слабом
      // BLE isBleConnected мигает, и раньше плитки прыгали вместе с ним;
      // теперь достаточно, что донгл БЫЛ в этой сессии — цифры уходят в «—»,
      // а разметка стоит. На ГУ без донгла оба слагаемых ложны, плиток
      // по-прежнему нет вовсе.
      if (svc.isBleConnected || svc.chargingSessionSawDongle) ...[
        _Metric(
          label: S.of('chg.counter_hdr'),
          value: counterRaw != null ? '$counterRaw' : '—',
          hint: '',
        ),
        _Metric(
          label: S.of('chg.imax_hdr'),
          value: maxCurrent != null
              ? '${maxCurrent.toStringAsFixed(0)} A'
              : '—',
          hint: '782/000C · CC→CV trigger',
        ),
      ],
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        // v0.1.29+56: Row of 5 on wide (BZ5 — each column gets ~400 dp);
        // Wrap on narrow (BZ3 720 dp portrait / phone) so the metrics
        // reflow into 2-3 rows instead of squeezing into ~140 dp columns.
        child: wide
            ? Row(
                children: [
                  for (final m in metrics) Expanded(child: m),
                ],
              )
            : Wrap(
                spacing: 24,
                runSpacing: 12,
                children: metrics,
              ),
      ),
    );
  }

  static String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return S.of('chg.dur_m').replaceFirst('{m}', '$m');
    return S
        .of('chg.dur_hm')
        .replaceFirst('{h}', '$h')
        .replaceFirst('{m}', '$m');
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  const _Metric(
      {required this.label, required this.value, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // v0.2.14+213: подписи были 10 и 9 dp — с водительского места
        // нечитаемы, и обрезались первыми. Мерка теперь по самой длинной
        // подписи «с запуска приложения» из +212, а не по короткой
        // «с момента подключения»: она длиннее и вылезает при рестарте
        // посреди зарядки, то есть реже и оттого незаметнее.
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 13, letterSpacing: 1.5, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w400,
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
      ],
    );
  }
}
