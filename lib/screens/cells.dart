import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/hal_telemetry_service.dart';
import '../services/locale_service.dart';

/// v0.1.2: Cells screen теперь имеет два режима — CELLS и THERMAL.
/// Переключатель в AppBar; данные общие из ConnectionService.
class CellsScreen extends StatefulWidget {
  const CellsScreen({super.key});

  @override
  State<CellsScreen> createState() => _CellsScreenState();
}

class _CellsScreenState extends State<CellsScreen> {
  // 0 = CELLS heatmap (как раньше)
  // 1 = THERMAL map (новое)
  int _mode = 0;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    // v0.1.29+102: HAL cumulative cell-balance fallback. In halOnly without a
    // dongle liveCells is empty (per-cell 136 is UDS-only), but the recon
    // BMS min/max pair (0x45400010/030) flows via BigData dongle-free. When
    // there are no per-cell values BUT the HAL pair is available, show the
    // cumulative view (min/max V + Δ + indices + pack temp) instead of the
    // "no data" placeholder. Per-cell present → unchanged OBD2 per-module UI.
    final hal = context.watch<HalTelemetryService>();
    final cells = svc.liveCells;
    final showHalCumulative = cells.isEmpty && hal.useHalForCellSpread;

    return Scaffold(
      appBar: AppBar(
        title: Text(S.of('cells.tab_balance')),
        actions: [
          // Сегментированный переключатель режима
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(S.of('dash.cells_title'))),
                ButtonSegment(
                    value: 1, label: Text(S.of('cells.tab_thermal'))),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
              ),
            ),
          ),
        ],
      ),
      body: showHalCumulative
          ? _HalCumulativeView(hal: hal)
          : cells.isEmpty
              ? Center(child: Text(S.of('cells.empty')))
              : (_mode == 0
                  ? _CellsView(cells: cells)
                  : _ThermalView(svc: svc)),
    );
  }
}

// ─────────────────── HAL cumulative balance (v0.1.29+102) ───────────────────
// Shown in halOnly/HAL-owned mode when per-cell 136 values are unavailable
// (UDS-only) but the recon BMS min/max pair flows via BigData dongle-free.
// This is the BMS aggregate (cell_v_lowest 0x45400010 / cell_v_highest
// 0x45400030), NOT per-module spread — delta here is 3–10 mV (the canonical
// pack balance), distinct from the per-module dongle spread (5–26 mV). HAL has
// no per-module temperature lowest/highest (STATISTIC_*_BATTERY_TEMP is
// request-only, not broadcast — confirmed on DC by Друг 3), so temperature is
// shown as a single pack number (battery_temp_bigdata 0x044C b[12]), not min/
// max/delta.
class _HalCumulativeView extends StatelessWidget {
  final HalTelemetryService hal;
  const _HalCumulativeView({required this.hal});

