// v0.2.34+233 — событийный счёт энергии на настоящем корпусе.
//
// Тот же эталон, что у tools/mirror_plus233_events.py: корпус recon 09.11
// 18:10–19:00 (шесть сигналов счёта, ключи без _priority/_tail) в
// tools/data/recon_corpus_20261109_energy6.csv.gz. Питоновское зеркало
// проверяет правило; этот тест — что Dart считает то же самое, без машины.

@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:bz5_companion/services/energy_split_service.dart';
import 'package:bz5_companion/services/firehose_check.dart';
import 'package:flutter_test/flutter_test.dart';

const int _refStartMs = 1794237000000; // 09.11.2026 18:10 +03:00
const int _refEndMs = 1794240000000; // 19:00

List<({int t, String name, double v})> _loadFixture() {
  final raw = File('tools/data/recon_corpus_20261109_energy6.csv.gz')
      .readAsBytesSync();
  final text = utf8.decode(gzip.decode(raw));
  var t = 0;
  var sig = <String>[];
  final out = <({int t, String name, double v})>[];
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    if (line.startsWith('#t0=')) {
      t = int.parse(line.substring(4));
      continue;
    }
    if (line.startsWith('#signals=')) {
      sig = line.substring('#signals='.length).split(',');
      continue;
    }
    if (line.startsWith('#')) continue;
    final f = line.split(',');
    t += int.parse(f[0]);
    out.add((t: t, name: sig[int.parse(f[1])], v: double.parse(f[2])));
  }
  return out;
}

EventEnergySums _corpusSums() {
  final acc = EventEnergyAccumulator(_refStartMs);
  for (final e in _loadFixture()) {
    if (e.t < _refStartMs || e.t > _refEndMs) continue;
    acc.add(e.name, e.v, e.t);
  }
  return acc.snapshot();
}

