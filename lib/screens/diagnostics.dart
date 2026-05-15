import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';

/// v0.1.7: Diagnostics / DTC reader screen.
///
/// Reads diagnostic trouble codes from all known ECUs via UDS service 0x19.
/// Read-only by design — no clear/erase functionality in this release.
/// Displays results grouped by ECU with status decoding.
///
/// Accessible from Settings → "Diagnostics (DTC)".
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DtcScanEcuResult>? _results;
  bool _running = false;
  int _progressDone = 0;
  int _progressTotal = 0;
  String _progressCurrent = '';
  DateTime? _lastScanAt;

  Future<void> _runScan() async {
    final svc = context.read<ConnectionService>();
    if (svc.status != ConnectionStatus.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Не подключено. Подключите адаптер в Settings.')),
      );
      return;
    }
    setState(() {
      _running = true;
      _results = null;
      _progressDone = 0;
      _progressTotal = 0;
      _progressCurrent = '';
    });
    final results = await svc.runDtcScan(
      onProgress: (done, total, name) {
        if (!mounted) return;
        setState(() {
          _progressDone = done;
          _progressTotal = total;
          _progressCurrent = name;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _running = false;
      _lastScanAt = DateTime.now();
    });
  }

  Future<void> _copyJson() async {
    if (_results == null) return;
    final asJson = jsonEncode(_results!
        .map((e) => {
              'tx': e.tx,
              'rx': e.rx,
              'name': e.name,
              'session_ok': e.sessionOk,
              'dtcs': e.dtcs
                  .map((d) => {
                        'code': d.code,
                        'code_full': d.codeFull,
                        'raw': d.rawHex,
                        'status': d.status,
                        'status_summary': d.statusSummary,
                      })
                  .toList(),
              'errors': e.errors,
            })
        .toList());
    await Clipboard.setData(ClipboardData(text: asJson));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('JSON скопирован в буфер обмена')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics (DTC)'),
        actions: [
          if (_results != null && !_running)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy JSON',
              onPressed: _copyJson,
            ),
        ],
      ),
      body: Column(
        children: [
          _ScanControlCard(
            running: _running,
            progressDone: _progressDone,
            progressTotal: _progressTotal,
            progressCurrent: _progressCurrent,
            lastScanAt: _lastScanAt,
            onRun: _runScan,
            hasResults: _results != null,
          ),
          if (_results != null) _SummaryBanner(results: _results!),
          Expanded(
            child: _results == null
                ? const _EmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _results!.length,
                    itemBuilder: (context, i) =>
                        _EcuResultTile(result: _results![i]),
                  ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Components ──────────────────────────────────

class _ScanControlCard extends StatelessWidget {
  final bool running;
  final int progressDone;
  final int progressTotal;
  final String progressCurrent;
  final DateTime? lastScanAt;
  final VoidCallback onRun;
  final bool hasResults;

  const _ScanControlCard({
    required this.running,
    required this.progressDone,
    required this.progressTotal,
    required this.progressCurrent,
    required this.lastScanAt,
    required this.onRun,
    required this.hasResults,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.medical_information,
                    color: Colors.lightBlueAccent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('DTC SCAN',
                          style: TextStyle(
                              fontSize: 12,
                              letterSpacing: 1.5,
                              color: Colors.grey)),
                      Text(
                        running
                            ? 'Сканирую: $progressCurrent'
                            : (hasResults
                                ? 'Last scan: ${_formatTime(lastScanAt)}'
                                : 'Считать коды ошибок с 9 ECU. Read-only.'),
                        style: const TextStyle(
                            fontSize: 13, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: running ? null : onRun,
                  icon: running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Icon(hasResults ? Icons.refresh : Icons.play_arrow),
                  label: Text(running
                      ? 'Сканирую…'
                      : (hasResults ? 'Run again' : 'Run scan')),
                ),
              ],
            ),
            if (running && progressTotal > 0) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progressDone / progressTotal,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 4),
              Text('$progressDone / $progressTotal ECU',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime? t) {
    if (t == null) return '—';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class _SummaryBanner extends StatelessWidget {
  final List<DtcScanEcuResult> results;
  const _SummaryBanner({required this.results});

  @override
  Widget build(BuildContext context) {
    final activeFaults =
        results.fold<int>(0, (sum, r) => sum + r.activeFaultCount);
    final totalDtcs = results.fold<int>(0, (sum, r) => sum + r.totalDtcCount);
    final readinessFlags = totalDtcs - activeFaults;
    final ecusWithIssues =
        results.where((r) => r.totalDtcCount > 0 || r.errors.isNotEmpty).length;

    final Color color;
    final String title;
    final IconData icon;
    if (activeFaults > 0) {
      color = Colors.red;
      icon = Icons.error;
      title = '$activeFaults active fault(s) found';
    } else if (totalDtcs > 0) {
      color = Colors.lightBlueAccent;
      icon = Icons.info_outline;
      title = 'Clean (no active faults)';
    } else {
      color = Colors.green;
      icon = Icons.check_circle;
      title = 'All ECUs clean';
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: color)),
                const SizedBox(height: 2),
                Text(
                  '${results.length} ECU scanned · '
                  '$activeFaults active · '
                  '$readinessFlags readiness · '
                  '$ecusWithIssues with entries',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EcuResultTile extends StatelessWidget {
  final DtcScanEcuResult result;
  const _EcuResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final Color statusColor;
    if (result.activeFaultCount > 0) {
      statusColor = Colors.red;
    } else if (result.dtcs.isNotEmpty) {
      statusColor = Colors.lightBlueAccent;
    } else if (result.errors.isNotEmpty) {
      statusColor = Colors.orange;
    } else {
      statusColor = Colors.green;
    }

    final statusText = result.activeFaultCount > 0
        ? '${result.activeFaultCount} active fault(s)'
        : result.dtcs.isNotEmpty
            ? '${result.dtcs.length} readiness flags'
            : result.errors.isNotEmpty
                ? 'probe error'
                : 'clean';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        title: Text(
          '${result.tx} · ${result.name}',
          style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              fontFeatures: [FontFeature.tabularFigures()]),
        ),
        subtitle: Text(
          statusText,
          style: TextStyle(fontSize: 12, color: statusColor),
        ),
        children: [
          if (!result.sessionOk)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                  SizedBox(width: 8),
                  Text(
                    'Extended session не открыта',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ],
              ),
            ),
          if (result.dtcs.isEmpty && result.errors.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Нет DTC',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            )
          else ...[
            ...result.dtcs.map((d) => _DtcRow(dtc: d)),
            if (result.errors.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Errors:',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ...result.errors.map((e) => Padding(
                          padding: const EdgeInsets.only(left: 8, top: 2),
                          child: Text('• $e',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.orange)),
                        )),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _DtcRow extends StatelessWidget {
  final DtcRecord dtc;
  const _DtcRow({required this.dtc});

  @override
  Widget build(BuildContext context) {
    final isActive = dtc.isActiveFault;
    final color = isActive ? Colors.red : Colors.grey.shade400;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isActive ? Icons.error_outline : Icons.flag_outlined,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              dtc.code,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: color),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dtc.statusSummary,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                Text(
                  'status 0x${dtc.status.toRadixString(16).padLeft(2, "0").toUpperCase()} · raw ${dtc.rawHex}',
                  style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade500,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.medical_services_outlined,
                size: 56, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            const Text('Tap "Run scan" to read DTCs',
                style: TextStyle(fontSize: 15, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              'Сканирование занимает ~30 секунд. Polling приостанавливается '
              'на время скана, чтобы не нагружать BLE.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Status flags meaning:',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.0,
                          color: Colors.grey)),
                  SizedBox(height: 8),
                  Row(children: [
                    Icon(Icons.error_outline, size: 14, color: Colors.red),
                    SizedBox(width: 6),
                    Text('Active fault — реальная ошибка прямо сейчас',
                        style: TextStyle(fontSize: 12)),
                  ]),
                  SizedBox(height: 4),
                  Row(children: [
                    Icon(Icons.flag_outlined, size: 14, color: Colors.grey),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          'Readiness — тест ещё не выполнен (не fault)',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
