#!/usr/bin/env python3
"""Зеркало +193, пункт 2 — тройка ячеек как дельта одного мгновения.

Воспроизводит на РЕАЛЬНОМ экспорте то, что делает `bg_trip_builder`:
  * синтез снапшотов шагом 60 с с переносом значений вперёд;
  * агрегат `trips.max_cell_spread_mv` максимумом по перенесённым парам.

И показывает, что даёт правило парности: пара пишется только если оба
значения обновлялись не дальше окна друг от друга, иначе не пишется
ни одно из трёх.

Запуск:  python3 mirror_plus193_cells.py <распакованный_экспорт>/samples.sqlite
"""
import sqlite3
import sys

TRIP = 155
STEP = 60          # шаг синтеза, секунды (как у живого писателя)
WINDOW = 1         # окно парности журнала, секунды (kCellPairWindowJournalMs)

FAIL = []


def check(cond, msg):
    print(('  [PASS] ' if cond else '  [FAIL] ') + msg)
    if not cond:
        FAIL.append(msg)


def rows(db, trip):
    """Строки журнала поездки в том же порядке, что видит строитель."""
    return db.execute(
        'SELECT timestamp, name, numeric_value FROM hal_samples '
        'WHERE trip_id = ? ORDER BY timestamp, id', (trip,)
    ).fetchall()


def replay(window, pair_window=None):
    """Синтез снапшотов. pair_window=None — как сегодня, без правила."""
    latest, at_of = {}, {}
    out, next_at = [], None
    for ts, name, v in window:
        if v is not None and name is not None:
            latest[name] = v
            at_of[name] = ts
        if next_at is None:
            next_at = ts
        while next_at is not None and ts >= next_at:
            out.append(flush(next_at, latest, at_of, pair_window))
            next_at += STEP
    return [r for r in out if r is not None]


def flush(at, latest, at_of, pair_window):
    soc, packv = latest.get('soc_precise'), latest.get('pack_voltage')
    if soc is None and packv is None:
        return None                      # прогрев: пустых строк не пишем
    lo, hi = latest.get('cell_v_lowest'), latest.get('cell_v_highest')
    lo_at, hi_at = at_of.get('cell_v_lowest'), at_of.get('cell_v_highest')
    delta = None if lo_at is None or hi_at is None else abs(hi_at - lo_at)
    keep = lo is not None and hi is not None
    if keep and pair_window is not None:
        keep = delta is not None and delta <= pair_window
    return {
        'at': at,
        'delta_ts': delta,
        'spread': round((hi - lo) * 1000.0, 6) if keep else None,
        'vmin': round(lo * 1000.0) if keep else None,
        'vmax': round(hi * 1000.0) if keep else None,
    }


def aggregate(window, pair_window=None):
    """Максимум разброса — то, что уезжает в trips.max_cell_spread_mv."""
    hi = lo = hi_at = lo_at = None
    best = None
    for ts, name, v in window:
        if v is None:
            continue
        if name == 'cell_v_highest':
            hi, hi_at = v, ts
        if name == 'cell_v_lowest':
            lo, lo_at = v, ts
        if hi is None or lo is None:
            continue
        if pair_window is not None and abs(hi_at - lo_at) > pair_window:
            continue
        d = (hi - lo) * 1000.0
        if best is None or d > best:
            best = d
    return best



# ─────────────────── зеркало источника (HalOut.kt) ───────────────────
#
# Порт логики придушивания из Kotlin. Проверяет ровно то, что нельзя
# проверить чтением: встречная запись пары даёт одномоментность и НЕ
# раздувает журнал. Без порта пришлось бы верить рассуждению, а рассуждение
# про «не зациклится» — именно то, что здесь легко ошибиться.

THROTTLE_MS = {'cell_v_lowest': 10_000, 'cell_v_highest': 10_000}
PAIRED_WITH = {'cell_v_lowest': 'cell_v_highest',
               'cell_v_highest': 'cell_v_lowest'}
PAIR_GRACE_MS = 250