  @override
  Widget build(BuildContext context) {
    final loV = hal.halCellVLowest; // volts
    final hiV = hal.halCellVHighest; // volts
    final spreadMv = hal.halCellSpreadMv; // mV
    final idxLo = hal.halCellIdxLowest;
    final idxHi = hal.halCellIdxHighest;
    final packTemp = hal.halBatteryTempC;

    // Balance quality by the same mV thresholds the per-cell header uses, so
    // the colour language is consistent across both views.
    String quality;
    Color color;
    if (spreadMv == null) {
      quality = '—';
      color = Colors.grey;
    } else if (spreadMv <= 20) {
      quality = S.of('dash.excellent_cap');
      color = Colors.green;
    } else if (spreadMv <= 50) {
      quality = S.of('dash.good_cap');
      color = Colors.lightGreen;
    } else if (spreadMv <= 100) {
      quality = S.of('dash.fair_cap');
      color = Colors.orange;
    } else {
      quality = S.of('dash.poor_cap');
      color = Colors.red;
    }

    String mv(double? v) => v == null ? '—' : '${(v * 1000).toInt()} mV';
    String idx(double? v) => v == null ? '' : '#${v.toInt()}';

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Source note — honest about this being the BMS aggregate, not 136.
          Text(
            S.of('cells.hal_cumulative_note'),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _StatColumn(
                          label: '${S.of('cells.min_v')} ${idx(idxLo)}'.trim(),
                          value: mv(loV)),
                      _StatColumn(
                          label: '${S.of('cells.max_v')} ${idx(idxHi)}'.trim(),
                          value: mv(hiV)),
                      _StatColumn(
                          label: S.of('cells.spread_d'),
                          value: spreadMv == null
                              ? '—'
                              : '${spreadMv.toInt()} mV',
                          color: color),
                    ],
                  ),
                  const Divider(height: 24),
                  Text(
                    S.of('cells.balance_fmt').replaceFirst('{q}', quality),
                    style: TextStyle(
                        fontSize: 16,
                        color: color,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Pack temperature — single number (no per-module min/max via HAL).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _StatColumn(
                    label: S.of('cells.pack_temp'),
                    value: packTemp == null
                        ? '—'
                        : '+${packTemp.toInt()}°C',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}


// ─────────────────────── Cells view (legacy) ───────────────────────

class _CellsView extends StatelessWidget {
  final List<int> cells;
  const _CellsView({required this.cells});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _SummaryHeader(cells: cells),
          const SizedBox(height: 24),
          Expanded(child: _CellsHeatmap(cells: cells)),
        ],
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  final List<int> cells;
  const _SummaryHeader({required this.cells});

  @override
  Widget build(BuildContext context) {
    final lo = cells.reduce((a, b) => a < b ? a : b);
    final hi = cells.reduce((a, b) => a > b ? a : b);
    final avg = cells.reduce((a, b) => a + b) / cells.length;
    final spread = hi - lo;
    final balanceQuality = spread <= 20
        ? S.of('dash.excellent_cap')
        : spread <= 50
            ? S.of('dash.good_cap')
            : spread <= 100
                ? S.of('dash.fair_cap')
                : S.of('dash.poor_cap');
    final balanceColor = spread <= 20 ? Colors.green : spread <= 50 ? Colors.lightGreen : spread <= 100 ? Colors.orange : Colors.red;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatColumn(label: 'Min', value: '$lo mV'),
                _StatColumn(label: 'Avg', value: '${avg.toInt()} mV'),
                _StatColumn(label: 'Max', value: '$hi mV'),
                _StatColumn(label: 'Δ', value: '$spread mV', color: balanceColor),
              ],
            ),
            const Divider(height: 24),
            Text(S.of('cells.balance_fmt').replaceFirst('{q}', balanceQuality),
                style: TextStyle(fontSize: 16, color: balanceColor, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _StatColumn({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: color)),
      ],
    );
  }
}

class _CellsHeatmap extends StatelessWidget {
  final List<int> cells;
  const _CellsHeatmap({required this.cells});

