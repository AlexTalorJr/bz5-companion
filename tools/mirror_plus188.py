#!/usr/bin/env python3
"""Зеркало подхвата фонового хвоста (v0.1.89+188) — проверка против поля.

Повторяет `_findJoinableTail` / `_adoptJoinedTail` из
`lib/services/hal_telemetry_service.dart` шаг в шаг и считает то же самое
по `hal_samples.csv` из экспорта. Смысл в том, что подхват проверяется БЕЗ
МАШИНЫ: у нас есть настоящий случай 02.08 (владелец тронулся в 21:29:10 при
закрытом приложении, открыл его в 21:30:10, живая поездка началась с нуля),
и Dart обязан дать по нему те же числа, что и этот файл.

    python3 tools/mirror_plus188.py путь/к/hal_samples.csv [ISO-момент-старта]

Без второго аргумента момент берётся как время последней строки — то есть
«открыли приложение прямо сейчас».

Расхождение зеркала и Dart — ошибка, и чинить её надо до выдачи, а не
после поездки.
"""
import csv
import datetime
import sys

MOTION_GAP = datetime.timedelta(minutes=5)     # BgTripBuilder.kMotionGap
LOOKBACK = datetime.timedelta(minutes=30)      # _kHalJoinLookback


def load(path):
    rows = []
    with open(path, newline='') as f:
        for r in csv.DictReader(f):
            if (r.get('source') or '') != 'hal':
                continue
            if (r.get('trip_id') or '').strip():
                continue          # приписанная строка в выборку не попадает
            raw = r.get('timestamp') or ''
            try:
                # Экспорт пишет ISO; целое число тоже принимаем — старые
                # выгрузки встречаются, и молча пропустить их значило бы
                # получить пустой отчёт вместо ответа.
                ts = (datetime.datetime.fromisoformat(raw) if '-' in raw
                      else datetime.datetime.fromtimestamp(int(raw)))
            except (KeyError, ValueError):
                continue
            v = r.get('numeric')
            try:
                v = float(v) if v not in (None, '') else None
            except ValueError:
                v = None
            rows.append({
                'ts': ts,
                'name': r.get('name') or '',
                'v': v,
            })
    rows.sort(key=lambda r: r['ts'])
    return rows


def find_join(rows, now):
    """Зеркало _findJoinableTail."""
    window = [r for r in rows if r['ts'] > now - LOOKBACK and r['ts'] <= now]
    if len(window) < 2:
        return None

    motion, last_odo = [], None
    for r in window:
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
    if len(motion) < 2:
        return None
    motion.sort()
    end = motion[-1]
    if now - end >= MOTION_GAP:
        return None
    start = end
    for i in range(len(motion) - 1, 0, -1):
        if motion[i] - motion[i - 1] >= MOTION_GAP:
            break
        start = motion[i - 1]
    if not start < end:
        return None

    first_odo = last_odo_in = first_soc = None
    peak = tmin = tmax = None
    for r in window:
        if r['ts'] < start or r['ts'] > end:
            continue
        v = r['v']
        if v is None:
            continue
        if r['name'] == 'odometer':
            if first_odo is None:
                first_odo = v
            last_odo_in = v
        elif r['name'] == 'soc_precise':
            if first_soc is None:
                first_soc = v
        elif r['name'] == 'speed':
            peak = v if peak is None or v > peak else peak
        elif r['name'] == 'battery_temp_bigdata':
            tmin = v if tmin is None or v < tmin else tmin
            tmax = v if tmax is None or v > tmax else tmax
    dist = (last_odo_in - first_odo) if (
        first_odo is not None and last_odo_in is not None
        and last_odo_in > first_odo) else 0.0
    return {
        'start': start, 'end': end, 'start_odo': first_odo,
        'start_soc': first_soc, 'distance_km': dist,
        'peak_speed': peak, 'min_temp': tmin, 'max_temp': tmax,
        'rows': sum(1 for r in window if start <= r['ts'] <= end),
    }


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rows = load(sys.argv[1])
    if not rows:
        print('неприписанных hal-строк в файле нет — подхватывать нечего')
        return 0
    now = (datetime.datetime.fromisoformat(sys.argv[2])
           if len(sys.argv) > 2 else rows[-1]['ts'])
    print(f'неприписанных строк: {len(rows)}')
    print(f'момент открытия приложения: {now:%Y-%m-%d %H:%M:%S}')
    j = find_join(rows, now)
    if j is None:
        print('ПОДХВАТЫВАТЬ НЕЧЕГО (нет движения ближе 5 минут назад)')
        return 0
    print('ПОДХВАТ')
    print(f"  окно          {j['start']:%H:%M:%S} → {j['end']:%H:%M:%S}")
    print(f"  строк         {j['rows']}")
    print(f"  дистанция     {j['distance_km']:.1f} км")
    print(f"  одометр       {j['start_odo']}")
    print(f"  SOC старта    {j['start_soc']}")
    print(f"  пик скорости  {j['peak_speed']}")
    print(f"  темп батареи  {j['min_temp']} … {j['max_temp']}")
    late = (now - j['start']).total_seconds()
    print(f"  поездка станет старше на {late:.0f} с")
    return 0


if __name__ == '__main__':
    sys.exit(main())