def run_journal(events, paired):
    """Возвращает список записанных строк как (ts, name)."""
    last = {}
    out = []
    for ts, name in events:
        prev = last.get(name)
        if prev is not None and ts - prev < THROTTLE_MS[name]:
            continue
        last[name] = ts
        if paired:
            partner = PAIRED_WITH.get(name)
            if partner is not None:
                p_prev = last.get(partner)
                if p_prev is None or ts - p_prev > PAIR_GRACE_MS:
                    last[partner] = ts - THROTTLE_MS[partner]
        out.append((ts, name))
    return out


def pair_gaps(rows):
    """|Δts| между каждой парой соседних записей разных имён, в секундах."""
    los = [t for t, n in rows if n == 'cell_v_lowest']
    his = [t for t, n in rows if n == 'cell_v_highest']
    gaps = []
    for t in los:
        if his:
            gaps.append(min(abs(h - t) for h in his) / 1000.0)
    return gaps


def check_source():
    print('=== зеркало источника: 48 Гц, 600 с, две цели в противофазе ===')
    # Противофаза как в поле: hi начинает на 5 с позже lo.
    ev = []
    for k in range(int(600 * 48)):
        ts = k * 1000 // 48
        ev.append((ts, 'cell_v_lowest'))
        ev.append((ts + 5_000, 'cell_v_highest'))
    ev.sort()

    before = run_journal(ev, paired=False)
    after = run_journal(ev, paired=True)
    g_before, g_after = pair_gaps(before), pair_gaps(after)
    med_b = sorted(g_before)[len(g_before) // 2]
    med_a = sorted(g_after)[len(g_after) // 2]
    print(f'  без встречной записи: строк {len(before)}, '
          f'медиана |Δts| {med_b:.3f} с')
    print(f'  со встречной записью: строк {len(after)}, '
          f'медиана |Δts| {med_a:.3f} с')

    check(med_b > 1.0,
          f'без починки пара расходится дальше секунды ({med_b:.3f} с) — '
          f'правило чтения отбросило бы почти всё')
    check(med_a <= 1.0,
          f'со встречной записью пара внутри секунды ({med_a:.3f} с) — '
          f'журнальное окно начинает пропускать')
    check(len(after) <= len(before) * 1.1,
          f'журнал не раздулся: {len(before)} → {len(after)} строк')
    # ПЕРВЫЙ ОБМЕН — ИСКЛЮЧЕНИЕ ПО ПОСТРОЕНИЮ, и знать о нём надо заранее.
    # Пока парного имени в журнале ещё нет, встречной записи не из чего
    # исходить: первая строка пишется в одиночестве, и её пара находится на
    # расстоянии исходной противофазы. Правило чтения такую тройку отбросит,
    # то есть у САМОГО ПЕРВОГО фонового снапшота после старта потока разброса
    # не будет. Это честная цена: выдуманного числа там тоже не появится.
    late = [g for g in g_after if g > 1.0]
    check(len(late) <= 1,
          f'за секунду выпадает не больше одной пары — первый обмен '
          f'(выпало {len(late)})')
    # Отбрасываем САМОЕ БОЛЬШОЕ, а не первое по порядку: первая редакция
    # этой проверки брала `sorted(...)[1:]` и оставляла выброс на месте —
    # сортировка кладёт его в конец. Проверка упала и была права.
    check(max(sorted(g_after)[:-1]) <= 1.0,
          f'все пары, кроме первого обмена, внутри секунды '
          f'(худшая из остальных {max(sorted(g_after)[:-1]):.3f} с)')

    # Главный риск конструкции: без окна снисхождения пара зацикливается и
    # оба имени начинают писать на каждом кадре.
    global PAIR_GRACE_MS
    saved, PAIR_GRACE_MS = PAIR_GRACE_MS, -1
    loop = run_journal(ev, paired=True)
    PAIR_GRACE_MS = saved
    check(len(loop) > len(after) * 10,
          f'без окна снисхождения пара действительно зациклилась '
          f'({len(loop)} строк против {len(after)}) — предохранитель нужен')
    print()


def main(path):
    db = sqlite3.connect(path)
    window = rows(db, TRIP)
    print(f'поездка #{TRIP}: строк журнала {len(window)}, '
          f'окно парности {WINDOW} с\n')

    today = replay(window)
    fixed = replay(window, WINDOW)

    print('=== распределение |Δts| между lo и hi в момент записи ===')
    for r in today:
        d = r['delta_ts']
        mark = ' ← отрицательный' if (r['spread'] or 0) < 0 else ''
        print(f"  {r['at']}  Δts={d:>4} с  разброс="
              f"{r['spread'] if r['spread'] is None else round(r['spread'], 1):>7}"
              f" мВ{mark}")
    print()

    neg = [r for r in today if (r['spread'] or 0) < 0]
    check(len(today) == 19, f'сегодня синтезируется 19 снапшотов (факт {len(today)})')
    check(len(neg) == 5, f'из них пять с отрицательным разбросом (факт {len(neg)})')

    # шаг ровно 60 с
    steps = {today[i + 1]['at'] - today[i]['at'] for i in range(len(today) - 1)}
    check(steps == {STEP}, f'шаг синтеза ровно {STEP} с (факт {sorted(steps)})')

    # правило убирает ровно отрицательные и ничего больше
    dropped = [r['at'] for r in fixed if r['spread'] is None]
    # Правило отбрасывает БОЛЬШЕ пяти, и это НЕ дефект, а измеренная
    # необходимость. Замер по окнам показал: при 3 с три отрицательных из
    # пяти выживают (Δts = 3, 3, 2), а честные показания лежат снаружи
    # (4, 5, 6 с) — то есть Δts не разделяет плохое от хорошего, пока
    # источник отдаёт противофазу. Выдуманы все девятнадцать разбросов;
    # отрицательные лишь те, где ошибка перевалила знак.
    check(all(x['at'] in dropped for x in neg),
          'все пять отрицательных отброшены')
    check(len(dropped) > len(neg),
          f'отброшено больше пяти ({len(dropped)}) — при противофазе честных '
          f'пар меньше, чем строк')

    kept_today = {r['at']: r['spread'] for r in today}
    kept_fixed = {r['at']: r['spread'] for r in fixed if r['spread'] is not None}
    check(all(kept_today[a] == v for a, v in kept_fixed.items()),
          f'уцелевшие {len(kept_fixed)} не изменились бит-в-бит')
    check(all(r['spread'] is None or r['spread'] >= 0 for r in fixed),
          'после правила отрицательного разброса не остаётся')
    check(all((r['vmin'] is None) == (r['spread'] is None) and
              (r['vmax'] is None) == (r['spread'] is None) for r in fixed),
          'тройка неделима: min/max отсутствуют ровно там, где отсутствует разброс')

    print()
    print('=== агрегат поездки (trips.max_cell_spread_mv) ===')
    a_today, a_fixed = aggregate(window), aggregate(window, WINDOW)
    in_db = db.execute(
        'SELECT max_cell_spread_mv FROM trips WHERE id=?', (TRIP,)).fetchone()[0]
    print(f'  в базе сейчас : {in_db:.1f} мВ')
    print(f'  зеркало без правила: {a_today:.1f} мВ')
    print(f'  зеркало с правилом : {a_fixed:.1f} мВ')
    check(abs(a_today - in_db) < 0.01,
          'зеркало воспроизводит сегодняшний агрегат бит-в-бит')
    check(a_fixed < a_today,
          f'правило снимает выброс: {a_today:.1f} → {a_fixed:.1f} мВ')

    live = db.execute(
        'SELECT MIN(cell_spread), MAX(cell_spread) FROM snapshots '
        'WHERE trip_id = 156').fetchone()
    print(f'\n  для сверки, живая #156: {live[0]:.1f}..{live[1]:.1f} мВ')
    check(live[0] <= a_fixed <= live[1],
          f'исправленный агрегат попал В ДИАПАЗОН живой поездки '
          f'({live[0]:.1f}..{live[1]:.1f} мВ)')

    check_source()

    print('=== миграция 18 → 19, прогон на копии реальной базы ===')
    tot = db.execute(
        'SELECT COUNT(*) FROM snapshots WHERE cell_spread < 0').fetchone()[0]
    print(f'  снапшотов с отрицательным разбросом: {tot}')
    for r in db.execute('SELECT trip_id, COUNT(*), MIN(cell_spread) FROM snapshots '
                        'WHERE cell_spread < 0 GROUP BY trip_id'):
        print(f'    trip {r[0]}: {r[1]} строк, минимум {r[2]:.1f} мВ')
    check(tot == 9, f'девять строк, как в плане (факт {tot})')

    agg = db.execute(
        "SELECT COUNT(*), MAX(max_cell_spread_mv) FROM trips "
        "WHERE source = 'hal_bg' AND max_cell_spread_mv IS NOT NULL"
    ).fetchone()
    print(f'  фоновых поездок с агрегатом: {agg[0]}, '
          f'крупнейший {agg[1]:.1f} мВ')

    # Прогоняем ОБЕ команды на копии в памяти. База экспорта открыта только
    # на чтение по смыслу, поэтому переносим её в память целиком.
    mem = sqlite3.connect(':memory:')
    db.backup(mem)
    rows_before = mem.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0]
    trips_before = mem.execute('SELECT COUNT(*) FROM trips').fetchone()[0]
    live_before = mem.execute(
        "SELECT COUNT(*) FROM trips WHERE (source IS NULL OR source <> 'hal_bg')"
        " AND max_cell_spread_mv IS NOT NULL").fetchone()[0]

    def migrate(conn):
        a = conn.execute(
            'UPDATE snapshots SET cell_spread = NULL, '
            'cell_voltage_min = NULL, cell_voltage_max = NULL '
            'WHERE cell_spread < 0').rowcount
        b = conn.execute(
            'UPDATE trips SET max_cell_spread_mv = NULL '
            "WHERE source = 'hal_bg' AND max_cell_spread_mv IS NOT NULL"
        ).rowcount
        conn.commit()
        return a, b

    a1, b1 = migrate(mem)
    a2, b2 = migrate(mem)
    print(f'  первый проход: снапшотов {a1}, поездок {b1}')
    print(f'  второй проход: снапшотов {a2}, поездок {b2}')

    check((a1, b1) == (9, 1), f'первый проход правит ровно 9 и 1 ({a1}, {b1})')
    check((a2, b2) == (0, 0),
          f'второй проход не правит ничего — идемпотентна ({a2}, {b2})')
    check(mem.execute('SELECT COUNT(*) FROM snapshots').fetchone()[0]
          == rows_before,
          f'ни один снапшот не удалён ({rows_before})')
    check(mem.execute('SELECT COUNT(*) FROM trips').fetchone()[0]
          == trips_before, f'ни одна поездка не удалена ({trips_before})')
    check(mem.execute(
        'SELECT COUNT(*) FROM snapshots WHERE cell_spread < 0').fetchone()[0]
        == 0, 'отрицательных разбросов не осталось')
    check(mem.execute(
        "SELECT COUNT(*) FROM trips WHERE source = 'hal_bg' "
        "AND max_cell_spread_mv IS NOT NULL").fetchone()[0] == 0,
        'у фоновых поездок агрегат разброса снят')
    check(mem.execute(
        "SELECT COUNT(*) FROM trips WHERE (source IS NULL OR source <> 'hal_bg')"
        " AND max_cell_spread_mv IS NOT NULL").fetchone()[0] == live_before,
        f'живые поездки не тронуты ({live_before} с агрегатом)')
    check(mem.execute(
        'SELECT COUNT(*) FROM snapshots WHERE soc IS NOT NULL').fetchone()[0]
        == db.execute(
            'SELECT COUNT(*) FROM snapshots WHERE soc IS NOT NULL').fetchone()[0],
        'прочие поля снапшотов целы (SOC)')

    print('\n' + '=' * 60)
    print('MIRROR FAIL' if FAIL else 'MIRROR PASS')
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else 'samples.sqlite'))
