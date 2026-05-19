import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/connection.dart';

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
class ChargingViewWide extends StatelessWidget {
  const ChargingViewWide({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 4, child: _TopHeroRow(svc: svc)),
          const SizedBox(height: 12),
          Expanded(flex: 5, child: _ChartsRow(svc: svc)),
          const SizedBox(height: 12),
          _BottomSummaryStrip(svc: svc),
        ],
      ),
    );
  }
}

// ─────────────────────────── Top hero row ───────────────────────────

class _TopHeroRow extends StatelessWidget {
  final ConnectionService svc;
  const _TopHeroRow({required this.svc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: _PowerHero(svc: svc)),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: _PhaseEtaStack(svc: svc)),
      ],
    );
  }
}

class _PowerHero extends StatelessWidget {
  final ConnectionService svc;
  const _PowerHero({required this.svc});

  @override
  Widget build(BuildContext context) {
    final kw = svc.chargingPowerKw;
    final hv = svc.hvBusV;
    return Card(
      color: Colors.amber.shade900.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('CHARGING POWER',
                style: TextStyle(
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
                    fontSize: 120,
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
              'Power = ΔB00 × ${Bz5Model.chargeCounterWh.toInt()} Wh/unit (calibration TBD)',
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
    final soc = svc.socPrecisePct ?? svc.readNumeric('790', '0005');
    final gain = svc.socGainedThisChargingSessionPct;

    final phaseLabel = switch (phase) {
      ChargingPhase.unknown => 'analyzing…',
      ChargingPhase.cc => 'CC phase',
      ChargingPhase.cv => 'CV phase (tapering)',
      ChargingPhase.almostDone => 'Almost done',
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
                  const Text('PHASE',
                      style: TextStyle(
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
                        ? 'SOC ${soc.toStringAsFixed(soc < 100 ? 2 : 1)}%'
                        : 'SOC —',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  if (gain != null)
                    Text(
                      '+${gain.toStringAsFixed(2)}% since plug-in',
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
                  const Text('ETA TO 100%',
                      style: TextStyle(
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
                        ? 'нужно ≥5 минут данных'
                        : 'linear extrapolation · curves to longer in CV',
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
    if (seconds < 60) return '<1 min';
    final m = seconds ~/ 60;
    if (m < 60) return '~$m min';
    final h = m ~/ 60;
    final mm = m % 60;
    return '~${h}h ${mm}m';
  }
}

// ───────────────────────── Charts row ─────────────────────────

class _ChartsRow extends StatelessWidget {
  final ConnectionService svc;
  const _ChartsRow({required this.svc});

  @override
  Widget build(BuildContext context) {
    final hist = svc.chargingHistory;
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
                      child: Text('collecting… ($sampleCount samples)',
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
      title: 'POWER',
      subtitle: 'kW vs minutes',
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
          ? 'mV vs min · current spread $spread mV'
          : 'mV vs min',
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
      title: 'BATTERY TEMP',
      subtitle: latestC != null
          ? '°C vs min · now ${latestC.toStringAsFixed(1)} °C'
          : '°C vs min',
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _Metric(
                label: 'CHARGED',
                value: chargedKwh != null
                    ? '${chargedKwh.toStringAsFixed(2)} kWh'
                    : '—',
                hint: 'счётчик × ${Bz5Model.chargeCounterWh.toInt()} Wh (calib TBD)',
              ),
            ),
            Expanded(
              child: _Metric(
                label: 'SOC GAIN',
                value: socGain != null
                    ? '+${socGain.toStringAsFixed(2)}%'
                    : '—',
                hint: 'с момента plug-in',
              ),
            ),
            Expanded(
              child: _Metric(
                label: 'SESSION',
                value: durationStr,
                hint: 'на текущей зарядке',
              ),
            ),
            Expanded(
              child: _Metric(
                label: 'COUNTER 0B00',
                value: counterRaw != null ? '$counterRaw' : '—',
                hint: 'raw — для калибровки scale',
              ),
            ),
            Expanded(
              child: _Metric(
                label: 'I-MAX SET',
                value: maxCurrent != null
                    ? '${maxCurrent.toStringAsFixed(0)} A'
                    : '—',
                hint: '782/000C · CC→CV trigger',
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h == 0) return '$m мин';
    return '${h}ч ${m}м';
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
