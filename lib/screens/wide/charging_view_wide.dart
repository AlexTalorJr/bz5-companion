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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ChargingLogBar(svc: svc),
            const SizedBox(height: 12),
            Expanded(flex: 4, child: _TopHeroRow(svc: svc, wide: true)),
            const SizedBox(height: 12),
            Expanded(flex: 5, child: _ChartsRow(svc: svc, wide: true)),
            const SizedBox(height: 12),
            _BottomSummaryStrip(svc: svc),
          ],
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
    final active = svc.chargingLogActive;
    final rows = svc.chargingLogRowsWritten;
    final pass = svc.chargingBlockAvgPassSeconds;
    return Card(
      color: active ? Colors.green.shade900.withValues(alpha: 0.35) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
                    )
                  else
                    Text(
                      S.of('chg.log.hint'),
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey),
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

class _TopHeroRow extends StatelessWidget {
  final ConnectionService svc;
  final bool wide;
  const _TopHeroRow({required this.svc, required this.wide});

  @override
  Widget build(BuildContext context) {
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: _PowerHero(svc: svc, wide: true)),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: _PhaseEtaStack(svc: svc)),
        ],
      );
    }
    // Narrow: hero and phase stack vertically; unbounded height inside
    // the scroll view, so no Expanded here.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PowerHero(svc: svc, wide: false),
        const SizedBox(height: 12),
        _PhaseEtaStack(svc: svc),
      ],
    );
  }
}

class _PowerHero extends StatelessWidget {
  final ConnectionService svc;
  final bool wide;
  const _PowerHero({required this.svc, this.wide = true});

