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
  Map<String, Object?> _diag = const {};

  // Active subscriptions: name → recent N values (cyclic buffer).
  final Map<String, List<_Sample>> _samples = {};
  StreamSubscription<NativeEvent>? _eventSub;
  bool _subscribing = false;

  // In-app log tail (no-adb workflow). Polled every 1.5s while the
  // screen is mounted. Newest entries last (matches logcat order).
  final List<NativeLogEntry> _logs = [];
  Timer? _logPollTimer;
  bool _logAutoFollow = true;
  final _logScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _refreshPerms();
    _refreshDiagnostics();
    _eventSub = _ch.events.listen(_onEvent);
    _startLogPolling();
  }

  @override
  void dispose() {
    _logPollTimer?.cancel();
    _eventSub?.cancel();
    // Best-effort cleanup of active subs so we don't leak server-side.
    if (_samples.isNotEmpty) {
      _ch.unsubscribe(_samples.keys.toList());
    }
    _propController.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void _startLogPolling() {
    _logPollTimer?.cancel();
    _logPollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final since = _logs.isEmpty ? null : _logs.last.ts;
      try {
        final batch = await _ch.pullLogs(count: 200, sinceTs: since);
        if (batch.isEmpty || !mounted) return;
        setState(() {
          _logs.addAll(batch);
          // Cap at 800 in-memory; oldest first.
          if (_logs.length > 800) {
            _logs.removeRange(0, _logs.length - 800);
          }
        });
        if (_logAutoFollow && _logScrollCtrl.hasClients) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (_logScrollCtrl.hasClients) {
            _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
          }
        }
      } catch (_) {
        // Plugin may not be available on this device; just stop polling.
      }
    });
  }

  Future<void> _refreshDiagnostics() async {
    try {
      final d = await _ch.getDiagnostics();
      if (mounted) setState(() => _diag = d);
    } catch (_) {/* plugin missing — keep empty */}
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
      _setResult(_validationHint(name));
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
    if (!_looksValid(name)) {
      _setResult(_validationHint(name));
      return;
    }
    try {
      final r = await _ch.getPropertyConfig([name]);
      _setResult('CONFIG $name → $r');
    } on PlatformException catch (e) {
      _setResult('CONFIG $name FAILED: ${e.code} ${e.message}');
    }
  }

  Future<void> _doSubscribe() async {
    final name = _propController.text.trim();
    if (!_looksValid(name)) {
      _setResult(_validationHint(name));
      return;
    }
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
    await _refreshDiagnostics();
    _setResult('VIN refresh: ${widget.detector.vin ?? "(none)"}');
  }

  Future<void> _doOpenAppSettings() async {
    final ok = await _ch.openAppSettings();
    if (!ok) {
      _setResult(
        'Could not open Settings. Open it manually: Android Settings → Apps '
        '→ BZ5 Companion → Permissions and grant the BYDAUTO_* entries.',
      );
    }
  }

  /// v0.1.26+14: programmatically trigger the system runtime-permission
  /// prompt. Field test showed Open App Settings reaches the app page
  /// but BYDAUTO_* perms aren't listed there — this API may surface
  /// them directly.
  Future<void> _doRequestPermissions() async {
    try {
      final r = await _ch.requestRuntimePermissions();
      final ok = r['ok'] == true;
      final requested = (r['requested'] as num?)?.toInt() ?? 0;
      final already = (r['alreadyGranted'] as num?)?.toInt() ?? 0;
      if (!ok) {
        _setResult('Request failed: ${r['error']}');
      } else if (requested == 0) {
        _setResult('All $already BYDAUTO permissions already granted.');
      } else {
        _setResult(
          'Requested $requested permission(s) ($already already granted). '
          'Re-check perms in a few seconds to see updated status.',
        );
        // Auto-refresh after a delay so the user sees the new state.
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) _refreshPerms();
        });
      }
    } catch (e) {
      _setResult('Request perms threw: $e');
    }
  }

  Future<void> _doClearLogs() async {
    await _ch.clearLogs();
    if (mounted) setState(() => _logs.clear());
  }

  /// Builds a single text blob with diagnostics + last 200 log lines and
  /// copies it to the clipboard. The user can then paste it into any
  /// note app / Telegram message / Toyota launcher's notepad and ship
  /// it off the head unit. No file system / ADB needed.
  Future<void> _doExportDiagnostics() async {
    final buf = StringBuffer()
      ..writeln('=== BZ5 Companion native diagnostics ===')
      ..writeln('Captured: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('--- environment ---');
    _diag.forEach((k, v) => buf.writeln('  $k: $v'));
    buf
      ..writeln()
      ..writeln('--- detector ---')
      ..writeln('  detected: ${widget.detector.detected}')
      ..writeln('  isOnHeadUnit: ${widget.detector.isOnHeadUnit}')
      ..writeln('  vin: ${widget.detector.vin}')
      ..writeln('  lastError: ${widget.detector.lastError}')
      ..writeln()
      ..writeln('--- permissions (${_perms.length}) ---');
    for (final p in _perms) {
      buf.writeln(
        '  ${p.granted ? "G" : p.declared ? "D" : "?"}  ${p.permission}',
      );
    }
    buf
      ..writeln()
      ..writeln('--- last result text ---')
      ..writeln('  $_lastResultText')
      ..writeln()
      ..writeln('--- recent logs (${_logs.length}) ---');
    for (final l in _logs) {
      buf.writeln(l.toString());
      if (l.throwable != null) {
        for (final ln in l.throwable!.split('\n')) {
          buf.writeln('    $ln');
        }
      }
    }

    final blob = buf.toString();
    await Clipboard.setData(ClipboardData(text: blob));
    _setResult('Diagnostics copied to clipboard (${blob.length} chars). '
        'Paste anywhere to share — Telegram, notes, email, etc.');
  }

  // ─── helpers ─────────────────────────────────────────────────────

  bool _looksValid(String s) =>
      RegExp(r'^0x[0-9A-Fa-f]+$').hasMatch(s);

  /// Human-readable error explaining why the current input isn't valid.
  /// v0.1.26+15: replaces the opaque "Expected format: 0x<HEX_FEATURE_ID>"
  /// which left the user with no idea what to type. Now we say what's
  /// wrong and suggest the next step.
  String _validationHint(String s) {
    if (s.isEmpty || s == '0x') {
      return 'Enter a hex feature ID (e.g. 0x99002B0A). '
          'See assets/native_api/bz5_feature_catalog.csv for the 10016 known IDs, '
          'or tap a preset below.';
    }
    if (!s.toLowerCase().startsWith('0x')) {
      return 'Feature ID must start with 0x (e.g. 0x99002B0A).';
    }
    return 'Feature ID has non-hex characters after 0x.';
  }

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
    return SingleChildScrollView(
      child: Column(
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
                    OutlinedButton(
                      onPressed: _doOpenAppSettings,
                      child: const Text('Open App Settings'),
                    ),
                    OutlinedButton(
                      onPressed: _doRequestPermissions,
                      child: const Text('Request perms'),
                    ),
                    OutlinedButton(
                      onPressed: _doExportDiagnostics,
                      child: const Text('Copy diagnostics'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // v0.1.27: env diagnostics — no-adb workflow. Each field is the
          // single most informative signal for that layer.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('Environment', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 18),
                      tooltip: 'Refresh',
                      onPressed: _refreshDiagnostics,
                    ),
                  ]),
                  const SizedBox(height: 4),
                  if (_diag.isEmpty)
                    const Text('(plugin not attached — open Status above)',
                        style: TextStyle(color: Colors.grey, fontSize: 12))
                  else ...[
                    _diagRow('carserver installed', _diag['carServerInstalled'] == true,
                        extra: _diag['carServerVersion']?.toString()),
                    _diagRow('provider resolves',   _diag['providerResolves']  == true,
                        extra: _diag['providerResolves'] == true
                            ? null
                            : 'add <queries> to manifest'),
                    _diagRow('framework present',   _diag['frameworkPresent']  == true),
                    _kv('package', (_diag['packageName'] ?? '?').toString()),
                    _kv('android sdk', (_diag['androidSdk'] ?? '?').toString()),
                    _kv('device', (_diag['device'] ?? '?').toString()),
                    _kv('perms granted',
                        '${_diag['permissionsGranted'] ?? 0} / ${_diag['permissionsDeclared'] ?? 0} declared'
                        ' (of ${_diag['permissionsTotal'] ?? 0} known)'),
                  ],
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
      ),
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
                    helperText: 'Hex feature ID. Tap a preset below or pick one from docs/bz5_feature_catalog.csv',
                  ),
                ),
                const SizedBox(height: 6),
                // v0.1.26+15: preset chips. The featureID -> semantic
                // mapping is NOT verified — these are candidates to
                // probe. Tap to fill the field, then Get / Config /
                // Subscribe. If the value looks plausible (SOC around
                // current pack state, voltage ~350V, speed 0 at parked,
                // ...) we found one. If not, try the next preset.
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final p in _presetCandidates)
                    ActionChip(
                      label: Text(p.label, style: const TextStyle(fontSize: 11)),
                      tooltip: '${p.id} (${p.note})',
                      onPressed: () {
                        _propController.text = p.id;
                        _setResult('Loaded preset: ${p.label} = ${p.id}\n${p.note}');
                      },
                    ),
                ]),
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
          flex: 1,
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
        const SizedBox(height: 8),
        // v0.1.27: in-app log tail. Replaces `adb logcat` for environments
        // where USB debugging isn't available. Polls every 1.5s in
        // _startLogPolling(). Auto-follows the tail unless the user
        // manually scrolls; toggle via the pin icon. Long-press a line
        // to copy it.
        Expanded(
          flex: 1,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('Logs (${_logs.length})',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: Icon(_logAutoFollow
                          ? Icons.vertical_align_bottom
                          : Icons.pause_circle_outline),
                      tooltip: _logAutoFollow ? 'Auto-follow on' : 'Auto-follow off',
                      onPressed: () =>
                          setState(() => _logAutoFollow = !_logAutoFollow),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'Copy all logs',
                      onPressed: () async {
                        final text = _logs.map((l) {
                          final s = StringBuffer(l.toString());
                          if (l.throwable != null) {
                            s.write('\n');
                            for (final ln in l.throwable!.split('\n')) {
                              s.write('    $ln\n');
                            }
                          }
                          return s.toString();
                        }).join('\n');
                        await Clipboard.setData(ClipboardData(text: text));
                        _setResult('Copied ${_logs.length} log lines to clipboard');
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.clear_all, size: 18),
                      tooltip: 'Clear log buffer',
                      onPressed: _doClearLogs,
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Expanded(
                    child: _logs.isEmpty
                        ? const Center(
                            child: Text(
                              'No log entries yet — interact with the buttons '
                              'above to populate. Logs are pulled from the plugin '
                              'every 1.5 seconds.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 11),
                            ),
                          )
                        : Container(
                            color: Colors.black,
                            child: ListView.builder(
                              controller: _logScrollCtrl,
                              padding: const EdgeInsets.all(6),
                              itemCount: _logs.length,
                              itemBuilder: (_, i) => _buildLogLine(_logs[i]),
                            ),
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

  Widget _buildLogLine(NativeLogEntry e) {
    final color = switch (e.level) {
      'E' => Colors.red.shade300,
      'W' => Colors.orange.shade300,
      'I' => Colors.green.shade300,
      _   => Colors.grey.shade400,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            e.toString(),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              color: color,
            ),
          ),
          if (e.throwable != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: SelectableText(
                e.throwable!,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  color: color.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
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

  Widget _diagRow(String label, bool ok, {String? extra}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel,
              size: 14, color: ok ? Colors.green : Colors.red),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              extra == null ? label : '$label  ($extra)',
              style: const TextStyle(fontSize: 12),
              softWrap: true,
            ),
          ),
        ]),
      );
}

