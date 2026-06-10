/// Temporary HAL push-telemetry bring-up screen (v0.1.29+63).
///
/// This is a DEVELOPER test surface, not a daily-driver view — it lives
/// under Settings → Advanced and exists to verify the +61/+62 HAL stream
/// actually flows on the head unit before the SPEED overlapping pilot
/// (+64) wires HAL into the real data source. It will be removed (or
/// folded into HAL Explorer) once the pilot proves the path.
///
/// What it does:
///   - Start  → listen on HalTelemetryChannel.events, then start the
///              native subscription; shows the SubscriptionStatus
///              (registered / failed / attempted).
///   - live   → per-decoder-name: latest value + unit + a rolling Hz
///              estimate (events/sec over a 5 s window) + total count.
///   - Stop   → stop the subscription and cancel the listener.
///
/// English-only by project rule (developer tool, like Sweep / Live Log).
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/hal_telemetry_channel.dart';
import '../services/hal_telemetry_service.dart';

class HalTestScreen extends StatefulWidget {
  const HalTestScreen({super.key});

  @override
  State<HalTestScreen> createState() => _HalTestScreenState();
}

/// Rolling per-name aggregate: latest value/unit, total count, and a Hz
/// estimate from event timestamps over a trailing window.
class _NameStat {
  num? lastValue;
  String unit = '';
  int count = 0;
  String key = '';
  final List<int> _arrivalsMs = [];

  void record(HalEvent e, int nowMs) {
    lastValue = e.value;
    unit = e.unit;
    key = e.key;
    count++;
    _arrivalsMs.add(nowMs);
    // keep only the last 5 s of arrivals for the Hz estimate
    final cutoff = nowMs - 5000;
    while (_arrivalsMs.isNotEmpty && _arrivalsMs.first < cutoff) {
      _arrivalsMs.removeAt(0);
    }
  }

  /// Events/sec over the trailing window. Needs ≥2 samples to span time.
  double get hz {
    if (_arrivalsMs.length < 2) return 0;
    final spanMs = _arrivalsMs.last - _arrivalsMs.first;
    if (spanMs <= 0) return 0;
    return (_arrivalsMs.length - 1) * 1000.0 / spanMs;
  }
}

class _HalTestScreenState extends State<HalTestScreen> {
  HalTelemetryService? _svc;
  StreamSubscription<HalEvent>? _sub;

  bool _running = false;
  bool _starting = false;
  HalStartStatus? _status;
  String? _error;
  int _totalEvents = 0;
  DateTime? _startedAt;

  // name → rolling stat. SplayTreeMap would keep it sorted, but we sort
  // the view list explicitly for clarity.
  final Map<String, _NameStat> _byName = {};

  // Throttle setState — events can arrive at ~50 Hz aggregate; rebuilding
  // the list on every event would peg the UI thread. Coalesce to ~5 fps.
  Timer? _repaint;

  @override
  void dispose() {
    _repaint?.cancel();
    _sub?.cancel();
    // The SERVICE owns the native subscription (it may be feeding the live
    // speedometer). We only release our diagnostic retainer — the service
    // keeps the stream up if the source mode still wants it.
    _svc?.releaseStream();
    super.dispose();
  }

  Future<void> _start() async {
    if (_running || _starting) return;
    final svc = _svc ??= context.read<HalTelemetryService>();
    setState(() {
      _starting = true;
      _error = null;
      _status = null;
      _byName.clear();
      _totalEvents = 0;
    });

    // Attach to the service's shared event stream and retain it so the
    // native subscription is running while we watch. Listen FIRST, then
    // retain (retain may start the stream, which needs a live sink).
    _sub = svc.rawEvents.listen(_onEvent, onError: (Object e) {
      if (mounted) setState(() => _error = 'stream error: $e');
    });
    await svc.retainStream();
    if (!mounted) return;
    setState(() {
      _starting = false;
      if (!svc.running) {
        _error = 'HAL stream not running (unavailable on this device, or '
            'no sink). Check logs.';
        _running = false;
        _sub?.cancel();
        _sub = null;
        svc.releaseStream();
      } else {
        _status = svc.status;
        _running = true;
        _startedAt = DateTime.now();
      }
    });
  }

  Future<void> _stop() async {
    await _sub?.cancel();
    _sub = null;
    await _svc?.releaseStream();
    if (mounted) setState(() => _running = false);
  }

  void _onEvent(HalEvent e) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _totalEvents++;
    (_byName[e.name] ??= _NameStat()).record(e, now);
    // Coalesced repaint.
    _repaint ??= Timer(const Duration(milliseconds: 200), () {
      _repaint = null;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final names = _byName.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('HAL Test')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _controls(),
          const Divider(height: 1),
          Expanded(
            child: names.isEmpty
                ? Center(
                    child: Text(
                      _running
                          ? 'Subscribed — waiting for events…\n'
                              '(parked: cell_v, pack_current, insulation; '
                              'speed/rpm need motion)'
                          : 'Stopped. Tap Start to subscribe.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: names.length,
                    itemBuilder: (_, i) => _row(names[i], _byName[names[i]]!),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _controls() {
    final s = _status;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: _running || _starting ? null : _start,
                icon: _starting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _running ? _stop : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              const Spacer(),
              if (_running)
                Text('${_totalEvents} ev',
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                        color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 10),
          if (s != null)
            Text(
              'registered ${s.registered}/${s.attempted}'
              '${s.failed > 0 ? ' · FAILED ${s.failed}' : ''}'
              '${_byName.isNotEmpty ? ' · ${_byName.length} params' : ''}',
              style: TextStyle(
                fontSize: 13,
                color: s.failed > 0 ? Colors.orangeAccent : Colors.greenAccent,
              ),
            ),
          if (s != null && s.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                s.errors.entries
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\n'),
                style: const TextStyle(fontSize: 11, color: Colors.orange),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.redAccent)),
            ),
        ],
      ),
    );
  }

  Widget _row(String name, _NameStat st) {
    final v = st.lastValue;
    final valueStr = v == null
        ? '—'
        : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
    return ListTile(
      dense: true,
      title: Text(name, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(st.key,
          style: const TextStyle(fontSize: 11, color: Colors.grey)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '$valueStr ${st.unit}',
            style: const TextStyle(
                fontSize: 15,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
          Text(
            '${st.hz.toStringAsFixed(1)} Hz · ${st.count}',
            style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}
