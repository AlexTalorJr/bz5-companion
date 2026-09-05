#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Зеркало +215: мощность зарядки на РЕАЛЬНОМ HAL-потоке.

Повторяет логику `halPowerKw` из lib/services/hal_telemetry_service.dart
на записанной AC-сессии и говорит, какую долю времени у экрана есть число.

Зачем. +214 объявил «точный канал напряжения ведёт», гейт CC5 держал этот
текст, мутации были зелёные — а в машине мощность жила от грубого канала,
потому что `pack_voltage_fine` не попадало в `_lastGood`. Текстовый гейт
такое не видит по определению: мёртвая ветка выглядит как живая. Видит
только прогон настоящего потока через ту же логику удержания — то, чего
требует правило пост-+86 и чего +214 не сделал.

Две модели, обе повторяются буквально:
  • before — как было в 0.2.15+214 на голове: ток событийный (удерж.
    бессрочно), напряжение ТОЛЬКО грубое `pack_voltage` с окном 90 с,
    потому что точное в _stickyNames не входило и в _lastGood не писалось;
  • after  — 0.2.16+215: точное `pack_voltage_fine` с окном 90 с ведёт,
    грубое с тем же окном запасное, ток тот же.

Проверка самого зеркала: в фикстуре лежат снимки приложения —
`app_snapshot_charging` (1 = halChargingActive) и `app_snapshot_power_kw`
(пусто = мощности не было). Модель before обязана предсказать
наличие/отсутствие мощности в КАЖДОМ снимке, где зарядка подтверждена —
иначе зеркало описывает не тот код, что стоял в машине. Снимки до
подтверждения (20 с дебаунса) не сравниваются: там halChargePowerKw
молчит по воротам активности, а не по напряжению, и здесь это не предмет.

Запуск:
    python3 tools/mirror_plus215_power.py                 # фикстура 05.09
    python3 tools/mirror_plus215_power.py path/to.csv     # свой экспорт
