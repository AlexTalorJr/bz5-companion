// v0.2.37+236 — этап зарядки по DEVICE_STATE, «залито» по счётчику 0x2D0,
// сверка наружной температуры. Чистая логика из
// lib/services/charge_state.dart; те же случаи держит зеркало
// tools/mirror_plus236_charge.py.

import 'package:flutter_test/flutter_test.dart';

import 'package:bz5_companion/services/charge_state.dart';

void main() {
  group('chargeStageOf', () {
    test('таблица Друга 3 (21.11) при вставленном пистолете', () {
      expect(chargeStageOf(deviceState: 1, gun: 2), ChargeStage.charging);
      expect(chargeStageOf(deviceState: 0, gun: 3), ChargeStage.handshake);
      expect(chargeStageOf(deviceState: 2, gun: 2), ChargeStage.finished);
      // 15 до зарядки — подключено, не идёт; 15 после зарядки — закончена.
      expect(chargeStageOf(deviceState: 15, gun: 2), ChargeStage.plugged);
      expect(chargeStageOf(deviceState: 15, gun: 3), ChargeStage.plugged);
      expect(
          chargeStageOf(deviceState: 15, gun: 2, chargedThisPlugIn: true),
          ChargeStage.finished);
    });

    test('пистолет «нет» закрывает сессию при любом состоянии', () {
      expect(chargeStageOf(deviceState: 1, gun: 1), ChargeStage.none);
      expect(chargeStageOf(deviceState: 2, gun: 1), ChargeStage.none);
      expect(
          chargeStageOf(deviceState: 15, gun: 1, chargedThisPlugIn: true),
          ChargeStage.none);
    });

    test('состояние не известно — null, решает запасной путь', () {
      expect(chargeStageOf(deviceState: null, gun: 2), isNull);
      expect(chargeStageOf(deviceState: 7, gun: 2), isNull);
    });

    test('пистолет не известен — этап по состоянию', () {
      expect(chargeStageOf(deviceState: 1), ChargeStage.charging);
      // По 15 без пистолета сказать «подключено» нечем.
      expect(chargeStageOf(deviceState: 15), ChargeStage.none);
      expect(chargeStageOf(deviceState: 15, chargedThisPlugIn: true),
          ChargeStage.none);
    });

    test('DC 20.11 целиком: вставка, 135 с при 15, согласование, зарядка, '
        'остановка станцией, кабель в порту, вынимание', () {
      var charged = false;
      ChargeStage? step(double ds, double gun) {
        charged = nextChargedThisPlugIn(charged, deviceState: ds, gun: gun);
        return chargeStageOf(
            deviceState: ds, gun: gun, chargedThisPlugIn: charged);
      }

      expect(step(15, 1), ChargeStage.none);
      expect(step(15, 3), ChargeStage.plugged); // 135 с согласования
      expect(step(0, 3), ChargeStage.handshake);
      expect(step(1, 3), ChargeStage.charging);
      expect(step(2, 3), ChargeStage.finished); // секунды
      expect(step(15, 3), ChargeStage.finished); // кабель в порту
      expect(step(15, 1), ChargeStage.none);
      // Следующая вставка начинается заново.
      expect(step(15, 2), ChargeStage.plugged);
    });

    test('nextChargedThisPlugIn: ставят 1 и 2, снимает только «нет '
        'пистолета»', () {
      expect(nextChargedThisPlugIn(false, deviceState: 15, gun: 2), isFalse);
      expect(nextChargedThisPlugIn(false, deviceState: 0, gun: 2), isFalse);
      expect(nextChargedThisPlugIn(false, deviceState: 1, gun: 2), isTrue);
      expect(nextChargedThisPlugIn(false, deviceState: 2, gun: 2), isTrue);
      expect(nextChargedThisPlugIn(true, deviceState: 15, gun: 2), isTrue);
      expect(nextChargedThisPlugIn(true, deviceState: 15), isTrue);
      expect(nextChargedThisPlugIn(true, deviceState: 15, gun: 1), isFalse);
      expect(nextChargedThisPlugIn(true, deviceState: 1, gun: 1), isFalse);
    });
  });

  group('chargeTypeOf', () {
    test('пистолет первым, тип зарядки вторым', () {
      expect(chargeTypeOf(gun: 2), 'AC');
      expect(chargeTypeOf(gun: 3), 'DC');
      expect(chargeTypeOf(gun: 1, fhType: 8), isNull);
      expect(chargeTypeOf(fhType: 9), 'AC');
      expect(chargeTypeOf(fhType: 11), 'DC');
      expect(chargeTypeOf(gun: 3, fhType: 9), 'DC');
    });
  });

  group('ChargedEnergyCounter', () {
    test('DC 20.11: 1.3 до вставки, 14.0 в конце — +12.7', () {
      final c = ChargedEnergyCounter();
      c.feed(1.3);
      c.feed(1.3);
      c.open(beforeCharging: true);
      expect(c.kwh, 0);
      expect(c.fromStart, isTrue);
      for (final v in [1.3, 1.7, 2.1, 6.5, 12.9, 14.0, 14.0]) {
        c.feed(v);
      }
      expect(c.kwh, closeTo(12.7, 1e-9));
      c.close();
      expect(c.kwh, isNull);
    });

    test('вне сессии счётчик не копится: рекуперация до вставки не в счёт',
        () {
      final c = ChargedEnergyCounter();
      c.feed(0.2);
      c.feed(1.3);
      c.open(beforeCharging: true);
      c.feed(1.8);
      expect(c.kwh, closeTo(0.5, 1e-9));
    });

    test('сброс подтверждается вторым кадром, счёт идёт от кандидата', () {
      final c = ChargedEnergyCounter();
      c.feed(5.0);
      c.feed(5.0);
      c.open(beforeCharging: true);
      c.feed(6.0);
      c.feed(0.4);
      c.feed(1.0);
      expect(c.resets, 1);
      expect(c.kwh, closeTo(1.6, 1e-9));
    });

    test('+237: ложный одиночный ноль (13.11 17:44) — не сброс и не '
        'прирост', () {
      final c = ChargedEnergyCounter();
      c.feed(5.9);
      c.feed(5.9);
      c.open(beforeCharging: true);
      c.feed(0.0);
      c.feed(5.9);
      expect(c.resets, 0);
      expect(c.kwh, closeTo(0.0, 1e-9));
      c.feed(6.1);
      expect(c.kwh, closeTo(0.2, 1e-9));
    });

    test('+237: пробуждение посреди зарядки, первый кадр — ложный ноль', () {
      final c = ChargedEnergyCounter();
      c.open(beforeCharging: false);
      c.feed(0.0);
      expect(c.kwh, isNull);
      c.feed(5.9);
      expect(c.kwh, isNull);
      c.feed(6.0);
      expect(c.kwh, closeTo(0.1, 1e-9));
    });

    test('сессия подхвачена на ходу: база — подтверждённый кадр, '
        'fromStart=false', () {
      final c = ChargedEnergyCounter();
      c.open(beforeCharging: false);
      expect(c.kwh, isNull);
      expect(c.fromStart, isFalse);
      c.feed(8.0);
      expect(c.kwh, isNull);
      c.feed(8.4);
      expect(c.kwh, closeTo(0.4, 1e-9));
    });

    test('базы нет, но зарядка ещё не началась — считается с начала', () {
      final c = ChargedEnergyCounter();
      c.open(beforeCharging: true);
      expect(c.fromStart, isTrue);
    });

    test('forget: значение остановленного потока базой не служит', () {
      final c = ChargedEnergyCounter();
      c.feed(3.0);
      c.feed(3.0);
      c.forget();
      c.open(beforeCharging: false);
      expect(c.kwh, isNull);
    });

    test('контроль ∫V·I: только внутрь батареи, разрыв длиннее 120 с не '
        'интегрируется', () {
      final c = ChargedEnergyCounter();
      c.feed(1.0);
      c.open(beforeCharging: true);
      c.addIntegral(-48.0, 60); // 0.8 кВт·ч
      c.addIntegral(2.0, 60); // разряд — не в счёт
      c.addIntegral(-48.0, 300); // разрыв
      c.addIntegral(null, 10);
      expect(c.integralKwh, closeTo(0.8, 1e-9));
    });

    test('расхождение счётчика и интеграла: больше 0.5 кВт·ч и 15 %', () {
      final c = ChargedEnergyCounter();
      c.feed(0.0);
      c.feed(0.0);
      c.open(beforeCharging: true);
      c.feed(10.0);
      for (var i = 0; i < 10; i++) {
        c.addIntegral(-36.0, 100); // по 1.0 кВт·ч
      }
      expect(c.diverged, isFalse);
      c.feed(13.0);
      expect(c.diverged, isTrue);
    });
  });

  group('OutsideTempCheck', () {
    test('firehose показал то же в пределах 10 с — достоверно', () {
      final k = OutsideTempCheck();
      k.feedHal(0, 1000);
      expect(k.feedFirehose(1, 1500), isFalse); // отстал на отсчёт
      expect(k.feedFirehose(0, 2500), isFalse);
      expect(k.untrusted, isFalse);
      // Сверка закрыта: дальнейшие значения не сравниваются.
      expect(k.feedFirehose(5, 60000), isFalse);
      expect(k.untrusted, isFalse);
    });

    test('расхождение держится 10 с — недостоверно до новой поездки', () {
      final k = OutsideTempCheck();
      k.feedHal(4, 1000);
      expect(k.feedFirehose(14, 5000), isFalse);
      expect(k.feedFirehose(14, 11000), isTrue);
      expect(k.untrusted, isTrue);
      expect(k.feedFirehose(14, 12000), isFalse); // флаг уже стоит
      k.resetForTrip();
      expect(k.untrusted, isFalse);
    });

    test('без события HAL сверки нет', () {
      final k = OutsideTempCheck();
      expect(k.feedFirehose(7, 1000), isFalse);
      expect(k.untrusted, isFalse);
    });

    test('серия событий HAL (выезд из гаража): срок считается от '
        'последнего', () {
      final k = OutsideTempCheck();
      k.feedHal(13, 0);
      k.feedFirehose(14, 500);
      k.feedHal(12, 8000);
      expect(k.feedFirehose(13, 10500), isFalse);
      expect(k.feedFirehose(12, 11500), isFalse);
      expect(k.untrusted, isFalse);
    });
  });

  group('StoredEnergyTracker (+238)', () {
    test('ночь 24–25.11: 24.4 → 65.2 после пробуждения — запасено 40.8', () {
      final t = StoredEnergyTracker();
      expect(t.feed(65.2, afterBreak: true), isNull); // до load не принимает
      t.load(lastKwh: 24.4);
      expect(t.feed(65.2, afterBreak: true), isNull);
      expect(t.feed(65.2, afterBreak: false), closeTo(40.8, 1e-9));
      expect(t.storedKwh, closeTo(40.8, 1e-9));
      t.clear();
      expect(t.storedKwh, isNull);
    });

    test('DC 20.11 при работающей голове не запас (вариант А)', () {
      final t = StoredEnergyTracker()..load(lastKwh: 23.7);
      var v = 23.7;
      while (v < 30.75) {
        v = ((v + 0.1) * 10).roundToDouble() / 10;
        t.feed(v, afterBreak: false);
      }
      expect(t.storedKwh, isNull);
      expect(t.lastKwh, 30.8);
      t.feed(31.2, afterBreak: false);
      t.feed(31.2, afterBreak: false);
      expect(t.storedKwh, isNull);
      expect(t.lastKwh, 31.2);
    });

    test('ложный ноль и одиночный выброс после пробуждения', () {
      final t = StoredEnergyTracker()..load(lastKwh: 40.8);
      t.feed(0, afterBreak: true);
      t.feed(40.8, afterBreak: false);
      t.feed(52, afterBreak: true);
      t.feed(40.8, afterBreak: false);
      expect(t.storedKwh, isNull);
      expect(t.lastKwh, 40.8);
    });

    test('два пробуждения на одной стоянке складываются; сумма из настроек',
        () {
      final t = StoredEnergyTracker()..load(lastKwh: 30);
      t.feed(40, afterBreak: true);
      t.feed(40, afterBreak: false);
      t.feed(45, afterBreak: true);
      t.feed(45, afterBreak: false);
      expect(t.storedKwh, closeTo(15, 1e-9));
      final r = StoredEnergyTracker()
        ..load(lastKwh: t.lastKwh, storedKwh: t.storedKwh);
      expect(r.storedKwh, closeTo(15, 1e-9));
      final fresh = StoredEnergyTracker()..load();
      fresh.feed(50, afterBreak: true);
      expect(fresh.storedKwh, isNull);
      expect(fresh.lastKwh, 50);
    });
  });
}
