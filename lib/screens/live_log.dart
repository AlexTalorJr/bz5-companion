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

/// v0.1.20: standard UDS request→response ECU address mapping.
///
/// All known BZ5 ECUs follow the convention RX = TX + 8 (i.e. 790→798,
/// 791→799, 740→748). The form previously required the user to update
/// RX manually after changing TX, which was a regular source of mistakes
/// (e.g. leaving rx=799 after changing tx from 791 to 790, producing
/// silent timeouts that looked like missing DIDs).
///
/// Returns null if [tx] is too short or doesn't parse as hex — caller
/// should leave the existing RX value untouched in that case.
String? _autoRxForTx(String tx) {
  if (tx.length < 3) return null;
  final clean = tx.toUpperCase();
  final n = int.tryParse(clean, radix: 16);
  if (n == null) return null;
  final rx = n + 8;
  // Match TX width: 3-char TX → 3-char RX, 4-char → 4-char.
  final width = clean.length;
  return rx.toRadixString(16).toUpperCase().padLeft(width, '0');
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

  /// v0.1.26: apply a built-in preset to the form (entry list + car state
  /// + notes). Used by the preset chips above the DID list.
  void _applyPreset(_LivelogPreset preset) {
    setState(() {
      _entries
        ..clear()
        ..addAll(preset.entries.map((t) =>
            _DidEntry(txEcu: t.$1, rxEcu: t.$2, did: t.$3)));
      _carStateCtrl.text = preset.carState;
      _notesCtrl.text = preset.notes;
    });
  }

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
        // v0.1.26: ready-made presets for the recurring R&E scenarios.
        // Tapping a preset replaces the entire entry list + annotations
        // and forces a setState to redraw form fields. Active during
        // launcher view only; disabled while a session is running.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ActionChip(
                avatar: const Icon(Icons.bolt, size: 16, color: Colors.amberAccent),
                label: const Text('DC Charging Calibration'),
                onPressed: () => _applyPreset(_LivelogPreset.dcCharging),
              ),
              ActionChip(
                avatar: const Icon(Icons.power, size: 16, color: Colors.lightGreenAccent),
                label: const Text('Charge-state hunt'),
                onPressed: () => _applyPreset(_LivelogPreset.chargeStateHunt),
              ),
              ActionChip(
                avatar: const Icon(Icons.directions_car, size: 16),
                label: const Text('Default driving'),
                onPressed: () => _applyPreset(_LivelogPreset.defaultDriving),
              ),
              ActionChip(
                avatar: const Icon(Icons.gps_fixed, size: 16),
                label: const Text('GPS in motion'),
                onPressed: () => _applyPreset(_LivelogPreset.gpsInMotion),
              ),
            ],
          ),
        ),
        ..._entries.asMap().entries.map((e) {
          final idx = e.key;
          final entry = e.value;
          // v0.1.26+5 fix: ObjectKey ties row's State to a specific
          // _DidEntry instance. When _applyPreset() rebuilds _entries
          // with brand-new instances, Flutter sees the keys changed,
          // disposes old States and creates fresh ones — so the
          // late-initialised controllers pick up the new tx/rx/did
          // values via initState. Without this, controllers stayed
          // pinned to whatever the user (or previous preset) had typed,
          // even though _entries had been replaced.
          return _DidEntryRow(
            key: ObjectKey(entry),
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
    super.key,
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
                  final upper = v.toUpperCase();
                  widget.entry.txEcu = upper;
                  // v0.1.20: auto-derive RX = TX + 8 (standard UDS convention)
                  // so user doesn't have to update both. They can still
                  // override RX manually after if needed — we only fire this
                  // on TX change, not on every keystroke in the RX field.
                  final autoRx = _autoRxForTx(upper);
                  if (autoRx != null && autoRx != _rxCtrl.text) {
                    _rxCtrl.text = autoRx;
                    widget.entry.rxEcu = autoRx;
                  }
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

/// v0.1.26: built-in Live Log preset.
///
/// Each preset bundles a fixed DID list + matching car-state hint + notes,
/// surfaced as a chip above the form so the user can fill the form in one
/// tap rather than typing 7 hex addresses correctly each time.
///
/// Stored as (TX_ECU, RX_ECU, DID) records so the entry list mirrors
/// _DidEntry's structure exactly.
enum _LivelogPreset {
  /// DC fast-charge calibration session — captures all DIDs needed to
  /// validate the 0x0B00 charge counter scale, watch CC→CV transition,
  /// and track cell V / pack temp during high-power charging.
  dcCharging,

  /// v0.1.26+4: hunt for a direct "charge cable connected" DID via
  /// plug/unplug toggle on home AC charger. Runs 7 candidate DIDs in
  /// parallel with 0x0B00 counter + 1FFD precise SOC as ground truth.
  /// User toggles plug 3–5× with ~30s on / 10s off; the DID that flips
  /// synchronously with their actions is the direct charge-connected
  /// signal (replaces or augments the counter-rate detection).
  chargeStateHunt,

  /// Recreates the v0.1.17 driving-defaults entry list (BMS 790 +
  /// VCU 791 status). Useful for in-motion observability when the user
  /// has just applied a different preset and wants the default back.
  defaultDriving,

  /// GPS Asensing 757 + speed cross-check. Goal: see whether the GPS
  /// module emits live lat/lon once the car is moving + IMU fuses
  /// dead-reckoning. If 0120/0121/0122 stay null in motion, escalate
  /// to ECU discovery. See handoff doc → pending sweeps.
  gpsInMotion,
}

extension _LivelogPresetX on _LivelogPreset {
  /// (TX, RX, DID) triples populating the form entry list.
  List<(String, String, String)> get entries => switch (this) {
        _LivelogPreset.dcCharging => const [
            ('790', '798', '1FFD'), // Precise SOC (0.01% resolution)
            ('790', '798', '0015'), // HV bus
            ('790', '798', '0B00'), // Charge counter — KEY for scale calibration
            ('790', '798', '002B'), // Min cell V (mV)
            ('790', '798', '002D'), // Max cell V (mV)
            ('790', '798', '002F'), // Battery temp (°C, offset -40)
            ('782', '78A', '000C'), // Max charge current setpoint — catches CC→CV
          ],
        _LivelogPreset.chargeStateHunt => const [
            // Suspected direct charge-connected DIDs to verify by plug/unplug
            // toggle. The one(s) that flip synchronously with cable
            // connect/disconnect events become the new primary detection.
            ('791', '799', '0099'), // suspected ★★ — 0/1/2 (Off/AC/DC?)
            ('791', '799', '0016'), // "Mode" — unknown semantics, worth watching
            ('782', '78A', '0006'), // Charge V target — station dictates on plug-in
            ('782', '78A', '000C'), // Charge I max — same
            ('782', '78A', '0008'), // OBC temp — should rise on AC charging
            ('790', '798', '0B00'), // Counter — ground truth (rises = real charging)
            ('790', '798', '1FFD'), // Precise SOC — extra ground truth
          ],
        _LivelogPreset.defaultDriving => const [
            ('790', '798', '0005'),
            ('790', '798', '0015'),
            ('790', '798', '002B'),
            ('790', '798', '002D'),
            ('791', '799', '0020'),
          ],
        _LivelogPreset.gpsInMotion => const [
            ('757', '75F', '0120'), // GPS data slot 1 (null when parked)
            ('757', '75F', '0121'), // GPS data slot 2
            ('757', '75F', '0122'), // GPS data slot 3
            ('740', '748', '0008'), // Vehicle speed (cross-check)
            ('790', '798', '002F'), // Battery temp (context)
          ],
      };

  String get carState => switch (this) {
        _LivelogPreset.dcCharging => 'DC charging',
        _LivelogPreset.chargeStateHunt => 'AC plug/unplug toggle',
        _LivelogPreset.defaultDriving => 'driving',
        _LivelogPreset.gpsInMotion => 'driving, GPS test',
      };

  String get notes => switch (this) {
        _LivelogPreset.dcCharging => 'DC charging — calibration session',
        _LivelogPreset.chargeStateHunt =>
            'Hunt for direct charge-connected DID. Toggle plug 3–5× with ~30s on / 10s off. Look for a DID flipping synchronously with cable events.',
        _LivelogPreset.defaultDriving => '',
        _LivelogPreset.gpsInMotion =>
            'Looking for live lat/lon in 757/0120-0122 with motion + IMU fusion',
      };
}
