import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/connection.dart';
import 'live_log_results.dart';

/// v0.1.15: Live Log launcher.
///
/// Time-series polling of up to 7 user-selected (TX_ECU, RX_ECU, DID) triples.
/// Unlike Sweep (which probes each DID once across a huge range), Live Log
/// repeatedly polls a small fixed set with each cycle producing one row
/// per DID, so we can correlate values with vehicle behaviour over time.
///
/// UI flow:
///   1. User adds up to 7 DIDs via the form below (TX/RX ECU + DID hex).
///   2. Optional carState + notes annotation.
///   3. Start → progress view (cycle counter, last value per DID, Cancel).
///   4. Cancel or BLE disconnect → finalize session → tap "Open" to view results.
///
/// Sweeps work in any car state. Wakelock keeps screen on for long sessions.
class LiveLogScreen extends StatefulWidget {
  const LiveLogScreen({super.key});

  @override
  State<LiveLogScreen> createState() => _LiveLogScreenState();
}

class _DidEntry {
  String txEcu;
  String rxEcu;
  String did;
  _DidEntry({this.txEcu = '', this.rxEcu = '', this.did = ''});

  bool get isValid =>
      txEcu.length >= 3 && rxEcu.length >= 3 && did.isNotEmpty && did.length <= 4;

  String get label => '$txEcu/$did';
}

class _LiveLogScreenState extends State<LiveLogScreen> {
  // v0.1.17: default DIDs picked for driving observability. VCU 791 closes
  // 0x0038/0039/0101/0104 in motion (observed in livelog #2 — NRC 7F2231
  // for ~99% of cycles), so we default to BMS 790 + one VCU status flag:
  //   - 790/0x0005 SOC%
  //   - 790/0x0015 HV bus voltage (drops on acceleration, rises on regen)
  //   - 790/0x002B / 0x002D cell V min/max (compare under load)
  //   - 791/0x0020 stays accessible in motion (status byte: P=00 D=0C)
  // User can replace any of these via the form.
  final List<_DidEntry> _entries = [
    _DidEntry(txEcu: '790', rxEcu: '798', did: '0005'),
    _DidEntry(txEcu: '790', rxEcu: '798', did: '0015'),
    _DidEntry(txEcu: '790', rxEcu: '798', did: '002B'),
    _DidEntry(txEcu: '790', rxEcu: '798', did: '002D'),
    _DidEntry(txEcu: '791', rxEcu: '799', did: '0020'),
  ];

  final _carStateCtrl = TextEditingController(text: 'driving');
  final _notesCtrl = TextEditingController();