  @override
  Widget build(BuildContext context) {
    final lo = cells.reduce((a, b) => a < b ? a : b);
    final hi = cells.reduce((a, b) => a > b ? a : b);
    final spread = (hi - lo).clamp(1, 99999);

    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 1.5,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: cells.length,
      itemBuilder: (context, i) {
        final v = cells[i];
        final ratio = (v - lo) / spread;
        final color = Color.lerp(Colors.blue.shade900, Colors.lightBlue.shade300, ratio)!;

        return Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('M${(i ~/ 2) + 1}.${i % 2 == 0 ? "min" : "max"}',
                  style: const TextStyle(fontSize: 10, color: Colors.white70)),
              Text('$v',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
              const Text('mV', style: TextStyle(fontSize: 10, color: Colors.white70)),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────── Thermal view (v0.1.2 NEW) ───────────────────────

class _ThermalView extends StatelessWidget {
  final ConnectionService svc;
  const _ThermalView({required this.svc});

  @override
  Widget build(BuildContext context) {
    final modules = svc.moduleSnapshots;

    // Сводка по модулям с известной температурой
    final reportedTemps = <double>[];
    for (final m in modules) {
      if (m.temp1C != null) reportedTemps.add(m.temp1C!);
      if (m.temp2C != null) reportedTemps.add(m.temp2C!);
    }

    String rangeText = '—';
    String spreadText = '—';
    Color spreadColor = Colors.grey;
    String spreadLabel = '';

    if (reportedTemps.isNotEmpty) {
      final tmin = reportedTemps.reduce((a, b) => a < b ? a : b);
      final tmax = reportedTemps.reduce((a, b) => a > b ? a : b);
      final delta = tmax - tmin;
      rangeText = tmin == tmax
          ? '+${tmin.toInt()}°C'
          : '+${tmin.toInt()}…+${tmax.toInt()}°C';
      spreadText = '${delta.toStringAsFixed(0)}°C';
      // Pop classification
      if (delta <= 2) {
        spreadColor = Colors.green;
        spreadLabel = S.of('cells.even');
      } else if (delta <= 5) {
        spreadColor = Colors.lightGreen;
        spreadLabel = S.of('cells.normal');
      } else if (delta <= 10) {
        spreadColor = Colors.orange;
        spreadLabel = S.of('cells.uneven');
      } else {
        spreadColor = Colors.red;
        spreadLabel = S.of('cells.check_cooling');
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // v0.1.3: Pack-wide extremes card.
        // BMS отдаёт глобальные min/max по ВСЕМ ~136 ячейкам:
        //   790/0x002B = global min mV, 790/0x002C = global min cell index
        //   790/0x002D = global max mV, 790/0x002E = global max cell index
        // Per-module table ниже показывает только min/max в каждом модуле,
        // что не отражает абсолютные крайности — отсюда нужна эта карточка.
        _PackExtremesCard(svc: svc),
        const SizedBox(height: 12),
        // Сводка
        Row(
          children: [
            Expanded(
              child: _SummaryTile(
                label: 'RANGE',
                value: rangeText,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SummaryTile(
                label: S.of('cells.spread_d'),
                value: '$spreadText$spreadLabel',
                color: spreadColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Модули
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      // v0.1.3: уточнили формулировку. У нас 136 ячеек в
                      // 10 модулях, но BMS отдаёт через UDS только min/max
                      // ячейки на модуль (не каждую из 14 ячеек модуля).
                      S
                          .of('cells.modules_hdr')
                          .replaceFirst('{m}', '${svc.packModuleCount ?? 10}')
                          .replaceFirst('{c}', '${svc.packCellCount ?? 136}'),
                      style: const TextStyle(fontSize: 10, letterSpacing: 0.5, color: Colors.grey),
                    ),
                    const Spacer(),
                    // v0.1.27: column heading now says only the
                    // delta sign — the two columns to the right
                    // are cell-voltage range and cell-voltage
                    // delta (both in mV), neither is a temperature
                    // reading. Per-module temperature is shown
                    // inside the bar to the left.
                    const Text('MIN..MAX mV · Δ',
                        style: TextStyle(fontSize: 9, letterSpacing: 0.3, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 10),
                // v0.1.27: for modules without their own temperature
                // sensor (e.g. M6 on BZ5 — structural, no sensor by
                // design) we color the bar fill using the nearest
                // neighbour's temperature so the row doesn't look
                // visually broken next to its peers. Caption text
                // inside the bar stays as 'no temp sensor' to keep
                // the user informed; only the color is borrowed.
                // Search order: previous (lower index) first, then
                // next (higher index) — for M6 on BZ5 that means M5
                // is used by default, exactly as requested.
                ..._buildModuleRows(modules, reportedTemps),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// v0.1.27: build _ModuleRow widgets with neighbour-fallback
  /// temperatures for modules without their own sensor. The fallback
  /// is only used for *coloring* the bar — the label inside stays
  /// 'no temp sensor' so the user knows the value isn't measured.
  List<Widget> _buildModuleRows(
    List<ModuleSnapshot> modules,
    List<double> reportedTemps,
  ) {
    final out = <Widget>[];
    for (int i = 0; i < modules.length; i++) {
      final m = modules[i];
      double? fallback;
      if (!m.hasAnyTemp) {
        // Search backward first (closer to the user's mental model
        // of "use the previous module" — M6 borrows from M5).
        for (int j = i - 1; j >= 0; j--) {
          final t = modules[j].avgTemp;
          if (t != null) {
            fallback = t;
            break;
          }
        }
        // Forward fallback only if nothing found behind (e.g. when
        // the very first module of the pack is sensorless).
        if (fallback == null) {
          for (int j = i + 1; j < modules.length; j++) {
            final t = modules[j].avgTemp;
            if (t != null) {
              fallback = t;
              break;
            }
          }
        }
      }
      out.add(_ModuleRow(
        module: m,
        tempRange: reportedTemps.isEmpty ? null : reportedTemps,
        fallbackTempC: fallback,
      ));
    }
    return out;
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.grey.shade900,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.grey, letterSpacing: 0.5)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(fontSize: 17, color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _ModuleRow extends StatelessWidget {
  final ModuleSnapshot module;
  final List<double>? tempRange;
  /// v0.1.27: optional fallback temperature for modules without an
  /// own temperature sensor. When set, the bar is filled with the
  /// color that corresponds to this temperature (instead of being
  /// a transparent outlined box) so the row sits visually flush
  /// with its neighbours. The label inside the bar remains 'no temp
  /// sensor' — only the color is borrowed, not the value.
  final double? fallbackTempC;
  const _ModuleRow({
    required this.module,
    this.tempRange,
    this.fallbackTempC,
  });

  @override
  Widget build(BuildContext context) {
    final temp = module.avgTemp;
    // v0.1.27: temperature used purely for choosing the bar color.
    // If the module has its own sensor, use that. Otherwise borrow
    // the neighbour's temperature (passed in via fallbackTempC). If
    // neither — leave null, which falls through to the original
    // transparent-outlined-box look.
    final tempForColor = temp ?? fallbackTempC;
    final delta = module.cellDelta;
    final deltaColor = delta == null
        ? Colors.grey
        : (delta > 15 ? Colors.red : (delta > 5 ? Colors.orange : Colors.green));

    // Цвет температурной полосы — относительно глобального диапазона.
    // v6.1: bar всегда полной ширины; разница температуры передаётся только
    // цветом. Раньше bar нормализовался по ширине (0.3..1.0), что давало
    // визуально ложное "M10 наполовину пустой" когда у него было всего
    // на 0.5°C ниже остальных модулей.
    Color tempBarColor = const Color(0xFF7AB9D4);
    if (tempForColor != null &&
        tempRange != null &&
        tempRange!.isNotEmpty) {
      final tmin = tempRange!.reduce((a, b) => a < b ? a : b);
      final tmax = tempRange!.reduce((a, b) => a > b ? a : b);
      if (tmax - tmin > 0.5) {
        final ratio =
            ((tempForColor - tmin) / (tmax - tmin)).clamp(0.0, 1.0);
        // hot = orange, cool = blue
        tempBarColor = Color.lerp(
          const Color(0xFF7AB9D4),
          const Color(0xFFD4944A),
          ratio,
        )!;
      } else {
        // Все модули в пределах 0.5°C — единый нейтральный цвет.
        tempBarColor = const Color(0xFFA8A496);
      }
    }

    // Текст температуры: с десятичным знаком если есть spread, иначе целое.
    // Это передаёт пользователю что M10 действительно холоднее на 0.5°C,
    // а не одинаков с остальными.
    String? tempText;
    if (temp != null) {
      final hasSpread = tempRange != null
          && tempRange!.isNotEmpty
          && (tempRange!.reduce((a, b) => a > b ? a : b)
              - tempRange!.reduce((a, b) => a < b ? a : b)) > 0.5;
      tempText = hasSpread
          ? '+${temp.toStringAsFixed(1)}°C'
          : '+${temp.toStringAsFixed(0)}°C';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          // Module label
          SizedBox(
            width: 30,
            child: Text('M${module.index}',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ),
          // Temperature bar
          Expanded(
            child: Builder(builder: (context) {
              // v0.1.27: bar gets a colored fill if the module has its
              // OWN sensor OR if a neighbour fallback temperature is
              // available. When borrowing, the bar looks the same as
              // a measured module — only the label inside differs
              // ('no temp sensor' instead of '+28°C').
              final hasFill =
                  module.hasAnyTemp || fallbackTempC != null;
              return Container(
                height: 16,
                decoration: BoxDecoration(
                  color: hasFill
                      ? Colors.grey.shade800
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: hasFill
                      ? null
                      : Border.all(
                          color: Colors.grey.shade700,
                          style: BorderStyle.solid,
                          width: 1),
                ),
                child: Stack(
                  children: [
                    if (hasFill)
                      Container(
                        decoration: BoxDecoration(
                          color: tempBarColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: tempText != null
                            ? Text(tempText,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: tempBarColor
                                              .computeLuminance() >
                                          0.4
                                      ? const Color(0xFF1a0a00)
                                      : Colors.white,
                                  fontWeight: FontWeight.w500,
                                ))
                            : Text(
                                // v0.1.3: structural, not a comm
                                // dropout — M6 has no temperature
                                // sensors by design on BZ5. Cell
                                // voltages M6 read normally.
                                // v0.1.6: 'no temp sensor' clearer
                                // than 'no sensors' (the latter sounds
                                // like the whole module is offline).
                                // v0.1.27: when bar is filled via
                                // fallbackTempC, contrast the label
                                // against the fill color the same
                                // way the real temp text does.
                                S.of('cells.no_temp_sensor'),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: hasFill
                                      ? (tempBarColor
                                                  .computeLuminance() >
                                              0.4
                                          ? const Color(0xFF1a0a00)
                                              .withOpacity(0.7)
                                          : Colors.white70)
                                      : Colors.grey.shade500,
                                  letterSpacing: 0.3,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          // Cell range: voltages of A and B in this module (mV)
          SizedBox(
            width: 96,
            child: Text(
              (module.cellAmV != null && module.cellBmV != null)
                  ? '${module.cellAmV}–${module.cellBmV}'
                  : '—',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white70,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.right,
            ),
          ),
          // Cell delta
          SizedBox(
            width: 50,
            child: Text(
              delta != null ? 'Δ$delta' : '',
              style: TextStyle(
                fontSize: 11,
                color: deltaColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

/// v0.1.3: Pack-wide extremes card. Shows the absolute min and max cell
/// voltages across all ~136 cells in the pack, with their cell indices
/// (which BMS continuously updates as cells fluctuate).
///
/// Sources:
///   790/0x002B → cellMin (mV) — DecodedValue via registry
///   790/0x002D → cellMax (mV) — DecodedValue via registry
///   790/0x002C → cellMinIndex (0..135) — read by _pollExtraDids
///   790/0x002E → cellMaxIndex (0..135) — read by _pollExtraDids
///
/// Per-module list below shows only per-module min/max; this card shows
/// the absolute pack-wide values, which is the more useful health metric
/// (a single bad cell anywhere will show up here even if the per-module
/// max for the affected module is still relatively normal).
class _PackExtremesCard extends StatelessWidget {
  final ConnectionService svc;
  const _PackExtremesCard({required this.svc});

  @override
  Widget build(BuildContext context) {
    // v0.1.6: prefer new getters over readNumeric — see connection.dart
    // _pollExtraDids docstring for why these DIDs need direct polling.
    final minV = svc.globalMinCellMv?.toDouble()
        ?? svc.readNumeric('790', '002B');
    final maxV = svc.globalMaxCellMv?.toDouble()
        ?? svc.readNumeric('790', '002D');
    final minIdx = svc.globalMinCellIndex;
    final maxIdx = svc.globalMaxCellIndex;
    final cellCount = svc.packCellCount ?? 136;

    if (minV == null || maxV == null) {
      return Card(
        color: Colors.grey.shade900,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.battery_unknown, color: Colors.grey, size: 18),
              const SizedBox(width: 10),
              Text(S.of('dash.pack_extremes_loading'),
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    final spread = (maxV - minV).round();
    // v0.1.3.1: используем те же SOC-aware пороги что и в Dashboard
    // _CellsSummaryCard._balanceQuality — иначе пользователь видит
    // "excellent" на одном экране и "good" на другом за один и тот же spread.
    // На LFP knee при SOC>90% spread всегда выше из-за крутой кривой → пороги мягче.
    final socPct = svc.readNumeric('790', '0005') ?? 50;
    final ({String label, Color color}) quality;
    int excellent, good, fair;
    if (socPct >= 90) {
      excellent = 50; good = 100; fair = 150;
    } else if (socPct < 30) {
      excellent = 10; good = 20; fair = 40;
    } else {
      excellent = 20; good = 40; fair = 80;
    }
    if (spread <= excellent) {
      quality = (label: S.of('dash.excellent'), color: Colors.green);
    } else if (spread <= good) {
      quality = (label: S.of('dash.good'), color: Colors.lightGreen);
    } else if (spread <= fair) {
      quality = (label: S.of('dash.fair'), color: Colors.orange);
    } else {
      quality = (label: S.of('dash.check'), color: Colors.red);
    }

    return Card(
      color: Colors.grey.shade900,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.battery_full, color: Colors.lightBlueAccent, size: 16),
                const SizedBox(width: 6),
                Text(
                    S
                        .of('dash.pack_extremes')
                        .replaceFirst('{n}', '$cellCount'),
                    style: const TextStyle(
                      fontSize: 10, letterSpacing: 0.8, color: Colors.grey,
                    )),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ExtremesStat(
                    label: 'MIN',
                    valueMv: minV.toInt(),
                    cellIndex: minIdx,
                  ),
                ),
                Expanded(
                  child: _ExtremesStat(
                    label: 'MAX',
                    valueMv: maxV.toInt(),
                    cellIndex: maxIdx,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Δ', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      const SizedBox(height: 2),
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w500,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                          children: [
                            TextSpan(text: '$spread', style: TextStyle(color: quality.color)),
                            const TextSpan(text: ' mV',
                                style: TextStyle(fontSize: 11, color: Colors.grey)),
                          ],
                        ),
                      ),
                      Text(quality.label,
                          style: TextStyle(
                            fontSize: 10, color: quality.color, letterSpacing: 0.3,
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ExtremesStat extends StatelessWidget {
  final String label;
  final int valueMv;
  final int? cellIndex;
  const _ExtremesStat({
    required this.label,
    required this.valueMv,
    required this.cellIndex,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 2),
        RichText(
          text: TextSpan(
            style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w500, color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            children: [
              TextSpan(text: '$valueMv'),
              const TextSpan(text: ' mV',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        Text(
          cellIndex != null
              ? S.of('dash.cell_n').replaceFirst('{n}', '$cellIndex')
              : S.of('dash.cell_dash'),
          style: const TextStyle(fontSize: 10, color: Colors.grey, letterSpacing: 0.3),
        ),
      ],
    );
  }
}
