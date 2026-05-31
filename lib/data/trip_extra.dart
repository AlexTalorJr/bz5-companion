import 'dart:convert';

/// v0.1.29+37: the `trips.extra` JSON payload.
///
/// Why this exists: raw `samples` are never uploaded to the bridge (the
/// server rejects them with 403 samples_disabled — ADR-08, kept for disk
/// budget). So when a head unit is wiped and restored from cloud backup,
/// trips come back but their sample series is gone — the Speed
/// Distribution chart shows "No samples recorded". To make that chart
/// survive a reinstall we precompute its histogram at endTrip and store
/// it on the trip row (which IS backed up). On restore the UI rebuilds
/// the chart from this histogram instead of the missing samples.
///
/// The histogram bins MUST match SpeedHistogramCard exactly (15 bins ×
/// 10 km/h, 0..149, samples below 1 km/h excluded) so a restored chart
/// is visually identical to a live one. Both sides call [binSpeed] /
/// [speedBinCount] here — single source of truth.
///
/// Format (versioned inside the JSON, not by a column):
///   {"v":1,"speedHist":[c0,c1,...,c14]}
/// `speedHist[i]` = count of speed samples in bin [i*10, i*10+10) km/h.
/// Future keys (socHist, tempHist, …) can be added without a migration.

const int speedBinSize = 10;
const int speedBinCount = 15; // covers 0..149 km/h

/// Bin one speed value (km/h) into its histogram index, or null if it
/// should be excluded (stopped, negative, or above the top bin). Matches
/// SpeedHistogramCard's logic byte-for-byte: values < 1 are "stopped"
/// and skipped.
int? binSpeed(double? kmh) {
  if (kmh == null || kmh < 1) return null;
  final idx = (kmh ~/ speedBinSize);
  if (idx < 0 || idx >= speedBinCount) return null;
  return idx;
}

/// Build a [speedBinCount]-length histogram from a list of speed values.
List<int> buildSpeedHistogram(Iterable<double?> speeds) {
  final counts = List<int>.filled(speedBinCount, 0);
  for (final v in speeds) {
    final b = binSpeed(v);
    if (b != null) counts[b]++;
  }
  return counts;
}

/// Parsed view over a trip's `extra` JSON. Tolerant: any malformed or
/// missing field yields null/empty rather than throwing, so a corrupt
/// blob degrades to "no extra data" instead of crashing the detail view.
class TripExtra {
  final List<int>? speedHist;

  const TripExtra({this.speedHist});

  bool get hasSpeedHistogram =>
      speedHist != null &&
      speedHist!.length == speedBinCount &&
      speedHist!.any((c) => c > 0);

  /// Serialize to the canonical JSON string for storage. Returns null if
  /// there's nothing worth storing (so we don't write empty blobs).
  static String? encode({List<int>? speedHist}) {
    final map = <String, dynamic>{'v': 1};
    if (speedHist != null && speedHist.any((c) => c > 0)) {
      map['speedHist'] = speedHist;
    }
    if (map.length == 1) return null; // only the version tag → nothing useful
    return jsonEncode(map);
  }

  /// Parse a stored blob. Null/empty/malformed → empty TripExtra (all
  /// fields null), never throws.
  static TripExtra parse(String? raw) {
    if (raw == null || raw.isEmpty) return const TripExtra();
    try {
      final obj = jsonDecode(raw);
      if (obj is! Map) return const TripExtra();
      List<int>? hist;
      final h = obj['speedHist'];
      if (h is List && h.length == speedBinCount) {
        hist = h.map((e) => e is num ? e.toInt() : 0).toList();
      }
      return TripExtra(speedHist: hist);
    } catch (_) {
      return const TripExtra();
    }
  }
}
