import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';

class CellsScreen extends StatelessWidget {
  const CellsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final cells = svc.liveCells;

    return Scaffold(
      appBar: AppBar(title: const Text('Cells balance')),
      body: cells.isEmpty
          ? const Center(child: Text('Нет данных. Подключитесь и запустите опрос.'))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _SummaryHeader(cells: cells),
                  const SizedBox(height: 24),
                  Expanded(child: _CellsHeatmap(cells: cells)),
                ],
              ),
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
        final color = Color.lerp(
          Colors.blue.shade900,
          Colors.lightBlue.shade300,
          ratio,
        )!;

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
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white)),
              const Text('mV',
                  style: TextStyle(fontSize: 10, color: Colors.white70)),
            ],
          ),
        );
      },
    );
  }
}
