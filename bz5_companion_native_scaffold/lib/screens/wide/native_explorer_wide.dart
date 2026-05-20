/// Native API Explorer — a debug/probing screen for the head-unit
/// native data channel. Twofold purpose:
///
///   1. **Status & demo**: shows whether the native API is reachable,
///      what VIN was detected, which permissions are granted, and how
///      to recover from common failures.
///
///   2. **Runtime probing tool**: lets the developer type a feature ID
///      (`0x...`) and:
///       - Get a one-shot value
///       - Subscribe to live updates with a small chart strip
///       - Read the property config (data type, permissions)
///      We need this to map feature IDs → semantics (SOC, speed,
///      voltage, etc.) since the proto config has no human names.
///
/// This screen is intentionally not pretty — it's a tool, not a
/// production view. Once we've mapped the high-value features we can
/// hide it behind a Settings toggle.
///
/// Layout: NavigationRail-friendly wide screen, mirroring the
/// existing `*_wide.dart` siblings.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/native_car_channel.dart';
import '../../services/native_detector.dart';

class NativeExplorerWide extends StatefulWidget {
  const NativeExplorerWide({super.key, required this.detector});
  final NativeDetector detector;

  @override
  State<NativeExplorerWide> createState() => _NativeExplorerWideState();
}

class _NativeExplorerWideState extends State<NativeExplorerWide> {
  final _ch = NativeCarChannel.instance;
  final _propController = TextEditingController(text: '0x');

  String? _lastResultText;
  List<PermissionStatus> _perms = const [];
  List<Map<String, Object?>> _dtcRows = const [];

  // Active subscriptions: name → recent N values (cyclic buffer).
  final Map<String, List<_Sample>> _samples = {};
  StreamSubscription<NativeEvent>? _eventSub;
  bool _subscribing = false;

  @override
  void initState() {
    super.initState();
    _refreshPerms();
    _eventSub = _ch.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    // Best-effort cleanup of active subs so we don't leak server-side.
    if (_samples.isNotEmpty) {
      _ch.unsubscribe(_samples.keys.toList());
    }
    _propController.dispose();
    super.dispose();
  }

  Future<void> _refreshPerms() async {
    try {
      final p = await _ch.checkPermissions();
      if (mounted) setState(() => _perms = p);
    } catch (_) {/* ignore — probably no plugin on this device */}
  }

  void _onEvent(NativeEvent e) {
    final buf = _samples[e.name];
    if (buf == null) return;
    buf.add(_Sample(DateTime.now(), e.value, e.type));
    // Keep last 120 samples per property — enough for a small trace.
    if (buf.length > 120) buf.removeAt(0);
    if (mounted) setState(() {});
  }

  // ─── actions ─────────────────────────────────────────────────────

  Future<void> _doGet() async {
    final name = _propController.text.trim();
    if (!_looksValid(name)) {
      _setResult('Invalid name. Expected format: 0x<HEX_FEATURE_ID>');
      return;
    }
    try {
      final r = await _ch.getProperty(name);
      _setResult('GET $name → $r');
    } on PlatformException catch (e) {
      _setResult('GET $name FAILED: ${e.code} ${e.message}');
    }
  }

  Future<void> _doGetConfig() async {
    final name = _propController.text.trim();
    if (!_looksValid(name)) return;
    try {
      final r = await _ch.getPropertyConfig([name]);
      _setResult('CONFIG $name → $r');
    } on PlatformException catch (e) {
      _setResult('CONFIG $name FAILED: ${e.code} ${e.message}');
    }
  }

