import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/connection.dart';
import '../services/locale_service.dart';

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
        SnackBar(content: Text(S.of('dtc.not_connected'))),
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
      SnackBar(content: Text(S.of('dtc.json_copied'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    // v0.1.29+60: re-render on language switch (per-screen subscription).
    context.watch<LocaleService>();
    return Scaffold(
      appBar: AppBar(
        title: Text(S.of('dtc.title')),
        actions: [
          if (_results != null && !_running)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: S.of('dtc.copy_json'),
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
                      Text(S.of('dtc.scan_hdr'),
                          style: const TextStyle(
                              fontSize: 12,
                              letterSpacing: 1.5,
                              color: Colors.grey)),
                      Text(
                        running
                            ? S
                                .of('dtc.scanning_cur')
                                .replaceFirst('{cur}', progressCurrent)
                            : (hasResults
                                ? S
                                    .of('dtc.last_scan')
                                    .replaceFirst(
                                        '{t}', _formatTime(lastScanAt))
                                : S.of('dtc.scan_desc')),
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
                      ? S.of('dtc.scanning')
                      : (hasResults
                          ? S.of('dtc.run_again')
                          : S.of('dtc.run_scan'))),
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
              Text(
                  S
                      .of('dtc.progress')
                      .replaceFirst('{a}', '$progressDone')
                      .replaceFirst('{b}', '$progressTotal'),
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
      title = S.of('dtc.active_found').replaceFirst('{n}', '$activeFaults');
    } else if (totalDtcs > 0) {
      color = Colors.lightBlueAccent;
      icon = Icons.info_outline;
      title = S.of('dtc.clean_no_active');
    } else {
      color = Colors.green;
      icon = Icons.check_circle;
      title = S.of('dtc.all_clean');
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
                  S
                      .of('dtc.summary')
                      .replaceFirst('{e}', '${results.length}')
                      .replaceFirst('{a}', '$activeFaults')
                      .replaceFirst('{r}', '$readinessFlags')
                      .replaceFirst('{i}', '$ecusWithIssues'),
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
        ? S.of('dtc.n_active').replaceFirst('{n}', '${result.activeFaultCount}')
        : result.dtcs.isNotEmpty
            ? S
                .of('dtc.n_readiness')
                .replaceFirst('{n}', '${result.dtcs.length}')
            : result.errors.isNotEmpty
                ? S.of('dtc.probe_error')
                : S.of('dtc.clean');

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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber,
                      size: 14, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(
                    S.of('dtc.ext_session'),
                    style: const TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                ],
              ),
            ),
          if (result.dtcs.isEmpty && result.errors.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(S.of('dtc.no_dtc'),
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
            Text(S.of('dtc.tap_run'),
                style: const TextStyle(fontSize: 15, color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              S.of('dtc.scan_takes'),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.of('dtc.flags_hdr'),
                      style: const TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.0,
                          color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.error_outline,
                        size: 14, color: Colors.red),
                    const SizedBox(width: 6),
                    Text(S.of('dtc.flag_active'),
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.flag_outlined,
                        size: 14, color: Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(S.of('dtc.flag_readiness'),
                          style: const TextStyle(fontSize: 12)),
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
