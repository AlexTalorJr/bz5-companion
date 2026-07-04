/// v0.1.29+122: in-app ring buffer over `debugPrint`.
///
/// Problem: the head unit has no ADB, so every `debugPrint` line the app
/// emits — including the CloudSync diag lines that gate field verification
/// ("uuid-mapping initial pass complete…", "restore via /v2/sync/pull —
/// trips X/Y new…", conflict counters) — is invisible on-device. The +121
/// field run had to leave three checklist items unanswered for exactly
/// this reason.
///
/// Fix: reassign the global [debugPrint] callback at startup (Flutter
/// explicitly supports this — it is a mutable top-level of type
/// [DebugPrintCallback]) with a wrapper that (a) appends the line to a
/// bounded in-memory ring buffer and (b) forwards to the original
/// throttled printer, so logcat behaviour is unchanged for anyone who
/// DOES have adb (e.g. the BZ3 friend's phone-side testing).
///
/// Deliberate properties:
///   * Zero persistence — the buffer lives and dies with the process.
///     Export goes through [DiagDumpFile] (proven Downloads path) on
///     explicit user action from the App Diagnostics screen.
///   * Bounded memory — [capacity] lines, oldest dropped first, with a
///     dropped-line counter so the reader knows the window is partial.
///   * Re-entrancy guard — a listener rebuilding on notify could itself
///     call debugPrint; without the guard that recurses into _append.
///   * Throttled notifications — sync bursts can emit dozens of lines
///     per second; listeners (the log screen) repaint at most once per
///     [_notifyInterval].
///
/// The class is a ChangeNotifier singleton, NOT a provider — the screen
/// subscribes directly via [AnimatedBuilder]. Keeping it out of the
/// provider tree means installing the hook in main() has no widget-tree
/// implications and no CLAUDE.md architectural surface.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

class AppDiagLog extends ChangeNotifier {
  AppDiagLog._();

  static final AppDiagLog instance = AppDiagLog._();

  /// Max lines held. 1500 × ~120 chars ≈ 180 KB worst case — fine for a
  /// head unit with GBs of RAM, and comfortably inside the DiagDumpFile
  /// "split anything over ~64 KB" advisory once exported in one section
  /// (export is explicitly allowed to exceed it for legitimate dumps).
  static const int capacity = 1500;

  static const Duration _notifyInterval = Duration(milliseconds: 300);

  final ListQueue<String> _lines = ListQueue<String>();
  int _dropped = 0;
  bool _installed = false;
  DebugPrintCallback? _forward;
  bool _inAppend = false;
  bool _notifyScheduled = false;

  /// Snapshot copy — safe to iterate while new lines keep arriving.
  List<String> get lines => List<String>.unmodifiable(_lines);

  int get length => _lines.length;

  /// Lines evicted from the front of the ring since install (or last
  /// [clear]). Non-zero means the visible window is partial.
  int get dropped => _dropped;

  bool get isInstalled => _installed;

  /// Install the debugPrint hook. Idempotent; call once from main()
  /// BEFORE any service init so the earliest startup lines are captured.
  void install() {
    if (_installed) return;
    _installed = true;
    _forward = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      _append(message);
      _forward?.call(message, wrapWidth: wrapWidth);
    };
    _append('AppDiagLog: hook installed (capacity $capacity lines)');
  }

  void clear() {
    _lines.clear();
    _dropped = 0;
    _append('AppDiagLog: buffer cleared');
    // A clear must repaint immediately, not on the throttle tick.
    notifyListeners();
  }

  /// Full buffer as one exportable text block. Header carries enough
  /// context (line count, drop count, wall-clock) that a file grabbed
  /// off the head unit days later is still self-describing.
  String exportText() {
    final b = StringBuffer()
      ..writeln('lines=${_lines.length} dropped=$_dropped '
          'exported=${DateTime.now().toIso8601String()}')
      ..writeln();
    for (final l in _lines) {
      b.writeln(l);
    }
    return b.toString();
  }

  void _append(String? message) {
    if (message == null || _inAppend) return;
    _inAppend = true;
    try {
      while (_lines.length >= capacity) {
        _lines.removeFirst();
        _dropped++;
      }
      _lines.addLast('${_stamp(DateTime.now())} $message');
      _scheduleNotify();
    } finally {
      _inAppend = false;
    }
  }

  void _scheduleNotify() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    Future<void>.delayed(_notifyInterval, () {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// HH:mm:ss.mmm without intl — this file must not depend on locale
  /// init ordering (it installs before everything else in main()).
  String _stamp(DateTime t) {
    String p2(int v) => v.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)}.$ms';
  }
}