  Future<void> _doSubscribe() async {
    final name = _propController.text.trim();
    if (!_looksValid(name)) return;
    setState(() => _subscribing = true);
    try {
      await _ch.subscribe([name]);
      _samples.putIfAbsent(name, () => <_Sample>[]);
      _setResult('Subscribed to $name. Events will appear in the trace below.');
    } on PlatformException catch (e) {
      _setResult('SUBSCRIBE $name FAILED: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _subscribing = false);
    }
  }

  Future<void> _doUnsubscribe(String name) async {
    await _ch.unsubscribe([name]);
    setState(() => _samples.remove(name));
  }

  Future<void> _doDtcSnapshot() async {
    try {
      final rows = await _ch.diagSnapshot();
      setState(() => _dtcRows = rows);
      _setResult('DTC snapshot: ${rows.length} rows');
    } on PlatformException catch (e) {
      _setResult('DTC FAILED: ${e.code} ${e.message}');
    }
  }

  Future<void> _doVinRefresh() async {
    await widget.detector.detect(force: true);
    _setResult('VIN refresh: ${widget.detector.vin ?? "(none)"}');
  }

  // ─── helpers ─────────────────────────────────────────────────────

  bool _looksValid(String s) =>
      RegExp(r'^0x[0-9A-Fa-f]+$').hasMatch(s);

  void _setResult(String s) {
    setState(() => _lastResultText = s);
  }

  // ─── build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final d = widget.detector;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: _buildLeftPane(d)),
          const SizedBox(width: 12),
          Expanded(flex: 3, child: _buildRightPane()),
        ],
      ),
    );
  }

  Widget _buildLeftPane(NativeDetector d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _kv('Detected', d.detected ? 'yes' : 'no'),
                _kv('Head unit', d.isOnHeadUnit ? 'yes' : 'no'),
                _kv('VIN', d.vin ?? '—'),
                if (d.lastError != null) _kv('Last error', d.lastError!),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  OutlinedButton(onPressed: _doVinRefresh, child: const Text('VIN refresh (fresh)')),
                  OutlinedButton(onPressed: _refreshPerms, child: const Text('Re-check perms')),
                  OutlinedButton(onPressed: _doDtcSnapshot, child: const Text('DTC snapshot')),
                ]),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Permissions', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                if (_perms.isEmpty)
                  const Text('(unknown — refresh)')
                else
                  ..._perms.map((p) => Row(children: [
                        Icon(
                          p.granted
                              ? Icons.check_circle
                              : p.declared
                                  ? Icons.error_outline
                                  : Icons.help_outline,
                          size: 16,
                          color: p.granted
                              ? Colors.green
                              : p.declared
                                  ? Colors.orange
                                  : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${p.label}  (${p.permission.split('.').last})',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ])),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_dtcRows.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DTC snapshot (${_dtcRows.length})',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  ..._dtcRows.take(8).map((r) => Text(
                        '${r['moduleName'] ?? '?'} ${r['dtc'] ?? '?'}'
                        '${r['isActiveFault'] == true ? ' (active)' : ''}',
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                      )),
                  if (_dtcRows.length > 8)
                    Text('… +${_dtcRows.length - 8} more',
                        style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildRightPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Probe feature ID',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _propController,
                  style: const TextStyle(fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '0x99002B0A',
                    helperText: 'Hex feature ID from bz5_feature_catalog.csv',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  ElevatedButton(onPressed: _doGet, child: const Text('Get')),
                  OutlinedButton(onPressed: _doGetConfig, child: const Text('Config')),
                  OutlinedButton(
                    onPressed: _subscribing ? null : _doSubscribe,
                    child: const Text('Subscribe'),
                  ),
                ]),
                const SizedBox(height: 12),
                if (_lastResultText != null)
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _lastResultText!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('Active subscriptions (${_samples.length})',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                  ]),
                  const SizedBox(height: 4),
                  Expanded(
                    child: _samples.isEmpty
                        ? const Center(
                            child: Text('No active subscriptions',
                                style: TextStyle(color: Colors.grey)),
                          )
                        : ListView(
                            children: _samples.entries.map((e) => _buildSubRow(e.key, e.value)).toList(),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubRow(String name, List<_Sample> samples) {
    final latest = samples.isNotEmpty ? samples.last : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              name,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              latest == null ? '(no samples yet)'
                             : '${latest.value}  [${latest.type ?? "?"}]'
                               '  +${samples.length}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => _doUnsubscribe(name),
            tooltip: 'Unsubscribe',
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
              width: 90,
              child: Text(k, style: const TextStyle(color: Colors.grey, fontSize: 12))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  softWrap: true)),
        ]),
      );
}

class _Sample {
  final DateTime ts;
  final Object? value;
  final String? type;
  _Sample(this.ts, this.value, this.type);
}
