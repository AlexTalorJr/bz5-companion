// v0.1.67+166 (D2) — первые исполняемые тесты движка «Замеров».
//
// ЗАЧЕМ. До +166 регрессионная сеть проекта состояла из питоновских
// гейтов, которые сопоставляют ТЕКСТ и не выполняют ни строки Dart.
// 444 «PASS» подтверждали, что нужные подстроки на месте, — и не могли
// поймать ни одной арифметической ошибки. Всё остальное проверялось
// физической поездкой, то есть самой дорогой проверкой из возможных.
//
// Эти тесты закрывают ровно то, что чинит +166, и делают это без
// машины: потолок сбора, запись чанка, отказ вставки, восстановление
// легаси-леджера.
//
// КАК ЭТО СТАЛО ВОЗМОЖНО — три шва из того же патча:
//   • HalTelemetrySource — интерфейс на девять членов вместо
//     прибитого к платформенному каналу синглтона;
//   • AppDatabase.forTesting(QueryExecutor) — база в памяти;
//   • инъекция часов в две точки входа тика — 120 секунд накопления
//     проигрываются за миллисекунды.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bz5_companion/data/database.dart';
import 'package:bz5_companion/services/hal_telemetry_channel.dart';
import 'package:bz5_companion/services/hal_telemetry_service.dart';
import 'package:bz5_companion/services/speed_profile_service.dart';

/// Управляемые часы. Движок берёт время через инъекцию только в
/// _onEvent и _onVirtualTick — дальше оно течёт параметром.
class _Clock {
  int ms = 1700000000000;
  int call() => ms;
  void advance(int d) => ms += d;
}

/// Подделка источника HAL. Ровно девять членов интерфейса.
class _FakeHal extends ChangeNotifier implements HalTelemetrySource {
  final _ctrl = StreamController<HalEvent>.broadcast();
  final Map<String, double> _values = {};
  final Set<String> _fresh = {};

  @override
  Stream<HalEvent> get rawEvents => _ctrl.stream;

  @override
  Future<void> retainStream() async {}

  @override
  Future<void> releaseStream() async {}

  @override
  bool get canUseHal => true;

  @override
  bool get platformProbed => true;

  @override
  bool halFresh(String name) => _fresh.contains(name);

  @override
  double? halValue(String name) => _values[name];

  void put(String name, double v) {
    _values[name] = v;
    _fresh.add(name);
  }

  void emitSpeed(double kmh) => _ctrl.add(HalEvent(
        name: 'speed',
        unit: 'km/h',
        value: kmh,
        key: 'speed|0x00000000',
        subtype: 0,
        ts: 0,
      ));

  Future<void> dispose_() async => _ctrl.close();
}

/// Проигрывает [seconds] секунд ровной езды: одно событие в секунду,
/// как отдаёт живой поток по изменению плюс насос +156.
Future<void> _drive(
    _FakeHal hal, _Clock clock, double kmh, int seconds) async {
  for (var i = 0; i < seconds; i++) {
    clock.advance(1000);
    hal.emitSpeed(kmh);
    await Future<void>.delayed(Duration.zero);
  }
}

