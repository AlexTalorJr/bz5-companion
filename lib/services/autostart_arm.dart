// v0.1.56+155 — Dart side of the autostart net (вариант D).
//
// Arms AutostartService once per app launch, but ONLY on the head
// unit: the same canUseHal honesty gate as the «Замеры» tab — a phone
// has nothing to auto-collect, so it never gets a sticky service or a
// permanent notification. Waits for the platform-probe verdict via a
// listener because canUseHal settles asynchronously (+83/+139).
//
// This is the «начальный завод» the START_STICKY contract requires:
// the service must be started once by the app before ActivityManager
// will resurrect it. Every launch re-arms (idempotent — the service
// just refreshes its notification).

import 'package:flutter/services.dart';

import 'hal_telemetry_service.dart';

class AutostartArm {
  AutostartArm._();

  static const MethodChannel _ch = MethodChannel('bz5/autostart');
  static bool _armed = false;

  /// Attach to the HAL service and arm as soon as (and only if) the
  /// head-unit verdict lands. Safe to call once from main().
  static void attach(HalTelemetryService hal) {
    void tryArm() {
      if (_armed || !hal.canUseHal) return;
      _armed = true;
      _ch.invokeMethod<bool>('arm').catchError((_) => false);
    }

    tryArm();
    hal.addListener(tryArm);
  }
}
