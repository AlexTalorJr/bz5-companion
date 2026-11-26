// v0.2.41+240 — «потрачено» по остатку пака 0x2EE в computeTripDerived.
// Остаток на обоих концах — первый и единственный источник; без него —
// прежний ΔSOC × ёмкость (пути connection.dart остатка не передают).

import 'package:flutter_test/flutter_test.dart';

import 'package:bz5_companion/services/trip_aggregates.dart';

TripDerived _derive({double? r0, double? r1}) => computeTripDerived(
      startOdoKm: 1000.0,
      endOdoKm: 1010.0,
      startSocPct: 80.0,
      endSocPct: 77.0,
      startSocPrecisePct: null,
      endSocPrecisePct: null,
      speedSum: 0,
      speedSamples: 0,
      batteryCapacityKwh: 65.28,
      startRemainingKwh: r0,
      endRemainingKwh: r1,
    );

void main() {
  test('+240: остаток на обоих концах — энергия по нему', () {
    final d = _derive(r0: 52.3, r1: 50.2);
    expect(d.energyUsedKwh, closeTo(2.1, 1e-9));
    expect(d.avgConsumptionKwh100km, closeTo(21.0, 1e-9));
  });

  test('+240: остаток вырос — энергия пуста, к SOC не переходим', () {
    expect(_derive(r0: 50.2, r1: 50.4).energyUsedKwh, isNull);
  });

  test('+240: остатка нет на одном из концов — прежний ΔSOC × ёмкость', () {
    expect(_derive(r0: 52.3).energyUsedKwh, closeTo(3 * 0.6528, 1e-9));
    expect(_derive().energyUsedKwh, closeTo(3 * 0.6528, 1e-9));
  });
}
