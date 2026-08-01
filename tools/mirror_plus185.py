#!/usr/bin/env python3
"""Зеркало BgTripBuilder (v0.1.86+185) — проверка логики против поля.

Повторяет `lib/services/bg_trip_builder.dart` шаг в шаг и считает то же
самое по `hal_samples.csv` из экспорта. Смысл в том, что фоновая сборка
поездок проверяется БЕЗ МАШИНЫ и без сборки: у нас есть настоящая поездка
01.08 (25 км с закрытым приложением), и Dart обязан дать по ней те же
числа, что и этот файл.

    python3 tools/mirror_plus185.py путь/к/hal_samples.csv

Расхождение зеркала и Dart — это ошибка, и чинить её надо до выдачи, а не
после поездки.
"""
import csv
import datetime
import sys

MOTION_GAP = datetime.timedelta(minutes=5)   # BgTripBuilder.kMotionGap
MIN_DISTANCE_KM = 0.3                        # BgTripBuilder.kMinDistanceKm
FRESH_TAIL = datetime.timedelta(minutes=5)   # BgTripBuilder.kFreshTail
CAPACITY_KWH = 65.28                         # Bz5Model.batteryCapacityKwh


def compute_trip_derived(start_odo, end_odo, start_soc, end_soc,
                         start_soc_p, end_soc_p, speed_sum, speed_samples,
                         capacity):
    """Зеркало trip_aggregates.dart — тех же пять величин, те же пороги."""
    distance = None
    if start_odo is not None and end_odo is not None and end_odo > start_odo:
        distance = end_odo - start_odo
    energy = None
    if start_soc is not None and end_soc is not None and start_soc > end_soc:
        energy = (start_soc - end_soc) * capacity / 100.0
    consumption = None
    if distance is not None and energy is not None and distance > 0.1:
        consumption = (energy / distance) * 100.0
    avg_speed = None
    if speed_samples > 0:
        avg_speed = speed_sum / speed_samples
    energy_soc = None
    if (start_soc_p is not None and end_soc_p is not None
            and start_soc_p > end_soc_p):
        energy_soc = (start_soc_p - end_soc_p) * capacity / 100.0
    return distance, energy, consumption, avg_speed, energy_soc


def motion_clusters(rows):
    motion, last_odo = [], None
    for r in rows:
        v = r['v']
        if v is None:
            continue
        if r['name'] == 'speed':
            if v > 0:
                motion.append(r['ts'])
        elif r['name'] == 'odometer':
            if last_odo is not None and v > last_odo:
                motion.append(r['ts'])
            last_odo = v
    if not motion:
        return []
    motion.sort()
    out, start, prev = [], motion[0], motion[0]
    for t in motion[1:]:
        if t - prev > MOTION_GAP:
            out.append((start, prev))
            start = t
        prev = t
    out.append((start, prev))
    return out


def main(path):
    rows = []
    with open(path) as fh:
        for r in csv.DictReader(fh):
            if r['source'] != 'hal' or not r['name']:
                continue
            if r['trip_id']:
                continue
            rows.append({
                'ts': datetime.datetime.fromisoformat(r['timestamp']),
                'name': r['name'],
                'v': float(r['numeric']) if r['numeric'] else None,
            })
    rows.sort(key=lambda r: r['ts'])
    print(f'строк без поездки: {len(rows)}')
    if len(rows) < 2:
        return 0
    now = rows[-1]['ts'] + FRESH_TAIL  # экспорт снят позже последней строки
    built = discarded = 0
    for start, end in motion_clusters(rows):
        if now - end < FRESH_TAIL:
            print(f'  {start:%H:%M:%S}–{end:%H:%M:%S} свежий хвост, отложен')
            break
        w = [r for r in rows if start <= r['ts'] <= end]

        def first(n):
            return next((r['v'] for r in w
                         if r['name'] == n and r['v'] is not None), None)

        def last(n):
            return next((r['v'] for r in reversed(w)
                         if r['name'] == n and r['v'] is not None), None)

        def mx(n):
            vs = [r['v'] for r in w if r['name'] == n and r['v'] is not None]
            return max(vs) if vs else None

        def mn(n):
            vs = [r['v'] for r in w if r['name'] == n and r['v'] is not None]
            return min(vs) if vs else None

        speeds = [r['v'] for r in w
                  if r['name'] == 'speed' and r['v'] is not None and r['v'] > 0]
        dist, energy, cons, avg_speed, energy_soc = compute_trip_derived(
            first('odometer'), last('odometer'),
            first('soc_precise'), last('soc_precise'),
            None, None, sum(speeds), len(speeds), CAPACITY_KWH)
        if dist is None or dist < MIN_DISTANCE_KM:
            discarded += 1
            print(f'  {start:%H:%M:%S}–{end:%H:%M:%S} отброшен '
                  f'(км={dist if dist is not None else "—"})')
            continue
        built += 1
        spread, hi, lo = None, None, None
        for r in w:
            if r['v'] is None:
                continue
            if r['name'] == 'cell_v_highest':
                hi = r['v']
            if r['name'] == 'cell_v_lowest':
                lo = r['v']
            if hi is not None and lo is not None:
                d = (hi - lo) * 1000.0
                spread = d if spread is None or d > spread else spread
        total_s = int((end - start).total_seconds())
        # то же, что в Dart: сумма промежутков между движущимися
        # отсчётами, каждый ограничен сверху (см. maxGapSec).
        MAX_GAP = 15
        moving_s, prev_m = 0, None
        for r in w:
            if r['name'] != 'speed' or r['v'] is None or r['v'] <= 0:
                continue
            if prev_m is not None:
                gap = int((r['ts'] - prev_m).total_seconds())
                moving_s += MAX_GAP if gap > MAX_GAP else gap
            prev_m = r['ts']
        print(f'  ПОЕЗДКА {start:%H:%M:%S}–{end:%H:%M:%S}')
        print(f'    строк         {len(w)}')
        print(f'    дистанция     {dist:.1f} км')
        print(f'    одометр       {first("odometer")} → {last("odometer")}')
        print(f'    SOC           {first("soc_precise")} → '
              f'{last("soc_precise")} %')
        print(f'    энергия       {energy:.2f} кВт·ч' if energy else
              '    энергия       —')
        print(f'    расход        {cons:.1f} кВт·ч/100км' if cons else
              '    расход        —')
        print(f'    пик скорости  {mx("speed")} км/ч')
        print(f'    средняя ход   {avg_speed:.1f} км/ч' if avg_speed else
              '    средняя ход   —')
        print(f'    разброс ячеек {spread:.1f} мВ' if spread else
              '    разброс ячеек —')
        print(f'    темп батареи  {mn("battery_temp_bigdata")} … '
              f'{mx("battery_temp_bigdata")} °C')
        print(f'    в движении    {moving_s} с из {total_s} с')
        print(f'    energy_from_soc {energy_soc}  (пусто — второго '
              f'источника нет)')
    print(f'построено {built}, отброшено {discarded}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'hal_samples.csv'))