class _Sample {
  final DateTime ts;
  final Object? value;
  final String? type;
  _Sample(this.ts, this.value, this.type);
}

/// v0.1.26+15: candidate featureID presets for the prober.
///
/// These are EDUCATED GUESSES, not verified mappings. The plan:
///   1. Tap a preset.
///   2. Tap Config — see what dataType/permission it reports.
///   3. Tap Get — see the value.
///   4. If the value matches expected magnitude (SOC=0..100, voltage
///      ~350V, etc.), the guess holds. Mark it. If not, try another.
///
/// The featureID values picked here are heuristic — taken from the
/// 10016-entry catalog by filtering on interfaceName (POWER, ENERGY,
/// CHARGING, SPEED, INSTRUMENT) and dataType, then picking IDs that
/// "look" like data signals based on byte structure. They may all be
/// wrong; that's why this is a probing UI, not a wiring UI.
///
/// Once we calibrate these on a real car, the mapping moves into a
/// proper VehicleDataSource implementation and these chips become
/// obsolete.
class _PresetCandidate {
  final String label;
  final String id;
  final String note;
  const _PresetCandidate(this.label, this.id, this.note);
}

const List<_PresetCandidate> _presetCandidates = [
  _PresetCandidate('SOC?',        '0x99002B0A',
      'POWER/STATISTIC domain candidate. Expected: 0..100 (or 0..10000 ×100).'),
  _PresetCandidate('Speed?',      '0x98000801',
      'SPEED domain candidate. Expected: km/h, ~0 when parked.'),
  _PresetCandidate('HV bus V?',   '0x99001501',
      'ENERGY domain. Expected: ~350-400 V (or ×40 raw).'),
  _PresetCandidate('Pack V?',     '0x99002201',
      'ENERGY domain. Expected: ~350-400 V.'),
  _PresetCandidate('Pack I?',     '0x99002101',
      'ENERGY domain. Expected: signed A, ~0 idle, ±50A driving.'),
  _PresetCandidate('Gear?',       '0x95000901',
      'GEARBOX domain. Expected: enum (1=P, 2=R, 3=N, 4=D).'),
  _PresetCandidate('Odometer?',   '0x96000101',
      'INSTRUMENT domain. Expected: km, large monotonic number.'),
  _PresetCandidate('12V V?',      '0x98010401',
      'POWER domain. Expected: ~12-14 V (or ×10).'),
];