/// Ждёт условия, не привязываясь к точному числу микротасков: запись
/// чанка уходит в unawaited и завершается через реальный await базы.
Future<bool> _waitFor(Future<bool> Function() cond,
    {int tries = 200}) async {
  for (var i = 0; i < tries; i++) {
    if (await cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeHal hal;
  late _Clock clock;
  late SpeedProfileService svc;

  Future<void> boot({Map<String, Object> prefs = const {}}) async {
    SharedPreferences.setMockInitialValues(prefs);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    hal = _FakeHal();
    clock = _Clock();
    // Свежие V/I — иначе _freshPowerKw() вернёт null и ни один тик не
    // квалифицируется. 350 В × 40 А = 14 кВт, правдоподобная крейсерская
    // мощность.
    hal.put('pack_voltage', 350.0);
    hal.put('pack_current', 40.0);
    hal.put('probe_highest_temp', 20.0);
    svc = SpeedProfileService(hal,
        db: db, appVersion: 'test', nowMs: clock.call);
    await svc.init();
  }

  tearDown(() async {
    await hal.dispose_();
    try {
      await db.close();
    } catch (_) {}
  });

  test('полоса ниже потолка живёт: 60 км/ч даёт клетку', () async {
    await boot();
    await _drive(hal, clock, 60.0, 20);
    final bands = svc.atlasLiveBands();
    expect(bands.map((b) => b.band), contains(60));
    // Первые kBandDwellS секунд не квалифицируются.
    expect(bands.firstWhere((b) => b.band == 60).timeS,
        greaterThan(10.0));
  });

  test('A2: полоса выше потолка не создаёт клетку вовсе', () async {
    await boot();
    await _drive(hal, clock, 160.0, 30);
    // До +166 здесь появлялась полноценная карточка «Полоса 160 ·
    // зреет», её полоска доходила до 120 с, и только тогда клетка
    // молча удалялась.
    expect(svc.atlasLiveBands(), isEmpty);
  });

  test('A2: легаси-клетка выше потолка отбрасывается при восстановлении',
      () async {
    // Ледждер, какой мог остаться от ≤+165: живая клетка 160 рядом с
    // законной 60.
    const legacy = '{"uid":"test-uid","ss":1700000000000,'
        '"lm":1700000000000,"aw":20,"sd":0,'
        '"cells":{'
        '"60:20":{"e":0.5,"d":2.0,"t":60.0,"sa":1700000000000},'
        '"160:20":{"e":1.0,"d":4.0,"t":90.0,"sa":1700000000000}}}';
    await boot(prefs: {'atlas_ledger': legacy});
    final bands = svc.atlasLiveBands().map((b) => b.band).toList();
    expect(bands, isNot(contains(160)));
  });

  test('A1: аккумулятор сбрасывается — второй чанк вообще возможен',
      () async {
    await boot();
    await _drive(hal, clock, 60.0, 130);
    expect(await _waitFor(() async => (await db.countAtlasSnapshots()) >= 1),
        isTrue,
        reason: 'первый снимок не лёг в базу');
    final first = await db.select(db.atlasSnapshots).get();
    expect(first, hasLength(1));
    expect(first.single.steadySeconds, closeTo(kBandMinSeconds, 1.5));

    // ГЛАВНОЕ. Второй чанк возможен ТОЛЬКО если аккумулятор сбросился:
    // переход требует beforeS < 120, а cell.timeS без сброса остаётся
    // выше порога навсегда и условие не выполнится больше никогда.
    //
    // Прежняя редакция этого теста проверяла atlasLiveBands().timeS и
    // была неправа: тот геттер отдаёт СЕССИОННУЮ сумму frozen ⊕ live
    // (решение +164 — число на карточке не должно прыгать назад), то
    // есть 120 + остаток, и «меньше 120» там не могло быть никогда.
    await _drive(hal, clock, 60.0, 120);
    expect(await _waitFor(() async => (await db.countAtlasSnapshots()) >= 2),
        isTrue,
        reason: 'второго чанка нет — значит аккумулятор не сбросился');
    expect(await db.countAtlasSnapshots(), 2);
  });

  test('A1: отказ вставки не теряет замер — повтор дописывает его',
      () async {
    await boot();
    // Триггер, отбивающий любую вставку. В отличие от закрытия базы,
    // его можно снять — а без восстановления тест не смог бы показать
    // главное: что замер уцелел, а не просто «что-то осталось».
    // Имя таблицы берём у Drift, а не пишем руками: оно выводится
    // из имени класса, и опечатка здесь дала бы падение теста,
    // неотличимое от настоящего дефекта.
    final t = db.atlasSnapshots.actualTableName;
    await db.customStatement('CREATE TRIGGER fail_atlas '
        'BEFORE INSERT ON $t '
        "BEGIN SELECT RAISE(ABORT, 'forced'); END;");

    await _drive(hal, clock, 60.0, 130);
    expect(await _waitFor(() async => svc.atlasFreezeRetryPending >= 1),
        isTrue,
        reason: 'клетка не встала в очередь повтора');
    expect(await db.countAtlasSnapshots(), 0);
    expect(svc.atlasInsertFailuresTotal, greaterThanOrEqualTo(1));

    // База ожила — следующий квалифицированный тик обязан дописать.
    await db.customStatement('DROP TRIGGER fail_atlas;');
    // Десять тиков, а не один: последняя неудачная вставка ещё
    // может быть в полёте, и первый тик уйдёт в _freezeInFlight.
    await _drive(hal, clock, 60.0, 10);
    expect(await _waitFor(() async => (await db.countAtlasSnapshots()) >= 1),
        isTrue,
        reason: 'повтор не дописал замер после восстановления базы');

    final rows = await db.select(db.atlasSnapshots).get();
    expect(rows, hasLength(1));
    // Замер уцелел ЦЕЛИКОМ: 120 с порога плюс всё, что натекло за
    // время отказов. До +166 здесь было бы либо пусто, либо строка,
    // потерявшая накопление между сбросом и неудачной вставкой.
    expect(rows.single.steadySeconds, greaterThanOrEqualTo(kBandMinSeconds));
    expect(await _waitFor(() async => svc.atlasFreezeRetryPending == 0),
        isTrue,
        reason: 'очередь повтора не опустела после успешной записи');
  });
}