void main() {
  test('corpus 09.11: sums match the reference', () {
    final s = _corpusSums();
    expect(s.packKwh, closeTo(3.60, 0.01));
    expect(s.tractionKwh - s.regenKwh, closeTo(2.72, 0.01));
    expect(s.regenKwh, closeTo(1.75, 0.01));
    expect(s.shaftTractionKwh, closeTo(3.96, 0.01));
    expect(s.shaftRegenKwh, closeTo(1.93, 0.01));
    expect(s.coveredSeconds, closeTo(2966, 1));
    expect(s.negativeIntervals, 0);
    expect(s.gaps, 0);
    expect(s.minutes, 49);
    expect(s.minutesLow, 1);
    expect(s.minutesNegative, 0);
    expect(s.minuteMinKw, closeTo(0.15, 0.005));
    // v0.2.35+234: рекуперация в батарею — меньше инверторной, у счётчика
    // 0x2D0 за ту поездку +1.6 (Друг 3: ∫V·I(−) 1.57).
    expect(s.batteryRegenKwh, closeTo(1.583, 0.005));
  });

  test('corpus 09.11: split 2.72 / 0.87, checks pass, parts sum to pack', () {
    final s = _corpusSums();
    final r = computeEnergySplitEvents(
        s,
        DateTime.fromMillisecondsSinceEpoch(_refStartMs),
        DateTime.fromMillisecondsSinceEpoch(_refEndMs))!;
    expect(r.model, EnergySplitModel.versionV2);
    expect(r.rejected, isNull);
    expect(r.motionKwh, closeTo(2.72, 0.01));
    expect(r.climateKwh, closeTo(0.87, 0.01));
    expect(r.otherKwh, 0.0);
    expect(r.motionKwh! + r.climateKwh!, closeTo(r.packKwh, 1e-9));
  });

  test('sums survive trips.extra and keep the other keys', () {
    final s = _corpusSums();
    final patch = jsonDecode(s.toExtraPatch()) as Map<String, dynamic>;
    final merged = <String, dynamic>{
      'v': 1,
      'speedHist': [1, 2, 3],
      'source': 'hal',
      ...patch,
    };
    expect(merged['speedHist'], [1, 2, 3]);
    expect(merged['source'], 'hal');
    final back = EventEnergySums.fromExtra(jsonEncode(merged))!;
    expect(back.packKwh, closeTo(s.packKwh, 1e-4));
    expect(back.regenKwh, closeTo(s.regenKwh, 1e-4));
    expect(back.counts, s.counts);
    expect(back.minutes, s.minutes);
    expect(back.batteryRegenKwh, closeTo(s.batteryRegenKwh!, 1e-4));
    expect(EventEnergySums.fromExtra('{"v":1,"speedHist":[1]}'), isNull);
    expect(EventEnergySums.fromExtra('not json'), isNull);
  });

  test('gap over 5 s and a negative interval are not integrated', () {
    final acc = EventEnergyAccumulator(0);
    acc.add('pack_voltage', 400, 0);
    acc.add('pack_current', 10, 0);
    acc.add('inverter_current', 0, 0);
    acc.add('pack_current', 10, 2000);
    acc.add('pack_current', 10, 1500); // назад: не считается, часы стоят
    acc.add('pack_current', 10, 3000);
    acc.add('pack_current', 10, 9000); // разрыв 6 с
    acc.add('pack_current', 10, 10000);
    final s = acc.snapshot();
    expect(s.negativeIntervals, 1);
    expect(s.gaps, 1);
    expect(s.coveredSeconds, closeTo(4.0, 1e-9));
    expect(s.packKwh, closeTo(4.0 * 4 / 3600, 1e-12));
  });

  test('checks: regen above shaft and bad board minutes leave no parts', () {
    EventEnergySums sums({double regen = 1.0, int low = 0, int neg = 0}) =>
        EventEnergySums(
          packKwh: 3.0,
          tractionKwh: 3.0,
          regenKwh: regen,
          shaftTractionKwh: 3.0,
          shaftRegenKwh: 1.2,
          coveredSeconds: 1000,
          negativeIntervals: 0,
          gaps: 0,
          counts: const [0, 0, 0, 0, 0, 0],
          minutes: 16,
          minutesLow: low,
          minutesNegative: neg,
          minuteMinKw: 0.5,
        );
    final a = DateTime.fromMillisecondsSinceEpoch(0);
    final b = DateTime.fromMillisecondsSinceEpoch(1000000);
    expect(computeEnergySplitEvents(sums(), a, b)!.motionKwh,
        closeTo(2.0, 1e-12));
    final r1 = computeEnergySplitEvents(sums(regen: 1.4), a, b)!;
    expect(r1.rejected, 'regen_above_shaft');
    expect(r1.hasSplit, isFalse);
    expect(r1.packKwh, 3.0);
    expect(computeEnergySplitEvents(sums(low: 2), a, b)!.rejected,
        'board_minutes');
    expect(computeEnergySplitEvents(sums(neg: 1), a, b)!.rejected,
        'board_minutes');
    // Покрытие ниже 0.8 поездки — суммы не берутся (оценка по hal_samples).
    expect(
        computeEnergySplitEvents(
            sums(), a, DateTime.fromMillisecondsSinceEpoch(1300000)),
        isNull);
    expect(EnergySplitModel.twoParts(EnergySplitModel.versionV2s), isTrue);
    expect(EnergySplitModel.twoParts(EnergySplitModel.version), isFalse);
  });

  test('firehose counters: first and last per trip, status kept', () {
    final acc = EventEnergyAccumulator(0);
    acc.firehoseStatus = FirehoseCheck.ok;
    acc.addFirehose('gb_cycle_discharge_kwh', 0.0);
    acc.addFirehose('gb_cycle_discharge_kwh', 1.7);
    acc.addFirehose('gb_cycle_regen_kwh', 0.4);
    acc.addFirehose('fh_energy_state', 2); // контрольное поле не копится
    final s = acc.snapshot();
    expect(s.firehose['gb_cycle_discharge_kwh'], (0.0, 1.7));
    expect(s.firehose.containsKey('fh_energy_state'), isFalse);
    final back = EventEnergySums.fromExtra(s.toExtraPatch())!;
    expect(back.firehoseStatus, FirehoseCheck.ok);
    expect(back.firehose['gb_cycle_regen_kwh'], (0.4, 0.4));
  });

  test('firehose check: match -> ok, divergence held 10 s -> mismatch until the next trip', () {
    final c = FirehoseCheck();
    expect(c.feed('ac_temp_main', 22.5, 0), isFalse);
    expect(c.feed('fh_ac_temp_main_c', 22.5, 500), isTrue);
    expect(c.state, FirehoseCheck.ok);
    // Короткое расхождение на смене уставки — норма.
    c.feed('ac_temp_main', 23.0, 1000);
    expect(c.state, FirehoseCheck.ok);
    c.feed('fh_ac_temp_main_c', 23.0, 1800);
    expect(c.state, FirehoseCheck.ok);
    // Расхождение дольше 10 с — mismatch, и обратно не возвращается.
    c.feed('fh_energy_state', 2, 2000);
    c.feed('energy_state', 5, 2100);
    expect(c.feed('fh_energy_state', 2, 13000), isTrue);
    expect(c.state, FirehoseCheck.mismatch);
    c.feed('fh_energy_state', 5, 14000);
    expect(c.state, FirehoseCheck.mismatch);
    // Новая поездка — проверка заново, совпадение снова даёт ok.
    c.resetForTrip();
    expect(c.state, FirehoseCheck.unchecked);
    expect(c.feed('energy_state', 5, 20000), isTrue);
    expect(c.state, FirehoseCheck.ok);
  });

  test('v2s estimate goes through the same checks: regen above shaft -> no parts', () {
    // 10 минут по 3 с: пак 10 кВт, инвертор то тяга, то рекуперация 40 кВт,
    // вал рекуперации нет (момент всегда > 0) — рекуперация инвертора
    // больше вала, как у поездки 1223 (12.11).
    final start = DateTime.fromMillisecondsSinceEpoch(0);
    final pts = <({DateTime ts, String name, double v})>[];
    for (var t = 0; t <= 600; t += 3) {
      final ts = DateTime.fromMillisecondsSinceEpoch(t * 1000);
      pts.add((ts: ts, name: 'pack_voltage', v: 400));
      pts.add((ts: ts, name: 'pack_current', v: 25));
      pts.add((ts: ts, name: 'inverter_current', v: (t ~/ 3).isEven ? 60 : -100));
      pts.add((ts: ts, name: 'motor_torque', v: 50));
      pts.add((ts: ts, name: 'motor_rpm', v: 3000));
    }
    final end = DateTime.fromMillisecondsSinceEpoch(600 * 1000);
    final raw = computeEnergySplitV2(pts, start, end);
    expect(raw.hasSplit, isTrue);
    final r = computeEnergySplitAuto(pts, start, end);
    expect(r.model, EnergySplitModel.versionV2s);
    expect(r.rejected, 'regen_above_shaft');
    expect(r.hasSplit, isFalse);
    expect(r.packKwh, raw.packKwh);
  });
}
