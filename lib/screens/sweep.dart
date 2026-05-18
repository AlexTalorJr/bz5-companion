import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/connection.dart';
import 'sweep_results.dart';

/// v0.1.14: In-car DID sweep launcher.
///
/// Replaces the CLI sweep workflow with a fully in-app one — pick a preset
/// (or fill the Custom form), run, watch progress, cancel if needed. Results
/// stream into the SweepRuns + SweepResults tables and can be exported via
/// the standard Data & Export screen.
///
/// Sweeps work in any car state. If running while driving, hand the device
/// to a passenger. The screen keeps the display awake (wakelock_plus) so
/// the bus doesn't drop mid-scan.
///
/// One active sweep at a time. Cancel takes effect within ~1 probe period.
class SweepScreen extends StatefulWidget {
  const SweepScreen({super.key});

  @override
  State<SweepScreen> createState() => _SweepScreenState();
}

class _SweepPreset {
  final String name;
  final String description;
  final String txEcu;
  final String rxEcu;
  final String startDid;
  final String endDid;
  const _SweepPreset({
    required this.name,
    required this.description,
    required this.txEcu,
    required this.rxEcu,
    required this.startDid,
    required this.endDid,
  });
}

class _SweepScreenState extends State<SweepScreen> {
  static const _presets = <_SweepPreset>[
    _SweepPreset(
      name: 'VCU full',
      description: '791 — Vehicle Control Unit, 0x0000..0x1FFF (8192 DIDs, ~55 min)',
      txEcu: '791',
      rxEcu: '799',
      startDid: '0000',
      endDid: '1FFF',
    ),
    _SweepPreset(
      name: 'VCU narrow',
      description: '791 — VCU, 0x0000..0x01FF (512 DIDs, ~3.5 min)',
      txEcu: '791',
      rxEcu: '799',
      startDid: '0000',
      endDid: '01FF',
    ),
    _SweepPreset(
      name: 'BMS Master full',
      description: '790 — BMS Master, 0x0000..0x1FFF (~55 min)',
      txEcu: '790',
      rxEcu: '798',
      startDid: '0000',
      endDid: '1FFF',
    ),
    _SweepPreset(
      name: 'BMS Master mid',
      description: '790 — BMS Master, 0x0000..0x0FFF (4096 DIDs, ~27 min) — '
          'driving sweep range, matches VCU mid for comparison',
      txEcu: '790',
      rxEcu: '798',
      startDid: '0000',
      endDid: '0FFF',
    ),
    _SweepPreset(
      name: 'BMS Master narrow',
      description: '790 — BMS Master, 0x0000..0x01FF (~3.5 min)',
      txEcu: '790',
      rxEcu: '798',
      startDid: '0000',
      endDid: '01FF',
    ),
    _SweepPreset(
      name: 'PDU / HV Junction',
      description: '740, 0x0000..0x00FF (256 DIDs, ~2 min) — '
          'pack nominal constants + PDU temps',
      txEcu: '740',
      rxEcu: '748',
      startDid: '0000',
      endDid: '00FF',
    ),
    _SweepPreset(
      name: 'OBC',
      description: '782 — On-Board Charger, 0x0000..0x00FF (~2 min)',
      txEcu: '782',
      rxEcu: '78A',
      startDid: '0000',
      endDid: '00FF',
    ),
    _SweepPreset(
      name: 'BMS Slaves',
      description: '752/753 — BMS slave packs, 0x0000..0x00FF (sequential)',
      txEcu: '752',
      rxEcu: '75A',
      startDid: '0000',
      endDid: '00FF',
    ),
    _SweepPreset(
      name: 'GPS Asensing',
      description: '757 — GPS module, 0x0000..0x00FF (~2 min)',
      txEcu: '757',
      rxEcu: '75F',
      startDid: '0000',
      endDid: '00FF',
    ),
  ];

  // Form state (Custom)
  final _txCtrl = TextEditingController(text: '791');
  final _rxCtrl = TextEditingController(text: '799');
  final _startCtrl = TextEditingController(text: '0000');
  final _endCtrl = TextEditingController(text: '01FF');
  final _carStateCtrl = TextEditingController(text: 'P+Ready, AC off');
  final _notesCtrl = TextEditingController();

