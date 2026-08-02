#!/usr/bin/env python3
"""Зеркало синтеза снапшотов фоновой поездки (v0.1.90+189).

Повторяет `BgTripBuilder._writeSnapshots` шаг в шаг и считает то же самое
по `hal_samples.csv` из экспорта. Проверяется БЕЗ МАШИНЫ на настоящей
фоновой поездке 02.08 (45.8 км, приложение не открывалось): сколько строк
получится, с каким шагом, и совпадают ли крайние значения с записанной
поездкой.

    python3 tools/mirror_plus189.py hal_samples.csv ISO-начало ISO-конец
"""
import csv
import datetime
import sys

STEP = datetime.timedelta(seconds=60)
CARRIED = ('soc_precise', 'pack_voltage', 'soh', 'battery_temp_bigdata',
           'cell_v_lowest', 'cell_v_highest', 'odometer')


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    frm = datetime.datetime.fromisoformat(sys.argv[2])
    to = datetime.datetime.fromisoformat(sys.argv[3])
    window = []
    with open(sys.argv[1], newline='') as f:
        for r in csv.DictReader(f):
            if (r.get('source') or '') != 'hal':
                continue
            raw = r.get('timestamp') or ''
            try:
                ts = datetime.datetime.fromisoformat(raw)
            except ValueError:
                continue
            if ts < frm or ts > to:
                continue
            v = r.get('numeric')
            try:
                v = float(v) if v not in (None, '') else None
            except ValueError:
                v = None
            window.append({'ts': ts, 'name': r.get('name') or '', 'v': v})
    window.sort(key=lambda r: r['ts'])
    print(f'строк окна: {len(window)}  {frm:%H:%M:%S} → {to:%H:%M:%S}')

    latest, out, nxt = {}, [], None
    for r in window:
        if r['v'] is not None:
            latest[r['name']] = r['v']
        if nxt is None:
            nxt = r['ts']
        while nxt is not None and r['ts'] >= nxt:
            soc, packv = latest.get('soc_precise'), latest.get('pack_voltage')
            if soc is not None or packv is not None:
                lo, hi = latest.get('cell_v_lowest'), latest.get('cell_v_highest')
                out.append({
                    'at': nxt, 'soc': soc, 'packv': packv,
                    'soh': latest.get('soh'),
                    'temp': latest.get('battery_temp_bigdata'),
                    'odo': latest.get('odometer'),
                    'cmin': None if lo is None else round(lo * 1000),
                    'cmax': None if hi is None else round(hi * 1000),
                    'spread': None if (lo is None or hi is None)
                              else round((hi - lo) * 1000, 1),
                })
            nxt = nxt + STEP
    print(f'СНАПШОТОВ БУДЕТ: {len(out)}')
    if not out:
        return 0
    span = (out[-1]['at'] - out[0]['at']).total_seconds()
    print(f'  первый {out[0]["at"]:%H:%M:%S}  последний {out[-1]["at"]:%H:%M:%S}'
          f'  средний шаг {span / max(1, len(out) - 1):.0f} с')
    for tag, s in (('первый', out[0]), ('последний', out[-1])):
        print(f'  {tag:10} SOC={s["soc"]} odo={s["odo"]} packV={s["packv"]} '
              f'SOH={s["soh"]} t={s["temp"]} '
              f'ячейки {s["cmin"]}/{s["cmax"]} мВ разброс {s["spread"]}')
    holes = sum(1 for s in out if s['odo'] is None)
    print(f'  строк без одометра: {holes}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