  @override
  Widget build(BuildContext context) {
    final kw = svc.chargingPowerKw;
    final hv = svc.hvBusV;
    // v0.1.26+17: power getter now returns 0 during the first ~7 min
    // of an AC session because precise SOC quantises in ~0.1% steps —
    // we wait for at least 3 quanta of growth before reporting a kW
    // figure to avoid the 4.4 kW phantom we saw at 2.4 kW real input.
    // Tell the user that explicitly when kW==0 but isCharging==true,
    // otherwise the big "—" looks broken.
    final isCalibrating = kw == 0 && svc.isCharging;
    return Card(
      color: Colors.amber.shade900.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(S.of('chg.power_hdr'),
                style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 2,
                    color: Colors.amberAccent,
                    fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  kw > 0 ? kw.toStringAsFixed(1) : '—',
                  style: TextStyle(
                    // v0.1.29+56: 120 on wide (BZ5), 72 on narrow (BZ3
                    // portrait 720 dp / phone) — 120 would eat half the
                    // viewport height there.
                    fontSize: wide ? 120 : 72,
                    height: 1,
                    fontWeight: FontWeight.w300,
                    color: kw > 0 ? Colors.amberAccent : Colors.grey,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
                const Text('kW',
                    style: TextStyle(
                        fontSize: 28,
                        color: Colors.amberAccent,
                        fontWeight: FontWeight.w300)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              hv != null ? 'HV bus ${hv.toStringAsFixed(1)} V' : 'HV bus —',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 4),
            Text(
              isCalibrating
                  ? S.of('chg.calc_note')
                  : S.of('chg.power_formula'),
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhaseEtaStack extends StatelessWidget {
  final ConnectionService svc;
  const _PhaseEtaStack({required this.svc});

  @override
  Widget build(BuildContext context) {
    final phase = svc.chargingPhase;
    final etaSec = svc.etaToFullSeconds;
    // v0.1.32+131: user-selected SOC source (display / precise).
    final hal = context.watch<HalTelemetryService>();
    final soc = resolveUiSocPct(hal, svc) ?? svc.readNumeric('790', '0005');
    final gain = svc.socGainedThisChargingSessionPct;

    final phaseLabel = switch (phase) {
      ChargingPhase.unknown => S.of('chg.analyzing'),
      ChargingPhase.cc => 'CC phase',
      ChargingPhase.cv => S.of('chg.cv_phase'),
      ChargingPhase.almostDone => S.of('chg.almost_done'),
    };
    final phaseColor = switch (phase) {
      ChargingPhase.unknown => Colors.grey,
      ChargingPhase.cc => Colors.greenAccent,
      ChargingPhase.cv => Colors.orangeAccent,
      ChargingPhase.almostDone => Colors.lightBlueAccent,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(S.of('chg.phase'),
                      style: const TextStyle(
                          fontSize: 11, letterSpacing: 2, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text(phaseLabel,
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w400,
                          color: phaseColor)),
                  const SizedBox(height: 8),
                  Text(
                    soc != null
                        // v0.1.32+131: integral (display mode) → "80";
                        // fractional keeps the historical two decimals.
                        ? 'SOC ${formatSocPct(soc, maxDecimals: soc < 100 ? 2 : 1)}%'
                        : 'SOC —',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  if (gain != null)
                    Text(
                      S
                          .of('chg.gain_since')
                          .replaceFirst('{n}', gain.toStringAsFixed(2)),
                      style: TextStyle(
                          fontSize: 11, color: Colors.greenAccent.shade400),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(S.of('chg.eta100'),
                      style: const TextStyle(
                          fontSize: 11, letterSpacing: 2, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Text(
                    etaSec == null ? '— : —' : _formatEta(etaSec),
                    style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w400,
                        color: Colors.lightBlueAccent),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    etaSec == null
                        ? S.of('chg.need5')
                        : S.of('chg.eta_note'),
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
    final hist = svc.chargingHistory;
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
                style: const TextStyle(
                    fontSize: 11, letterSpacing: 2, color: Colors.grey)),
            const SizedBox(height: 2),
            Text(subtitle,
                style:
                    TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            const SizedBox(height: 8),
            Expanded(
              child: sampleCount < 2
                  ? Center(
                      child: Text(
                          S
                              .of('chg.collecting')
                              .replaceFirst('{n}', '$sampleCount'),
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600)),
                    )
                  : chartBuilder(),
            ),
          ],
        ),
      ),
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
          gridData: const FlGridData(show: false),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(show: false),
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
          gridData: const FlGridData(show: false),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(show: false),
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
          gridData: const FlGridData(show: false),
          titlesData: _axisTitles(unit: ''),
          borderData: FlBorderData(show: false),
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
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 38,
        getTitlesWidget: (v, _) => Text(
          v.toStringAsFixed(v.abs() < 10 ? 1 : 0),
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 16,
        getTitlesWidget: (v, _) => Text(
          v.toStringAsFixed(0),
          style: const TextStyle(fontSize: 9, color: Colors.grey),
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
    final chargedKwh = svc.chargedThisChargingSessionKwh;
    final socGain = svc.socGainedThisChargingSessionPct;
    final start = svc.chargingSessionStartedAt;
    final durationStr = start == null
        ? '—'
        : _fmtDuration(DateTime.now().difference(start));
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
        hint: '',
      ),
      _Metric(
        label: S.of('chg.soc_gain'),
        value: socGain != null
            ? '+${socGain.toStringAsFixed(2)}%'
            : '—',
        hint: S.of('chg.since_plugin'),
      ),
      _Metric(
        label: S.of('chg.session'),
        value: durationStr,
        hint: S.of('chg.session_sub'),
      ),
      _Metric(
        label: 'COUNTER 0B00',
        value: counterRaw != null ? '$counterRaw' : '—',
        hint: '',
      ),
      _Metric(
        label: 'I-MAX SET',
        value: maxCurrent != null
            ? '${maxCurrent.toStringAsFixed(0)} A'
            : '—',
        hint: '782/000C · CC→CV trigger',
      ),
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
        Text(label,
            style: const TextStyle(
                fontSize: 10, letterSpacing: 1.5, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w400,
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 2),
        Text(hint,
            style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
      ],
    );
  }
}