  int? _justFinishedId;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _carStateCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();
    final running = svc.liveLogRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Previous live-log sessions',
            onPressed: running
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const LiveLogSessionListScreen(),
                      ),
                    ),
          ),
        ],
      ),
      body: running ? _buildRunningView(svc) : _buildLauncherView(svc),
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
              const Text('Адаптер не подключен', style: TextStyle(fontSize: 16)),
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

    // v0.1.15: BLE channel mutex with Sweep and DTC scan.
    final busyReason = svc.sweepRunning
        ? 'DID Sweep is currently running'
        : svc.dtcScanRunning
            ? 'DTC scan is currently running'
            : null;
    final canStart = busyReason == null;

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (_justFinishedId != null) ...[
          Card(
            color: Colors.green.shade900.withValues(alpha: 0.3),
            child: ListTile(
              leading:
                  const Icon(Icons.check_circle, color: Colors.greenAccent),
              title: const Text('Live log complete'),
              subtitle: Text('Session #$_justFinishedId'),
              trailing: TextButton(
                child: const Text('Open'),
                onPressed: () {
                  final id = _justFinishedId;
                  setState(() => _justFinishedId = null);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        LiveLogResultsScreen(sessionId: id!),
                  ));
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        _section('DIDs to poll (up to 7)'),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Один цикл = один запрос к каждому DID подряд. С 5 DIDs цикл ~1.2 сек '
            '(~0.8 Hz общая частота). Записи в БД stream-ом — отмена не потеряет '
            'данные.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        ..._entries.asMap().entries.map((e) {
          final idx = e.key;
          final entry = e.value;
          return _DidEntryRow(
            entry: entry,
            onChanged: () => setState(() {}),
            onRemove: _entries.length > 1
                ? () => setState(() => _entries.removeAt(idx))
                : null,
          );
        }),
        if (_entries.length < 7)
          Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: Text('Add DID (${_entries.length}/7)'),
              onPressed: () => setState(
                  () => _entries.add(_DidEntry(txEcu: '791', rxEcu: '799'))),
            ),
          ),
        const Divider(),
        _section('Annotations'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _carStateCtrl,
            decoration: const InputDecoration(
              labelText: 'Car state',
              hintText: 'e.g. driving 60 km/h steady, regen test',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _notesCtrl,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              hintText: 'free-form',
              isDense: true,
            ),
            maxLines: 2,
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.fiber_manual_record, color: Colors.red),
            label: const Text('Start Live Log'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: (canStart && _entries.every((e) => e.isValid))
                ? () => _start(svc)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        if (!canStart)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '$busyReason. Live Log will be available when the other operation finishes.',
              style: const TextStyle(fontSize: 11, color: Colors.orangeAccent),
            ),
          )
        else if (!_entries.every((e) => e.isValid))
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Заполните все поля: TX, RX (3+ hex), DID (1-4 hex, padded автоматически).',
              style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
            ),
          ),
      ],
    );
  }

  Widget _buildRunningView(ConnectionService svc) {
    final lastValues = svc.liveLogLastRaw;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.fiber_manual_record,
                  color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Text(
                'RECORDING — cycle ${svc.liveLogCycle}',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 1.2),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('LATEST VALUES',
              style: TextStyle(
                  fontSize: 11, letterSpacing: 1.5, color: Colors.grey)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: _entries.map((e) {
                final key = '${e.txEcu}/${e.did}';
                final value = lastValues[key];
                return Card(
                  child: ListTile(
                    dense: true,
                    leading: Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                          color: value != null && value.startsWith('62')
                              ? Colors.greenAccent
                              : Colors.grey,
                          shape: BoxShape.circle),
                    ),
                    title: Text('${e.txEcu} → ${e.rxEcu}  ·  0x${e.did}',
                        style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()])),
                    subtitle: Text(
                      value ?? '(no data yet)',
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Colors.grey),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: () => svc.cancelLiveLog(),
          ),
        ],
      ),
    );
  }

  Future<void> _start(ConnectionService svc) async {
    final specs = _entries
        .map((e) => (e.txEcu.toUpperCase(), e.rxEcu.toUpperCase(), e.did.toUpperCase().padLeft(4, '0')))
        .toList();
    final id = await svc.runLiveLog(
      didSpecs: specs,
      carState: _carStateCtrl.text.trim().isEmpty ? null : _carStateCtrl.text.trim(),
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );
    if (!mounted) return;
    if (id != null) {
      setState(() => _justFinishedId = id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось запустить live-log')),
      );
    }
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
}

class _DidEntryRow extends StatefulWidget {
  final _DidEntry entry;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  const _DidEntryRow({
    required this.entry,
    required this.onChanged,
    this.onRemove,
  });

  @override
  State<_DidEntryRow> createState() => _DidEntryRowState();
}

class _DidEntryRowState extends State<_DidEntryRow> {
  late final TextEditingController _txCtrl;
  late final TextEditingController _rxCtrl;
  late final TextEditingController _didCtrl;

  @override
  void initState() {
    super.initState();
    _txCtrl = TextEditingController(text: widget.entry.txEcu);
    _rxCtrl = TextEditingController(text: widget.entry.rxEcu);
    _didCtrl = TextEditingController(text: widget.entry.did);
  }

  @override
  void dispose() {
    _txCtrl.dispose();
    _rxCtrl.dispose();
    _didCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hexFilter = FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Fa-f]'));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: _txCtrl,
                decoration: const InputDecoration(
                  labelText: 'TX',
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [hexFilter, LengthLimitingTextInputFormatter(4)],
                onChanged: (v) {
                  widget.entry.txEcu = v.toUpperCase();
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _rxCtrl,
                decoration: const InputDecoration(
                  labelText: 'RX',
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [hexFilter, LengthLimitingTextInputFormatter(4)],
                onChanged: (v) {
                  widget.entry.rxEcu = v.toUpperCase();
                  widget.onChanged();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _didCtrl,
                decoration: const InputDecoration(
                  labelText: 'DID',
                  hintText: '0000',
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [hexFilter, LengthLimitingTextInputFormatter(4)],
                onChanged: (v) {
                  // Store as user typed; pad to 4 only when starting session.
                  widget.entry.did = v.toUpperCase();
                  widget.onChanged();
                },
              ),
            ),
            if (widget.onRemove != null)
              IconButton(
                icon: const Icon(Icons.remove_circle_outline,
                    color: Colors.redAccent),
                onPressed: widget.onRemove,
              ),
          ],
        ),
      ),
    );
  }
}
