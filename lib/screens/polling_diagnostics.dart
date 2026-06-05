// v0.1.29+51: polling-layer observability for pack current (790/0009).
//
// This screen surfaces the four counters added in connection.dart so
// the owner can put a number on the field complaint of "Power card
// shows '—' for stretches under heavy throttle". Read-only; the only
// write operation is the reset button which zeroes the counters so
// numbers can be scoped to a single drive.
//
// What each number means:
//   ok reads        — successful raw 790/0009 decodes since reset
//   getter calls    — number of UI requests for the value
//   getter nulls    — calls that returned null (no cache or stale)
//   null rate       — nulls/calls, the "how often was Power '—'" %
//   current gap     — ms since the last successful read (live)
//   max gap         — worst observed gap between two reads (this run)
//
// The number to watch is max gap. If it stays under ~3000 ms during
// a drive, the 2-second stale-gate is the proximate cause of the
// flicker (one cycle of bad luck). If it climbs into the tens of
// thousands, transport is stalling for real — that points to the
// 790-chain quirk or BLE link loss under burst load.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/connection.dart';

class PollingDiagnosticsScreen extends StatefulWidget {
  const PollingDiagnosticsScreen({super.key});

  @override
  State<PollingDiagnosticsScreen> createState() =>
      _PollingDiagnosticsScreenState();
}

class _PollingDiagnosticsScreenState extends State<PollingDiagnosticsScreen> {
  // The counters change when the service notifies (ingest path). But
  // "current gap" is computed live from a timestamp and won't trigger
  // a notify on its own — we need a 1 Hz ticker so the gap column on
  // screen advances visibly. Cheap; only runs while this screen is
  // mounted.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<ConnectionService>();

    final okCount = svc.packCurrentReadOkCount;
    final getterCalls = svc.packCurrentGetterCalls;
    final getterNulls = svc.packCurrentGetterNulls;
    final currentGap = svc.packCurrentCurrentGapMs;
    final maxGap = svc.packCurrentMaxGapMs;
    final nullRate =
        getterCalls == 0 ? 0.0 : (getterNulls / getterCalls) * 100;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Polling diagnostics'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Pack current (790/0009)'),
          _Row('ok reads', okCount.toString()),
          _Row('getter calls', getterCalls.toString()),
          _Row('getter nulls', getterNulls.toString()),
          _Row('null rate', '${nullRate.toStringAsFixed(1)} %'),
          _Row('current gap',
              currentGap == null ? '—' : '${currentGap} ms'),
          _Row('max gap',
              maxGap == 0 ? '—' : '${maxGap} ms',
              warn: maxGap > 10000),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Reset counters'),
            onPressed: () {
              svc.resetPackCurrentObservers();
            },
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'How to read this:\n'
              '• If max gap stays under ~3000 ms, the 2-second stale-gate '
              'on packCurrentA is the proximate cause of any flicker — '
              'one cycle of bad luck is enough.\n'
              '• If max gap climbs into 10000+ ms, the transport is '
              'stalling for real (790-chain stall or BLE loss under '
              'burst load).\n'
              '• null rate reflects what the UI saw, not what came over '
              'the wire — high rate with low max gap means the UI is '
              'polling faster than the cycle refills the cache.',
              style:
                  TextStyle(fontSize: 12, color: Colors.grey.shade400),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.0,
            color: Colors.lightBlueAccent,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  const _Row(this.label, this.value, {this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(
            value,
            style: TextStyle(
              color: warn ? Colors.orangeAccent : Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
