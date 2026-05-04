import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/ecu_registry.dart';
import '../../services/connection.dart';

/// v0.1.4: Raw Data screen for head unit.
///
/// Layout: ECU selector (left rail ~200dp) + live DID table (right pane).
/// Replaces the old phone-only EcuExplorer for head unit users — denser,
/// realtime-updating, and includes a Diagnostics card for one-shot sweeps.
///
/// Diagnostics sweep is locked to gear=P (parking) — running a multi-minute
/// sweep during driving would saturate the BLE bus and cripple realtime
/// monitoring. Lock can be bypassed only when gear is P or stationary states.
class RawDataWideScreen extends StatefulWidget {
  const RawDataWideScreen({super.key});

  @override
  State<RawDataWideScreen> createState() => _RawDataWideScreenState();
}

class _RawDataWideScreenState extends State<RawDataWideScreen> {
  // Currently selected ECU TX address. We hard-code the known ones from
  // reverse engineering — these match the EcuSpec set defined elsewhere.
  String _selectedTx = '790';

  static const _knownEcus = [
    _EcuInfo(tx: '790', rx: '798', name: 'BMS Master', subtitle: 'cells, SOC, pack stats'),
    _EcuInfo(tx: '791', rx: '799', name: 'VCU', subtitle: 'gear, odometer, parking'),
    _EcuInfo(tx: '740', rx: '748', name: 'Pack Monitor', subtitle: 'pack voltage'),
    _EcuInfo(tx: '782', rx: '78A', name: 'OBC', subtitle: 'on-board charger'),
    _EcuInfo(tx: '752', rx: '75A', name: 'BMS Slave 1', subtitle: 'sub-pack'),
    _EcuInfo(tx: '753', rx: '75B', name: 'BMS Slave 2', subtitle: 'sub-pack'),
  ];

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final connected = svc.status == ConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(title: const Text('Raw Data')),
      body: !connected
          ? const Center(
              child: Text(
                'Адаптер не подключен',
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ECU list (left rail)
                  SizedBox(
                    width: 240,
                    child: _EcuListPanel(
                      ecus: _knownEcus,
                      selectedTx: _selectedTx,
                      svc: svc,
                      onSelect: (tx) => setState(() => _selectedTx = tx),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Right pane: DID table + diagnostics card
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 5,
                          child: _DidTablePanel(
                            ecuTx: _selectedTx,
                            ecuName: _knownEcus
                                .firstWhere((e) => e.tx == _selectedTx,
                                    orElse: () => _knownEcus.first)
                                .name,
                            svc: svc,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          flex: 2,
                          child: _DiagnosticsPanel(svc: svc),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _EcuInfo {
  final String tx;
  final String rx;
  final String name;
  final String subtitle;
  const _EcuInfo({
    required this.tx,
    required this.rx,
    required this.name,
    required this.subtitle,
  });
}

// ──────────────────────────── ECU list panel ───────────────────────────────

class _EcuListPanel extends StatelessWidget {
  final List<_EcuInfo> ecus;
  final String selectedTx;
  final ConnectionService svc;
  final ValueChanged<String> onSelect;
  const _EcuListPanel({
    required this.ecus,
    required this.selectedTx,
    required this.svc,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text('ECU MODULES',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      color: Colors.grey)),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: ecus.length,
                itemBuilder: (context, i) {
                  final e = ecus[i];
                  final selected = e.tx == selectedTx;
                  // Live indicator: do we have any data for this ECU?
                  final dataMap = svc.latestValues[e.tx];
                  final hasData = dataMap != null && dataMap.isNotEmpty;

                  return Material(
                    color: selected
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.18)
                        : Colors.transparent,
                    child: InkWell(
                      onTap: () => onSelect(e.tx),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: hasData ? Colors.greenAccent : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(e.tx,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              fontFeatures: [
                                                FontFeature.tabularFigures()
                                              ])),
                                      const SizedBox(width: 6),
                                      Text(e.name,
                                          style: const TextStyle(fontSize: 13)),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(e.subtitle,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────── DID table panel ──────────────────────────────

class _DidTablePanel extends StatelessWidget {
  final String ecuTx;
  final String ecuName;
  final ConnectionService svc;
  const _DidTablePanel({
    required this.ecuTx,
    required this.ecuName,
    required this.svc,
  });

  @override
  Widget build(BuildContext context) {
    final values = svc.latestValues[ecuTx];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('$ecuTx · $ecuName',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                const Spacer(),
                if (values != null)
                  Text('${values.length} DIDs · live',
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 10),
            // Header row
            const _DidTableHeader(),
            const Divider(height: 16, thickness: 0.5),
            // Body
            Expanded(
              child: values == null || values.isEmpty
                  ? const Center(
                      child: Text(
                        'Нет данных. Polling ещё не достиг этого ECU,\nили он не отвечает.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: values.length,
                      itemBuilder: (context, i) {
                        final entries = values.entries.toList()
                          ..sort((a, b) => a.key.compareTo(b.key));
                        final entry = entries[i];
                        return _DidTableRow(
                          did: entry.key,
                          decoded: entry.value,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DidTableHeader extends StatelessWidget {
  const _DidTableHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        SizedBox(
          width: 90,
          child: Text('DID',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  color: Colors.grey)),
        ),
        Expanded(
          flex: 2,
          child: Text('NUMERIC',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  color: Colors.grey)),
        ),
        Expanded(
          flex: 3,
          child: Text('TEXT',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  color: Colors.grey)),
        ),
      ],
    );
  }
}

class _DidTableRow extends StatelessWidget {
  final String did;
  final DecodedValue decoded;
  const _DidTableRow({required this.did, required this.decoded});

  @override
  Widget build(BuildContext context) {
    final num = decoded.numeric;
    final txt = decoded.text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 90,
            child: Text('0x$did',
                style: const TextStyle(
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: Colors.white70)),
          ),
          Expanded(
            flex: 2,
            child: Text(
              num != null ? _formatNum(num) : '—',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  fontFeatures: [FontFeature.tabularFigures()]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              txt ?? '',
              style:
                  const TextStyle(fontSize: 12, color: Colors.white70),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _formatNum(double n) {
    if (n == n.toInt().toDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

// ─────────────────────────── Diagnostics panel ─────────────────────────────

class _DiagnosticsPanel extends StatelessWidget {
  final ConnectionService svc;
  const _DiagnosticsPanel({required this.svc});

  @override
  Widget build(BuildContext context) {
    final gear = svc.readNumeric('791', '0009');
    final inP = gear != null && gear.toInt() == 1;
    final pawlEngaged = svc.parkingPawlEngaged ?? false;
    final canRun = inP || pawlEngaged;

    return Card(
      color: Colors.grey.shade900,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              canRun ? Icons.science : Icons.lock_outline,
              color: canRun ? Colors.lightBlueAccent : Colors.orange,
              size: 32,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('DIAGNOSTICS',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text(
                    canRun
                        ? 'Run a DID sweep to capture raw responses for analysis. Available while parking.'
                        : 'Locked while driving. Diagnostics sweep saturates BLE for several minutes — engage parking (gear = P) to enable.',
                    style: TextStyle(
                        fontSize: 12,
                        color: canRun ? Colors.white70 : Colors.grey),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            FilledButton.icon(
              onPressed: canRun ? () => _showSoonSnackbar(context) : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run sweep'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSoonSnackbar(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Diagnostics UI coming in next release. '
            'For now use bz5_scanner CLI on Mac.'),
      ),
    );
  }
}
