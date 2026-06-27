/// v0.1.29+100: reader for the byd `car_status` ContentProvider.
///
/// This is a self-contained service feature — vehicle health + maintenance
/// + fluid-reminder flags — read **directly from a head-unit-local
/// ContentProvider**. It does NOT use HAL, does NOT use UDS, and does NOT
/// need the dongle. It is therefore completely independent of
/// [ConnectionService] and [HalTelemetryService]; Honesty AA2 is untouched
/// (this file never references either, and neither references it).
///
/// Availability: the provider lives in the head-unit system image. On a
/// phone the authority does not resolve and the native side returns
/// `available=false` with an empty map — the UI shows an honest empty
/// state. The Status screen is gated to the head unit anyway (via
/// HalTelemetryService.canUseHal, the same "are we on the HU?" signal), so
/// in practice this is only ever queried where it can succeed.
///
/// Source spec: Друг 3 (recon) `CarStatusProviderReadProbe`, 2026-06-27.
/// Field replay values (parked, odo ≈ 4347): car_status_issue=[],
/// issue_num=0, maintenance_mile=20001, all *_no_prompt=0.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

import 'native_car_channel.dart';

/// One fluid/tyre reminder flag as surfaced on the Status screen.
///
/// Polarity note: the raw `*_no_prompt` flags read 0 on the field sample.
/// Друг 3 flags the polarity as UNCONFIRMED (0 = reminders on? or 0 = no
/// problem?). We deliberately do NOT claim "reminders on/off". We present
/// 0 as "ok / no problem flagged" per the owner's reading, and anything
/// non-zero as "attention" so a real future fault still surfaces loudly.
@immutable
class FluidFlag {
  final String key;
  final String label;
  final String? raw;

  const FluidFlag({required this.key, required this.label, this.raw});

  /// Field sample shows all flags = "0". We treat 0 (and null/empty) as
  /// "ok"; any other value as "needs attention". This is intentionally
  /// conservative: if the provider ever reports a non-zero value we show
  /// it rather than silently calling it fine.
  bool get isOk {
    final r = raw?.trim();
    if (r == null || r.isEmpty) return true;
    return r == '0';
  }
}

/// Parsed, UI-ready snapshot of the `car_status` table.
@immutable
class CarStatus {
  /// True when the provider was reachable and returned rows. False on a
  /// phone (no such provider) or if the query was refused/threw.
  final bool available;

  /// Number of active vehicle issues (`car_status_issue_num`). null if the
  /// key was absent.
  final int? issueNum;

  /// Raw `car_status_issue` value (e.g. "[]" when empty, or a list-ish
  /// string when populated). Kept raw — we only know the empty shape from
  /// the field sample.
  final String? issueRaw;

  /// Maintenance mileage THRESHOLD in km (`car_status_maintenance_mile`).
  /// This is the absolute odometer at which the next service is due, NOT a
  /// remaining distance — remaining is computed against the live odometer.
  final int? maintenanceMileThresholdKm;

  /// Raw maintenance-time value (`car_status_maintenance_time`). Semantics
  /// UNCONFIRMED (days? interval?) — we store it but do NOT render a
  /// "days remaining" until Друг 3's second-sample test resolves it.
  final String? maintenanceTimeRaw;

  /// Fluid / tyre reminder flags, in display order.
  final List<FluidFlag> fluids;

  /// Diagnostic summary string from the native side (for debugging).
  final String? summary;

  const CarStatus({
    required this.available,
    this.issueNum,
    this.issueRaw,
    this.maintenanceMileThresholdKm,
    this.maintenanceTimeRaw,
    this.fluids = const [],
    this.summary,
  });

  /// True when the vehicle reports zero active issues. Drives the green
  /// "no errors" health banner. When [issueNum] is null (key missing) we
  /// do NOT claim healthy — return false so the UI shows "unknown".
  bool get isHealthy => issueNum != null && issueNum == 0;

  /// Whether we have enough to show the health banner at all.
  bool get hasHealthSignal => available && issueNum != null;

  /// Remaining km to next service given a live odometer reading. Returns
  /// null when either the threshold or the odometer is unavailable, or if
  /// the result would be negative (overdue / stale threshold) — the caller
  /// shows "—" in that case rather than a misleading number.
  int? remainingKmToService(double? odometerKm) {
    final t = maintenanceMileThresholdKm;
    if (t == null || odometerKm == null) return null;
    final rem = t - odometerKm.round();
    if (rem < 0) return null;
    return rem;
  }

  /// An unavailable snapshot (phone / provider absent / error).
  static const CarStatus unavailable = CarStatus(available: false);
}

/// Reads and parses the `car_status` provider on demand. Stateless beyond
/// a cached last-good snapshot; the Status screen calls [refresh] on open
/// and on pull-to-refresh. Not a polling service — this data changes on
/// the order of days, not seconds.
class CarStatusService extends ChangeNotifier {
  CarStatus _status = CarStatus.unavailable;
  bool _loading = false;
  DateTime? _lastFetch;

  CarStatus get status => _status;
  bool get loading => _loading;
  DateTime? get lastFetch => _lastFetch;

  /// Fluid/tyre keys in the order Друг 3 documented them, with display
  /// labels resolved by the caller (we keep keys here; the UI maps to
  /// localized strings so this service stays l10n-free).
  static const List<String> fluidKeys = [
    'dicare_engine_oil_no_prompt',
    'dicare_at_fluid_no_prompt',
    'dicare_brake_fluid_no_prompt',
    'dicare_battery_coolant_no_prompt',
    'dicare_motor_coolant_no_prompt',
    'tyre_pressure_guidance_no_prompt',
  ];

  /// Query the provider and parse. Safe to call repeatedly. Never throws —
  /// failure resolves to an `unavailable` snapshot.
  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      final map = await NativeCarChannel.instance.queryCarStatus();
      _status = _parse(map);
    } catch (e) {
      _status = CarStatus.unavailable;
    } finally {
      _loading = false;
      _lastFetch = DateTime.now();
      notifyListeners();
    }
  }

  CarStatus _parse(Map<String, dynamic>? map) {
    if (map == null) return CarStatus.unavailable;
    final available = map['available'] == true;
    if (!available) {
      return CarStatus(available: false, summary: map['summary'] as String?);
    }
    final kvRaw = map['kv'];
    final kv = <String, String>{};
    if (kvRaw is Map) {
      kvRaw.forEach((k, v) {
        if (k != null) kv['$k'] = v == null ? '' : '$v';
      });
    }

    int? parseIntKey(String key) {
      final v = kv[key];
      if (v == null) return null;
      return int.tryParse(v.trim());
    }

    final fluids = <FluidFlag>[];
    for (final key in fluidKeys) {
      // Only include a flag if the provider actually has the key — we
      // never fabricate a "fine" row for a key the firmware didn't send.
      if (kv.containsKey(key)) {
        fluids.add(FluidFlag(key: key, label: key, raw: kv[key]));
      }
    }

    return CarStatus(
      available: true,
      issueNum: parseIntKey('car_status_issue_num'),
      issueRaw: kv['car_status_issue'],
      maintenanceMileThresholdKm: parseIntKey('car_status_maintenance_mile'),
      maintenanceTimeRaw: kv['car_status_maintenance_time'],
      fluids: fluids,
      summary: map['summary'] as String?,
    );
  }
}
