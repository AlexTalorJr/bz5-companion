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

import '../../services/diag_dump_file.dart';
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

  // v0.1.27+1: deep probe results — only populated after the user
  // explicitly clicks the buttons. Empty until first run so the card
  // shows a meaningful "not yet probed" CTA.
  Map<String, Object?> _connProbeReport = const {};
  String? _connProbeRendered;
  List<Map<String, Object?>> _halProbeRows = const [];
  bool _probeBusy = false;
  // HAL Direct Get inputs — domain dropdown + feature id input field.
  String _halDomain = 'ENERGY';
  final _halFeatureCtrl = TextEditingController(text: '0x99002B0A');
  String? _halGetResultText;

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

  // v0.1.26+18: persistent diagnostic dump file on /sdcard/Download/.
  // When _autoDumpEnabled is true, every _setResult() additionally
  // appends a labeled section to the file so the user has a permanent
  // recon journal they can copy to USB. The flag is off by default to
  // avoid surprising filesystem writes; the user enables it from the
  // Status card switch. _dumpInfo is refreshed after each write so the
  // path-and-size row reflects current reality.
  bool _autoDumpEnabled = false;
  DiagDumpInfo? _dumpInfo;
  bool _dumpBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshPerms();
    _refreshDiagnostics();
    _refreshDumpInfo();
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
    _halFeatureCtrl.dispose();
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

  // ─── v0.1.27+1: deep probe actions ─────────────────────────────────
  //
  // These three actions exist to find a working data path on firmwares
  // where the canonical ContentResolver.query bootstrap returns null
  // (as observed on carserver 2.1.0-alpha10). They run independently of
  // the property client, so they keep working even when the normal
  // Get/Subscribe buttons fail.

  Future<void> _doProbeConnectionPaths() async {
    setState(() => _probeBusy = true);
    try {
      final r = await _ch.probeConnectionPaths();
      final rendered = r['rendered']?.toString();
      setState(() {
        _connProbeReport = r;
        _connProbeRendered = rendered;
      });
      if (rendered != null) {
        await Clipboard.setData(ClipboardData(text: rendered));
      }
      _setResult('Connection probe complete (${r['attemptCount']} attempts). '
          'Report copied to clipboard.');
    } on PlatformException catch (e) {
      _setResult('Connection probe FAILED: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _probeBusy = false);
    }
  }

  Future<void> _doHalProbeAll() async {
    setState(() => _probeBusy = true);
    try {
      final rows = await _ch.halProbeAll();
      setState(() => _halProbeRows = rows);
      final ok = rows.where((r) => r['getInstanceOk'] == true).length;
      _setResult('HAL probe complete: $ok / ${rows.length} domains reached '
          'getInstance(). See HAL Probe card for details.');
    } on PlatformException catch (e) {
      _setResult('HAL probe FAILED: ${e.code} ${e.message}');
    } finally {
      if (mounted) setState(() => _probeBusy = false);
    }
  }

  Future<void> _doHalGet() async {
    final raw = _halFeatureCtrl.text.trim();
    if (!_looksValid(raw)) {
      _setResult('HAL Get: ${_validationHint(raw)}');
      return;
    }
    final id = int.tryParse(raw.substring(2), radix: 16);
    if (id == null) {
      _setResult('HAL Get: could not parse "$raw" as hex int');
      return;
    }
    setState(() => _probeBusy = true);
    try {
      final r = await _ch.halGet(_halDomain, [id]);
      final text = 'HAL Get $_halDomain $raw → $r';
      setState(() => _halGetResultText = text);
      _setResult(text);
    } on PlatformException catch (e) {
      final text = 'HAL Get $_halDomain $raw FAILED: ${e.code} ${e.message}';
      setState(() => _halGetResultText = text);
      _setResult(text);
    } finally {
      if (mounted) setState(() => _probeBusy = false);
    }
  }

  Future<void> _doCopyProbeReport() async {
    final t = _connProbeRendered;
    if (t == null) {
      _setResult('No probe report yet — tap "Probe connection paths" first.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: t));
    _setResult('Probe report copied to clipboard (${t.length} chars).');
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
  ///
  /// v0.1.26+18: body now comes from _buildFullSnapshotBody so the
  /// clipboard path and the "Save dump to file" path stay in sync.
  Future<void> _doExportDiagnostics() async {
    final header = StringBuffer()
      ..writeln('=== BZ5 Companion native diagnostics ===')
      ..writeln('Captured: ${DateTime.now().toIso8601String()}')
      ..writeln();
    final blob = header.toString() + _buildFullSnapshotBody();
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
          'Tap a preset below.';
    }
    if (!s.toLowerCase().startsWith('0x')) {
      return 'Feature ID must start with 0x (e.g. 0x99002B0A).';
    }
    return 'Feature ID has non-hex characters after 0x.';
  }

  void _setResult(String s) {
    setState(() => _lastResultText = s);
    // v0.1.26+18: auto-append every action's result to the persistent
    // dump file on /sdcard/Download/ when the user has enabled it.
    // This is the single hook point — adding it here means every
    // existing handler (VinRefresh, DtcSnapshot, HalProbe, HalGet,
    // Probe, Get/Subscribe/Config etc.) is auto-captured without
    // having to touch each call site.
    //
    // Title heuristic: first line of `s`, since action handlers
    // already put a meaningful label there ("VIN refresh: ...",
    // "DTC snapshot: ...", "HAL Get ENERGY 0xXXXX → ..."). The full
    // text becomes the body so multi-line results are preserved.
    if (_autoDumpEnabled) {
      final firstLine = s.split('\n').first.trim();
      final title = firstLine.isEmpty ? '(empty result)' : firstLine;
      // Fire-and-forget: if the write fails we don't want to block
      // the UI thread or chain an error dialog onto every probe.
      // The user notices via the dump-info row not updating, and a
      // manual "Save dump to file" click would surface the error.
      // Keep async work off this synchronous setState path.
      unawaited(_appendToDumpFile(title: title, body: s, refresh: true));
    }
  }

  /// v0.1.26+18: write a labeled section into the persistent dump
  /// file. Called either by [_setResult] (when auto-dump is on) or
  /// explicitly by the "Save dump to file" button (which writes a
  /// full snapshot — env + perms + last result + recent logs).
  Future<void> _appendToDumpFile({
    required String title,
    required String body,
    bool refresh = true,
  }) async {
    try {
      final res = await DiagDumpFile.instance.append(
        title: title,
        body: body,
      );
      if (refresh && mounted) {
        setState(() => _dumpInfo = DiagDumpInfo(
              path: res.path,
              sizeBytes: res.sizeBytes,
              isPublicDownloads: res.isPublicDownloads,
              exists: true,
            ));
      }
    } catch (e) {
      // Don't loop _setResult here — that would recurse via auto-dump.
      // Update the result text directly without the append-hook path.
      if (mounted) {
        setState(() => _lastResultText =
            'Dump append failed: $e (auto-dump may be off-target)');
      }
    }
  }

  /// v0.1.26+18: refresh the dump-file info row (path, size, whether
  /// it landed in public Downloads or a fallback dir). Called on init
  /// and after every write so the UI doesn't lie about where the file
  /// actually is.
  Future<void> _refreshDumpInfo() async {
    try {
      final info = await DiagDumpFile.instance.info();
      if (mounted) setState(() => _dumpInfo = info);
    } catch (_) {
      // Info should never throw — but if it does, leave _dumpInfo as-is.
    }
  }

  /// v0.1.26+18: explicit "save everything I have right now" — same
  /// payload as _doExportDiagnostics (env + perms + last result +
  /// recent logs), but appended to the persistent file instead of (or
  /// in addition to) the clipboard. The clipboard variant stays as
  /// _doExportDiagnostics for cases where the user wants to paste
  /// into Telegram/chat.
  Future<void> _doSaveDumpToFile() async {
    if (_dumpBusy) return;
    setState(() => _dumpBusy = true);
    try {
      final body = _buildFullSnapshotBody();
      final res = await DiagDumpFile.instance.append(
        title: 'Full diagnostics snapshot',
        body: body,
      );
      if (!mounted) return;
      setState(() => _dumpInfo = DiagDumpInfo(
            path: res.path,
            sizeBytes: res.sizeBytes,
            isPublicDownloads: res.isPublicDownloads,
            exists: true,
          ));
      // Use _lastResultText directly (NOT _setResult) so we don't
      // double-append the snapshot via the auto-dump hook.
      setState(() => _lastResultText =
          '${res.describeForUi()}\nPath: ${res.path}');
    } catch (e) {
      if (mounted) {
        setState(() => _lastResultText = 'Save dump FAILED: $e');
      }
    } finally {
      if (mounted) setState(() => _dumpBusy = false);
    }
  }

  /// v0.1.26+18: delete the persistent dump file. Asks confirmation
  /// via a simple dialog so an accidental tap doesn't nuke a session
  /// the user just spent an hour collecting.
  Future<void> _doClearDumpFile() async {
    final info = _dumpInfo;
    if (info == null || !info.exists) {
      setState(() => _lastResultText =
          'Dump file does not exist — nothing to clear.');
      return;
    }
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Clear dump file?'),
            content: Text(
                'This deletes ${info.path} '
                '(${(info.sizeBytes / 1024).toStringAsFixed(1)} KB). '
                'The file will be recreated on the next append.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    final deleted = await DiagDumpFile.instance.clear();
    await _refreshDumpInfo();
    if (mounted) {
      setState(() => _lastResultText = deleted
          ? 'Dump file deleted.'
          : 'Dump file delete returned false — see logcat.');
    }
  }

  /// Body builder shared between "Copy diagnostics" (clipboard) and
  /// "Save dump to file" (persistent). The two used to inline this
  /// content; v0.1.26+18 factored it out so they stay in sync.
  String _buildFullSnapshotBody() {
    final buf = StringBuffer()
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
    return buf.toString();
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
          // v0.1.26+18: persistent dump file card. Writes to
          // /sdcard/Download/bz5_companion_diag.md so the user can
          // grab it via Toyota Проводник → USB flash without ADB.
          _buildDumpCard(),
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
          // v0.1.27+1: deep probe card. Two buttons that run extensive
          // diagnostics — used when the canonical Get/Subscribe path
          // fails (as it does on carserver 2.1.0-alpha10 due to
          // ContentResolver.query returning null).
          _buildDeepProbeCard(),
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
                    helperText: 'Hex feature ID. Tap a preset below.',
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

  // ─── v0.1.27+1: Deep Probe card ────────────────────────────────────
  //
  // Two parallel diagnostic paths the user can run to find a working
  // data channel when the canonical ICarPropertyService bootstrap
  // fails:
  //
  //   * "Probe connection paths" runs a matrix of URI × FQCN × call()
  //     combinations through ContentResolver, plus a
  //     ServiceManager.getService() sweep. Output is a clipboard-
  //     friendly text dump.
  //
  //   * "HAL probe all domains" walks every BYDAutoXxxDevice we know
  //     of, reports class loadability, getInstance reachability,
  //     method inventory, and permission state. For domains that come
  //     back green we can use the direct HAL path (BydHalProbe.halGet)
  //     completely bypassing CarServiceProvider.
  //
  // Below the buttons we also expose a HAL Direct Get prober — pick a
  // domain, enter a feature ID, see the decoded value.
  /// v0.1.26+18: Dump File card. Two controls + one info row.
  ///
  /// Toggle: when on, every action's result (the one shown in the
  /// "Last result" panel) is also appended to a single Markdown file
  /// at /sdcard/Download/bz5_companion_diag.md. Survives app
  /// reinstalls (same keystore = same signing = no data clear).
  ///
  /// Buttons:
  ///   * Save dump to file — appends a full snapshot (env + perms
  ///     + last result + recent logs), same payload as Copy
  ///     diagnostics but persistent instead of clipboard.
  ///   * Clear — deletes the file (with confirmation dialog).
  ///
  /// Info row: where the file actually is (public Downloads vs
  /// fallback), current size, exists/missing.
  Widget _buildDumpCard() {
    final info = _dumpInfo;
    return Card(
      color: const Color(0xFFE8F5E9), // pale green so it's visually distinct
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.save_alt, size: 18, color: Colors.green),
              const SizedBox(width: 6),
              Text('Dump file (v0.1.26+18)',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_dumpBusy)
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ]),
            const SizedBox(height: 4),
            const Text(
              'Append-only diagnostic log on /sdcard/Download/ so you '
              'can pick it up via Toyota Проводник → USB flash. One '
              'file, sections delimited by timestamps.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            // Toggle row.
            Row(children: [
              Switch(
                value: _autoDumpEnabled,
                onChanged: (v) => setState(() => _autoDumpEnabled = v),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _autoDumpEnabled
                      ? 'Auto-append: ON — every action writes to file'
                      : 'Auto-append: OFF — file only updates on "Save"',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            // Action buttons.
            Wrap(spacing: 6, runSpacing: 6, children: [
              ElevatedButton.icon(
                onPressed: _dumpBusy ? null : _doSaveDumpToFile,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('Save dump to file'),
              ),
              OutlinedButton.icon(
                onPressed: _dumpBusy ? null : _refreshDumpInfo,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh info'),
              ),
              OutlinedButton.icon(
                onPressed: _dumpBusy ? null : _doClearDumpFile,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Clear'),
              ),
            ]),
            const SizedBox(height: 8),
            // Info row.
            if (info == null)
              const Text('(probing dump file location...)',
                  style: TextStyle(fontSize: 11, color: Colors.black54))
            else ...[
              _kv('Path', info.path ?? '(unresolved)'),
              _kv(
                'Status',
                info.exists
                    ? '${(info.sizeBytes / 1024).toStringAsFixed(1)} KB'
                    : 'not yet created',
              ),
              _kv(
                'Location',
                info.isPublicDownloads
                    ? 'public Downloads (visible to Проводник)'
                    : 'app-private fallback (use share / file mgr)',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeepProbeCard() {
    return Card(
      color: const Color(0xFFFFF8E1), // subtle amber tint so the card stands out
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.troubleshoot, size: 18, color: Colors.deepOrange),
              const SizedBox(width: 6),
              Text('Deep Probe (v0.1.27+1)',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_probeBusy)
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ]),
            const SizedBox(height: 4),
            const Text(
              'Diagnostics for "ContentResolver returned null" / HAL access. '
              'Run both probes once after granting permissions; copy the '
              'reports back to chat.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              ElevatedButton.icon(
                onPressed: _probeBusy ? null : _doProbeConnectionPaths,
                icon: const Icon(Icons.network_check, size: 16),
                label: const Text('Probe connection paths'),
              ),
              ElevatedButton.icon(
                onPressed: _probeBusy ? null : _doHalProbeAll,
                icon: const Icon(Icons.memory, size: 16),
                label: const Text('HAL probe all domains'),
              ),
              if (_connProbeRendered != null)
                OutlinedButton.icon(
                  onPressed: _doCopyProbeReport,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy report'),
                ),
            ]),
            if (_connProbeReport.isNotEmpty) ...[
              const SizedBox(height: 8),
              _kv('connection attempts',
                  '${_connProbeReport['attemptCount'] ?? "?"}'),
              if (_connProbeRendered != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _connProbeRendered!.length > 600
                        ? '${_connProbeRendered!.substring(0, 600)}…\n\n'
                          '(${_connProbeRendered!.length} chars total — full '
                          'report is in clipboard)'
                        : _connProbeRendered!,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 10),
                  ),
                ),
            ],
            if (_halProbeRows.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('HAL probe results:',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
              const SizedBox(height: 4),
              ..._halProbeRows.map(_buildHalRow),
              const SizedBox(height: 8),
              const Divider(height: 1),
              const SizedBox(height: 8),
              const Text('HAL Direct Get (bypasses CarServiceProvider):',
                  style: TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
              const SizedBox(height: 4),
              Row(children: [
                DropdownButton<String>(
                  value: _halDomain,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(value: 'ENERGY',     child: Text('ENERGY')),
                    DropdownMenuItem(value: 'CHARGING',   child: Text('CHARGING')),
                    DropdownMenuItem(value: 'SPEED',      child: Text('SPEED')),
                    DropdownMenuItem(value: 'GEARBOX',    child: Text('GEARBOX')),
                    DropdownMenuItem(value: 'STATISTIC',  child: Text('STATISTIC')),
                    DropdownMenuItem(value: 'TYRE',       child: Text('TYRE')),
                    DropdownMenuItem(value: 'INSTRUMENT', child: Text('INSTRUMENT')),
                    DropdownMenuItem(value: 'POWER',      child: Text('POWER')),
                    DropdownMenuItem(value: 'BODYWORK',   child: Text('BODYWORK')),
                    DropdownMenuItem(value: 'VEHICLE_DATA', child: Text('VEHICLE_DATA')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _halDomain = v);
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _halFeatureCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Feature ID (0x…)',
                    ),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _probeBusy ? null : _doHalGet,
                  child: const Text('HAL Get'),
                ),
              ]),
              if (_halGetResultText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _halGetResultText!,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Renders a single HAL-domain probe row: green check if getInstance
  /// reached, red cross + truncated error if not. Compact, scannable.
  Widget _buildHalRow(Map<String, Object?> row) {
    final name = row['name']?.toString() ?? '?';
    final classLoaded = row['classLoaded'] == true;
    final getOk = row['getInstanceOk'] == true;
    final hasGet = row['hasGenericGet'] == true;
    final commonG = row['commonGranted'] == true;
    final getG = row['getGranted'] == true;
    final err = row['getInstanceErr']?.toString();

    final IconData icon;
    final Color color;
    if (getOk) {
      icon = Icons.check_circle; color = Colors.green;
    } else if (classLoaded) {
      icon = Icons.error_outline; color = Colors.orange;
    } else {
      icon = Icons.cancel; color = Colors.red;
    }

    final flags = <String>[];
    flags.add(commonG ? 'C+' : 'C−');
    flags.add(getG ? 'G+' : 'G−');
    if (hasGet) flags.add('.get');
    final flagsStr = flags.join(' ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        SizedBox(
          width: 90,
          child: Text(name,
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 11)),
        ),
        SizedBox(
          width: 70,
          child: Text(flagsStr,
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ),
        Expanded(
          child: Text(
            getOk
                ? 'getInstance OK'
                : (err != null
                    ? (err.length > 110 ? '${err.substring(0, 110)}…' : err)
                    : (classLoaded ? 'class loaded only' : 'class missing')),
            style: const TextStyle(fontSize: 11),
            softWrap: true,
          ),
        ),
      ]),
    );
  }
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
