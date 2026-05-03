import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';

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
    final cells = svc.liveCells;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cells balance'),
        actions: [
          // Сегментированный переключатель режима
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Cells')),
                ButtonSegment(value: 1, label: Text('Thermal')),
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
      body: cells.isEmpty
          ? const Center(child: Text('Нет данных. Подключитесь и запустите опрос.'))
          : (_mode == 0 ? _CellsView(cells: cells) : _ThermalView(svc: svc)),
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
    final balanceQuality = spread <= 20 ? 'Excellent' : spread <= 50 ? 'Good' : spread <= 100 ? 'Fair' : 'Poor';
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
            Text('Balance: $balanceQuality',
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
        spreadLabel = ' — even';
      } else if (delta <= 5) {
        spreadColor = Colors.lightGreen;
        spreadLabel = ' — normal';
      } else if (delta <= 10) {
        spreadColor = Colors.orange;
        spreadLabel = ' — uneven';
      } else {
        spreadColor = Colors.red;
        spreadLabel = ' — check cooling';
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
                label: 'SPREAD Δ',
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
                  children: const [
                    Text('10 MODULES (20 measurement points)',
                        style: TextStyle(fontSize: 10, letterSpacing: 0.5, color: Colors.grey)),
                    Spacer(),
                    Text('VOLT mV · TEMP °C',
                        style: TextStyle(fontSize: 9, letterSpacing: 0.3, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 10),
                ...modules.map((m) => _ModuleRow(
                      module: m,
                      tempRange: reportedTemps.isEmpty ? null : reportedTemps,
                    )),
              ],
            ),
          ),
        ),
      ],
    );
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
  const _ModuleRow({required this.module, this.tempRange});

  @override
  Widget build(BuildContext context) {
    final temp = module.avgTemp;
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
    if (temp != null && tempRange != null && tempRange!.isNotEmpty) {
      final tmin = tempRange!.reduce((a, b) => a < b ? a : b);
      final tmax = tempRange!.reduce((a, b) => a > b ? a : b);
      if (tmax - tmin > 0.5) {
        final ratio = ((temp - tmin) / (tmax - tmin)).clamp(0.0, 1.0);
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
            child: Container(
              height: 16,
              decoration: BoxDecoration(
                color: module.hasAnyTemp ? Colors.grey.shade800 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: module.hasAnyTemp
                    ? null
                    : Border.all(color: Colors.grey.shade700, style: BorderStyle.solid, width: 1),
              ),
              child: Stack(
                children: [
                  if (module.hasAnyTemp)
                    Container(
                      decoration: BoxDecoration(
                        color: tempBarColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: tempText != null
                          ? Text(tempText,
                              style: TextStyle(
                                fontSize: 11,
                                color: tempBarColor.computeLuminance() > 0.4
                                    ? const Color(0xFF1a0a00)
                                    : Colors.white,
                                fontWeight: FontWeight.w500,
                              ))
                          : Text(
                              'temp not reported',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade500,
                                letterSpacing: 0.3,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
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