Свой CSV — либо такой же трёхколоночный (timestamp,name,numeric), либо
hal_samples.csv экспорта (тогда снимков нет и самопроверка пропускается).
Код возврата 0 — after покрывает ≥ MIN_AFTER и самопроверка сошлась.
"""
import csv
import pathlib
import re
import sys
from datetime import datetime, timedelta

FIXTURE = pathlib.Path(__file__).parent / 'data' / 'ac_session_20260905_power.csv'
SERVICE = pathlib.Path(__file__).parent.parent / 'lib' / 'services' / 'hal_telemetry_service.dart'
MIN_AFTER = 0.99                       # доля минут с числом после +215


def read_service():
    """Модель «как стало» берёт свои две константы ИЗ КОДА, не из головы:
    окно _coreHold и членство pack_voltage_fine в _stickyNames. Иначе зеркало
    описывало бы намерение, а не дерево — ровно то, чем грешил гейт CC5."""
    if not SERVICE.exists():
        return timedelta(seconds=90), True
    # Комментарии долой ДО поиска: в них имена названы намеренно (урок №22 —
    # иглы ловили пояснительный текст), и «да» из комментария ничего не
    # стоит.
    src = '\n'.join(re.sub(r'//.*$', '', ln)
                    for ln in SERVICE.read_text(encoding='utf-8').splitlines())
    m = re.search(r'_coreHold = Duration\(seconds: (\d+)\);', src)
    hold = timedelta(seconds=int(m.group(1))) if m else timedelta(seconds=90)
    sticky = re.search(r'_stickyNames = \{(.*?)\n  \};', src, re.S)
    fine_sticky = sticky is not None and "'pack_voltage_fine'" in sticky.group(1)
    return hold, fine_sticky


CORE_HOLD, FINE_STICKY_IN_CODE = read_service()


def load(path):
    rows = []
    with open(path, newline='', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            name = r['name']
            if name not in ('pack_voltage_fine', 'pack_voltage',
                            'pack_current', 'app_snapshot_power_kw',
                            'app_snapshot_charging'):
                continue
            ts = datetime.fromisoformat(r['timestamp'])
            v = r['numeric']
            rows.append((ts, name, float(v) if v not in ('', 'nan') else None))
    rows.sort(key=lambda x: x[0])
    return rows


class Hold:
    """_latest/_lastGood для одного имени: значение и время прихода."""

    def __init__(self):
        self.value = None
        self.at = None

    def push(self, at, value):
        self.value, self.at = value, at

    def within(self, now, hold):
        return self.at is not None and now - self.at <= hold


def power_kw(now, cur, fine, coarse, fine_sticky):
    """halPowerKw: ток событийный (всегда, если пришёл); напряжение — точное
    в окне 90 с, если оно липкое, иначе грубое в окне 90 с."""
    if cur.value is None:
        return None
    v = None
    if fine_sticky and fine.within(now, CORE_HOLD):
        v = fine.value
    elif coarse.within(now, CORE_HOLD):
        v = coarse.value
    if v is None:
        return None
    return abs(v * cur.value / 1000.0)


def replay(rows, fine_sticky):
    cur, fine, coarse = Hold(), Hold(), Hold()
    per_minute = {}          # минута → мощность (или None)
    snap_pred = []           # (время снимка, предсказано ли число, было ли)
    kws = []
    charging_at = {}
    for ts, name, v in rows:
        if name == 'app_snapshot_charging':
            charging_at[ts] = v == 1.0
            continue
        if name == 'app_snapshot_power_kw':
            if not charging_at.get(ts, False):
                continue
            p = power_kw(ts, cur, fine, coarse, fine_sticky)
            snap_pred.append((ts, p is not None, v is not None))
            continue
        if v is None:
            continue
        {'pack_current': cur, 'pack_voltage_fine': fine,
         'pack_voltage': coarse}[name].push(ts, v)
        p = power_kw(ts, cur, fine, coarse, fine_sticky)
        per_minute[ts.replace(second=0, microsecond=0)] = p
        if p is not None:
            kws.append(p)
    return per_minute, snap_pred, kws


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURE
    rows = load(path)
    if not rows:
        print(f'нет строк Charging в {path}')
        return 2
    first = rows[0][0]
    last = rows[-1][0]
    print(f'поток: {first} .. {last}, строк {len(rows)}')

    ok = True
    print(f'из кода: _coreHold = {CORE_HOLD.seconds} с, '
          f"pack_voltage_fine в _stickyNames: {'да' if FINE_STICKY_IN_CODE else 'НЕТ'}")
    for label, sticky in (('before (+214, точное не липкое)', False),
                          ('after  (дерево как есть)', FINE_STICKY_IN_CODE)):
        per_min, snaps, kws = replay(rows, sticky)
        mins = sorted(per_min)
        # доля минут, в которых ХОТЯ БЫ на одном кадре было число
        have = sum(1 for m in mins if per_min[m] is not None)
        share = have / len(mins) if mins else float('nan')
        mean = sum(kws) / len(kws) if kws else float('nan')
        print(f'{label}: минут с мощностью {have}/{len(mins)} = {share:.1%}'
              f', средняя {mean:.2f} kW')
        if snaps and label.startswith('before'):
            # Сверка только для before — в машине стоял именно он.
            hit = sum(1 for _, pred, real in snaps if pred == real)
            print(f'   снимки приложения: предсказано верно {hit}/{len(snaps)}')
            if hit != len(snaps):
                print('   FAIL: модель before не совпала со снимками — зеркало '
                      'описывает не тот код, что стоял в машине')
                ok = False
        if label.startswith('after') and not (share >= MIN_AFTER):
            print(f'   FAIL: after покрывает {share:.1%} < {MIN_AFTER:.0%}')
            ok = False
    print('MIRROR PASS' if ok else 'MIRROR FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