  bool _customExpanded = false;

  // Local UI state for the "just finished" navigation prompt
  int? _justFinishedRunId;

  @override
  void initState() {
    super.initState();
    // Keep screen on during sweeps
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _txCtrl.dispose();
    _rxCtrl.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    _carStateCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final running = svc.sweepRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('DID Sweep'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Previous sweep runs',
            onPressed: running
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SweepRunListScreen(),
                      ),
                    ),
          ),
        ],
      ),
      body: running ? _buildProgressView(svc) : _buildLauncherView(svc),
    );
  }

  Widget _buildProgressView(ConnectionService svc) {
    final pct = (svc.sweepProgress * 100).toStringAsFixed(1);
    // Rough ETA: remaining DIDs * 280ms (probe ~250ms + spacing 30ms)
    final remaining = svc.sweepTotal - svc.sweepDone;
    final etaSec = (remaining * 0.4).round();
    final etaStr = _fmtEta(etaSec);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Icon(Icons.search, size: 64, color: Colors.lightBlueAccent),
          const SizedBox(height: 16),
          const Text('Sweep in progress',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w300, letterSpacing: 1.5)),
          const SizedBox(height: 24),
          LinearProgressIndicator(
            value: svc.sweepProgress,
            minHeight: 8,
            backgroundColor: Colors.grey.shade800,
            valueColor: const AlwaysStoppedAnimation(Colors.lightBlueAccent),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${svc.sweepDone} / ${svc.sweepTotal}',
                  style: const TextStyle(
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()])),
              Text('$pct %',
                  style: const TextStyle(
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()])),
              Text('ETA $etaStr',
                  style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 24),
          Card(
            color: Colors.black.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('CURRENT DID',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text('0x${svc.sweepCurrentDid}',
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w300,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
            ),
          ),
          const Spacer(),
          ElevatedButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Cancel sweep'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: () => svc.cancelSweep(),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildLauncherView(ConnectionService svc) {
    if (svc.status != ConnectionStatus.connected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bluetooth_disabled,
                  size: 56, color: Colors.grey.shade600),
              const SizedBox(height: 16),
              const Text('Адаптер не подключен',
                  style: TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              Text(
                'Подключитесь к ELM327 через Settings → ELM327 BLE adapter.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      );
    }

    // v0.1.15: BLE channel mutex — refuse if Live Log or DTC scan running.
    final busyReason = svc.liveLogRunning
        ? 'Live Log is currently running'
        : svc.dtcScanRunning
            ? 'DTC scan is currently running'
            : null;

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (busyReason != null) ...[
          Card(
            color: Colors.orange.shade900.withValues(alpha: 0.3),
            child: ListTile(
              leading:
                  const Icon(Icons.lock_outline, color: Colors.orangeAccent),
              title: Text(busyReason),
              subtitle: const Text(
                  'Sweep will be available when the other operation finishes.'),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_justFinishedRunId != null) ...[
          Card(
            color: Colors.green.shade900.withValues(alpha: 0.3),
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.greenAccent),
              title: const Text('Sweep complete'),
              subtitle: Text('Run #$_justFinishedRunId'),
              trailing: TextButton(
                child: const Text('Open'),
                onPressed: () {
                  final runId = _justFinishedRunId;
                  setState(() => _justFinishedRunId = null);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SweepResultsScreen(runId: runId!),
                  ));
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        _section('Presets'),
        ..._presets.map((p) => _PresetTile(
              preset: p,
              onTap: busyReason == null
                  ? () => _confirmAndStart(svc, p)
                  : null,
            )),
        const Divider(),
        _section('Custom'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _txCtrl,
                        decoration: const InputDecoration(
                          labelText: 'TX ECU (hex)',
                          hintText: '791',
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                          LengthLimitingTextInputFormatter(4),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _rxCtrl,
                        decoration: const InputDecoration(
                          labelText: 'RX ECU (hex)',
                          hintText: '799',
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                          LengthLimitingTextInputFormatter(4),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _startCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Start DID (hex)',
                          hintText: '0000',
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                          LengthLimitingTextInputFormatter(4),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _endCtrl,
                        decoration: const InputDecoration(
                          labelText: 'End DID (hex)',
                          hintText: '01FF',
                          isDense: true,
                        ),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]')),
                          LengthLimitingTextInputFormatter(4),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _carStateCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Car state (optional)',
                    hintText: 'P+Ready, AC off',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    hintText: 'e.g. baseline before drive sweep',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start custom sweep'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: busyReason == null ? () => _startCustom(svc) : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(title,
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: Colors.grey,
                fontWeight: FontWeight.w500)),
      );

  Future<void> _confirmAndStart(
      ConnectionService svc, _SweepPreset preset) async {
    final start = int.parse(preset.startDid, radix: 16);
    final end = int.parse(preset.endDid, radix: 16);
    final total = end - start + 1;
    final etaSec = (total * 0.4).round();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(preset.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preset.description),
            const SizedBox(height: 12),
            Text('TX: ${preset.txEcu} → RX: ${preset.rxEcu}'),
            Text('Range: 0x${preset.startDid} .. 0x${preset.endDid} '
                '($total DIDs)'),
            Text('ETA: ~${_fmtEta(etaSec)}'),
            const SizedBox(height: 12),
            const Text(
              'Normal polling will be paused during the sweep. '
              'Screen stays awake. Cancel anytime.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Start'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runAndAwait(
      svc,
      txEcu: preset.txEcu,
      rxEcu: preset.rxEcu,
      startDid: preset.startDid,
      endDid: preset.endDid,
      carState: _carStateCtrl.text.trim().isEmpty ? null : _carStateCtrl.text.trim(),
      notes: 'preset: ${preset.name}',
    );
  }

  Future<void> _startCustom(ConnectionService svc) async {
    final tx = _txCtrl.text.trim().toUpperCase();
    final rx = _rxCtrl.text.trim().toUpperCase();
    final startDid = _startCtrl.text.trim().toUpperCase().padLeft(4, '0');
    final endDid = _endCtrl.text.trim().toUpperCase().padLeft(4, '0');

    if (tx.isEmpty || rx.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TX и RX обязательны')),
      );
      return;
    }
    final s = int.tryParse(startDid, radix: 16);
    final e = int.tryParse(endDid, radix: 16);
    if (s == null || e == null || e < s) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Некорректный диапазон DID')),
      );
      return;
    }

    await _runAndAwait(
      svc,
      txEcu: tx,
      rxEcu: rx,
      startDid: startDid,
      endDid: endDid,
      carState: _carStateCtrl.text.trim().isEmpty ? null : _carStateCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );
  }

  Future<void> _runAndAwait(
    ConnectionService svc, {
    required String txEcu,
    required String rxEcu,
    required String startDid,
    required String endDid,
    String? carState,
    String? notes,
  }) async {
    final runId = await svc.runSweep(
      txEcu: txEcu,
      rxEcu: rxEcu,
      startDidHex: startDid,
      endDidHex: endDid,
      carState: carState,
      notes: notes,
    );
    if (!mounted) return;
    if (runId != null) {
      setState(() => _justFinishedRunId = runId);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось запустить sweep')),
      );
    }
  }

  String _fmtEta(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m ${s}s';
    final h = m ~/ 60;
    return '${h}h ${m % 60}m';
  }
}

class _PresetTile extends StatelessWidget {
  final _SweepPreset preset;
  final VoidCallback? onTap;
  const _PresetTile({required this.preset, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Card(
      child: ListTile(
        leading: Icon(Icons.flash_on,
            color: enabled ? Colors.lightBlueAccent : Colors.grey),
        title: Text(preset.name,
            style: TextStyle(color: enabled ? null : Colors.grey)),
        subtitle: Text(preset.description,
            style: TextStyle(
                fontSize: 12,
                color: enabled ? null : Colors.grey.shade700)),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: onTap,
        enabled: enabled,
      ),
    );
  }
}
